import SwiftUI
import Observation
import Combine
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
@MainActor @Observable final class ViewingChromeController {
    private struct Scope {
        let id: UUID
        let inline: Bool
    }

    static let shared = ViewingChromeController()
    private(set) var hidden = false
    private(set) var activeScope: UUID?
    private var scopes: [Scope] = []
    private var overlays = Set<UUID>()
    private var departingRailScope: UUID?
    var isSuspended: Bool { !overlays.isEmpty }
    // Full-screen players own the theme of their own presentation.
    private(set) var hasInlinePlayer = false
    private func syncInlineProjection() {
        let next = scopes.last?.inline == true
        if hasInlinePlayer != next { hasInlinePlayer = next }
    }
    #if DEBUG && targetEnvironment(simulator)
    private(set) var qaToggleCount = 0
    #endif
    func begin(_ scope: UUID, inline: Bool) {
        guard !scopes.contains(where: { $0.id == scope }) else { return }
        scopes.append(.init(id: scope, inline: inline)); syncInlineProjection(); activeScope = overlays.isEmpty ? scope : nil; hidden = false
    }
    func end(_ scope: UUID) {
        guard let index = scopes.firstIndex(where: { $0.id == scope }) else { return }
        let wasForemost = activeScope == scope
        scopes.remove(at: index)
        syncInlineProjection()
        if departingRailScope == scope { departingRailScope = nil }
        if wasForemost { activeScope = scopes.last?.id; hidden = false }
    }
    func endInlinePlayer() {
        if let scope = scopes.last, scope.inline { end(scope.id) }
    }
    func suspend(for overlay: UUID) {
        guard overlays.insert(overlay).inserted else { return }
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("chrome.suspend", ["overlay": overlay.uuidString, "count": overlays.count])
        #endif
        activeScope = nil; hidden = false
    }
    func resume(after overlay: UUID) {
        guard overlays.remove(overlay) != nil else { return }
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("chrome.resume", ["overlay": overlay.uuidString, "count": overlays.count])
        #endif
        activeScope = overlays.isEmpty ? scopes.last?.id : nil; hidden = false
    }
    func toggle(_ scope: UUID) {
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("chrome.toggle", ["requested": scope.uuidString, "active": activeScope?.uuidString ?? "nil", "hiddenBefore": hidden])
        #endif
        guard activeScope == scope else { return }
        hidden.toggle()
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("chrome.toggled", ["hidden": hidden])
        #endif
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
        Image(systemName: symbol).font(.system(size: ContentMetrics.Icon.primary, weight: .medium))
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
        Group {
            if state.failure != nil, restartRetryAvailableAt != nil || state.failure?.retryAvailableAt != nil {
                SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    status(at: context.date)
                }
            } else {
                status(at: .now)
            }
        }
        .existingFeedbackToast(state.failure?.message)
    }

    private func status(at date: Date) -> some View {
            VStack(spacing: 8) {
                switch state {
                case .loading, .scanning:
                    loadingIndicator
                case .ended:
                    Text(empty ? "没有符合条件的作品" : "已经看到最后啦")
                        .accessibilityIdentifier("feed.continuation.ended")
                case .failed(let failure):
                    if failure.requiresRestart {
                        if let restart {
                            StatusReloadButton(title: "重新加载", action: restart)
                                .disabled(performing || (restartRetryAvailableAt.map { $0 > date } ?? false))
                                .accessibilityIdentifier("feed.continuation.restart")
                        }
                    } else {
                        StatusReloadButton(action: retry)
                            .disabled(performing || (failure.retryAvailableAt.map { $0 > date } ?? false))
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

private struct PlaybackPhysicalInsetsKey: EnvironmentKey {
    static let defaultValue: EdgeInsets? = nil
}
private extension EnvironmentValues {
    var playbackPhysicalInsets: EdgeInsets? {
        get { self[PlaybackPhysicalInsetsKey.self] }
        set { self[PlaybackPhysicalInsetsKey.self] = newValue }
    }
}

/// Only offset readers observe finger motion. The deck and its native page
/// configuration do not participate in each movement sample.
@MainActor @Observable private final class MediaBoundaryMotion {
    var offset: CGFloat = 0
}
private struct MediaBoundaryOffset: ViewModifier {
    let motion: MediaBoundaryMotion
    var waiting = false
    var height: CGFloat = 0
    func body(content: Content) -> some View {
        content.offset(y: waiting ? max(0, motion.offset) - height : motion.offset)
    }
}

struct PlaybackNavigation<Content: View>: View {
    @Binding var creator: CreatorRoute?
    @ViewBuilder let content: (@escaping (CreatorRoute) -> Void) -> Content
    @EnvironmentObject private var session: SiteSession
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var exitToTab
    private let chrome = ViewingChromeController.shared
    @StateObject private var favoriteSelectionBar = FavoriteSelectionBar()
    var headerRoute: NativeHeaderRoute? = nil
    @State private var standaloneHeaderRoute = NativeHeaderRoute()
    private var authorHeaderRoute: NativeHeaderRoute { headerRoute ?? standaloneHeaderRoute }
    @State private var measuredSafeInsets: EdgeInsets?

    var body: some View {
        NavigationStack {
            content(openAuthor)
                .nativeHeaderRouteBoundary(authorHeaderRoute, isPresented: false)
                .navigationDestination(item: $creator) { route in
                    CreatorView(creator: route.creator, initialKind: route.kind, preparation: route.preparation)
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
        .playbackLoginPage()
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
            measuredSafeInsets = $0
        }
        .environment(\.playbackPhysicalInsets, measuredSafeInsets)
        .onChange(of: creator != nil) { _, showsCreator in
            if showsCreator { chrome.prepareRailDeparture() }
            else {
                authorHeaderRoute.dismissed(animate: false)
                chrome.cancelRailDeparture()
            }
        }
    }

    private func openAuthor(_ route: CreatorRoute) {
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("navigation.openAuthor", ["creator": route.creator.id])
        #endif
        authorHeaderRoute.preparePresentation()
        creator = route.preparing(session: session, blockedTags: TagBlocklist.shared.names)
    }
}

struct PlaybackTabsBar: View {
    var overMedia = true
    var hidden = false
    var identifier = "playback.tabs"
    var selection: FavoriteSelectionBar.Entry? = nil
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var exitToTab

    var body: some View {
        if let tabs, let exitToTab {
            tabs.render(overMedia, identifier, selection) { id in
                exitToTab(MediaTabExit(id: id, fromMedia: overMedia))
            }
                .viewingChromeHidden(hidden)
                #if DEBUG && targetEnvironment(simulator)
                .background {
                    if ProcessInfo.processInfo.arguments.contains("--qa-terminal-tone175") {
                        Text("tone").font(.system(size: 1)).opacity(0.01).frame(width: 1, height: 1)
                            .accessibilityIdentifier("playback.tone175")
                            .accessibilityValue("idle")
                    }
                }
                #endif
        }
    }
}

struct PlaybackShareButton: View {
    let workID: Int?
    @Environment(\.isHeaderRasterPreview) private var rasterPreview

    var body: some View {
        if let workID, workID > 0,
           let url = URL(string: SiteSession.origin + "/images/\(workID)") {
            Group {
                if rasterPreview { Button {} label: { FloatingPageIcon(symbol: "square.and.arrow.up") } }
                else { ShareLink(item: url) { FloatingPageIcon(symbol: "square.and.arrow.up") } }
            }
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
        .pageReturnAction { onClose(); return true }
    }
}

/// Navigation belongs to the presentation session, outside replaceable media content.
/// The standalone owner serves inline callers without an enclosing media cover.
@MainActor @Observable final class PlaybackNavigationOwner {
    let session: UUID?
    private(set) var finished = false
    init(session: UUID? = nil) {
        self.session = session
        playback = MediaDeckPresentationLease(externallyOwned: session != nil)
    }
    private(set) var creator: CreatorRoute?
    private(set) var consumer: UUID?
    let headerRoute = NativeHeaderRoute()
    var authorDeparture = false
    let playback: MediaDeckPresentationLease
    func accepts(_ token: UUID?, consumer mount: UUID) -> Bool { !finished && session == token && consumer == mount }
    func creator(for token: UUID?) -> CreatorRoute? { !finished && session == token ? creator : nil }
    func attach(_ mount: UUID, for token: UUID?) {
        guard !finished, session == token else { return }
        consumer = mount
    }
    func setCreator(_ value: CreatorRoute?, for token: UUID?, consumer mount: UUID) {
        guard accepts(token, consumer: mount) else { return }
        creator = value
    }
    func finish(_ token: UUID) {
        guard !finished, session == token else { return }
        finished = true; creator = nil; consumer = nil; authorDeparture = false
        playback.finish(); headerRoute.dismissed(animate: false)
    }
}

extension EnvironmentValues {
    @Entry var playbackNavigationOwner: PlaybackNavigationOwner? = nil
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
    @State private var navigationMount = UUID()
    @Environment(\.playbackNavigationOwner) private var presentedNavigation
    @State private var standaloneNavigation = PlaybackNavigationOwner()
    private var navigation: PlaybackNavigationOwner { presentedNavigation ?? standaloneNavigation }
    private var creator: CreatorRoute? { navigation.creator }
    private var creatorBinding: Binding<CreatorRoute?> {
        let owner = navigation
        let token = owner.session
        return Binding(get: { owner.creator(for: token) }, set: { owner.setCreator($0, for: token, consumer: navigationMount) })
    }
    private let chrome = ViewingChromeController.shared

    var body: some View {
        let owner = navigation, token = navigation.session, mount = navigationMount
        return PlaybackNavigation(creator: creatorBinding, headerRoute: owner.headerRoute) { openAuthor in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                MediaDeck(items: items, focused: $focused, focusRequest: focusRequest, queueRevision: queueRevision,
                          playbackSuspended: playbackSuspended, automaticLoadingAllowed: automaticLoadingAllowed, initialID: initialID,
                          coveredByNavigation: creator != nil || navigation.authorDeparture,
                          playbackPresentationLease: owner.playback,
                          continuationState: continuationState, loadMoreAutomatically: loadMoreAutomatically,
                          refreshFromStart: refreshFromStart, restartRetryAvailableAt: restartRetryAvailableAt,
                          bottomBarInset: exitToTab == nil ? nil : tabs?.height,
                          continuationTopInset: PageHeaderLayout.singleRow.reservedHeight,
                          onEdgeSwipe: onEdgeSwipe.map { callback in { direction, region in
                              guard owner.accepts(token, consumer: mount) else { return }
                              callback(direction, region)
                          } }, onAuthor: { route in
                              #if DEBUG && targetEnvironment(simulator)
                              PagerGestureTraceQA.lifecycle("viewer.authorEffect", ["accepted": owner.accepts(token, consumer: mount), "external": onOpenAuthor != nil,
                                  "expectedSession": token?.uuidString ?? "nil", "session": owner.session?.uuidString ?? "nil", "expectedConsumer": mount.uuidString,
                                  "consumer": owner.consumer?.uuidString ?? "nil", "finished": owner.finished])
                              #endif
                              guard owner.accepts(token, consumer: mount) else { return }
                              owner.authorDeparture = true
                              if let onOpenAuthor { onOpenAuthor(route) }
                              else { openAuthor(route) }
                          }, onDetailsVisibility: onDetailsVisibility,
                          historyCheckpoint: historyCheckpoint, resumePositions: resumePositions,
                          loadMore: loadMore)
            }
            .onAppear { if owner.accepts(token, consumer: mount) { owner.authorDeparture = false } }
            .tint(.white)
            .playbackTitleBar(title, workID: items.first(where: { $0.id == focused })?.id,
                              hidden: chrome.hidden, onClose: {
                                  guard owner.accepts(token, consumer: mount) else { return }
                                  onClose()
                              })
        }.environment(\.overlaidTabBarHeight, 0)
        .onAppear { owner.attach(mount, for: token); if owner.accepts(token, consumer: mount) { owner.authorDeparture = false } }
        .onChange(of: ObjectIdentifier(owner), initial: true) { _, _ in
            owner.attach(mount, for: token)
            if owner.accepts(token, consumer: mount) { owner.authorDeparture = false }
        }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear { PagerGestureTraceQA.lifecycle("viewer.appear", ["owner": navigationMount.uuidString]) }
        .onDisappear { PagerGestureTraceQA.lifecycle("viewer.disappear", ["owner": navigationMount.uuidString]) }
        .onChange(of: creator) { old, value in
            PagerGestureTraceQA.lifecycle("viewer.creatorChanged", ["owner": navigationMount.uuidString, "old": old?.creator.id ?? -1, "new": value?.creator.id ?? -1])
        }
        #endif
    }
}

@MainActor
final class MediaDeckPresentationLease: ObservableObject {
    @Published var railHasAppeared = false
    let chrome = UUID()
    let details = UUID()
    let externallyOwned: Bool
    private(set) var finished = false

    init(externallyOwned: Bool = false) { self.externallyOwned = externallyOwned }

    func syncChrome(visible: Bool, inline: Bool) {
        guard !finished else { return }
        if visible { ViewingChromeController.shared.begin(chrome, inline: inline) }
        else if !externallyOwned { ViewingChromeController.shared.end(chrome) }
    }

    func viewDetached(covered: Bool, retainedRoot: Bool) {
        guard !externallyOwned else { return }
        ViewingChromeController.shared.end(chrome)
        if !covered && !retainedRoot {
            VideoPlaybackSessions.shared.retireOwner(chrome)
            ViewingChromeController.shared.resume(after: details)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        VideoPlaybackSessions.shared.retireOwner(chrome)
        ViewingChromeController.shared.end(chrome)
        ViewingChromeController.shared.resume(after: details)
    }
    deinit {
        let details = details, chrome = chrome
        Task { @MainActor in
            VideoPlaybackSessions.shared.retireOwner(chrome)
            ViewingChromeController.shared.end(chrome)
            ViewingChromeController.shared.resume(after: details)
        }
    }
}

/// Per-MediaDeck-session projection cache. This is deliberately not observable:
/// callers resolve it at the view boundary and keep the reference in local state.
@MainActor
final class MediaDeckVisibility {
    struct Snapshot {
        let items: [MediaItem]
        let ids: [Int]
        /// The optional end-page sentinel is always available to the owner.
        /// The owner decides whether its current presentation includes it.
        let idsWithEnd: [Int]
        let indexByID: [Int: Int]

        func item(id: Int) -> MediaItem? {
            guard let index = indexByID[id], items.indices.contains(index) else { return nil }
            return items[index]
        }

        func index(id: Int) -> Int? { indexByID[id] }
    }

    private var hasProjection = false
    private var sourceItems: [MediaItem] = []
    private var sourceIdentity = ""
    private var sourceAuthors: [BlockedAuthor] = []
    private var sourceTags = Set<String>()
    private(set) var projectionBuilds = 0
    private(set) var snapshot = Snapshot(items: [], ids: [], idsWithEnd: [-2], indexByID: [:])

    @discardableResult
    func resolve(items: [MediaItem], identity: String, blockedTags: Set<String>, authors: [BlockedAuthor]) -> Snapshot {
        if hasProjection, sourceIdentity == identity, sourceAuthors == authors,
           sourceTags == blockedTags, sourceItems == items {
            return snapshot
        }

        let blockedIDs = Set(authors.map(\.id))
        let groupedHandles = Dictionary(grouping: authors, by: { AuthorHandlePolicy.normalize($0.username) })
        let blockedHandles = Set(groupedHandles.compactMap { handle, entries in entries.count == 1 ? handle : nil })
        let visible = items.filter { item in
            !AuthorHandlePolicy.blocks(creatorID: item.creatorID, username: item.username,
                                       blockedIDs: blockedIDs, blockedHandles: blockedHandles) &&
                TagPolicy.verdict(names: item.tagNames, blocked: blockedTags) == .allowed
        }

        var indexByID: [Int: Int] = [:]
        indexByID.reserveCapacity(visible.count)
        for (index, item) in visible.enumerated() where indexByID[item.id] == nil {
            indexByID[item.id] = index
        }
        let ids = visible.map(\.id)
        snapshot = Snapshot(items: visible, ids: ids, idsWithEnd: ids + [-2], indexByID: indexByID)

        // Keep the entire input alive so Array equality can use its identical
        // CoW-storage fast path while still detecting equal independent copies
        // and every changed MediaItem field.
        sourceItems = items
        sourceIdentity = identity
        sourceAuthors = authors
        sourceTags = blockedTags
        hasProjection = true
        projectionBuilds += 1
        return snapshot
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
    var playbackPresentationLease: MediaDeckPresentationLease? = nil
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
    var onCanvasReady: ((UIView) -> Void)? = nil
    var onEdgeSwipe: MediaEdgeSwipeAction? = nil
    var onEdgeDrag: MediaEdgeDragAction? = nil
    let onAuthor: (CreatorRoute) -> Void
    var onDetailsVisibility: ((Bool) -> Void)? = nil
    var historyCheckpoint: ((MediaItem) -> TimelineCheckpoint?)? = nil
    var resumePositions: [Int: Double] = [:]
    var endAction: (() -> Void)? = nil
    let loadMore: () async -> Void
    @EnvironmentObject private var session: SiteSession
    @Environment(\.rootPageParticipation) private var rootParticipation
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.pageSurfaceTone) private var surfaceTone
    @Environment(\.exitMediaCoverToTab) private var exitToTab
    @Environment(\.requestSignIn) private var requestSignIn
    @Environment(\.rotatePlayback) private var rotatePlayback
    @Environment(\.pageVisualActivationPermit) private var pageVisualActivationPermit
    @Environment(\.pageCoverScope) private var pageCoverScope
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocks = AuthorBlocklist.shared
    private let history = BrowsingHistory.shared
    @State private var historySignal = 0
    private let chrome = ViewingChromeController.shared
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
    private enum DeckPage: Identifiable, Equatable {
        case details(MediaItem), favorite(MediaItem)
        var id: String {
            switch self { case .details(let item): "details-\(item.id)"; case .favorite(let item): "favorite-\(item.id)" }
        }
    }
    private struct DeckPageRequest: Identifiable, Equatable {
        let id = UUID()
        let page: DeckPage
    }
    @State private var presentedPage: DeckPageRequest?
    @State private var detailsExit: MediaDetailsView.ExitAction?
    @State private var pageTagSnapshot: Set<String>?
    @State private var pageHeaderRoute = NativeHeaderRoute()
    @StateObject private var standalonePresentationLease = MediaDeckPresentationLease()
    private var presentationLease: MediaDeckPresentationLease { playbackPresentationLease ?? standalonePresentationLease }
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
    @State private var boundaryMotion = MediaBoundaryMotion()
    @Environment(\.playbackPhysicalInsets) private var physicalInsets
    @Environment(\.floatingPageSafeInsets) private var floatingInsets
    @State private var transitionFrames: [URL: UIImage] = [:]
    @State private var transitionFrameContext: String?
    @State private var transitionFrameRevision = 0
    #if DEBUG && targetEnvironment(simulator)
    @State private var transitionFrameDecodes = 0
    #endif
    @State private var transitionCacheGeneration: Int?
    @Environment(\.viewingControlsReferenceInset) private var controlsReferenceInset
    @State private var visibilityProjection = MediaDeckVisibility()
    private struct ForegroundWorkActivation: Equatable {
        let identity: String
        let queueRevision: Int
        let owner: UUID
        let rootSlot: UUID?
        let workID: Int
        let url: URL
    }
    @State private var foregroundWorkActivation: ForegroundWorkActivation?
    private var visibleSnapshot: MediaDeckVisibility.Snapshot {
        visibilityProjection.resolve(items: items, identity: session.feedIdentity,
                                     blockedTags: pageTagSnapshot ?? blocklist.names, authors: authorBlocks.entries)
    }
    private var visibleItems: [MediaItem] { visibleSnapshot.items }
    private var historyContext: HistoryContext? {
        _ = historySignal
        return history.context(ownerID: session.tagLibraryOwnerID)
    }
    private var viewerVisible: Bool { appeared && isVisible && !session.showLogin && !presentationLease.finished }
    private var pagePresentationActive: Bool { pageTagSnapshot != nil }
    private var isCoveredByPage: Bool { pagePresentationActive || coveredByNavigation }
    private var allowsForegroundMedia: Bool {
        (pageVisualActivationPermit?.isAllowed ?? true) && viewerVisible && rootParticipation.isActive &&
            scenePhase == .active && !playbackSuspended && !pagePresentationActive
    }
    private var continuationIntentContext: String { "\(session.feedIdentity):\(queueRevision):\(focusRequest)" }
    private var awaitingNextItem: Bool {
        guard let boundaryDemand, let focused else { return false }
        return viewerVisible && scenePhase == .active && !playbackSuspended && !pagePresentationActive &&
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
        let snapshot = visibleSnapshot
        let works = snapshot.items
        let index = focused.flatMap { snapshot.index(id: $0) }
        let count = [3, 6, 10].contains(mediaPrefetchCount) ? mediaPrefetchCount : 6
        let concurrency = MediaPrefetchConcurrency.validated(mediaPrefetchConcurrency)
        let previousVideo = index.flatMap { index -> MediaItem? in
            guard index > 0, works[index - 1].isVideo else { return nil }
            return works[index - 1]
        }
        let window = (previousVideo.map { [$0] } ?? []) +
            (index.map { Array(works.dropFirst($0).prefix(count + 1)) } ?? [])
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
        let scope: String
        let plan: TransitionFramePlan?
        let retention: TransitionFramePlan?
        let revision: Int
    }
    private var frameContext: String { "\(session.feedIdentity):\(queueRevision)" }
    @State private var foregroundPlaybackWaiting = false
    private struct WarmPlaybackDemand: Equatable {
        let context: String
        let expectedCurrentWorkID: Int?
        let rootSlot: UUID?
        let targets: [VideoPlaybackNeighborWindow.Neighbor]
        let window: VideoPlaybackNeighborWindow?
    }

    private func playbackNeighbors(around id: Int) -> VideoPlaybackNeighborWindow? {
        let snapshot = visibleSnapshot
        let works = snapshot.items
        guard let index = snapshot.index(id: id) else { return nil }
        func video(at offset: Int) -> VideoPlaybackNeighborWindow.Neighbor? {
            let candidateIndex = index + offset
            guard works.indices.contains(candidateIndex) else { return nil }
            let item = works[candidateIndex]
            guard item.isVideo, let address = item.mediaURL else { return nil }
            return .init(workID: item.id, address: address)
        }
        return .init(previous: video(at: -1), next: video(at: 1))
    }

    private var warmPlaybackDemand: WarmPlaybackDemand {
        let rootSlot = inlinePlayback ? rootParticipation.token : nil
        guard viewerVisible, scenePhase == .active, !playbackSuspended, !isCoveredByPage, !foregroundPlaybackWaiting,
              !inlinePlayback || allowsForegroundMedia,
              let focused, let neighbors = playbackNeighbors(around: focused) else {
            return .init(context: frameContext, expectedCurrentWorkID: nil, rootSlot: rootSlot, targets: [], window: nil)
        }
        let targets = [neighbors.next, inlinePlayback ? neighbors.previous : nil].compactMap { $0 }
        return .init(context: frameContext, expectedCurrentWorkID: focused, rootSlot: rootSlot,
                     targets: targets, window: inlinePlayback ? neighbors : nil)
    }

    private func prepareWarmPlayback(_ demand: WarmPlaybackDemand, matching: URL? = nil) async {
        guard !presentationLease.finished, !Task.isCancelled, demand == warmPlaybackDemand,
              let expectedCurrentWorkID = demand.expectedCurrentWorkID else { return }
        let pool = VideoPlaybackSessions.shared
        let cacheGeneration = MediaCache.shared.repairGeneration
        if let window = demand.window {
            pool.updateTimelineWindow(window, owner: chromeScope, scope: demand.context,
                                      rootSlot: demand.rootSlot, expectedCurrentWorkID: expectedCurrentWorkID)
        }
        for target in demand.targets where matching == nil || target.address == matching {
            guard !Task.isCancelled, demand == warmPlaybackDemand else { return }
            if demand.window != nil, pool.hasPreparedTimelineNeighbor(target, owner: chromeScope, scope: demand.context,
                rootSlot: demand.rootSlot, cacheGeneration: cacheGeneration) { continue }
            let address = target.address
            let lease = address.isFileURL ? await MediaCache.shared.leaseFile(address) :
                await MediaCache.shared.leaseCached(address, video: true)
            guard let lease else { continue }
            guard !presentationLease.finished, !Task.isCancelled, demand == warmPlaybackDemand,
                  lease.generation == cacheGeneration, cacheGeneration == MediaCache.shared.repairGeneration else {
                await MediaCache.shared.release(lease); return
            }
            let key = videoPlaybackKey(owner: chromeScope, scope: demand.context, workID: target.workID,
                address: address, source: lease.file, rootSlot: demand.rootSlot, lease: lease)
            var consumed = false
            _ = pool.prepareCandidate(key: key, expectedCurrentWorkID: expectedCurrentWorkID,
                pin: { consumed = true }, unpin: { Task { await MediaCache.shared.release(lease) } })
            if !consumed { await MediaCache.shared.release(lease) }
        }
    }

    private var frameRetentionPlan: TransitionFramePlan? {
        let snapshot = visibleSnapshot
        let works = snapshot.items
        guard let focused, let index = snapshot.index(id: focused) else { return nil }
        func videoURL(at index: Int) -> URL? {
            guard works.indices.contains(index), works[index].isVideo,
                  (resumePositions[works[index].id] ?? 0) <= 0 else { return nil }
            return works[index].mediaURL
        }
        return .init(context: frameContext, current: videoURL(at: index),
                     neighbors: [index + 1, index - 1, index + 2].compactMap(videoURL(at:)))
    }
    private var frameRetentionURLs: Set<URL> {
        guard let plan = frameRetentionPlan else { return [] }
        return Set(plan.neighbors + [plan.current].compactMap { $0 })
    }
    private var transitionFramePlan: TransitionFramePlan? {
        guard viewerVisible, scenePhase == .active, !playbackSuspended, !pagePresentationActive else { return nil }
        // The closest pages in the native pager matter first. Keep only
        // nearby frame images and decode one at a time from cached files.
        return frameRetentionPlan
    }
    private func prepareTransitionFrames(_ plan: TransitionFramePlan?, retaining retention: TransitionFramePlan?, scope: String) async {
        guard !Task.isCancelled else { return }
        if transitionFrameContext != scope {
            transitionFrames = [:]
            transitionFrameContext = scope
        }
        let retained = retention.map { Set($0.neighbors + [$0.current].compactMap { $0 }) } ?? []
        transitionFrames = transitionFrames.filter { retained.contains($0.key) }
        guard let plan else { return }
        for url in plan.neighbors where transitionFrames[url] == nil {
            guard !Task.isCancelled else { return }
            let frame = await MediaCache.shared.transitionFrame(for: url)
            guard !Task.isCancelled, scope == frameContext, plan.context == frameContext,
                  frameRetentionURLs.contains(url) else { return }
            if let frame {
                transitionFrames[url] = frame
                #if DEBUG && targetEnvironment(simulator)
                transitionFrameDecodes += 1
                #endif
            }
        }
    }

    var body: some View {
        GeometryReader { safeViewport in
            deck(topInset: physicalInsets?.top ?? max(floatingInsets.top, safeViewport.safeAreaInsets.top),
                 bottomInset: physicalInsets?.bottom ?? max(floatingInsets.bottom, safeViewport.safeAreaInsets.bottom))
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func deck(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let framePlan = transitionFramePlan
        let frameScope = frameContext
        let frameRetention = frameRetentionPlan
        let frameDemand = TransitionFrameDemand(scope: frameScope, plan: framePlan,
                                                retention: frameRetention, revision: transitionFrameRevision)
        return GeometryReader { geometry in
            NativeMediaPager(ids: pageIDs, focused: $focused, initialID: initialID,
                             focusRequest: focusRequest &+ pageRecoveryRequest, queueRevision: queueRevision,
                             viewport: geometry.size,
                             accessibilityIdentifier: historyCheckpoint == nil ? "media.viewer.deck" : "timeline.media.deck",
                             isVisible: viewerVisible && scenePhase == .active && (pageVisualActivationPermit?.isAllowed ?? true),
                             onUserPageSettled: { id in
                guard allowsForegroundMedia else { return }
                pagedQueueRevision = queueRevision
                if let demand = boundaryDemand, demand.anchorID != id && demand.targetID != id { boundaryDemand = nil }
            }, onUserContinuationDemand: { id in
                guard allowsForegroundMedia, showsLoadMore, continuationState != .ended,
                      continuationState?.isLoading != true, continuationState?.requiresRestart != true else { return }
                startContinuationAction(loadMore)
            }, onUserBoundaryDemand: { id in
                if allowsForegroundMedia, showsLoadMore, id == focused {
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
                    withTransaction(transaction) { boundaryMotion.offset = offset }
                case .ended, .cancelled, .interrupted:
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { boundaryMotion.offset = 0 }
                }
            }, onPageDisplayed: { id in
                if let demand = boundaryDemand, demand.context == continuationIntentContext,
                   demand.targetID == id, focused == id, awaitingNextItem { boundaryDemand = nil }
            }, onCanvasReady: onCanvasReady,
               actionContext: frameContext, actionHistoryContext: historyContext,
               pageProjection: { id, settled in
                pageProjection(id: id, settled: settled, size: geometry.size, topInset: topInset,
                               controlsBottomInset: (bottomBarInset ?? controlsReferenceInset) + bottomInset)
            }, onPageAction: handlePageAction) { id, settled, action in
                let content = page(id: id, settled: settled, size: geometry.size, topInset: topInset, action: action)
                    // Move rendered content inside its stable native host. The
                    // pager's hit-test viewport and internal queue stay in place.
                    .modifier(MediaBoundaryOffset(motion: boundaryMotion, waiting: awaitingNextItem, height: geometry.size.height))
                    .allowsHitTesting(allowsForegroundMedia && !awaitingNextItem)
                    .accessibilityHidden(awaitingNextItem || !allowsForegroundMedia)
                    .background {
                        if awaitingNextItem, settled, allowsForegroundMedia, onEdgeSwipe != nil {
                            // The outgoing work is offset by a full page while waiting.
                            // Keep this recognizer in the stationary viewport instead.
                            let chromeHidden = chrome.isHidden(for: chromeScope)
                            Color.clear.contentShape(Rectangle())
                                .background {
                                    MediaGestureLayer(active: true, isVideo: false,
                                        topExclusion: chromeHidden ? 0 : topInset + gestureTopExclusion,
                                        bottomExclusion: chromeHidden ? 0 : (bottomBarInset ?? controlsReferenceInset) + bottomInset + 8,
                                        excludedFrames: (chromeHidden ? [] : gestureExcludedFrames.map { $0.offsetBy(dx: 0, dy: topInset) }) +
                                            (continuationStatusFrame.isEmpty ? [] : [continuationStatusFrame]),
                                        onEdgeSwipe: { action(.edgeSwipe($0, $1)) },
                                        onEdgeDrag: onEdgeDrag.map { _ in { action(.edgeDrag($0, $1, $2)) } })
                                }
                                .accessibilityHidden(true)
                        }
                    }
                    .environmentObject(session).environmentObject(session.oauth)
                    .environment(\.ordinaryColorScheme, ordinaryScheme)
                    .environment(\.pageSurfaceTone, surfaceTone)
                    .environment(\.pageCanvasRole, .playback)
                    .environment(\.mediaTabs, tabs)
                    .environment(\.exitMediaCoverToTab, exitToTab.map { _ in { action(.exitTab($0)) } })
                    .environment(\.requestSignIn, requestSignIn.map { _ in { action(.signIn($0)) } })
                    .environment(\.pageVisualActivationPermit, pageVisualActivationPermit)
                    .environment(\.pageCoverScope, pageCoverScope)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.verticalSizeClass, verticalSizeClass)
                    .environment(\.playbackControlsBottomInset, (bottomBarInset ?? controlsReferenceInset) + bottomInset)
                    .environment(\.rotatePlayback, { action(.rotate) })
                    .environment(\.colorScheme, .dark)
                #if DEBUG && targetEnvironment(simulator)
                if ResumePromptQA.enabled { return AnyView(content.defaultAppStorage(ResumePromptQA.defaults)) }
                #endif
                return AnyView(content)
            }
            .id(session.feedIdentity)
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
            .task(id: warmPlaybackDemand) {
                await prepareWarmPlayback(warmPlaybackDemand)
            }
            .task(id: frameDemand) {
                await prepareTransitionFrames(framePlan, retaining: frameRetention, scope: frameScope)
            }
            .onReceive(history.$ready.combineLatest(history.$generation)
                .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.receive(on: RunLoop.main)) { value in
                historySignal &+= 1
            }
            .onReceive(MediaCache.shared.foregroundVideoDemands) { demand in
                if foregroundPlaybackWaiting != demand.waiting { foregroundPlaybackWaiting = demand.waiting }
            }
            .onReceive(MediaCache.shared.videoPreloadUpdates) { url in
                let warm = warmPlaybackDemand
                if warm.targets.contains(where: { $0.address == url }) {
                    Task { await prepareWarmPlayback(warm, matching: url) }
                }
                if framePlan?.neighbors.contains(url) == true && transitionFrames[url] == nil {
                    transitionFrameRevision &+= 1
                }
            }
            .onReceive(MediaCache.shared.prefetchInvalidations) { generation in
                guard transitionCacheGeneration != generation else { return }
                if inlinePlayback && transitionCacheGeneration != nil {
                    VideoPlaybackSessions.shared.clearTimelineSpares(owner: chromeScope, cacheGeneration: generation)
                }
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
                if inlinePlayback && id.flatMap({ visibleSnapshot.item(id: $0) })?.isVideo != true {
                    VideoPlaybackSessions.shared.clearTimelineSpares(owner: chromeScope)
                }
                if let id, id < 0, viewerVisible, chrome.activeScope == chromeScope { chrome.reveal() }
            }
            .onChange(of: frameContext) { _, _ in VideoPlaybackSessions.shared.retireOwner(chromeScope) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                VideoPlaybackSessions.shared.handleMemoryPressure()
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
                if !waiting { boundaryMotion.offset = 0 }
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
                    .modifier(MediaBoundaryOffset(motion: boundaryMotion))
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
                        } else if continuationState?.isLoading == true {
                            ProgressView().tint(.white.opacity(0.8))
                                .accessibilityIdentifier("media.empty.loading")
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
                    Text("frames=\(transitionFrames.count);decodes=\(transitionFrameDecodes)")
                        .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("media.qa.transition-frames").accessibilityValue("frames=\(transitionFrames.count);decodes=\(transitionFrameDecodes)")
                }
            }
            #endif
            .pinnedPageCover(item: $presentedPage, route: pageHeaderRoute, sourceRole: .playback, animateDismissal: detailsExit == nil, onDismiss: finishPage) { request in
                pageContent(request.page)
            }
            .onAppear {
                appeared = true; syncViewingChrome()
            }
            .onChange(of: isVisible) { _, value in
                if !value {
                    foregroundWorkActivation = nil
                    if inlinePlayback { VideoPlaybackSessions.shared.clearTimelineSpares(owner: chromeScope) }
                    cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop()
                }
                syncViewingChrome()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    foregroundWorkActivation = nil
                    VideoPlaybackSessions.shared.suspendForBackground()
                    cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop()
                }
                syncViewingChrome()
            }
            .onChange(of: focused) { oldID, newID in
                if oldID != newID { foregroundWorkActivation = nil }
            }
            .onChange(of: queueRevision) { _, _ in foregroundWorkActivation = nil }
            .onChange(of: pageVisualActivationPermit?.isAllowed) { _, allowed in
                if allowed == true { foregroundWorkActivation = nil }
            }
            .onChange(of: rootParticipation.isActive) { _, active in
                if !active { foregroundWorkActivation = nil }
            }
            .onChange(of: session.showLogin) { _, shown in
                if shown { cancelBoundaryDemand(); cancelContinuationAction(); preloader.stop() }
                syncViewingChrome()
            }
            .onChange(of: presentedPage) { _, item in
                if item != nil { cancelBoundaryDemand(); chrome.suspend(for: detailsChromeScope) }
                // Clearing the binding requests dismissal; finishPage owns release.

            }
            .onDisappear {
                appeared = false
                if inlinePlayback { VideoPlaybackSessions.shared.clearTimelineSpares(owner: chromeScope) }
                cancelBoundaryDemand()
                cancelContinuationAction()
                preloader.stop()
                let retainedRoot = inlinePlayback && rootParticipation.token.map {
                    VideoPlaybackSessions.shared.hasRootPaused(owner: chromeScope, rootSlot: $0)
                } == true
                presentationLease.viewDetached(covered: isCoveredByPage, retainedRoot: retainedRoot)
            }
    }

    @ViewBuilder private func pageContent(_ page: DeckPage) -> some View {
        switch page {
        case .details(let item):
            MediaDetailsView(item: item, onClose: closePage)
        case .favorite(let item):
            BusinessPageSurface(fromMedia: true, onTab: { closePage(.tab($0)) }) {
                FavoriteEditor(item: item, onClose: { closePage(nil) })
            }
        }
    }

    private func openPage(_ page: DeckPage) {
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("deck.openPage", ["page": page.id, "scope": chromeScope.uuidString])
        #endif
        guard !pagePresentationActive else { return }
        detailsExit = nil
        pageTagSnapshot = blocklist.names
        onDetailsVisibility?(true)
        withoutPageAnimation { presentedPage = DeckPageRequest(page: page) }
    }

    private func closePage(_ action: MediaDetailsView.ExitAction?) {
        guard presentedPage != nil else { return }
        detailsExit = action
        if case .tab(let exit) = action {
            // All covers unwind in the same selection transaction, so an
            // intermediate player or grid never becomes the destination.
            withoutPageAnimation {
                clearPagePresentation()
                (exitToTab ?? tabs?.select)?(exit)
                presentedPage = nil
            }
        } else {
            withoutPageAnimation {
                presentedPage = nil
            }
        }
    }

    private func finishPage() {
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("deck.finishPage", ["scope": chromeScope.uuidString, "snapshot": pageTagSnapshot != nil])
        #endif
        let action = detailsExit
        detailsExit = nil
        guard pageTagSnapshot != nil else { return }
        clearPagePresentation()
        switch action {
        case .author(let route): onAuthor(route)
        case .signIn:
            if let requestSignIn { requestSignIn(false) } else { session.openLogin() }
        case .tab, nil: break
        }
    }

    private func clearPagePresentation() {
        pageTagSnapshot = nil
        onDetailsVisibility?(false)
        chrome.resume(after: detailsChromeScope)
    }

    private func resolveBoundaryDemand() {
        guard let demand = boundaryDemand else { return }
        let active = viewerVisible && scenePhase == .active && !playbackSuspended && !pagePresentationActive
        let ids = visibleSnapshot.ids
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
        boundaryMotion.offset = 0
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
        presentationLease.syncChrome(visible: viewerVisible, inline: inlinePlayback)
        if viewerVisible && visibleItems.isEmpty { revealFallbackControls() }
    }

    private var pageIDs: [Int] {
        let snapshot = visibleSnapshot
        guard !snapshot.items.isEmpty else { return [] }
        return endAction == nil ? snapshot.ids : snapshot.idsWithEnd
    }

    /// These are the values read by one rendered page. Queue append, callback changes,
    /// unrelated downloads and boundary motion do not replace unchanged neighboring roots.
    private struct PageProjection: Equatable {
        let item: MediaItem?
        let end: Bool
        let recover: Bool
        let active: Bool
        let frame: ObjectIdentifier?
        let transitionPreview: Bool
        let pausedForDetails: Bool
        let retain: Bool
        let preserveCover: Bool
        let history: HistoryContext?
        let resume: Double?
        let rootSlot: UUID?
        let timelineWindow: VideoPlaybackNeighborWindow?
        let scope: String
        let queueRevision: Int
        let chrome: UUID
        let inline: Bool
        let reduceMotion: Bool
        let size: CGSize
        let topExclusion: CGFloat
        let excludedFrames: [CGRect]
        let controlsBottomInset: CGFloat
        let hasEdgeSwipe: Bool
        let hasEdgeDrag: Bool
        let waiting: Bool
        let waitingChromeHidden: Bool
        let ordinaryScheme: ColorScheme
        let tone: UUID?
        let dynamicType: DynamicTypeSize
        let verticalSizeClass: UserInterfaceSizeClass?
        let tabHeight: CGFloat?
        let hasExitTab: Bool
        let hasSignIn: Bool
    }

    private func pageProjection(id: Int, settled: Bool, size: CGSize, topInset: CGFloat, controlsBottomInset: CGFloat) -> NativeMediaPageProjection {
        let item = visibleSnapshot.item(id: id)
        let frame = transitionFrameContext == frameContext
            ? item?.mediaURL.flatMap { frameRetentionURLs.contains($0) ? transitionFrames[$0] : nil } : nil
        let allowsPreview = viewerVisible && scenePhase == .active && !playbackSuspended && !pagePresentationActive
        return NativeMediaPageProjection(PageProjection(item: item,
            end: id == -2 && endAction != nil, recover: !visibleItems.isEmpty,
            active: pageIsForegroundActive(id: id, settled: settled),
            frame: frame.map(ObjectIdentifier.init),
            transitionPreview: allowsPreview && (!settled || pagedQueueRevision == queueRevision || boundaryDemand?.targetID == id),
            pausedForDetails: pagePresentationActive || awaitingNextItem,
            retain: (focused == id || boundaryDemand?.anchorID == id) && (isVisible || isCoveredByPage || rootParticipation.token != nil),
            preserveCover: focused == id && scenePhase == .active && (isCoveredByPage || visibleSnapshot.item(id: id).map(shouldPreserveActivationForPermit) == true),
            history: historyContext, resume: resumePositions[id], rootSlot: inlinePlayback ? rootParticipation.token : nil,
            timelineWindow: inlinePlayback && focused == id ? playbackNeighbors(around: id) : nil,
            scope: frameContext, queueRevision: queueRevision, chrome: chromeScope, inline: inlinePlayback, reduceMotion: reduceRailMotion,
            size: size, topExclusion: topInset + gestureTopExclusion,
            excludedFrames: gestureExcludedFrames.map { $0.offsetBy(dx: 0, dy: topInset) } + (continuationStatusFrame.isEmpty ? [] : [continuationStatusFrame]),
            controlsBottomInset: controlsBottomInset, hasEdgeSwipe: onEdgeSwipe != nil, hasEdgeDrag: onEdgeDrag != nil,
            waiting: awaitingNextItem, waitingChromeHidden: awaitingNextItem && chrome.isHidden(for: chromeScope), ordinaryScheme: ordinaryScheme, tone: surfaceTone?.id,
            dynamicType: dynamicTypeSize, verticalSizeClass: verticalSizeClass, tabHeight: tabs?.height,
            hasExitTab: exitToTab != nil, hasSignIn: requestSignIn != nil))
    }

    private func handlePageAction(_ action: NativeMediaPageAction) {
        if case .edgeDrag(_, let phase, let region) = action, phase == .cancelled || phase == .interrupted {
            // A retired page can only clean up its previously accepted drag.
            onEdgeDrag?(0, phase, region)
            return
        }
        guard !presentationLease.finished else { return }
        if case .prepared = action {
            // Cover/player preparation remains useful while this page is parked.
        } else {
            guard allowsForegroundMedia else { return }
        }
        switch action {
        case .toggleChrome: chrome.toggle(chromeScope)
        case .rotate:
            #if DEBUG && targetEnvironment(simulator)
            PagerGestureTraceQA.lifecycle("deck.rotate", ["forwarded": rotatePlayback != nil])
            #endif
            if let rotatePlayback { rotatePlayback() }
            else { ViewingOrientationController.shared.toggleOrientation() }
        case .edgeSwipe(let direction, let region): onEdgeSwipe?(direction, region)
        case .edgeDrag(let offset, let phase, let region): onEdgeDrag?(offset, phase, region)
        case .author(let route): onAuthor(route)
        case .details(let item): openPage(.details(item))
        case .favorite(let item): openPage(.favorite(item))
        case .unavailable(let id):
                guard allowsForegroundMedia,
                      advance.canAdvance(failedID: id, focused: focused, active: true),
                      boundaryDemand?.anchorID != id else { return }
                let ids = visibleSnapshot.ids
                let hasNext = ids.firstIndex(of: id).map { ids.indices.contains($0 + 1) } ?? false
                guard hasNext || (showsLoadMore && automaticLoadingAllowed) else { return }
                boundaryDemand = .init(anchorID: id, context: continuationIntentContext, cause: .failedPlayback)
                resolveBoundaryDemand()
                if boundaryDemand != nil, continuationState != .ended, continuationState?.isLoading != true,
                   continuationState?.requiresRestart != true {
                    startContinuationAction(loadMoreAutomatically ?? loadMore)
                }

        case .prepared: Task { await prepareWarmPlayback(warmPlaybackDemand) }
        case .exposure(let item, let context):
            guard allowsForegroundMedia else { return }
            history.record(item, context: context, checkpoint: historyCheckpoint?(item))
        case .end: endAction?()
        case .recover:
            if let next = visibleItems.first { focused = next.id; pageRecoveryRequest &+= 1 }
        case .revealControls: revealFallbackControls()
        case .exitTab(let exit): exitToTab?(exit)
        case .signIn(let collections): requestSignIn?(collections)
        }
    }

    @ViewBuilder private func page(id: Int, settled: Bool, size: CGSize, topInset: CGFloat, action: @escaping (NativeMediaPageAction) -> Void) -> some View {
        if let item = visibleSnapshot.item(id: id) {
            let allowsTransitionPreview = viewerVisible && scenePhase == .active && !playbackSuspended && !pagePresentationActive
            let warmFrame = transitionFrameContext == frameContext
                ? item.mediaURL.flatMap { frameRetentionURLs.contains($0) ? transitionFrames[$0] : nil } : nil
            MediaPageView(item: item, active: pageIsForegroundActive(id: item.id, settled: settled),
                          transitionFrame: warmFrame,
                          usesTransitionPreview: allowsTransitionPreview && (!settled || pagedQueueRevision == queueRevision || boundaryDemand?.targetID == id),
                          chromeScope: chromeScope, inlinePlayback: inlinePlayback,
                          presentationLease: presentationLease, reduceRailMotion: reduceRailMotion,
                          onToggleChrome: { action(.toggleChrome) },
                          gestureTopExclusion: topInset + gestureTopExclusion,
                          gestureExcludedFrames: gestureExcludedFrames.map { $0.offsetBy(dx: 0, dy: topInset) } +
                              (continuationStatusFrame.isEmpty ? [] : [continuationStatusFrame]),
                          onEdgeSwipe: onEdgeSwipe.map { _ in { action(.edgeSwipe($0, $1)) } },
                          onEdgeDrag: onEdgeDrag.map { _ in { action(.edgeDrag($0, $1, $2)) } },
                          onAuthor: { action(.author($0)) }, pausedForDetails: pagePresentationActive || awaitingNextItem, onDetails: { value in
                action(.details(value))
            }, onFavoriteManagement: { action(.favorite($0)) }, onUnavailable: { action(.unavailable($0)) }, historyContext: historyContext, resumePosition: resumePositions[item.id],
                retainDuringInterruption: (focused == item.id || boundaryDemand?.anchorID == item.id) && (isVisible || isCoveredByPage || rootParticipation.token != nil),
                playbackOwner: chromeScope, playbackScope: frameContext,
                playbackRootSlot: inlinePlayback ? rootParticipation.token : nil,
                timelineWindow: inlinePlayback && focused == item.id ? playbackNeighbors(around: item.id) : nil,
                preserveForPageCover: focused == item.id && scenePhase == .active &&
                    (isCoveredByPage || shouldPreserveActivationForPermit(item)),
                onPlaybackPrepared: {
                    noteForegroundWorkActivation(item)
                    action(.prepared)
                },
                onQualifiedExposure: { item, context in
                action(.exposure(item, context))
            }).id("\(item.id):queue:\(queueRevision)")
                .environment(\.tabPageMotion, tabPageMotion)
                .environment(\.pageVisualActivationPermit, pageVisualActivationPermit)
                .frame(width: size.width, height: size.height).clipped()
                .resumePromptQAFrame("page-\(item.id)")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("media-page-\(item.id)")
        } else if id == -2, endAction != nil {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle").font(.largeTitle)
                Text("已看完这段浏览记录").font(.headline)
                Button("加载当前最新内容") { action(.end) }.buttonStyle(.borderedProminent)
            }.foregroundStyle(.white).frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: 12) {
                Text("作品列表已更新").font(.callout)
                if !visibleItems.isEmpty {
                    Button("返回当前作品") { action(.recover) }
                        .buttonStyle(AppActionButtonStyle(tone: .neutral))
                }
            }.foregroundStyle(.white).frame(width: size.width, height: size.height)
                .accessibilityIdentifier("media.page.updated")
                .onAppear { action(.revealControls) }
        }
    }

    private func pageIsForegroundActive(id: Int, settled: Bool) -> Bool {
        settled && (focused == id || (awaitingNextItem && boundaryDemand?.anchorID == id)) && allowsForegroundMedia
    }

    private func noteForegroundWorkActivation(_ item: MediaItem) {
        guard allowsForegroundMedia, focused == item.id, let url = item.mediaURL, item.isVideo else { return }
        foregroundWorkActivation = ForegroundWorkActivation(identity: session.feedIdentity,
            queueRevision: queueRevision, owner: chromeScope, rootSlot: inlinePlayback ? rootParticipation.token : nil,
            workID: item.id, url: url)
    }

    private func hadForegroundWorkActivation(_ item: MediaItem) -> Bool {
        guard let url = item.mediaURL, let activation = foregroundWorkActivation else { return false }
        return activation.identity == session.feedIdentity && activation.queueRevision == queueRevision &&
            activation.owner == chromeScope && activation.rootSlot == (inlinePlayback ? rootParticipation.token : nil) &&
            activation.workID == item.id && activation.url == url
    }

    private func shouldPreserveActivationForPermit(_ item: MediaItem) -> Bool {
        pageVisualActivationPermit?.isAllowed == false && rootParticipation.isActive &&
            viewerVisible && scenePhase == .active && !playbackSuspended && hadForegroundWorkActivation(item)
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
    var onFavoriteManagement: ((MediaItem) -> Void)? = nil
    var onUnavailable: ((Int) -> Void)? = nil
    var historyContext: HistoryContext? = nil
    var resumePosition: Double? = nil
    var retainDuringInterruption = false
    var playbackOwner: UUID? = nil
    var playbackScope: String? = nil
    var playbackRootSlot: UUID? = nil
    var timelineWindow: VideoPlaybackNeighborWindow? = nil
    var preserveForPageCover = false
    var onPlaybackPrepared: (() -> Void)? = nil
    var onQualifiedExposure: ((MediaItem, HistoryContext) -> Void)? = nil
    @Environment(\.isEnabled) private var inputEnabled
    @EnvironmentObject private var session: SiteSession
    private let chrome = ViewingChromeController.shared
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
    private var railVisible: Bool {
        presentationLease.railHasAppeared
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
                                     chromeHidden: chromeHidden, onChromeHold: chromeAvailable ? toggleChrome : nil, pausedForOverlay: pausedForDetails, retainDuringInterruption: retainDuringInterruption, presentationLease: presentationLease,
                                     playbackOwner: playbackOwner, playbackScope: playbackScope, playbackRootSlot: playbackRootSlot,
                                     timelineWindow: timelineWindow, preserveForPageCover: preserveForPageCover, mediaBlurred: shouldBlur && !revealed,
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
                        }, onDisplayReady: { ready in
                            mediaReady = ready
                            if ready, active { onPlaybackPrepared?() }
                        }, onImageContent: { actualDisplayType = .image },
                                     transitionFrame: transitionFrame, usesTransitionPreview: usesTransitionPreview && (!shouldBlur || revealed),
                                     caption: { mediaCaption }, actionRail: { muted in mediaActionRail(muted: muted) })
                    }
                    else {
                        BitmapMediaSurface(url: url, active: active && (!shouldBlur || revealed), gestureTopExclusion: chromeHidden ? 0 : gestureTopExclusion, gestureExcludedFrames: chromeHidden ? [] : gestureExcludedFrames + actionHitFrames, pausedForOverlay: pausedForDetails,
                                           warmCoverRequest: inlinePlayback && !item.isVideo && !url.isFileURL
                                               ? MediaPosterPolicy.coverRequest(source: url, declared: item.posterURL, isVideo: false) : nil,
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
                Button { revealed = true } label: { Label("显示这条作品", systemImage: "eye").padding(FloatingPageChrome.cardInset).background(.ultraThinMaterial, in: FloatingPageChrome.controlShape) }
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
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if CollectionPagingQA.enabled && active {
                Text("ready=\(mediaReady)").font(.system(size: 1)).frame(width: 1, height: 1)
                    .opacity(0.01).allowsHitTesting(false).accessibilityIdentifier("media.qa.parent-ready")
                    .accessibilityValue("ready=\(mediaReady);active=\(active);enabled=\(inputEnabled);paused=\(pausedForDetails);chromeHidden=\(chromeHidden);rail=\(railVisible);suspended=\(chrome.isSuspended);scope=\(chromeScope?.uuidString ?? "nil");activeScope=\(chrome.activeScope?.uuidString ?? "nil")")
            }
        }
        #endif
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
            if current.active, !item.isStandaloneOfflineCopy, followAuthor == nil {
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
        .existingFeedbackToast(error, active: active && !chrome.hidden && !pausedForDetails, scope: item.id)
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
            case .cleanImage: return !displaysVideo && item.mediaURL != nil && chromeScope != nil && onToggleChrome != nil
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
            if item.isStandaloneOfflineCopy {
                MediaIconActionLabel(title: "离线", symbol: "internaldrive.fill", qaKey: "control.\(item.id).offline")
            } else { FavoriteButton(item: item, active: active, onManage: { onFavoriteManagement?($0) }) }
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
                #if DEBUG && targetEnvironment(simulator)
                PagerGestureTraceQA.lifecycle("page.rotateTap", ["forwarded": rotatePlayback != nil, "rail": railVisible])
                #endif
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
            if !item.isStandaloneOfflineCopy {
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
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("page.toggleChrome", ["active": active, "paused": pausedForDetails, "available": chromeAvailable])
        #endif
        guard active, !pausedForDetails, chromeAvailable else { return }
        onToggleChrome?()
    }

    private func confirmVideoContent() {
        // A positive image probe is more specific than the bitmap decoder's
        // generic "video content" response; do not oscillate between surfaces.
        if actualDisplayType == nil { actualDisplayType = .video }
    }

    private func openAuthor() {
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.active?.record("page.authorTap", ["id": item.id, "active": authorVisibility.active,
            "resolved": cachedAuthor != nil, "attributed": item.attributedCreator != nil])
        #endif
        guard authorVisibility.active else { return }
        if let author = followAuthor {
            onAuthor(CreatorRoute(creator: author, item: effectiveItem))
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
                #if DEBUG && targetEnvironment(simulator)
                PagerGestureTraceQA.active?.record("page.authorResolved", ["id": item.id,
                    "requestCurrent": authorLookup?.id == requestID, "identityCurrent": key.identity == session.feedIdentity,
                    "open": openAuthorOnResolve, "creatorValid": value.id > 0])
                #endif
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
            if let retry {
                Button(action: retry) { Label(retryLabel, systemImage: "arrow.clockwise").font(.caption) }
                    .buttonStyle(AppActionButtonStyle()).fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier(retryIdentifier)
            }
        }.padding(12).frame(maxWidth: 260)
            .existingFeedbackToast(message)
    }
}

struct CachedImage: View {
    let url: URL
    var fallbackURLs: [URL] = []
    var sharedResult: CachedPosterLoadResult? = nil
    var restoresDecodedCoverPreview = false
    var loadingEnabled = true
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
    var retriesTransientFailures = false
    @Environment(\.displayScale) private var displayScale
    @State private var failure: String?
    @State private var retry = 0
    @State private var ownedResult = CachedPosterLoadResult()
    private var loadResult: CachedPosterLoadResult { sharedResult ?? ownedResult }
    private var resourceIdentity: CachedPosterLoadResult.Identity { .image(primary: url, fallbackURLs: fallbackURLs) }
    private var image: UIImage? { loadResult.image(for: url, fallbackURLs: fallbackURLs) }
    private struct RequestKey: Equatable {
        let resource: CachedImageResourceIdentity
        let result: ObjectIdentifier
        let restoreDecodedPreview: Bool
        let retry: Int
        let externalRetry: Int
        let pixels: Int
        let loadingEnabled: Bool
    }
    var body: some View {
        GeometryReader { geometry in
            let pixels = pixelDemand(geometry.size)
            ZStack {
                AppTheme.secondarySurface
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
                } else if sharedResult == nil { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        .task(id: RequestKey(resource: CachedImageResourceIdentity(url: url, fallbackURLs: fallbackURLs),
                             result: ObjectIdentifier(loadResult), restoreDecodedPreview: restoresDecodedCoverPreview, retry: retry,
                             externalRetry: retryToken, pixels: pixelDemand(geometry.size), loadingEnabled: loadingEnabled)) {
            guard !Task.isCancelled else { return }
            guard loadingEnabled else { return }
            let identity = resourceIdentity
            var attempt = loadResult.begin(identity)
            onReady?(image != nil); onFailure?(false); onFailureMessage?(nil); failure = nil
            do {
                #if DEBUG && targetEnvironment(simulator)
                if sharedResult != nil, AuthorPaging176QA.holdsCovers { try await AuthorPaging176QA.holdCoverIfNeeded(url) }
                #endif
                if restoresDecodedCoverPreview {
                    let candidates = [url] + fallbackURLs
                    let tiers = [4096, 2048, 1024, 512, 256].filter { $0 <= pixels }
                    for tier in tiers {
                        let request = MediaPosterPolicy.CoverRequest(source: url, declared: nil, isVideo: false,
                            candidates: candidates, decodePixels: tier)
                        guard let preview = MediaCache.shared.preparedCoverMemory(request) else { continue }
                        try Task.checkCancellation()
                        guard loadResult.succeed(preview, identity: identity, attempt: attempt) else { return }
                        onReady?(true)
                        if pixels <= tier { return }
                        attempt = loadResult.begin(identity)
                        break
                    }
                }
                #if DEBUG && targetEnvironment(simulator)
                if placeholderTitle != nil && ProcessInfo.processInfo.arguments.contains("--qa-cover69-wait") { try await Task.sleep(for: .seconds(6)) }
                #endif
                let value: UIImage
                if retriesTransientFailures && !fallbackURLs.isEmpty {
                    value = try await MediaCache.shared.loadPreviewImage(candidates: [url] + fallbackURLs, pixels: pixelDemand(geometry.size))
                } else if retriesTransientFailures { value = try await MediaCache.shared.loadPreviewImage(url, pixels: pixelDemand(geometry.size)) }
                else { value = try await MediaCache.shared.loadImage(url, pixels: pixelDemand(geometry.size)) }
                guard !Task.isCancelled else { return }
                guard loadResult.succeed(value, identity: identity, attempt: attempt) else { return }
                onReady?(true)
            } catch is CancellationError {
                loadResult.cancel(identity: identity, attempt: attempt)
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A failed quality upgrade does not invalidate the existing
                // decoded image from this same source.
                guard loadResult.fail(identity: identity, attempt: attempt) else { return }
                if image != nil { return }
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
        }
        .onDisappear {
            if sharedResult == nil { ownedResult.clear() }
            onReady?(false)
        }
    }
    private func pixelDemand(_ size: CGSize) -> Int {
        let requested = Int(min(4096, max(1, max(size.width, size.height) * displayScale)))
        return [256, 512, 1024, 2048, 4096].first { $0 >= requested } ?? 4096
    }
}
