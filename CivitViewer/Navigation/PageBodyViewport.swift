import SwiftUI
import UIKit

@MainActor @Observable final class PageVisualActivationPermit {
    private var blockers: [UUID: Int] = [:]
    var isAllowed: Bool { blockers.isEmpty }

    func block(_ token: UUID) -> PageVisualActivationLease {
        blockers[token, default: 0] += 1
        return PageVisualActivationLease(permit: self, token: token)
    }

    fileprivate func release(_ token: UUID) {
        guard let count = blockers[token] else { return }
        if count > 1 { blockers[token] = count - 1 } else { blockers[token] = nil }
    }
}

@MainActor final class PageVisualActivationLease {
    private var permit: PageVisualActivationPermit?
    private let token: UUID
    fileprivate init(permit: PageVisualActivationPermit, token: UUID) { self.permit = permit; self.token = token }
    func release() {
        let held = permit; permit = nil
        held?.release(token)
    }
    deinit { MainActor.assumeIsolated { release() } }
}

extension EnvironmentValues {
    @Entry var pageVisualActivationPermit: PageVisualActivationPermit? = nil
}

struct RootFooterEndpoint: Equatable {
    let selectedTab: Int
    let overMedia: Bool
    let selectionOwner: UUID?
    let frame: CGRect
}

struct FixedBottomBarContent: Equatable {
    let identifier: String
    let selectedTab: Int
    let overMedia: Bool
    let selectionOwner: UUID?
}

/// One explicit UIKit drawable for a floating control surface. Capture leases
/// add their own tokens; releasing an older lease cannot change current base
/// visibility or remove another capture's suppression.
@MainActor
final class PageControlDrawable {
    enum Kind: String, Equatable { case header, footer }
    weak var view: UIView?
    let kind: Kind
    var baseVisible: Bool
    var onVisibilityChange: (() -> Void)?
    private(set) var captureSuppression: Set<UUID> = []

    private var inputOwners: Set<UUID> = []
    private let invisibleMask = CALayer()
    private var previousMask: CALayer?

    func keepInput(_ token: UUID) { inputOwners.insert(token); applyVisibility(notify: false) }
    func releaseInput(_ token: UUID) { inputOwners.remove(token); applyVisibility(notify: false) }

    init(view: UIView, kind: Kind, visible: Bool) {
        self.view = view
        self.kind = kind
        self.baseVisible = visible
        applyVisibility()
    }

    var isDrawable: Bool { baseVisible && captureSuppression.isEmpty && view != nil }
    func setBaseVisible(_ visible: Bool) { baseVisible = visible; applyVisibility() }
    func suppress(_ token: UUID) { captureSuppression.insert(token); applyVisibility() }
    func release(_ token: UUID) { captureSuppression.remove(token); applyVisibility() }

    private func applyVisibility(notify: Bool = true) {
        guard let view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A floating control can keep its actions while its pixels are supplied
        // by the edge animation. A clear layer mask changes drawing only.
        let inputOnly = baseVisible && !inputOwners.isEmpty && !isDrawable
        if inputOnly, view.layer.mask !== invisibleMask {
            previousMask = view.layer.mask
            view.layer.mask = invisibleMask
        } else if !inputOnly, view.layer.mask === invisibleMask {
            view.layer.mask = previousMask
            previousMask = nil
        }
        let acceptsTouches = isDrawable || inputOnly
        view.alpha = acceptsTouches ? 1 : 0
        view.isUserInteractionEnabled = acceptsTouches
        view.accessibilityElementsHidden = !acceptsTouches
        if notify { onVisibilityChange?() }
        CATransaction.commit()
    }
}

@MainActor
final class PageControlCaptureLease {
    private var entries: [(WeakDrawable, UUID)]
    private var released = false
    fileprivate init(_ entries: [(PageControlDrawable, UUID)]) {
        self.entries = entries.map { (WeakDrawable($0.0), $0.1) }
    }
    func release() {
        guard !released else { return }
        released = true
        for (drawable, token) in entries { drawable.value?.release(token) }
        entries.removeAll()
    }
    deinit { MainActor.assumeIsolated { release() } }
    private struct WeakDrawable { weak var value: PageControlDrawable?; init(_ value: PageControlDrawable) { self.value = value } }
}

/// Shared coordinate rule for measured body content. Registering this geometry
/// never installs a gesture, changes a navigation role, or captures pixels.
@MainActor enum PageViewportGeometry {
    static func rect(owner: UIView, marker: UIView, top: CGFloat, bottom: CGFloat) -> CGRect? {
        guard marker.isDescendant(of: owner), marker.window === owner.window,
              top.isFinite, bottom.isFinite else { return nil }
        let marked = marker.convert(marker.bounds, to: owner).intersection(owner.bounds)
        let upper = max(marked.minY, owner.bounds.minY + owner.safeAreaInsets.top + max(0, top))
        var lower = min(marked.maxY, owner.bounds.maxY - owner.safeAreaInsets.bottom - max(0, bottom))
        if let barTop = PageBodyViewports.fixedBottomBarTop(in: owner) { lower = min(lower, barTop) }
        let rect = CGRect(x: marked.minX, y: upper, width: marked.width, height: lower - upper)
        guard !marked.isNull, !rect.isNull, rect.width > 1, rect.height > 1,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }

    static func owner(of probe: UIViewController) -> UIViewController? {
        guard let marker = probe.viewIfLoaded else { return nil }
        var candidate: UIViewController? = probe
        while let current = candidate {
            if let nav = current.navigationController,
               let owner = nav.viewControllers.reversed().first(where: {
                   $0.viewIfLoaded.map { marker.isDescendant(of: $0) } == true
               }) { return owner }
            candidate = current.parent
        }
        candidate = probe.parent
        var outermost: UIViewController?
        while let current = candidate {
            guard current.viewIfLoaded.map({ marker.isDescendant(of: $0) }) == true else { break }
            if current is UINavigationController || current is UITabBarController { break }
            outermost = current
            if current.presentingViewController != nil { break }
            candidate = current.parent
        }
        return outermost
    }
}

@MainActor enum PageBodyViewports {
    private static var activationKey: UInt8 = 0

    static func suspendActivation(in scope: UIViewController, token: UUID) -> PageVisualActivationLease? {
        if let permit = objc_getAssociatedObject(scope, &activationKey) as? PageVisualActivationPermit {
            return permit.block(token)
        }
        if let owner = geometry(containing: scope)?.owner,
           let permit = objc_getAssociatedObject(owner, &activationKey) as? PageVisualActivationPermit {
            return permit.block(token)
        }
        let children: [UIViewController]
        if let nav = scope as? UINavigationController { children = nav.topViewController.map { [$0] } ?? [] }
        else if let tabs = scope as? UITabBarController { children = tabs.selectedViewController.map { [$0] } ?? [] }
        else if let root = scope as? RootTabHostController { children = root.navigationOwner(tab: root.selected).map { [$0] } ?? [] }
        else { children = scope.children }
        return children.lazy.compactMap { suspendActivation(in: $0, token: token) }.first
    }
    @MainActor struct Geometry {
        let owner: UIViewController
        /// Fixed controls stay outside this reading / gesture aperture.
        let rect: CGRect
        /// Rendered content can pass behind chrome and the system safe areas.
        var canvasRect: CGRect? {
            guard let view = owner.viewIfLoaded, view.window != nil,
                  view.bounds.width > 1, view.bounds.height > 1 else { return nil }
            // A translated navigation owner still owns its complete local
            // canvas, rather than only the part intersecting the window.
            return view.bounds
        }
    }
    private struct WeakProbe { weak var value: BodyViewportProbe? }
    private static var probes: [WeakProbe] = []
    private struct WeakBottomBar { weak var view: FixedBottomBarProbe? }
    private static var bottomBars: [WeakBottomBar] = []
    private struct WeakDrawable { weak var value: PageControlDrawable? }
    private static var drawables: [WeakDrawable] = []

    static func register(_ drawable: PageControlDrawable) {
        drawables.removeAll { $0.value == nil }
        if !drawables.contains(where: { $0.value === drawable }) { drawables.append(.init(value: drawable)) }
    }

    static func controlDrawables(for views: [UIView]) -> [PageControlDrawable] {
        let ids = Set(views.map(ObjectIdentifier.init))
        return drawables.compactMap(\.value).filter { $0.view.map { ids.contains(ObjectIdentifier($0)) } == true }
    }

    /// Suppress only explicitly registered control hosts inside this owner and
    /// window. The lease owns exactly the tokens it added.
    static func suppressFloatingControls(in owner: UIViewController, token: UUID,
                                         includePresentationFooter: Bool = false) -> PageControlCaptureLease {
        drawables.removeAll { $0.value == nil }
        guard let root = owner.viewIfLoaded, let window = root.window else { return PageControlCaptureLease([]) }
        let footerScope = includePresentationFooter ? presentationControlScope(owner).viewIfLoaded : nil
        let matches = drawables.compactMap(\.value).filter { drawable in
            guard let view = drawable.view, view.window === window else { return false }
            return view === root || view.isDescendant(of: root)
                || (drawable.kind == .footer && footerScope.map { view === $0 || view.isDescendant(of: $0) } == true)
        }
        matches.forEach { $0.suppress(token) }
        return PageControlCaptureLease(matches.map { ($0, token) })
    }

    /// The registered, currently drawn control subtrees owned by this page.
    /// Only explicit drawable registrations participate; no SwiftUI ancestors
    /// or private framework views are inspected to discover controls.
    static func floatingControlViews(in owner: UIViewController, kind: PageControlDrawable.Kind? = nil,
                                     includePresentationFooter: Bool = false,
                                     includingSuppressed: Bool = false) -> [UIView] {
        drawables.removeAll { $0.value == nil }
        guard let root = owner.viewIfLoaded, let window = root.window else { return [] }
        let footerScope = includePresentationFooter ? presentationControlScope(owner).viewIfLoaded : nil
        return drawables.compactMap(\.value).compactMap { drawable -> UIView? in
            guard kind == nil || drawable.kind == kind,
                  drawable.baseVisible, drawable.isDrawable || includingSuppressed,
                  let view = drawable.view, view.window === window,
                  view === root || view.isDescendant(of: root)
                    || (drawable.kind == .footer && footerScope.map { view === $0 || view.isDescendant(of: $0) } == true) else { return nil }
            var current: UIView? = view
            while let node = current {
                let suppressedHost = includingSuppressed && node === view && !drawable.captureSuppression.isEmpty
                if node.isHidden || (node.alpha < 0.01 && !suppressedHost) { return nil }
                if node === window { return view }
                current = node.superview
            }
            return nil
        }
    }

    /// A presentation may put its footer outside the nested NavigationStack.
    /// Stop at a retained root slot; never borrow another root's controls.
    private static func presentationControlScope(_ owner: UIViewController) -> UIViewController {
        var scope = owner
        while let parent = scope.parent {
            if parent is RootTabHostController { break }
            scope = parent
        }
        return scope
    }

    fileprivate static func register(_ view: FixedBottomBarProbe) {
        bottomBars.removeAll { $0.view == nil }
        if !bottomBars.contains(where: { $0.view === view }) { bottomBars.append(.init(view: view)) }
    }

    /// Root handoff must observe the actual root control host, rather than a
    /// same-frame copy retained by a playback or business presentation.
    static func rootFooterEndpoint(in window: UIWindow, includingSuppressed: Bool = false) -> RootFooterEndpoint? {
        let suppressed = includingSuppressed ? Set(drawables.compactMap(\.value).compactMap { drawable -> ObjectIdentifier? in
            guard drawable.kind == .footer, drawable.baseVisible, !drawable.captureSuppression.isEmpty,
                  let view = drawable.view, view.window === window else { return nil }
            return ObjectIdentifier(view)
        }) : []
        let matches = bottomBars.compactMap(\.view).filter { marker in
            guard marker.enabled, marker.window === window,
                  marker.content?.identifier == "main.tabs.compact",
                  marker.bounds.width > 1, marker.bounds.height > 1 else { return false }
            var ancestor: UIView? = marker
            while let view = ancestor {
                if view.isHidden || (view.alpha < 0.01 && !suppressed.contains(ObjectIdentifier(view))) { return false }
                ancestor = view.superview
            }
            return marker.convert(marker.bounds, to: window).intersects(window.bounds)
        }
        guard matches.count == 1, let marker = matches.first, let content = marker.content else { return nil }
        return RootFooterEndpoint(selectedTab: content.selectedTab, overMedia: content.overMedia,
                                  selectionOwner: content.selectionOwner,
                                  frame: marker.convert(marker.bounds, to: window))
    }

    static func rootFooterControl(in window: UIWindow) -> PageControlDrawable? {
        drawables.removeAll { $0.value == nil }
        let markers = bottomBars.compactMap(\.view).filter {
            $0.window === window && $0.content?.identifier == "main.tabs.compact" && $0.enabled
        }
        guard markers.count == 1, let marker = markers.first,
              let drawable = drawables.compactMap(\.value).first(where: {
                  guard $0.kind == .footer, let view = $0.view, view.window === window else { return false }
                  return marker === view || marker.isDescendant(of: view)
              }) else { return nil }
        return drawable
    }

    static func suppressRootFooter(in window: UIWindow, token: UUID) -> PageControlCaptureLease? {
        guard let drawable = rootFooterControl(in: window) else { return nil }
        drawable.suppress(token)
        return PageControlCaptureLease([(drawable, token)])
    }

    static func fixedBottomBarFrame(in owner: UIView) -> CGRect? {
        guard let window = (owner as? UIWindow) ?? owner.window else { return nil }
        return bottomBars.compactMap(\.view).filter {
            guard $0.enabled, $0.window === window, $0.bounds.width > 1, $0.bounds.height > 1,
                  $0.convert($0.bounds, to: window).intersects(window.bounds) else { return false }
            var ancestor: UIView? = $0
            while let view = ancestor {
                if view.isHidden || view.alpha < 0.01 { return false }
                ancestor = view.superview
            }
            return true
        }.map { owner.convert($0.bounds, from: $0) }.min { $0.minY < $1.minY }
    }

    static func fixedBottomBarIsOutside(_ owner: UIView) -> Bool {
        guard let window = owner.window, let frame = fixedBottomBarFrame(in: window) else { return false }
        let matches = bottomBars.compactMap(\.view).filter {
            guard $0.enabled, $0.window === window, $0.convert($0.bounds, to: window) == frame else { return false }
            var ancestor: UIView? = $0
            while let view = ancestor {
                if view.isHidden || view.alpha < 0.01 { return false }
                ancestor = view.superview
            }
            return true
        }
        return matches.count == 1 && !matches[0].isDescendant(of: owner)
    }

    #if DEBUG && targetEnvironment(simulator)
    private static var floatingReadbacks: [ObjectIdentifier: FloatingCanvasReadback173] = [:]
    private final class FloatingCanvasReadback173: UILabel {
        weak var targetWindow: UIWindow?
        override var accessibilityValue: String? {
            get { targetWindow.map(PageBodyViewports.floatingCanvasSummary) ?? "unavailable" }
            set {}
        }
    }
    fileprivate static func installFloatingReadback(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-floating173") else { return }
        floatingReadbacks = floatingReadbacks.filter { $0.value.targetWindow != nil }
        let key = ObjectIdentifier(window)
        guard floatingReadbacks[key] == nil else { return }
        let label = FloatingCanvasReadback173(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        label.targetWindow = window; label.alpha = 0.01; label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true; label.accessibilityTraits = .staticText
        label.accessibilityIdentifier = "page.canvas173"
        window.addSubview(label); floatingReadbacks[key] = label
    }
    private static func visible(_ view: UIView, in window: UIWindow) -> Bool {
        guard view.window === window else { return false }
        var current: UIView? = view
        while let value = current {
            if value.isHidden || value.alpha < 0.01 || !value.isUserInteractionEnabled { return false }
            if value === window { return true }
            current = value.superview
        }
        return false
    }
    private static func floatingCanvasSummary(in window: UIWindow) -> String {
        let owners = probes.compactMap(\.value).filter { $0.visible }.compactMap(PageViewportGeometry.owner)
        guard let owner = owners.last(where: { candidate in
            guard let view = candidate.viewIfLoaded, visible(view, in: window) else { return false }
            return candidate.navigationController.map { $0.topViewController === candidate } ?? true
        }), let view = owner.viewIfLoaded, let geometry = geometry(containing: owner) else { return "unavailable" }
        var scrolls: [UIScrollView] = []
        func scan(_ node: UIView) {
            guard visible(node, in: window) else { return }
            if let scroll = node as? UIScrollView,
               scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.height + 1 { scrolls.append(scroll) }
            node.subviews.forEach(scan)
        }
        scan(view)
        let nativeLists = scrolls.filter { $0 is UICollectionView || $0 is UITableView }
        let scroll = (nativeLists.isEmpty ? scrolls : nativeLists).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        let canvas = view.convert(view.bounds, to: window)
        let reading = geometry.owner.view.convert(geometry.rect, to: window)
        let sf = scroll.map { $0.convert($0.bounds, to: window) } ?? .zero
        return String(format: "canvasY=%.2f;canvasBottom=%.2f;readingY=%.2f;readingBottom=%.2f;scrollY=%.2f;scrollBottom=%.2f;contentInsetTop=%.2f;adjustedTop=%.2f;contentOffsetY=%.2f", canvas.minY, canvas.maxY, reading.minY, reading.maxY, sf.minY, sf.maxY, scroll?.contentInset.top ?? -1, scroll?.adjustedContentInset.top ?? -1, scroll?.contentOffset.y ?? -1)
    }
    #endif

    static func fixedBottomBarTop(in owner: UIView) -> CGFloat? {
        fixedBottomBarFrame(in: owner)?.minY
    }

    fileprivate static func register(_ probe: BodyViewportProbe) {
        probes.removeAll { $0.value == nil }
        if !probes.contains(where: { $0.value === probe }) { probes.append(.init(value: probe)) }
        bindActivation(probe)
    }

    fileprivate static func bindActivation(_ probe: BodyViewportProbe) {
        guard let permit = probe.activationPermit, let owner = PageViewportGeometry.owner(of: probe) else { return }
        if (objc_getAssociatedObject(owner, &activationKey) as? PageVisualActivationPermit) !== permit {
            objc_setAssociatedObject(owner, &activationKey, permit, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Search only explicitly registered, currently visible geometry in this
    /// controller's containment scope. Ambiguous matches are never guessed.
    static func geometry(containing controller: UIViewController) -> Geometry? {
        guard let root = controller.viewIfLoaded, let window = root.window else { return nil }
        let candidates = probes.compactMap(\.value).compactMap { probe -> (BodyViewportProbe, Geometry)? in
            guard probe.visible, probe.viewIfLoaded?.window === window,
                  let owner = PageViewportGeometry.owner(of: probe), let view = owner.viewIfLoaded,
                  view === root || view.isDescendant(of: root) || root.isDescendant(of: view),
                  owner.navigationController.map({ $0.topViewController === owner }) ?? true,
                  let marker = probe.viewIfLoaded,
                  let rect = PageViewportGeometry.rect(owner: view, marker: marker, top: probe.top, bottom: probe.bottom) else { return nil }
            return (probe, Geometry(owner: owner, rect: rect))
        }
        let matches = candidates.filter { activeProbe($0.0, within: root) }.map { $0.1 }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-page-return"), candidates.count != matches.count,
           geometryReadbacks175 < 24 {
            geometryReadbacks175 += 1
            NSLog("GEOMETRY175_SCOPE raw=%d;active=%d;scope=%@;rejectedHiddenOrInactive=%d",
                  candidates.count, matches.count, String(String(describing: type(of: controller)).prefix(100)), candidates.count - matches.count)
        }
        #endif
        return matches.count == 1 ? matches[0] : nil
    }

    /// A departing navigation page can lose top-of-stack ownership before its
    /// pixels leave the window. Capture only that exact declared owner; this
    /// grants no gesture, playback or business activation to a covered page.
    static func capturableGeometry(of controller: UIViewController) -> Geometry? {
        guard let root = controller.viewIfLoaded, let window = root.window else { return nil }
        let matches = probes.compactMap(\.value).compactMap { probe -> Geometry? in
            guard let marker = probe.viewIfLoaded, marker.window === window,
                  PageViewportGeometry.owner(of: probe) === controller,
                  marker.isDescendant(of: root),
                  let rect = PageViewportGeometry.rect(owner: root, marker: marker, top: probe.top, bottom: probe.bottom) else { return nil }
            return Geometry(owner: controller, rect: rect)
        }
        guard let first = matches.first, matches.allSatisfy({ $0.rect == first.rect }) else { return nil }
        return first
    }

    #if DEBUG && targetEnvironment(simulator)
    private static var geometryReadbacks175 = 0
    #endif

    /// Retained roots do not necessarily receive appearance callbacks when
    /// hidden. Qualify the marker's branch, rather than its outer presenter.
    /// The query scope itself can be a staged destination; its ancestors are
    /// intentionally outside this check so preparation remains possible.
    private static func activeProbe(_ probe: BodyViewportProbe, within scope: UIView) -> Bool {
        guard let marker = probe.viewIfLoaded, marker === scope || marker.isDescendant(of: scope) else { return false }
        var controller: UIViewController? = probe
        while let current = controller {
            if let view = current.viewIfLoaded, view === scope || view.isDescendant(of: scope) {
                if let root = current as? RootTabHostController, !root.owns(probe, tab: root.selected) { return false }
                if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController,
                   let marker = probe.viewIfLoaded, let selectedView = selected.viewIfLoaded,
                   marker !== selectedView, !marker.isDescendant(of: selectedView) { return false }
            }
            controller = current.parent
        }
        var view = probe.viewIfLoaded
        while let current = view, current !== scope {
            if current.isDescendant(of: scope), current.isHidden || current.alpha < 0.01 { return false }
            view = current.superview
        }
        return true
    }
}

private struct BodyViewportMarker: UIViewControllerRepresentable {
    let top: CGFloat
    let bottom: CGFloat
    @Environment(\.pageVisualActivationPermit) private var activationPermit
    func makeUIViewController(context: Context) -> BodyViewportProbe { BodyViewportProbe() }
    func updateUIViewController(_ probe: BodyViewportProbe, context: Context) {
        probe.top = top; probe.bottom = bottom
        probe.activationPermit = activationPermit
        PageBodyViewports.register(probe)
    }
    static func dismantleUIViewController(_ probe: BodyViewportProbe, coordinator: ()) { probe.visible = false }
}

@MainActor private final class BodyViewportProbe: UIViewController {
    var activationPermit: PageVisualActivationPermit?
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var visible = false
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); visible = true; PageBodyViewports.register(self)
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); visible = false }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        PageBodyViewports.bindActivation(self)
        #if DEBUG && targetEnvironment(simulator)
        if let window = view.window { PageBodyViewports.installFloatingReadback(in: window) }
        #endif
    }
}

extension View {
    func pageBodyViewport(top: CGFloat, bottom: CGFloat, enabled: Bool = true) -> some View {
        background {
            if enabled { BodyViewportMarker(top: top, bottom: bottom).allowsHitTesting(false).accessibilityHidden(true) }
        }
    }
}


/// Measures the actual fixed bar, including replicas in media presentations.
/// Viewports clamp to its top instead of guessing or subtracting its height twice.
private final class FixedBottomBarProbe: UIView {
    var enabled = true
    var content: FixedBottomBarContent?
    override func didMoveToWindow() { super.didMoveToWindow(); PageBodyViewports.register(self) }
    override func layoutSubviews() { super.layoutSubviews(); PageBodyViewports.register(self) }
}
struct FixedBottomBarMarker: UIViewRepresentable {
    let enabled: Bool
    var content: FixedBottomBarContent? = nil
    func makeUIView(context: Context) -> UIView {
        let view = FixedBottomBarProbe(); view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard let marker = view as? FixedBottomBarProbe else { return }
        marker.enabled = enabled
        marker.content = content
    }
}

private struct FloatingControlsDrawableHost: UIViewControllerRepresentable {
    let identifier: String
    let visible: Bool
    let content: AnyView
    @EnvironmentObject private var session: SiteSession

    func makeUIViewController(context: Context) -> FloatingControlsDrawableController {
        FloatingControlsDrawableController(identifier: identifier)
    }

    func updateUIViewController(_ controller: FloatingControlsDrawableController, context: Context) {
        let content = content.pageControlHostingEnvironment(from: context.environment, session: session)
        controller.update(content: AnyView(content), visible: visible)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: FloatingControlsDrawableController, context: Context) -> CGSize? {
        uiViewController.controlsSizeThatFits(proposal)
    }
}

extension View {
    /// A floating drawable is a new hosting root, not a continuation of the
    /// representable's private navigation/accessibility graph. Share only the
    /// public inputs actually consumed by both bars.
    func pageControlHostingEnvironment(from environment: EnvironmentValues, session: SiteSession) -> some View {
        self
            .environmentObject(session)
            .environmentObject(session.oauth)
            .environment(\.scenePhase, environment.scenePhase)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.ordinaryColorScheme, environment.ordinaryColorScheme)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.displayScale, environment.displayScale)
            .environment(\.horizontalSizeClass, environment.horizontalSizeClass)
            .environment(\.verticalSizeClass, environment.verticalSizeClass)
            .environment(\.isEnabled, environment.isEnabled)
            .environment(\.pageCanvasRole, environment.pageCanvasRole)
            .environment(\.pageSurfaceTone, environment.pageSurfaceTone)
            .environment(\.pageCoverScope, environment.pageCoverScope)
            .environment(\.pageVisualActivationPermit, environment.pageVisualActivationPermit)
            .environment(\.rootPageParticipation, environment.rootPageParticipation)
            .environment(\.tabPageMotion, environment.tabPageMotion)
            .environment(\.motionTab, environment.motionTab)
            .environment(\.mediaTabs, environment.mediaTabs)
            .environment(\.favoriteSelectionBar, environment.favoriteSelectionBar)
    }
}

@MainActor
private final class FloatingControlsDrawableController: UIViewController {
    private let identifier: String
    private var hosting: UIHostingController<AnyView>?
    private var drawable: PageControlDrawable?

    init(identifier: String) {
        self.identifier = identifier
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        root.isOpaque = false
        root.layer.name = identifier + ".floatingControls"
        view = root
    }

    func update(content: AnyView, visible: Bool) {
        if hosting == nil {
            let host = UIHostingController(rootView: AnyView(content.frame(maxWidth: .infinity)))
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            host.safeAreaRegions = []
            addChild(host)
            view.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            host.didMove(toParent: self)
            hosting = host
            let drawable = PageControlDrawable(view: host.view, kind: .footer, visible: visible)
            self.drawable = drawable
            PageBodyViewports.register(drawable)
        } else {
            hosting?.rootView = AnyView(content.frame(maxWidth: .infinity))
            drawable?.setBaseVisible(visible)
        }
    }

    func controlsSizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let available = CGSize(width: proposal.width ?? UIView.layoutFittingCompressedSize.width,
                               height: .greatestFiniteMagnitude)
        return hosting?.sizeThatFits(in: available)
            ?? CGSize(width: available.width, height: FloatingPageChrome.controlHeight + 4)
    }
}

private struct FloatingControlsDrawableModifier: ViewModifier {
    let identifier: String
    let visible: Bool
    func body(content: Content) -> some View {
        FloatingControlsDrawableHost(identifier: identifier, visible: visible, content: AnyView(content))
    }
}

extension View {
    /// Host the existing footer controls in a transparent UIKit drawable. The
    /// hosted controls own their natural layout, safe areas, focus and actions.
    func floatingControlsDrawable(identifier: String, visible: Bool = true) -> some View {
        modifier(FloatingControlsDrawableModifier(identifier: identifier, visible: visible))
    }
}
