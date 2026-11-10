import Foundation

/// Last confirmed collection previews. The disk index carries display metadata
/// and image-cache keys only. Site URLs, cursors and credentials stay in memory.
actor CollectionListCache {
    static let shared = CollectionListCache()
    static let previewLimit = 30
    private static let lifetime: TimeInterval = 24 * 60 * 60
    private static let maximumBytes = 512 * 1024

    struct Scope: Codable, Equatable, Sendable {
        let folderIDs: [Int]
        let filter: FeedFilter
        let browsingLevel: Int

        init?(source: FeedSource, filter: FeedFilter, browsingLevel: Int) {
            switch source {
            case .collection(let id): folderIDs = [id]
            case .collections(let ids): folderIDs = ids.sorted()
            default: return nil
            }
            guard !folderIDs.isEmpty else { return nil }
            self.filter = filter
            self.browsingLevel = filter.onlyPG ? 1 : browsingLevel
        }
    }

    struct Row: Codable, Equatable, Sendable {
        let id: Int
        let video: Bool
        let username: String?
        let creatorID: Int?
        let browsingLevel: Int?
        let duration: Double?
        let tags: Set<String>?
        let previewKeys: [String]

        init(_ item: MediaItem, previewKeys: [String]) {
            id = item.id
            video = item.isVideo
            username = item.username
            creatorID = item.creatorID
            browsingLevel = item.browsingLevel
            duration = item.durationSeconds
            tags = item.tagNames
            self.previewKeys = previewKeys
        }

        func preview(with image: URL?) -> MediaItem {
            var item = MediaItem(id: id, url: "", width: nil, height: nil, type: video ? "video" : "image",
                                 username: username, browsingLevel: browsingLevel, thumbnail: nil, creatorID: creatorID)
            item.tags = tags.map { $0.sorted().map { MediaTag(name: $0) } }
            item.metadata = duration.map { VideoTechnicalMetadata(duration: $0) }
            if video { item.offlinePosterURL = image }
            else { item.offlineMediaURL = image }
            return item
        }
    }

    private struct Preview: Codable {
        let scope: Scope
        let checkedAt: Date
        let rows: [Row]
    }

    private struct Index: Codable {
        let owner: Int
        var folders: [SavedCollection]
        var foldersCheckedAt: Date
        var previews: [Preview] = []
    }

    private let file: URL

    init() {
        var root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CivitCollections", isDirectory: true)
        #if DEBUG && targetEnvironment(simulator)
        if let fixture = CollectionListCacheQA.fixture {
            root = root.appendingPathComponent("qa-" + fixture.uuidString, isDirectory: true)
        }
        #endif
        file = root.appendingPathComponent("index-v1.json")
    }

    func folders(owner: Int) -> [SavedCollection]? {
        guard let index = read(owner: owner), fresh(index.foldersCheckedAt) else { return nil }
        return index.folders.filter { $0.isPersonalMedia(actorID: owner) }
    }

    func rows(owner: Int, scope: Scope) -> [Row]? {
        guard let index = read(owner: owner), fresh(index.foldersCheckedAt),
              let preview = index.previews.first(where: { $0.scope == scope }), fresh(preview.checkedAt) else { return nil }
        return preview.rows
    }

    func storeFolders(_ folders: [SavedCollection], owner: Int) {
        let personal = folders.filter { $0.isPersonalMedia(actorID: owner) }
        var index = read(owner: owner) ?? Index(owner: owner, folders: personal, foldersCheckedAt: .now)
        index.folders = personal
        index.foldersCheckedAt = .now
        let ids = Set(personal.map(\.id))
        index.previews.removeAll { !ids.isSuperset(of: $0.scope.folderIDs) || !fresh($0.checkedAt) }
        _ = write(index)
    }

    @discardableResult func storeRows(_ rows: [Row], owner: Int, scope: Scope, verifiedFolders: [SavedCollection]) -> Bool {
        let personal = verifiedFolders.filter { $0.isPersonalMedia(actorID: owner) }
        var index = read(owner: owner) ?? Index(owner: owner, folders: personal, foldersCheckedAt: .now)
        guard Set(index.folders.map(\.id)).isSuperset(of: scope.folderIDs) else { return false }
        let firstRows = Array(rows.prefix(Self.previewLimit))
        if let previous = index.previews.first(where: { $0.scope == scope }),
           Date.now.timeIntervalSince(previous.checkedAt) < 30, previous.rows == firstRows { return true }
        index.previews.removeAll { $0.scope == scope || !fresh($0.checkedAt) }
        if !firstRows.isEmpty {
            index.previews.insert(.init(scope: scope, checkedAt: .now, rows: firstRows), at: 0)
            index.previews = Array(index.previews.prefix(8))
        }
        let written = write(index)
        if !written && firstRows.isEmpty { clear() }
        return written
    }

    func invalidateRows(owner: Int) {
        guard var index = read(owner: owner), !index.previews.isEmpty else { return }
        index.previews = []
        if !write(index) { clear() }
    }

    func clear() { try? FileManager.default.removeItem(at: file) }

    private func fresh(_ date: Date) -> Bool {
        let age = Date.now.timeIntervalSince(date)
        return age >= 0 && age < Self.lifetime
    }

    private func read(owner: Int) -> Index? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: file),
              let index = try? JSONDecoder().decode(Index.self, from: data), index.owner == owner else { return nil }
        return index
    }

    private func write(_ index: Index) -> Bool {
        do {
            let data = try JSONEncoder().encode(index)
            guard data.count <= Self.maximumBytes else { clear(); return false }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
enum CollectionListCacheQA {
    static var fixture: UUID? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-collection-cache-key=") })
            .flatMap { UUID(uuidString: String($0.dropFirst("--qa-collection-cache-key=".count))) }
    }
    static var updatesList: Bool {
        fixture != nil && ProcessInfo.processInfo.arguments.contains("--qa-collection-cache-update")
    }
}
#endif
