import SwiftUI
import UIKit

private struct CompactBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

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

private struct MediaCover<Item: Identifiable, Presented: View>: ViewModifier {
    @Binding var item: Item?
    var onDismiss: () -> Void
    @ViewBuilder var presented: (Item) -> Presented
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var parentExit
    @State private var playbackOrientation = PlaybackOrientationSession()
    @State private var exitsToTab = false

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $item, onDismiss: {
            exitsToTab = false
            playbackOrientation.restore()
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
        item: Binding<Item?>, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> Presented
    ) -> some View {
        modifier(MediaCover(item: item, onDismiss: onDismiss, presented: content))
    }
}

/// The production and UI-test roots use the same tab ownership, navigation
/// containers, labels and observation point. Content dependencies stay outside.
struct MainTabs<Timeline: View, Authors: View, Search: View, Collections: View>: View {
    @Binding var selectedTab: Int
    var onTimelineTap: () -> Void
    var onTimelineDoubleTap: () -> Void
    let timeline: Timeline
    let authors: Authors
    let search: Search
    let collections: Collections
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @State private var pageMotion = TabPageMotion()
    private struct CanvasHandoff {
        let tone: PageToneTransition
        // A playback change has a direction. A system appearance change does not.
        let destinationIsMedia: Bool?
    }

    @State private var canvasHandoff: CanvasHandoff?
    @State private var lastTimelineWasMedia: Bool?
    @State private var skipHiddenInlineExitBlend = false
    @AppStorage("timeline.presentation") private var timelinePresentation = TimelinePresentation.stream.rawValue
    @ObservedObject private var chrome = ViewingChromeController.shared
    @StateObject private var favoriteSelectionBar = FavoriteSelectionBar()
    @State private var previousTimelineTap: CFTimeInterval?
    @State private var lastTimelineRefresh = -Double.infinity
    @State private var compactBarHeight: CGFloat = 48
    // A navigation push in the timeline ends playback, but must not resize its
    // underlying viewport while the next screen covers or reveals it.
    private var overlaysBottomBar: Bool { selectedTab == 0 }
    private var barOverMedia: Bool { overlaysBottomBar && chrome.hasInlinePlayer }
    private let destinations: [(Int, String, String)] = [
        (0, "时间线", "rectangle.portrait.on.rectangle.portrait"),
        (2, "作者榜", "person.3"), (4, "搜索", "magnifyingglass"), (3, "收藏", "bookmark")
    ]

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { timeline }
                .environment(\.motionTab, 0)
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("时间线", systemImage: "rectangle.portrait.on.rectangle.portrait").accessibilityIdentifier("main.tab.timeline") }.tag(0)
            NavigationStack { authors }
                .environment(\.motionTab, 2)
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("作者榜", systemImage: "person.3") }.tag(2)
            NavigationStack { search }
                .environment(\.motionTab, 4)
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(4)
            NavigationStack { collections }
                .environment(\.motionTab, 3)
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("收藏", systemImage: "bookmark") }.tag(3)
        }
        .background(barOverMedia ? Color.black : AppTheme.pageBackground(for: ordinaryScheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.tabPageMotion, pageMotion)
        .environment(\.overlaidTabBarHeight, overlaysBottomBar ? compactBarHeight : 0)
        .environment(\.viewingControlsReferenceInset, compactBarHeight)
        .environment(\.favoriteSelectionBar, favoriteSelectionBar)
        .environment(\.mediaTabs, MediaTabs(height: compactBarHeight, render: { overMedia, identifier, selection, tone, onSelect in
            AnyView(compactBar(selected: selectedTab, overMedia: overMedia, showsBatchActions: false,
                               identifier: identifier, selection: selection, tone: tone, onSelect: onSelect))
        }, select: selectFromPlayback))
        .safeAreaPadding(.bottom, overlaysBottomBar ? 0 : compactBarHeight)
        .overlay(alignment: .top) {
            if barOverMedia { PlaybackStatusBarScrim() }
        }
        .overlay {
            if let canvasHandoff {
                let tone = canvasHandoff.tone
                PageToneBlend(source: tone.source, initialOpacity: tone.initialOpacity) {
                    if self.canvasHandoff?.tone.id == tone.id { self.canvasHandoff = nil }
                }
                .id(tone.id)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if let handoff = pageMotion.handoff {
                GeometryReader { geometry in
                    let origin = geometry.frame(in: .global).origin
                    HeaderHandoffView(handoff: handoff)
                        .offset(x: handoff.source.frame.minX - origin.x,
                                y: handoff.source.frame.minY - origin.y)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            measuredBar.viewingChromeHidden(barOverMedia && chrome.hidden)
        }
        .onPreferenceChange(CompactBarHeightKey.self) { if $0 > 0 { compactBarHeight = $0 } }
        .tint(.blue)
        .onChange(of: selectedTab) { _, _ in chrome.reveal(); favoriteSelectionBar.clear() }
        .onChange(of: barOverMedia) { wasOverMedia, isOverMedia in
            if skipHiddenInlineExitBlend {
                skipHiddenInlineExitBlend = false
                return
            }
            guard canvasHandoff?.destinationIsMedia != isOverMedia else { return }
            blendCanvas(fromMedia: wasOverMedia, toMedia: isOverMedia)
        }
        .onChange(of: ordinaryScheme) { previous, _ in
            guard !barOverMedia, !reduceMotion else { return }
            canvasHandoff = CanvasHandoff(tone: PageToneTransition(source: AppTheme.pageBackground(for: previous)),
                                          destinationIsMedia: nil)
        }
        .onDisappear { pageMotion.cancel() }
    }

    private var measuredBar: some View {
        compactBar(selected: selectedTab, overMedia: barOverMedia, showsBatchActions: true, tone: canvasHandoff?.tone, onSelect: select).background(GeometryReader { geometry in
            Color.clear.preference(key: CompactBarHeightKey.self, value: geometry.size.height)
        })
    }

    private func compactBar(selected: Int, overMedia: Bool, showsBatchActions: Bool, identifier: String = "main.tabs.compact",
                            selection: FavoriteSelectionBar.Entry? = nil, tone: PageToneTransition?,
                            onSelect: @escaping (Int) -> Void) -> some View {
        let entry = showsBatchActions ? favoriteSelectionBar.entry : selection
        let isBlending = showsBatchActions && tone != nil
        let inactiveColor: Color = overMedia ? .white.opacity(0.88) : (isBlending ? .primary : .secondary)
        return HStack(spacing: FloatingPageChrome.groupInset) {
            ForEach(destinations, id: \.0) { destination in
                if destination.0 == 0 && showsBatchActions {
                    tabButton(destination, selected: selected == destination.0, overMedia: overMedia, inactiveColor: inactiveColor, onSelect: onSelect)
                        .accessibilityAction(named: Text("从头刷新时间线")) { refreshTimeline() }
                } else { tabButton(destination, selected: selected == destination.0, overMedia: overMedia, inactiveColor: inactiveColor, onSelect: onSelect) }
            }
        }
            .opacity(entry == nil ? 1 : 0)
            .allowsHitTesting(entry == nil)
            .accessibilityHidden(entry != nil)
            .overlay {
                if let entry { FavoriteBatchBarButtons(entry: entry).id(entry.owner) }
            }
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .padding(.horizontal, FloatingPageChrome.groupInset).padding(.vertical, 2)
            .background {
                Group {
                    if overMedia { PlaybackChromeSurface() }
                    else {
                        let shape = FloatingPageChrome.controlShape
                        shape.fill(Color(uiColor: .systemBackground).opacity(reduceTransparency ? 1 : 0.68))
                            .overlay { shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
                    }
                }
                .frame(height: FloatingPageChrome.surfaceHeight)
                .overlay {
                    if let tone {
                        PageToneBlend(source: tone.source, coversSafeArea: false, initialOpacity: 0.48)
                            .clipShape(FloatingPageChrome.controlShape)
                            .id(tone.id)
                    }
                }
            }
            .padding(.horizontal, PlaybackChrome.horizontalInset)
            .accessibilityElement(children: .contain).accessibilityAddTraits(.isTabBar)
            .accessibilityIdentifier(identifier)
            .environment(\.colorScheme, overMedia ? .dark : ordinaryScheme)
    }
    private func tabButton(_ destination: (Int, String, String), selected: Bool, overMedia: Bool, inactiveColor: Color,
                           onSelect: @escaping (Int) -> Void) -> some View {
        Button { onSelect(destination.0) } label: {
            VStack(spacing: 2) {
                Image(systemName: destination.2)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 14)
                Text(destination.1)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 4)
            }
            .frame(height: FloatingPageChrome.visibleHeight(nested: true))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight)
            .foregroundStyle(selected ? Color.accentColor : inactiveColor)
            .shadow(color: .black.opacity(overMedia ? 0.7 : 0), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityLabel(destination.1)
        .accessibilityIdentifier(destination.0 == 0 ? "main.tab.timeline" : "main.tab.\(destination.0)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func select(_ id: Int) {
        if id != selectedTab, !reduceMotion,
           destinations.contains(where: { $0.0 == selectedTab }),
           destinations.contains(where: { $0.0 == id }) {
            pageMotion.switchPage(from: selectedTab, to: id,
                                  leavesInlinePlayback: barOverMedia && !chrome.hidden) {
                applySelection(id)
            }
        } else {
            pageMotion.cancel()
            if id != selectedTab { pageMotion.takeHeaderOwnership(from: selectedTab) }
            applySelection(id)
        }
    }

    private func selectFromPlayback(_ exit: MediaTabExit) {
        if exit.id == selectedTab {
            blendCanvas(fromMedia: exit.fromMedia, toMedia: barOverMedia)
            return
        }
        pageMotion.cancel()
        pageMotion.takeHeaderOwnership(from: selectedTab)
        withoutPageAnimation { applySelection(exit.id, visibleSourceIsMedia: exit.fromMedia) }
    }

    private func blendCanvas(fromMedia: Bool, toMedia: Bool) {
        guard fromMedia != toMedia, ordinaryScheme == .light, !reduceMotion else { return }
        let source: Color = fromMedia ? .black : AppTheme.pageBackground(for: ordinaryScheme)
        // A quick reversal starts from the shade the outgoing blend has reached.
        let tone: PageToneTransition
        if let active = canvasHandoff, active.destinationIsMedia == fromMedia {
            tone = active.tone.reversed(from: source)
        } else {
            tone = PageToneTransition(source: source)
        }
        canvasHandoff = CanvasHandoff(tone: tone, destinationIsMedia: toMedia)
    }

    private func applySelection(_ id: Int, visibleSourceIsMedia: Bool? = nil) {
        if id != selectedTab {
            if selectedTab == 0 { lastTimelineWasMedia = barOverMedia }
            // On first entry, wait for the player to appear before starting the blend.
            let destinationIsMedia = id == 0 && timelinePresentation == TimelinePresentation.stream.rawValue
                && lastTimelineWasMedia == true
            // A light Details or Author page can cover the dark inline player.
            // Ending the hidden player does not change the visible source tone.
            skipHiddenInlineExitBlend = visibleSourceIsMedia == false && barOverMedia && !destinationIsMedia
            blendCanvas(fromMedia: visibleSourceIsMedia ?? barOverMedia, toMedia: destinationIsMedia)
        }
        if id != 0 { chrome.endInlinePlayer() }
        selectedTab = id
        guard id == 0 else { previousTimelineTap = nil; return }
        let now = CACurrentMediaTime()
        if let previousTimelineTap, now - previousTimelineTap <= 0.4 {
            self.previousTimelineTap = nil; refreshTimeline()
        } else {
            previousTimelineTap = now; onTimelineTap()
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
