import SwiftUI
import UIKit

enum RootTab: Int, CaseIterable {
    case timeline = 0
    case leaderboard = 2
    case search = 4
    case collections = 3

    static let order = allCases.map(\.rawValue)
    static let destinations = allCases.map(\.destination)

    private var destination: (Int, String, String) {
        switch self {
        case .timeline: (rawValue, "时间线", "rectangle.portrait.on.rectangle.portrait")
        case .leaderboard: (rawValue, "作者榜", "person.3")
        case .search: (rawValue, "搜索", "magnifyingglass")
        case .collections: (rawValue, "收藏", "bookmark")
        }
    }
}

/// The production and UI-test roots use the same tab ownership, navigation
/// containers, labels and observation point. Content dependencies stay outside.
struct MainTabs<Timeline: View, Authors: View, Search: View, Collections: View>: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var session: SiteSession
    var onTimelineTap: () -> Void
    var onTimelineDoubleTap: () -> Void
    let timeline: Timeline
    let authors: Authors
    let search: Search
    let collections: Collections
    /// Revisions describe only external value inputs to root templates. Local
    /// observable state and bindings continue updating inside retained hosts.
    var pageContentRevisions: [Int: AnyHashable] = [:]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @State private var pageMotion = TabPageMotion()
    @State private var coveredRootTransition = CoveredRootTransition()
    @State private var visualActivation = PageVisualActivationPermit()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("timeline.presentation") private var timelinePresentation = TimelinePresentation.stream.rawValue
    #if DEBUG && targetEnvironment(simulator)
    @State private var canvasStarts179 = 0
    @State private var blackCanvasStarts179 = 0
    @State private var rootPreparations179 = 0
    #endif
    private let chrome = ViewingChromeController.shared
    @StateObject private var favoriteSelectionBar = FavoriteSelectionBar()
    @State private var lastTimelineRefresh = -Double.infinity
    @State private var compactBarHeight: CGFloat = 48
    @State private var compactBarSize: CGSize = .zero
    @Environment(\.displayScale) private var displayScale
    // A navigation push in the timeline ends playback, but must not resize its
    // underlying viewport while the next screen covers or reveals it.
    private var barOverMedia: Bool { selectedCanvasRole == .playback }
    /// The selected page owns ordinary color changes. A staged target is only
    /// a preview; cancelling it must not start a second full-window color flight.
    private var selectedCanvasRole: PageCanvasRole {
        if let committedTarget = pageMotion.committedRootCanvasRole(tab: selectedTab) { return committedTarget }
        if let role = pageMotion.currentCanvasRole(tab: selectedTab) { return role }
        if pageMotion.preparedTab != nil, let source = pageMotion.handoff?.source.appearance.canvasRole {
            return source
        }
        return selectedTab == RootTab.timeline.rawValue && timelinePresentation != TimelinePresentation.grid.rawValue ? .playback : .ordinary
    }
    private var destinationCanvasRole: PageCanvasRole {
        pageMotion.handoff?.surfaceDestination?.appearance.canvasRole
            ?? pageMotion.handoff?.destination?.appearance.canvasRole
            ?? selectedCanvasRole
    }
    private var destinationBarOverMedia: Bool {
        if case .playback = destinationCanvasRole { return true }
        return false
    }
    private var tabContent: some View {
        ZStack {
        RootTabHost(selected: selectedTab, prepared: pageMotion.preparedTab, pages: [
            RootTab.timeline.rawValue: AnyView(NavigationStack { timeline }.environment(\.overlaidTabBarHeight, compactBarHeight)),
            RootTab.leaderboard.rawValue: AnyView(NavigationStack { authors }.environment(\.overlaidTabBarHeight, compactBarHeight)),
            RootTab.search.rawValue: AnyView(NavigationStack { search }.environment(\.overlaidTabBarHeight, compactBarHeight)),
            RootTab.collections.rawValue: AnyView(NavigationStack { collections }.environment(\.overlaidTabBarHeight, compactBarHeight))
        ], contentRevisions: pageContentRevisions, motion: pageMotion, commit: applySelection)
        .ignoresSafeArea(.container, edges: .vertical)
        }
        .businessPage(isPresented: $session.showLogin, onDismiss: { session.oauth.cancel() }) { close in
            LoginView(onClose: close)
        }
        .environment(\.pageCanvasRole, selectedCanvasRole)
        .background(AppTheme.pageBackground(for: ordinaryScheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.tabPageMotion, pageMotion)
        .environment(\.overlaidTabBarHeight, compactBarHeight)
        .environment(\.viewingControlsReferenceInset, compactBarHeight)
        .environment(\.favoriteSelectionBar, favoriteSelectionBar)
        .environment(\.mediaTabs, MediaTabs(height: compactBarHeight, render: { overMedia, identifier, selection, onSelect in
            AnyView(CoveredRootTabControls(select: { id, scope in
                selectCoveredRoot(id, scope: scope, fallback: onSelect)
            }) { action in
                compactBar(selected: selectedTab, overMedia: overMedia, showsBatchActions: false,
                           identifier: identifier, selection: selection, onSelect: action)
            })
        }, select: selectFromPlayback))
        .overlay(alignment: .bottom) {
            measuredBar.viewingChromeHidden(barOverMedia && chrome.hidden)
        }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--qa-canvas-cancel179") {
                Text("canvas ownership").font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                    .allowsHitTesting(false).accessibilityIdentifier("canvas.cancel179.qa")
                    .accessibilityValue("selected=\(selectedTab);starts=\(canvasStarts179);black=\(blackCanvasStarts179);active=false;preview=\(pageMotion.preparedTab != nil);prepared=\(rootPreparations179)")
            }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--qa-root-activation181")
                || ProcessInfo.processInfo.arguments.contains("--qa-native-activation181") {
                SwiftUI.TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    let playing = VideoPlaybackSessions.shared.entries.filter { $0.player.rate != 0 }.count
                    let value = "allowed=\(visualActivation.isAllowed);playing=\(playing)"
                    Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                        .allowsHitTesting(false).accessibilityIdentifier("root.activation181.qa")
                        .accessibilityValue(value)
                }
            }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if RootTransition180QA.enabled {
                RootTransition180QAView(motion: pageMotion,
                    selectedTab: { selectedTab },
                    selectTab: { select($0) },
                    commitEdge: applySelection,
                    canvasStarts: { (canvasStarts179, blackCanvasStarts179) })
                    .frame(width: 1, height: 1).opacity(0.01)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        #endif
        .tint(.blue)
        #if DEBUG && targetEnvironment(simulator)
        .onChange(of: pageMotion.preparedTab) { _, target in
            if target != nil, ProcessInfo.processInfo.arguments.contains("--qa-canvas-cancel179") { rootPreparations179 += 1 }
        }
        #endif
        .onChange(of: selectedTab) { _, selected in
            chrome.reveal(); favoriteSelectionBar.clear()
        }
        .onChange(of: session.accountSessionID) { _, _ in
            coveredRootTransition.cancel(reason: "cover-root-account-changed")
            PageBodyHandoff.cancelAll()
            VideoPlaybackSessions.shared.reset()
            PageEdgeReturnPolicy.invalidatePreviewCache()
            pageMotion.cancel()
            pageMotion.takeHeaderOwnership(from: selectedTab)
        }
        #if DEBUG && targetEnvironment(simulator)
        .modifier(HandoffIdentityQA())
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                coveredRootTransition.cancel(reason: "cover-root-scene-inactive")
                pageMotion.cancel()
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            tabContent.environment(\.floatingPageSafeInsets, geometry.safeAreaInsets)
                .environment(\.pageVisualActivationPermit, visualActivation)
        }
        .preference(key: RootPlaybackCanvasPreferenceKey.self, value: selectedCanvasRole == .playback)
        .onAppear { registerRootFooterRenderer() }
        .onChange(of: compactBarSize) { _, _ in registerRootFooterRenderer() }
        .onChange(of: ordinaryScheme) { _, _ in registerRootFooterRenderer() }
        .onChange(of: displayScale) { _, _ in registerRootFooterRenderer() }
        .onChange(of: reduceTransparency) { _, _ in registerRootFooterRenderer() }
        .onChange(of: dynamicTypeSize) { _, _ in registerRootFooterRenderer() }
        .onDisappear {
            pageMotion.cancel()
            pageMotion.rootFooterRenderer = nil
        }
    }

    private var measuredBar: some View {
        compactBar(selected: selectedTab, overMedia: barOverMedia, showsBatchActions: true, onSelect: select)
            .environment(\.pageCanvasRole, selectedCanvasRole)
            .environment(\.rootFooterMotion, pageMotion.rootFooterMotion)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
                if compactBarSize != size { compactBarSize = size }
                if compactBarHeight != size.height { compactBarHeight = size.height }
            }
    }

    @MainActor private func registerRootFooterRenderer() {
        let size = compactBarSize
        let scheme = ordinaryScheme
        let scale = displayScale
        let reduceTransparency = reduceTransparency
        let dynamicTypeSize = dynamicTypeSize
        let choices = RootTab.destinations
        let motion = pageMotion
        let selectionBar = favoriteSelectionBar
        let siteSession = session
        motion.rootFooterRenderer = { [size, scheme, scale, reduceTransparency, dynamicTypeSize, choices, weak motion, weak selectionBar, siteSession] selected, overMedia in
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("footerRaster", cost174) }
        #endif
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            let content = Self.compactBarView(
                selected: selected, overMedia: overMedia, showsBatchActions: false,
                identifier: "main.tabs.root-footer-snapshot",
                selection: selected == motion?.rootHost?.selected ? selectionBar?.entry : nil,
                ordinaryScheme: scheme, choices: choices, chromeHidden: false, onSelect: { _ in }, onRefresh: {},
                snapshot: true, opaqueOverride: reduceTransparency
            )
            let renderer = ImageRenderer(content: content
                .frame(width: size.width, height: size.height)
                .background(Color.clear)
                .environment(\.pageSurfaceTone, nil)
                .environmentObject(siteSession)
                .environment(\.dynamicTypeSize, dynamicTypeSize))
            renderer.scale = scale
            renderer.isOpaque = false
            return renderer.uiImage
        }
    }

    private func compactBar(selected: Int, overMedia: Bool, showsBatchActions: Bool, identifier: String = "main.tabs.compact",
                            selection: FavoriteSelectionBar.Entry? = nil,
                            onSelect: @escaping (Int) -> Void) -> some View {
        Self.compactBarView(
            selected: selected, overMedia: overMedia, showsBatchActions: showsBatchActions,
            identifier: identifier, selection: showsBatchActions ? favoriteSelectionBar.entry : selection,
            ordinaryScheme: ordinaryScheme, choices: RootTab.destinations,
            chromeHidden: chrome.hidden, onSelect: onSelect,
            onRefresh: { select(RootTab.timeline.rawValue, refresh: true) }, snapshot: false,
            onTimelineVisit: { select(RootTab.timeline.rawValue, refresh: false, timelineVisit: $0) }
        )
    }

    @ViewBuilder private static func compactBarView(selected: Int, overMedia: Bool, showsBatchActions: Bool,
                                                     identifier: String, selection: FavoriteSelectionBar.Entry?,
                                                     ordinaryScheme: ColorScheme,
                                                     choices: [(Int, String, String)], chromeHidden: Bool,
                                                     onSelect: @escaping (Int) -> Void,
                                                     onRefresh: @escaping () -> Void, snapshot: Bool, opaqueOverride: Bool? = nil,
                                                     onTimelineVisit: ((TimelineTabVisit) -> Void)? = nil) -> some View {
        let bar = HStack(spacing: FloatingPageChrome.groupInset) {
            ForEach(choices, id: \.0) { destination in
                if destination.0 == RootTab.timeline.rawValue, showsBatchActions, let onTimelineVisit {
                    tabButton(destination, selected: selected == destination.0, overMedia: overMedia,
                              onSelect: onSelect, timelineInput: TimelineTabButtonStyle(
                                selected: selected == destination.0, onVisit: onTimelineVisit, onDoubleTap: onRefresh))
                        .accessibilityAction(named: Text("从头刷新时间线"), onRefresh)
                } else {
                    tabButton(destination, selected: selected == destination.0, overMedia: overMedia, onSelect: onSelect)
                }
            }
        }
        .opacity(selection == nil ? 1 : 0)
        .allowsHitTesting(selection == nil)
        .accessibilityHidden(selection != nil)
        .overlay {
            if let selection { FavoriteBatchBarButtons(entry: selection).id(selection.owner) }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .padding(.horizontal, FloatingPageChrome.groupInset).padding(.vertical, 2)
        .background { PageToneBarSurface(overMedia: overMedia, opaqueOverride: opaqueOverride) }
        .padding(.horizontal, PlaybackChrome.horizontalInset)
        .environment(\.colorScheme, overMedia ? .dark : ordinaryScheme)

        if snapshot {
            bar
        } else {
            bar
                .background {
                    FixedBottomBarMarker(enabled: !overMedia || !chromeHidden,
                        content: FixedBottomBarContent(identifier: identifier, selectedTab: selected,
                                                       overMedia: overMedia, selectionOwner: selection?.owner))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .floatingControlsDrawable(identifier: identifier, visible: !overMedia || !chromeHidden)
                .accessibilityElement(children: .contain).accessibilityAddTraits(.isTabBar)
                .accessibilityIdentifier(identifier)
        }
    }
    private static func tabButton(_ destination: (Int, String, String), selected: Bool, overMedia: Bool,
                                  onSelect: @escaping (Int) -> Void, timelineInput: TimelineTabButtonStyle? = nil) -> some View {
        let button = Button { onSelect(destination.0) } label: {
            VStack(spacing: ContentMetrics.Optical.iconTextGap) {
                Image(systemName: destination.2)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 14)
                Text(destination.1)
                    .font(AppTypography.tabLabel.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
            }
            .frame(height: FloatingPageChrome.visibleHeight(nested: true))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight)
            .modifier(PageToneBarInk(tab: destination.0, selected: selected, overMedia: overMedia))
            .contentShape(Rectangle())
        }
        return Group {
            if let timelineInput {
                button.buttonStyle(timelineInput)
            } else {
                button.buttonStyle(.plain)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(destination.1)
        .accessibilityIdentifier(destination.0 == RootTab.timeline.rawValue ? "main.tab.timeline" : "main.tab.\(destination.0)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func select(_ id: Int) {
        select(id, refresh: false)
    }

    private func select(_ id: Int, refresh: Bool, timelineVisit: TimelineTabVisit? = nil) {
        NavigationDiagnostics.mark(.rootRequested, tab: id)
        let account = session.accountSessionID
        let commit = {
            let reselectsCurrentTab = id == selectedTab
            applySelection(id)
            if refresh { refreshTimeline() }
            else if let timelineVisit {
                timelineVisit.didCommit {
                    guard selectedTab == id, session.accountSessionID == account else { return }
                    refreshTimeline()
                }
            } else if reselectsCurrentTab && id == RootTab.timeline.rawValue { onTimelineTap() }
        }
        if id != selectedTab, !reduceMotion,
           RootTab(rawValue: selectedTab) != nil,
           RootTab(rawValue: id) != nil {
            pageMotion.switchPage(from: selectedTab, to: id, select: commit)
        } else {
            pageMotion.cancel()
            if id != selectedTab { pageMotion.takeHeaderOwnership(from: selectedTab) }
            commit()
        }
    }

    private func selectFromPlayback(_ exit: MediaTabExit) {
        guard exit.id != selectedTab else { return }
        pageMotion.cancel()
        pageMotion.takeHeaderOwnership(from: selectedTab)
        withoutPageAnimation { applySelection(exit.id) }
    }

    private func selectCoveredRoot(_ id: Int, scope: UUID?, fallback: @escaping (Int) -> Void) {
        guard !coveredRootTransition.isActive else { return }
        guard let scope else { fallback(id); return }
        let identity = session.feedIdentity
        if coveredRootTransition.select(id, scope: scope, host: pageMotion.rootHost,
            identity: identity, account: session.accountSessionID, reduceMotion: reduceMotion,
            selected: selectedTab, ordinaryScheme: ordinaryScheme,
            rootPermit: visualActivation, isCurrent: { session.feedIdentity == identity },
            commit: { applySelection(id) }, fallback: { fallback(id) }) { return }
        // A lost source is not permission to keep the user trapped. Preserve
        // the existing business action when a visual session cannot begin.
        fallback(id)
    }

    private func applySelection(_ id: Int) {
        NavigationDiagnostics.mark(.rootSelected, tab: id)
        if id != selectedTab {
            pageMotion.markRootTabDeparture(from: selectedTab)
        }
        if id != RootTab.timeline.rawValue { chrome.endInlinePlayer() }
        selectedTab = id
    }
    private func refreshTimeline() {
        let now = CACurrentMediaTime()
        guard now - lastTimelineRefresh >= 0.65 else { return }
        lastTimelineRefresh = now; onTimelineDoubleTap()
    }
}

/// Refresh belongs to the exact navigation started by the first physical tap.
@MainActor private final class TimelineTabVisit {
    private var requestedRefresh = false
    private var refresh: (() -> Void)?

    func requestRefresh() {
        guard !requestedRefresh else { return }
        requestedRefresh = true
        refresh?()
        refresh = nil
    }

    func didCommit(refresh: @escaping () -> Void) {
        if requestedRefresh { refresh() }
        else { self.refresh = refresh }
    }
}

private struct TimelineTabButtonStyle: PrimitiveButtonStyle {
    let selected: Bool
    let onVisit: (TimelineTabVisit) -> Void
    let onDoubleTap: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .overlay {
                TimelineTabTouchInput(selected: selected, onVisit: onVisit,
                                      onReselect: { configuration.trigger() }, onDoubleTap: onDoubleTap)
                    .accessibilityHidden(true)
            }
            .accessibilityAction { configuration.trigger() }
    }
}

/// The real footer supplies the hit rectangle. Window recognizers keep the
/// second tap observable while a root flight temporarily shields new touches.
private struct TimelineTabTouchInput: UIViewRepresentable {
    let selected: Bool
    let onVisit: (TimelineTabVisit) -> Void
    let onReselect: () -> Void
    let onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) { context.coordinator.input = self }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.install(on: nil) }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.install(on: self)
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var input: TimelineTabTouchInput
        private weak var anchor: Anchor?
        private weak var window: UIWindow?
        private var doubleStartedOnTimeline = false
        private var visit: (firstTouch: TimeInterval, action: TimelineTabVisit)?
        private lazy var crossTabTap = makeTap(count: 1, action: #selector(navigate(_:)))
        private lazy var reselectTap = makeTap(count: 1, action: #selector(reselect(_:)))
        private lazy var doubleTap = makeTap(count: 2, action: #selector(refresh(_:)))

        init(_ input: TimelineTabTouchInput) { self.input = input }
        private func makeTap(count: Int, action: Selector) -> TimelineFooterTapGesture {
            let tap = TimelineFooterTapGesture(target: self, action: action)
            tap.numberOfTapsRequired = count
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }

        func install(on view: Anchor?) {
            anchor = view
            let nextWindow = view?.window
            guard window !== nextWindow else { return }
            let taps = [crossTabTap, reselectTap, doubleTap]
            if let window { taps.forEach(window.removeGestureRecognizer) }
            visit = nil
            window = nextWindow
            guard let nextWindow else { return }
            reselectTap.require(toFail: doubleTap)
            taps.forEach(nextWindow.addGestureRecognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let anchor, let window, anchor.window === window,
                  window.windowScene?.activationState == .foregroundActive,
                  anchor.bounds.contains(touch.location(in: anchor)) else { return false }
            let onButton = touch.view === anchor
            if gestureRecognizer === crossTabTap { return onButton && !input.selected }
            if gestureRecognizer === reselectTap { return onButton && input.selected }

            if let firstTouch = doubleTap.firstTouch {
                return onButton || (visit?.firstTouch == firstTouch && PageInteractionShield.blocksNewTouches(in: window))
            }
            guard onButton else { return false }
            doubleStartedOnTimeline = input.selected
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === crossTabTap && other === doubleTap) ||
                (gestureRecognizer === doubleTap && other === crossTabTap)
        }

        @objc private func navigate(_ tap: TimelineFooterTapGesture) {
            guard let firstTouch = tap.firstTouch else { return }
            let action = TimelineTabVisit()
            visit = (firstTouch, action)
            input.onVisit(action)
        }

        @objc private func reselect(_ tap: TimelineFooterTapGesture) { input.onReselect() }

        @objc private func refresh(_ tap: TimelineFooterTapGesture) {
            guard let firstTouch = tap.firstTouch else { return }
            if doubleStartedOnTimeline {
                guard input.selected else { return }
                input.onDoubleTap()
            } else if visit?.firstTouch == firstTouch {
                visit?.action.requestRefresh()
                visit = nil
            }
        }
    }
}

private final class TimelineFooterTapGesture: UITapGestureRecognizer {
    private(set) var firstTouch: TimeInterval?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if firstTouch == nil { firstTouch = touches.first?.timestamp }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        firstTouch = nil
        super.reset()
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct HandoffIdentityQA: ViewModifier {
    @EnvironmentObject private var session: SiteSession
    @State private var injected = false
    private var enabled: Bool { CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-body-identity164") }
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if enabled { Text(session.feedIdentity).font(.system(size: 1)).opacity(0.01)
                .allowsHitTesting(false).accessibilityIdentifier("body.identity.qa") }
        }.onReceive(NotificationCenter.default.publisher(for: PageBodyHandoff.qaStateDidChange)) { event in
            guard enabled, !injected else { return }
            let expected = ProcessInfo.processInfo.arguments.contains("--qa-body-identity-hold164") ? "holding" : "handoff"
            guard event.userInfo?["kind"] as? String == "edge-return",
                  event.userInfo?["phase"] as? String == expected else { return }
            DispatchQueue.main.async {
                guard !injected else { return }
                injected = true
                session.invalidateVisualIdentityForQA()
            }
        }
    }
}
#endif
