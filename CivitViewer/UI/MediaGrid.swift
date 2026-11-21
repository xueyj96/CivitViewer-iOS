import SwiftUI
import Observation

struct DelayedLoadingIndicator<Scope: Equatable, Content: View>: View {
    let scope: Scope
    @ViewBuilder let content: () -> Content
    @State private var visibleScope: Scope?

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            if visibleScope == scope { content() }
        }
            .task(id: scope) {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled else { return }
                visibleScope = scope
            }
    }
}

/// A page request belongs to a mounted grid/scope, not to the last visible row.
/// Scrolling away from the trigger keeps its one accepted request alive.
@MainActor @Observable final class GridContinuationLoader<Scope: Equatable> {
    private(set) var completion = 0
    @ObservationIgnored private var scope: Scope?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    func update(scope: Scope, enabled: Bool, demanded: Bool, canLoad: Bool,
                load: @escaping @MainActor () async -> Bool) {
        if self.scope != scope { cancel(); self.scope = scope }
        guard enabled else { cancel(); return }
        guard demanded, canLoad, task == nil else { return }
        let id = UUID(); requestID = id
        task = Task {
            let advanced = await load()
            guard requestID == id else { return }
            task = nil; requestID = nil
            if advanced { completion &+= 1 }
        }
    }
    func cancel() {
        task?.cancel(); task = nil; requestID = nil
    }
}

@MainActor @Observable final class MediaGridVisibility {
    private(set) var nearEnd = false
    @ObservationIgnored private var visibleIDs = Set<Int>()
    @ObservationIgnored private var tailIDs = Set<Int>()

    func insert(_ id: Int) {
        visibleIDs.insert(id)
        updateNearEnd()
    }
    func remove(_ id: Int) {
        visibleIDs.remove(id)
        updateNearEnd()
    }
    func replaceVisible(_ ids: [Int]) {
        visibleIDs = Set(ids)
        updateNearEnd()
    }
    func updateTail(_ ids: [Int]) {
        tailIDs = Set(ids)
        updateNearEnd()
    }
    func clear() {
        visibleIDs.removeAll(keepingCapacity: true)
        updateNearEnd()
    }
    private func updateNearEnd() {
        let value = !visibleIDs.isDisjoint(with: tailIDs)
        guard value != nearEnd else { return }
        nearEnd = value
    }
}

struct MediaGrid: View {
    @ObservedObject var feed: FeedStore
    var previewItems: [MediaItem]? = nil
    var expectedRequestKey: FeedStoreRequestKey? = nil
    var continuationState: FeedContinuationState? = nil
    @Environment(\.rootPageParticipation) private var rootParticipation
    @EnvironmentObject private var session: SiteSession
    var emptyDescription: String? = nil
    var anchor: Binding<Int?>? = nil
    var scrollRequest = 0
    var loadsOnAppearance = true
    var isVisible = true
    var retainCoverWindow = false
    var automaticLoadingAllowed = true
    var loadMoreAutomatically: (() async -> Void)? = nil
    var refreshFromStart: (() async -> Void)? = nil
    var showsLoadingWithContent = true
    var delaysEmptyProgress = false
    var header: AnyView? = nil
    var horizontalInset: CGFloat = 10
    var centersInitialProgress = false
    var showRoutineTagSummary = true
    var favoriteSelection: Set<Int>? = nil
    var beginSelection: ((MediaItem) -> Void)? = nil
    let open: (MediaItem) -> Void
    let loadMore: () async -> Void
    @State private var userScrolled = false
    @State private var visibility = MediaGridVisibility()
    @State private var coverWindow = GridCoverImageWindow()
    @State private var mounted = false
    @State private var automaticLoader = GridContinuationLoader<AutomaticLoadScope>()
    @State private var continuationAction: Task<Void, Never>?
    @State private var continuationActionID: UUID?
    @Environment(\.scenePhase) private var scenePhase
    private var nearEnd: Bool { visibility.nearEnd }
    private var coverCanLoad: Bool { isVisible && rootParticipation.canPrepare && scenePhase == .active }
    private var coverWindowEnabled: Bool { coverCanLoad || (retainCoverWindow && mounted) }
    private enum RequestProjection {
        case pending(FeedStoreRequestKey)
        case ready(FeedStoreRequestKey)
        case failed(FeedStoreRequestKey)

        var key: FeedStoreRequestKey {
            switch self { case .pending(let key), .ready(let key), .failed(let key): key }
        }
        var isPending: Bool { if case .pending = self { true } else { false } }
        var isFailed: Bool { if case .failed = self { true } else { false } }
    }
    private var requestProjection: RequestProjection? {
        guard let key = expectedRequestKey else { return nil }
        guard feed.requestKey == key else { return .pending(key) }
        if feed.continuationState.failure != nil { return .failed(key) }
        if feed.loading && feed.items.isEmpty { return .pending(key) }
        return .ready(key)
    }
    private var projectionIsCurrent: Bool { requestProjection.map { $0.key == feed.requestKey } ?? true }
    private var continuationStatus: FeedContinuationState {
        if requestProjection?.isPending == true { return .loading }
        if requestProjection?.isFailed == true { return feed.displayContinuationState }
        return continuationState ?? feed.displayContinuationState
    }
    private var projectedItems: [MediaItem] {
        if let expectedRequestKey, expectedRequestKey != feed.requestKey { return [] }
        return previewItems ?? feed.items
    }
    private var empty: Bool { projectedItems.isEmpty }
    private var showsCenteredProgress: Bool {
        let requestPending = requestProjection?.isPending == true
        return empty && (requestPending || (centersInitialProgress && previewItems == nil && (continuationStatus == .ready || continuationStatus.isLoading)))
    }
    private var showsContinuationAtBottom: Bool {
        guard !showsCenteredProgress, requestProjection?.isPending != true else { return false }
        if !showsLoadingWithContent, !empty, continuationStatus.isLoading { return false }
        return previewItems == nil || continuationStatus.failure != nil
    }
    private var continuationView: some View {
        FeedContinuationStatusView(state: continuationStatus, empty: empty,
                                   performing: continuationAction != nil, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                                   retry: { startExplicitAction(loadMore) },
                                   restart: { startExplicitAction(refreshFromStart ?? { _ = await feed.restartCurrentFeed(session: session) }) })
    }
    @ViewBuilder private var continuationFeedback: some View {
        if delaysEmptyProgress, empty, continuationStatus.isLoading, let key = expectedRequestKey ?? feed.requestKey {
            DelayedLoadingIndicator(scope: key) { continuationView }
        } else {
            continuationView
        }
    }
    private struct AutomaticLoadScope: Equatable {
        let request: FeedStoreRequestKey?
        let active: Bool
        let permitted: Bool
    }
    private struct AutomaticLoadKey: Equatable {
        let scope: AutomaticLoadScope
        let tail: Int?
        let demanded: Bool
        let canLoad: Bool
        let completion: Int
    }
    private var automaticLoadKey: AutomaticLoadKey {
        .init(scope: .init(request: expectedRequestKey ?? feed.requestKey, active: mounted && isVisible && rootParticipation.isActive && scenePhase == .active,
                           permitted: automaticLoadingAllowed), tail: projectedItems.last?.id,
              demanded: (loadsOnAppearance || userScrolled) && (projectedItems.isEmpty || nearEnd),
              canLoad: feed.canAutomaticallyContinue && (requestProjection?.isPending != true), completion: automaticLoader.completion)
    }
    private func canOpen(_ item: MediaItem) -> Bool {
        (expectedRequestKey == nil || expectedRequestKey == feed.requestKey) &&
        projectedItems.contains(where: { $0.id == item.id })
    }
    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        let _ = ContentPerformance179QA.enabled ? (ContentPerformance179QA.gridBodies += 1) : ()
        #endif
        ScrollViewReader { proxy in
        ScrollView {
            if let header { header.id(-1001) }
            if projectionIsCurrent && (feed.unverifiedDuration > 0 || feed.hiddenByDuration > 0) {
                Text("时长范围隐藏 \(feed.hiddenByDuration) 项；\(feed.unverifiedDuration) 项时长未知，暂不展示。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, FloatingPageChrome.groupInset)
            }
            if projectionIsCurrent && feed.duplicatesDiscarded > 0 { Text("已去除 \(feed.duplicatesDiscarded) 项重复结果").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, FloatingPageChrome.groupInset) }
            if projectionIsCurrent && (feed.unverifiedTags > 0 || (feed.hiddenByTags > 0 && (showRoutineTagSummary || projectedItems.isEmpty))) {
                Text("标签屏蔽已隐藏 \(feed.hiddenByTags) 项；\(feed.unverifiedTags) 项标签待核实，暂不展示。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if projectionIsCurrent && feed.hiddenByAuthors > 0 {
                Text("本机作者屏蔽隐藏 \(feed.hiddenByAuthors) 项；取消屏蔽后可重新显示。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, FloatingPageChrome.groupInset)
            }
            LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(projectedItems) { item in
                    let blurred = (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0)
                    MediaGridCellHost(item: item, blurred: blurred,
                                      favoriteSelected: favoriteSelection?.contains(item.id),
                                      coverWindow: coverWindow,
                                      gridActive: coverWindowEnabled,
                                      coverCanLoad: coverCanLoad,
                                      retainCoverWindow: retainCoverWindow,
                                      sceneActive: scenePhase == .active,
                                      beginSelection: beginSelection.map { selection in { if canOpen(item) { selection(item) } } }) { if canOpen(item) { open(item) } }
                        .onAppear {
                            if #unavailable(iOS 18.0) {
                                visibility.insert(item.id)
                                coverWindow.fallbackAppeared(item.id)
                            }
                        }
                        .onDisappear {
                            if #unavailable(iOS 18.0) {
                                visibility.remove(item.id)
                                coverWindow.fallbackDisappeared(item.id)
                            }
                        }
                }
            }.scrollTargetLayout().padding(.horizontal, horizontalInset)
            if showsContinuationAtBottom {
                continuationFeedback.padding(.vertical, 16)
            }
            if projectedItems.isEmpty, requestProjection?.isPending != true, continuationStatus == .ended, let emptyDescription {
                Text(emptyDescription).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
        }
        .modifier(MediaGridTargetVisibility(visibility: visibility, coverWindow: coverWindow, frozen: retainCoverWindow))
        .overlay {
            if showsCenteredProgress {
                Color.clear
                    .overlay { continuationFeedback }
                    .ignoresSafeArea(.container, edges: .vertical)
                    .allowsHitTesting(false)
            }
        }
        .modifier(MediaGridPosition(anchor: anchor))
        .pageContentViewport(active: isVisible && rootParticipation.canPrepare,
                             initiallyAtTop: anchor.map { $0.wrappedValue == nil || $0.wrappedValue == projectedItems.first?.id })
        // scrollPosition owns restoration. The reader handles only an explicit
        // caller request; reappearing must not snap an existing row to its top.
        .onChange(of: scrollRequest) { _, _ in userScrolled = false; if let id = anchor?.wrappedValue { proxy.scrollTo(id, anchor: .top) } }
        .onAppear {
            mounted = true
            coverWindow.setFrozen(retainCoverWindow)
            coverWindow.setEnabled(coverWindowEnabled)
        }
        .onChange(of: feed.items.suffix(8).map(\.id), initial: true) { _, tailIDs in
            visibility.updateTail(tailIDs)
        }
        .onChange(of: automaticLoadKey, initial: true) { _, _ in
            let key = automaticLoadKey
            automaticLoader.update(scope: key.scope, enabled: key.scope.active && key.scope.permitted,
                                   demanded: key.demanded, canLoad: key.canLoad) {
                let priorTail = projectedItems.last?.id
                if let loadMoreAutomatically { await loadMoreAutomatically() }
                else { await feed.nextAutomatically(session: session) }
                return projectedItems.last?.id != priorTail
            }
        }
        .onChange(of: isVisible) { _, value in
            if !value { userScrolled = false; cancelContinuationAction() }
        }
        .onChange(of: coverCanLoad) { _, _ in coverWindow.setEnabled(coverWindowEnabled) }
        .onChange(of: retainCoverWindow) { _, frozen in
            coverWindow.setFrozen(frozen)
            coverWindow.setEnabled(coverWindowEnabled)
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active { cancelContinuationAction() }
        }
        .onChange(of: feed.requestKey) { _, _ in
            visibility.updateTail(feed.items.suffix(8).map(\.id))
            cancelContinuationAction()
        }
        .onDisappear {
            mounted = false; automaticLoader.cancel(); cancelContinuationAction(); visibility.clear(); coverWindow.clear()
        }
        .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
            #if DEBUG && targetEnvironment(simulator)
            if AuthorPaging176QA.continuous, isVisible, let key = feed.requestKey, case .creator = key.source {
                AuthorPaging176QA.dragChanged()
            }
            #endif
            if !userScrolled && !loadsOnAppearance && isVisible {
                userScrolled = true
            }
        }.onEnded { value in
            #if DEBUG && targetEnvironment(simulator)
            if AuthorPaging176QA.continuous, isVisible, let key = feed.requestKey, case .creator = key.source {
                AuthorPaging176QA.dragEnded()
            }
            #endif
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

private struct MediaGridTargetVisibility: ViewModifier {
    let visibility: MediaGridVisibility
    let coverWindow: GridCoverImageWindow
    let frozen: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.05) { ids in
                guard !frozen else { return }
                visibility.replaceVisible(ids)
                coverWindow.updateVisible(ids)
            }
        } else {
            content
        }
    }
}

private struct MediaGridCell: View {
    let item: MediaItem
    let blurred: Bool
    var favoriteSelected: Bool? = nil
    var beginSelection: (() -> Void)? = nil
    var projectedDisplayItem: MediaItem? = nil
    var collectionWaiting = false
    var downloadState: OfflineLibrary.CollectionDownloadState? = nil
    let coverWindow: GridCoverImageWindow
    let gridActive: Bool
    var coverCanLoad = true
    var retainCoverWindow = false
    var sceneActive = true
    let open: () -> Void
    @State private var retry = 0
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.showsCollectionDownloads) private var collectionDownloads
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
    @State private var coverSlot = GridCoverImageSlot()
    private var coverAdmission: GridCoverImageAdmission? { gridActive ? coverSlot.admission : nil }
    private var coverLoadingEnabled: Bool { gridActive && coverCanLoad && !retainCoverWindow && sceneActive }
    private var coverResult: CachedPosterLoadResult? { coverAdmission?.result }
    private var coverAdmitted: Bool { coverAdmission != nil }
    private var coverTicket: Int { coverAdmission?.ticket ?? 0 }
    private var coverRetryIdentity: Int { coverTicket &* 1_000_003 &+ retry }
    private func displaySource(for value: MediaItem) -> URL? { value.mediaURL ?? (item.isVideo ? value.posterURL : nil) }
    private var hasCoverImage: Bool {
        guard let coverResult else { return false }
        if collectionDownloads && collectionWaiting, let cover = item.posterURL {
            return coverResult.image(for: cover, fallbackURLs: []) != nil
        }
        guard let source = displaySource(for: projectedDisplayItem ?? item) else { return false }
        if item.isVideo, (projectedDisplayItem ?? item).mediaURL != nil {
            return coverResult.image(for: source, declared: (projectedDisplayItem ?? item).posterURL) != nil
        }
        let candidates = MediaPosterPolicy.gridImageCandidates(source: source, declared: (projectedDisplayItem ?? item).posterURL)
        return coverResult.image(for: MediaPosterPolicy.gridImageURL(source: source, declared: (projectedDisplayItem ?? item).posterURL),
                                 fallbackURLs: Array(candidates.dropFirst())) != nil
    }
    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        let _ = ContentPerformance179QA.cell(collection: collectionDownloads)
        #endif
        let displayItem = projectedDisplayItem ?? item
        ZStack(alignment: .topTrailing) {
            Button {
                guard activationAllowed else { return }
                open()
            } label: {
                Group {
                    if !coverAdmitted {
                        AppTheme.secondarySurface.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if collectionDownloads, collectionWaiting {
                        // A waiting collection card may fetch a small declared
                        // cover, never a remote full image/video as a fallback.
                        if let cover = item.posterURL, let coverResult {
                            CachedImage(url: cover, sharedResult: coverResult, restoresDecodedCoverPreview: true,
                                        loadingEnabled: coverLoadingEnabled,
                                        allowsRetry: false, retryToken: coverRetryIdentity,
                                        imageBlur: blurred ? 20 : 0)
                        } else {
                            AppTheme.secondarySurface.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if item.isVideo, let source = displayItem.mediaURL, let coverResult {
                        ZStack {
                            AppTheme.secondarySurface
                            CachedPoster(source: source, declared: displayItem.posterURL, presentation: .imageOnly,
                                         sharedResult: coverResult, restoresDecodedCoverPreview: true,
                                         loadingEnabled: coverLoadingEnabled,
                                         retryToken: coverRetryIdentity, diagnosticWorkID: item.id,
                                         showsFailure: false, imageBlur: blurred ? 20 : 0)
                        }
                    } else if let url = displayItem.mediaURL ?? (item.isVideo ? displayItem.posterURL : nil), let coverResult {
                        let primary = MediaPosterPolicy.gridImageURL(source: url, declared: displayItem.posterURL)
                        let fallbacks = Array(MediaPosterPolicy.gridImageCandidates(source: url, declared: displayItem.posterURL).dropFirst())
                        ZStack {
                            AppTheme.secondarySurface
                            CachedImage(url: primary, fallbackURLs: fallbacks, sharedResult: coverResult,
                                    restoresDecodedCoverPreview: true,
                                    loadingEnabled: coverLoadingEnabled,
                                    allowsRetry: false, retryToken: coverRetryIdentity, showsFailure: false,
                                        imageBlur: blurred ? 20 : 0, retriesTransientFailures: true)
                        }
                    } else {
                        AppTheme.secondarySurface
                    }
                }.frame(height: cardHeight).contentShape(Rectangle())
            }.buttonStyle(SegmentedContentButtonStyle()).accessibilityLabel("\(item.isVideo ? "视频" : "图片") \(item.id)")
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
                    .onEnded { _ in
                        guard activationAllowed else { return }
                        beginSelection?()
                    }, including: beginSelection == nil ? .none : .all)
                .accessibilityAddTraits(favoriteSelected == true ? .isSelected : [])
                .accessibilityIdentifier("media.grid.cell.\(item.id)")
            if item.isVideo && hasCoverImage && favoriteSelected == nil {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(8).background(.black.opacity(0.4), in: Circle()).padding(8).allowsHitTesting(false)
            }
        }.frame(height: cardHeight).clipShape(FloatingPageChrome.controlShape)
        .overlay(alignment: .center) {
            if coverResult?.failed == true && favoriteSelected == nil {
                Button { if !retainCoverWindow && isGridActionAllowed { retry += 1 } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.58), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(retainCoverWindow || !isGridActionAllowed)
                .accessibilityLabel(item.isVideo ? "重试封面" : "重试图片")
                .accessibilityIdentifier("media.grid.retry.\(item.id)")
            }
        }
        .onAppear { coverWindow.register(item.id, slot: coverSlot) }
        .onDisappear { coverWindow.unregister(item.id, slot: coverSlot) }
        .onChange(of: coverResult?.isLoading) { _, loading in
            #if DEBUG && targetEnvironment(simulator)
            if loading == true { previewAttempts += 1 }
            #endif
        }
        .overlay(alignment: .topLeading) {
            if collectionDownloads {
                CollectionDownloadBadge(workID: item.id, state: downloadState).padding(FloatingPageChrome.spacing)
            }
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
    private var isGridActionAllowed: Bool { gridActive && !retainCoverWindow }
}

private struct MediaGridCellHost: View {
    let item: MediaItem
    let blurred: Bool
    let favoriteSelected: Bool?
    let coverWindow: GridCoverImageWindow
    let gridActive: Bool
    var coverCanLoad = true
    var retainCoverWindow = false
    var sceneActive = true
    let beginSelection: (() -> Void)?
    let open: () -> Void
    @Environment(\.showsCollectionDownloads) private var collectionDownloads
    @EnvironmentObject private var session: SiteSession

    @ViewBuilder var body: some View {
        if collectionDownloads {
            CollectionMediaGridCell(item: item, owner: session.account?.id, blurred: blurred,
                                    favoriteSelected: favoriteSelected, coverWindow: coverWindow,
                                    gridActive: gridActive, coverCanLoad: coverCanLoad,
                                    retainCoverWindow: retainCoverWindow, sceneActive: sceneActive,
                                    beginSelection: beginSelection,
                                    open: open)
                .id("\(session.account.map { String($0.id) } ?? "signed-out"):\(item.id)")
        } else {
            MediaGridCell(item: item, blurred: blurred, favoriteSelected: favoriteSelected,
                          beginSelection: beginSelection, coverWindow: coverWindow,
                          gridActive: gridActive, coverCanLoad: coverCanLoad,
                          retainCoverWindow: retainCoverWindow, sceneActive: sceneActive, open: open)
        }
    }
}

private struct CollectionMediaGridCell: View {
    let item: MediaItem
    let blurred: Bool
    let favoriteSelected: Bool?
    let coverWindow: GridCoverImageWindow
    let gridActive: Bool
    let coverCanLoad: Bool
    let retainCoverWindow: Bool
    let sceneActive: Bool
    let beginSelection: (() -> Void)?
    let open: () -> Void
    @StateObject private var projection: OfflineCollectionContentProjection

    init(item: MediaItem, owner: Int?, blurred: Bool, favoriteSelected: Bool?, coverWindow: GridCoverImageWindow,
         gridActive: Bool, coverCanLoad: Bool, retainCoverWindow: Bool, sceneActive: Bool,
         beginSelection: (() -> Void)?, open: @escaping () -> Void) {
        self.item = item
        self.blurred = blurred
        self.favoriteSelected = favoriteSelected
        self.coverWindow = coverWindow
        self.gridActive = gridActive
        self.coverCanLoad = coverCanLoad
        self.retainCoverWindow = retainCoverWindow
        self.sceneActive = sceneActive
        self.beginSelection = beginSelection
        self.open = open
        _projection = StateObject(wrappedValue: OfflineCollectionContentProjection(workID: item.id, owner: owner))
    }

    var body: some View {
        let state = projection.state
        MediaGridCell(item: item, blurred: blurred, favoriteSelected: favoriteSelected,
                      beginSelection: beginSelection, projectedDisplayItem: state.displayItem(item),
                      collectionWaiting: state.mediaURL == nil, downloadState: state.downloadState,
                      coverWindow: coverWindow, gridActive: gridActive, coverCanLoad: coverCanLoad,
                      retainCoverWindow: retainCoverWindow, sceneActive: sceneActive, open: open)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Exercises production grid failures with missing local fixtures, no network.
struct GridRetryQAView: View {
    @State private var opened = 0
    @State private var coverWindow = GridCoverImageWindow()
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
                    MediaGridCell(item: item, blurred: false, coverWindow: coverWindow,
                              gridActive: true, open: { opened += 1 })
                        .frame(maxWidth: .infinity)
                        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            Text("opened=\(opened)").accessibilityIdentifier("grid.retry.qa.opens")
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .preferredColorScheme(.dark)
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--qa-grid-retry-large55") ? .accessibility2 : .large)
            .onAppear {
                coverWindow.setEnabled(true)
                coverWindow.updateVisible(items.map(\.id))
            }
            .onDisappear { coverWindow.clear() }
    }
}
#endif

extension FeedStore {
    /// Explicit recovery keeps the currently committed source/filter/account.
    @discardableResult
    func restartCurrentFeed(session: any FeedPageReading) async -> FeedRestartResult? {
        guard let key = requestKey, key.identity == session.feedIdentity else { return nil }
        return await restartFromStart(session: session, filter: key.filter, source: key.source, blockedTags: TagBlocklist.shared.names)
    }
}
