import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var board: Board = .seasonal
    @State private var recent: RecentPublication = .any
    @State private var openedAuthor: Creator?
    var body: some View {
        SegmentedContentPager(selection: board, options: Board.allCases, identifier: "leaderboard.board", isolatesNativeLists: true) { value, active in
            LeaderboardList(board: value, visible: active, selected: value == board, recent: recent, onOpen: { openedAuthor = $0 })
        }
        .floatingPageBar("leaderboard.top-bar") {
            HStack(spacing: FloatingPageChrome.groupInset) {
                FloatingSegmentedControl(title: "作者榜类型", selection: $board, options: Board.allCases,
                                         optionTitle: { $0.title }, identifier: "leaderboard.board")
                AppValueSelector(title: "作品更新时间", selection: $recent,
                                 options: RecentPublication.allCases, name: { $0.title }) {
                    AppFilterLabel(title: recent.title, symbol: "calendar")
                }
                .accessibilityLabel("作品更新：" + recent.title)
                .accessibilityIdentifier("leaderboard.recent-filter")
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .ordinaryAppearance()
        .navigationDestination(item: $openedAuthor) { CreatorView(creator: $0) }
        .edgeSwitchingSegments(selection: $board, options: Board.allCases, identifier: "leaderboard.board", reservesPageEdges: false, leftEdge: false, rightEdge: false, centerSwipe: true)
    }
}

// Both boards retain their mounted list and original rank positions.
private struct LeaderboardList: View {
    let board: Board
    let visible: Bool
    let selected: Bool
    let recent: RecentPublication
    let onOpen: (Creator) -> Void
    @Environment(\.rootPageParticipation) private var rootParticipation
    @Environment(\.segmentedPageMotion) private var segmentMotion
    @EnvironmentObject private var session: SiteSession
    @State private var entries: [LeaderboardEntry] = []
    @State private var loading = false
    @State private var loadID: UUID?
    @State private var loaded = false
    @State private var error: String?
    @State private var showUnknown = false
    @StateObject private var activity = CreatorActivityStore()
    private struct ActivityKey: Equatable { let visible: Bool; let active: Bool; let identity: String; let ids: [Int] }
    private var activityKey: ActivityKey { .init(visible: visible && selected && rootParticipation.isActive, active: recent != .any, identity: session.feedIdentity, ids: entries.map(\.id)) }
    private var matching: [LeaderboardEntry] {
        entries.filter { entry in
            if recent == .any { return true }
            if case .published(let date) = activity.result(for: entry.id) { return recent.includes(date) }
            return false
        }
    }
    private var unknown: [LeaderboardEntry] { entries.filter { activity.result(for: $0.id) == nil || activity.result(for: $0.id) == .unverified } }
    private var unchecked: Bool { entries.contains { activity.result(for: $0.id) == nil } }
    private var activitySummary: String {
        let verified = (entries.count - unknown.count).formatted(.number.locale(Locale(identifier: "en_US")))
        let total = entries.count.formatted(.number.locale(Locale(identifier: "en_US")))
        return "符合 \(matching.count) 位 · 已核实 \(verified)/\(total)"
    }
    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        let _ = segmentMotion?.recordProfileBodyEvaluation()
        #endif
        Group {
            if entries.isEmpty {
                if loading || (!loaded && error == nil) {
                    ProgressView().controlSize(.small).accessibilityLabel("正在加载作者榜").frame(maxHeight: .infinity)
                }
                else if let error { FailureView(message: error) { Task { await load() } } }
                else {
                    ScrollView {
                        PageStatusCard(title: "当前榜单暂无结果", symbol: "person.3")
                            .padding(.horizontal, FloatingPageChrome.pageInset)
                    }
                    .refreshable { await load() }
                }
            } else {
                List {
                    Section {
                        let results = matching
                        ForEach(results) { entry in row(entry, startsSection: entry.id == results.first?.id) }
                        if results.isEmpty && !activity.busy && !activity.checks.isEmpty {
                            Text(unknown.isEmpty ? "没有符合条件的作者" : "暂未找到符合条件的作者").foregroundStyle(.secondary)
                        }
                    } header: {
                        if recent != .any { activityHeader }
                    }
                    .listSectionSeparator(.hidden)
                    if recent != .any && !unknown.isEmpty && (!activity.busy || showUnknown) {
                        let failed = unknown.filter { activity.result(for: $0.id) == .unverified }
                        Section {
                            DisclosureGroup("待核实 · \(unknown.count) 位", isExpanded: $showUnknown) {
                                if !failed.isEmpty {
                                    StatusReloadButton(title: "重试待核实作者") {
                                        Task { await activity.checkNext(failed.map(\.user), source: session, retryUnknown: true) }
                                    }
                                        .disabled(activity.busy)
                                }
                                ForEach(unknown) { entry in row(entry) }
                            }
                            .accessibilityIdentifier("leaderboard.activity.unknown")
                        }
                    }
                }
                .listStyle(.plain)
                .pageContentViewport(active: visible && selected && rootParticipation.canPrepare)
                .floatingScrollCanvas()
                .refreshable { await load() }
                    .overlay(alignment: .bottom) {
                        if error != nil {
                            HStack(spacing: 4) {
                                StatusReloadButton { Task { await load() } }
                            }.padding(.leading, 12).background(AppTheme.secondarySurface, in: Capsule()).padding()
                        }
                    }
            }
        }
        .existingFeedbackToast(entries.isEmpty ? nil : error.map { _ in "刷新失败" }, active: visible && selected, scope: session.feedIdentity)
        .task(id: visible && rootParticipation.canPrepare) { if visible && rootParticipation.canPrepare && !loaded { await load(replacing: true) } }
            .task(id: activityKey) {
                guard visible, selected, rootParticipation.isActive, recent != .any else { return }
                await activity.checkNext(entries.map(\.user), source: session)
            }
    }
    private var activityHeader: some View {
        HStack(spacing: 8) {
            Text("符合更新范围")
                .accessibilityValue(activitySummary)
                .accessibilityIdentifier("leaderboard.activity.summary")
            Spacer(minLength: 4)
            Group {
                if activity.busy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在核实作品发布时间")
                        .accessibilityIdentifier("leaderboard.activity.loading")
                } else if unchecked {
                    Button {
                        Task { await activity.checkNext(entries.map(\.user), source: session) }
                    } label: {
                        Text("继续").font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("继续核实下一批作者")
                        .accessibilityIdentifier("leaderboard.activity.next")
                }
            }.frame(minWidth: 44, minHeight: 44, alignment: .trailing)
        }
    }
    private func row(_ entry: LeaderboardEntry, startsSection: Bool = false) -> some View {
        let shape = FloatingPageChrome.controlShape
        return Button {
            guard selected, visible, rootParticipation.isActive, segmentMotion?.isInteracting != true else { return }
            onOpen(entry.user)
        } label: {
            HStack(spacing: FloatingPageChrome.spacing) {
                AuthorRowIdentity(name: entry.user.username, detail: publicationDate(for: entry), position: entry.position)
                Spacer(minLength: 0)
                if session.following.contains(entry.user.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .accessibilityLabel("已关注")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .authorCardRow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.secondarySurface, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(SegmentedContentButtonStyle())
        .navigationLinkIndicatorVisibility(.hidden)
        .listRowInsets(EdgeInsets(top: startsSection ? 0 : 2, leading: FloatingPageChrome.pageInset, bottom: 2, trailing: FloatingPageChrome.pageInset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("leaderboard.author.\(entry.user.id)")
    }
    private func publicationDate(for entry: LeaderboardEntry) -> String? {
        guard recent != .any, case .published(let date) = activity.result(for: entry.id) else { return nil }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).year().month().day())
    }

    private func load(replacing: Bool = false) async {
        guard replacing || !loading else { return }
        let request = UUID()
        loadID = request
        loading = true
        error = nil
        defer {
            if loadID == request { loading = false }
        }
        do {
            let value = try await session.leaderboard(board)
            guard !Task.isCancelled, loadID == request else { return }
            entries = value.filter { !$0.user.username.isEmpty }
            loaded = true
        } catch {
            if !Task.isCancelled, loadID == request { self.error = error.localizedDescription }
        }
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 43
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.18, green: 0.36, blue: 0.43), in: Circle())
    }
}

/// Shared list numbering reserves the width of four digits without zero padding.
struct OrdinalLabel: View {
    let position: Int
    var body: some View {
        ZStack {
            Text("0000").hidden().accessibilityHidden(true)
            Text(String(position))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct AuthorRowIdentity: View {
    let name: String
    var showsHandle = false
    var detail: String? = nil
    var position: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let position {
                OrdinalLabel(position: position)
            }
            HStack(spacing: FloatingPageChrome.spacing) {
                AvatarView(name: name, size: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(showsHandle ? "@" + name : name)
                        .font(FloatingPageChrome.controlFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension View {
    func authorCardRow(horizontalInset: Bool = true) -> some View {
        padding(.horizontal, horizontalInset ? FloatingPageChrome.cardInset : 0)
            .padding(.vertical, FloatingPageChrome.groupInset)
            .frame(minHeight: FloatingPageChrome.controlHeight)
    }
}

struct CreatorIdentityCard: View {
    let creator: Creator

    var body: some View {
        HStack(spacing: FloatingPageChrome.spacing) {
            AuthorRowIdentity(name: creator.username, showsHandle: true)
            Spacer(minLength: FloatingPageChrome.groupInset)
            FollowButton(creator: creator)
        }
        .padding(.horizontal, FloatingPageChrome.cardInset)
        .padding(.vertical, FloatingPageChrome.groupInset)
        .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
    }
}

struct CreatorView: View {
    let creator: Creator
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @StateObject private var imageFeed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: AuthorBlocklist.shared)
    @StateObject private var videoFeed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: AuthorBlocklist.shared)
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
    init(creator: Creator, initialKind: MediaKind = .image) {
        self.creator = creator
        _filter = State(initialValue: .defaults(for: .creator, kind: initialKind))
    }
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
                SegmentedContentPager(selection: filter.effectiveKind, options: MediaKind.browsingCases,
                                      identifier: "creator.media-kind") { kind, active in
                    creatorMediaPane(kind: kind, active: active)
                }
            }
        }
        .avoidOverlaidTabBar()
        .floatingPageBar("creator.top-bar", layoutIdentity: creatorBlocked) { floatingBar }
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
        return MediaGrid(feed: paneFeed, previewItems: paneFeed.requestKey == paneKey ? nil : [],
                         emptyDescription: paneFilter.summary + "。可切换媒体类型，或调整时间与内容范围。",
                         anchor: Binding(get: { creatorGridAnchors[kind] }, set: { creatorGridAnchors[kind] = $0 }),
                         isVisible: active && kind == filter.effectiveKind && viewerItem == nil,
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
                let retainedKey = paneFeed.requestKey == paneKey
                let commit = await paneFeed.activate(session: session, filter: paneFilter, source: .creator(creator), blockedTags: blocklist.names)
                if !retainedKey && paneFeed.accepts(commit, identity: session.feedIdentity), commit.state == .loaded || commit.state == .ended {
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

extension FeedStore {
    /// Explicit recovery keeps the currently committed source/filter/account.
    @discardableResult
    func restartCurrentFeed(session: any FeedPageReading) async -> FeedRestartResult? {
        guard let key = requestKey, key.identity == session.feedIdentity else { return nil }
        return await restartFromStart(session: session, filter: key.filter, source: key.source, blockedTags: TagBlocklist.shared.names)
    }
}

struct MediaGrid: View {
    @ObservedObject var feed: FeedStore
    var previewItems: [MediaItem]? = nil
    var waitingForPreviewOpen: Int? = nil
    var continuationState: FeedContinuationState? = nil
    @Environment(\.rootPageParticipation) private var rootParticipation
    @EnvironmentObject private var session: SiteSession
    var emptyDescription: String? = nil
    var anchor: Binding<Int?>? = nil
    var scrollRequest = 0
    var loadsOnAppearance = true
    var isVisible = true
    var automaticLoadingAllowed = true
    var loadMoreAutomatically: (() async -> Void)? = nil
    var refreshFromStart: (() async -> Void)? = nil
    var header: AnyView? = nil
    var horizontalInset: CGFloat = 10
    var centersInitialProgress = false
    var showRoutineTagSummary = true
    var favoriteSelection: Set<Int>? = nil
    var beginSelection: ((MediaItem) -> Void)? = nil
    let open: (MediaItem) -> Void
    let loadMore: () async -> Void
    @State private var userScrolled = false
    @State private var visibleCells = Set<Int>()
    @State private var continuationAction: Task<Void, Never>?
    @State private var continuationActionID: UUID?
    @Environment(\.scenePhase) private var scenePhase
    private var nearEnd: Bool { !Set(feed.items.suffix(4).map(\.id)).isDisjoint(with: visibleCells) }
    private var continuationStatus: FeedContinuationState { continuationState ?? feed.displayContinuationState }
    private var empty: Bool { (previewItems ?? feed.items).isEmpty }
    private var showsCenteredProgress: Bool {
        centersInitialProgress && previewItems == nil && empty && (continuationStatus == .ready || continuationStatus.isLoading)
    }
    private var continuationView: some View {
        FeedContinuationStatusView(state: continuationStatus, empty: empty,
                                   performing: continuationAction != nil, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                                   retry: { startExplicitAction(loadMore) },
                                   restart: { startExplicitAction(refreshFromStart ?? { _ = await feed.restartCurrentFeed(session: session) }) })
    }
    private struct AutomaticLoadKey: Equatable {
        let request: FeedStoreRequestKey?
        let tail: Int?
        let active: Bool
        let permitted: Bool
        let demanded: Bool
    }
    private var automaticLoadKey: AutomaticLoadKey {
        .init(request: feed.requestKey, tail: feed.items.last?.id, active: isVisible && rootParticipation.isActive && scenePhase == .active,
              permitted: automaticLoadingAllowed, demanded: (loadsOnAppearance || userScrolled) && (feed.items.isEmpty || nearEnd))
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if let header { header.id(-1001) }
            if feed.unverifiedDuration > 0 || feed.hiddenByDuration > 0 {
                Text("时长范围隐藏 \(feed.hiddenByDuration) 项；\(feed.unverifiedDuration) 项时长未知，暂不展示。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, FloatingPageChrome.groupInset)
            }
            if feed.durationMetadataFailedPages > 0 {
                Text("视频时长暂时无法取得，当前作品和位置已保留；请稍后重试。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if feed.duplicatesDiscarded > 0 { Text("已去除 \(feed.duplicatesDiscarded) 项重复结果").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, FloatingPageChrome.groupInset) }
            if feed.unverifiedTags > 0 || (feed.hiddenByTags > 0 && (showRoutineTagSummary || (previewItems ?? feed.items).isEmpty)) {
                Text("标签屏蔽已隐藏 \(feed.hiddenByTags) 项；\(feed.unverifiedTags) 项标签待核实，暂不展示。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if feed.hiddenByAuthors > 0 {
                Text("本机作者屏蔽隐藏 \(feed.hiddenByAuthors) 项；取消屏蔽后可重新显示。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, FloatingPageChrome.groupInset)
            }
            LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(previewItems ?? feed.items) { item in
                    MediaGridCell(item: item, blurred: (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0),
                                  favoriteSelected: favoriteSelection?.contains(item.id),
                                  beginSelection: beginSelection.map { select in { select(item) } }) { open(item) }
                        .overlay {
                            if waitingForPreviewOpen == item.id {
                                ProgressView().controlSize(.small).tint(.white).padding(10)
                                    .background(.black.opacity(0.65), in: Circle())
                                    .allowsHitTesting(false).accessibilityLabel("正在更新收藏")
                            }
                        }
                        .onAppear {
                            visibleCells.insert(item.id)
                        }
                        .onDisappear { visibleCells.remove(item.id) }
                }
            }.scrollTargetLayout().padding(.horizontal, horizontalInset)
            if !showsCenteredProgress && (previewItems == nil || continuationStatus.failure != nil) {
                continuationView.padding(.vertical, 16)
            }
            if feed.items.isEmpty, continuationStatus == .ended, let emptyDescription {
                Text(emptyDescription).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
        }
        .overlay {
            if showsCenteredProgress {
                Color.clear
                    .overlay { continuationView }
                    .ignoresSafeArea(.container, edges: .vertical)
                    .allowsHitTesting(false)
            }
        }
        .modifier(MediaGridPosition(anchor: anchor))
        .pageContentViewport(active: isVisible && rootParticipation.canPrepare,
                             initiallyAtTop: anchor.map { $0.wrappedValue == nil || $0.wrappedValue == feed.items.first?.id })
        // scrollPosition owns restoration. The reader handles only an explicit
        // caller request; reappearing must not snap an existing row to its top.
        .onChange(of: scrollRequest) { _, _ in userScrolled = false; if let id = anchor?.wrappedValue { proxy.scrollTo(id, anchor: .top) } }
        .task(id: automaticLoadKey) {
            let key = automaticLoadKey
            guard key.active, key.permitted, key.demanded, feed.canAutomaticallyContinue else { return }
            if let loadMoreAutomatically { await loadMoreAutomatically() }
            else { await feed.nextAutomatically(session: session) }
        }
        .onChange(of: isVisible) { _, value in if !value { userScrolled = false; cancelContinuationAction() } }
        .onChange(of: scenePhase) { _, value in if value != .active { cancelContinuationAction() } }
        .onChange(of: feed.requestKey) { _, _ in cancelContinuationAction() }
        .onDisappear { cancelContinuationAction(); visibleCells = [] }
        .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
            if !userScrolled && !loadsOnAppearance && isVisible {
                userScrolled = true
            }
        }.onEnded { value in
            guard isVisible, scenePhase == .active, nearEnd,
                  value.translation.height < -36, abs(value.translation.height) > abs(value.translation.width) * 1.2,
                  continuationStatus != .ended, !continuationStatus.isLoading, !continuationStatus.requiresRestart else { return }
            // An actual forward scroll is explicit demand. This also releases a
            // programmatic-return gate when a short queue has no new cell to appear.
            startExplicitAction(loadMore)
        })
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if CollectionPagingQA.enabled {
                Text(verbatim: "count=\(feed.items.count);loading=\(feed.loading);error=\(feed.error ?? "none")")
                    .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("collection.qa.grid")
            }
        }
        #endif
        }
        .ordinaryAppearance()
    }
    private func startExplicitAction(_ action: @escaping () async -> Void) {
        guard continuationAction == nil, isVisible, scenePhase == .active else { return }
        let id = UUID()
        continuationActionID = id
        continuationAction = Task {
            defer { if continuationActionID == id { continuationAction = nil; continuationActionID = nil } }
            await action()
        }
    }
    private func cancelContinuationAction() {
        continuationAction?.cancel(); continuationAction = nil; continuationActionID = nil
    }
}

private struct MediaGridPosition: ViewModifier {
    var anchor: Binding<Int?>?
    @ViewBuilder func body(content: Content) -> some View {
        if let anchor { content.scrollPosition(id: anchor, anchor: .top) } else { content }
    }
}

private struct MediaGridCell: View {
    let item: MediaItem
    let blurred: Bool
    var favoriteSelected: Bool? = nil
    var beginSelection: (() -> Void)? = nil
    let open: () -> Void
    @State private var failure: String?
    @State private var retry = 0
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.showsCollectionDownloads) private var collectionDownloads
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var offline = OfflineLibrary.shared
    private var displayItem: MediaItem {
        collectionDownloads ? offline.localCollectionItem(item, owner: session.account?.id) ?? item : item
    }
    @Environment(\.segmentedPageMotion) private var segmentMotion
    @Environment(\.tabPageMotion) private var pageMotion
    @Environment(\.motionTab) private var tab
    private var activationAllowed: Bool {
        segmentMotion?.isInteracting != true && pageMotion?.blocksContentActivation(tab: tab) != true
    }
    #if DEBUG && targetEnvironment(simulator)
    @State private var previewAttempts = 0
    #endif
    private var cardHeight: CGFloat { textSize.isAccessibilitySize ? 300 : 230 }
    private var coverTitle: String { "\(item.isVideo ? "视频" : "图片") · #\(item.id)\(item.username.map { " · \($0)" } ?? "")" }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                guard activationAllowed else { return }
                open()
            } label: {
                Group {
                    if collectionDownloads, offline.localCollectionItem(item, owner: session.account?.id) == nil {
                        // A waiting collection card may fetch a small declared
                        // cover, never a remote full image/video as a fallback.
                        if let cover = item.posterURL {
                            CachedImage(url: cover, allowsRetry: false, imageBlur: blurred ? 20 : 0)
                        } else {
                            CoverPlaceholder(symbol: item.isVideo ? "play.rectangle" : "photo", title: coverTitle)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                        }
                    } else if item.isVideo, let source = displayItem.mediaURL {
                        CachedPoster(source: source, declared: displayItem.posterURL, retryToken: retry,
                                     onFailure: { failed in
                                         #if DEBUG && targetEnvironment(simulator)
                                         if !failed { previewAttempts += 1 }
                                         #endif
                                         failure = failed ? "封面暂时无法加载" : nil
                                     }, showsFailure: false,
                                     placeholderTitle: "视频 · #\(item.id)\(item.username.map { " · \($0)" } ?? "")", imageBlur: blurred ? 20 : 0)
                    } else if let url = displayItem.mediaURL ?? (item.isVideo ? displayItem.posterURL : nil) {
                        CachedImage(url: url, allowsRetry: false, retryToken: retry, showsFailure: false,
                                    onFailureMessage: { message in
                                        #if DEBUG && targetEnvironment(simulator)
                                        if message == nil { previewAttempts += 1 }
                                        #endif
                                        failure = message
                                    },
                                    placeholderTitle: coverTitle, imageBlur: blurred ? 20 : 0)
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.1)
                            CoverPlaceholder(symbol: item.isVideo ? "play.rectangle" : "photo",
                                title: "\(item.isVideo ? "视频" : "图片") · #\(item.id)\(item.username.map { " · \($0)" } ?? "")")
                        }
                    }
                }.opacity(failure == nil || favoriteSelected != nil ? 1 : 0).frame(height: cardHeight).contentShape(Rectangle())
            }.buttonStyle(SegmentedContentButtonStyle()).accessibilityLabel("\(item.isVideo ? "视频" : "图片") \(item.id)")
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
                    .onEnded { _ in
                        guard activationAllowed else { return }
                        beginSelection?()
                    }, including: beginSelection == nil ? .none : .all)
                .accessibilityAddTraits(favoriteSelected == true ? .isSelected : [])
                .accessibilityIdentifier("media.grid.cell.\(item.id)")
            if item.isVideo && favoriteSelected == nil {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(8).background(.black.opacity(0.4), in: Circle()).padding(8).allowsHitTesting(false)
            }
            if let failure {
                MediaLoadFailureContent(message: failure, workTitle: coverTitle, symbol: item.isVideo ? "play.rectangle" : "photo",
                                        retryLabel: item.isVideo ? "重试封面" : "重试图片",
                                        retryIdentifier: "media.grid.retry.\(item.id)", retry: { retry += 1 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(favoriteSelected == nil)
                    .accessibilityHidden(favoriteSelected != nil)
            }
        }.frame(height: cardHeight).clipShape(FloatingPageChrome.controlShape)
        .overlay(alignment: .topLeading) {
            if collectionDownloads { CollectionDownloadBadge(workID: item.id).padding(FloatingPageChrome.spacing) }
        }
        .overlay(alignment: .topTrailing) {
            if let favoriteSelected {
                FavoriteSelectionMark(selected: favoriteSelected, onMedia: true).padding(FloatingPageChrome.spacing).allowsHitTesting(false)
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--qa-grid-retry55") {
                Text("attempts=\(previewAttempts)").font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("grid.preview.attempts.\(item.id)").accessibilityValue("attempts=\(previewAttempts)")
            }
        }
        #endif
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Exercises production grid failures with missing local fixtures, no network.
struct GridRetryQAView: View {
    @State private var opened = 0
    private var items: [MediaItem] {
        [false, true].enumerated().map { index, video in
            var item = MediaItem(id: 55_001 + index, url: "", width: 192, height: 256,
                                 type: video ? "video" : "image", username: "LocalFixture", browsingLevel: 1, thumbnail: nil)
            let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-grid55-\(index)")
            item.offlineMediaURL = missing
            if video { item.offlinePosterURL = missing }
            return item
        }
    }
    var body: some View {
        VStack(spacing: 18) {
            Text("本地加载失败布局").font(.headline)
            HStack(spacing: FloatingPageChrome.spacing) {
                ForEach(items) { item in
                    MediaGridCell(item: item, blurred: false, open: { opened += 1 })
                        .frame(maxWidth: .infinity)
                        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            Text("opened=\(opened)").accessibilityIdentifier("grid.retry.qa.opens")
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .preferredColorScheme(.dark)
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--qa-grid-retry-large55") ? .accessibility2 : .large)
    }
}
#endif

struct FollowingView: View {
    private enum PresentationOrder: String, CaseIterable, Identifiable {
        case newest, oldest, nameAscending, nameDescending
        var id: Self { self }
        var title: String {
            switch self {
            case .newest: "最近关注"
            case .oldest: "最早关注"
            case .nameAscending: "名称 A–Z"
            case .nameDescending: "名称 Z–A"
            }
        }
        var sort: FollowingSort { self == .nameAscending || self == .nameDescending ? .name : .followed }
        var reverse: Bool { self == .oldest || self == .nameDescending }
        init(sort: FollowingSort, reverse: Bool) {
            switch (sort, reverse) {
            case (.followed, false): self = .newest
            case (.followed, true): self = .oldest
            case (.name, false): self = .nameAscending
            case (.name, true): self = .nameDescending
            }
        }
    }
    @EnvironmentObject private var session: SiteSession
    @StateObject private var store = FollowingListStore(cache: .shared)
    @AppStorage("following.sort") private var sortRaw = FollowingSort.followed.rawValue
    @AppStorage("following.reverseTime") private var reverseTime = false
    @AppStorage("following.reverseName") private var reverseName = false
    private var sort: FollowingSort { FollowingSort(rawValue: sortRaw) ?? .followed }
    private var reverse: Bool { sort == .followed ? reverseTime : reverseName }
    private var presentationOrder: PresentationOrder {
        get { PresentationOrder(sort: sort, reverse: reverse) }
        nonmutating set {
            sortRaw = newValue.sort.rawValue
            if newValue.sort == .followed { reverseTime = newValue.reverse }
            else { reverseName = newValue.reverse }
        }
    }
    private var key: FollowingListKey { .init(identity: session.followingIdentity, memberIDs: session.following, revision: session.followingRevision) }
    private var current: Bool { store.requestKey == key }
    private var orderIdentity: String { "\(session.followingIdentity):\(sort.rawValue):\(reverse)" }
    var body: some View {
        Group {
            if session.account == nil {
                ScrollView {
                    PageMessageCard(title: "登录后查看关注", symbol: "star", detail: "与 Civitai 账号同步关注关系。") {
                        Button("登录 Civitai") { session.openLogin() }
                            .buttonStyle(AppActionButtonStyle(tone: .accent))
                    }
                }
                .pageScrollContentInsets()
            } else if current, store.complete {
                List {
                    Section {
                        ForEach(store.ordered(sort, reverse: reverse)) { creator in
                            NavigationLink { CreatorView(creator: creator) } label: {
                                    AuthorRowIdentity(name: creator.username).authorCardRow(horizontalInset: false)
                            }
                        }
                    }
                    .floatingCardListRows()
                    if store.creators.isEmpty {
                        Section { Text("你还没有关注作者").foregroundStyle(.secondary) }
                            .floatingCardListRows()
                    }
                    if store.error != nil {
                        Section {
                            HStack(spacing: FloatingPageChrome.spacing) {
                                Spacer(minLength: 0)
                                StatusReloadButton(title: "重新加载关注列表") { Task { await load(force: true) } }
                            }
                        }
                        .floatingCardListRows()
                    }
                    Section {
                        Text("共 \(store.creators.count) 位")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .floatingCardListRows()
                }
                .accessibilityIdentifier("following.card-list")
                .listStyle(.plain)
                .listRowSpacing(FloatingPageChrome.groupInset)
                .id(orderIdentity)
                .refreshable { await load(force: true) }
            } else if !current || store.loading {
                VStack {
                    Spacer(minLength: 0)
                    ProgressView()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("following.loading")
            } else {
                List {
                    Section {
                        if store.error != nil {
                            HStack(spacing: FloatingPageChrome.spacing) {
                                Spacer(minLength: 0)
                                StatusReloadButton(title: "重新加载关注列表") { Task { await load(force: true) } }
                            }
                        }
                    }
                    .floatingCardListRows()
                }
                .listStyle(.plain)
                .refreshable { await load(force: true) }
            }
        }
        .avoidOverlaidTabBar(constrainViewport: true)
        .existingFeedbackToast(store.error, active: current, scope: session.feedIdentity)
        .floatingTitleBar("我的关注") {
                AppValueSelector(title: "关注排序", selection: Binding(get: { presentationOrder }, set: { presentationOrder = $0 }),
                                 options: PresentationOrder.allCases, name: { $0.title }) {
                    FloatingPageIcon(symbol: "arrow.up.arrow.down")
                }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("关注排序")
                .accessibilityValue(presentationOrder.title)
                .accessibilityIdentifier("following.order")
        }
        .task(id: key) { await load(force: false) }.ordinaryAppearance()
    }
    private func load(force: Bool) async {
        guard !Task.isCancelled else { return }
        guard session.account != nil else { store.clear(); return }
        let requestedKey = key
        if !force, store.requestKey == requestedKey, store.complete,
           !store.isStaleSnapshot, store.error == nil { return }
        await store.reload(key: requestedKey, source: session)
    }
}
