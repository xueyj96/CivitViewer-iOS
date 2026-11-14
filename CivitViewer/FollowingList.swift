import Foundation
import Combine

struct FollowingListKey: Hashable {
    let identity: String
    let memberIDs: Set<Int>
    let revision: Int
    init(identity: String, memberIDs: Set<Int>, revision: Int = 0) {
        self.identity = identity; self.memberIDs = memberIDs; self.revision = revision
    }
}

struct FollowingPage: Decodable {
    let items: [Creator]
    let totalItems: Int
    let currentPage: Int
    let pageSize: Int
    let totalPages: Int
}

@MainActor protocol FollowingListSource: AnyObject {
    var followingIdentity: String { get }
    var followingActorID: Int? { get }
    var followingMemberIDs: Set<Int> { get }
    var followingRevision: Int { get }
    func refreshFollowingIDs() async throws -> Set<Int>
    func followingPage(page: Int, limit: Int) async throws -> FollowingPage
}

enum FollowingSort: String, CaseIterable, Identifiable {
    case followed, name
    var id: Self { self }
    var title: String { self == .followed ? "关注顺序" : "名称 A–Z" }
}

enum FollowingListError: LocalizedError {
    case accountChanged, membershipChanged, invalidSnapshotID, invalidPage, changedCounts, unexpectedCreator, duplicateCreator, incomplete
    var errorDescription: String? {
        switch self {
        case .accountChanged: "账号已变更，请重新加载关注列表。"
        case .membershipChanged: "关注关系已变化，请刷新后重新加载。"
        case .invalidSnapshotID: "关注关系包含无效作者 ID，请刷新关注状态后重试。"
        case .invalidPage: "关注列表分页数据无效，可重试当前页。"
        case .changedCounts: "关注列表总数在加载期间发生变化，可重试或刷新。"
        case .unexpectedCreator: "关注列表包含当前关系之外的作者，可重试当前页。"
        case .duplicateCreator: "关注列表分页包含重复作者，可重试当前页。"
        case .incomplete: "关注列表尚未完整加载。"
        }
    }
}

enum FollowingMembership {
    static func eligibleIDs(_ ids: Set<Int>, actorID: Int?) -> Set<Int> {
        Set(ids.filter { $0 != -1 && $0 != actorID })
    }
}

enum FollowingListOrdering {
    static func sort(_ creators: [Creator], by mode: FollowingSort, reverse: Bool = false) -> [Creator] {
        let result: [Creator]
        switch mode {
        case .followed: result = creators
        case .name:
            let locale = Locale(identifier: "en_US_POSIX")
            result = creators.sorted {
                let order = $0.username.compare($1.username, options: [.caseInsensitive, .diacriticInsensitive, .numeric], range: nil, locale: locale)
                if order == .orderedSame { return $0.id < $1.id }
                return order == .orderedAscending
            }
        }
        return reverse ? Array(result.reversed()) : result
    }
}

actor FollowingListCache {
    static let shared = FollowingListCache()
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumBytes = 1024 * 1024
    private static let maximumCreators = 20_000

    private struct Entry: Codable {
        let identity: String
        let memberIDs: [Int]
        let revision: Int
        let checkedAt: Date
        let creators: [Row]
    }

    private struct Row: Codable {
        let id: Int
        let username: String
        var creator: Creator { Creator(id: id, username: username, image: nil) }
        init(_ creator: Creator) { id = creator.id; username = creator.username }
    }

    private let file: URL

    init(file: URL? = nil) {
        if let file {
            self.file = file
        } else {
            self.file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CivitFollowing", isDirectory: true)
                .appendingPathComponent("index-v1.json")
        }
    }

    func creators(for key: FollowingListKey) -> [Creator]? {
        guard let entry = read(), entry.identity == key.identity,
              entry.memberIDs == key.memberIDs.sorted(), entry.revision == key.revision,
              Self.fresh(entry.checkedAt), entry.creators.count <= Self.maximumCreators else { return nil }
        let creators = entry.creators.map(\.creator)
        guard Set(creators.map(\.id)).count == creators.count else { return nil }
        return creators
    }

    func store(_ creators: [Creator], for key: FollowingListKey) {
        guard creators.count <= Self.maximumCreators,
              Set(creators.map(\.id)).count == creators.count else { return }
        let entry = Entry(identity: key.identity, memberIDs: key.memberIDs.sorted(), revision: key.revision,
                          checkedAt: .now, creators: creators.map(Row.init))
        guard let data = try? JSONEncoder().encode(entry), data.count <= Self.maximumBytes else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { }
    }

    private func read() -> Entry? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.creators.count <= Self.maximumCreators, Self.fresh(entry.checkedAt) else { return nil }
        return entry
    }

    private static func fresh(_ date: Date) -> Bool {
        let age = Date.now.timeIntervalSince(date)
        return age >= 0 && age < lifetime
    }
}

@MainActor final class FollowingListStore: ObservableObject {
    @Published private(set) var creators: [Creator] = []
    @Published private(set) var loading = false
    @Published private(set) var complete = false
    @Published private(set) var error: String?
    @Published private(set) var totalItems = 0
    @Published private(set) var nextPage = 1
    @Published private(set) var isStaleSnapshot = false
    @Published private(set) var requestKey: FollowingListKey?

    let pageSize: Int
    let batchPages: Int
    private let cache: FollowingListCache?
    private var eligible = Set<Int>()
    private var requestGeneration = 0
    private var workingCreators: [Creator] = []
    private var workingTotal = 0
    private var workingComplete = false

    init(pageSize: Int = 50, batchPages: Int = 20, cache: FollowingListCache? = nil) {
        self.pageSize = min(max(pageSize, 1), 200)
        self.batchPages = min(max(batchPages, 1), 20)
        self.cache = cache
    }

    func clear() {
        requestGeneration += 1; requestKey = nil; eligible = []; creators = []; loading = false
        complete = false; error = nil; totalItems = 0; nextPage = 1; isStaleSnapshot = false
        workingCreators = []; workingTotal = 0; workingComplete = false
    }

    func ordered(_ mode: FollowingSort, reverse: Bool = false) -> [Creator] {
        guard complete else { return [] }
        return FollowingListOrdering.sort(creators, by: mode, reverse: reverse)
    }

    func reload(key newKey: FollowingListKey, source: FollowingListSource) async {
        guard !Task.isCancelled else { return }
        requestGeneration += 1; let generation = requestGeneration
        let retained = requestKey == newKey && complete ? creators : nil
        requestKey = newKey; eligible = []; error = nil; loading = true
        nextPage = 1; workingCreators = []; workingTotal = 0; workingComplete = false
        complete = false; isStaleSnapshot = false; totalItems = 0
        defer { if generation == requestGeneration { loading = false } }
        do {
            guard source.followingIdentity == newKey.identity else { throw FollowingListError.accountChanged }
            guard source.followingMemberIDs == newKey.memberIDs,
                  source.followingRevision == newKey.revision else { throw FollowingListError.membershipChanged }
            if let retained {
                creators = retained; complete = true; isStaleSnapshot = true; totalItems = retained.count
            } else {
                creators = []
                let cached = await cache?.creators(for: newKey)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                if let cached,
                   source.followingIdentity == newKey.identity,
                   source.followingMemberIDs == newKey.memberIDs,
                   source.followingRevision == newKey.revision {
                    let expected = FollowingMembership.eligibleIDs(newKey.memberIDs, actorID: source.followingActorID)
                    if Set(cached.map(\.id)) == expected, cached.count == expected.count {
                        creators = cached; complete = true; isStaleSnapshot = true; totalItems = cached.count
                    }
                }
            }
            let ids = try await source.refreshFollowingIDs()
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard source.followingIdentity == newKey.identity else {
                creators = []; complete = false; isStaleSnapshot = false; totalItems = 0
                throw FollowingListError.accountChanged
            }
            guard ids == newKey.memberIDs, source.followingMemberIDs == newKey.memberIDs, source.followingRevision == newKey.revision else {
                creators = []; complete = false; isStaleSnapshot = false; totalItems = 0
                throw FollowingListError.membershipChanged
            }
            guard ids.allSatisfy({ $0 > 0 || $0 == -1 || $0 == source.followingActorID }) else { throw FollowingListError.invalidSnapshotID }
            eligible = FollowingMembership.eligibleIDs(ids, actorID: source.followingActorID)
            if eligible.isEmpty {
                creators = []; totalItems = 0; complete = true; isStaleSnapshot = false; workingComplete = true
                await cache?.store([], for: newKey)
                return
            }
            try await loadAllPages(source: source, generation: generation)
        } catch is CancellationError {
            if generation == requestGeneration { error = "加载已取消，可重试当前关注列表。" }
        } catch {
            if generation == requestGeneration { self.error = error.localizedDescription }
        }
    }

    private func loadAllPages(source: FollowingListSource, generation: Int) async throws {
        var pagesInBatch = 0
        while !workingComplete {
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard let key = requestKey, source.followingIdentity == key.identity else { throw FollowingListError.accountChanged }
            guard source.followingMemberIDs == key.memberIDs, source.followingRevision == key.revision else { throw FollowingListError.membershipChanged }
            let response = try await source.followingPage(page: nextPage, limit: pageSize)
            guard generation == requestGeneration else { return }
            try Task.checkCancellation()
            guard source.followingIdentity == key.identity else { throw FollowingListError.accountChanged }
            guard source.followingMemberIDs == key.memberIDs, source.followingRevision == key.revision else { throw FollowingListError.membershipChanged }
            guard response.totalItems >= 0 else { throw FollowingListError.invalidPage }
            let expectedPages = max(1, response.totalItems / pageSize + (response.totalItems % pageSize == 0 ? 0 : 1))
            guard response.currentPage == nextPage, response.pageSize == pageSize,
                  response.totalPages >= 0,
                  response.totalPages == expectedPages,
                  response.items.count <= pageSize,
                  response.items.count == (nextPage < response.totalPages ? pageSize : response.totalItems - (nextPage - 1) * pageSize)
            else { throw FollowingListError.invalidPage }
            let candidateTotal = nextPage == 1 ? response.totalItems : workingTotal
            guard candidateTotal == response.totalItems else { throw FollowingListError.changedCounts }
            let existing = Set(workingCreators.map(\.id))
            guard response.items.allSatisfy({ eligible.contains($0.id) }) else { throw FollowingListError.unexpectedCreator }
            guard Set(response.items.map(\.id)).count == response.items.count,
                  existing.isDisjoint(with: response.items.map(\.id)) else { throw FollowingListError.duplicateCreator }
            let combined = workingCreators + response.items
            let finalPage = nextPage == response.totalPages
            if finalPage {
                guard Set(combined.map(\.id)) == eligible, combined.count == candidateTotal else { throw FollowingListError.incomplete }
            }
            workingCreators = combined
            workingTotal = candidateTotal
            nextPage += 1
            if finalPage {
                creators = combined; totalItems = candidateTotal; complete = true; isStaleSnapshot = false
                workingComplete = true
                await cache?.store(combined, for: key)
                return
            }
            pagesInBatch += 1
            if pagesInBatch >= batchPages { pagesInBatch = 0; await Task.yield() }
        }
    }
}
