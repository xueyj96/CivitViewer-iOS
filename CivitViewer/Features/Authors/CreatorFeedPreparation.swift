import SwiftUI
import Observation

@MainActor final class CreatorFeedPreparation: CreatorRoutePreparation {
    let creatorID: Int
    let kind: MediaKind
    let identity: String
    let key: FeedStoreRequestKey
    let store: FeedStore
    let firstPage: Task<FeedCommit, Never>
    private let coverPreloader: MediaPreloader

    init(creator: Creator, kind: MediaKind, session: SiteSession, blockedTags: Set<String>) {
        creatorID = creator.id
        self.kind = kind
        identity = session.feedIdentity
        let filter = FeedFilter.defaults(for: .creator, kind: kind)
        key = FeedStoreRequestKey(identity: identity, filter: filter, source: .creator(creator))
        let feed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: AuthorBlocklist.shared)
        store = feed
        let preloader = MediaPreloader()
        coverPreloader = preloader
        let preparationIdentity = identity
        firstPage = Task { @MainActor [feed, preloader, session, creator, kind, preparationIdentity] in
            let commit = await feed.activate(session: session, filter: filter, source: .creator(creator),
                                             blockedTags: blockedTags, transportPageBudget: 1)
            guard !Task.isCancelled, feed.accepts(commit, identity: preparationIdentity),
                  commit.state == .loaded || commit.state == .ended else { return commit }
            preloader.update(feed.items, after: -1, count: 3,
                             context: "creator:\(preparationIdentity):\(creator.id):\(kind.rawValue)",
                             wifiOnly: UserDefaults.standard.object(forKey: "wifiVideoPrefetch") as? Bool ?? true,
                             concurrency: MediaPrefetchConcurrency.validated(UserDefaults.standard.integer(forKey: MediaPrefetchConcurrency.defaultsKey)),
                             coverOnly: true)
            return commit
        }
    }

    isolated deinit {
        firstPage.cancel()
        coverPreloader.stop()
    }

    func matches(creator: Creator, kind: MediaKind) -> Bool {
        creatorID == creator.id && self.kind == kind && key.source == .creator(creator)
    }

    func matches(session: SiteSession, creator: Creator, kind: MediaKind) -> Bool {
        matches(creator: creator, kind: kind) && identity == session.feedIdentity &&
            key.filter == .defaults(for: .creator, kind: kind)
    }

    func matches(key: FeedStoreRequestKey, creator: Creator, kind: MediaKind) -> Bool {
        matches(creator: creator, kind: kind) && self.key == key && identity == key.identity
    }
}

extension CreatorRoute {
    @MainActor func preparing(session: SiteSession, blockedTags: Set<String>) -> CreatorRoute {
        if let prepared = preparation as? CreatorFeedPreparation,
           prepared.matches(session: session, creator: creator, kind: kind) { return self }
        return CreatorRoute(creator: creator, kind: kind,
                     preparation: CreatorFeedPreparation(creator: creator, kind: kind,
                                                         session: session, blockedTags: blockedTags))
    }
}
