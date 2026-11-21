import CryptoKit
import Darwin
import Foundation

enum OfflineFileStoreError: Error {
    case limitExceeded
}

/// A paused download may finish staging but cannot publish its file.
final class OfflineWritePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.withLock { valid = false }
    }

    func check() throws {
        guard lock.withLock({ valid }) else { throw CancellationError() }
    }
}

@MainActor
final class OfflineFileStore {
    struct Snapshot: Sendable {
        let disk: OfflineDiskSnapshot
        let repairBytes: [String: Int64]
    }

    struct Load: Sendable {
        let manifest: OfflineManifest
        let snapshot: Snapshot?
    }

    struct Removal: Sendable {
        let indexSize: Int64
        let removed: Set<Int>?
        let snapshot: Snapshot?
    }

    private let queue = DispatchQueue(label: "CivitViewer.offline-files", qos: .utility)
    private var tail: Task<Void, Never>?

    /// Reserve the order at the call site. Each result is applied on the main
    /// actor before the next operation starts, even when an operation fails.
    @discardableResult func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T,
        completed: @escaping @MainActor (Result<T, Error>) -> Void = { _ in }
    ) -> Task<T, Error> {
        let previous = tail
        let queue = self.queue
        let job = Task<T, Error> {
            await previous?.value
            let result: Result<T, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Result(catching: operation))
                }
            }
            completed(result)
            return try result.get()
        }
        tail = Task { _ = await job.result }
        return job
    }

    nonisolated static func directory(root: URL, owner: Int) -> URL {
        let key = SHA256.hash(data: Data(String(owner).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true)
    }

    /// Called before the first account load. Only our uniquely named staging
    /// entries can remain here after the process stops mid-copy or conversion.
    nonisolated static func recoverStaging(in root: URL) {
        let manager = FileManager.default
        guard (try? requireDirectory(root)) != nil,
              let contents = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in contents {
            let name = file.lastPathComponent
            let entries: [(String, FileAttributeType)] = [(".install-", .typeRegular), (".repair-", .typeDirectory)]
            guard let entry = entries.first(where: { name.hasPrefix($0.0) }),
                  UUID(uuidString: String(name.dropFirst(entry.0.count))) != nil,
                  let attributes = try? manager.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == entry.1 else { continue }
            try? manager.removeItem(at: file)
        }
    }

    nonisolated static func load(directory: URL, owner: Int) throws -> Load {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try requireDirectory(directory)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(resourceValues)

        let index = directory.appendingPathComponent("index.json")
        let manifest: OfflineManifest
        if try regularFileSize(index) != nil {
            manifest = try JSONDecoder().decode(OfflineManifest.self, from: Data(contentsOf: index))
            guard manifest.version == 1, manifest.accountID == owner else {
                throw ClientError.invalidResponse
            }
        } else {
            manifest = OfflineManifest(accountID: owner)
        }
        return Load(manifest: manifest, snapshot: try? scan(directory: directory))
    }

    nonisolated static func scan(directory: URL) throws -> Snapshot {
        try requireDirectory(directory)
        let disk = try OfflineDiskSnapshot.read(directory: directory)
        let repairBytes = MediaRepairStore.familySnapshot(disk.files, sizes: disk.sizes).bytes
        return Snapshot(disk: disk, repairBytes: repairBytes)
    }

    nonisolated static func freeBytes(in directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    nonisolated static func sizeOrAbsent(_ file: URL) throws -> Int64 {
        try regularFileSize(file) ?? 0
    }

    nonisolated static func persist(_ manifest: OfflineManifest, in directory: URL) throws -> Int64 {
        try requireDirectory(directory)
        guard manifest.version == 1 else { throw ClientError.invalidResponse }
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: directory.appendingPathComponent("index.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return Int64(data.count)
    }

    nonisolated static func install(
        _ source: URL,
        at target: URL,
        copying: Bool,
        limit: Int64,
        permit: OfflineWritePermit
    ) throws -> Int64 {
        try permit.check()
        try requireDirectory(target.deletingLastPathComponent())
        _ = try installSize(source, limit: limit)

        // Account scans only see final files. The staging path shares their volume.
        let stage = target.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".install-" + UUID().uuidString)
        let files = FileManager.default
        defer { try? files.removeItem(at: stage) }
        if copying {
            try files.copyItem(at: source, to: stage)
        } else {
            try files.moveItem(at: source, to: stage)
        }
        let size = try installSize(stage, limit: limit)
        try files.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stage.path
        )
        try permit.check()
        try replace(stage, at: target)
        return size
    }

    nonisolated static func replace(_ source: URL, at target: URL) throws {
        guard source.isFileURL, target.isFileURL else { throw ClientError.invalidResponse }
        try source.withUnsafeFileSystemRepresentation { sourcePath in
            try target.withUnsafeFileSystemRepresentation { targetPath in
                guard let sourcePath, let targetPath else { throw ClientError.invalidResponse }
                guard rename(sourcePath, targetPath) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
    }

    nonisolated static func remove(_ records: [OfflineRecord], in directory: URL) throws -> Set<Int> {
        try requireDirectory(directory)
        let files = FileManager.default
        let contents = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let repairFamilies = MediaRepairStore.familySnapshot(contents).files
        var removed = Set<Int>()
        for record in records {
            let media = directory.appendingPathComponent(record.fileName)
            let poster = directory.appendingPathComponent(record.posterName)
            let family = repairFamilies[MediaRepairStore.stem(media)] ?? []
            do {
                for file in family + [media, poster] {
                    if try regularFileSize(file) != nil {
                        try files.removeItem(at: file)
                    }
                }
                removed.insert(record.id)
            } catch {
                // Retain the record so a later cleanup can retry the remaining files.
            }
        }
        return removed
    }

    nonisolated static func removeAfterExcluding(_ records: [OfflineRecord], manifest: OfflineManifest,
                                                in directory: URL, binding: OfflineWritePermit,
                                                membership: OfflineWritePermit?) throws -> Removal {
        try binding.check()
        try membership?.check()
        let size = try persist(manifest, in: directory)
        let removed = try? remove(records, in: directory)
        let snapshot = try? scan(directory: directory)
        return Removal(indexSize: size, removed: removed, snapshot: snapshot)
    }

    nonisolated static func empty(directory: URL) throws {
        try requireDirectory(directory)
        let files = FileManager.default
        for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try files.removeItem(at: file)
        }
    }

    nonisolated private static func requireDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw ClientError.invalidResponse }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ClientError.invalidResponse
        }
    }

    nonisolated private static func installSize(_ file: URL, limit: Int64) throws -> Int64 {
        let size = try sizeOrAbsent(file)
        guard size > 0 else { throw ClientError.invalidResponse }
        guard size <= limit else { throw OfflineFileStoreError.limitExceeded }
        return size
    }

    nonisolated private static func regularFileSize(_ file: URL) throws -> Int64? {
        guard file.isFileURL else { throw ClientError.invalidResponse }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
            throw ClientError.invalidResponse
        }
        return size.int64Value
    }
}
