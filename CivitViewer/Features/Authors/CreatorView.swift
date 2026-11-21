import SwiftUI
import Observation

struct CreatorView: View {
    let creator: Creator
    private let preparation: CreatorFeedPreparation?
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @StateObject private var imageFeed: FeedStore
    @StateObject private var videoFeed: FeedStore
    @State private var filter: FeedFilter
    @State private var showFilter = false
    @State private var showWorkSearch = false
    @State private var focused: Int?
    @State private var creatorGridAnchors: [MediaKind: Int] = [:]
    @State private var viewerItem: MediaItem?
    @State private var authorBlockError: String?
    @State private var favoriteBatch = FavoriteBatchSelection()
    private struct CreatorPaneKey: Equatable {
        let request: FeedStoreRequestKey
        let active: Bool
        let blocked: Bool
    }
    private var requestKey: FeedStoreRequestKey { requestKey(for: filter.effectiveKind) }
    private func requestKey(for kind: MediaKind) -> FeedStoreRequestKey {
        .init(identity: session.feedIdentity, filter: filter.selecting(kind: kind), source: .creator(creator))
    }
    private func feed(for kind: MediaKind) -> FeedStore { kind == .video ? videoFeed : imageFeed }
    private var feed: FeedStore { feed(for: filter.effectiveKind) }
    private var creatorBlocked: Bool { authorBlocklist.contains(id: creator.id) }
    private var creatorFeedHeader: some View {
        VStack(spacing: FloatingPageChrome.spacing) {
            CreatorIdentityCard(creator: creator)
                .padding(.horizontal, FloatingPageChrome.pageInset)
        }
        .padding(.bottom, 8)
    }
    private var floatingBar: some View {
        HStack(spacing: FloatingPageChrome.groupInset) {
            FloatingPageBackButton()
            if creatorBlocked {
                Text("作者").font(FloatingPageChrome.controlFont).frame(maxWidth: .infinity)
            }
            else {
                FloatingMediaPicker(title: "作者媒体类型",
                                    selection: Binding(get: { filter.effectiveKind }, set: selectMediaKind),
                                    identifier: "creator.media-kind")
                    .disabled(favoriteBatch.works != nil)
            }
            creatorActions.disabled(favoriteBatch.works != nil)
        }
    }
    private var creatorActions: some View {
        AppMenu {
            if !creatorBlocked {
                Button("搜索作品", systemImage: "magnifyingglass") { showWorkSearch = true }
                    .accessibilityIdentifier("creator.search")
                Button("筛选作品", systemImage: FloatingPageChrome.filterSymbol) { showFilter = true }
                    .accessibilityIdentifier("creator.filter")
            }
            if !creatorBlocked && feed.requestKey == requestKey && !feed.items.isEmpty {
                Button("多选收藏", systemImage: "checklist") { favoriteBatch.begin() }
                    .accessibilityIdentifier("favorite-batch.select")
            }
            if let profileURL {
                AppMenuLink(destination: profileURL) { Label("在 Civitai 打开", systemImage: "safari") }
                    .accessibilityIdentifier("creator.open-site")
                AppMenuShareLink(item: profileURL) { Label("分享作者", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("creator.share")
            }
            if !creatorBlocked {
                Divider()
                Button("在本机屏蔽作者", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                    if !authorBlocklist.add(creator) { authorBlockError = "无法加入本机屏蔽名单。" }
                    else { authorBlockError = nil }
                }
            }
        } label: { FloatingPageIcon(symbol: "ellipsis") }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .accessibilityLabel("作者更多操作")
        .accessibilityValue(creatorBlocked ? "" : filter.summary)
        .accessibilityIdentifier("creator.actions")
    }
    private var profileURL: URL? {
        let username = creator.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#%"))
        guard !username.isEmpty, let component = username.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: SiteSession.origin + "/user/" + component)
    }
    init(creator: Creator, initialKind: MediaKind = .image,
         preparation: (any CreatorRoutePreparation)? = nil) {
        self.creator = creator
        let candidate = preparation as? CreatorFeedPreparation
        let acceptedPreparation = candidate?.matches(creator: creator, kind: initialKind) == true ? candidate : nil
        self.preparation = acceptedPreparation
        _imageFeed = StateObject(wrappedValue: initialKind == .image && acceptedPreparation != nil
            ? acceptedPreparation!.store
            : FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: AuthorBlocklist.shared))
        _videoFeed = StateObject(wrappedValue: initialKind == .video && acceptedPreparation != nil
            ? acceptedPreparation!.store
            : FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: AuthorBlocklist.shared))
        _filter = State(initialValue: .defaults(for: .creator, kind: initialKind))
    }
    var body: some View {
        CreatorBrowser(creator: creator, kind: filter.effectiveKind, creatorBlocked: creatorBlocked) { kind, active in
            AnyView(creatorMediaPane(kind: kind, active: active))
        }
        .avoidOverlaidTabBar()
        .floatingPageBar("creator.top-bar", layoutIdentity: creatorBlocked) { floatingBar }
        .onAppear { NavigationDiagnostics.mark(.authorOpened) }
        .onDisappear { NavigationDiagnostics.mark(.authorClosed) }
        #if CIVIT_NAVIGATION_DIAGNOSTICS || (DEBUG && targetEnvironment(simulator))
        .onChange(of: feed.items.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty { NavigationDiagnostics.mark(.authorGridPublished) }
        }
        #endif
        .existingFeedbackToast(authorBlockError, scope: session.feedIdentity)
        .navigationDestination(isPresented: $showFilter) { FilterView(filter: $filter, context: .creator) }
        .navigationDestination(isPresented: $showWorkSearch) {
            SearchView(initialCriteria: .init(author: creator), initialFilter: filter, showsBack: true)
        }
        .favoriteBatchBottomBar($favoriteBatch, canManage: !creatorBlocked && feed.requestKey == requestKey)
        .favoriteBatchEditor($favoriteBatch)
        .mediaCover(item: $viewerItem) { opening in
            FeedMediaViewer(items: feed.items, focused: $focused, initialID: opening.id,
                            continuationState: feed.displayContinuationState,
                            loadMoreAutomatically: { await feed.nextAutomatically(session: session) },
                            refreshFromStart: refreshFeed, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                            onDetailsVisibility: { feed.setTagPolicyDeferred($0) }, title: "作者作品",
                            onEdgeSwipe: { _, _ in viewerItem = nil },
                            onOpenAuthor: { _ in viewerItem = nil }, onClose: { viewerItem = nil }) {
                await feed.next(session: session)
            }
        }
        .onChange(of: requestKey) { _, _ in favoriteBatch.reset() }
        .onChange(of: blocklist.names) { _, tags in
            imageFeed.applyBlockedTags(tags); videoFeed.applyBlockedTags(tags); favoriteBatch.reset()
        }
        .onChange(of: authorBlocklist.entries) { _, _ in
            if creatorBlocked {
                viewerItem = nil; imageFeed.invalidatePendingRequests(); videoFeed.invalidatePendingRequests(); favoriteBatch.reset()
            }
        }
        .ordinaryAppearance()
        .edgeSwitchingSegments(selection: Binding(get: { filter.effectiveKind }, set: selectMediaKind),
                               options: MediaKind.browsingCases, identifier: "creator.media-kind",
                               enabled: !creatorBlocked && viewerItem == nil && !showFilter && !showWorkSearch && favoriteBatch.works == nil,
                               reservesPageEdges: false, leftEdge: false, rightEdge: false, centerSwipe: true)
    }
    private func selectMediaKind(_ kind: MediaKind) {
        guard filter.effectiveKind != kind else { return }
        filter = filter.selecting(kind: kind)
    }

    private func creatorMediaPane(kind: MediaKind, active: Bool) -> some View {
        let paneFeed = feed(for: kind)
        let paneFilter = filter.selecting(kind: kind)
        let paneKey = requestKey(for: kind)
        return MediaGrid(feed: paneFeed, expectedRequestKey: paneKey,
                         emptyDescription: paneFilter.summary + "。可切换媒体类型，或调整时间与内容范围。",
                         anchor: Binding(get: { creatorGridAnchors[kind] }, set: { creatorGridAnchors[kind] = $0 }),
                         isVisible: active && kind == filter.effectiveKind && viewerItem == nil,
                         retainCoverWindow: viewerItem != nil,
                         refreshFromStart: { await refreshFeed(kind: kind) }, header: AnyView(creatorFeedHeader),
                         horizontalInset: AppTheme.spacing, showRoutineTagSummary: false, favoriteSelection: favoriteBatch.works,
                         beginSelection: { item in
            guard paneFeed.requestKey == paneKey else { return }
            favoriteBatch.begin(selecting: item.id)
        }, open: { item in
            if favoriteBatch.works != nil { favoriteBatch.toggle(item.id) }
            else { focused = item.id; viewerItem = item }
        }) { await paneFeed.next(session: session) }
            .task(id: CreatorPaneKey(request: paneKey, active: active, blocked: creatorBlocked)) {
                guard active else { return }
                guard !creatorBlocked else { paneFeed.invalidatePendingRequests(); return }
                if let preparation, paneFeed === preparation.store,
                   preparation.matches(key: paneKey, creator: creator, kind: kind) {
                    paneFeed.applyBlockedTags(blocklist.names)
                    let preparedCommit = await preparation.firstPage.value
                    guard !Task.isCancelled, feed(for: kind) === preparation.store,
                          preparation.matches(key: paneKey, creator: creator, kind: kind) else { return }
                    paneFeed.applyBlockedTags(blocklist.names)
                    let preparedStateIsConsumable = paneFeed.requestKey == paneKey &&
                        paneFeed.accepts(preparedCommit, identity: session.feedIdentity) &&
                        (preparedCommit.state == .loaded || preparedCommit.state == .ended || preparedCommit.state == .incomplete)
                    if preparedStateIsConsumable { return }
                }
                let retainedKey = paneFeed.requestKey == paneKey
                let commit = await paneFeed.activate(session: session, filter: paneFilter, source: .creator(creator), blockedTags: blocklist.names)
                if !retainedKey && paneFeed.accepts(commit, identity: session.feedIdentity) &&
                    (commit.state == .loaded || commit.state == .ended) {
                    focused = nil
                    creatorGridAnchors[kind] = nil
                }
            }
    }

    private func refreshFeed() async {
        await refreshFeed(kind: filter.effectiveKind)
    }

    private func refreshFeed(kind: MediaKind) async {
        let paneFeed = feed(for: kind)
        if await paneFeed.restartCurrentFeed(session: session)?.status == .committed { focused = paneFeed.items.first?.id }
    }
}


// The browser owns the lifetime of each visited pane. The navigation, player
// and editor share a single concrete browser type regardless of pane content.
private struct CreatorBrowser: View {
    let creator: Creator
    let kind: MediaKind
    let creatorBlocked: Bool
    let pane: (MediaKind, Bool) -> AnyView
    @State private var mountedKinds: Set<MediaKind> = []

    var body: some View {
        VStack(spacing: 0) {
            if creatorBlocked {
                ScrollView {
                    VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                        CreatorIdentityCard(creator: creator)
                        PageMessageCard(title: "已屏蔽此作者", symbol: "person.crop.circle.badge.xmark",
                                        detail: "可在设置中管理屏蔽作者。") { EmptyView() }
                    }
                    .pageScrollContentInsets()
                }
            } else {
                SegmentedContentPager(selection: kind, options: MediaKind.browsingCases,
                                      identifier: "creator.media-kind") { kind, active in
                    if active || mountedKinds.contains(kind) {
                        pane(kind, active)
                            .onAppear {
                                if !mountedKinds.contains(kind) { mountedKinds.insert(kind) }
                            }
                    }
                }
            }
        }
    }
}
