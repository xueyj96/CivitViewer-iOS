import SwiftUI
import UIKit

private extension View {
    @ViewBuilder func resumePromptQAFrame(_ key: String) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            background(GeometryReader { proxy in
                Color.clear.preference(key: CollectionPagingQAFrameKey.self, value: [key: proxy.frame(in: .global)])
            })
        } else if ResumePromptQA.enabled {
            background(GeometryReader { proxy in
                Color.clear.preference(key: ResumePromptQAFrameKey.self, value: [key: proxy.frame(in: .global)])
            })
        } else { self }
        #else
        self
        #endif
    }
}

/// Transient viewing state. Scope leases follow the existing viewer lifecycle;
/// only the foremost visible deck can toggle, and leaving it restores navigation.
@MainActor final class ViewingChromeController: ObservableObject {
    private struct Scope {
        let id: UUID
        let inline: Bool
    }

    static let shared = ViewingChromeController()
    @Published private(set) var hidden = false
    @Published private(set) var activeScope: UUID?
    @Published private var scopes: [Scope] = []
    private var overlays = Set<UUID>()
    @Published private var departingRailScope: UUID?
    var isSuspended: Bool { !overlays.isEmpty }
    // Full-screen players own the theme of their own presentation.
    var hasInlinePlayer: Bool { scopes.last?.inline == true }
    #if DEBUG && targetEnvironment(simulator)
    @Published private(set) var qaToggleCount = 0
    #endif
    func begin(_ scope: UUID, inline: Bool) {
        guard !scopes.contains(where: { $0.id == scope }) else { return }
        scopes.append(.init(id: scope, inline: inline)); activeScope = overlays.isEmpty ? scope : nil; hidden = false
    }
    func end(_ scope: UUID) {
        guard let index = scopes.firstIndex(where: { $0.id == scope }) else { return }
        let wasForemost = activeScope == scope
        scopes.remove(at: index)
        if departingRailScope == scope { departingRailScope = nil }
        if wasForemost { activeScope = scopes.last?.id; hidden = false }
    }
    func endInlinePlayer() {
        if let scope = scopes.last, scope.inline { end(scope.id) }
    }
    func suspend(for overlay: UUID) {
        guard overlays.insert(overlay).inserted else { return }
        activeScope = nil; hidden = false
    }
    func resume(after overlay: UUID) {
        guard overlays.remove(overlay) != nil else { return }
        activeScope = overlays.isEmpty ? scopes.last?.id : nil; hidden = false
    }
    func toggle(_ scope: UUID) {
        guard activeScope == scope else { return }
        hidden.toggle()
        #if DEBUG && targetEnvironment(simulator)
        qaToggleCount += 1
        #endif
    }
    func reveal() { hidden = false }
    func isHidden(for scope: UUID) -> Bool { activeScope == scope && hidden }
    func showsRail(for scope: UUID) -> Bool {
        departingRailScope != scope && !isSuspended && scopes.contains(where: { $0.id == scope })
    }
    func prepareRailDeparture() {
        departingRailScope = activeScope
    }
    func cancelRailDeparture() {
        departingRailScope = nil
    }
}

let playbackRailFadeDuration = 0.10
let playbackRailFade = Animation.easeInOut(duration: playbackRailFadeDuration)

private struct ViewingChromeBottomExclusionKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}
private struct MediaContinuationFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
private struct ViewingChromeToggleKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
private struct PlaybackControlsBottomInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
/// A shared floating-control baseline. It positions overlays without reducing
/// the media canvas, including full-screen entries which have no visible tabs.
private struct ViewingControlsReferenceInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
private struct MediaActionHitFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}
extension EnvironmentValues {
    var viewingControlsReferenceInset: CGFloat {
        get { self[ViewingControlsReferenceInsetKey.self] }
        set { self[ViewingControlsReferenceInsetKey.self] = newValue }
    }
    var playbackControlsBottomInset: CGFloat {
        get { self[PlaybackControlsBottomInsetKey.self] }
        set { self[PlaybackControlsBottomInsetKey.self] = newValue }
    }
    var viewingChromeBottomExclusion: CGFloat? {
        get { self[ViewingChromeBottomExclusionKey.self] }
        set { self[ViewingChromeBottomExclusionKey.self] = newValue }
    }
    var viewingChromeToggle: (() -> Void)? {
        get { self[ViewingChromeToggleKey.self] }
        set { self[ViewingChromeToggleKey.self] = newValue }
    }
}
extension View {
    /// Keep the subtree and its playback identity in place while hiding chrome.
    func viewingChromeHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
    func playbackRailInsets(bottomBarHeight: CGFloat, compactHeight: Bool) -> some View {
        padding(.trailing, PlaybackChrome.railHitInset)
            .padding(.bottom, compactHeight ? 12 : bottomBarHeight + 92)
    }

    fileprivate func mediaActionHitFrame(in space: Namespace.ID) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: MediaActionHitFramesKey.self, value: [geometry.frame(in: .named(space))])
        })
    }
}

enum MediaDisplayType: Equatable {
    case image
    case video
}

private extension View {
    @ViewBuilder func mediaControlQAFrame(_ key: String) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled || CollectionPagingQA.enabled || PlaybackLayoutQA.enabled {
            background(GeometryReader { geometry in
                Color.clear.preference(key: CollectionPagingQAFrameKey.self, value: [key: geometry.frame(in: .global)])
                    .preference(key: PlaybackLayoutQAFrameKey.self, value: [key: geometry.frame(in: .global)])
            })
        } else { self }
        #else
        self
        #endif
    }
}

/// Keep the visible mark smaller than its 44-point touch target.
struct MediaIconActionLabel: View {
    let title: String
    let symbol: String
    let qaKey: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white.opacity(0.94))
            .mediaControlQAFrame(qaKey + ".icon")
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .mediaControlQAFrame(qaKey).accessibilityLabel(title)
    }
}

/// Pagination feedback shared by the deck and media grids.
struct FeedContinuationStatusView: View {
    let state: FeedContinuationState
    var empty = false
    var darkCanvas = false
    @Environment(\.colorScheme) private var colorScheme
    var performing = false
    var restartRetryAvailableAt: Date? = nil
    let retry: () -> Void
    var restart: (() -> Void)? = nil

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(spacing: 8) {
                switch state {
                case .loading, .scanning:
                    loadingIndicator
                case .ended:
                    Text(empty ? "没有符合条件的作品" : "已经看到最后啦")
                        .accessibilityIdentifier("feed.continuation.ended")
                case .failed(let failure):
                    Text(failure.requiresRestart ? "分页加载停滞" : "加载失败")
                        .accessibilityIdentifier("feed.continuation.error")
                    Text(failure.message).lineLimit(3)
                    if failure.requiresRestart {
                        if let restart {
                            StatusReloadButton(title: "重新加载", action: restart)
                                .disabled(performing || (restartRetryAvailableAt.map { $0 > context.date } ?? false))
                                .accessibilityIdentifier("feed.continuation.restart")
                        }
                    } else {
                        StatusReloadButton(action: retry)
                            .disabled(performing || (failure.retryAvailableAt.map { $0 > context.date } ?? false))
                            .accessibilityIdentifier("feed.continuation.retry")
                    }
                case .ready:
                    if empty { loadingIndicator }
                }
            }
            .font(.caption).multilineTextAlignment(.center)
            .foregroundStyle(darkCanvas ? Color.white : Color.primary)
            .environment(\.colorScheme, darkCanvas ? .dark : colorScheme)
            .tint(darkCanvas ? .white : .accentColor)
            .shadow(color: darkCanvas ? .black.opacity(0.75) : .clear, radius: 2, y: 1)
            .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadingIndicator: some View {
        ProgressView().controlSize(.small)
            .accessibilityLabel("正在查找作品")
            .accessibilityIdentifier("feed.continuation.loading")
    }
}

/// Owns the appearance of a presented player and of its ordinary author page.
/// Each entry still supplies its own playback queue, controls and lifecycle.
struct PlaybackStatusBarScrim: View {
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.safeAreaInsets.top
            if height > 0 {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.78), location: 0),
                    .init(color: .black.opacity(0.54), location: height / (height + 12)),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: height + 12)
                .offset(y: -height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PlaybackNavigation<Content: View>: View {
    @Binding var creator: CreatorRoute?
    @ViewBuilder let content: (@escaping (CreatorRoute) -> Void) -> Content
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var exitToTab
    @ObservedObject private var chrome = ViewingChromeController.shared
    @StateObject private var favoriteSelectionBar = FavoriteSelectionBar()
    @State private var authorHeaderRoute = NativeHeaderRoute()

    var body: some View {
        NavigationStack {
            content(openAuthor)
                .nativeHeaderRouteBoundary(authorHeaderRoute, isPresented: false)
                .navigationDestination(item: $creator) { route in
                    CreatorView(creator: route.creator, initialKind: route.kind)
                        .nativeHeaderRouteBoundary(authorHeaderRoute, isPresented: true)
                        .environment(\.favoriteSelectionBar, exitToTab == nil ? nil : favoriteSelectionBar)
                        .environment(\.overlaidTabBarHeight, exitToTab == nil ? 0 : (tabs?.height ?? 0))
                }
        }
        .overlay(alignment: .top) {
            if creator == nil { PlaybackStatusBarScrim() }
        }
        .overlay(alignment: .bottom) {
            PlaybackTabsBar(overMedia: creator == nil, hidden: creator == nil && chrome.hidden,
                            selection: creator == nil ? nil : favoriteSelectionBar.entry)
        }
        .preferredColorScheme(creator == nil ? .dark : ordinaryScheme)
        .onChange(of: creator != nil) { _, showsCreator in
            if showsCreator { chrome.prepareRailDeparture() }
            else {
                authorHeaderRoute.dismissed(animate: false)
                chrome.cancelRailDeparture()
            }
        }
    }

    private func openAuthor(_ route: CreatorRoute) {
        authorHeaderRoute.preparePresentation()
        creator = route
    }
}

struct PlaybackTabsBar: View {
    var overMedia = true
    var hidden = false
    var identifier = "playback.tabs"
    var selection: FavoriteSelectionBar.Entry? = nil
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @State private var tone: PageToneTransition?
    @Environment(\.exitMediaCoverToTab) private var exitToTab

    var body: some View {
        if let tabs, let exitToTab {
            tabs.render(overMedia, identifier, selection, tone) { id in
                exitToTab(MediaTabExit(id: id, fromMedia: overMedia))
            }
                .viewingChromeHidden(hidden)
                .onChange(of: overMedia) { previous, _ in
                    tone = ordinaryScheme == .light
                        ? PageToneTransition(source: previous ? .black : AppTheme.pageBackground(for: ordinaryScheme))
                        : nil
                }
        }
    }
}

struct PlaybackShareButton: View {
    let workID: Int?

    var body: some View {
        if let workID, workID > 0,
           let url = URL(string: SiteSession.origin + "/images/\(workID)") {
            ShareLink(item: url) { FloatingPageIcon(symbol: "square.and.arrow.up") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("分享作品")
                .accessibilityIdentifier("playback.share")
        }
    }
}

struct PlaybackCloseButton: View {
    var label = "关闭作品"
    var identifier = "playback.close"
    let action: () -> Void

    var body: some View {
        Button(action: action) { FloatingPageIcon(symbol: "xmark") }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    func playbackTitleBar<Actions: View>(
        _ title: String, workID: Int?, hidden: Bool = false,
        closeLabel: String = "关闭作品", closeIdentifier: String = "playback.close",
        onClose: @escaping () -> Void,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) -> some View {
        floatingTitleBar(title, overMedia: true, hidden: hidden) {
            PlaybackCloseButton(label: closeLabel, identifier: closeIdentifier) {
                ViewingChromeController.shared.prepareRailDeparture()
                onClose()
            }
        } actions: {
            PlaybackShareButton(workID: workID)
            actions()
        }
    }
}

struct FeedMediaViewer: View {
    let items: [MediaItem]
    @Binding var focused: Int?
    let initialID: Int
    var focusRequest = 0
    var queueRevision = 0
    var playbackSuspended = false
    var automaticLoadingAllowed = true
    var continuationState: FeedContinuationState? = nil
    var loadMoreAutomatically: (() async -> Void)? = nil
    var refreshFromStart: (() async -> Void)? = nil
    var restartRetryAvailableAt: Date? = nil
    var historyCheckpoint: ((MediaItem) -> TimelineCheckpoint?)? = nil
    var resumePositions: [Int: Double] = [:]
    var onDetailsVisibility: ((Bool) -> Void)? = nil
    var title = "作品"
    var onEdgeSwipe: MediaEdgeSwipeAction? = nil
    var onOpenAuthor: ((CreatorRoute) -> Void)? = nil
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var exitToTab
    let onClose: () -> Void
    let loadMore: () async -> Void
    @State private var creator: CreatorRoute?
    @ObservedObject private var chrome = ViewingChromeController.shared

    var body: some View {
        PlaybackNavigation(creator: $creator) { openAuthor in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                MediaDeck(items: items, focused: $focused, focusRequest: focusRequest, queueRevision: queueRevision,
                          playbackSuspended: playbackSuspended, automaticLoadingAllowed: automaticLoadingAllowed, initialID: initialID,
                          continuationState: continuationState, loadMoreAutomatically: loadMoreAutomatically,
                          refreshFromStart: refreshFromStart, restartRetryAvailableAt: restartRetryAvailableAt,
                          bottomBarInset: exitToTab == nil ? nil : tabs?.height,
                          onEdgeSwipe: onEdgeSwipe, onAuthor: { route in
                              if let onOpenAuthor { onOpenAuthor(route) }
                              else { openAuthor(route) }
                          }, onDetailsVisibility: onDetailsVisibility,
                          historyCheckpoint: historyCheckpoint, resumePositions: resumePositions,
                          loadMore: loadMore)
            }
            .tint(.white)
            .playbackTitleBar(title, workID: items.first(where: { $0.id == focused })?.id,
                              hidden: chrome.hidden, onClose: onClose)
        }.environment(\.overlaidTabBarHeight, 0)
    }
}

@MainActor
final class MediaDeckPresentationLease: ObservableObject {
    @Published var railHasAppeared = false
    let chrome = UUID()
    let details = UUID()

    deinit {
        let details = details
        Task { @MainActor in
            ViewingChromeController.shared.resume(after: details)
        }
    }
}

struct MediaDeck: View {
    let items: [MediaItem]
    @Binding var focused: Int?
    var focusRequest = 0
    var queueRevision = 0
    var playbackSuspended = false
    var automaticLoadingAllowed = true
    var loadsPageOnAppearance = true
    var initialID: Int? = nil
    var isVisible = true
    var coveredByNavigation = false
    var showsLoadMore = true
    var continuationState: FeedContinuationState? = nil
    var loadMoreAutomatically: (() async -> Void)? = nil
    var refreshFromStart: (() async -> Void)? = nil
    var restartRetryAvailableAt: Date? = nil
    var bottomBarInset: CGFloat? = nil
    var inlinePlayback = false
    var continuationTopInset: CGFloat = 0
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var onEdgeSwipe: MediaEdgeSwipeAction? = nil
    var onEdgeDrag: MediaEdgeDragAction? = nil
    let onAuthor: (CreatorRoute) -> Void
    var onDetailsVisibility: ((Bool) -> Void)? = nil
    var historyCheckpoint: ((MediaItem) -> TimelineCheckpoint?)? = nil
    var resumePositions: [Int: Double] = [:]
    var endAction: (() -> Void)? = nil
    let loadMore: () async -> Void
    @EnvironmentObject private var session: SiteSession
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var exitToTab
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocks = AuthorBlocklist.shared
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var chrome = ViewingChromeController.shared
    @StateObject private var preloader = MediaPreloader()
    @AppStorage("wifiVideoPrefetch") private var wifiVideoPrefetch = true
    @AppStorage("mediaPrefetchCount") private var mediaPrefetchCount = 6
    @AppStorage(MediaPrefetchConcurrency.defaultsKey) private var mediaPrefetchConcurrency = MediaPrefetchConcurrency.defaultValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var advance = PlaybackAdvanceState()
    @State private var boundaryDemand: MediaContinuationIntent?
    @State private var detailsItem: MediaItem?
    @State private var detailsExit: MediaDetailsView.ExitAction?
    @State private var detailTagSnapshot: Set<String>?
    @State private var detailsHeaderCover = NativeHeaderRoute()
    @State private var detailsReturnBlend: UUID?
    @StateObject private var presentationLease = MediaDeckPresentationLease()
    @Environment(\.tabPageMotion) private var tabPageMotion
    @Environment(\.accessibilityReduceMotion) private var reduceRailMotion
    private var chromeScope: UUID { presentationLease.chrome }
    private var detailsChromeScope: UUID { presentationLease.details }
    @State private var pageRecoveryRequest = 0
    @State private var pagedQueueRevision: Int?
    @State private var appeared = false
    @State private var continuationAction: Task<Void, Never>?
    @State private var continuationActionID: UUID?
    @State private var continuationStatusFrame: CGRect = .zero
    @State private var boundaryDragOffset: CGFloat = 0
    @State private var transitionFrames: [URL: UIImage] = [:]
    @State private var transitionFrameContext: String?
    @State private var transitionFrameRevision = 0
    @State private var transitionCacheGeneration: Int?
    @Environment(\.viewingControlsReferenceInset) private var controlsReferenceInset
    private var visibleItems: [MediaItem] { items.filter { !authorBlocks.blocks($0) && TagPolicy.verdict(names: $0.tagNames, blocked: detailTagSnapshot ?? blocklist.names) == .allowed } }
    private var historyContext: HistoryContext? { history.context(ownerID: session.tagLibraryOwnerID) }
    private var viewerVisible: Bool { appeared && isVisible && !session.showLogin }
    private var isCoveredByPage: Bool { detailsItem != nil || coveredByNavigation }
    private var continuationIntentContext: String { "\(session.feedIdentity):\(queueRevision):\(focusRequest)" }
    private var awaitingNextItem: Bool {
        guard let boundaryDemand, let focused else { return false }
        return viewerVisible && scenePhase == .active && !playbackSuspended && detailsItem == nil &&
            boundaryDemand.context == continuationIntentContext &&
            (boundaryDemand.anchorID == focused || boundaryDemand.targetID == focused)
    }
    private struct PrefetchDemand: Equatable {
        let focus: Int?
        let context: String
        let active: Bool
        let count: Int
        let concurrency: Int
        let wifiOnly: Bool
        let window: [MediaItem]
    }
    private var prefetchDemand: PrefetchDemand {
        let index = focused.flatMap { id in visibleItems.firstIndex(where: { $0.id == id }) }
        let count = [3, 6, 10].contains(mediaPrefetchCount) ? mediaPrefetchCount : 6
        let concurrency = MediaPrefetchConcurrency.validated(mediaPrefetchConcurrency)
        let window = index.map { Array(visibleItems.dropFirst($0).prefix(count + 1)) } ?? []
        return PrefetchDemand(focus: focused, context: "\(session.feedIdentity):\(queueRevision)",
            active: viewerVisible && scenePhase == .active && !playbackSuspended,
            count: count, concurrency: concurrency, wifiOnly: wifiVideoPrefetch, window: window)
    }

    private struct TransitionFramePlan: Equatable {
        let context: String
        let current: URL?
        let neighbors: [URL]
    }
    private struct TransitionFrameDemand: Equatable {
        let plan: TransitionFramePlan?
        let revision: Int
    }
    private var frameContext: String { "\(session.feedIdentity):\(queueRevision)" }
    private var transitionFramePlan: TransitionFramePlan? {
        guard viewerVisible, scenePhase == .active, !playbackSuspended, detailsItem == nil else { return nil }
        let works = visibleItems
        guard let index = works.firstIndex(where: { $0.id == focused }) else { return nil }
        func videoURL(at index: Int) -> URL? {
            guard works.indices.contains(index), works[index].isVideo,
                  (resumePositions[works[index].id] ?? 0) <= 0 else { return nil }
            return works[index].mediaURL
        }
        // The closest pages in the native pager matter first. Keep only
        // nearby frame images and decode one at a time from cached files.
        return .init(context: frameContext, current: videoURL(at: index),
                     neighbors: [index + 1, index - 1, index + 2].compactMap(videoURL(at:)))
    }
    private func prepareTransitionFrames(_ plan: TransitionFramePlan?) async {
        guard !Task.isCancelled else { return }
        if transitionFrameContext != plan?.context {
            transitionFrames = [:]
            transitionFrameContext = plan?.context
        }
        guard let plan else { return }
        let retained = Set(plan.neighbors + [plan.current].compactMap { $0 })
        transitionFrames = transitionFrames.filter { retained.contains($0.key) }
        for url in plan.neighbors where transitionFrames[url] == nil {
            guard !Task.isCancelled else { return }
            let frame = await MediaCache.shared.transitionFrame(for: url)
            guard !Task.isCancelled, plan.context == frameContext else { return }
            if let frame { transitionFrames[url] = frame }
        }
    }

    var body: some View {
        GeometryReader { safeViewport in
            deck(topInset: safeViewport.safeAreaInsets.top, bottomInset: safeViewport.safeAreaInsets.bottom)
                .ignoresSafeArea(.container, edges: .vertical)
        }
    }

    private func deck(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let framePlan = transitionFramePlan
        return GeometryReader { geometry in
            NativeMediaPager(ids: pageIDs, focused: $focused, initialID: initialID,
                             focusRequest: focusRequest &+ pageRecoveryRequest, queueRevision: queueRevision,
                             viewport: geometry.size,
                             accessibilityIdentifier: historyCheckpoint == nil ? "media.viewer.deck" : "timeline.media.deck",
                             isVisible: viewerVisible && scenePhase == .active,
                             onUserPageSettled: { id in
                pagedQueueRevision = queueRevision
                if let demand = boundaryDemand, demand.anchorID != id && demand.targetID != id { boundaryDemand = nil }
            }, onUserContinuationDemand: { id in
                guard showsLoadMore, continuationState != .ended,
                      continuationState?.isLoading != true, continuationState?.requiresRestart != true else { return }
                startContinuationAction(loadMore)
            }, onUserBoundaryDemand: { id in
                if showsLoadMore, !playbackSuspended, id == focused {
                    // The native pager owns the settled tail. A response can
                    // already be in SwiftUI while its native queue waits for this
                    // gesture to finish, so resolve an available next ID too.
                    boundaryDemand = .init(anchorID: id, context: continuationIntentContext)
                    resolveBoundaryDemand()
                }
            }, boundaryWaiting: awaitingNextItem, onUserBoundaryCancel: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { cancelBoundaryDemand() }
            }, onBoundaryDrag: { offset, phase in
                switch phase {
                case .began, .changed:
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { boundaryDragOffset = offset }
                case .ended, .cancelled:
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { boundaryDragOffset = 0 }
                }
            }, onPageDisplayed: { id in
                if let demand = boundaryDemand, demand.context == continuationIntentContext,
                   demand.targetID == id, focused == id, awaitingNextItem { boundaryDemand = nil }
            }) { id, settled in
                let content = page(id: id, settled: settled, size: geometry.size, topInset: topInset)
                    // Move rendered content inside its stable native host. The
                    // pager's hit-test viewport and internal queue stay in place.
                    .offset(y: awaitingNextItem ? max(0, boundaryDragOffset) - geometry.size.height : boundaryDragOffset)
                    .allowsHitTesting(!awaitingNextItem).accessibilityHidden(awaitingNextItem)
                    .environmentObject(session).environmentObject(session.oauth)
                    .environment(\.ordinaryColorScheme, ordinaryScheme)
                    .environment(\.mediaTabs, tabs)
                    .environment(\.exitMediaCoverToTab, exitToTab)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.verticalSizeClass, verticalSizeClass)
                    .environment(\.playbackControlsBottomInset, (bottomBarInset ?? controlsReferenceInset) + bottomInset)
                    .environment(\.colorScheme, .dark)
                #if DEBUG && targetEnvironment(simulator)
                if ResumePromptQA.enabled { return AnyView(content.defaultAppStorage(ResumePromptQA.defaults)) }
                #endif
                return AnyView(content)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: "\(focused ?? -1):\(viewerVisible && scenePhase == .active):\(playbackSuspended):\(automaticLoadingAllowed):\(queueRevision):\(pagedQueueRevision.map(String.init) ?? "nil")") {
                guard viewerVisible, scenePhase == .active, !playbackSuspended, automaticLoadingAllowed,
                      let id = focused, let index = visibleItems.firstIndex(where: { $0.id == id }) else { return }
                if loadsPageOnAppearance || pagedQueueRevision == queueRevision,
                   showsLoadMore, continuationState == nil || continuationState == .ready,
                   index >= visibleItems.count - (prefetchDemand.count + 1) { await (loadMoreAutomatically ?? loadMore)() }
            }
            .task(id: prefetchDemand) {
                guard !Task.isCancelled else { return }
                guard viewerVisible, scenePhase == .active, !playbackSuspended,
                      let id = focused, let index = visibleItems.firstIndex(where: { $0.id == id }) else { preloader.stop(); return }
                preloader.update(visibleItems, after: index, count: prefetchDemand.count,
                    context: prefetchDemand.context, wifiOnly: wifiVideoPrefetch,
                    concurrency: prefetchDemand.concurrency)
            }
            .task(id: TransitionFrameDemand(plan: framePlan, revision: transitionFrameRevision)) {
                await prepareTransitionFrames(framePlan)
            }
            .onReceive(MediaCache.shared.videoPreloadUpdates) { url in
                if framePlan?.neighbors.contains(url) == true && transitionFrames[url] == nil {
                    transitionFrameRevision &+= 1
                }
            }
            .onReceive(MediaCache.shared.prefetchInvalidations) { generation in
                guard transitionCacheGeneration != generation else { return }
                transitionCacheGeneration = generation
                transitionFrames = [:]
                transitionFrameRevision &+= 1
            }
            .onChange(of: visibleItems) { previous, current in
                resolveBoundaryDemand()
                if current.isEmpty { revealFallbackControls() }
                let target = MediaFocusPolicy.target(current: focused, previousItems: previous, items: current)
                if target != focused { focused = target }
            }
            .onChange(of: focused) { _, id in
                if let demand = boundaryDemand, demand.anchorID != id && demand.targetID != id { boundaryDemand = nil }
                advance.focusChanged(id)
                if let id, id < 0, viewerVisible, chrome.activeScope == chromeScope { chrome.reveal() }
            }
            .onChange(of: queueRevision) { _, _ in
                advance = PlaybackAdvanceState(); boundaryDemand = nil
            }
            .onChange(of: focusRequest) { _, _ in boundaryDemand = nil }
            .onChange(of: playbackSuspended) { _, value in if value { cancelBoundaryDemand() } }
            .onChange(of: continuationState) { previous, value in
                resolveBoundaryDemand()
                if viewerVisible, value?.failure != nil, previous?.failure == nil { chrome.reveal() }
            }
            .onChange(of: awaitingNextItem) { _, waiting in
                if !waiting { boundaryDragOffset = 0 }
            }
        }.clipped().background(.black)
            .overlay {
                if awaitingNextItem {
                    ZStack {
                        Color.black.allowsHitTesting(false)
                        if let state = continuationState, state.failure != nil || state == .ended {
                            FeedContinuationStatusView(state: state, empty: true, darkCanvas: true,
                                performing: continuationAction != nil, restartRetryAvailableAt: restartRetryAvailableAt,
                                retry: { startContinuationAction(loadMore) },
                                restart: refreshFromStart.map { action in { startContinuationAction(action) } })
                                .padding(.horizontal, 28)
                        } else {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(.white.opacity(0.8))
                                    .dynamicTypeSize(.medium).frame(width: 20, height: 20)
                                    .accessibilityIdentifier("media.boundary.waiting")
                                Text("正在加载…").font(.caption).foregroundStyle(.white.opacity(0.7))
                                    .accessibilityIdentifier("media.boundary.message")
                            }.allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("media.boundary.state")
                    .offset(y: boundaryDragOffset)
                }
            }
            .clipped()
            .overlay {
                if viewerVisible && visibleItems.isEmpty {
                    VStack(spacing: 14) {
                        if let state = continuationState, state.isLoading || state.failure != nil || state == .ended {
                            FeedContinuationStatusView(state: state, empty: true, darkCanvas: true,
                                performing: continuationAction != nil, restartRetryAvailableAt: restartRetryAvailableAt,
                                retry: { startContinuationAction(loadMore) },
                                restart: refreshFromStart.map { action in { startContinuationAction(action) } })
                        } else {
                            Text("当前没有可展示的作品").font(.callout)
                                .accessibilityIdentifier("media.empty.message")
                            if showsLoadMore {
                                StatusReloadButton(title: "继续查找") { startContinuationAction(loadMore) }
                                    .environment(\.colorScheme, .dark)
                                    .disabled(continuationAction != nil)
                                    .accessibilityIdentifier("media.empty.continue")
                            }
                        }
                    }
                    .foregroundStyle(.white).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("media.empty.state")
                    .onAppear {
                        revealFallbackControls()
                        LocalDiagnosticsStore.shared.note(area: .lifecycle, code: .emptyMediaViewport,
                            count: min(items.count, 1_000_000))
                    }
                }
            }
            .overlay(alignment: .top) {
                if showsLoadMore, let state = continuationState, viewerVisible, !visibleItems.isEmpty, !awaitingNextItem,
                   !state.isLoading,
                   (focused == visibleItems.last?.id || state.failure != nil),
                   !chrome.isHidden(for: chromeScope) {
                    FeedContinuationStatusView(state: state, empty: false, darkCanvas: true,
                        performing: continuationAction != nil, restartRetryAvailableAt: restartRetryAvailableAt,
                        retry: { startContinuationAction(loadMore) },
                        restart: refreshFromStart.map { action in { startContinuationAction(action) } })
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: MediaContinuationFrameKey.self,
                                                   value: proxy.frame(in: .named(chromeScope)))
                        })
                        .padding(.horizontal, 60).padding(.top, topInset + continuationTopInset + 8)
                }
            }
            .coordinateSpace(name: chromeScope)
            .onPreferenceChange(MediaContinuationFrameKey.self) { continuationStatusFrame = $0 }
            #if DEBUG && targetEnvironment(simulator)
            .modifier(CollectionPagingQAObserver(focused: focused))
            .overlay(alignment: .topTrailing) {
                if (CollectionPagingQA.enabled || PlaybackLayoutQA.enabled) && viewerVisible {
                    let state = "hidden=\(chrome.isHidden(for: chromeScope));toggles=\(chrome.qaToggleCount);scope=\(chromeScope.uuidString)"
                    Text(state).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("media.qa.chrome").accessibilityValue(state)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if CollectionPagingQA.enabled && viewerVisible {
                    MediaPreloadQAReadback(preloader: preloader, pagingAllowed: automaticLoadingAllowed)
                    Text("frames=\(transitionFrames.count)")
                        .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("media.qa.transition-frames").accessibilityValue("frames=\(transitionFrames.count)")
                }
            }
            #endif
            .overlay {
                if let detailsReturnBlend {
                    PageToneBlend(source: AppTheme.pageBackground(for: ordinaryScheme)) {
                        if self.detailsReturnBlend == detailsReturnBlend { self.detailsReturnBlend = nil }
                    }
                    .id(detailsReturnBlend)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .nativeHeaderRouteBoundary(detailsHeaderCover, isPresented: false)
            .background {
                // Scope the modal transaction to its presenter so the player
                // and the shared header keep their own animations.
                Color.clear
                    .fullScreenCover(item: $detailsItem, onDismiss: finishDetails) { item in
                        detailsPage(item)
                    }
                    .transaction {
                        $0.animation = nil
                        $0.disablesAnimations = true
                    }
            }
            .onAppear { appeared = true; syncViewingChrome() }
            .onChange(of: isVisible) { _, value in
                if !value { cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop() }
                syncViewingChrome()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop() }
                syncViewingChrome()
            }
            .onChange(of: session.showLogin) { _, shown in
                if shown { cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop() }
                syncViewingChrome()
            }
            .onChange(of: detailsItem) { _, item in
                if item != nil { cancelBoundaryDemand(); chrome.suspend(for: detailsChromeScope) }
                else { chrome.resume(after: detailsChromeScope) }
            }
            .onDisappear {
                appeared = false
                cancelBoundaryDemand()
                cancelContinuationAction()
                preloader.stop()
                chrome.end(chromeScope)
                if !isCoveredByPage {
                    chrome.resume(after: detailsChromeScope)
                }
            }
    }

    private func detailsPage(_ item: MediaItem) -> some View {
        MediaDetailsView(item: item, onClose: closeDetails)
            .nativeHeaderRouteBoundary(detailsHeaderCover, isPresented: true)
    }

    private func closeDetails(_ action: MediaDetailsView.ExitAction?) {
        guard detailsItem != nil else { return }
        if case .tab(let exit) = action {
            // All covers unwind in the same selection transaction, so an
            // intermediate player or grid never becomes the destination.
            withoutPageAnimation {
                detailsHeaderCover.dismissed(animate: false)
                clearDetailsPresentation()
                (exitToTab ?? tabs?.select)?(exit)
                detailsItem = nil
            }
        } else {
            detailsExit = action
            detailsHeaderCover.prepareDismissal()
            withoutPageAnimation {
                if action == nil, ordinaryScheme == .light, !reduceRailMotion {
                    detailsReturnBlend = UUID()
                }
                detailsItem = nil
            }
        }
    }

    private func finishDetails() {
        guard detailTagSnapshot != nil else { return }
        detailsHeaderCover.dismissed(animate: detailsExit == nil)
        clearDetailsPresentation()
        let action = detailsExit; detailsExit = nil
        switch action {
        case .author(let route): onAuthor(route)
        case .signIn: session.openLogin()
        case .tab, nil: break
        }
    }

    private func clearDetailsPresentation() {
        detailTagSnapshot = nil
        onDetailsVisibility?(false)
        chrome.resume(after: detailsChromeScope)
    }

    private func resolveBoundaryDemand() {
        guard let demand = boundaryDemand else { return }
        let active = viewerVisible && scenePhase == .active && !playbackSuspended && detailsItem == nil
        let ids = visibleItems.map(\.id)
        guard active, demand.context == continuationIntentContext, let current = focused,
              current == demand.anchorID || current == demand.targetID,
              ids.contains(demand.anchorID) else { boundaryDemand = nil; return }
        if let target = demand.targetID {
            if !ids.contains(target) { boundaryDemand = nil }
            return
        }
        if let target = demand.target(focused: focused, ids: ids, context: continuationIntentContext, active: active) {
            if demand.cause == .failedPlayback,
               advance.target(failedID: demand.anchorID, focused: focused, ids: ids, active: active) == nil {
                boundaryDemand = nil
                return
            }
            var pending = demand
            pending.targetID = target
            boundaryDemand = pending
            focused = target
        }
    }

    private func cancelBoundaryDemand() {
        if let demand = boundaryDemand, let target = demand.targetID, demand.context == continuationIntentContext,
           target == focused, visibleItems.contains(where: { $0.id == demand.anchorID }) {
            focused = demand.anchorID
        }
        boundaryDemand = nil
        boundaryDragOffset = 0
    }

    private func startContinuationAction(_ action: @escaping () async -> Void) {
        guard continuationAction == nil, viewerVisible, scenePhase == .active, !playbackSuspended else { return }
        let owner = UUID(); continuationActionID = owner
        continuationAction = Task {
            await action()
            guard continuationActionID == owner else { return }
            continuationAction = nil; continuationActionID = nil
        }
    }
    private func cancelContinuationAction() {
        continuationAction?.cancel(); continuationAction = nil; continuationActionID = nil
    }

    private func revealFallbackControls() {
        guard viewerVisible, scenePhase == .active, chrome.activeScope == chromeScope else { return }
        chrome.reveal()
    }
    private func syncViewingChrome() {
        // Playback and loading still stop offscreen. Keep the mounted viewer's
        // appearance so the system captures it without ordinary page backgrounds.
        if viewerVisible {
            chrome.begin(chromeScope, inline: inlinePlayback)
            if visibleItems.isEmpty { revealFallbackControls() }
        } else { chrome.end(chromeScope) }
    }

    private var pageIDs: [Int] {
        guard !visibleItems.isEmpty else { return [] }
        return visibleItems.map(\.id) + (endAction == nil ? [] : [-2])
    }

    @ViewBuilder private func page(id: Int, settled: Bool, size: CGSize, topInset: CGFloat) -> some View {
        if let item = visibleItems.first(where: { $0.id == id }) {
            let allowsTransitionPreview = viewerVisible && scenePhase == .active && !playbackSuspended && detailsItem == nil
            let warmFrame = transitionFrameContext == frameContext && allowsTransitionPreview
                ? item.mediaURL.flatMap { transitionFrames[$0] } : nil
            MediaPageView(item: item, active: settled && (focused == item.id || (awaitingNextItem && boundaryDemand?.anchorID == item.id)) && viewerVisible && !playbackSuspended && scenePhase == .active,
                          transitionFrame: warmFrame,
                          usesTransitionPreview: allowsTransitionPreview && (!settled || pagedQueueRevision == queueRevision || boundaryDemand?.targetID == id),
                          chromeScope: chromeScope, inlinePlayback: inlinePlayback,
                          presentationLease: presentationLease, reduceRailMotion: reduceRailMotion,
                          onToggleChrome: { chrome.toggle(chromeScope) },
                          gestureTopExclusion: topInset + gestureTopExclusion,
                          gestureExcludedFrames: gestureExcludedFrames.map { $0.offsetBy(dx: 0, dy: topInset) } +
                              (continuationStatusFrame.isEmpty ? [] : [continuationStatusFrame]),
                          onEdgeSwipe: onEdgeSwipe, onEdgeDrag: onEdgeDrag, onAuthor: onAuthor, pausedForDetails: detailsItem != nil || awaitingNextItem, onDetails: { value in
                guard detailsItem == nil else { return }
                detailsHeaderCover.preparePresentation()
                detailTagSnapshot = blocklist.names
                onDetailsVisibility?(true)
                withoutPageAnimation { detailsItem = value }
            }, onUnavailable: { id in
                guard viewerVisible, !playbackSuspended, scenePhase == .active, detailsItem == nil,
                      advance.canAdvance(failedID: id, focused: focused, active: true),
                      boundaryDemand?.anchorID != id else { return }
                let ids = visibleItems.map(\.id)
                let hasNext = ids.firstIndex(of: id).map { ids.indices.contains($0 + 1) } ?? false
                guard hasNext || (showsLoadMore && automaticLoadingAllowed) else { return }
                boundaryDemand = .init(anchorID: id, context: continuationIntentContext, cause: .failedPlayback)
                resolveBoundaryDemand()
                if boundaryDemand != nil, continuationState != .ended, continuationState?.isLoading != true,
                   continuationState?.requiresRestart != true {
                    startContinuationAction(loadMoreAutomatically ?? loadMore)
                }
            }, historyContext: historyContext, resumePosition: resumePositions[item.id],
                retainDuringInterruption: (focused == item.id || boundaryDemand?.anchorID == item.id) && (isVisible || isCoveredByPage),
                onQualifiedExposure: { item, context in
                history.record(item, context: context, checkpoint: historyCheckpoint?(item))
            }).id("\(item.id):queue:\(queueRevision)")
                .environment(\.tabPageMotion, tabPageMotion)
                .frame(width: size.width, height: size.height).clipped()
                .resumePromptQAFrame("page-\(item.id)")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("media-page-\(item.id)")
        } else if id == -2, let endAction {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle").font(.largeTitle)
                Text("已看完这段浏览记录").font(.headline)
                Button("加载当前最新内容", action: endAction).buttonStyle(.borderedProminent)
            }.foregroundStyle(.white).frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: 12) {
                Text("作品列表已更新").font(.callout)
                if let next = visibleItems.first {
                    Button("返回当前作品") { focused = next.id; pageRecoveryRequest &+= 1 }
                        .buttonStyle(AppActionButtonStyle(tone: .neutral))
                }
            }.foregroundStyle(.white).frame(width: size.width, height: size.height)
                .accessibilityIdentifier("media.page.updated")
                .onAppear { revealFallbackControls() }
        }
    }

}

enum MediaRailAction: String, CaseIterable {
    case favorite, details, mute, cleanImage, rotate

    static let defaultsKey = "mediaRailOrder"
    static let hiddenDefaultsKey = "mediaRailHiddenActions"

    static func ordered(_ rawValue: String) -> [Self] {
        var saved = parsed(rawValue)
        // Older custom orders have a video-only slot but no image counterpart.
        if !saved.contains(.cleanImage), let muteIndex = saved.firstIndex(of: .mute) {
            saved.insert(.cleanImage, at: muteIndex + 1)
        }
        var seen = Set<Self>()
        return (saved + allCases).filter { seen.insert($0).inserted }
    }

    static func hidden(_ rawValue: String) -> Set<Self> { Set(parsed(rawValue)) }

    private static func parsed(_ rawValue: String) -> [Self] {
        rawValue.split(separator: ",").compactMap { Self(rawValue: String($0)) }
    }

    var title: String {
        switch self {
        case .favorite: "收藏"
        case .details: "作品详情"
        case .mute: "静音"
        case .cleanImage: "纯净看图"
        case .rotate: "横竖屏"
        }
    }

    var symbol: String {
        switch self {
        case .favorite: "bookmark"
        case .details: "info.circle"
        case .mute: "speaker.slash.fill"
        case .cleanImage: "arrow.up.left.and.arrow.down.right"
        case .rotate: "rectangle.portrait.rotate"
        }
    }
}

struct MediaPageView: View {
    let item: MediaItem
    let active: Bool
    var transitionFrame: UIImage? = nil
    var usesTransitionPreview = false
    var chromeScope: UUID? = nil
    var inlinePlayback = false
    @ObservedObject var presentationLease: MediaDeckPresentationLease
    var reduceRailMotion: Bool
    var onToggleChrome: (() -> Void)? = nil
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var onEdgeSwipe: MediaEdgeSwipeAction? = nil
    var onEdgeDrag: MediaEdgeDragAction? = nil
    let onAuthor: (CreatorRoute) -> Void
    var pausedForDetails = false
    var onDetails: ((MediaItem) -> Void)? = nil
    var onUnavailable: ((Int) -> Void)? = nil
    var historyContext: HistoryContext? = nil
    var resumePosition: Double? = nil
    var retainDuringInterruption = false
    var onQualifiedExposure: ((MediaItem, HistoryContext) -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var chrome = ViewingChromeController.shared
    @State private var resolvedAuthor: (key: AuthorKey, creator: Creator)?
    @State private var authorLookup: (id: UUID, task: Task<Void, Never>)?
    @State private var failedAuthorKey: AuthorKey?
    @State private var openAuthorOnResolve = false
    @State private var error: String?
    @State private var revealed = false
    @State private var mediaReady = false
    @State private var qualifiedContext: HistoryContext?
    @State private var actualDisplayType: MediaDisplayType?
    @State private var actionHitFrames: [CGRect] = []
    @Namespace private var actionSpace
    @Environment(\.playbackControlsBottomInset) private var bottomBarHeight
    @Environment(\.rotatePlayback) private var rotatePlayback
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compactHeight: Bool { verticalSizeClass == .compact }
    @ScaledMetric(relativeTo: .subheadline) private var captionSize = 14
    @AppStorage(MediaRailAction.defaultsKey) private var railOrder = ""
    @AppStorage(MediaRailAction.hiddenDefaultsKey) private var hiddenRailActions = ""
    private var hiddenActions: Set<MediaRailAction> { MediaRailAction.hidden(hiddenRailActions) }
    private var chromeHidden: Bool { chromeScope.map { chrome.isHidden(for: $0) } ?? false }
    @Environment(\.tabPageMotion) private var tabPageMotion
    private var railVisible: Bool {
        let waitingForTab = inlinePlayback && tabPageMotion?.holdsInlineRail == true
        return !waitingForTab && presentationLease.railHasAppeared
            && (chromeScope.map { chrome.showsRail(for: $0) } ?? true)
    }
    private var chromeAvailable: Bool { chromeScope.map { chrome.activeScope == $0 } ?? false }
    private var displayType: MediaDisplayType { actualDisplayType ?? (item.isVideo ? .video : .image) }
    private var displaysVideo: Bool { displayType == .video }
    private var effectiveItem: MediaItem { item.resolvingMediaType(isVideo: displaysVideo) }
    private var shouldBlur: Bool { (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0) }
    private var canRecord: Bool { active && mediaReady && !pausedForDetails && (!shouldBlur || revealed) }
    private struct ExposureKey: Equatable { let record: Bool; let context: HistoryContext?; let id: Int }
    private struct AuthorKey: Equatable { let itemID: Int; let username: String?; let identity: String }
    private struct AuthorVisibility: Equatable { let key: AuthorKey; let active: Bool }
    private var authorKey: AuthorKey { .init(itemID: item.id, username: item.username, identity: session.feedIdentity) }
    private var authorVisibility: AuthorVisibility { .init(key: authorKey, active: active && !pausedForDetails) }
    private var cachedAuthor: Creator? { resolvedAuthor?.key == authorKey ? resolvedAuthor?.creator : nil }
    private var followAuthor: Creator? { item.attributedCreator ?? cachedAuthor }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            Group {
                if let url = item.mediaURL {
                    if displaysVideo {
                        VideoSurface(url: url, poster: item.posterURL, active: active && (!shouldBlur || revealed), diagnosticWorkID: item.id, diagnosticOffline: item.offlineMediaURL != nil, gesturesActive: active, gestureTopExclusion: chromeHidden ? 0 : gestureTopExclusion, gestureExcludedFrames: chromeHidden ? [] : gestureExcludedFrames + actionHitFrames,
                                     chromeHidden: chromeHidden, onChromeHold: chromeAvailable ? toggleChrome : nil, pausedForOverlay: pausedForDetails, retainDuringInterruption: retainDuringInterruption, mediaBlurred: shouldBlur && !revealed,
                                     onEdgeSwipe: onEdgeSwipe, onEdgeDrag: onEdgeDrag, onDoubleTap: openAuthor,
                                     refreshURL: {
                            if item.offlineMediaURL != nil { return item.mediaURL }
                            let refreshed = try await session.mediaItem(id: item.id)
                            guard let refreshed, TagPolicy.verdict(names: refreshed.tagNames, blocked: TagBlocklist.shared.names) == .allowed else { return nil }
                            return refreshed.mediaURL
                        }, onConfirmedUnavailable: { onUnavailable?(item.id) }, resumePosition: resumePosition,
                                     onProgress: { position, duration, flush in
                            let history = BrowsingHistory.shared
                            guard let context = qualifiedContext ?? historyContext,
                                  HistoryProgressPolicy.allows(qualifiedVisit: qualifiedContext == context,
                                      existingVideo: history.records.contains { $0.id == item.id && $0.kind == .video },
                                      contextIsCurrent: history.accepts(context), recordingEnabled: history.recordingEnabled) else { return }
                            history.progress(id: item.id, position: position, duration: duration, flush: flush, context: context)
                        }, onDisplayReady: { mediaReady = $0 }, onImageContent: { actualDisplayType = .image },
                                     transitionFrame: transitionFrame, usesTransitionPreview: usesTransitionPreview && (!shouldBlur || revealed),
                                     caption: { mediaCaption }, actionRail: { muted in mediaActionRail(muted: muted) })
                    }
                    else {
                        BitmapMediaSurface(url: url, active: active && (!shouldBlur || revealed), gestureTopExclusion: chromeHidden ? 0 : gestureTopExclusion, gestureExcludedFrames: chromeHidden ? [] : gestureExcludedFrames + actionHitFrames, pausedForOverlay: pausedForDetails,
                                           onReady: { mediaReady = $0 }, onVideoContent: confirmVideoContent,
                                           onEdgeSwipe: onEdgeSwipe, onEdgeDrag: onEdgeDrag, onDoubleTap: openAuthor)
                            .blur(radius: shouldBlur && !revealed ? 24 : 0)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle").font(.title2)
                        Text("这条作品暂时无法打开").font(.callout)
                        Text(onDetails != nil && !hiddenActions.contains(.details)
                             ? "媒体地址不可用，可查看详情或切换作品" : "媒体地址不可用，可切换作品")
                            .font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("media.source.unavailable")
                        .onAppear { revealMissingSourceControls() }
                }
            }
            if shouldBlur && !revealed {
                Button { revealed = true } label: { Label("显示这条作品", systemImage: "eye").padding(14).background(.ultraThinMaterial, in: Capsule()) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).viewingChromeHidden(chromeHidden)
            }
            if !displaysVideo || item.mediaURL == nil {
                mediaCaption
                    .padding(.leading, PlaybackChrome.horizontalInset)
                    .padding(.trailing, 72)
                    .padding(.bottom, bottomBarHeight + 8)
                    .viewingChromeHidden(chromeHidden)
            }
        }
        .overlay(alignment: compactHeight ? .trailing : .bottomTrailing) {
            if !displaysVideo || item.mediaURL == nil {
                mediaActionRail()
                    .playbackRailInsets(bottomBarHeight: bottomBarHeight, compactHeight: compactHeight)
                    .viewingChromeHidden(chromeHidden)
            }
        }
        .clipped()
        .coordinateSpace(name: actionSpace)
        .onPreferenceChange(MediaActionHitFramesKey.self) { actionHitFrames = $0 }
        .environment(\.viewingChromeToggle, chromeAvailable && active && !pausedForDetails ? toggleChrome : nil)
        .environment(\.viewingChromeBottomExclusion, chromeHidden ? 0 : (displaysVideo ? nil : bottomBarHeight + 8))
        .task(id: ExposureKey(record: canRecord, context: historyContext, id: item.id)) {
            guard canRecord, let context = historyContext else { return }
            do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() } catch { return }
            guard BrowsingHistory.shared.accepts(context) else { return }
            qualifiedContext = context; onQualifiedExposure?(effectiveItem, context)
        }
        .onChange(of: active) { _, value in
            if value { qualifiedContext = nil; revealMissingSourceControls() }
        }
        .onChange(of: authorVisibility, initial: true) { previous, current in
            cancelAuthorLookup()
            if previous.key != current.key {
                resolvedAuthor = nil
                failedAuthorKey = nil
                error = nil
            }
            // Metadata is enough for most works. Resolve a missing ID only
            // for the foreground work, never for the preloaded pages.
            if current.active, item.offlineMediaURL == nil, followAuthor == nil {
                loadAuthor()
            }
        }
        .onDisappear { cancelAuthorLookup() }
        .onChange(of: chromeAvailable) { _, value in if value { revealMissingSourceControls() } }
    }

    private func revealMissingSourceControls() {
        guard active, item.mediaURL == nil, chromeAvailable, !pausedForDetails else { return }
        chrome.reveal()
    }

    private var mediaCaption: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error { Text(error).font(.caption2).lineLimit(2) }
            if let title = item.postTitle {
                Text(title).font(.system(size: captionSize, weight: .semibold)).lineLimit(2)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("media.title.\(item.id)")
            }
            if let username = item.username, !username.isEmpty {
                authorRow(username)
            } else if item.postTitle == nil {
                Text(displaysVideo ? "视频" : "图片").font(.system(size: captionSize, weight: .semibold))
            }
        }
        .foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if DEBUG && targetEnvironment(simulator)
        .playbackQAFrame("actions")
        .resumePromptQAFrame("actions-\(item.id)")
        #endif
    }

    @ViewBuilder
    private func mediaActionRail(muted: Binding<Bool>? = nil) -> some View {
        let actions = MediaRailAction.ordered(railOrder).filter {
            guard !hiddenActions.contains($0) else { return false }
            switch $0 {
            case .favorite, .rotate: return true
            case .details: return onDetails != nil
            case .mute: return muted != nil
            case .cleanImage: return !displaysVideo && item.mediaURL != nil && chromeAvailable
            }
        }
        if !actions.isEmpty {
            let inset = FloatingPageChrome.groupInset
            VStack(spacing: inset) {
                ForEach(actions, id: \.self) { action in
                    mediaRailControl(action, muted: muted)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(.vertical, inset)
            .background {
                PlaybackChromeSurface()
                    .frame(width: FloatingPageChrome.iconSurfaceWidth)
            }
            .tint(.white)
            .opacity(railVisible ? 1 : 0)
            .animation(reduceRailMotion ? nil : playbackRailFade, value: railVisible)
            .task(id: active) {
                guard active, !presentationLease.railHasAppeared else { return }
                try? await Task.sleep(for: .milliseconds(24))
                guard !Task.isCancelled else { return }
                presentationLease.railHasAppeared = true
            }
            .allowsHitTesting(railVisible)
            .accessibilityHidden(!railVisible)
            .mediaActionHitFrame(in: actionSpace)
        }
    }

    @ViewBuilder
    private func mediaRailControl(_ action: MediaRailAction, muted: Binding<Bool>?) -> some View {
        switch action {
        case .favorite:
            if item.offlineMediaURL != nil {
                MediaIconActionLabel(title: "离线", symbol: "internaldrive.fill", qaKey: "control.\(item.id).offline")
            } else { FavoriteButton(item: item, active: active) }
        case .details:
            if let onDetails {
                Button { onDetails(effectiveItem) } label: {
                    MediaIconActionLabel(title: action.title, symbol: action.symbol, qaKey: "control.\(item.id).details")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("作品详情")
                .accessibilityIdentifier("media.details.\(item.id)")
            }
        case .mute:
            if let muted {
                Button { muted.wrappedValue.toggle() } label: {
                    MediaIconActionLabel(title: muted.wrappedValue ? "取消静音" : "静音",
                                         symbol: muted.wrappedValue ? action.symbol : "speaker.wave.2.fill",
                                         qaKey: "control.\(item.id).mute")
                }.buttonStyle(.plain).accessibilityLabel(muted.wrappedValue ? "取消静音" : "静音")
            }
        case .cleanImage:
            Button(action: toggleChrome) {
                MediaIconActionLabel(title: action.title, symbol: action.symbol, qaKey: "control.\(item.id).cleanImage")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(action.title)
            .accessibilityHint("隐藏界面，长按画面可恢复")
            .accessibilityIdentifier("media.clean-image.\(item.id)")
        case .rotate:
            Button {
                if let rotatePlayback { rotatePlayback() }
                else { ViewingOrientationController.shared.toggleOrientation() }
            } label: {
                MediaIconActionLabel(title: "手动切换横竖屏", symbol: action.symbol, qaKey: "control.\(item.id).rotate")
            }.buttonStyle(.plain).accessibilityLabel("手动切换横竖屏")
        }
    }

    private func authorRow(_ username: String) -> some View {
        HStack(spacing: 6) {
            Button(action: openAuthor) {
                Text("@" + username)
                    .font(.system(size: captionSize, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("media.author.\(item.id)")
            .mediaControlQAFrame("control.\(item.id).author")
            .mediaActionHitFrame(in: actionSpace)
            if item.offlineMediaURL == nil {
                if let followAuthor {
                    FollowButton(creator: followAuthor, mediaItemID: item.id)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                        .mediaActionHitFrame(in: actionSpace)
                } else if authorLookup != nil {
                    ProgressView().controlSize(.small).tint(.white).accessibilityLabel("正在读取作者")
                } else if failedAuthorKey == authorKey {
                    StatusReloadButton(title: "重试读取作者") { loadAuthor() }
                        .environment(\.colorScheme, .dark)
                        .mediaActionHitFrame(in: actionSpace)
                }
            }
        }
    }
    private func toggleChrome() {
        guard active, !pausedForDetails, chromeAvailable else { return }
        onToggleChrome?()
    }

    private func confirmVideoContent() {
        // A positive image probe is more specific than the bitmap decoder's
        // generic "video content" response; do not oscillate between surfaces.
        if actualDisplayType == nil { actualDisplayType = .video }
    }

    private func openAuthor() {
        guard authorVisibility.active else { return }
        if let cachedAuthor {
            onAuthor(CreatorRoute(creator: cachedAuthor, item: effectiveItem))
        } else { loadAuthor(open: true) }
    }

    private func loadAuthor(open: Bool = false) {
        guard authorVisibility.active, let username = item.username, !username.isEmpty else { return }
        if open { openAuthorOnResolve = true }
        guard authorLookup == nil else { return }
        let key = authorKey
        let requestID = UUID()
        failedAuthorKey = nil
        error = nil
        let task = Task {
            defer {
                if authorLookup?.id == requestID { authorLookup = nil; openAuthorOnResolve = false }
            }
            do {
                let value = try await session.creator(username: username)
                try Task.checkCancellation()
                guard authorLookup?.id == requestID, key.identity == session.feedIdentity else { return }
                guard value.id > 0 else { throw ClientError.invalidResponse }
                resolvedAuthor = (key, value)
                if openAuthorOnResolve { onAuthor(CreatorRoute(creator: value, item: effectiveItem)) }
            } catch {
                guard !Task.isCancelled, authorLookup?.id == requestID, key.identity == session.feedIdentity else { return }
                failedAuthorKey = key
                if openAuthorOnResolve { self.error = error.localizedDescription }
            }
        }
        authorLookup = (requestID, task)
    }

    private func cancelAuthorLookup() {
        authorLookup?.task.cancel()
        authorLookup = nil
        openAuthorOnResolve = false
    }
}

/// Shared compact failure content. Grid retries are siblings of the open button,
/// so a retry cannot accidentally navigate into the failed work.
struct MediaLoadFailureContent: View {
    let message: String
    var workTitle: String? = nil
    var symbol = "photo"
    var retryLabel = "重试图片"
    var retryIdentifier = ""
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            if let workTitle { Text(workTitle).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.secondary) }
            Text(message).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button(action: retry) { Label(retryLabel, systemImage: "arrow.clockwise").font(.caption) }
                    .buttonStyle(AppActionButtonStyle()).fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier(retryIdentifier)
            }
        }.padding(12).frame(maxWidth: 260)
    }
}

struct CachedImage: View {
    let url: URL
    var fit = false
    var onReady: ((Bool) -> Void)? = nil
    var allowsRetry = true
    var retryToken = 0
    var onFailure: ((Bool) -> Void)? = nil
    var showsFailure = true
    var onFailureMessage: ((String?) -> Void)? = nil
    var placeholderTitle: String? = nil
    var placeholderSymbol = "photo"
    var imageBlur: CGFloat = 0
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    private struct RequestKey: Equatable { let url: URL; let retry: Int; let externalRetry: Int }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.06)
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .blur(radius: imageBlur)
                } else if let placeholderTitle {
                    CoverPlaceholder(symbol: placeholderSymbol, title: placeholderTitle)
                } else if let failure {
                    if showsFailure {
                        MediaLoadFailureContent(message: failure, retry: allowsRetry ? { retry += 1 } : nil)
                    }
                } else { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: RequestKey(url: url, retry: retry, externalRetry: retryToken)) {
            guard !Task.isCancelled else { return }
            onReady?(false); onFailure?(false); onFailureMessage?(nil); image = nil; failure = nil
            do {
                #if DEBUG && targetEnvironment(simulator)
                if placeholderTitle != nil && ProcessInfo.processInfo.arguments.contains("--qa-cover69-wait") { try await Task.sleep(for: .seconds(6)) }
                #endif
                let value = try await MediaCache.shared.loadImage(url)
                guard !Task.isCancelled else { return }
                image = value; onReady?(true)
            } catch {
                guard !Task.isCancelled else { return }
                if let known = error as? ImageLoadError {
                    failure = known.localizedDescription
                    let code: DiagnosticCode
                    switch known { case .decode: code = .decode; case .queueFull: code = .queueFull; default: code = .storage }
                    LocalDiagnosticsStore.shared.note(area: .thumbnail, code: code)
                } else if let known = error as? MediaDownloadError {
                    failure = known.localizedDescription
                    if case .http(let status) = known { LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .http, httpStatus: status) }
                    else { LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .invalidResponse) }
                } else { failure = "图片暂时无法加载"; LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .network) }
                onFailure?(true)
                onFailureMessage?(failure)
            }
        }
        .onDisappear { image = nil; onReady?(false) }
    }
}
