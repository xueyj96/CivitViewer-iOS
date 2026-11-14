import SwiftUI
import UIKit

/// Roles belong to a concrete navigation page, never to its SwiftUI descendants.
/// Each segmented browser removes only its own token when it detaches.
@MainActor
enum PageEdgeReturnPolicy {
    private static var stateKey: UInt8 = 0
    private static var previews: [PageReturnPreview] = []

    static func setSegmentedBrowsing(owner: UIViewController, token: UUID, active: Bool) {
        let state = state(for: owner)
        if active { state.segmentedTokens.insert(token) }
        else { state.segmentedTokens.remove(token) }
        state.driver.policyDidChange()
    }

    static func isSegmentedBrowsing(owner: UIViewController) -> Bool {
        existingState(for: owner)?.segmentedTokens.isEmpty == false
    }

    /// FlatBackNavigationSupport uses this at touch time to avoid racing our pan.
    /// Ownership follows the installed viewport role, not temporary readiness.
    static func ownsReturnGesture(owner: UIViewController) -> Bool {
        guard let state = existingState(for: owner) else { return false }
        return state.viewports.contains { $0.probe != nil } || state.driver.hasActiveFlight
    }

    /// Only the root tab owner may mark this departure. Unknown hierarchy
    /// changes continue capturing their return preview.
    static func markRootTabDeparture(owner: UIViewController) {
        state(for: owner).rootTabDeparture = UUID()
    }

    static func clearRootTabDeparture(owner: UIViewController) {
        existingState(for: owner)?.rootTabDeparture = nil
    }

    enum CaptureCause: String { case cover, disappearance }

    /// Capture while this owner is still visibly mounted, before a push/cover.
    /// UIKit owns the raster-backed snapshot; the real page never moves.
    static func cacheVisiblePage(owner: UIViewController, identity: AnyHashable?, cause: CaptureCause = .disappearance) {
        #if DEBUG && targetEnvironment(simulator)
        let performanceStart = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.arguments.contains("--qa-transition-performance") {
                NSLog("TRANSITION_PERF returnCache_ms=\((CACurrentMediaTime() - performanceStart) * 1000);cause=\(cause.rawValue);rootTab=\(existingState(for: owner)?.rootTabDeparture != nil)")
            }
        }
        #endif
        if cause == .disappearance, existingState(for: owner)?.rootTabDeparture != nil { return }
        previews.removeAll { $0.owner == nil }
        let key = ObjectIdentifier(owner)
        if let existing = previews.first(where: { $0.key == key && $0.owner === owner }) {
            if existing.snapshot.superview != nil { return }
            // Explicit cover capture precedes the native handoff. Do not replace
            // its exact header with a later, already-hidden disappearance pose.
            if cause == .disappearance, existing.hasExactHeaderPixels,
               existing.window === owner.viewIfLoaded?.window,
               existing.windowBounds == existing.window?.bounds,
               existing.identity == identity, let window = existing.window,
               existing.matchesTraits(of: owner, window: window) { return }
        }
        guard let view = owner.viewIfLoaded, let window = view.window,
              view.bounds.width > 1, view.bounds.height > 1, view.layer.mask == nil,
              existingState(for: owner)?.driver.hasActiveFlight != true else { return }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha >= 0.01 else { return }
            ancestor = current.superview
        }
        guard let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        previews.removeAll { $0.key == key }
        if previews.count == 3 { previews.removeFirst() }
        previews.append(PageReturnPreview(owner: owner, snapshot: snapshot,
                                          window: window, frame: view.convert(view.bounds, to: window), identity: identity, captureHeader: cause == .cover))
    }

    fileprivate static func preview(for owner: UIViewController, in window: UIWindow,
                                    identity: AnyHashable?, excluding source: UIView) -> PageReturnPreview {
        previews.removeAll { $0.owner == nil }
        let container = owner.viewIfLoaded
        func cached(in controller: UIViewController) -> PageReturnPreview? {
            let key = ObjectIdentifier(controller)
            if let entry = previews.first(where: { $0.key == key && $0.owner === controller }),
               entry.identity == identity,
               entry.window === window, entry.windowBounds == window.bounds,
               entry.matchesTraits(of: controller, window: window),
               entry.snapshot.superview == nil {
                if entry.kind != .surface { entry.kind = .cached }
                return entry
            }
            let children: [UIViewController]
            if let navigation = controller as? UINavigationController {
                children = navigation.topViewController.map { [$0] } ?? []
            } else if let tabs = controller as? UITabBarController {
                children = tabs.selectedViewController.map { [$0] } ?? []
            } else { children = Array(controller.children.reversed()) }
            for child in children {
                guard let container, let childView = child.viewIfLoaded,
                      childView.isDescendant(of: container) else { continue }
                if let found = cached(in: child) { return found }
            }
            return nil
        }
        if let entry = cached(in: owner) { return entry }
        // A fresh visible snapshot also needs established account provenance.
        // Missing/evicted/rotated caches must never block the actual return.
        let probe = existingState(for: owner)?.viewports.compactMap(\.probe).first
        let trustedIdentity = (probe != nil && probe?.identity == identity)
            || previews.contains { $0.owner === owner && $0.identity == identity }
        if trustedIdentity, let target = owner.viewIfLoaded,
           target !== source, !source.isDescendant(of: target) {
            cacheVisiblePage(owner: owner, identity: identity)
            if let entry = cached(in: owner) {
                if entry.kind != .surface { entry.kind = .visible }
                return entry
            }
        }
        let surface = UIView(frame: window.bounds)
        let style = owner.overrideUserInterfaceStyle == .unspecified
            ? window.traitCollection.userInterfaceStyle : owner.overrideUserInterfaceStyle
        let traits = UITraitCollection(userInterfaceStyle: style)
        surface.backgroundColor = UIColor.systemBackground.resolvedColor(with: traits)
        surface.isUserInteractionEnabled = false
        surface.accessibilityElementsHidden = true
        return PageReturnPreview(owner: owner, snapshot: surface, window: window, frame: window.bounds,
                                 identity: identity, kind: .surface)
    }

    static func invalidatePreviewCache() {
        previews.removeAll()
    }

    fileprivate static func state(for owner: UIViewController) -> PageReturnState {
        if let state = existingState(for: owner) { return state }
        let state = PageReturnState(owner: owner)
        objc_setAssociatedObject(owner, &stateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    fileprivate static func existingState(for owner: UIViewController) -> PageReturnState? {
        objc_getAssociatedObject(owner, &stateKey) as? PageReturnState
    }
}

@MainActor
struct PageReturnFooterPreview {
    let frame: CGRect
    let canvasFrame: CGRect
    let surface: UIView

    init(controls: UIImage, canvas: UIView, frame: CGRect, canvasFrame: CGRect) {
        self.frame = frame; self.canvasFrame = canvasFrame
        let surface = UIView(frame: canvasFrame)
        surface.isUserInteractionEnabled = false; surface.accessibilityElementsHidden = true
        canvas.frame = CGRect(origin: .zero, size: canvasFrame.size)
        surface.addSubview(canvas)
        let ink = UIImageView(image: controls)
        ink.frame = frame.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY)
        ink.isUserInteractionEnabled = false; ink.accessibilityElementsHidden = true
        surface.addSubview(ink)
        self.surface = surface
    }
}

@MainActor
private final class PageReturnPreview {
    enum Kind: String { case cached, visible, surface }
    let key: ObjectIdentifier
    weak var owner: UIViewController?
    weak var window: UIWindow?
    let snapshot: UIView
    let windowBounds: CGRect
    let frame: CGRect
    let identity: AnyHashable?
    var kind: Kind
    let header: HeaderContent?
    let hasExactHeaderPixels: Bool
    let capturedBodyFrame: CGRect?
    let capturedMediaBandFrame: CGRect?
    let capturedMediaBandView: UIView?
    let capturedMediaCanvasFrame: CGRect?
    let footer: PageReturnFooterPreview?
    private let logicalScheme: ColorScheme?
    private let logicalRole: PageCanvasRole?
    private let ownerStyle: UIUserInterfaceStyle
    private let windowStyle: UIUserInterfaceStyle
    private let ownerContentSize: UIContentSizeCategory
    private let windowContentSize: UIContentSizeCategory

    init(owner: UIViewController, snapshot: UIView, window: UIWindow, frame: CGRect,
         identity: AnyHashable?, kind: Kind = .cached, captureHeader: Bool = false) {
        key = ObjectIdentifier(owner)
        self.owner = owner; self.window = window
        windowBounds = window.bounds; self.frame = frame
        self.identity = identity
        self.kind = kind
        let content = NativeHeaderMotion.forWindow(window).settledContent(for: owner)
        let appearance = content?.appearance
        let exactHeader: UIView? = {
            guard captureHeader, NativeHeaderMotion.forWindow(window).canBeginBodyReturn,
                  let content, let page = owner.viewIfLoaded else { return nil }
            let region = page.convert(content.frame, from: window)
            guard page.bounds.contains(region), region.width > 1, region.height > 1 else { return nil }
            guard let snapshot = page.resizableSnapshotView(from: region, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
            snapshot.frame = CGRect(origin: .zero, size: region.size)
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            return snapshot
        }()
        let mediaBand: (view: UIView, frame: CGRect, canvasFrame: CGRect)? = {
            guard captureHeader, appearance != nil,
                  NativeHeaderMotion.forWindow(window).canBeginBodyReturn,
                  let geometry = PageBodyViewports.geometry(containing: owner),
                  let body = geometry.owner.viewIfLoaded,
                  let canvas = owner.viewIfLoaded else { return nil }
            let bodyFrame = body.convert(geometry.rect, to: window)
            let region = CGRect(x: bodyFrame.minX, y: window.bounds.minY,
                                width: bodyFrame.width, height: bodyFrame.minY - window.bounds.minY)
            let local = canvas.convert(region, from: window)
            guard region.height > 1, let content, region.contains(content.frame), canvas.bounds.contains(local),
                  let band = canvas.resizableSnapshotView(from: local, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
            band.isUserInteractionEnabled = false; band.accessibilityElementsHidden = true
            return (band, region, canvas.convert(canvas.bounds, to: window))
        }()
        capturedMediaBandFrame = mediaBand?.frame
        capturedMediaBandView = mediaBand?.view
        capturedMediaCanvasFrame = mediaBand?.canvasFrame
        hasExactHeaderPixels = exactHeader != nil || mediaBand != nil
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
            NSLog("RETURN172_CANVAS band=%d;top=%.2f;height=%.2f", mediaBand == nil ? 0 : 1, mediaBand?.frame.minY ?? -1, mediaBand?.frame.height ?? -1)
        }
        #endif
        if let content, let canonical = HeaderHandoff.renderControls(content) {
            let original = content.appearance
            var environment = EnvironmentValues()
            environment.displayScale = canonical.scale
            let pixels = HeaderAppearance(controls: AnyView(Image(uiImage: canonical).resizable()
                    .opacity(mediaBand == nil ? 1 : 0)
                    .frame(width: content.frame.width, height: content.frame.height)),
                snapshotControls: mediaBand == nil ? exactHeader : nil,
                hasCompositedHeaderSnapshot: mediaBand != nil,
                firstRowHeight: original.firstRowHeight, colorScheme: original.colorScheme,
                surfaceColor: mediaBand == nil ? original.surfaceColor : .clear,
                borderColor: mediaBand == nil ? original.borderColor : .clear,
                surfaceHeight: original.surfaceHeight, environment: environment,
                layoutIdentity: original.layoutIdentity, canvasRole: original.canvasRole,
                contentClearance: original.contentClearance, retainsViewport: original.retainsViewport,
                contentOwner: original.contentOwner)
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
                let roundtrip = HeaderHandoff.renderControls(HeaderContent(frame: content.frame, appearance: pixels))
                NSLog("RETURN172_RASTER role=%@;exact=%d;canonical=%@;roundtrip=%@", String(describing: original.canvasRole), hasExactHeaderPixels ? 1 : 0,
                      HeaderHandoff.qaPixelSignature(canonical), HeaderHandoff.qaPixelSignature(roundtrip))
            }
            #endif
            header = HeaderContent(frame: content.frame, appearance: pixels)
        } else { header = nil }
        footer = {
            guard kind != .surface, let appearance, let page = owner.viewIfLoaded,
                  PageBodyViewports.fixedBottomBarIsOutside(page),
                  let barFrame = PageBodyViewports.fixedBottomBarFrame(in: window),
                  let motion = appearance.environment?.tabPageMotion, let selected = motion.rootHost?.selected,
                  let controls = motion.rootFooterRenderer?(selected, appearance.canvasRole == .playback) else { return nil }
            let canvasFrame = CGRect(x: window.bounds.minX, y: barFrame.minY, width: window.bounds.width,
                                     height: window.bounds.maxY - barFrame.minY)
            let local = page.convert(canvasFrame, from: window).intersection(page.bounds)
            guard !local.isNull, local.width > 1, local.height > 1,
                  let pixels = page.resizableSnapshotView(from: local, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
            // Include the complete footer gutters and home area. Outside the
            // drawable owner (e.g. landscape side safe areas), use its palette.
            let canvas = UIView(frame: CGRect(origin: .zero, size: canvasFrame.size))
            canvas.backgroundColor = appearance.canvasRole == .playback ? .black
                : UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance.colorScheme == .dark ? .dark : .light))
            pixels.frame = page.convert(local, to: window).offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY)
            canvas.addSubview(pixels)
            return PageReturnFooterPreview(controls: controls, canvas: canvas, frame: barFrame, canvasFrame: canvasFrame)
        }()
        logicalScheme = appearance?.colorScheme; logicalRole = appearance?.canvasRole
        ownerStyle = owner.traitCollection.userInterfaceStyle == .unspecified
            ? window.traitCollection.userInterfaceStyle : owner.traitCollection.userInterfaceStyle
        windowStyle = window.traitCollection.userInterfaceStyle
        ownerContentSize = owner.traitCollection.preferredContentSizeCategory
        windowContentSize = window.traitCollection.preferredContentSizeCategory
        // The fixed header has its own renderer. A taller destination header
        // must never escape through a shorter source page's body aperture.
        var hasBodyGeometry = false
        var capturedBodyFrame: CGRect?
        if let geometry = PageBodyViewports.geometry(containing: owner),
           let body = geometry.owner.viewIfLoaded {
            let bodyFrame = body.convert(geometry.rect, to: window)
                .offsetBy(dx: -frame.minX, dy: -frame.minY)
                .intersection(CGRect(origin: .zero, size: frame.size))
            if !bodyFrame.isNull, bodyFrame.width > 1, bodyFrame.height > 1 {
                let mask = CAShapeLayer()
                mask.frame = snapshot.bounds
                mask.path = UIBezierPath(rect: bodyFrame).cgPath
                snapshot.layer.mask = mask
                capturedBodyFrame = bodyFrame.offsetBy(dx: frame.minX, dy: frame.minY)
                hasBodyGeometry = true
            }
        }
        self.capturedBodyFrame = capturedBodyFrame
        if hasBodyGeometry, let mediaBand {
            let surface = UIView(frame: CGRect(origin: .zero, size: frame.size))
            surface.isUserInteractionEnabled = false; surface.accessibilityElementsHidden = true
            snapshot.frame = surface.bounds
            surface.addSubview(snapshot)
            mediaBand.view.frame = mediaBand.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            surface.addSubview(mediaBand.view)
            self.snapshot = surface
        } else if hasBodyGeometry {
            self.snapshot = snapshot
        } else {
            let surface = UIView(frame: CGRect(origin: .zero, size: frame.size))
            let style: UIUserInterfaceStyle = appearance.map { $0.colorScheme == .dark ? .dark : .light }
                ?? (owner.traitCollection.userInterfaceStyle == .unspecified
                    ? window.traitCollection.userInterfaceStyle : owner.traitCollection.userInterfaceStyle)
            surface.backgroundColor = appearance?.canvasRole == .playback ? .black
                : UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            surface.isUserInteractionEnabled = false
            surface.accessibilityElementsHidden = true
            self.snapshot = surface
            self.kind = .surface
        }
    }

    func matchesMediaCanvas(of owner: UIViewController, window: UIWindow) -> Bool {
        guard let expected = capturedMediaCanvasFrame else { return true }
        guard owner === self.owner, let canvas = owner.viewIfLoaded, canvas.window === window else { return false }
        let current = canvas.convert(canvas.bounds, to: window)
        return abs(current.minX - expected.minX) <= 2 && abs(current.minY - expected.minY) <= 2 &&
            abs(current.width - expected.width) <= 2 && abs(current.height - expected.height) <= 2
    }

    func matchesTraits(of owner: UIViewController, window: UIWindow) -> Bool {
        if let logicalScheme, let logicalRole,
           let appearance = NativeHeaderMotion.forWindow(window).appearance(for: owner) {
            // A covering page can change inherited UIKit traits. Validate the
            // destination's own declared palette rather than its cover's style.
            return appearance.colorScheme == logicalScheme && appearance.canvasRole == logicalRole
                && ownerContentSize == owner.traitCollection.preferredContentSizeCategory
                && windowContentSize == window.traitCollection.preferredContentSizeCategory
        }
        let style = owner.traitCollection.userInterfaceStyle == .unspecified
            ? window.traitCollection.userInterfaceStyle : owner.traitCollection.userInterfaceStyle
        return ownerStyle == style && windowStyle == window.traitCollection.userInterfaceStyle
            && ownerContentSize == owner.traitCollection.preferredContentSizeCategory
            && windowContentSize == window.traitCollection.preferredContentSizeCategory
    }
}

extension View {
    /// Apply to the content inside FloatingPageBar, before its header/footer insets.
    func pageReturnViewport(topInset: CGFloat, bottomInset: CGFloat, identity: AnyHashable? = nil,
                            onReturn: @escaping () -> Void) -> some View {
        background {
            PageReturnMarker(kind: .viewport, action: nil, identity: identity,
                             topInset: topInset, bottomInset: bottomInset, onReturn: onReturn)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// Explicit close for this modal root only. Existing finish/save guards remain
    /// in the supplied action; return false to reject and rebound the preview.
    /// This modifier never dismisses a UIKit controller.
    func pageReturnAction(enabled: Bool = true, action: @escaping () -> Bool) -> some View {
        background {
            PageReturnMarker(kind: .action, action: enabled ? action : nil, identity: nil,
                             topInset: 0, bottomInset: 0, onReturn: nil)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

@MainActor
private final class PageReturnState {
    struct Source {
        let token: UUID
        weak var probe: PageReturnProbe?
    }
    weak var owner: UIViewController?
    var rootTabDeparture: UUID?
    var segmentedTokens = Set<UUID>()
    var viewports: [Source] = []
    var actions: [Source] = []
    lazy var driver = PageReturnDriver(state: self)

    init(owner: UIViewController) { self.owner = owner }

    func register(_ probe: PageReturnProbe) {
        viewports.removeAll { $0.probe == nil || $0.token == probe.token }
        actions.removeAll { $0.probe == nil || $0.token == probe.token }
        switch probe.kind {
        case .viewport: viewports.append(Source(token: probe.token, probe: probe))
        case .action: actions.append(Source(token: probe.token, probe: probe))
        }
        driver.refresh()
    }

    func unregister(_ token: UUID, disappeared: Bool = false) {
        viewports.removeAll { $0.probe == nil || $0.token == token }
        actions.removeAll { $0.probe == nil || $0.token == token }
        driver.sourceRemoved(token, disappeared: disappeared)
        driver.refresh()
    }

    var viewport: PageReturnProbe? {
        viewports.reversed().compactMap(\.probe).first { $0.isVisibleSource }
    }

    var close: PageReturnProbe? {
        actions.reversed().compactMap(\.probe).first { $0.isVisibleSource && $0.closeAction != nil }
    }
}

private struct PageReturnMarker: UIViewControllerRepresentable {
    enum Kind { case viewport, action }
    let kind: Kind
    let action: (() -> Bool)?
    let identity: AnyHashable?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onReturn: (() -> Void)?
    @Environment(\.pageReturnNavigationReceipt) private var navigationReceipt

    func makeUIViewController(context: Context) -> PageReturnProbe {
        let probe = PageReturnProbe(kind: kind)
        probe.closeAction = action
        probe.identity = identity
        probe.topInset = topInset
        probe.bottomInset = bottomInset
        probe.returnAction = onReturn
        probe.navigationReceipt = navigationReceipt
        return probe
    }

    func updateUIViewController(_ probe: PageReturnProbe, context: Context) {
        if probe.identity != identity { probe.invalidateIdentity() }
        if probe.topInset != topInset || probe.bottomInset != bottomInset { probe.invalidateViewport() }
        if probe.navigationReceipt !== navigationReceipt { probe.invalidateViewport() }
        probe.identity = identity
        probe.topInset = topInset
        probe.bottomInset = bottomInset
        probe.closeAction = action
        probe.returnAction = onReturn
        probe.navigationReceipt = navigationReceipt
        probe.attach()
    }

    static func dismantleUIViewController(_ probe: PageReturnProbe, coordinator: ()) {
        probe.detach()
        probe.closeAction = nil
        probe.returnAction = nil
    }
}

@MainActor
private final class PageReturnProbe: UIViewController {
    let token = UUID()
    let kind: PageReturnMarker.Kind
    var closeAction: (() -> Bool)?
    var returnAction: (() -> Void)?
    var navigationReceipt: PageReturnNavigationReceipt?
    var identity: AnyHashable?
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    private weak var registeredOwner: UIViewController?
    private var disappeared = false
    private var popReceipt: PageNativePopReceiptObserver?

    init(kind: PageReturnMarker.Kind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let marker = PageReturnMarkerView()
        marker.backgroundColor = .clear
        marker.isUserInteractionEnabled = false
        marker.onWindowChange = { [weak self] in self?.attach() }
        view = marker
    }

    var isVisibleSource: Bool {
        guard !disappeared, let view = viewIfLoaded, view.window != nil else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return true
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        attach()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        disappeared = false
        popReceipt = nil
        attach()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        disappeared = false
        attach()
        if let owner = registeredOwner { PageEdgeReturnPolicy.clearRootTabDeparture(owner: owner) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        if case .viewport = kind, let owner = registeredOwner ?? resolveOwner() {
            popReceipt = PageEdgeReturnPolicy.existingState(for: owner)?.driver.observeNativePop(from: owner)
            popReceipt?.observeTransition(from: owner)
        }
        if case .viewport = kind, let owner = registeredOwner ?? resolveOwner(),
           let navigation = owner.navigationController, !owner.isMovingFromParent,
           navigation.viewControllers.contains(where: { $0 === owner }) {
            PageEdgeReturnPolicy.cacheVisiblePage(owner: owner, identity: identity)
        }
        super.viewWillDisappear(animated)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attach()
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        attach()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        registeredOwner.flatMap { PageEdgeReturnPolicy.existingState(for: $0) }?.driver.invalidateLayout()
        super.viewWillTransition(to: size, with: coordinator)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        popReceipt?.sourceDisappeared()
        if let owner = registeredOwner { PageEdgeReturnPolicy.clearRootTabDeparture(owner: owner) }
        disappeared = true
        detach(disappeared: true)
    }

    func attach() {
        guard isVisibleSource, let owner = resolveOwner() else {
            detach()
            return
        }
        if registeredOwner !== owner {
            detach()
            registeredOwner = owner
        }
        PageEdgeReturnPolicy.state(for: owner).register(self)
    }

    func detach(disappeared: Bool = false) {
        let previous = registeredOwner
        registeredOwner = nil
        if let previous {
            PageEdgeReturnPolicy.existingState(for: previous)?.unregister(token, disappeared: disappeared)
        }
    }

    func invalidateIdentity() {
        PageEdgeReturnPolicy.invalidatePreviewCache()
        if let registeredOwner {
            PageEdgeReturnPolicy.existingState(for: registeredOwner)?.driver.identityDidChange()
        }
    }

    func invalidateViewport() {
        if let registeredOwner {
            PageEdgeReturnPolicy.existingState(for: registeredOwner)?.driver.invalidateLayout()
        }
    }

    private func resolveOwner() -> UIViewController? { PageViewportGeometry.owner(of: self) }
}

private final class PageReturnMarkerView: UIView {
    var onWindowChange: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

/// One driver per controller, even if a SwiftUI layout temporarily mounts two
/// viewport markers. UIKit navigation delegates and transitions stay untouched.
@MainActor
private final class PageReturnDriver: NSObject, UIGestureRecognizerDelegate {
    private weak var state: PageReturnState?
    private weak var host: UIView?
    private lazy var pan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }()
    private var origin: CGPoint?
    private var sign: CGFloat = 1
    private var flight: PageReturnFlight?
    private var animator: RenderProgressAnimation?
    #if DEBUG && targetEnvironment(simulator)
    private static var qaKey: UInt8 = 0
    #endif

    init(state: PageReturnState) {
        self.state = state
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(becameInactive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameInactive), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // The owner is a UIKit controller and releases its associated state on
        // the main thread. Cover teardown even if SwiftUI skips dismantling.
        MainActor.assumeIsolated {
            animator?.cancel()
            host?.removeGestureRecognizer(pan)
            flight?.completeNativeHeader(animate: false)
            if let flight {
                _ = flight.receipt.recordVisual(.aborted("return-driver-released"), token: flight.bodyToken)
                flight.navigationReceipt?.releaseBody(flight.bodyToken)
                flight.bodyHandoff.cancel(reason: "return-driver-released")
            }
            flight?.removeVisuals()
            #if DEBUG && targetEnvironment(simulator)
            if let flight {
                recordQA(phase: "aborted", flight: flight, reason: "return-driver-released")
            }
            #endif
        }
    }

    var hasActiveFlight: Bool { flight != nil }

    var isAvailable: Bool {
        guard let state, state.segmentedTokens.isEmpty, let owner = state.owner,
              let viewport = state.viewport, viewport.viewIfLoaded?.window != nil,
              isCurrent(owner), viewportRect(viewport, in: owner) != nil else { return false }
        if let navigation = owner.navigationController,
           let index = navigation.viewControllers.firstIndex(where: { $0 === owner }), index > 0 { return true }
        return state.close != nil && state.viewport?.navigationReceipt != nil && presentingBoundary(of: owner) != nil
    }

    func refresh() {
        guard let state, let owner = state.owner, let page = owner.viewIfLoaded,
              state.viewport != nil else {
            if flight?.phase != .awaitingDisappearance { cancelImmediately(reason: "refresh-no-viewport") }
            host?.removeGestureRecognizer(pan)
            host = nil
            return
        }
        if host !== page {
            cancelImmediately(reason: "refresh-owner-view")
            host?.removeGestureRecognizer(pan)
            host = page
            page.addGestureRecognizer(pan)
        }
        if let flight, flight.phase != .awaitingDisappearance {
            if !geometryMatches(flight) { cancelImmediately(reason: "refresh-geometry") }
            else if !isCurrent(owner) {
                #if DEBUG && targetEnvironment(simulator)
                cancelImmediately(reason: "refresh-owner-not-current")
                #else
                cancelImmediately(reason: "refresh-owner-not-current")
                #endif
            }
            else if !state.segmentedTokens.isEmpty { cancelImmediately(reason: "refresh-segmented") }
        }
        // Keep a held/settling pan alive; eligibility is always rechecked at
        // touch time, during movement, and again immediately before committing.
        pan.isEnabled = state.viewport != nil
    }

    func policyDidChange() {
        if state?.segmentedTokens.isEmpty == false, flight?.phase != .awaitingDisappearance { cancelImmediately() }
        refresh()
    }

    func sourceRemoved(_ token: UUID, disappeared _: Bool) {
        guard let flight, token == flight.viewportToken || token == flight.actionToken else { return }
        if flight.phase == .awaitingDisappearance {
            // Probe removal is not a navigation receipt. The exact native-pop
            // observer or presentation session will report the platform outcome.
            return
        } else {
            cancelImmediately(reason: "source-removed")
        }
    }

    func invalidateLayout() {
        cancelImmediately(reason: "return-layout-invalidated")
    }

    func identityDidChange() { cancelImmediately(reason: "identity-changed") }

    func observeNativePop(from owner: UIViewController) -> PageNativePopReceiptObserver? {
        guard let flight, flight.phase == .awaitingDisappearance, flight.owner === owner,
              let navigation = flight.navigation else { return nil }
        return PageNativePopReceiptObserver(owner: owner, navigation: navigation) { [self, flight] outcome in
            receiveNavigation(outcome, flight: flight)
        }
    }

    private func receiveNavigation(_ outcome: PageNavigationOutcome, flight: PageReturnFlight) {
        guard flight.receipt.recordNavigation(outcome, token: flight.bodyToken) else { return }
        guard self.flight === flight else { return } // Visual cancellation cannot undo this receipt.
        if outcome == .committed { finishCommitted(flight) }
        else { cancelImmediately(reason: outcome == .cancelled ? "cancel" : "platform-return-not-committed") }
    }

    @objc private func becameInactive(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== host?.window?.windowScene { return }
        invalidateLayout()
    }
    @objc private func orientationChanged() { invalidateLayout() }

    private func isCurrent(_ owner: UIViewController) -> Bool {
        guard let view = owner.viewIfLoaded, let window = view.window,
              window.windowScene?.activationState == .foregroundActive,
              !owner.isBeingDismissed, !owner.isMovingFromParent else { return false }
        var controller: UIViewController? = owner
        while let current = controller {
            guard current.presentedViewController == nil, current.transitionCoordinator == nil,
                  !current.isBeingDismissed else { return false }
            if let navigation = current as? UINavigationController, navigation.topViewController !== owner { return false }
            controller = current.parent
        }
        if let navigation = owner.navigationController, navigation.topViewController !== owner { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return true
    }

    private func viewportRect(_ probe: PageReturnProbe, in owner: UIViewController) -> CGRect? {
        guard let source = owner.viewIfLoaded, let marker = probe.viewIfLoaded else { return nil }
        return PageViewportGeometry.rect(owner: source, marker: marker, top: probe.topInset, bottom: probe.bottomInset)
    }

    private func edge(at point: CGPoint, in rect: CGRect) -> CGFloat? {
        guard rect.contains(point) else { return nil }
        if point.x - rect.minX <= 30 { return 1 }
        if rect.maxX - point.x <= 30 { return -1 }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        origin = nil
        guard gestureRecognizer === pan, flight == nil, isAvailable,
              let state, let owner = state.owner, let source = owner.viewIfLoaded,
              let probe = state.viewport, let rect = viewportRect(probe, in: owner) else {
            #if DEBUG && targetEnvironment(simulator)
            if let host {
                let point = touch.location(in: host)
                if point.x - host.bounds.minX <= 30 || host.bounds.maxX - point.x <= 30 {
                    recordGuardQA(reason: "receive-\(unavailableReason)")
                }
            }
            #endif
            return false
        }
        let point = touch.location(in: source)
        guard let edgeSign = edge(at: point, in: rect) else { return false }
        origin = point
        sign = edgeSign
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, flight == nil, isAvailable,
              let origin, let state, let owner = state.owner, let source = owner.viewIfLoaded,
              let probe = state.viewport, let rect = viewportRect(probe, in: owner),
              edge(at: origin, in: rect) == sign else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "shouldBegin-\(unavailableReason)")
            #endif
            return false
        }
        if let window = source.window, PageInteractionShield.isActive(in: window) { return false }
        let velocity = pan.velocity(in: source)
        guard velocity.x * sign > 0, abs(velocity.x) > abs(velocity.y) * 1.4 else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "shouldBegin-direction-vx\(Int(velocity.x))-vy\(Int(velocity.y))-sign\(Int(sign))")
            #endif
            return false
        }
        // Eligibility must not mutate the hierarchy. UIKit may still reject
        // this recognizer after consulting another delegate's failure rules.
        return destination(for: owner, state: state) != nil && source.layer.mask == nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A SwiftUI scroll pan can begin before failure precedence is queried.
        // It never receives this driver's return commit, and the shield blocks taps.
        return gestureRecognizer === pan && otherGestureRecognizer is UIPanGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, isAvailable, origin != nil else { return false }
        // A body-originating touch must first resolve its edge intent. SwiftUI
        // also installs non-pan recognizers for buttons and gesture containers;
        // protecting only UIScrollView's pan lets those claim the same drag.
        // System/navigation recognizers outside this page are not reordered.
        guard let state, let owner = state.owner, let source = owner.viewIfLoaded,
              let origin, let probe = state.viewport,
              let rect = viewportRect(probe, in: owner), edge(at: origin, in: rect) == sign,
              let otherView = otherGestureRecognizer.view,
              otherView === source || otherView.isDescendant(of: source) else { return false }
        return true
    }

    @objc private func panned() {
        if pan.state == .began, flight == nil {
            guard isAvailable, let state, let owner = state.owner, let probe = state.viewport,
                  let rect = viewportRect(probe, in: owner), begin(owner: owner, probe: probe, rect: rect) else { return }
        }
        guard let flight, flight.phase == .dragging else { return }
        guard validForCommit(flight) else { cancelImmediately(); return }
        let translation = pan.translation(in: flight.source).x
        switch pan.state {
        case .began, .changed:
            move(flight, translation: translation)
        case .ended:
            move(flight, translation: translation)
            let distance = max(0, translation * flight.sign)
            let velocity = pan.velocity(in: flight.source).x * flight.sign
            settle(flight, commit: distance >= 45 || (distance >= 12 && velocity >= 450))
        case .cancelled, .failed:
            settle(flight, commit: false)
        default: break
        }
    }

    private func begin(owner: UIViewController, probe: PageReturnProbe, rect: CGRect) -> Bool {
        guard let state, let source = owner.viewIfLoaded, let parent = source.superview,
              let window = source.window, !PageInteractionShield.isActive(in: window) else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "begin-source-unavailable")
            #endif
            return false
        }
        guard source.layer.mask == nil else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "begin-source-already-masked")
            #endif
            return false
        }
        guard let destination = destination(for: owner, state: state) else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "begin-target-unavailable")
            #endif
            return false
        }
        let preview = PageEdgeReturnPolicy.preview(for: destination.controller, in: window,
                                                   identity: probe.identity, excluding: source)
        guard preview.snapshot.superview == nil else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "begin-preview-not-ready")
            #endif
            return false
        }

        // Both visual surfaces are copies. The destination's actual SwiftUI /
        // AVPlayer hierarchy stays exactly where UIKit owns it throughout preview.
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: rect.size))
        var rendered = false
        let image = renderer.image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            rendered = source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
        }
        guard rendered else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "begin-source-draw-failed")
            #endif
            return false
        }

        let flight = PageReturnFlight(owner: owner, source: source, parent: parent,
                                      destination: destination, viewportToken: probe.token,
                                      identity: probe.identity, rect: rect, sign: sign, preview: preview)
        self.flight = flight
        if destination.navigation != nil {
            let motion = NativeHeaderMotion.forWindow(window)
            let route = UUID()
            if let tone = motion.beginBodyReturn(from: owner, to: destination.controller, id: route, cachedTarget: preview.kind != .surface ? preview.header : nil) {
                flight.headerRoute = route
                flight.sharedTone = tone
                flight.nativeHeaderCompletion = { [weak motion, weak flight] animate, completion in
                    guard let motion else { completion(false); return }
                    motion.completeRoute(route, animate: animate, prepareBody: {
                        guard let flight else { return false }
                        let prepared = flight.bodyHandoff.startReturnTone(flight.bodyToken, destination: flight.destination)
                        if prepared { motion.markPreparedCanvas(routeID: route) }
                        return prepared
                    }, completion: completion)
                }
            }
        }
        func stillCurrent(_ stage: String) -> Bool {
            let current = self.flight === flight && self.validForCommit(flight)
            if !current { flight.assemblyFailure = stage }
            return current
        }
        // Mount the source copy while the live source still covers the target.
        // Do not expose the target or punch a hole before this copy is rendered.
        let imageView = UIImageView(image: image)
        imageView.isUserInteractionEnabled = false
        imageView.accessibilityElementsHidden = true
        imageView.frame = source.convert(rect, to: parent)
        flight.snapshot = imageView
        parent.insertSubview(imageView, aboveSubview: source)
        guard stillCurrent("snapshot-insert") else { abandonAssembly(flight); return false }
        flight.assemblyBoundary = RenderFrameBoundary { [weak self, weak flight] in
            guard let self, let flight else { return }
            guard self.validForCommit(flight) else {
                if self.flight === flight { self.cancelImmediately(reason: "assembly-frame-invalid") }
                return
            }
            flight.assemblyBoundary = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.snapshot.frame = parent.convert(preview.frame, from: window)
            parent.insertSubview(preview.snapshot, belowSubview: source)
            if flight.sharedTone != nil, let bandFrame = preview.capturedMediaBandFrame,
               let band = preview.capturedMediaBandView {
                band.frame = parent.convert(bandFrame, from: window)
                band.alpha = 0
                parent.insertSubview(band, aboveSubview: source)
                flight.mediaHeaderCanvas = band
            }
            if let footer = preview.footer, footer.surface.superview == nil {
                footer.surface.frame = footer.canvasFrame; footer.surface.alpha = 0
                window.addSubview(footer.surface)
                flight.footerSurface = footer.surface
            }
            guard self.validForCommit(flight) else {
                CATransaction.commit()
                self.abandonAssembly(flight)
                return
            }
            let mask = CAShapeLayer()
            mask.frame = source.bounds
            mask.fillRule = .evenOdd
            let path = UIBezierPath(rect: source.bounds)
            path.append(UIBezierPath(rect: rect))
            mask.path = path.cgPath
            flight.mask = mask
            source.layer.mask = mask
            guard self.validForCommit(flight) else {
                CATransaction.commit()
                self.abandonAssembly(flight)
                return
            }
            flight.assembled = true
            self.move(flight, translation: flight.pendingTranslation)
            CATransaction.commit()
            #if DEBUG && targetEnvironment(simulator)
            self.recordQA(phase: "dragging", flight: flight)
            #endif
            if let commit = flight.pendingSettle { self.settle(flight, commit: commit) }
        }
        // Acquiring a shield changes the window hierarchy and can itself reenter
        // page registration. Keep the new lease local until the flight survives.
        let interaction = PageInteractionShield.acquire(in: window)
        guard stillCurrent("shield-acquire") else {
            interaction.release()
            abandonAssembly(flight)
            return false
        }
        flight.interaction = interaction
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "dragging", flight: flight)
        #endif
        guard stillCurrent("begin-finished") else { abandonAssembly(flight); return false }
        return true
    }

    private func abandonAssembly(_ flight: PageReturnFlight) {
        if self.flight === flight { cancelImmediately(reason: "assembly-\(flight.assemblyFailure ?? "invalid")") }
        // A reentrant cancellation may already have detached this flight. Its
        // local begin call still owns it until every partial mutation is undone.
        flight.removeVisuals()
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "cancelled", flight: flight, event: "reentered", reason: flight.assemblyFailure ?? "assembly-invalid")
        #endif
    }

    private struct Destination {
        let controller: UIViewController
        let navigation: UINavigationController?
        let actionToken: UUID?
    }

    private func destination(for owner: UIViewController, state: PageReturnState) -> Destination? {
        if let navigation = owner.navigationController,
           let index = navigation.viewControllers.firstIndex(where: { $0 === owner }), index > 0 {
            let previous = navigation.viewControllers[index - 1]
            return Destination(controller: previous, navigation: navigation, actionToken: nil)
        }
        guard let close = state.close, close.closeAction != nil,
              let boundary = presentingBoundary(of: owner), let presenter = boundary.presentingViewController else { return nil }
        return Destination(controller: presenter, navigation: nil, actionToken: close.token)
    }

    private func presentingBoundary(of owner: UIViewController) -> UIViewController? {
        var current: UIViewController? = owner
        while let candidate = current {
            if candidate.presentingViewController != nil { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private func geometryMatches(_ flight: PageReturnFlight) -> Bool {
        guard let owner = state?.owner, let probe = state?.viewport,
              probe.token == flight.viewportToken, let rect = viewportRect(probe, in: owner) else { return false }
        return flight.source.bounds == flight.sourceBounds
            && flight.source.safeAreaInsets == flight.sourceSafeAreaInsets && rect == flight.rect
            && flight.source.superview === flight.parent && flight.source.window === flight.window
            && flight.source.convert(flight.rect, to: flight.parent) == flight.snapshotFrame
    }

    private func validForCommit(_ flight: PageReturnFlight) -> Bool {
        guard self.flight === flight, let state, let owner = state.owner,
              owner === flight.owner, state.segmentedTokens.isEmpty,
              state.viewport?.identity == flight.identity,
              isCurrent(owner), geometryMatches(flight) else { return false }
        if let navigation = flight.navigation {
            let stack = navigation.viewControllers
            return stack.last === owner && stack.count > 1 && stack[stack.count - 2] === flight.destination
        }
        return state.close?.token == flight.actionToken
            && state.close?.closeAction != nil
            && presentingBoundary(of: owner)?.presentingViewController === flight.destination
    }

    private func move(_ flight: PageReturnFlight, translation: CGFloat) {
        flight.pendingTranslation = translation
        guard flight.assembled else { return }
        let distance = min(flight.rect.width, max(0, translation * flight.sign))
        flight.snapshot?.transform = CGAffineTransform(translationX: distance * flight.sign, y: 0)
        flight.mediaHeaderCanvas?.alpha = distance / max(1, flight.rect.width)
        flight.footerSurface?.alpha = distance / max(1, flight.rect.width)
        if let route = flight.headerRoute, let window = flight.window {
            NativeHeaderMotion.forWindow(window).updateBodyReturn(route, progress: Double(distance / max(1, flight.rect.width)))
        }
        #if DEBUG && targetEnvironment(simulator)
        if !flight.qaMidRecorded, flight.phase == .dragging, distance >= flight.rect.width * 0.35 {
            flight.qaMidRecorded = true
            recordQA(phase: "tracking", flight: flight)
        }
        #endif
    }

    private func settle(_ flight: PageReturnFlight, commit: Bool) {
        guard self.flight === flight else { return }
        guard flight.assembled else { flight.pendingSettle = commit; return }
        flight.phase = .settling
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "settling", flight: flight)
        #endif
        let start = min(1, max(0, flight.pendingTranslation * flight.sign / max(1, flight.rect.width)))
        let end: CGFloat = commit ? 1 : 0
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.26 * Double(abs(end - start))
        let curve = UnitCurve.bezier(startControlPoint: .init(x: 0.22, y: 0.8), endControlPoint: .init(x: 0.32, y: 1))
        animator = RenderProgressAnimation(duration: duration) { [weak self, weak flight] elapsed in
            guard let self, let flight, self.flight === flight else { return }
            let p = start + (end - start) * curve.value(at: min(1, elapsed / max(0.001, duration)))
            self.move(flight, translation: p * flight.rect.width * flight.sign)
        } completion: { [weak self, weak flight] in
            guard let self, let flight, self.flight === flight else { return }
            self.animator = nil
            self.move(flight, translation: end * flight.rect.width * flight.sign)
            if commit, self.validForCommit(flight) { self.commit(flight) }
            else { self.cancelImmediately() }
        }
    }

    private func commit(_ flight: PageReturnFlight) {
        guard validForCommit(flight), let owner = flight.owner else { cancelImmediately(); return }
        flight.phase = .awaitingDisappearance
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "awaitingDisappearance", flight: flight)
        #endif
        origin = nil
        if let window = flight.window {
            let appearance = NativeHeaderMotion.forWindow(window).appearance(for: owner)
            // The gesture aperture belongs to the source. Once committed,
            // retain the media destination's own captured viewport; cropping
            // it to a taller author's body loses the strip below its header.
            let usesFullBand = flight.sharedTone != nil && flight.preview.header?.appearance.hasCompositedHeaderSnapshot == true
            let previewFrame = usesFullBand
                ? (flight.preview.capturedBodyFrame ?? flight.source.convert(flight.rect, to: window))
                : flight.source.convert(flight.rect, to: window)
            flight.bodyHandoff.preparePreview(flight.bodyToken, snapshot: flight.preview.snapshot,
                                               frame: previewFrame, in: window,
                                               sourceScheme: appearance?.colorScheme ?? .light,
                                               sourceIsMedia: appearance?.canvasRole == .playback, sharedTone: flight.sharedTone)
            if usesFullBand {
                guard flight.bodyHandoff.hasCapturedReturnPixels(flight.bodyToken),
                      let band = flight.mediaHeaderCanvas, let bandFrame = flight.preview.capturedMediaBandFrame else {
                    flight.bodyHandoff.cancel(reason: "return-promotion-capture-failed")
                    cancelImmediately(reason: "return-promotion-capture-failed")
                    return
                }
                let preview = flight.preview
                guard flight.bodyHandoff.installReturnHeaderBand(flight.bodyToken, band: band, frame: bandFrame, release: {
                    band.alpha = 1
                    band.frame = bandFrame.offsetBy(dx: -preview.frame.minX, dy: -preview.frame.minY)
                    preview.snapshot.addSubview(band)
                }) else {
                    flight.bodyHandoff.cancel(reason: "return-header-band-transfer-failed")
                    cancelImmediately(reason: "return-header-band-transfer-failed")
                    return
                }
            }
        }
        if let footer = flight.preview.footer {
            flight.footerProtected = flight.bodyHandoff.installReturnFooter(flight.bodyToken, footer: footer)
            guard flight.footerProtected else {
                cancelImmediately(reason: "return-footer-transfer-failed"); return
            }
        }
        if flight.navigation != nil {
            guard let onReturn = state?.viewport?.returnAction else {
                cancelImmediately(reason: "missing-swiftui-return")
                return
            }
            let motion = flight.window.map(NativeHeaderMotion.forWindow)
            let route = UUID()
            let pinned = flight.nativeHeaderCompletion == nil && motion?.beginRoute(from: owner, to: flight.destination, id: route, tone: flight.bodyHandoff.tone,
                                            preservesDestinationViewport: true) == true
            if pinned {
                flight.nativeHeaderCompletion = { [weak motion, weak flight] animate, completion in
                    guard let motion else { completion(false); return }
                    motion.completeRoute(route, animate: animate, prepareBody: {
                        guard let flight else { return false }
                        let prepared = flight.bodyHandoff.startReturnTone(flight.bodyToken, destination: flight.destination)
                        if prepared { motion.markPreparedCanvas(routeID: route) }
                        return prepared
                    }, completion: completion)
                }
            }
            guard self.flight === flight else {
                flight.completeNativeHeader(animate: false)
                return
            }
            // Match the real SwiftUI Back button, including its navigation state
            // and toolbar preferences. Our native observer confirms the actual pop.
            withoutPageAnimation { onReturn() }
        } else {
            // Read the current closure from the same registration. Do not retain
            // a stale form/account action across a held gesture or a rerender.
            guard let receipt = state?.viewport?.navigationReceipt,
                  receipt.claimBody(flight.bodyToken, navigation: { [self, flight] outcome in
                      receiveNavigation(outcome, flight: flight)
                  }, abortVisual: { [self, flight] reason in
                      if self.flight === flight { cancelImmediately(reason: reason) }
                      else {
                          flight.revealBoundary?.cancel(); flight.revealBoundary = nil
                          flight.bodyHandoff.cancel(reason: reason)
                          visualDidFinish(.aborted(reason), flight: flight)
                      }
                  }) else {
                cancelImmediately(reason: "missing-presentation-receipt")
                return
            }
            flight.navigationReceipt = receipt
            guard let close = state?.close, close.token == flight.actionToken,
                  let action = close.closeAction else { cancelImmediately(); return }
            let accepted = action()
            guard self.flight === flight else { return }
            if !accepted {
                _ = flight.receipt.recordNavigation(.cancelled, token: flight.bodyToken)
                flight.navigationReceipt?.releaseBody(flight.bodyToken)
                flight.navigationReceipt = nil
                flight.bodyHandoff.cancel()
                settle(flight, commit: false)
                return
            }
        }
    }

    private func finishCommitted(_ flight: PageReturnFlight) {
        guard self.flight === flight, flight.receipt.navigation == .committed else { return }
        self.flight = nil
        origin = nil
        flight.removeVisuals()
        // The platform has popped, but the parent's binding/player visibility
        // is committed on the next main turn. Keep the promoted target body
        // alive independently of the departed source until that rendered frame.
        let coordinatedHeader = flight.nativeHeaderCompletion != nil
        flight.completeNativeHeader(animate: true) { [self, flight] completed in
            guard flight.bodyHandoff.isPrepared(flight.bodyToken) else {
                visualDidFinish(.aborted("body-ended-before-header"), flight: flight)
                return
            }
            guard completed else {
                flight.bodyHandoff.cancel(reason: "header-handoff-failed")
                visualDidFinish(.aborted("header-handoff-failed"), flight: flight)
                return
            }
            guard let window = flight.window, flight.preview.matchesMediaCanvas(of: flight.destination, window: window) else {
                flight.bodyHandoff.cancel(reason: "return-media-canvas-changed")
                visualDidFinish(.aborted("return-media-canvas-changed"), flight: flight)
                return
            }
            if coordinatedHeader {
                flight.bodyHandoff.finishReturnReveal(flight.bodyToken, destination: flight.destination) { [self, flight] outcome in
                    visualDidFinish(outcome, flight: flight)
                }
                return
            }
            flight.revealBoundary = RenderFrameBoundary { [self, flight] in
                flight.revealBoundary = nil
                flight.bodyHandoff.reveal(flight.bodyToken, destination: flight.destination) { [self, flight] outcome in
                    visualDidFinish(outcome, flight: flight)
                }
            }
        }
    }

    private func visualDidFinish(_ outcome: PageVisualOutcome, flight: PageReturnFlight) {
        guard flight.receipt.recordVisual(outcome, token: flight.bodyToken) else { return }
        flight.navigationReceipt?.releaseBody(flight.bodyToken)
        flight.navigationReceipt = nil
        #if DEBUG && targetEnvironment(simulator)
        let phase: String
        switch outcome {
        case .completed: phase = "completed"
        case .cancelled: phase = "cancelled"
        case .aborted: phase = "aborted"
        }
        recordQA(phase: phase, flight: flight)
        #endif
    }

    private func cancelImmediately(reason: String = "cancel") {
        let outgoing = flight
        flight = nil
        origin = nil
        animator?.cancel()
        animator = nil
        if let flight = outgoing {
            if flight.phase != .awaitingDisappearance {
                _ = flight.receipt.recordNavigation(.cancelled, token: flight.bodyToken)
            }
            flight.completeNativeHeader(animate: false)
            flight.revealBoundary?.cancel(); flight.revealBoundary = nil
            let outcome: PageVisualOutcome = reason == "cancel" && flight.receipt.navigation != .committed
                ? .cancelled : .aborted(reason)
            flight.bodyHandoff.cancel(reason: reason == "cancel" ? "cancelled" : reason)
            flight.removeVisuals()
            visualDidFinish(outcome, flight: flight)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    private func qaLabel(in window: UIWindow) -> UILabel {
        if let existing = objc_getAssociatedObject(window, &Self.qaKey) as? UILabel { return existing }
        let label = UILabel(frame: CGRect(x: window.bounds.minX, y: window.bounds.maxY - 1, width: 1, height: 1))
        label.alpha = 0.01
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "page.return-motion.qa"
        label.accessibilityLabel = "Page return motion"
        label.autoresizingMask = [.flexibleTopMargin]
        objc_setAssociatedObject(window, &Self.qaKey, label, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.addSubview(label)
        return label
    }

    private var unavailableReason: String {
        guard let state else { return "no-state" }
        guard state.segmentedTokens.isEmpty else { return "segmented" }
        guard let owner = state.owner else { return "no-owner" }
        guard let probe = state.viewport else { return "no-viewport" }
        guard probe.viewIfLoaded?.window != nil else { return "viewport-no-window" }
        guard isCurrent(owner) else { return "owner-not-current" }
        guard viewportRect(probe, in: owner) != nil else { return "viewport-invalid" }
        if let nav = owner.navigationController, let index = nav.viewControllers.firstIndex(where: { $0 === owner }), index > 0 {
            return "origin-or-flight"
        }
        guard state.close != nil else { return "no-root-action" }
        guard presentingBoundary(of: owner) != nil else { return "no-presenter" }
        return "origin-or-flight"
    }

    private func recordGuardQA(reason: String) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-page-return"),
              let window = host?.window ?? state?.owner?.viewIfLoaded?.window else { return }
        let label = qaLabel(in: window)
        let owner = state?.owner
        let source = owner?.viewIfLoaded
        let actionWithinOwner = state?.close?.viewIfLoaded.map { action in
            source.map { action.isDescendant(of: $0) } ?? false
        } ?? false
        let ownsReturn = owner.map { PageEdgeReturnPolicy.ownsReturnGesture(owner: $0) } ?? false
        label.accessibilityValue = "phase=guard;event=guard;reason=\(reason);sourceMasked=\(source?.layer.mask != nil);hasViewport=\(state?.viewport != nil);hasAction=\(state?.close != nil);actionWithinOwner=\(actionWithinOwner);navDepth=\(owner?.navigationController?.viewControllers.count ?? 0);topMatches=\(owner?.navigationController?.topViewController === owner);windowActive=\(window.windowScene?.activationState == .foregroundActive);globalBlocked=\(PageInteractionShield.blocksNewTouches(in: window));returnRoleOwns=\(ownsReturn)"
    }

    private func recordQA(phase: String, flight: PageReturnFlight, event: String = "phase", reason: String = "none") {
        guard ProcessInfo.processInfo.arguments.contains("--qa-page-return"), let window = flight.window else { return }
        let label = qaLabel(in: window)
        let rect = flight.qaWindowRect
        let coordinates = String(format: "minY=%.2f;maxY=%.2f;minX=%.2f;maxX=%.2f", rect.minY, rect.maxY, rect.minX, rect.maxX)
        let targetView = flight.destination.viewIfLoaded
        let target: String
        if let targetView {
            let targetRect = targetView.window === window ? targetView.convert(targetView.bounds, to: window) : targetView.frame
            target = String(format: "targetAlpha=%.3f;targetX=%.2f;targetY=%.2f;targetWidth=%.2f;targetHeight=%.2f", targetView.alpha, targetRect.minX, targetRect.minY, targetRect.width, targetRect.height)
        } else {
            target = "targetAlpha=unknown;targetX=unknown;targetY=unknown;targetWidth=unknown;targetHeight=unknown"
        }
        let headerPoint = CGPoint(x: 42, y: rect.minY - 28)
        let headerHit = PageReturnDriver.qaViewPath(from: window.hitTest(headerPoint, with: nil))
        let targetAncestors = PageReturnDriver.qaViewPath(from: targetView)
        let headerCoordinates = String(format: "headerPointX=%.2f;headerPointY=%.2f", headerPoint.x, headerPoint.y)
        let ownsReturn = flight.owner.map { PageEdgeReturnPolicy.ownsReturnGesture(owner: $0) } ?? false
        let targetHidden = targetView.map { String($0.isHidden) } ?? "unknown"
        let targetEnabled = targetView.map { String($0.isUserInteractionEnabled) } ?? "unknown"
        let targetSpace = targetView == nil ? "unloaded" : targetView?.window === window ? "window" : "superview"
        let navigationOutcome = flight.receipt.navigation.map { String(describing: $0) } ?? "pending"
        let visualOutcome = flight.receipt.visual.map { String(describing: $0) } ?? "pending"
        let value = "phase=\(phase);navigationOutcome=\(navigationOutcome);visualOutcome=\(visualOutcome);event=\(event);reason=\(reason);\(coordinates);sourceMasked=\(flight.source.layer.mask != nil);\(target);targetLoaded=\(targetView != nil);targetHidden=\(targetHidden);targetWindow=\(targetView?.window != nil);targetWindowSame=\(targetView?.window === window);targetFrameSpace=\(targetSpace);sourceWindow=\(flight.source.window != nil);hasLease=\(flight.interaction != nil);globalBlocked=\(PageInteractionShield.blocksNewTouches(in: window));targetUIEnabled=\(targetEnabled);sourceUIEnabled=\(flight.source.isUserInteractionEnabled);targetAncestors=\(targetAncestors);\(headerCoordinates);headerHit=\(headerHit);returnRoleOwns=\(ownsReturn);mediaBand=\(flight.preview.capturedMediaBandFrame != nil);mediaBandTop=\(flight.preview.capturedMediaBandFrame?.minY ?? -1);mediaBandHeight=\(flight.preview.capturedMediaBandFrame?.height ?? -1);previewKind=\(flight.preview.kind.rawValue);previewAttached=\(flight.preview.snapshot.superview === flight.parent);previewWindow=\(flight.preview.snapshot.window != nil)"
        var layers: [String] = []
        var view: UIView? = flight.source
        for _ in 0..<7 {
            guard let current = view else { break }
            let layer = current.layer.presentation() ?? current.layer
            layers.append("\(type(of: current)):r\(layer.cornerRadius):clip\(current.clipsToBounds):mask\(layer.mask.map { String(describing: type(of: $0)) } ?? "none"):frame\(current.frame)")
            view = current.superview
        }
        let native = flight.navigation?.interactivePopGestureRecognizer?.state.rawValue ?? -1
        let content: Int
        if #available(iOS 26.0, *) { content = flight.navigation?.interactiveContentPopGestureRecognizer?.state.rawValue ?? -1 }
        else { content = -1 }
        let publishedValue = value + ";nativePop=\(native);nativeContentPop=\(content);nativeInteractive=\(flight.navigation?.transitionCoordinator?.isInteractive == true);corners=\(layers.joined(separator: "|"));sharedHeader=\(flight.headerRoute != nil);footerProtected=\(flight.footerProtected)"
        label.accessibilityValue = publishedValue
        if phase == "dragging" || phase == "tracking" || phase == "awaitingDisappearance" {
            NSLog("RETURN171_GEOMETRY %@", publishedValue)
        }
        guard phase == "completed" || phase == "cancelled" else { return }
        // The delayed sample retains only scalar text and weak references.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak targetView, weak window, weak label] in
            guard let window, let label, label.accessibilityValue == publishedValue else { return }
            let postHit = PageReturnDriver.qaViewPath(from: window.hitTest(headerPoint, with: nil))
            let postAncestors = PageReturnDriver.qaViewPath(from: targetView)
            let postEnabled = targetView.map { String($0.isUserInteractionEnabled) } ?? "deallocated"
            label.accessibilityValue = publishedValue + ";postHit=\(postHit);postGlobalBlocked=\(PageInteractionShield.blocksNewTouches(in: window));postTargetUIEnabled=\(postEnabled);postTargetAncestors=\(postAncestors)"
        }
    }

    private static func qaViewPath(from view: UIView?) -> String {
        guard let view else { return "nil" }
        var ancestor: UIView? = view
        var entries: [String] = []
        while let current = ancestor, entries.count < 16 {
            let fullName = String(describing: type(of: current))
            let className = String((fullName.split(separator: "<").first.map(String.init) ?? fullName).prefix(96))
            let alpha = String(format: "%.3f", current.alpha)
            entries.append("\(className)(enabled:\(current.isUserInteractionEnabled),hidden:\(current.isHidden),alpha:\(alpha),masked:\(current.layer.mask != nil))")
            ancestor = current.superview
        }
        if ancestor != nil { entries.append("truncated") }
        return entries.joined(separator: ">")
    }
    #endif

    @MainActor
    private final class PageReturnFlight {
        enum Phase { case dragging, settling, awaitingDisappearance }
        weak var owner: UIViewController?
        weak var navigation: UINavigationController?
        let source: UIView
        let parent: UIView
        let destination: UIViewController
        let preview: PageReturnPreview
        weak var window: UIWindow?
        let viewportToken: UUID
        let actionToken: UUID?
        let identity: AnyHashable?
        let rect: CGRect
        let sign: CGFloat
        let sourceBounds: CGRect
        let sourceSafeAreaInsets: UIEdgeInsets
        #if DEBUG && targetEnvironment(simulator)
        let qaWindowRect: CGRect
        #endif
        let snapshotFrame: CGRect
        let oldMask: CALayer?
        var assemblyFailure: String?
        var assemblyBoundary: RenderFrameBoundary?
        var assembled = false
        var pendingTranslation: CGFloat = 0
        var pendingSettle: Bool?
        var phase: Phase = .dragging
        var snapshot: UIImageView?
        var mediaHeaderCanvas: UIView?
        var footerSurface: UIView?
        var mask: CAShapeLayer?
        var interaction: PageInteractionShield.Lease?
        #if DEBUG && targetEnvironment(simulator)
        var qaMidRecorded = false
        #endif
        var footerProtected = false
        var headerRoute: UUID?
        var sharedTone: PageToneTransition?
        var nativeHeaderCompletion: ((Bool, @escaping (Bool) -> Void) -> Void)?
        let bodyHandoff = PageBodyHandoff()
        let receipt = PageTransitionReceipt()
        var bodyToken: UUID { receipt.id }
        var navigationReceipt: PageReturnNavigationReceipt?
        var revealBoundary: RenderFrameBoundary?

        init(owner: UIViewController, source: UIView, parent: UIView,
             destination: Destination, viewportToken: UUID, identity: AnyHashable?, rect: CGRect,
             sign: CGFloat, preview: PageReturnPreview) {
            self.owner = owner; self.source = source; self.parent = parent
            self.destination = destination.controller; navigation = destination.navigation
            self.preview = preview
            actionToken = destination.actionToken
            self.identity = identity
            window = source.window
            self.viewportToken = viewportToken; self.rect = rect; self.sign = sign
            sourceBounds = source.bounds; snapshotFrame = source.convert(rect, to: parent)
            sourceSafeAreaInsets = source.safeAreaInsets
            #if DEBUG && targetEnvironment(simulator)
            qaWindowRect = source.window.map { source.convert(rect, to: $0) } ?? .null
            #endif
            oldMask = source.layer.mask
        }

        func restoreMediaHeaderCanvas() {
            guard let band = mediaHeaderCanvas, let frame = preview.capturedMediaBandFrame else { return }
            band.alpha = 1
            band.frame = frame.offsetBy(dx: -preview.frame.minX, dy: -preview.frame.minY)
            preview.snapshot.addSubview(band)
            mediaHeaderCanvas = nil
        }

        func removeVisuals() {
            assemblyBoundary?.cancel(); assemblyBoundary = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Restore the real source before relinquishing either visual copy.
            if let mask, source.layer.mask === mask { source.layer.mask = oldMask }
            mask = nil
            snapshot?.removeFromSuperview(); snapshot = nil
            if mediaHeaderCanvas?.superview === parent { restoreMediaHeaderCanvas() }
            if footerSurface?.superview === window {
                footerSurface?.removeFromSuperview(); footerSurface?.alpha = 1
            }
            // The cached view is already a copy of the destination. Remove only
            // our mounted copy, never the real destination's view or constraints.
            if preview.snapshot.superview === parent { preview.snapshot.removeFromSuperview() }
            CATransaction.commit()
            interaction?.release(); interaction = nil
        }

        func completeNativeHeader(animate: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
            let finish = nativeHeaderCompletion
            nativeHeaderCompletion = nil
            if let finish { finish(animate, completion) }
            else { completion(true) }
        }
    }
}
