import SwiftUI
import UIKit

struct MediaTabExit {
    let id: Int
    let fromMedia: Bool
}

struct MediaTabs {
    let height: CGFloat
    let render: (_ overMedia: Bool, _ identifier: String, _ selection: FavoriteSelectionBar.Entry?, _ tone: PageToneTransition?, _ onSelect: @escaping (Int) -> Void) -> AnyView
    let select: (MediaTabExit) -> Void
}

extension EnvironmentValues {
    @Entry var mediaTabs: MediaTabs? = nil
    @Entry var exitMediaCoverToTab: ((MediaTabExit) -> Void)? = nil
    @Entry var rotatePlayback: (() -> Void)? = nil
}

enum MediaPresentationSource { case ordinary, playback }

private struct MediaCover<Item: Identifiable, Presented: View>: ViewModifier {
    @Binding var item: Item?
    var onDismiss: () -> Void
    let source: MediaPresentationSource
    @ViewBuilder var presented: (Item) -> Presented
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var parentExit
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @State private var route = NativeHeaderRoute()
    @State private var playbackOrientation = PlaybackOrientationSession()
    @State private var exitsToTab = false

    func body(content: Content) -> some View {
        content.pinnedPageCover(item: $item, route: route, destinationRole: .playback, sourceRole: source == .playback ? .playback : .ordinary, animateDismissal: !exitsToTab, onDismiss: {
            playbackOrientation.restore()
            exitsToTab = false
            onDismiss()
        }) { opening in
            presented(opening)
                .environment(\.rotatePlayback, { playbackOrientation.rotate() })
                .environment(\.exitMediaCoverToTab, tabs.map { _ in
                    { exit in
                        guard item != nil else { return }
                        // Waiting for dismissal before selecting the tab
                        // exposes the old grid between presentations.
                        withoutPageAnimation {
                            exitsToTab = true
                            playbackOrientation.restore()
                            item = nil
                            (parentExit ?? tabs?.select)?(exit)
                        }
                    }
                })
        }
        .transaction {
            // A native pager hosts its media page in a separate SwiftUI root.
            // Keep the exit policy attached until that cover has dismissed.
            if exitsToTab, item == nil {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }
}

extension View {
    func mediaCover<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, source: MediaPresentationSource = .ordinary, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> Presented
    ) -> some View {
        modifier(MediaCover(item: item, onDismiss: onDismiss, source: source, presented: content))
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @State private var pageMotion = TabPageMotion()
    @Environment(\.scenePhase) private var scenePhase
    private struct CanvasHandoff {
        let tone: PageToneTransition
        // A playback change has a direction. A system appearance change does not.
        let destinationIsMedia: Bool?
    }

    @State private var canvasHandoff: CanvasHandoff?
    @State private var pendingCoverExit: MediaTabExit?
    @ObservedObject private var chrome = ViewingChromeController.shared
    @StateObject private var favoriteSelectionBar = FavoriteSelectionBar()
    @State private var previousTimelineTap: CFTimeInterval?
    @State private var lastTimelineRefresh = -Double.infinity
    @State private var compactBarHeight: CGFloat = 48
    @State private var compactBarSize: CGSize = .zero
    @Environment(\.displayScale) private var displayScale
    // A navigation push in the timeline ends playback, but must not resize its
    // underlying viewport while the next screen covers or reveals it.
    private var overlaysBottomBar: Bool { selectedTab == 0 }
    private var barOverMedia: Bool { overlaysBottomBar && chrome.hasInlinePlayer }
    private var destinationCanvasRole: PageCanvasRole {
        if let staged = pageMotion.handoff?.surfaceDestination?.appearance.canvasRole
            ?? pageMotion.handoff?.destination?.appearance.canvasRole {
            return staged
        }
        if let role = pageMotion.currentCanvasRole(tab: selectedTab) { return role }
        if pageMotion.preparedTab != nil, let source = pageMotion.handoff?.source.appearance.canvasRole {
            return source
        }
        return barOverMedia ? .playback : .ordinary
    }
    private var destinationBarOverMedia: Bool {
        if case .playback = destinationCanvasRole { return true }
        return false
    }
    private var pendingCoverTargetRole: Bool? {
        guard let exit = pendingCoverExit, let role = pageMotion.currentCanvasRole(tab: exit.id) else { return nil }
        if case .playback = role { return true }
        return false
    }
    private let destinations: [(Int, String, String)] = [
        (0, "时间线", "rectangle.portrait.on.rectangle.portrait"),
        (2, "作者榜", "person.3"), (4, "搜索", "magnifyingglass"), (3, "收藏", "bookmark")
    ]

    private var tabContent: some View {
        ZStack {
        RootTabHost(selected: selectedTab, prepared: pageMotion.preparedTab, pages: [
            0: AnyView(NavigationStack { timeline }.environment(\.overlaidTabBarHeight, compactBarHeight)),
            2: AnyView(NavigationStack { authors }.environment(\.overlaidTabBarHeight, compactBarHeight)),
            4: AnyView(NavigationStack { search }.environment(\.overlaidTabBarHeight, compactBarHeight)),
            3: AnyView(NavigationStack { collections }.environment(\.overlaidTabBarHeight, compactBarHeight))
        ], motion: pageMotion, commit: { applySelection($0, isTap: false) })
        .ignoresSafeArea(.container, edges: .vertical)
        }
        .businessPage(isPresented: $session.showLogin, onDismiss: { session.oauth.cancel() }) { close in
            LoginView(onClose: close)
        }
        .environment(\.pageCanvasRole, barOverMedia ? .playback : .ordinary)
        .background(destinationBarOverMedia ? Color.black : AppTheme.pageBackground(for: ordinaryScheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.tabPageMotion, pageMotion)
        .environment(\.overlaidTabBarHeight, compactBarHeight)
        .environment(\.viewingControlsReferenceInset, compactBarHeight)
        .environment(\.favoriteSelectionBar, favoriteSelectionBar)
        .environment(\.mediaTabs, MediaTabs(height: compactBarHeight, render: { overMedia, identifier, selection, tone, onSelect in
            AnyView(compactBar(selected: selectedTab, overMedia: overMedia, showsBatchActions: false,
                               identifier: identifier, selection: selection, tone: tone, onSelect: onSelect))
        }, select: selectFromPlayback))
        .overlay(alignment: .top) {
            if barOverMedia { PlaybackStatusBarScrim() }
        }
        .overlay {
            if let canvasHandoff {
                let tone = canvasHandoff.tone
                PageToneBlend(tone: tone) {
                    if self.canvasHandoff?.tone.id == tone.id {
                        self.canvasHandoff = nil
                        pageMotion.clearCanvasTone(tone.id)
                    }
                }
                .id(tone.id)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            measuredBar.viewingChromeHidden(barOverMedia && chrome.hidden)
        }
        .tint(.blue)
        .onChange(of: selectedTab) { _, selected in
            chrome.reveal(); favoriteSelectionBar.clear()
            if pendingCoverExit?.id != selected { pendingCoverExit = nil }
        }
        .onChange(of: destinationBarOverMedia) { wasOverMedia, isOverMedia in
            if pendingCoverExit != nil {
                consumePendingCoverExit()
                return
            }
            guard canvasHandoff?.destinationIsMedia != isOverMedia else { return }
            blendCanvas(fromMedia: wasOverMedia, toMedia: isOverMedia)
        }
        .onChange(of: pendingCoverTargetRole) { _, _ in
            Task { @MainActor in
                await Task.yield()
                consumePendingCoverExit()
            }
        }
        .onChange(of: ordinaryScheme) { previous, _ in
            guard !destinationBarOverMedia, !reduceMotion else { return }
            if pageMotion.hasActiveBodyHandoff {
                if let id = canvasHandoff?.tone.id { pageMotion.clearCanvasTone(id) }
                canvasHandoff = nil
                return
            }
            canvasHandoff = CanvasHandoff(tone: PageToneTransition(source: AppTheme.pageBackground(for: previous), sourceScheme: previous),
                                          destinationIsMedia: nil)
        }
        .onChange(of: session.accountSessionID) { _, _ in
            pendingCoverExit = nil
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
            if phase != .active { pendingCoverExit = nil; pageMotion.cancel() }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            tabContent.environment(\.floatingPageSafeInsets, geometry.safeAreaInsets)
        }
        .onAppear { registerRootFooterRenderer() }
        .onChange(of: compactBarSize) { _, _ in registerRootFooterRenderer() }
        .onChange(of: ordinaryScheme) { _, _ in registerRootFooterRenderer() }
        .onChange(of: displayScale) { _, _ in registerRootFooterRenderer() }
        .onChange(of: reduceTransparency) { _, _ in registerRootFooterRenderer() }
        .onChange(of: dynamicTypeSize) { _, _ in registerRootFooterRenderer() }
        .onDisappear {
            pendingCoverExit = nil; pageMotion.cancel()
            pageMotion.rootFooterRenderer = nil
        }
    }

    private var measuredBar: some View {
        compactBar(selected: selectedTab, overMedia: destinationBarOverMedia, showsBatchActions: true,
                   tone: pageMotion.handoff?.surfaceTone ?? canvasHandoff?.tone, onSelect: select)
            .environment(\.pageCanvasRole, destinationBarOverMedia ? .playback : .ordinary)
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
        let choices = destinations
        let motion = pageMotion
        let selectionBar = favoriteSelectionBar
        let siteSession = session
        motion.rootFooterRenderer = { [size, scheme, scale, reduceTransparency, dynamicTypeSize, choices, weak motion, weak selectionBar, siteSession] selected, overMedia in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            let content = Self.compactBarView(
                selected: selected, overMedia: overMedia, showsBatchActions: false,
                identifier: "main.tabs.root-footer-snapshot",
                selection: selected == motion?.rootHost?.selected ? selectionBar?.entry : nil, tone: nil,
                ordinaryScheme: scheme, choices: choices, chromeHidden: false, onSelect: { _ in }, onRefresh: {},
                snapshot: true, opaqueOverride: reduceTransparency
            )
            let renderer = ImageRenderer(content: content
                .frame(width: size.width, height: size.height)
                .background(Color.clear)
                .environment(\.pageSurfaceTone, nil)
                .environment(\.pageWindowToneContext, nil)
                .environmentObject(siteSession)
                .environment(\.dynamicTypeSize, dynamicTypeSize))
            renderer.scale = scale
            renderer.isOpaque = false
            return renderer.uiImage
        }
    }

    private func compactBar(selected: Int, overMedia: Bool, showsBatchActions: Bool, identifier: String = "main.tabs.compact",
                            selection: FavoriteSelectionBar.Entry? = nil, tone: PageToneTransition?,
                            onSelect: @escaping (Int) -> Void) -> some View {
        Self.compactBarView(
            selected: selected, overMedia: overMedia, showsBatchActions: showsBatchActions,
            identifier: identifier, selection: showsBatchActions ? favoriteSelectionBar.entry : selection,
            tone: tone, ordinaryScheme: ordinaryScheme, choices: destinations,
            chromeHidden: chrome.hidden, onSelect: onSelect, onRefresh: refreshTimeline, snapshot: false
        )
    }

    @ViewBuilder private static func compactBarView(selected: Int, overMedia: Bool, showsBatchActions: Bool,
                                                     identifier: String, selection: FavoriteSelectionBar.Entry?,
                                                     tone: PageToneTransition?, ordinaryScheme: ColorScheme,
                                                     choices: [(Int, String, String)], chromeHidden: Bool,
                                                     onSelect: @escaping (Int) -> Void,
                                                     onRefresh: @escaping () -> Void, snapshot: Bool, opaqueOverride: Bool? = nil) -> some View {
        let bar = HStack(spacing: FloatingPageChrome.groupInset) {
            ForEach(choices, id: \.0) { destination in
                if destination.0 == 0 && showsBatchActions {
                    tabButton(destination, selected: selected == destination.0, overMedia: overMedia, tone: tone, onSelect: onSelect)
                        .accessibilityAction(named: Text("从头刷新时间线"), onRefresh)
                } else {
                    tabButton(destination, selected: selected == destination.0, overMedia: overMedia, tone: tone, onSelect: onSelect)
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
        .background { PageToneBarSurface(overMedia: overMedia, fallback: snapshot ? nil : tone, opaqueOverride: opaqueOverride) }
        .padding(.horizontal, PlaybackChrome.horizontalInset)
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isTabBar)
        .accessibilityIdentifier(identifier)
        .environment(\.colorScheme, overMedia ? .dark : ordinaryScheme)

        if snapshot {
            bar
        } else {
            bar
                .background { PageToneBarCanvas() }
                .modifier(PageWindowToneReader())
                .background { FixedBottomBarMarker(enabled: !overMedia || !chromeHidden).allowsHitTesting(false).accessibilityHidden(true) }
        }
    }
    private static func tabButton(_ destination: (Int, String, String), selected: Bool, overMedia: Bool, tone: PageToneTransition?,
                                  onSelect: @escaping (Int) -> Void) -> some View {
        Button { onSelect(destination.0) } label: {
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
            .modifier(PageToneBarInk(selected: selected, overMedia: overMedia, fallback: tone))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(destination.1)
        .accessibilityIdentifier(destination.0 == 0 ? "main.tab.timeline" : "main.tab.\(destination.0)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func select(_ id: Int) {
        if id != selectedTab, !reduceMotion,
           destinations.contains(where: { $0.0 == selectedTab }),
           destinations.contains(where: { $0.0 == id }) {
            pageMotion.switchPage(from: selectedTab, to: id) {
                applySelection(id)
            }
        } else {
            pageMotion.cancel()
            if id != selectedTab { pageMotion.takeHeaderOwnership(from: selectedTab) }
            applySelection(id)
        }
    }

    private func selectFromPlayback(_ exit: MediaTabExit) {
        pendingCoverExit = exit
        guard exit.id != selectedTab else { return }
        pageMotion.cancel()
        pageMotion.takeHeaderOwnership(from: selectedTab)
        withoutPageAnimation { applySelection(exit.id, isTap: false) }
        Task { @MainActor in
            await Task.yield()
            consumePendingCoverExit()
        }
    }

    private func consumePendingCoverExit() {
        guard let exit = pendingCoverExit, selectedTab == exit.id,
              let destinationIsMedia = pendingCoverTargetRole else { return }
        pendingCoverExit = nil
        blendCanvas(fromMedia: exit.fromMedia, toMedia: destinationIsMedia)
    }

    private func blendCanvas(fromMedia: Bool, toMedia: Bool, suspended: Bool = false) {
        // A cover already owns this window's color flight, including ancestor bars.
        if pageMotion.hasActiveBodyHandoff {
            if let id = canvasHandoff?.tone.id { pageMotion.clearCanvasTone(id) }
            canvasHandoff = nil; return
        }
        guard fromMedia != toMedia, ordinaryScheme == .light, !reduceMotion else { return }
        let source: Color = fromMedia ? .black : AppTheme.pageBackground(for: ordinaryScheme)
        // A quick reversal starts from the shade the outgoing blend has reached.
        let tone: PageToneTransition
        if let navigationTone = pageMotion.navigationTone(from: fromMedia ? .playback : .ordinary, tab: selectedTab) {
            tone = navigationTone
        } else if let active = canvasHandoff, active.destinationIsMedia == fromMedia {
            tone = active.tone.reversed(from: source, sourceScheme: fromMedia ? .dark : ordinaryScheme, sourceIsMedia: fromMedia)
        } else {
            tone = PageToneTransition(source: source, sourceScheme: fromMedia ? .dark : ordinaryScheme, sourceIsMedia: fromMedia, suspended: suspended)
        }
        pageMotion.rememberCanvasTone(tone, tab: selectedTab)
        canvasHandoff = CanvasHandoff(tone: tone, destinationIsMedia: toMedia)
    }

    private func applySelection(_ id: Int, isTap: Bool = true) {
        let reselectsCurrentTab = id == selectedTab
        if id != selectedTab {
            pageMotion.markRootTabDeparture(from: selectedTab)
        }
        if id != 0 { chrome.endInlinePlayer() }
        selectedTab = id
        guard id == 0 else { previousTimelineTap = nil; return }
        guard isTap else { previousTimelineTap = nil; return }
        let now = CACurrentMediaTime()
        if let previousTimelineTap, now - previousTimelineTap <= 0.4 {
            self.previousTimelineTap = nil; refreshTimeline()
        } else {
            previousTimelineTap = now
            if reselectsCurrentTab { onTimelineTap() }
        }
    }
    private func refreshTimeline() {
        let now = CACurrentMediaTime()
        guard now - lastTimelineRefresh >= 0.65 else { return }
        lastTimelineRefresh = now; onTimelineDoubleTap()
    }
}

/// Observe completed taps without replacing SwiftUI's tab delegate. A single
/// completed tap returns to the current queue's start. A second nearby tap
/// requests a new first page; it is not left to UIKit's re-selection behavior.
struct TimelineTabDoubleTap: UIViewRepresentable {
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onDoubleTap: onDoubleTap) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        context.coordinator.probe = view
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.attach()
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: UIView {
        var onLayout: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onLayout?() }
        override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var probe: Probe?
        private weak var host: UIWindow?
        private weak var bar: UITabBar?
        private weak var item: UITabBarItem?
        var onTap: () -> Void
        var onDoubleTap: () -> Void
        private var retry: DispatchWorkItem?
        private var attempts = 0
        private var previousTap: (time: CFTimeInterval, point: CGPoint)?
        private var lastDelivery = -Double.infinity
        private var customAction: UIAccessibilityCustomAction?
        private lazy var gesture: UITapGestureRecognizer = {
            let value = UITapGestureRecognizer(target: self, action: #selector(tapped))
            value.cancelsTouchesInView = false
            value.delaysTouchesBegan = false
            value.delaysTouchesEnded = false
            value.delegate = self
            return value
        }()
        init(onTap: @escaping () -> Void, onDoubleTap: @escaping () -> Void) {
            self.onTap = onTap; self.onDoubleTap = onDoubleTap
        }
        func attach() {
            guard let window = probe?.window else { detach(); return }
            var candidates: [UITabBarController] = []
            func collect(_ controller: UIViewController?) {
                guard let controller else { return }
                if let tabs = controller as? UITabBarController,
                   tabs.tabBar.window === window, tabs.tabBar.items?.first?.title == "时间线" {
                    candidates.append(tabs)
                }
                for child in controller.children { collect(child) }
                collect(controller.presentedViewController)
            }
            // Prefer the Probe's own controller ancestry. The zero-size
            // TabView background may instead be hosted above the tab controller;
            // in that case accept only one matching controller in this window.
            var responder: UIResponder? = probe
            var owner: UITabBarController?
            while let value = responder {
                if let controller = value as? UIViewController,
                   let tabs = (controller as? UITabBarController) ?? controller.tabBarController,
                   tabs.tabBar.items?.first?.title == "时间线" { owner = tabs; break }
                responder = value.next
            }
            if owner == nil {
                collect(window.rootViewController)
                if candidates.count == 1 { owner = candidates[0] }
            }
            guard let target = owner?.tabBar, let first = target.items?.first else {
                guard attempts < 12, retry == nil else { return }
                attempts += 1
                let work = DispatchWorkItem { [weak self] in self?.retry = nil; self?.attach() }
                retry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                return
            }
            retry?.cancel(); retry = nil; attempts = 0
            if host !== window {
                host?.removeGestureRecognizer(gesture)
                host = window; previousTap = nil
                window.addGestureRecognizer(gesture)
            }
            bar = target
            if item !== first {
                removeCustomAction()
                item = first
                first.accessibilityIdentifier = "main.tab.timeline"
                let action = UIAccessibilityCustomAction(name: "从头刷新时间线", target: self, selector: #selector(accessibleRestart))
                customAction = action
                first.accessibilityCustomActions = (first.accessibilityCustomActions ?? []) + [action]
            }
        }
        private func removeCustomAction() {
            if let action = customAction { item?.accessibilityCustomActions?.removeAll { $0 === action } }
            item = nil; customAction = nil
        }
        func detach() {
            retry?.cancel(); retry = nil; attempts = 0
            host?.removeGestureRecognizer(gesture); host = nil; bar = nil; previousTap = nil
            removeCustomAction()
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let bar, let host, bar.window === host, !bar.isHidden,
                  let title = item?.title, let touched = touch.view,
                  touched === bar || touched.isDescendant(of: bar) else { previousTap = nil; return false }
            let point = touch.location(in: bar)
            guard bar.bounds.contains(point) else { previousTap = nil; return false }
            func matches(_ view: UIView) -> Bool {
                view.accessibilityIdentifier == "main.tab.timeline" || view.accessibilityLabel == title || (view as? UILabel)?.text == title
            }
            var ancestor: UIView? = touched
            while let view = ancestor, view !== bar {
                if matches(view) { return true }
                ancestor = view.superview
            }
            // Resolve the actual labelled control instead of assuming that the
            // number of UIKit implementation controls equals the number of tabs.
            func containsLabel(_ view: UIView) -> Bool {
                matches(view) || view.subviews.contains(where: containsLabel)
            }
            func matchingControl(_ view: UIView) -> Bool {
                for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
                    if child is UIControl, containsLabel(child), child.convert(child.bounds, to: bar).contains(point) { return true }
                    if matchingControl(child) { return true }
                }
                return false
            }
            let accepted = matchingControl(bar)
            if !accepted { previousTap = nil }
            return accepted
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        private func deliver() {
            let now = CACurrentMediaTime()
            guard now - lastDelivery >= 0.65 else { return }
            lastDelivery = now; onDoubleTap()
        }
        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let host else { return }
            let now = CACurrentMediaTime(), point = recognizer.location(in: host)
            if let previousTap, now - previousTap.time <= 0.4,
               hypot(point.x - previousTap.point.x, point.y - previousTap.point.y) <= 30 {
                self.previousTap = nil
                deliver()
            } else {
                previousTap = (now, point)
                onTap()
            }
        }
        @objc private func accessibleRestart(_ action: UIAccessibilityCustomAction) -> Bool {
            previousTap = nil; deliver(); return true
        }
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
