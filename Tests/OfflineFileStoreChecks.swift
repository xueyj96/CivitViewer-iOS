import Foundation

@main struct OfflineFileStoreChecks {
    @MainActor static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("OfflineFileStoreChecks-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let first = OfflineFileStore.directory(root: root, owner: 41)
        let second = OfflineFileStore.directory(root: root, owner: 52)
        let index = first.appendingPathComponent("index.json")
        precondition(first.lastPathComponent.count == 64 && first != second)
        let empty = try OfflineFileStore.load(directory: first, owner: 41)
        precondition(empty.manifest.records.isEmpty && empty.snapshot?.disk.totalBytes == 0)
        _ = try OfflineFileStore.load(directory: second, owner: 52)
        let record = OfflineRecord(id: 99, video: true, username: nil, creatorID: nil,
                                   browsingLevel: nil, collectionIDs: [], cloudState: .unknown)
        let manifest = OfflineManifest(accountID: 41, records: [record])
        let indexSize = try OfflineFileStore.persist(manifest, in: first)
        let prior = try Data(contentsOf: index)
        precondition(indexSize == prior.count)
        let loaded = try OfflineFileStore.load(directory: first, owner: 41)
        precondition(loaded.manifest.records == [record])
        do {
            _ = try OfflineFileStore.load(directory: first, owner: 52)
            preconditionFailure("wrong owner admitted")
        } catch ClientError.invalidResponse {}
        let unchanged = try Data(contentsOf: index)
        precondition(unchanged == prior)
        let unknown = first.appendingPathComponent("unexpected", isDirectory: true)
        try files.createDirectory(at: unknown, withIntermediateDirectories: false)
        let unreadable = try OfflineFileStore.load(directory: first, owner: 41)
        precondition(unreadable.snapshot == nil && unreadable.manifest.records == [record])
        do {
            _ = try OfflineFileStore.sizeOrAbsent(unknown)
            preconditionFailure("nonregular entry treated as absent")
        } catch ClientError.invalidResponse {}
        try files.removeItem(at: unknown)
        let absent = try OfflineFileStore.sizeOrAbsent(unknown)
        precondition(absent == 0)

        let target = first.appendingPathComponent(record.fileName)
        let source = root.appendingPathComponent("source.tmp")
        try Data([9, 8, 7]).write(to: source)
        try Data([1, 2]).write(to: target)
        do {
            _ = try OfflineFileStore.install(source, at: target, copying: true, limit: 2, permit: OfflineWritePermit())
            preconditionFailure("quota bypassed")
        } catch OfflineFileStoreError.limitExceeded {}
        let preserved = try Data(contentsOf: target)
        precondition(preserved == Data([1, 2]))
        let copied = try OfflineFileStore.install(source, at: target, copying: true, limit: 3, permit: OfflineWritePermit())
        let current = try Data(contentsOf: target)
        precondition(copied == 3 && current == Data([9, 8, 7]) && files.fileExists(atPath: source.path))

        let badTarget = first.appendingPathComponent("unexpected", isDirectory: true)
        try files.createDirectory(at: badTarget, withIntermediateDirectories: false)
        do {
            _ = try OfflineFileStore.install(source, at: badTarget, copying: true, limit: 3, permit: OfflineWritePermit())
            preconditionFailure("replacement of directory was allowed")
        } catch let error as NSError {
            precondition(error.domain == NSPOSIXErrorDomain)
        }
        let rootContents = try files.contentsOfDirectory(atPath: root.path)
        precondition(!rootContents.contains { $0.hasPrefix(".install-") })
        try files.removeItem(at: badTarget)

        let store = OfflineFileStore()
        var events: [String] = []
        let gate = DispatchSemaphore(value: 0)
        let newScan = Date(timeIntervalSince1970: 1_000)
        let firstJob = store.enqueue({
            dispatchPrecondition(condition: .notOnQueue(.main))
            gate.wait()
            let committed = OfflineManifest(accountID: 41, records: [record], lastScan: newScan)
            return try OfflineFileStore.persist(committed, in: first)
        }, completed: { result in
            MainActor.assertIsolated()
            if case .success = result { events.append("first") }
        })
        let permit = OfflineWritePermit()
        let late = store.enqueue({
            try OfflineFileStore.install(source, at: target, copying: false, limit: 3, permit: permit)
        }, completed: { result in
            if case .failure(let error) = result, error is CancellationError { events.append("rejected") }
        })
        permit.invalidate()
        let otherAccount = store.enqueue({
            try OfflineFileStore.load(directory: second, owner: 52)
        }, completed: { result in
            if case .success = result { events.append("other") }
        })
        let reopened = store.enqueue({
            try OfflineFileStore.load(directory: first, owner: 41)
        }, completed: { result in
            if case .success = result { events.append("read") }
        })
        gate.signal()
        _ = try await firstJob.value
        do {
            _ = try await late.value
            preconditionFailure("revoked write admitted")
        } catch is CancellationError {}
        let other = try await otherAccount.value
        let rebound = try await reopened.value
        precondition(events == ["first", "rejected", "other", "read"] && files.fileExists(atPath: source.path))
        precondition(other.manifest.records.isEmpty && rebound.manifest.lastScan == newScan)
        let moved = try OfflineFileStore.install(source, at: target, copying: false, limit: 3, permit: OfflineWritePermit())
        precondition(moved == 3 && !files.fileExists(atPath: source.path))


        // A re-favorite can arrive while conditional cleanup is waiting for disk.
        let stillSaved = OfflineWritePermit()
        let removalGate = DispatchSemaphore(value: 0)
        store.enqueue { removalGate.wait() }
        let intent = OfflineManifest(accountID: 41, records: [record], omittedIDs: [record.id])
        let cleanup = store.enqueue {
            try OfflineFileStore.removeAfterExcluding([record], manifest: intent, in: first,
                                                      binding: OfflineWritePermit(), membership: stillSaved)
        }
        stillSaved.invalidate()
        removalGate.signal()
        do {
            _ = try await cleanup.value
            preconditionFailure("Revoked membership admitted a deletion")
        } catch is CancellationError {}
        let afterRevocation = try OfflineFileStore.load(directory: first, owner: 41)
        precondition(afterRevocation.manifest.omittedIDs.isEmpty && files.fileExists(atPath: target.path))

        // A broken index target cannot admit deletion of any media.
        try files.removeItem(at: index)
        try files.createDirectory(at: index, withIntermediateDirectories: false)
        do {
            _ = try OfflineFileStore.removeAfterExcluding([record], manifest: intent, in: first,
                                                          binding: OfflineWritePermit(), membership: nil)
            preconditionFailure("Expected protected index write to fail")
        } catch {
            precondition(files.fileExists(atPath: target.path))
        }
        try files.removeItem(at: index)
        _ = try OfflineFileStore.persist(manifest, in: first)

        let staleInstall = root.appendingPathComponent(".install-" + UUID().uuidString)
        let staleRepair = root.appendingPathComponent(".repair-" + UUID().uuidString, isDirectory: true)
        let unrelated = root.appendingPathComponent(".install-existing")
        try Data([7]).write(to: staleInstall)
        try Data([7]).write(to: unrelated)
        try files.createDirectory(at: staleRepair, withIntermediateDirectories: false)
        try Data([7]).write(to: staleRepair.appendingPathComponent("partial.mp4"))
        OfflineFileStore.recoverStaging(in: root)
        precondition(!files.fileExists(atPath: staleInstall.path) && !files.fileExists(atPath: staleRepair.path))
        precondition(files.fileExists(atPath: unrelated.path) && files.fileExists(atPath: target.path))

        let secondRecord = OfflineRecord(id: 100, video: false, username: nil, creatorID: nil,
                                         browsingLevel: nil, collectionIDs: [], cloudState: .unknown)
        let secondRecordFile = first.appendingPathComponent(secondRecord.fileName, isDirectory: true)
        try files.createDirectory(at: secondRecordFile, withIntermediateDirectories: false)
        let poster = first.appendingPathComponent(record.posterName)
        let repairReceipt = MediaRepairStore.receiptURL(target, directory: first)
        let otherMedia = second.appendingPathComponent(record.fileName)
        for file in [poster, repairReceipt, otherMedia] { try Data([3]).write(to: file) }
        let removed = try OfflineFileStore.remove([record, secondRecord], in: first)
        precondition(removed == [record.id])
        precondition(!files.fileExists(atPath: poster.path) && !files.fileExists(atPath: repairReceipt.path))
        precondition(files.fileExists(atPath: secondRecordFile.path) && files.fileExists(atPath: otherMedia.path))
        try OfflineFileStore.empty(directory: first)
        let after = try OfflineFileStore.scan(directory: first)
        precondition(after.disk.totalBytes == 0 && files.fileExists(atPath: otherMedia.path))
        print("OfflineFileStore fixture checks passed")
    }
}
