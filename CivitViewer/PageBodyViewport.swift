import SwiftUI
import UIKit

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
    struct Geometry {
        let owner: UIViewController
        /// Fixed controls stay outside this reading / gesture aperture.
        let rect: CGRect
        /// Rendered content can pass behind chrome and the system safe areas.
        var canvasRect: CGRect? {
            guard let view = owner.viewIfLoaded, let window = view.window else { return nil }
            let visible = view.convert(window.bounds, from: window).intersection(view.bounds)
            return visible.isNull ? nil : visible
        }
    }
    private struct WeakProbe { weak var value: BodyViewportProbe? }
    private static var probes: [WeakProbe] = []
    private struct WeakBottomBar { weak var view: FixedBottomBarProbe? }
    private static var bottomBars: [WeakBottomBar] = []

    fileprivate static func register(_ view: FixedBottomBarProbe) {
        bottomBars.removeAll { $0.view == nil }
        if !bottomBars.contains(where: { $0.view === view }) { bottomBars.append(.init(view: view)) }
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
    }

    /// Search only explicitly registered, currently visible geometry in this
    /// controller's containment scope. Ambiguous matches are never guessed.
    static func geometry(containing controller: UIViewController) -> Geometry? {
        guard let root = controller.viewIfLoaded, let window = root.window else { return nil }
        let matches = probes.compactMap(\.value).compactMap { probe -> Geometry? in
            guard probe.visible, probe.viewIfLoaded?.window === window,
                  let owner = PageViewportGeometry.owner(of: probe), let view = owner.viewIfLoaded,
                  view === root || view.isDescendant(of: root) || root.isDescendant(of: view),
                  owner.navigationController.map({ $0.topViewController === owner }) ?? true,
                  let marker = probe.viewIfLoaded,
                  let rect = PageViewportGeometry.rect(owner: view, marker: marker, top: probe.top, bottom: probe.bottom) else { return nil }
            return Geometry(owner: owner, rect: rect)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

private struct BodyViewportMarker: UIViewControllerRepresentable {
    let top: CGFloat
    let bottom: CGFloat
    func makeUIViewController(context: Context) -> BodyViewportProbe { BodyViewportProbe() }
    func updateUIViewController(_ probe: BodyViewportProbe, context: Context) {
        probe.top = top; probe.bottom = bottom
        PageBodyViewports.register(probe)
    }
    static func dismantleUIViewController(_ probe: BodyViewportProbe, coordinator: ()) { probe.visible = false }
}

@MainActor private final class BodyViewportProbe: UIViewController {
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
    override func didMoveToWindow() { super.didMoveToWindow(); PageBodyViewports.register(self) }
    override func layoutSubviews() { super.layoutSubviews(); PageBodyViewports.register(self) }
}
struct FixedBottomBarMarker: UIViewRepresentable {
    let enabled: Bool
    func makeUIView(context: Context) -> UIView {
        let view = FixedBottomBarProbe(); view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ view: UIView, context: Context) { (view as? FixedBottomBarProbe)?.enabled = enabled }
}
