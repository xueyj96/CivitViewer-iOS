import Foundation
import WebKit
import Combine

/// Owns the current account and qualifies site responses before updating browsing or account state.
@MainActor
final class SiteSession: NSObject, ObservableObject, PublicationSource, MediaSearchSource, TagDirectorySource, FollowingListSource, TagCandidateSource, TagLibrarySource, TimelineReading {
    struct AccountSessionID: Hashable {
        let accountID: Int
        fileprivate let generation: Int
    }

    var accountSessionID: AccountSessionID? {
        account.map { AccountSessionID(accountID: $0.id, generation: authGeneration) }
    }

    var collectionSessionID: AccountSessionID? {
        hasCollectionAccess ? accountSessionID : nil
    }

    static let origin = "https://civitai.red"
    @Published private(set) var account: Account?
    @Published private(set) var following = Set<Int>()
    @Published private(set) var followingRevision = 0
    @Published private(set) var followsKnown = false
    @Published private(set) var pendingUsers = Set<Int>()
    @Published private(set) var unknownUsers = Set<Int>()
    @Published var message: String?
    @Published var showLogin = false
    @Published private(set) var loginForCollections = false
    @Published private(set) var collections: [SavedCollection] = []
    @Published private(set) var collectionsKnown = false
    @Published private(set) var savedMemberships: [Int: Set<Int>] = [:]
    @Published private(set) var savingFavoriteID: Int?
    @Published private var optimisticBookmark: (imageID: Int, saved: Bool)?
    private var favoriteSaveToken: UUID?
    @Published private(set) var collectionRevision = 0
    @Published private(set) var savedMembershipUpdate: SavedMembershipUpdate?
    private let collectionRead = CollectionRead<[SavedCollection]>()
    private var membershipReadAt: [Int: Date] = [:]
    private var membershipReads: [Int: CollectionRead<Set<Int>>] = [:]
    let oauth: OAuthLogin
    private let webContext: SiteWebContext
    private let requestClient: SiteRequestClient
    var webView: WKWebView { webContext.webView }
    private var authGeneration = 0
    #if DEBUG
    private(set) var tagRPCReads = 0
    private(set) var tagCandidateReads = 0
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private var simulatedBatchFailure = false
    private var simulatedTagPageFailure = false
    private static let simulatesTagDirectoryPagination = CollectionPagingQA.enabled &&
        ProcessInfo.processInfo.arguments.contains("--qa-tag-directory-pagination")
    #endif
    var feedIdentity: String { "\(authGeneration):\(account?.id ?? -1):\(account?.browsingLevel ?? -1)" }
    var tagEvidenceIdentity: String {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { return "local-fixture|\(ProcessInfo.processInfo.processIdentifier)" }
        #endif
        return "\(Self.origin)|\(account?.id ?? -1)|\(account?.browsingLevel ?? -1)"
    }
    var siteRetryAvailableAt: Date? { SiteRequestCooldown.shared.retryAvailableAt }
    var followingIdentity: String { "\(authGeneration):\(account?.id ?? -1):\(account?.username ?? "")" }
    var followingActorID: Int? { account?.id }
    var followingMemberIDs: Set<Int> { following }
    var tagLibraryOwnerID: Int? { account?.id ?? oauth.storedAccountID }
    var tagLibraryIdentity: String { "\(authGeneration):\(tagLibraryOwnerID ?? -1)" }
    var tagLookupIdentity: String { tagLibraryIdentity + "|" + feedIdentity }

    override init() {
        let oauth = OAuthLogin()
        let webContext = SiteWebContext(origin: Self.origin)
        self.oauth = oauth
        self.webContext = webContext
        requestClient = SiteRequestClient(origin: Self.origin, oauth: oauth, web: webContext, cooldown: .shared)
        super.init()
        oauth.onAuthenticated = { [weak self] in
            self?.authGeneration += 1
            self?.clearCollectionState()
            self?.account = nil
            self?.showLogin = false
            await self?.refreshAccount()
        }
    }

    var hasCollectionAccess: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            return !ProcessInfo.processInfo.arguments.contains("--qa-no-collection-access49") && account?.id == CollectionPagingQA.ownerID
        }
        #endif
        return account != nil && oauth.hasCollectionAccess
    }
    #if DEBUG && targetEnvironment(simulator)
    func configureForCollectionPagingQA() {
        guard CollectionPagingQA.enabled else { return }
        if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") {
            UserDefaults.standard.set(false, forKey: "tagDirectory.showCatalog57")
        }
        account = Account(id: CollectionPagingQA.ownerID, username: "PagingFixture", browsingLevel: 1,
                          blurNsfw: ProcessInfo.processInfo.arguments.contains("--qa-image-failure55"))
        if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") || ProcessInfo.processInfo.arguments.contains("--qa-style48") {
            let special = ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55")
            let policy = TagAvailabilityPolicy(blockedTags: TagBlocklist.shared.names, blockedAuthorIDs: AuthorBlocklist.shared.blockedIDs,
                blockedAuthorHandles: AuthorBlocklist.shared.blockedHandles, deduplicateMediaAssets: UserDefaults.standard.object(forKey: "deduplicateMedia") as? Bool ?? true)
            for tag in 42_001...42_018 where !special || ![42_002,42_003].contains(tag) {
                let items = (0..<3).map { offset in
                    MediaItem(id: tag * 10 + offset, url: "https://example.invalid/local-fixture/\(tag)/\(offset)", width: 1, height: 1,
                              type: "image", username: "LocalFixture", browsingLevel: 1, thumbnail: nil, tags: [.init(id: tag, name: "fixture")])
                }
                TagObservationStore.shared.observe(items: items, scope: tagEvidenceIdentity, policy: policy)
            }
            if special { TagObservationStore.shared.recordEmpty(tagID: 42_002, scope: tagEvidenceIdentity, policy: policy) }
        }
        collectionsKnown = CollectionListCacheQA.fixture == nil
        collections = collectionsKnown ? CollectionPagingQA.collections : []
        if VisualControlsQA.enabled {
            following = []; followsKnown = true; savedMemberships = [:]
            if ProcessInfo.processInfo.arguments.contains("--qa-favorite-save69-start-saved") {
                savedMemberships[28_037_100] = [CollectionPagingQA.collection.id]
            }
            if VisualControlsQA.state == "busy" { pendingUsers = [VisualControlsQA.creatorID] }
            if VisualControlsQA.state == "unknown" { unknownUsers = [VisualControlsQA.creatorID] }
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") {
            for item in CollectionPagingQA.items {
                savedMemberships[item.id] = [CollectionPagingQA.collection.id]
            }
            if let second = collections.dropFirst().first {
                savedMemberships[28_037_100, default: []].insert(second.id)
            }
        }
        if ViewportAuditQA.enabled { following = [CollectionPagingQA.ownerID]; followsKnown = true }
    }
    #endif
    var defaultCollectionIDs: Set<Int> {
        guard let actorID = account?.id else { return [] }
        let available = Set(collections.map(\.id))
        let remembered = Set(UserDefaults.standard.array(forKey: "favoriteFolders.\(actorID)") as? [Int] ?? []).intersection(available)
        if !remembered.isEmpty { return remembered }
        if let folder = collections.first(where: { $0.name == "收藏作品" && $0.read == "Private" }) ?? collections.first(where: { $0.read == "Private" }) { return [folder.id] }
        return []
    }
    func rememberCollectionSelection(_ ids: Set<Int>) {
        guard let actorID = account?.id, !ids.isEmpty else { return }
        UserDefaults.standard.set(ids.sorted(), forKey: "favoriteFolders.\(actorID)")
    }

    func openLogin(forCollections: Bool = false) {
        loginForCollections = forCollections || oauth.hasCollectionAccess
        showLogin = true
    }

    func refreshAccount() async {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return }
        if ResumePromptQA.enabled { return }
        #endif
        let generation = authGeneration
        guard oauth.hasCredentials else { account = nil; following = []; followsKnown = false; clearCollectionState(); return }
        do {
            let value: Account? = try await request(path: "/api/auth/session", response: .identity)
            guard generation == authGeneration, oauth.hasCredentials else { return }
            if account?.id != value?.id { following = []; followsKnown = false; unknownUsers = []; clearCollectionState() }
            account = value
            if let value { try? oauth.bindAccountIdentity(value.id) }
            if value != nil { try await refreshFollowing() }
            else { following = []; followsKnown = false }
        } catch ClientError.signedOut {
            guard generation == authGeneration else { return }
            account = nil; following = []; followsKnown = false; message = ClientError.signedOut.localizedDescription
        } catch { message = error.localizedDescription }
    }

    func refreshFollowing() async throws {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return }
        #endif
        guard let actorID = account?.id else { throw ClientError.signedOut }
        let generation = authGeneration
        do {
            let ids: [Int] = try await rpc("user.getFollowingUsers")
            guard generation == authGeneration, account?.id == actorID, oauth.hasCredentials else { throw ClientError.accountChanged }
            let confirmed = Set(ids)
            if confirmed != following { followingRevision += 1 }
            following = confirmed; followsKnown = true; unknownUsers = []
        } catch ClientError.signedOut {
            guard generation == authGeneration, account?.id == actorID else { throw ClientError.accountChanged }
            account = nil; following = []; followsKnown = false
            throw ClientError.signedOut
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func configureForResumePromptQA() {
        guard ResumePromptQA.enabled else { return }
        account = Account(id: ResumePromptQA.ownerID, username: "NativeResumePattern", browsingLevel: 1, blurNsfw: false)
        following = ResumePromptQA.scenario.contains("following") ? [ResumePromptQA.ownerID] : []
        followsKnown = true; authGeneration = 29_001
    }
    #endif

    func refreshFollowingIDs() async throws -> Set<Int> {
        let identity = followingIdentity
        try await refreshFollowing()
        guard identity == followingIdentity else { throw ClientError.accountChanged }
        return following
    }

    func followingPage(page: Int, limit: Int) async throws -> FollowingPage {
        guard let actor = account, !actor.username.isEmpty else { throw ClientError.signedOut }
        guard page > 0, (1...200).contains(limit) else { throw ClientError.invalidResponse }
        let identity = followingIdentity
        let result: FollowingPage = try await rpc("user.getList", input: ["username": actor.username, "type": "following", "page": page, "limit": limit])
        guard identity == followingIdentity, oauth.hasCredentials else { throw ClientError.accountChanged }
        return result
    }

    func setFollowing(_ desired: Bool, creator: Creator) async {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled {
            guard account?.id == CollectionPagingQA.ownerID, creator.id == VisualControlsQA.creatorID else { return }
            if desired { following.insert(creator.id) } else { following.remove(creator.id) }
            return // Controlled in-memory interaction; never issue a site write.
        }
        #endif
        guard let actorID = account?.id else { message = ClientError.signedOut.localizedDescription; return }
        guard pendingUsers.isEmpty else { return }
        pendingUsers.insert(creator.id)
        defer { pendingUsers.remove(creator.id) }
        // This is a toggle API: always read before deciding to issue ONE mutation.
        do {
            let identity: Account? = try await request(path: "/api/auth/session", response: .identity)
            guard identity?.id == actorID else {
                account = identity; following = []; followsKnown = false
                throw ClientError.accountChanged
            }
            try await refreshFollowing()
            guard following.contains(creator.id) != desired else { return }
            guard account?.id == actorID && !showLogin else { throw ClientError.accountChanged }
        } catch { message = error.localizedDescription; return }
        do {
            let _: FollowResult = try await rpc("user.toggleFollow", input: ["targetUserId": creator.id, "username": creator.username], mutation: true)
            try await refreshFollowing()
            if following.contains(creator.id) != desired {
                unknownUsers.insert(creator.id); message = ClientError.writeUnknown.localizedDescription
            }
        } catch {
            // A timeout may have happened after the write. Read back, never auto-toggle again.
            do {
                try await refreshFollowing()
                if following.contains(creator.id) != desired {
                    unknownUsers.insert(creator.id); message = ClientError.writeUnknown.localizedDescription
                }
            } catch {
                unknownUsers.insert(creator.id); message = ClientError.writeUnknown.localizedDescription
            }
        }
    }

    func mediaPage(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool = false, includeTags: Bool = false) async throws -> MediaPage {
        #if DEBUG && targetEnvironment(simulator)
        if AutoContinuationQA.enabled { return try await AutoContinuationQA.page(filter: filter, cursor: cursor) }
        if ViewportAuditQA.enabled { return ViewportAuditQA.page(filter: filter, cursor: cursor, creator: creator) }
        if CollectionPagingQA.enabled {
            return MediaPage(items: cursor == nil ? CollectionPagingQA.items.filter { filter.effectiveKind == .all || $0.isVideo == (filter.effectiveKind == .video) } : [], metadata: .init(nextCursor: nil))
        }
        if ResumePromptQA.enabled {
            ResumePromptQA.recordPageRequest(filter: filter, cursor: cursor, creator: creator, followed: followed)
            if ResumePromptQA.scenario == "restart-presentation" {
                if cursor == nil { return MediaPage(items: ResumePromptQA.items, metadata: .init(nextCursor: "qa-next")) }
                var next = MediaItem(id: ResumePromptQA.itemIDs[3], url: "https://example.invalid/extra-paging-image.png", width: 192, height: 256,
                                 type: "image", username: "NativeResumePattern", browsingLevel: 1, thumbnail: nil, creatorID: ResumePromptQA.ownerID, tags: [])
                next.offlineMediaURL = ResumePromptQA.imageURL(for: next.id)
                return MediaPage(items: [next], metadata: .init(nextCursor: nil))
            }
            if ResumePromptQA.scenario.hasPrefix("restart-short-"), cursor != nil { throw ClientError.http(503) }
            if ResumePromptQA.manualUI, ResumePromptQA.scenario == "restore-stale-cursor", cursor != nil {
                throw ClientError.http(503)
            }
            if ResumePromptQA.manualUI, ResumePromptQA.scenario == "restore-legacy-nil-then-restart-failure", cursor == nil {
                throw ClientError.http(503)
            }
            return MediaPage(items: ResumePromptQA.items, metadata: .init(nextCursor: nil))
        }
        #endif
        if followed { return try await followingPage(filter: filter, cursor: cursor, includeTags: includeTags) }
        var components = URLComponents(string: Self.origin + "/api/v1/images")!
        components.queryItems = filter.query(cursor: cursor, creator: creator)
        if includeTags { components.queryItems?.append(.init(name: "withTags", value: "true")) }
        if !filter.onlyPG, let level = account?.browsingLevel {
            components.queryItems?.append(.init(name: "browsingLevel", value: String(level)))
        }
        let path = components.url!.path + "?" + (components.percentEncodedQuery ?? "")
        return try await request(path: path, preferPublicREST: true)
    }

    private func followingPage(filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        guard account != nil else { throw ClientError.signedOut }
        if !followsKnown { try await refreshFollowing() }
        // The website's old DB route can fall back to a global feed for zero follows.
        // Refuse that meaning: an empty following set is an empty following feed.
        guard !following.isEmpty else { return MediaPage(items: [], metadata: .init(nextCursor: nil)) }
        var input: [String: Any] = ["followed": true, "limit": 20, "sort": filter.sort,
                                    "period": filter.period, "include": [String]()]
        if let cursor { input["cursor"] = cursor }
        if filter.effectiveKind != .all { input["types"] = [filter.effectiveKind.rawValue] }
        if !filter.baseModel.isEmpty { input["baseModels"] = [filter.baseModel] }
        input["browsingLevel"] = filter.onlyPG ? 1 : (account?.browsingLevel ?? 1)
        let identity = feedIdentity
        let page: FollowingIndexPage = try await rpc("image.getInfinite", input: input)
        guard identity == feedIdentity else { throw ClientError.accountChanged }
        let scoped = page.items.filter { following.contains($0.user.id) }
        guard !scoped.isEmpty else { return MediaPage(items: [], metadata: .init(nextCursor: page.nextCursor)) }
        // One batched hydration gives us the site's real media URLs and safe video
        // thumbnails. It is not one request per creator or per media item.
        let media = try await hydrateMedia(ids: scoped.map(\.id), browsingLevel: filter.onlyPG ? 1 : (account?.browsingLevel ?? 1),
                                           includeTags: includeTags)
        guard identity == feedIdentity else { throw ClientError.accountChanged }
        let byID = Dictionary(media.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = scoped.compactMap { row -> MediaItem? in
            guard var item = byID[row.id] else { return nil }
            item.creatorID = row.user.id
            if let metadata = row.metadata { item.metadata = metadata }
            return item
        }
        return MediaPage(items: ordered, metadata: .init(nextCursor: page.nextCursor))
    }

    /// `postIds` with original IDs selects the official narrow DB route, whose
    /// technical metadata includes duration. IDs alone can use an index without it.
    func videoDurationMetadata(ids: [Int], postIDs: [Int], onlyPG: Bool) async throws -> [VideoDurationRecord] {
        guard !ids.isEmpty, ids.count <= 20, Set(ids).count == ids.count,
              ids.allSatisfy({ $0 > 0 }), !postIDs.isEmpty, postIDs.count <= ids.count,
              Set(postIDs).count == postIDs.count, postIDs.allSatisfy({ $0 > 0 }) else {
            throw ClientError.format("视频时长范围")
        }
        let identity = feedIdentity
        let result: VideoDurationMetadataPage = try await rpc("image.getInfinite", input: [
            "ids": ids, "postIds": postIDs, "types": ["video"], "limit": ids.count,
            "browsingLevel": onlyPG ? 1 : (account?.browsingLevel ?? 1), "include": [String]()
        ])
        guard identity == feedIdentity else { throw ClientError.accountChanged }
        return result.items.filter { ids.contains($0.id) }
    }

    func creator(username: String) async throws -> Creator {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { return Creator(id: VisualControlsQA.enabled ? VisualControlsQA.creatorID : CollectionPagingQA.ownerID, username: username) }
        #endif
        var components = URLComponents(string: Self.origin + "/api/v1/users")!
        components.queryItems = [.init(name: "query", value: username)]
        let response: UserPage = try await request(path: components.url!.path + "?" + (components.percentEncodedQuery ?? ""))
        guard let creator = response.items.first(where: { $0.username.lowercased() == username.lowercased() }) else { throw ClientError.missingCreator }
        return creator
    }

    func creatorBiography(_ creator: Creator) async throws -> CreatorBiography {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            let variant = CollectionPagingQA.biographyCase ?? "english"
            return CreatorBiography(id: creator.id, username: creator.username, profile: .init(bio: CollectionPagingQAView.biography(variant)), blockedByThem: false)
        }
        #endif
        let identity = feedIdentity
        let result: CreatorBiography = try await rpc("userProfile.get", input: ["username": creator.username])
        guard identity == feedIdentity, result.id == creator.id else { throw ClientError.accountChanged }
        return result
    }

    func creators(ids: [Int]) async throws -> [Creator] {
        guard !ids.isEmpty else { return [] }
        var components = URLComponents(string: Self.origin + "/api/v1/users")!
        components.queryItems = [.init(name: "ids", value: ids.map(String.init).joined(separator: ","))]
        let page: UserPage = try await request(path: components.url!.path + "?" + (components.percentEncodedQuery ?? ""))
        return page.items
    }

    func leaderboard(_ board: Board) async throws -> [LeaderboardEntry] {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            if ProcessInfo.processInfo.arguments.contains("--qa-author-activity58") {
                let base = board == .legacy ? 58_000 : 59_000
                return (1...1_000).map { index in
                    LeaderboardEntry(position: index, user: Creator(id: base + index, username: "Pattern Creator \(index)"))
                }
            }
            let firstRank = ProcessInfo.processInfo.arguments.contains("--qa-leaderboard-three-digits") ? 108 : 1
            return (0..<8).map { index in
                LeaderboardEntry(position: firstRank + index, user: Creator(id: CollectionPagingQA.ownerID + index, username: "Pattern Creator \(index + 1)"))
            }
        }
        #endif
        return try await rpc(board.procedure, input: ["id": "images-nsfw"])
    }

    func latestPublication(creator: Creator) async throws -> PublicationResult {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-author-activity58") {
            try await Task.sleep(for: .milliseconds(300))
            return .published(Date().addingTimeInterval(creator.id.isMultiple(of: 4) ? -3_600 : -259_200))
        }
        #endif
        let identity = feedIdentity
        var cursor: PublicationCursor?
        var scan = PublicationScan(creatorID: creator.id)
        for _ in 0..<4 {
            try Task.checkCancellation()
            var input: [String: Any] = ["username": creator.username, "sort": "Newest", "period": "AllTime", "limit": 5,
                                        "browsingLevel": account?.browsingLevel ?? 1, "include": [String](), "draftOnly": false, "scheduled": false]
            if let cursor { input["cursor"] = cursor.value }
            let page: PublicationPage = try await rpc("post.getInfinite", input: input)
            guard identity == feedIdentity else { throw ClientError.accountChanged }
            if let result = scan.consume(page) { return result }
            cursor = page.nextCursor
        }
        return .unverified // Bounded or incomplete scanning is never a negative result.
    }

    func mediaItem(id: Int, includeTags: Bool = true) async throws -> MediaItem? {
        try await mediaItems(ids: [id], includeTags: includeTags).first
    }

    func mediaItems(ids: [Int], includeTags: Bool = true) async throws -> [MediaItem] {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.detailsTagsEnabled {
            if ProcessInfo.processInfo.arguments.contains("--qa-details-tags-failure") { throw ClientError.invalidResponse }
            return CollectionPagingQA.items.filter { ids.contains($0.id) }
        }
        if ViewportAuditQA.enabled { return ViewportAuditQA.mediaItems(ids: ids) }
        if ResumePromptQA.enabled {
            if ResumePromptQA.scenario == "restore-failure" {
                return ResumePromptQA.fixtureItems(for: ids.filter { $0 != ResumePromptQA.itemIDs[2] })
            }
            return ResumePromptQA.fixtureItems(for: ids)
        }
        #endif
        guard !ids.isEmpty, ids.count <= 30 else { return [] }
        let page = try await hydrateMedia(ids: ids, browsingLevel: account?.browsingLevel ?? 1, includeTags: includeTags)
        guard page.items.allSatisfy({ ids.contains($0.id) }) else { throw ClientError.invalidResponse }
        return page.items
    }

    private func hydrateMedia(ids: [Int], browsingLevel: Int, includeTags: Bool) async throws -> MediaPage {
        var components = URLComponents()
        components.path = "/api/v1/images"
        var query = [
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(ids.count)),
            URLQueryItem(name: "browsingLevel", value: String(browsingLevel))
        ]
        if includeTags { query.append(.init(name: "withTags", value: "true")) }
        components.queryItems = query
        guard let path = components.string else { throw ClientError.invalidResponse }
        return try await request(path: path)
    }

    func searchAuthors(keyword: String, excluding: [Int] = []) async throws -> [Creator] {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled {
            if keyword == "pagedfixture" {
                if excluding.isEmpty { try await Task.sleep(for: .seconds(2)) }
                let excluded = Set(excluding)
                return (1...25).map { Creator(id: 29_000_000 + $0, username: "PagedFixture\($0)") }
                    .filter { !excluded.contains($0.id) }
                    .prefix(SearchLookupStore.authorPageSize).map { $0 }
            }
            let creator = Creator(id: CollectionPagingQA.ownerID, username: "PagingFixture")
            return creator.username.localizedCaseInsensitiveContains(MediaSearchText.normalized(keyword)) ? [creator] : []
        }
        #endif
        guard MediaSearchText.valid(keyword, mode: .author) else { throw ClientError.format("作者关键词") }
        var input: [String: Any] = ["query": MediaSearchText.normalized(keyword),
                                    "limit": SearchLookupStore.authorPageSize, "include": [String]()]
        if !excluding.isEmpty { input["excludedUserIds"] = excluding }
        return try await rpc("user.getAll", input: input)
    }

    func searchTags(keyword: String, page: Int) async throws -> [SearchTag] {
        guard MediaSearchText.valid(keyword, mode: .tag), page > 0 else { throw ClientError.format("标签关键词") }
        return try await LocalTagLibrary.shared.legacyPage(ownerID: tagLibraryOwnerID, keyword: keyword, page: page)
    }

    func commonTags() async throws -> [SearchTag] {
        try await LocalTagLibrary.shared.legacyPage(ownerID: tagLibraryOwnerID, keyword: "", page: 1, common: true)
    }
    func catalogTags(keyword: String, page: Int) async throws -> [SearchTag] {
        guard page > 0, keyword.isEmpty || MediaSearchText.valid(keyword, mode: .tag) else { throw ClientError.format("标签目录查询") }
        return try await LocalTagLibrary.shared.legacyPage(ownerID: tagLibraryOwnerID, keyword: keyword, page: page)
    }
    func directoryPage(mode: TagDirectoryMode, keyword: String, cursor: TagDirectoryCursor?) async throws -> TagDirectoryPage {
        #if DEBUG && targetEnvironment(simulator)
        if Self.simulatesTagDirectoryPagination { return .init(items: [], next: nil) }
        if CollectionPagingQA.enabled && (ProcessInfo.processInfo.arguments.contains("--qa-style48") || ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55")) {
            let normalized = TagPolicy.normalize(keyword)
            let tags = CollectionPagingQA.neutralDetailsTags.compactMap { value -> SearchTag? in
                guard let id = value.id, let name = value.name,
                      normalized.isEmpty || TagPolicy.normalize(name).contains(normalized) else { return nil }
                return SearchTag(id: id, name: name)
            }
            return .init(items: cursor == nil ? tags : [], next: nil)
        }
        #endif
        let result = try await LocalTagLibrary.shared.page(ownerID: tagLibraryOwnerID, keyword: keyword, common: mode == .common, cursor: cursor?.local, limit: mode == .common ? 200 : 20)
        return .init(items: result.items, next: result.next.map { .init(page: (cursor?.page ?? 1) + 1, local: $0) })
    }
    func onlineTagPage(mode: TagDirectoryMode, keyword: String, page: Int) async throws -> [SearchTag]? {
        #if DEBUG && targetEnvironment(simulator)
        if Self.simulatesTagDirectoryPagination {
            guard mode == .catalog, keyword.isEmpty else { return [] }
            if page == 2 && !simulatedTagPageFailure {
                simulatedTagPageFailure = true
                throw URLError(.timedOut)
            }
            let rows: Range<Int>
            switch page {
            case 1: rows = 1..<21
            case 2: rows = 21..<41
            case 3: rows = 41..<44
            default: return []
            }
            return rows.map { index in
                let name = index == 43
                    ? "paging fixture 43 with an unusually long tag name for narrow layouts"
                    : String(format: "paging fixture %02d", index)
                return SearchTag(id: 43_000 + index, name: name)
            }
        }
        if CollectionPagingQA.enabled && (ProcessInfo.processInfo.arguments.contains("--qa-style48") || ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55")) {
            if mode == .common && keyword.isEmpty {
                return CollectionPagingQA.neutralDetailsTags.compactMap { value in
                    guard let id = value.id, let name = value.name else { return nil }
                    return SearchTag(id: id, name: name)
                }
            }
            return []
        }
        #endif
        guard page > 0, keyword.isEmpty || MediaSearchText.valid(keyword, mode: .tag) else { throw ClientError.format("标签查询") }
        let identity = tagLookupIdentity
        let result: [SearchTag]
        if mode == .common && keyword.isEmpty { result = try await remoteCommonTags() }
        else {
            struct TagPage: Decodable { let items: [SearchTag] }
            let response: TagPage = try await rpc("tag.getAll", input: TagCatalogQuery.input(keyword: keyword, page: page))
            result = response.items
        }
        guard identity == tagLookupIdentity else { throw ClientError.accountChanged }
        return result
    }
    func rememberTags(_ tags: [SearchTag], common: Bool, identity: String) async throws {
        #if DEBUG && targetEnvironment(simulator)
        if Self.simulatesTagDirectoryPagination { return }
        #endif
        guard identity == tagLookupIdentity, !Task.isCancelled else { throw ClientError.accountChanged }
        try await LocalTagLibrary.shared.rememberDiscovered(ownerID: tagLibraryOwnerID, tags: tags, common: common)
        guard identity == tagLookupIdentity else { throw ClientError.accountChanged }
    }
    func remoteTagPage(prefix: String, page: Int, limit: Int) async throws -> [SearchTag] {
        guard MediaSearchText.valid(prefix, mode: .tag), page > 0, (1...200).contains(limit) else { throw LocalTagError.invalidPage }
        struct TagPage: Decodable { let items: [SearchTag] }
        var input = TagCatalogQuery.input(keyword: prefix, page: page); input["limit"] = limit
        let result: TagPage = try await rpc("tag.getAll", input: input)
        return result.items
    }
    func remoteCommonTags() async throws -> [SearchTag] { try await rpc("tag.getFeedTagBar") }
    func exactTag(name: String) async throws -> SearchTag? {
        let name = MediaSearchText.normalized(name)
        guard !name.isEmpty else { throw ClientError.invalidResponse }
        let tags: [SearchTag] = try await rpc("tag.getTagWithModelCount", input: ["name": name])
        return tags.first { $0.id > 0 && TagPolicy.normalize($0.name) == TagPolicy.normalize(name) }
    }

    func searchTitlePosts(keyword: String, filter: FeedFilter, cursor: PublicationCursor?) async throws -> SearchPostPage {
        guard MediaSearchText.valid(keyword, mode: .title) else { throw ClientError.format("标题关键词") }
        var input: [String: Any] = ["query": MediaSearchText.normalized(keyword), "limit": 5, "sort": filter.sort, "period": filter.period,
                                   "include": [String](), "draftOnly": false, "scheduled": false,
                                   "browsingLevel": filter.onlyPG ? 1 : (account?.browsingLevel ?? 1)]
        if let cursor { input["cursor"] = cursor.value }
        return try await rpc("post.getInfinite", input: input)
    }

    func searchPostMedia(postID: Int, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        guard postID > 0 else { throw ClientError.invalidResponse }
        return try await scopedSearchMedia(filter: filter, cursor: cursor, extra: [.init(name: "postId", value: String(postID))], includeTags: includeTags)
    }

    func searchMediaPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-tag-empty-result56") {
            return .init(items: [], metadata: .init(nextCursor: nil))
        }
        if ViewportAuditQA.enabled { return try ViewportAuditQA.searchPage(target: target, filter: filter, cursor: cursor) }
        #endif
        switch target {
        case .author(let creator):
            let page = try await mediaPage(filter: filter, cursor: cursor, creator: creator, includeTags: includeTags)
            guard page.items.allSatisfy({ $0.username?.lowercased() == creator.username.lowercased() }) else { throw ClientError.format("作者搜索返回范围不符") }
            return page
        case .tag(let tag):
            guard tag.id > 0 else { throw ClientError.invalidResponse }
            let page = try await scopedSearchMedia(filter: filter, cursor: cursor, extra: [.init(name: "tags", value: String(tag.id))], includeTags: true)
            guard page.items.allSatisfy({ $0.tags?.contains(where: { $0.id == tag.id }) == true }) else { throw ClientError.format("标签搜索返回范围待核实") }
            return page
        case .title(let keyword):
            return try await TitleMediaPager.page(keyword: keyword, filter: filter, cursor: cursor, includeTags: includeTags, source: self)
        case .combined(let criteria):
            guard criteria.valid else { throw ClientError.format("请至少选择一个有效搜索条件") }
            if !criteria.normalizedText.isEmpty {
                return try await TitleMediaPager.page(keyword: criteria.normalizedText, filter: filter, cursor: cursor, includeTags: true, source: self, criteria: criteria)
            }
            if criteria.tags.count > 1 {
                return try await TagConjunctionPager.page(criteria: criteria, filter: filter, cursor: cursor, source: self)
            }
            let firstTag = criteria.tags.sorted { $0.id < $1.id }.first
            let extra: [URLQueryItem] = firstTag.map { [.init(name: "tags", value: String($0.id))] } ?? []
            let page = try await scopedSearchMedia(filter: filter, cursor: cursor, extra: extra, includeTags: true, creator: criteria.author)
            if let author = criteria.author {
                guard page.items.allSatisfy({ $0.username?.lowercased() == author.username.lowercased() }) else { throw ClientError.format("作者搜索返回范围不符") }
            }
            if let firstTag {
                guard page.items.allSatisfy({ $0.tags?.contains(where: { $0.id == firstTag.id }) == true }) else { throw ClientError.format("标签搜索返回范围待核实") }
            }
            return .init(items: try page.items.filter { try criteria.matches($0) }, metadata: page.metadata)
        }
    }

    func tagCandidates(tagID: Int, author: Creator?, filter: FeedFilter, cursor: String?, limit: Int) async throws -> MediaPage {
        guard tagID > 0, (1...100).contains(limit) else { throw ClientError.invalidResponse }
        #if DEBUG
        tagCandidateReads += 1
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled && (ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") || ProcessInfo.processInfo.arguments.contains("--qa-style48")) {
            if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55"), tagID == 42_002 { return .init(items: [], metadata: .init(nextCursor: nil)) }
            if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55"), tagID == 42_003 { throw URLError(.timedOut) }
            let items = (0..<3).map { offset in
                MediaItem(id: 55_100 + offset, url: "https://example.invalid/tag-fixture/\(tagID)/\(offset)", width: 1, height: 1, type: offset == 0 ? "video" : "image",
                          username: "LocalFixture", browsingLevel: 1, thumbnail: nil, tags: [.init(id: tagID, name: "fixture")])
            }
            return .init(items: items, metadata: .init(nextCursor: nil))
        }
        #endif
        return try await scopedSearchMedia(filter: filter, cursor: cursor, extra: [.init(name: "tags", value: String(tagID))], includeTags: true, creator: author, limit: limit, recordTagRequest: false)
    }

    private func scopedSearchMedia(filter: FeedFilter, cursor: String?, extra: [URLQueryItem], includeTags: Bool, creator: Creator? = nil, limit: Int = 20, recordTagRequest: Bool = true) async throws -> MediaPage {
        var components = URLComponents(string: "/api/v1/images")!
        components.queryItems = filter.query(cursor: cursor, creator: creator) + extra
        components.queryItems?.removeAll { $0.name == "limit" }
        components.queryItems?.append(.init(name: "limit", value: String(limit)))
        if includeTags { components.queryItems?.append(.init(name: "withTags", value: "true")) }
        if !filter.onlyPG { components.queryItems?.append(.init(name: "browsingLevel", value: String(account?.browsingLevel ?? 1))) }
        let ids = Set(extra.filter { $0.name == "tags" }.flatMap { ($0.value ?? "").split(separator: ",").compactMap { Int($0) } })
        func note(_ page: MediaPage?, error: Error? = nil) {
            guard recordTagRequest, !ids.isEmpty else { return }
            let status: Int? = if case ClientError.http(let value)? = error { value } else { nil }
            let matched = page.map { p in p.items.filter { ids.isSubset(of: Set(($0.tags ?? []).compactMap(\.id))) }.count }
            let context = TagSearchDiagnostic(stage: "upstream", tagIDs: ids.sorted(), outcome: error == nil ? "page" : "error",
                reason: error == nil ? (matched == page?.items.count ? "response" : "tagMismatch") : (status == nil ? "requestFailed" : "http"),
                rawCount: page?.items.count ?? 0, visibleCount: nil, pages: 1, hasMore: page?.metadata.nextCursor != nil,
                browsingLevel: filter.onlyPG ? 1 : (account?.browsingLevel ?? 1), kind: filter.effectiveKind.rawValue, period: filter.period,
                hasAuthor: creator != nil, hasText: false, blockedTags: TagBlocklist.shared.names.count, blockedAuthors: AuthorBlocklist.shared.blockedIDs.count,
                matchedCount: matched)
            LocalDiagnosticsStore.shared.note(area: .search, code: .tagSearch, httpStatus: status, tagSearch: context)
        }
        do {
            let page: MediaPage = try await request(path: components.string!)
            note(page)
            return page
        } catch {
            if !Task.isCancelled { note(nil, error: error) }
            throw error
        }
    }

    private func readVerifiedAccount(for expectedSession: AccountSessionID) async throws -> Account {
        guard accountSessionID == expectedSession, oauth.hasCredentials else { throw ClientError.accountChanged }
        let verified: Account? = try await request(path: "/api/auth/session", response: .identity)
        guard let verified, verified.id == expectedSession.accountID,
              accountSessionID == expectedSession, oauth.hasCredentials else { throw ClientError.accountChanged }
        return verified
    }

    func saveBrowsingPreferences(level: Int, blur: Bool?, for expectedSession: AccountSessionID) async {
        guard accountSessionID == expectedSession, (0...31).contains(level) else { return }
        var input: [String: Any] = ["browsingLevel": level]
        if let blur { input["blurNsfw"] = blur }
        do {
            _ = try await readVerifiedAccount(for: expectedSession)
            try Task.checkCancellation()
            do { let _: Bool? = try await rpc("user.updateBrowsingMode", input: input, mutation: true) }
            catch {
                // Do not repeat an ambiguous write. Continue with a server readback.
            }
            let updated = try await readVerifiedAccount(for: expectedSession)
            account = updated
            if updated.browsingLevel == level, blur == nil || updated.blurNsfw == blur {
                message = "账号偏好已读回确认。"
            } else {
                message = "服务器尚未确认这组偏好，保留当前读回值。"
            }
        } catch {
            if !Task.isCancelled, accountSessionID == expectedSession { message = error.localizedDescription }
        }
    }

    private func clearCollectionState() {
        favoriteSaveToken = nil; savingFavoriteID = nil
        optimisticBookmark = nil
        collectionRead.invalidate()
        for read in membershipReads.values { read.invalidate() }
        collections = []; collectionsKnown = false; savedMemberships = [:]
        membershipReadAt = [:]; membershipReads = [:]
        collectionRevision += 1
    }

    func refreshCollections() async throws {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            if CollectionListCacheQA.fixture != nil, !collectionsKnown {
                _ = try await collectionRead.task(load: {
                    try await Task.sleep(for: .milliseconds(1_400))
                    return CollectionPagingQA.collections
                }, commit: { folders in self.collections = folders; self.collectionsKnown = true }).value
            }
            return
        }
        #endif
        guard let actorID = account?.id else { throw ClientError.signedOut }
        guard hasCollectionAccess else { throw ClientError.collectionAuthorization }
        let generation = authGeneration
        _ = try await collectionRead.task(load: {
            let values: [SavedCollection] = try await self.rpc("collection.getAllUser", input: ["type": "Image", "contributingOnly": true])
            guard generation == self.authGeneration, self.account?.id == actorID, self.hasCollectionAccess else { throw ClientError.accountChanged }
            return values.filter { $0.isPersonalMedia(actorID: actorID) }.sorted {
                if ($0.mode == "Bookmark") != ($1.mode == "Bookmark") { return $0.mode == "Bookmark" }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }, commit: { values in self.collections = values; self.collectionsKnown = true }).value
        guard generation == authGeneration, account?.id == actorID, hasCollectionAccess else { throw ClientError.accountChanged }
    }

    @discardableResult
    func refreshSavedMembership(_ imageID: Int, force: Bool = false) async throws -> Set<Int> {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled { return savedMemberships[imageID] ?? [] }
        if CollectionPagingQA.enabled {
            return savedMemberships[imageID] ?? []
        }
        #endif
        guard let actorID = account?.id, hasCollectionAccess else { throw ClientError.collectionAuthorization }
        if !force, let date = membershipReadAt[imageID], Date().timeIntervalSince(date) < 60,
           let known = savedMemberships[imageID] { return known }
        if !collectionsKnown { try await refreshCollections() }
        let generation = authGeneration
        let read = membershipReads[imageID] ?? CollectionRead<Set<Int>>()
        membershipReads[imageID] = read
        let ids = try await read.task(load: {
            let rows: [CollectionMembership] = try await self.rpc("collection.getUserCollectionItemsByItem", input: ["imageId": imageID, "type": "Image"])
            guard generation == self.authGeneration, self.account?.id == actorID, self.hasCollectionAccess else { throw ClientError.accountChanged }
            return Set(rows.map(\.collectionId)).intersection(Set(self.collections.map(\.id)))
        }, commit: { ids in self.savedMemberships[imageID] = ids; self.membershipReadAt[imageID] = Date() }).value
        guard generation == authGeneration, account?.id == actorID, hasCollectionAccess else { throw ClientError.accountChanged }
        return ids
    }

    private func invalidateMembershipRead(_ imageID: Int) {
        membershipReads[imageID]?.invalidate()
        membershipReadAt[imageID] = nil
    }

    /// Cleanup must also preserve references in shared/contest folders that the
    /// personal-folder picker intentionally does not offer for writes.
    func allSavedMembership(_ imageID: Int) async throws -> Set<Int> {
        guard let actorID = account?.id, hasCollectionAccess else { throw ClientError.collectionAuthorization }
        let generation = authGeneration
        let rows: [CollectionMembership] = try await rpc("collection.getUserCollectionItemsByItem", input: ["imageId": imageID, "type": "Image"])
        guard generation == authGeneration, account?.id == actorID, hasCollectionAccess else { throw ClientError.accountChanged }
        return Set(rows.map(\.collectionId))
    }

    private enum FavoriteSaveIntent {
        case toggle(wasSaved: Bool)
        case folders(original: Set<Int>, selected: Set<Int>)
    }

    func isBookmarked(_ imageID: Int) -> Bool {
        if let optimisticBookmark, optimisticBookmark.imageID == imageID {
            return optimisticBookmark.saved
        }
        return savedMemberships[imageID]?.isEmpty == false
    }

    func toggleFavorite(imageID: Int, wasSaved: Bool, for expectedSession: AccountSessionID) throws {
        try submitFavoriteSave(imageID: imageID, intent: .toggle(wasSaved: wasSaved), for: expectedSession)
    }

    /// The session owns this one in-flight save, so dismissing the picker or
    /// paging away does not cancel it or leave its failure in a discarded view.
    func submitCollectionSelection(imageID: Int, original: Set<Int>, selected: Set<Int>, for expectedSession: AccountSessionID) throws {
        try submitFavoriteSave(imageID: imageID, intent: .folders(original: original, selected: selected), for: expectedSession)
    }

    private func submitFavoriteSave(imageID: Int, intent: FavoriteSaveIntent, for expectedSession: AccountSessionID) throws {
        try requireCollectionSession(expectedSession)
        guard savingFavoriteID == nil else { throw ClientError.collectionBusy }
        let token = UUID()
        favoriteSaveToken = token; savingFavoriteID = imageID
        // Only the button projects the pending intent. Folder reads and
        // offline downloads continue to consume confirmed memberships.
        if case .toggle(let wasSaved) = intent {
            optimisticBookmark = (imageID, !wasSaved)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.favoriteSaveToken == token {
                    self.optimisticBookmark = nil
                    self.favoriteSaveToken = nil; self.savingFavoriteID = nil
                }
            }
            guard self.acceptsFavoriteSave(token, for: expectedSession) else { return }
            do {
                try await self.saveCollectionSelection(imageID: imageID, intent: intent, token: token, for: expectedSession)
            } catch {
                guard self.acceptsFavoriteSave(token, for: expectedSession) else { return }
                self.message = error.localizedDescription
            }
        }
    }

    private func requireCollectionSession(_ expectedSession: AccountSessionID) throws {
        guard accountSessionID == expectedSession else { throw ClientError.accountChanged }
        guard collectionSessionID == expectedSession else { throw ClientError.collectionAuthorization }
    }

    private func acceptsFavoriteSave(_ token: UUID, for expectedSession: AccountSessionID) -> Bool {
        favoriteSaveToken == token && collectionSessionID == expectedSession && !showLogin
    }

    /// Confirm each work separately so a partial save can be resumed safely.
    func updateFavorites(_ ids: Set<Int>, folders: Set<Int>, removing: Bool,
                         for expectedSession: AccountSessionID) async throws -> (confirmed: Set<Int>, error: String?) {
        try requireCollectionSession(expectedSession)
        let actorID = expectedSession.accountID
        let works = ids.sorted()
        guard let first = works.first, first > 0, !folders.isEmpty else { throw ClientError.invalidResponse }
        guard savingFavoriteID == nil else { throw ClientError.collectionBusy }

        let token = UUID()
        favoriteSaveToken = token; savingFavoriteID = first
        var attemptedWrite = false
        defer {
            if favoriteSaveToken == token {
                if attemptedWrite && acceptsFavoriteSave(token, for: expectedSession) { collectionRevision += 1 }
                favoriteSaveToken = nil; savingFavoriteID = nil
            }
        }

        try await verifyFavoriteAccount(token, for: expectedSession)
        try await refreshCollections()
        guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
        let editable = Set(collections.map(\.id))
        guard folders.isSubset(of: editable) else { throw ClientError.invalidResponse }

        var confirmed = Set<Int>()
        var failure: String?
        for id in works {
            try Task.checkCancellation()
            guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
            savingFavoriteID = id
            invalidateMembershipRead(id)
            do {
                let current = try await refreshSavedMembership(id, force: true)
                let change = CollectionSelectionChange(original: removing ? folders : [],
                                                       selected: removing ? [] : folders, editable: editable, current: current)
                if !change.isEmpty {
                    if !attemptedWrite { await CollectionListCache.shared.invalidateRows(owner: actorID) }
                    attemptedWrite = true
                    _ = try await confirmCollectionChange(change, imageID: id, token: token, for: expectedSession)
                }
                try Task.checkCancellation()
                guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
                confirmed.insert(id)
            } catch {
                try Task.checkCancellation()
                guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
                if case ClientError.http(429) = error { failure = error.localizedDescription; break }
                if failure == nil { failure = error.localizedDescription }
            }
        }
        guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
        if !removing && !confirmed.isEmpty { rememberCollectionSelection(folders) }
        return (confirmed, failure)
    }

    private func verifyFavoriteAccount(_ token: UUID, for expectedSession: AccountSessionID) async throws {
        #if DEBUG && targetEnvironment(simulator)
        if !CollectionPagingQA.enabled { _ = try await readVerifiedAccount(for: expectedSession) }
        #else
        _ = try await readVerifiedAccount(for: expectedSession)
        #endif
        guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
    }

    private func favoriteSelection(for intent: FavoriteSaveIntent, current: Set<Int>) throws -> (original: Set<Int>, selected: Set<Int>) {
        switch intent {
        case .folders(let original, let selected):
            return (original, selected)
        case .toggle(let wasSaved):
            if wasSaved { return (current, []) }
            if !current.isEmpty { return (current, current) }
            let privateFolders = collections.filter { $0.read == "Private" }
            let preferred = defaultCollectionIDs
            guard let folder = privateFolders.first(where: { preferred.contains($0.id) }) ?? privateFolders.first else {
                throw ClientError.noPrivateFavoriteFolder
            }
            return (current, [folder.id])
        }
    }

    private func saveCollectionSelection(imageID: Int, intent: FavoriteSaveIntent, token: UUID,
                                         for expectedSession: AccountSessionID) async throws {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled {
            if ProcessInfo.processInfo.arguments.contains("--qa-favorite-save69-delay") {
                try await Task.sleep(for: .seconds(6))
            }
            if ProcessInfo.processInfo.arguments.contains("--qa-favorite-save69-account-change") {
                authGeneration += 1
                clearCollectionState()
                throw ClientError.accountChanged
            }
            guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
            if ProcessInfo.processInfo.arguments.contains("--qa-favorite-save69-failure") { throw ClientError.collectionWriteUnknown }
            let current = savedMemberships[imageID] ?? []
            let (original, selected) = try favoriteSelection(for: intent, current: current)
            guard account?.id == CollectionPagingQA.ownerID,
                  CollectionPagingQA.items.contains(where: { $0.id == imageID }),
                  original == current,
                  selected.isSubset(of: [CollectionPagingQA.collection.id]) else { throw ClientError.invalidResponse }
            savedMemberships[imageID] = selected; collectionRevision += 1
            if case .folders = intent { rememberCollectionSelection(selected) }
            return // Controlled in-memory interaction; never issue a site write.
        }
        #endif
        try requireCollectionSession(expectedSession)
        let actorID = expectedSession.accountID
        invalidateMembershipRead(imageID)
        try await verifyFavoriteAccount(token, for: expectedSession)
        try await refreshCollections()
        let current = try await refreshSavedMembership(imageID, force: true)
        guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
        let (original, selected) = try favoriteSelection(for: intent, current: current)
        let change = CollectionSelectionChange(original: original, selected: selected, editable: Set(collections.map(\.id)), current: current)
        if !change.isEmpty {
            await CollectionListCache.shared.invalidateRows(owner: actorID)
            defer { if acceptsFavoriteSave(token, for: expectedSession) { collectionRevision += 1 } }
            let after = try await confirmCollectionChange(change, imageID: imageID, token: token, for: expectedSession)
            savedMembershipUpdate = .init(accountID: actorID, imageID: imageID, collectionIDs: after)
        }
        if case .folders = intent, acceptsFavoriteSave(token, for: expectedSession) {
            rememberCollectionSelection(selected)
        }
    }

    private func confirmCollectionChange(_ change: CollectionSelectionChange, imageID: Int, token: UUID,
                                         for expectedSession: AccountSessionID) async throws -> Set<Int> {
        try Task.checkCancellation()
        guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            guard CollectionPagingQA.items.contains(where: { $0.id == imageID }) else { throw ClientError.invalidResponse }
            if !simulatedBatchFailure, imageID == 28_037_101,
               ProcessInfo.processInfo.arguments.contains("--qa-batch-favorite-partial") {
                simulatedBatchFailure = true
                throw ClientError.collectionWriteUnknown
            }
            let result = (savedMemberships[imageID] ?? []).union(change.additions).subtracting(change.removals)
            savedMemberships[imageID] = result
            return result
        }
        #endif
        var rateLimited = false
        do {
            let _: CollectionWriteResult = try await rpc("collection.saveItem", input: [
                "imageId": imageID, "type": "Image",
                "collections": change.additions.sorted().map { ["collectionId": $0] },
                "removeFromCollectionIds": change.removals.sorted()
            ], mutation: true)
        } catch {
            // The server may have committed before a timeout. Read, never replay.
            if case ClientError.http(429) = error { rateLimited = true }
        }
        guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
        invalidateMembershipRead(imageID)
        do {
            let after = try await refreshSavedMembership(imageID, force: true)
            guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
            guard change.isConfirmed(by: after) else { throw ClientError.collectionWriteUnknown }
            return after
        } catch {
            guard acceptsFavoriteSave(token, for: expectedSession) else { throw ClientError.accountChanged }
            // Keep the last observed membership for rollback, but force
            // the next read to recheck an uncertain server outcome.
            membershipReadAt[imageID] = nil
            if case ClientError.http(429) = error { rateLimited = true }
            throw rateLimited ? ClientError.http(429) : ClientError.collectionWriteUnknown
        }
    }

    func collectionPage(id: Int, filter: FeedFilter, cursor: String?, allAccessibleLevels: Bool = false, includeTags: Bool = false) async throws -> MediaPage {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            if !collectionsKnown { try await refreshCollections() }
            guard collections.contains(where: { $0.id == id }) else { throw ClientError.invalidResponse }
            if CollectionListCacheQA.fixture != nil, cursor == nil { try await Task.sleep(for: .seconds(5)) }
            let source = if ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") {
                CollectionPagingQA.items.filter { savedMemberships[$0.id]?.contains(id) == true }
            } else if CollectionListCacheQA.updatesList { Array(CollectionPagingQA.otherCollectionItems.prefix(1)) }
                else { id == CollectionPagingQA.collection.id ? CollectionPagingQA.items : CollectionPagingQA.otherCollectionItems }
            return MediaPage(items: cursor == nil ? source.filter { filter.effectiveKind == .all || $0.isVideo == (filter.effectiveKind == .video) } : [], metadata: .init(nextCursor: nil))
        }
        #endif
        guard let actorID = account?.id, hasCollectionAccess else { throw ClientError.collectionAuthorization }
        let generation = authGeneration
        let startingRevision = collectionRevision
        if !collectionsKnown { try await refreshCollections() }
        guard collections.contains(where: { $0.id == id }) else { throw ClientError.invalidResponse }
        let level = allAccessibleLevels ? 31 : (filter.onlyPG ? 1 : (account?.browsingLevel ?? 1))
        var input: [String: Any] = ["collectionId": id, "limit": 30, "browsingLevel": level]
        if let cursor { input["cursor"] = cursor }
        let index: CollectionIndexPage = try await rpc("collection.getAllCollectionItems", input: input)
        guard generation == authGeneration, account?.id == actorID else { throw ClientError.accountChanged }
        guard !index.mediaIDs.isEmpty else { return MediaPage(items: [], metadata: .init(nextCursor: index.nextCursor, sourceIDs: index.mediaIDs)) }
        let media = try await hydrateMedia(ids: index.mediaIDs, browsingLevel: level, includeTags: includeTags)
        guard generation == authGeneration, account?.id == actorID else { throw ClientError.accountChanged }
        let byID = Dictionary(media.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = index.mediaIDs.compactMap { byID[$0] }
        if startingRevision == collectionRevision, savingFavoriteID == nil {
            for item in ordered { savedMemberships[item.id, default: []].insert(id) }
        }
        return MediaPage(items: ordered, metadata: .init(nextCursor: index.nextCursor, sourceIDs: index.mediaIDs))
    }

    private struct CollectionWriteResult: Decodable { let status: String }

    func rpc<T: Decodable>(_ procedure: String, input: [String: Any]? = nil, mutation: Bool = false) async throws -> T {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { throw ClientError.format("本地测试不使用站点接口") }
        #endif
        #if DEBUG
        if procedure.hasPrefix("tag.") && !mutation { tagRPCReads += 1 }
        #endif
        let allowed = ["user.getFollowingUsers", "user.getList", "user.toggleFollow", "user.updateBrowsingMode", "leaderboard.getLeaderboard", "leaderboard.getLeadboardLegends", "image.getInfinite",
                       "collection.getAllUser", "collection.getUserCollectionItemsByItem", "collection.getAllCollectionItems", "collection.saveItem", "post.getInfinite", "tag.getAll", "tag.getFeedTagBar", "tag.getTagWithModelCount", "tag.getById", "user.getAll", "userProfile.get"]
        guard allowed.contains(procedure) else { throw ClientError.invalidResponse }
        let envelope: [String: Any] = ["json": input.map { $0 as Any } ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let body = String(decoding: data, as: UTF8.self)
        var components = URLComponents(string: "/api/trpc/" + procedure)!
        if !mutation { components.queryItems = [.init(name: "input", value: body)] }
        return try await request(path: components.string!, postBody: mutation ? body : nil, response: .rpc)
    }

    private func request<T: Decodable>(path: String, postBody: String? = nil, response: SiteRequestClient.Response = .rest,
                                       preferPublicREST: Bool = false) async throws -> T {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { throw ClientError.format("本地测试不使用站点接口") }
        #endif
        let requestGeneration = authGeneration
        return try await requestClient.request(path: path, postBody: postBody, response: response,
                                               preferPublicREST: preferPublicREST, loginPresented: { self.showLogin }) {
            try Task.checkCancellation()
            guard requestGeneration == self.authGeneration else { throw CancellationError() }
        }
    }

    func clearLocalLogin() async {
        authGeneration += 1
        oauth.clear()
        await webContext.clearWebsiteData()
        account = nil; following = []; followsKnown = false; unknownUsers = []
        clearCollectionState()
        MediaCache.shared.clear()
        await CollectionListCache.shared.clear()
        webContext.reloadSession()
    }

    private struct FollowResult: Decodable { let following: Bool }
    private struct UserPage: Decodable { let items: [Creator] }

}

extension OAuthLogin: SiteAuthorizedTransport {}
