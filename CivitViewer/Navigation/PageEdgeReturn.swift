import SwiftUI
import UIKit

/// Reading geometry controls layout and gestures; these pixels cover the whole
/// page, including the area behind floating controls and the system safe areas.
@MainActor struct CapturedPageCanvas {
    let owner: UIViewController
    let pixels: UIView
    let frame: CGRect
    let readingFrame: CGRect
    let header: HeaderContent?
    let footer: PageReturnFooterPreview?
}

@MainActor enum PageCanvasSnapshot {
    #if DEBUG && targetEnvironment(simulator)
    fileprivate static var captureToHoldForQA: UUID?
    #endif

    enum CaptureResult {
        case captured(CapturedPageCanvas)
        case unavailable
        case cancelled
    }

    private static var flights: [ObjectIdentifier: Capture] = [:]

    static func isCapturing(in window: UIWindow) -> Bool { flights[ObjectIdentifier(window)] != nil }

    static func cancelAll() {
        Array(flights.values).forEach { $0.finish(.cancelled) }
    }

    @discardableResult
    static func capture(owner: UIViewController, token: UUID, capturesImmediately: Bool = false,
                        completion: @escaping (CaptureResult) -> Void) -> () -> Void {
        guard let geometry = PageBodyViewports.geometry(containing: owner) ?? PageBodyViewports.capturableGeometry(of: owner),
              geometry.owner === owner, let view = owner.viewIfLoaded, let window = view.window,
              let canvas = geometry.canvasRect, canvas.width > 1, canvas.height > 1,
              window.windowScene?.activationState == .foregroundActive,
              view.layer.mask == nil else { completion(.unavailable); return {} }
        let key = ObjectIdentifier(window)
        let capture = Capture(owner: owner, window: window, token: token, canvas: canvas,
                              reading: geometry.rect, completion: completion)
        let previous = flights[key]
        flights[key] = capture
        previous?.finish(.cancelled)
        // Superseding invokes the previous completion, which may itself start
        // a newer capture. Only the current owner may mutate drawing state.
        if flights[key] === capture { capture.start(immediately: capturesImmediately) }
        return { [weak capture] in capture?.finish(.cancelled) }
    }

    @MainActor private final class Capture {
        weak var owner: UIViewController?
        weak var window: UIWindow?
        let token: UUID
        let controlsToken = UUID()
        let canvas: CGRect
        let bounds: CGRect
        let windowBounds: CGRect
        let windowKey: ObjectIdentifier
        let safeArea: UIEdgeInsets
        let scene: ObjectIdentifier?
        let frame: CGRect
        let readingFrame: CGRect
        var completion: ((CaptureResult) -> Void)?
        var boundary: RenderFrameBoundary?
        var deadline: Task<Void, Never>?

        init(owner: UIViewController, window: UIWindow, token: UUID, canvas: CGRect,
             reading: CGRect, completion: @escaping (CaptureResult) -> Void) {
            self.owner = owner; self.window = window; self.token = token
            self.canvas = canvas
            bounds = owner.view.bounds; windowBounds = window.bounds
            windowKey = ObjectIdentifier(window)
            safeArea = window.safeAreaInsets; scene = window.windowScene.map(ObjectIdentifier.init)
            frame = owner.view.convert(canvas, to: window)
            readingFrame = owner.view.convert(reading, to: window)
            self.completion = completion
        }

        func start(immediately: Bool) {
            #if DEBUG && targetEnvironment(simulator)
            let snapshotStart = TransitionCostQA174.start
            defer { TransitionCostQA174.record("pageCapture.start", snapshotStart) }
            #endif
            guard let view = owner?.viewIfLoaded else { finish(.unavailable); return }
            #if DEBUG && targetEnvironment(simulator)
            if PageCanvasSnapshot.captureToHoldForQA == token {
                PageCanvasSnapshot.captureToHoldForQA = nil
                return  // Keep the registered capture pending until cache invalidation.
            }
            #endif
            if immediately {
                render(view)
                return
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                self?.finish(.unavailable)
            }
            boundary = RenderFrameBoundary { [weak self, weak view] in
                guard let view else { self?.finish(.unavailable); return }
                self?.render(view)
            }
        }

        private func render(_ view: UIView) {
            #if DEBUG && targetEnvironment(simulator)
            let snapshotStart = TransitionCostQA174.start
            defer { TransitionCostQA174.record("pageCapture.frame", snapshotStart) }
            #endif
            guard let owner, let window, canRender(view, for: owner, in: window),
                  (PageBodyViewports.geometry(containing: owner) ?? PageBodyViewports.capturableGeometry(of: owner))?.owner === owner else {
                finish(.unavailable)
                return
            }
            let headerMotion = NativeHeaderMotion.forWindow(window)
            let header = headerMotion.settledContent(for: owner)
            let footer = PageReturnFooterPreview.capture(for: owner, header: header, in: window)
            if canRender(view, for: owner, in: window) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // Keep real chrome active while this request waits for a frame.
                // Suppression only spans the synchronous snapshot and handoff.
                let suppression = PageBodyViewports.suppressFloatingControls(in: owner, token: controlsToken,
                                                                              includePresentationFooter: true)
                defer {
                    suppression.release()
                    CATransaction.commit()
                }
                if canRender(view, for: owner, in: window),
                   let pixels = view.resizableSnapshotView(from: canvas, afterScreenUpdates: true, withCapInsets: .zero),
                   canRender(view, for: owner, in: window) {
                    pixels.isUserInteractionEnabled = false; pixels.accessibilityElementsHidden = true
                    let plane = UIView(frame: CGRect(origin: .zero, size: frame.size))
                    plane.backgroundColor = AppTheme.returnCanvasColor(appearance: header?.appearance
                        ?? headerMotion.appearance(for: owner), in: window)
                    plane.isUserInteractionEnabled = false; plane.accessibilityElementsHidden = true
                    plane.clipsToBounds = true
                    pixels.frame = plane.bounds; plane.addSubview(pixels)
                    // The recipient can mount the body and its fixed controls in
                    // this transaction before the source controls are released.
                    finish(.captured(CapturedPageCanvas(owner: owner, pixels: plane, frame: frame,
                        readingFrame: readingFrame, header: header, footer: footer)))
                    return
                }
            }
            finish(.unavailable)
        }

        private func canRender(_ view: UIView, for owner: UIViewController, in window: UIWindow) -> Bool {
            completion != nil && PageCanvasSnapshot.flights[windowKey] === self
                && owner.viewIfLoaded === view && view.window === window && view.bounds == bounds
                && window.bounds == windowBounds && window.safeAreaInsets == safeArea
                && window.windowScene.map(ObjectIdentifier.init) == scene
                && window.windowScene?.activationState == .foregroundActive
                && view.layer.mask == nil
                && view.convert(canvas, to: window) == frame
        }

        func finish(_ result: CaptureResult) {
            guard let callback = completion else { return }
            completion = nil; boundary?.cancel(); boundary = nil
            deadline?.cancel(); deadline = nil
            if PageCanvasSnapshot.flights[windowKey] === self {
                PageCanvasSnapshot.flights[windowKey] = nil
            }
            callback(result)
        }
    }
}

/// Roles belong to a concrete navigation page, never to its SwiftUI descendants.
/// Each segmented browser removes only its own token when it detaches.
@MainActor
enum PageEdgeReturnPolicy {
    private static var stateKey: UInt8 = 0
    private static var previews: [PageReturnPreview] = []
    fileprivate static private(set) var previewGeneration: UInt64 = 0

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
    static func cacheVisiblePage(owner: UIViewController, identity: AnyHashable?, cause: CaptureCause = .disappearance,
                                 isCurrent: (() -> Bool)? = nil) {
        if cause == .cover, let isCurrent {
            guard isCurrent() else { return }
            // A new explicit entry may now represent a different work in the
            // same retained owner. A failed capture must never revive that
            // owner's previous work; a mounted return plane keeps its lease.
            previews.removeAll { $0.owner === owner && $0.snapshot.superview == nil }
        }
        if cause == .disappearance, existingState(for: owner)?.rootTabDeparture != nil { return }
        previews.removeAll { $0.owner == nil }
        guard let view = owner.viewIfLoaded, let window = view.window,
              view.bounds.width > 1, view.bounds.height > 1, view.layer.mask == nil,
              existingState(for: owner)?.driver.hasActiveFlight != true,
              !PageBodyHandoff.hasActiveFlight(in: window),
              !PageCanvasSnapshot.isCapturing(in: window) else { return }
        if let existing = previews.first(where: { $0.owner === owner }), existing.snapshot.superview != nil { return }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha >= 0.01 else { return }
            ancestor = current.superview
        }
        // Caching the outgoing page is optional and owns no input. Any body
        // transition using the capture has its own interaction policy.
        _ = PageCanvasSnapshot.capture(owner: owner, token: UUID()) { [weak owner, weak window] result in
            guard let owner, let window, case let .captured(canvas) = result, canvas.owner === owner else { return }
            if cause == .cover, let isCurrent {
                guard isCurrent() else { return }
            } else {
                guard existingState(for: owner)?.viewports.contains(where: { $0.probe?.identity == identity }) == true else { return }
            }
            cachePreparedCanvas(canvas, identity: identity, window: window)
        }
    }

    static func cachePreparedCanvas(_ canvas: CapturedPageCanvas, identity: AnyHashable?, window originalWindow: UIWindow? = nil) {
        guard let window = originalWindow ?? canvas.owner.viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive,
              canvas.frame.width > 1, canvas.frame.height > 1 else { return }
        let key = ObjectIdentifier(canvas.owner)
        previews.removeAll { $0.owner == nil || $0.key == key }
        if previews.count >= 3 { previews.removeFirst() }
        let shift = abs(canvas.frame.width - window.bounds.width) <= 2
            ? window.bounds.minX - canvas.frame.minX : 0
        let stored = CapturedPageCanvas(owner: canvas.owner, pixels: canvas.pixels,
            frame: canvas.frame.offsetBy(dx: shift, dy: 0), readingFrame: canvas.readingFrame.offsetBy(dx: shift, dy: 0),
            header: canvas.header, footer: canvas.footer)
        previews.append(PageReturnPreview(owner: canvas.owner, snapshot: canvas.pixels,
            window: window, frame: stored.frame, identity: identity, canvas: stored))
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
            } else if let roots = controller as? RootTabHostController {
                // Retained inactive tabs are descendants too. Only the
                // currently selected slot can supply this return preview.
                children = roots.children.filter { roots.owns($0, tab: roots.selected) }
            } else { children = Array(controller.children.reversed()) }
            for child in children {
                guard let container, let childView = child.viewIfLoaded,
                      childView.isDescendant(of: container) else { continue }
                if let found = cached(in: child) { return found }
            }
            return nil
        }
        if let entry = cached(in: owner) { return entry }
        // A cold return has an explicit neutral canvas. Do not enqueue a
        // target capture and then cancel it with the source capture in this
        // same window; nor reuse pixels with missing account/layout provenance.
        let geometry = PageBodyViewports.geometry(containing: owner)
            ?? PageBodyViewports.capturableGeometry(of: owner)
        let paletteOwner = geometry?.owner ?? owner
        let appearance = NativeHeaderMotion.forWindow(window).appearance(for: paletteOwner)
        let surface = UIView(frame: window.bounds)
        surface.backgroundColor = AppTheme.returnCanvasColor(appearance: appearance, in: window)
        surface.isUserInteractionEnabled = false
        surface.accessibilityElementsHidden = true
        return PageReturnPreview(owner: paletteOwner, snapshot: surface, window: window, frame: window.bounds,
                                 identity: identity, kind: .surface)
    }

    static func invalidatePreviewCache() {
        previewGeneration &+= 1
        PageCanvasSnapshot.cancelAll()
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
    let endpoint: RootFooterEndpoint?

    init(controls: UIImage, frame: CGRect, endpoint: RootFooterEndpoint? = nil) {
        self.endpoint = endpoint
        self.frame = frame; self.canvasFrame = frame
        let surface = UIView(frame: frame)
        surface.backgroundColor = .clear
        surface.isUserInteractionEnabled = false; surface.accessibilityElementsHidden = true
        let ink = UIImageView(image: controls)
        ink.frame = CGRect(origin: .zero, size: frame.size)
        ink.isUserInteractionEnabled = false; ink.accessibilityElementsHidden = true
        surface.addSubview(ink)
        self.surface = surface
    }

    init(controls: UIView, frame: CGRect, endpoint: RootFooterEndpoint? = nil) {
        self.endpoint = endpoint
        self.frame = frame; canvasFrame = frame
        surface = controls; surface.frame = frame
        surface.backgroundColor = .clear
        surface.isUserInteractionEnabled = false; surface.accessibilityElementsHidden = true
    }

    static func capture(for owner: UIViewController, header: HeaderContent?, in window: UIWindow) -> Self? {
        if let drawable = PageBodyViewports.floatingControlViews(in: owner, kind: .footer, includePresentationFooter: true).first,
           let pixels = drawable.snapshotView(afterScreenUpdates: false) {
            return Self(controls: pixels, frame: drawable.convert(drawable.bounds, to: window))
        }
        guard let appearance = header?.appearance, let page = owner.viewIfLoaded,
              PageBodyViewports.fixedBottomBarIsOutside(page),
              let frame = PageBodyViewports.fixedBottomBarFrame(in: window),
              let motion = appearance.environment?.tabPageMotion, let selected = motion.rootHost?.selected,
              let controls = motion.rootFooterRenderer?(selected, appearance.canvasRole == .playback) else { return nil }
        let endpoint = PageBodyViewports.rootFooterEndpoint(in: window).map {
            RootFooterEndpoint(selectedTab: $0.selectedTab, overMedia: appearance.canvasRole == .playback,
                               selectionOwner: $0.selectionOwner, frame: frame)
        }
        return Self(controls: controls, frame: frame, endpoint: endpoint)
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
    private let capturedReadingFrame: CGRect?
    let capturedMediaBandFrame: CGRect?
    let capturedMediaBandView: UIView?
    let capturedMediaCanvasFrame: CGRect?
    private weak var capturedMediaBodyOwner: UIViewController?
    let footer: PageReturnFooterPreview?
    private let logicalScheme: ColorScheme?
    private let logicalRole: PageCanvasRole?
    private let ownerStyle: UIUserInterfaceStyle
    private let windowStyle: UIUserInterfaceStyle
    private let ownerContentSize: UIContentSizeCategory
    private let windowContentSize: UIContentSizeCategory

    var canvasRole: PageCanvasRole? { logicalRole }

    var canvas: CapturedPageCanvas? {
        guard kind != .surface, let owner, let readingFrame = capturedReadingFrame else { return nil }
        return CapturedPageCanvas(owner: owner, pixels: snapshot, frame: frame,
                                  readingFrame: readingFrame, header: header, footer: footer)
    }

    init(owner: UIViewController, snapshot: UIView, window: UIWindow, frame: CGRect,
         identity: AnyHashable?, kind: Kind = .cached, canvas: CapturedPageCanvas? = nil) {
        key = ObjectIdentifier(owner)
        self.owner = owner; self.window = window
        windowBounds = window.bounds; self.frame = frame
        self.identity = identity
        self.kind = kind
        let content = canvas?.header ?? NativeHeaderMotion.forWindow(window).settledContent(for: owner)
        let appearance = content?.appearance
        // Only explicit controls enter the header copy. No rectangle from the
        // composited page, status area, or media background is used as chrome.
        if let content, let canonical = HeaderHandoff.renderControls(content) {
            let original = content.appearance
            var environment = EnvironmentValues()
            environment.displayScale = canonical.scale
            let pixels = HeaderAppearance(controls: AnyView(Image(uiImage: canonical).resizable()
                    .frame(width: content.frame.width, height: content.frame.height)),
                firstRowHeight: original.firstRowHeight, colorScheme: original.colorScheme,
                surfaceColor: original.surfaceColor, borderColor: original.borderColor,
                surfaceHeight: original.surfaceHeight, environment: environment,
                layoutIdentity: original.layoutIdentity, canvasRole: original.canvasRole,
                contentClearance: original.contentClearance, retainsViewport: original.retainsViewport,
                contentOwner: original.contentOwner,
                frozenRaster: FrozenHeaderRaster(image: canonical, frameSize: content.frame.size,
                    displayScale: canonical.scale, canvasRole: original.canvasRole,
                    isCompositedHeaderSnapshot: false))
            header = HeaderContent(frame: content.frame, appearance: pixels)
        } else { header = nil }
        footer = canvas?.footer
        logicalScheme = appearance?.colorScheme; logicalRole = appearance?.canvasRole
        ownerStyle = owner.traitCollection.userInterfaceStyle == .unspecified
            ? window.traitCollection.userInterfaceStyle : owner.traitCollection.userInterfaceStyle
        windowStyle = window.traitCollection.userInterfaceStyle
        ownerContentSize = owner.traitCollection.preferredContentSizeCategory
        windowContentSize = window.traitCollection.preferredContentSizeCategory
        hasExactHeaderPixels = false
        capturedMediaBandFrame = nil; capturedMediaBandView = nil
        capturedBodyFrame = canvas?.frame
        capturedReadingFrame = canvas?.readingFrame
        capturedMediaCanvasFrame = canvas?.frame
        capturedMediaBodyOwner = canvas?.owner
        snapshot.layer.mask = nil
        self.snapshot = snapshot
    }

    func matchesMediaCanvas(of scope: UIViewController, window: UIWindow) -> Bool {
        guard let expected = capturedMediaCanvasFrame else { return true }
        guard let capturedOwner = owner, let canvas = capturedOwner.viewIfLoaded,
              let scopeView = scope.viewIfLoaded else { return false }
        // A cover returns to a container scope; its cached pixels can belong
        // to the active navigation page inside it. Validate that exact page,
        // never compare the outer container's frame to the inner canvas.
        var controller: UIViewController? = capturedOwner
        var contained = false
        var active = true
        while let current = controller {
            if let root = current as? RootTabHostController,
               !root.owns(capturedOwner, tab: root.selected) { active = false }
            if current === scope { contained = true; break }
            if let navigation = current.parent as? UINavigationController,
               navigation.topViewController !== current { active = false }
            if let tabs = current.parent as? UITabBarController,
               tabs.selectedViewController !== current { active = false }
            controller = current.parent
        }
        let descendant = canvas === scopeView || canvas.isDescendant(of: scopeView)
        var visible = true
        var ancestor: UIView? = canvas
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.01 { visible = false }
            if view === window { break }
            ancestor = view.superview
        }
        let sameWindow = canvas.window === window && scopeView.window === window && window.bounds == windowBounds
        let body = PageBodyViewports.geometry(containing: capturedOwner)?.owner
        let sameBody = capturedMediaBodyOwner != nil && body === capturedMediaBodyOwner
        let current = canvas.convert(canvas.bounds, to: window)
        let sameFrame = abs(current.minX - expected.minX) <= 2 && abs(current.minY - expected.minY) <= 2 &&
            abs(current.width - expected.width) <= 2 && abs(current.height - expected.height) <= 2
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
            NSLog("RETURN175_CANVAS oldEqual=%d;contained=%d;descendant=%d;active=%d;visible=%d;window=%d;body=%d;frame=%d;expected=%@;current=%@;scope=%@",
                  scope === capturedOwner ? 1 : 0, contained ? 1 : 0, descendant ? 1 : 0,
                  active ? 1 : 0, visible ? 1 : 0, sameWindow ? 1 : 0, sameBody ? 1 : 0, sameFrame ? 1 : 0,
                  String(describing: expected), String(describing: current), String(describing: scopeView.convert(scopeView.bounds, to: window)))
        }
        #endif
        return contained && descendant && active && visible && sameWindow && sameBody && sameFrame
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

extension EnvironmentValues {
    @Entry var pageMayRetryEdgeClose: (() -> Bool)? = nil
}

extension View {
    /// Apply to the content inside FloatingPageBar, before its header/footer insets.
    func pageReturnViewport(topInset: CGFloat, bottomInset: CGFloat, identity: AnyHashable? = nil,
                            canvasRole: PageCanvasRole, colorScheme: ColorScheme,
                            nativeReturnGate: PageNativeReturnGate,
                            onReturn: @escaping () -> Void) -> some View {
        background {
            PageReturnMarker(kind: .viewport, action: nil, identity: identity,
                             topInset: topInset, bottomInset: bottomInset,
                             canvasStyle: .init(role: canvasRole, scheme: colorScheme),
                             nativeReturnGate: nativeReturnGate, onReturn: onReturn)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// Explicit close for this modal root only. Existing finish/save guards remain
    /// in the supplied action; return false to reject and rebound the preview.
    /// This modifier never dismisses a UIKit controller.
    func pageReturnAction(enabled: Bool = true, action: @escaping () -> Bool) -> some View {
        background {
            PageReturnMarker(kind: .action, action: enabled ? action : nil, identity: nil,
                             topInset: 0, bottomInset: 0, canvasStyle: nil, nativeReturnGate: nil, onReturn: nil)
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

private struct PageReturnCanvasStyle: Equatable {
    let role: PageCanvasRole
    let scheme: ColorScheme
}

private struct PageReturnMarker: UIViewControllerRepresentable {
    enum Kind { case viewport, action }
    let kind: Kind
    let action: (() -> Bool)?
    let identity: AnyHashable?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let canvasStyle: PageReturnCanvasStyle?
    let nativeReturnGate: PageNativeReturnGate?
    let onReturn: (() -> Void)?
    @Environment(\.pageReturnNavigationReceipt) private var navigationReceipt
    @Environment(\.pageMayRetryEdgeClose) private var mayRetryEdgeClose

    func makeUIViewController(context: Context) -> PageReturnProbe {
        let probe = PageReturnProbe(kind: kind)
        probe.closeAction = action
        probe.identity = identity
        probe.topInset = topInset
        probe.bottomInset = bottomInset
        probe.canvasStyle = canvasStyle
        probe.nativeReturnGate = nativeReturnGate
        probe.returnAction = onReturn
        probe.navigationReceipt = navigationReceipt
        probe.mayRetryEdgeClose = mayRetryEdgeClose
        return probe
    }

    func updateUIViewController(_ probe: PageReturnProbe, context: Context) {
        if probe.identity != identity { probe.invalidateIdentity() }
        if probe.topInset != topInset || probe.bottomInset != bottomInset || probe.canvasStyle != canvasStyle {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
                NSLog("RETURN192_VIEWPORT_CHANGED top=%g/%g bottom=%g/%g paletteChanged=%d",
                      Double(probe.topInset), Double(topInset), Double(probe.bottomInset), Double(bottomInset),
                      probe.canvasStyle != canvasStyle ? 1 : 0)
            }
            #endif
            probe.invalidateViewport()
        }
        if probe.navigationReceipt !== navigationReceipt {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
                NSLog("RETURN192_VIEWPORT_CHANGED receiptChanged=1")
            }
            #endif
            probe.invalidateViewport()
        }
        probe.identity = identity
        probe.topInset = topInset
        probe.bottomInset = bottomInset
        probe.canvasStyle = canvasStyle
        probe.closeAction = action
        probe.nativeReturnGate = nativeReturnGate
        probe.returnAction = onReturn
        probe.navigationReceipt = navigationReceipt
        probe.mayRetryEdgeClose = mayRetryEdgeClose
        probe.attach()
    }

    static func dismantleUIViewController(_ probe: PageReturnProbe, coordinator: ()) {
        probe.detach()
        probe.closeAction = nil
        probe.returnAction = nil
        probe.mayRetryEdgeClose = nil
    }
}

@MainActor
private final class PageReturnProbe: UIViewController {
    let token = UUID()
    let kind: PageReturnMarker.Kind
    var closeAction: (() -> Bool)?
    var returnAction: (() -> Void)?
    var nativeReturnGate: PageNativeReturnGate?
    var navigationReceipt: PageReturnNavigationReceipt?
    var mayRetryEdgeClose: (() -> Bool)?
    var identity: AnyHashable?
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var canvasStyle: PageReturnCanvasStyle?
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
        if let owner = registeredOwner {
            PageEdgeReturnPolicy.clearRootTabDeparture(owner: owner)
        }
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
        if let gate = nativeReturnGate, let token = gate.receipt?.id { gate.release(token) }
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
    private lazy var pan: PageMotionPanGestureRecognizer = {
        let recognizer = PageMotionPanGestureRecognizer(target: self, action: #selector(panned))
        recognizer.onReset = { [weak self] in self?.panDidReset() }
        recognizer.onTouchSequenceFinished = { [weak self] in self?.touchSequenceDidFinish() }
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
    private var nativeReturnGate: PageNativeReturnGate?
    private weak var nativeReturnNavigation: UINavigationController?
    #if DEBUG && targetEnvironment(simulator)
    private enum PanFault {
        case dropTerminal, dropTerminalAndReset, dropTerminalResetAndTouchEnd, staleTouchSequence
    }
    private static let panFaultForQA: PanFault? = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--qa-stale-edge-pan-touch") { return .staleTouchSequence }
        if arguments.contains("--qa-drop-edge-return-pan-terminal-reset-and-touch-end") { return .dropTerminalResetAndTouchEnd }
        if arguments.contains("--qa-drop-edge-return-pan-terminal-and-reset") { return .dropTerminalAndReset }
        if arguments.contains("--qa-drop-edge-return-pan-terminal") { return .dropTerminal }
        return nil
    }()
    private static var qaKey: UInt8 = 0
    private static var lateCaptureQAKey: UInt8 = 0
    private static var heldCaptureForQA = false
    private var droppedReturnActionForQA = false
    private var droppedAssemblyEntryForQA = false
    // Reopening an author creates a new driver within the same test run.
    private static var injectedPanFaultForQA = false
    private var droppedSettlementCompletionForQA = false
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
            cancelImmediately(reason: "return-driver-released")
            host?.removeGestureRecognizer(pan)
        }
    }

    var hasActiveFlight: Bool { flight != nil }

    var isAvailable: Bool {
        guard let state, state.segmentedTokens.isEmpty, let owner = state.owner,
              let viewport = state.viewport, viewport.viewIfLoaded?.window != nil,
              isCurrent(owner), viewportRect(viewport, in: owner) != nil else { return false }
        if let navigation = owner.navigationController,
           let index = navigation.viewControllers.firstIndex(where: { $0 === owner }), index > 0 {
            return nativeReturnGate?.blocksBack != true && viewport.nativeReturnGate?.blocksBack != true
        }
        return state.close != nil && state.viewport?.navigationReceipt != nil && presentingBoundary(of: owner) != nil
    }

    func refresh() {
        guard let state, let owner = state.owner, let page = owner.viewIfLoaded,
              state.viewport != nil else {
            if flight?.lifecycle.isReturning != true { cancelImmediately(reason: "refresh-no-viewport") }
            host?.removeGestureRecognizer(pan)
            host = nil
            return
        }
        if host !== page {
            if flight?.lifecycle.isReturning != true { cancelImmediately(reason: "refresh-owner-view") }
            host?.removeGestureRecognizer(pan)
            host = page
            page.addGestureRecognizer(pan)
        }
        if let flight, !flight.lifecycle.isReturning {
            if !geometryMatches(flight) { cancelImmediately(reason: "refresh-geometry") }
            else if !isCurrent(owner) { cancelImmediately(reason: "refresh-owner-not-current") }
            else if !state.segmentedTokens.isEmpty { cancelImmediately(reason: "refresh-segmented") }
        }
        // Keep a held/settling pan alive; eligibility is always rechecked at
        // touch time, during movement, and again immediately before committing.
        pan.isEnabled = state.viewport != nil
    }

    func policyDidChange() {
        if state?.segmentedTokens.isEmpty == false, flight?.lifecycle.isReturning != true { cancelImmediately() }
        refresh()
    }

    func sourceRemoved(_ token: UUID, disappeared _: Bool) {
        guard let flight, token == flight.viewportToken || token == flight.actionToken else { return }
        if flight.lifecycle.isReturning {
            // Probe removal is not a navigation receipt. The exact native-pop
            // observer or presentation session will report the platform outcome.
            return
        } else {
            cancel(flight, reason: "source-removed")
        }
    }

    func invalidateLayout() {
        cancelImmediately(reason: "return-layout-invalidated")
    }

    func identityDidChange() { cancelImmediately(reason: "identity-changed") }

    func observeNativePop(from owner: UIViewController) -> PageNativePopReceiptObserver? {
        guard state?.owner === owner, let gate = nativeReturnGate,
              let receipt = gate.receipt, let navigation = nativeReturnNavigation else { return nil }
        return PageNativePopReceiptObserver(owner: owner, navigation: navigation) { [weak self, weak gate] outcome in
            gate?.release(receipt.id)
            if let self, let flight = self.flight, flight.receipt === receipt {
                self.receiveNavigation(outcome, flight: flight)
            } else {
                receipt.recordNavigation(outcome, token: receipt.id)
            }
        }
    }

    private func receiveNavigation(_ outcome: PageNavigationOutcome, flight: PageReturnFlight) {
        guard flight.receipt.recordNavigation(outcome, token: flight.bodyToken) else { return }
        // A real platform receipt can arrive after the matching visual ended.
        guard self.flight === flight, case .awaitingNavigation = flight.lifecycle else { return }
        flight.stopNavigationDeadline()
        if outcome == .committed { finishCommitted(flight) }
        else { cancel(flight, reason: outcome == .cancelled ? "cancel" : "platform-return-not-committed") }
    }

    @objc private func becameInactive(_ notification: Notification) {
        if let scene = notification.object as? UIScene,
           scene !== (flight?.window?.windowScene ?? host?.window?.windowScene) { return }
        cancelImmediately(reason: "return-scene-inactive")
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
        guard let flight, flight.lifecycle.tracksPan else { return }
        guard validForCommit(flight) else { cancel(flight); return }
        #if DEBUG && targetEnvironment(simulator)
        if flight.panFaultForQA != nil, [.ended, .cancelled, .failed].contains(pan.state) {
            recordQA(phase: "dragging", flight: flight, event: "pan-terminal-dropped")
            return
        }
        #endif
        let translation = pan.translation(in: flight.parent).x
        switch pan.state {
        case .began, .changed:
            move(flight, translation: translation)
        case .ended:
            move(flight, translation: translation)
            let distance = max(0, translation * flight.sign)
            let velocity = pan.velocity(in: flight.parent).x * flight.sign
            settleGesture(flight, commit: distance >= 45 || (distance >= 12 && velocity >= 450))
        case .cancelled, .failed:
            settleGesture(flight, commit: false)
        default: break
        }
    }

    private var panIsTracking: Bool { pan.state == .began || pan.state == .changed }

    private func panDidReset() {
        guard let flight, flight.lifecycle.tracksPan else { return }
        #if DEBUG && targetEnvironment(simulator)
        if let fault = flight.panFaultForQA, fault != .dropTerminal { return }
        #endif
        // A reset can arrive during a UIKit hierarchy update. Finish any
        // terminal action on the current call stack before checking ownership.
        recoverAbandonedDrag(flight, reason: "return-pan-reset")
    }

    private func touchSequenceDidFinish() {
        guard let flight, flight.lifecycle.tracksPan else { return }
        #if DEBUG && targetEnvironment(simulator)
        guard flight.panFaultForQA != .dropTerminal else { return }
        flight.touchWatchRecoveredForQA = pan.touchWatchRecoveredForQA
        #endif
        recoverAbandonedDrag(flight, reason: "return-touch-ended")
    }

    private func recoverAbandonedDrag(_ flight: PageReturnFlight, reason: String) {
        Task { @MainActor [weak self, weak flight] in
            guard let self, let flight, self.flight === flight,
                  flight.lifecycle.tracksPan else { return }
            if reason == "return-touch-ended" {
                NavigationDiagnostics.mark(.touchTrackingRecovered, owner: .edgeReturn)
            }
            self.cancel(flight, reason: reason)
        }
    }

    private func independentTouchBegan(whileHolding flight: PageReturnFlight) {
        guard self.flight === flight, !flight.lifecycle.hasEnded else { return }
        // A posted native action keeps its own receipt even if its visual
        // handoff yields. Never replay a pop while releasing the old visuals.
        let reason = flight.lifecycle.isReturning ? "return-visual-superseded" : "return-abandoned-on-new-touch"
        cancel(flight, reason: reason)
        if self.flight == nil, pan.isEnabled {
            pan.isEnabled = false
            pan.isEnabled = true
        }
    }

    private func begin(owner: UIViewController, probe: PageReturnProbe, rect: CGRect) -> Bool {
        let resetGeneration = pan.resetGeneration
        #if DEBUG && targetEnvironment(simulator)
        let cost175 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("edgeBegin175", cost175) }
        #endif
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
        let generation = PageEdgeReturnPolicy.previewGeneration
        let identity = probe.identity
        let preview = PageEdgeReturnPolicy.preview(for: destination.controller, in: window,
                                                   identity: identity, excluding: source)
        guard preview.snapshot.superview == nil else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "begin-preview-not-ready")
            #endif
            return false
        }

        // The gesture aperture stays a reading/interaction rule. Capture the
        // complete canvas only after its explicit controls have been gated.
        let sourceControls = UIView(frame: window.bounds)
        sourceControls.backgroundColor = .clear; sourceControls.isUserInteractionEnabled = false
        sourceControls.accessibilityElementsHidden = true
        var headerCopies: [UIView] = []
        for control in PageBodyViewports.floatingControlViews(in: owner) {
            guard let copy = control.snapshotView(afterScreenUpdates: false) else { return false }
            copy.frame = control.convert(control.bounds, to: window)
            copy.isUserInteractionEnabled = false; copy.accessibilityElementsHidden = true
            if PageBodyViewports.floatingControlViews(in: owner, kind: .header).contains(where: { $0 === control }) {
                headerCopies.append(copy)
            } else { sourceControls.addSubview(copy) }
        }

        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-reset-edge-before-assembly") {
            pan.simulateResetNotificationForQA()
        }
        #endif
        // Snapshot setup can reenter UIKit before a flight owns the gesture.
        guard self.flight == nil, panIsTracking, pan.resetGeneration == resetGeneration,
              generation == PageEdgeReturnPolicy.previewGeneration, probe.identity == identity,
              state.viewport === probe else {
            #if DEBUG && targetEnvironment(simulator)
            recordGuardQA(reason: "begin-pan-reset")
            #endif
            return false
        }
        let flight = PageReturnFlight(owner: owner, source: source, parent: parent,
                                      destination: destination, viewportToken: probe.token,
                                      identity: identity, rect: rect, sign: sign, preview: preview,
                                      generation: generation, canvasStyle: probe.canvasStyle)
        #if DEBUG && targetEnvironment(simulator)
        // The raw callback can arrive before the target action. Select the
        // fault before UIKit can reenter with either callback.
        if !Self.injectedPanFaultForQA, let fault = Self.panFaultForQA {
            flight.panFaultForQA = fault
            pan.dropTouchTerminalForQA = fault == .dropTerminalResetAndTouchEnd || fault == .staleTouchSequence
            pan.keepTouchAliveForQA = fault == .staleTouchSequence
        }
        if !Self.heldCaptureForQA, flight.navigation != nil,
           ProcessInfo.processInfo.arguments.contains("--qa-hold-edge-return-assembly-for-independent-input") {
            Self.heldCaptureForQA = true
            flight.holdsCaptureForQA = true
        }
        let assemblyTimeout: Duration = flight.holdsCaptureForQA ? .seconds(9) : .milliseconds(1100)
        #else
        let assemblyTimeout: Duration = .milliseconds(1100)
        #endif
        self.flight = flight
        NavigationDiagnostics.mark(.edgeStarted)
        func stillCurrent() -> Bool {
            let panIsCurrent = panIsTracking && pan.resetGeneration == resetGeneration
            return validForCommit(flight) && (panIsCurrent || flight.lifecycle.waitsForCanvasCommit)
        }
        let observer = PageReturnTouchObserver(frame: window.bounds)
        observer.onNewTouch = { [weak self, weak flight] in
            guard let flight else { return }
            self?.independentTouchBegan(whileHolding: flight)
        }
        observer.controlsAreCurrent = { [weak self, weak flight, weak owner] in
            guard let self, let flight, let owner, self.flight === flight,
                  !flight.lifecycle.hasEnded, flight.receipt.navigation == nil else { return false }
            return self.isCurrent(owner)
        }
        flight.touchObserver = observer
        observer.install(in: window)
        observer.trackControls(of: owner)
        guard stillCurrent() else {
            cancel(flight, reason: "assembly-owner-changed")
            return false
        }
        // Own this deadline at the flight level. Capture can be invalidated
        // before it gets far enough to install its own deadline.
        flight.assemblyDeadline = Task { @MainActor [weak self, weak flight] in
            do { try await Task.sleep(for: assemblyTimeout) } catch { return }
            guard let self, let flight, self.flight === flight, flight.lifecycle.isAssembling else { return }
            if flight.lifecycle.waitsForCanvasCommit {
                self.commitWithoutCanvas(flight, reason: "return-assembly-timeout")
            } else {
                self.cancel(flight, reason: "return-assembly-timeout")
            }
        }
        flight.sourceHeaderCopies = headerCopies
        for copy in headerCopies {
            sourceControls.addSubview(copy)
        }
        #if DEBUG && targetEnvironment(simulator)
        if !droppedAssemblyEntryForQA,
           ProcessInfo.processInfo.arguments.contains("--qa-drop-return-assembly-entry") {
            droppedAssemblyEntryForQA = true
        } else if ProcessInfo.processInfo.arguments.contains("--qa-return-assembly-delay181") {
            flight.assemblyDelayTask = Task { @MainActor [weak self, weak flight] in
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                guard let self, let flight, self.flight === flight, flight.lifecycle.isAssembling else { return }
                self.captureSourceCanvas(flight, sourceControls: sourceControls)
            }
        } else if flight.holdsCaptureForQA || ProcessInfo.processInfo.arguments.contains("--qa-invalidate-accepted-return-capture")
            || ProcessInfo.processInfo.arguments.contains("--qa-require-return-source-capture") {
            captureSourceCanvas(flight, sourceControls: sourceControls)
        } else {
            prepareLiveSourceOrCapture(flight, owner: owner, window: window, sourceControls: sourceControls)
        }
        #else
        prepareLiveSourceOrCapture(flight, owner: owner, window: window, sourceControls: sourceControls)
        #endif
        guard self.flight === flight else { return false }
        guard flight.lifecycle.tracksPan else { return false }
        guard stillCurrent() else { cancel(flight, reason: "assembly-begin-finished"); return false }
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "dragging", flight: flight)
        if flight.panFaultForQA != nil { Self.injectedPanFaultForQA = true }
        #endif
        pan.watchTouchSequence()
        return true
    }

    private func installHeaderCompletion(_ flight: PageReturnFlight, motion: NativeHeaderMotion, route: UUID) {
        flight.nativeHeaderCompletion = { [weak self, weak motion, weak flight] animate, completion in
            guard let motion else { completion(false); return }
            motion.completeRoute(route, animate: animate, prepareBody: {
                guard let self, let flight, self.flight === flight,
                      case .revealing = flight.lifecycle else { return false }
                let prepared = flight.bodyHandoff.startReturnTone(flight.bodyToken, destination: flight.destination)
                if prepared { motion.markPreparedCanvas(routeID: route) }
                return prepared
            }, completion: completion)
        }
    }

    private func prepareLiveSourceOrCapture(_ flight: PageReturnFlight, owner: UIViewController,
                                            window: UIWindow, sourceControls: UIView) {
        let destinationOwner = flight.preview.owner ?? flight.destination
        let destinationRole = PageEdgeReturnPolicy.existingState(for: destinationOwner)?.viewport?.canvasStyle?.role
            ?? flight.preview.canvasRole
        // Playback handoff composes its captured body and controls across
        // the complete window. Live transforms belong to ordinary pairs.
        if flight.navigation != nil, destinationRole == .ordinary,
           let style = flight.canvasStyle, style.role == .ordinary,
           assembleLiveSource(flight, owner: owner, window: window,
                              scheme: style.scheme, sourceControls: sourceControls) {
            return
        }
        captureSourceCanvas(flight, sourceControls: sourceControls)
    }

    private func captureSourceCanvas(_ flight: PageReturnFlight, sourceControls: UIView) {
        guard self.flight === flight, flight.lifecycle.isAssembling else { return }
        guard let owner = flight.owner, validForCommit(flight) else {
            cancel(flight, reason: "source-canvas-invalid-before-capture")
            return
        }
        flight.assemblyDelayTask = nil
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-forbid-return-source-capture") {
            cancel(flight, reason: "unexpected-return-source-capture")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-invalidate-accepted-return-capture") {
            PageCanvasSnapshot.captureToHoldForQA = flight.bodyToken
        }
        #endif
        let capturesImmediately = flight.navigation != nil && flight.canvasStyle?.role == .ordinary
        var delivered = false
        let cancelCapture = PageCanvasSnapshot.capture(owner: owner, token: flight.bodyToken,
            capturesImmediately: capturesImmediately) { [weak self, weak flight] result in
            delivered = true
            guard let self, let flight else { return }
            #if DEBUG && targetEnvironment(simulator)
            if flight.holdsCaptureForQA, self.flight === flight, flight.lifecycle.isAssembling {
                flight.heldCaptureForQA = { driver, flight in
                    driver.receiveSourceCanvas(result, for: flight, sourceControls: sourceControls)
                }
                return
            }
            #endif
            self.receiveSourceCanvas(result, for: flight, sourceControls: sourceControls)
        }
        if !delivered {
            if self.flight === flight, flight.lifecycle.isAssembling { flight.sourceCanvasCaptureCancel = cancelCapture }
            else { cancelCapture() }
        }
    }

    private func receiveSourceCanvas(_ result: PageCanvasSnapshot.CaptureResult, for flight: PageReturnFlight,
                                     sourceControls: UIView) {
        guard self.flight === flight, flight.lifecycle.isAssembling else {
            #if DEBUG && targetEnvironment(simulator)
            if flight.holdsCaptureForQA { recordLateCaptureQA(result, flight: flight) }
            #endif
            return
        }
        flight.sourceCanvasCaptureCancel = nil
        guard let owner = flight.owner, let window = flight.window, validForCommit(flight) else {
            cancel(flight, reason: "source-canvas-invalid-after-capture")
            return
        }
        if case .cancelled = result {
            cancel(flight, reason: "source-capture-cancelled")
            return
        }
        guard case let .captured(canvas) = result, canvas.owner === owner else {
            sourceCaptureUnavailable(flight)
            return
        }
        let source = flight.source
        let parent = flight.parent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let imageView = canvas.pixels
        imageView.frame = parent.convert(canvas.frame, from: window)
        imageView.transform = .identity
        flight.snapshot = imageView
        parent.insertSubview(imageView, aboveSubview: source)
        guard self.flight === flight, flight.lifecycle.isAssembling else { return }
        let mask = CAShapeLayer()
        mask.frame = source.bounds
        mask.fillRule = .evenOdd
        let path = UIBezierPath(rect: source.bounds)
        path.append(UIBezierPath(rect: source.convert(canvas.frame, from: window)))
        mask.path = path.cgPath
        flight.mask = mask
        source.layer.mask = mask
        installReturnPlanes(flight, in: window, sourceControls: sourceControls)
        finishAssembly(flight)
    }

    private func assembleLiveSource(_ flight: PageReturnFlight, owner: UIViewController, window: UIWindow,
                                    scheme: ColorScheme, sourceControls: UIView) -> Bool {
        let source = flight.source
        guard source.transform == .identity, source.layer.mask == nil, validForCommit(flight) else { return false }
        NavigationDiagnostics.mark(.edgeLiveSourceEntered, owner: .edgeReturn)
        // Keep the actual page body moving beneath its fixed controls. The
        // source is already on-screen and needs no snapshot or render fence.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let suppression = PageBodyViewports.suppressFloatingControls(in: owner, token: flight.bodyToken)
        guard validForCommit(flight), source.transform == .identity, source.layer.mask == nil else {
            suppression.release()
            CATransaction.commit()
            return false
        }
        flight.liveControlSuppression = suppression
        flight.liveSourceOffset = 0
        let backdrop = UIView(frame: source.convert(source.bounds, to: flight.parent))
        backdrop.backgroundColor = UIColor.systemBackground.resolvedColor(with:
            UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        flight.liveSourceBackdrop = backdrop
        // The backdrop travels with the source and keeps the target preview
        // from showing through any transparent margins of the source page.
        flight.parent.insertSubview(backdrop, belowSubview: source)
        installReturnPlanes(flight, in: window, sourceControls: sourceControls, below: backdrop)
        CATransaction.commit()
        finishAssembly(flight)
        return true
    }

    private func installReturnPlanes(_ flight: PageReturnFlight, in window: UIWindow,
                                     sourceControls: UIView, below: UIView? = nil) {
        guard self.flight === flight, flight.lifecycle.isAssembling else { return }
        let preview = flight.preview
        guard let owner = flight.owner else { cancel(flight, reason: "assembly-source-lost"); return }
        let motion = NativeHeaderMotion.forWindow(window)
        let route = UUID()
        if let tone = motion.beginBodyReturn(from: owner, to: preview.owner ?? flight.destination, id: route,
                                              cachedTarget: preview.kind != .surface ? preview.header : nil) {
            guard self.flight === flight, flight.lifecycle.isAssembling else {
                motion.completeRoute(route, animate: false)
                return
            }
            flight.headerRoute = route
            flight.sharedTone = tone
            flight.sourceHeaderCopies.forEach { $0.alpha = 0 }
            installHeaderCompletion(flight, motion: motion, route: route)
        }
        guard self.flight === flight, flight.lifecycle.isAssembling else { return }
        preview.snapshot.transform = .identity
        preview.snapshot.frame = flight.parent.convert(preview.frame, from: window)
        flight.mountedPreview = preview.snapshot
        flight.parent.insertSubview(preview.snapshot, belowSubview: below ?? flight.source)
        if self.flight === flight, flight.lifecycle.isAssembling, !sourceControls.subviews.isEmpty {
            flight.sourceControls = sourceControls
            window.addSubview(sourceControls)
        }
    }

    private func finishAssembly(_ flight: PageReturnFlight) {
        guard self.flight === flight, let assembly = flight.lifecycle.assembly else { return }
        flight.lifecycle = .tracking(translation: assembly.translation)
        flight.stopAssembly()
        NavigationDiagnostics.mark(.edgeAssembled, owner: .edgeReturn)
        render(flight, translation: assembly.translation)
        guard self.flight === flight else { return }
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "dragging", flight: flight)
        #endif
        if assembly.commitsOnArrival { settleGesture(flight, commit: true) }
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
              probe.token == flight.viewportToken, let rect = viewportRect(probe, in: owner) else {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
                NSLog("RETURN192_GEOMETRY_MISMATCH viewport-unavailable")
            }
            #endif
            return false
        }
        let current = flight.source.convert(flight.rect, to: flight.parent)
        let original = flight.snapshotFrame
        let positionMatches = flight.liveSourceOffset.map { offset in
            flight.source.transform == CGAffineTransform(translationX: offset, y: 0)
                && abs(current.minX - original.minX - offset) <= 0.5
                && abs(current.minY - original.minY) <= 0.5
                && abs(current.width - original.width) <= 0.5
                && abs(current.height - original.height) <= 0.5
        } ?? (current == original)
        let matches = flight.source.bounds == flight.sourceBounds
            && flight.source.safeAreaInsets == flight.sourceSafeAreaInsets && rect == flight.rect
            && flight.source.superview === flight.parent && flight.source.window === flight.window
            && positionMatches
        #if DEBUG && targetEnvironment(simulator)
        if !matches, ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
            NSLog("RETURN192_GEOMETRY_MISMATCH offset=%g transform=%@ srcInsets=%@/%@ bounds=%@/%@ rect=%@/%@ converted=%@/%@ parent=%d window=%d",
                  Double(flight.liveSourceOffset ?? 0), NSCoder.string(for: flight.source.transform),
                  NSCoder.string(for: flight.source.safeAreaInsets), NSCoder.string(for: flight.sourceSafeAreaInsets),
                  NSCoder.string(for: flight.source.bounds), NSCoder.string(for: flight.sourceBounds),
                  NSCoder.string(for: rect), NSCoder.string(for: flight.rect),
                  NSCoder.string(for: current), NSCoder.string(for: original),
                  flight.source.superview === flight.parent ? 1 : 0, flight.source.window === flight.window ? 1 : 0)
        }
        #endif
        return matches
    }

    private func validForCommit(_ flight: PageReturnFlight) -> Bool {
        guard self.flight === flight, !flight.lifecycle.hasEnded,
              flight.previewGeneration == PageEdgeReturnPolicy.previewGeneration,
              let state, let owner = state.owner,
              owner === flight.owner, state.segmentedTokens.isEmpty,
              state.viewport?.identity == flight.identity,
              state.viewport?.canvasStyle == flight.canvasStyle,
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
        guard self.flight === flight else { return }
        switch flight.lifecycle {
        case .assembling:
            flight.lifecycle = .assembling(translation: translation)
        case .tracking:
            flight.lifecycle = .tracking(translation: translation)
            render(flight, translation: translation)
        default: break
        }
    }

    private func render(_ flight: PageReturnFlight, translation: CGFloat) {
        guard self.flight === flight, flight.lifecycle.hasSourceCanvas else { return }
        let distance = min(flight.rect.width, max(0, translation * flight.sign))
        let visualDistance = UIAccessibility.isReduceMotionEnabled ? 0 : distance
        let offset = visualDistance * flight.sign
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if flight.liveSourceOffset != nil {
            flight.moveLiveSource(to: offset)
        } else {
            flight.snapshot?.transform = CGAffineTransform(translationX: offset, y: 0)
        }
        CATransaction.commit()
        guard self.flight === flight, flight.lifecycle.hasSourceCanvas else { return }
        if flight.lifecycle.tracksPan, pan.state == .changed, abs(offset) > 1, !flight.firstMovement,
           (flight.liveSourceOffset != nil || flight.snapshot != nil) {
            flight.firstMovement = true
            NavigationDiagnostics.mark(.edgeFirstMovement, owner: .edgeReturn)
        }
        flight.mediaHeaderCanvas?.alpha = distance / max(1, flight.rect.width)
        flight.footerSurface?.alpha = distance / max(1, flight.rect.width)
        if let route = flight.headerRoute, let window = flight.window {
            NativeHeaderMotion.forWindow(window).updateBodyReturn(route, progress: Double(distance / max(1, flight.rect.width)))
        }
        #if DEBUG && targetEnvironment(simulator)
        guard self.flight === flight, !flight.lifecycle.hasEnded else { return }
        let travelingBody = flight.liveSourceOffset != nil ? flight.source : flight.snapshot
        if flight.lifecycle.tracksPan, pan.state == .changed,
           let renderedOffset = travelingBody?.layer.presentation()?.affineTransform().tx {
            if abs(renderedOffset) > abs(flight.qaHeldSourceOffset) {
                flight.qaHeldSourceOffset = renderedOffset
            }
        }
        if !flight.qaMidRecorded, flight.lifecycle.tracksPan, distance >= flight.rect.width * 0.35 {
            flight.qaMidRecorded = true
            recordQA(phase: "tracking", flight: flight)
        }
        #endif
    }

    private func settleGesture(_ flight: PageReturnFlight, commit: Bool) {
        guard self.flight === flight else { return }
        switch flight.lifecycle {
        case let .assembling(translation):
            guard commit else { cancel(flight); return }
            flight.lifecycle = .awaitingCanvas(translation: translation)
            NavigationDiagnostics.mark(.edgeSettlementDeferred, owner: .edgeReturn)
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-invalidate-accepted-return-capture") {
                PageEdgeReturnPolicy.invalidatePreviewCache()
                return
            }
            recordQA(phase: "dragging", flight: flight, event: "settlement-deferred")
            #endif
        case .trackingNativeFallback:
            if commit { commitWithoutCanvas(flight, reason: "source-canvas-not-ready") }
            else { cancel(flight) }
        case let .tracking(translation):
            let settlement = PageReturnFlight.Settlement(translation: translation, commit: commit)
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-return-hold-travel-shot") {
                flight.lifecycle = .holdingSettlement(settlement)
                flight.qaHoldTravelTask = Task { @MainActor [weak self, weak flight] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, let flight, self.flight === flight,
                          case let .holdingSettlement(held) = flight.lifecycle, held.id == settlement.id else { return }
                    flight.qaHoldTravelTask = nil
                    self.startSettlement(flight, settlement: settlement)
                }
                recordQA(phase: "tracking", flight: flight, event: "return-travel-held-for-qa")
                return
            }
            #endif
            startSettlement(flight, settlement: settlement)
        default: break
        }
    }

    private func startSettlement(_ flight: PageReturnFlight, settlement: PageReturnFlight.Settlement) {
        guard self.flight === flight else { return }
        flight.lifecycle = .settling(settlement)
        NavigationDiagnostics.mark(.edgeSettlementStarted, owner: .edgeReturn)
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "settling", flight: flight)
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let deadline: Duration = ProcessInfo.processInfo.arguments.contains("--qa-navigation-observe-shield")
            ? .seconds(5) : .milliseconds(750)
        #else
        let deadline: Duration = .milliseconds(750)
        #endif
        flight.settlementDeadline = Task { @MainActor [weak self, weak flight] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let self, let flight, self.flight === flight,
                  flight.lifecycle.isSettling(settlement) else { return }
            self.cancel(flight, reason: "return-settlement-timeout")
        }
        let start = min(1, max(0, settlement.translation * flight.sign / max(1, flight.rect.width)))
        let end: CGFloat = settlement.commit ? 1 : 0
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.26 * Double(abs(end - start))
        let curve = UnitCurve.bezier(startControlPoint: .init(x: 0.22, y: 0.8), endControlPoint: .init(x: 0.32, y: 1))
        let animator = RenderProgressAnimation(duration: duration) { [weak self, weak flight] elapsed in
            guard let self, let flight, self.flight === flight,
                  flight.lifecycle.isSettling(settlement) else { return }
            let p = start + (end - start) * curve.value(at: min(1, elapsed / max(0.001, duration)))
            self.render(flight, translation: p * flight.rect.width * flight.sign)
        } completion: { [weak self, weak flight] in
            guard let self, let flight, self.flight === flight,
                  flight.lifecycle.isSettling(settlement) else { return }
            flight.animator = nil
            #if DEBUG && targetEnvironment(simulator)
            if !self.droppedSettlementCompletionForQA,
               ProcessInfo.processInfo.arguments.contains("--qa-drop-edge-return-settlement-completion") {
                self.droppedSettlementCompletionForQA = true
                self.recordQA(phase: "settling", flight: flight, event: "settlement-completion-dropped")
                return
            }
            #endif
            flight.stopSettlement()
            self.render(flight, translation: end * flight.rect.width * flight.sign)
            guard self.flight === flight, flight.lifecycle.isSettling(settlement) else { return }
            if settlement.commit, self.validForCommit(flight) { self.commit(flight) }
            else { self.cancel(flight) }
        }
        // Initial render runs inside the initializer and can invalidate the flight.
        if self.flight === flight, flight.lifecycle.isSettling(settlement) { flight.animator = animator }
        else { animator.cancel() }
    }

    private func sourceCaptureUnavailable(_ flight: PageReturnFlight) {
        guard self.flight === flight, flight.lifecycle.isAssembling else { return }
        guard flight.navigation != nil else {
            cancel(flight, reason: "source-canvas-not-ready")
            return
        }
        if flight.lifecycle.waitsForCanvasCommit {
            commitWithoutCanvas(flight, reason: "source-canvas-not-ready")
            return
        }
        flight.lifecycle = .trackingNativeFallback
        flight.stopAssembly()
        flight.completeNativeHeader(animate: false)
    }

    private func commitWithoutCanvas(_ flight: PageReturnFlight, reason: String) {
        guard validForCommit(flight), let owner = flight.owner, let navigation = flight.navigation else {
            cancel(flight, reason: reason)
            return
        }
        cancel(flight, reason: reason)
        // Recheck the exact route after releasing the visual and input holds.
        // The ordinary Back path owns the ensuing UIKit navigation and color.
        guard self.flight == nil, flight.previewGeneration == PageEdgeReturnPolicy.previewGeneration,
              state?.owner === owner, isCurrent(owner),
              navigation.topViewController === owner,
              navigation.viewControllers.dropLast().last === flight.destination,
              state?.segmentedTokens.isEmpty == true,
              let viewport = state?.viewport, viewport.token == flight.viewportToken,
              viewport.identity == flight.identity, viewport.canvasStyle == flight.canvasStyle,
              geometryMatches(flight) else { return }
        submitNativeReturn(PageTransitionReceipt(), from: viewport, navigation: navigation, isFallback: true)
    }

    @discardableResult
    private func submitNativeReturn(_ receipt: PageTransitionReceipt, from viewport: PageReturnProbe,
                                    navigation: UINavigationController, isFallback: Bool = false) -> Bool {
        guard nativeReturnGate?.blocksBack != true, let gate = viewport.nativeReturnGate,
              let action = viewport.returnAction, gate.submit(receipt) else { return false }
        nativeReturnGate = gate
        nativeReturnNavigation = navigation
        if isFallback {
            NavigationDiagnostics.mark(.edgeNativeFallback, owner: .edgeReturn)
            action()
        } else {
            withoutPageAnimation { action() }
        }
        return true
    }

    private func commit(_ flight: PageReturnFlight) {
        guard self.flight === flight, case .settling = flight.lifecycle else { return }
        guard validForCommit(flight), let owner = flight.owner,
              let window = flight.window else {
            cancel(flight); return
        }
        flight.lifecycle = .awaitingNavigation
        NavigationDiagnostics.mark(.edgeNavigationStarted, owner: .edgeReturn)
        #if DEBUG && targetEnvironment(simulator)
        recordQA(phase: "awaitingDisappearance", flight: flight)
        #endif
        origin = nil
        do {
            let promoted = flight.bodyHandoff.preparePreview(flight.bodyToken, snapshot: flight.preview.snapshot,
                frame: flight.preview.frame, in: window, canvas: flight.preview.canvas,
                sourceScheme: flight.canvasStyle?.scheme ?? .light,
                sourceIsMedia: flight.canvasStyle?.role == .playback, sharedTone: flight.sharedTone,
                controlSource: owner)
            guard self.flight === flight, case .awaitingNavigation = flight.lifecycle else {
                if flight.bodyHandoff.isPrepared(flight.bodyToken) {
                    flight.bodyHandoff.cancel(reason: "return-ended-during-promotion")
                }
                return
            }
            let captured = flight.bodyHandoff.hasCapturedReturnPixels(flight.bodyToken)
            guard promoted, flight.preview.kind == .surface || captured else {
                cancel(flight, reason: "return-promotion-capture-failed")
                return
            }
            // The promoted destination now covers the source. UIKit must
            // receive the outgoing controller at its original geometry.
            flight.moveLiveSource(to: 0)
            let activation = PageBodyViewports.suspendActivation(in: flight.destination, token: flight.bodyToken)
            guard self.flight === flight, case .awaitingNavigation = flight.lifecycle else {
                activation?.release()
                return
            }
            flight.bodyHandoff.attachActivationLease(activation)
            #if DEBUG && targetEnvironment(simulator)
            flight.bodyHandoff.observeReturnFooterProtectionForQA(flight.bodyToken) { [weak self, weak flight] token, protected in
                guard let self, let flight, self.flight === flight, token == flight.bodyToken,
                      flight.lifecycle.isReturning else { return }
                flight.footerProtected = protected
            }
            if let canvas = flight.preview.canvas {
                flight.mediaCanvasProtected = captured
                    && canvas.header?.appearance.canvasRole == .playback
                    && canvas.frame.insetBy(dx: -1, dy: -1).contains(window.bounds)
            }
            #endif
        }
        #if DEBUG && targetEnvironment(simulator)
        let receiptTimeout: Duration = ProcessInfo.processInfo.arguments.contains("--qa-hold-edge-navigation-receipt") ? .seconds(6) : .seconds(2)
        #else
        let receiptTimeout: Duration = .seconds(2)
        #endif
        flight.navigationDeadline = Task { [weak self, weak flight] in
            do { try await Task.sleep(for: receiptTimeout) } catch { return }
            guard let self, let flight, self.flight === flight,
                  case .awaitingNavigation = flight.lifecycle else { return }
            self.cancel(flight, reason: "return-navigation-receipt-timeout")
        }
        if let navigation = flight.navigation {
            let motion = flight.window.map(NativeHeaderMotion.forWindow)
            let route = UUID()
            let pinned = flight.nativeHeaderCompletion == nil && motion?.beginRoute(from: owner, to: flight.destination, id: route, tone: flight.bodyHandoff.tone,
                                            preservesDestinationViewport: true, inputOwnedByBody: true) == true
            guard self.flight === flight, case .awaitingNavigation = flight.lifecycle else {
                if pinned { motion?.completeRoute(route, animate: false) }
                return
            }
            if pinned, let motion { installHeaderCompletion(flight, motion: motion, route: route) }
            guard validForCommit(flight), let viewport = state?.viewport else {
                cancel(flight, reason: "native-return-route-changed")
                return
            }
            // Match the real SwiftUI Back button, including its navigation state
            // and toolbar preferences. Our native observer confirms the actual pop.
            #if DEBUG && targetEnvironment(simulator)
            if !droppedReturnActionForQA,
               ProcessInfo.processInfo.arguments.contains("--qa-drop-edge-return-action") {
                droppedReturnActionForQA = true
                recordQA(phase: "awaitingDisappearance", flight: flight, event: "return-action-dropped")
                return
            }
            #endif
            if !submitNativeReturn(flight.receipt, from: viewport, navigation: navigation) {
                cancel(flight, reason: "native-return-submission-unavailable")
            }
        } else {
            // Read the current closure from the same registration. Do not retain
            // a stale form/account action across a held gesture or a rerender.
            guard let viewport = state?.viewport, let receipt = viewport.navigationReceipt,
                  receipt.claimBody(flight.bodyToken, visibleAndRequested: viewport.mayRetryEdgeClose?() == true,
                                    navigation: { [self, flight] outcome in
                      receiveNavigation(outcome, flight: flight)
                  }, abortVisual: { [self, flight] reason in
                      cancel(flight, reason: reason)
                  }) else {
                cancel(flight, reason: "missing-presentation-receipt")
                return
            }
            flight.navigationReceipt = receipt
            guard validForCommit(flight), state?.viewport?.navigationReceipt === receipt,
                  let close = state?.close, close.token == flight.actionToken,
                  let action = close.closeAction, receipt.beginEdgeClose(flight.receipt) else {
                cancel(flight, reason: "presentation-return-route-changed")
                return
            }
            let mayRetryEdgeClose = viewport.mayRetryEdgeClose
            let accepted = action()
            receipt.resolveEdgeClose(flight.bodyToken, accepted: accepted,
                                    requested: mayRetryEdgeClose?() != true, retryDelay: receiptTimeout)
            if !accepted { flight.receipt.recordNavigation(.cancelled, token: flight.bodyToken) }
            guard self.flight === flight, case .awaitingNavigation = flight.lifecycle else { return }
            if !accepted {
                flight.stopNavigationDeadline()
                flight.releaseNavigationReceipt()
                guard let window = flight.window else {
                    cancel(flight, reason: "return-preview-window-lost"); return
                }
                let frame = flight.parent.convert(flight.preview.frame, from: window)
                guard flight.bodyHandoff.reclaimPreviewPlane(flight.bodyToken, parent: flight.parent,
                                                           below: flight.source, frame: frame) else {
                    cancel(flight, reason: "return-preview-reclaim-failed"); return
                }
                guard self.flight === flight, case .awaitingNavigation = flight.lifecycle else {
                    return
                }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                flight.sourceHeaderCopies.forEach { $0.alpha = 1 }
                if let controls = flight.sourceControls { window.bringSubviewToFront(controls) }
                flight.bodyHandoff.cancel()
                CATransaction.commit()
                guard self.flight === flight, case .awaitingNavigation = flight.lifecycle else { return }
                startSettlement(flight, settlement: .init(translation: flight.rect.width * flight.sign, commit: false))
            }
        }
    }

    private func finishCommitted(_ flight: PageReturnFlight) {
        guard self.flight === flight, case .awaitingNavigation = flight.lifecycle,
              flight.receipt.navigation == .committed else { return }
        flight.lifecycle = .revealing
        flight.removeSourceVisuals()
        guard self.flight === flight, case .revealing = flight.lifecycle else { return }
        trackDestinationControls(flight)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-hold-committed-edge-handoff"),
           flight.bodyHandoff.isPrepared(flight.bodyToken) {
            // Keep the actual promoted pixels mounted. The normal terminal deadline
            // starts with the handoff below, after this simulator-only hold.
            recordQA(phase: "revealing", flight: flight, event: "committed-handoff-held")
            Task { @MainActor [self, flight] in
                do { try await Task.sleep(for: .seconds(7)) } catch { return }
                let superseded = self.flight !== flight
                self.continueCommittedHandoff(flight)
                guard superseded, let window = flight.window else { return }
                let label = self.qaLabel(in: window)
                guard let value = label.accessibilityValue,
                      value.contains(";receipt=\(flight.bodyToken.uuidString);") else { return }
                label.accessibilityValue = value + ";lateCommittedHandoffRejected=true"
            }
            return
        }
        #endif
        continueCommittedHandoff(flight)
    }

    private func continueCommittedHandoff(_ flight: PageReturnFlight) {
        guard self.flight === flight, case .revealing = flight.lifecycle else { return }
        guard flight.bodyHandoff.awaitCommittedReturnHandoff(flight.bodyToken, completion: { [self, flight] outcome in
            guard self.flight === flight, case .revealing = flight.lifecycle else { return }
            end(flight, outcome: outcome)
        }) else {
            end(flight, outcome: .aborted("missing-return-body"))
            return
        }
        // Keep the same flight through the header and destination render fences.
        let coordinatedHeader = flight.nativeHeaderCompletion != nil
        flight.completeNativeHeader(animate: true) { [self, flight] completed in
            guard self.flight === flight, case .revealing = flight.lifecycle else { return }
            guard flight.bodyHandoff.isPrepared(flight.bodyToken) else {
                end(flight, outcome: .aborted("body-ended-before-header"))
                return
            }
            guard completed else {
                end(flight, outcome: .aborted("header-handoff-failed"))
                return
            }
            if coordinatedHeader {
                guard validateReturnedCanvas(flight) else { return }
                flight.bodyHandoff.finishReturnReveal(flight.bodyToken, destination: flight.destination)
                return
            }
            flight.revealBoundary = RenderFrameBoundary { [self, flight] in
                guard self.flight === flight, case .revealing = flight.lifecycle else { return }
                flight.revealBoundary = nil
                // A presented panel's parent registers its return viewport on this frame.
                guard validateReturnedCanvas(flight) else { return }
                flight.bodyHandoff.reveal(flight.bodyToken, destination: flight.destination)
            }
        }
    }

    private func trackDestinationControls(_ flight: PageReturnFlight) {
        // Native navigation has handed input to the destination. Its own Back
        // action must already work while the retained pixels finish revealing.
        if let observer = flight.touchObserver,
           let owner = PageBodyViewports.geometry(containing: flight.destination)?.owner {
            observer.controlsAreCurrent = { [weak self, weak flight, weak owner] in
                guard let self, let flight, let owner, self.flight === flight,
                      case .revealing = flight.lifecycle else { return false }
                return self.isCurrent(owner)
            }
            observer.trackControls(of: owner, includingSuppressed: true)
        }
    }

    private func validateReturnedCanvas(_ flight: PageReturnFlight) -> Bool {
        guard self.flight === flight, case .revealing = flight.lifecycle else { return false }
        guard flight.bodyHandoff.isPrepared(flight.bodyToken) else {
            end(flight, outcome: .aborted("body-ended-before-canvas"))
            return false
        }
        guard let window = flight.window, flight.preview.matchesMediaCanvas(of: flight.destination, window: window) else {
            end(flight, outcome: .aborted("return-media-canvas-changed"))
            return false
        }
        // A modal presenter can register its own viewport on this render frame.
        trackDestinationControls(flight)
        return true
    }

    private func cancelImmediately(reason: String = "cancel") {
        guard let flight else { origin = nil; return }
        cancel(flight, reason: reason)
    }

    private func cancel(_ flight: PageReturnFlight, reason: String = "cancel") {
        let outcome: PageVisualOutcome = reason == "cancel" && flight.receipt.navigation != .committed
            ? .cancelled : .aborted(reason)
        end(flight, outcome: outcome)
    }

    private func end(_ flight: PageReturnFlight, outcome: PageVisualOutcome) {
        guard self.flight === flight, !flight.lifecycle.hasEnded else { return }
        let previous = flight.lifecycle
        flight.lifecycle = .ended(assembled: previous.hasSourceCanvas)
        flight.touchObserver?.onNewTouch = nil
        origin = nil
        if !previous.isReturning {
            _ = flight.receipt.recordNavigation(.cancelled, token: flight.bodyToken)
        }
        _ = flight.receipt.recordVisual(outcome, token: flight.bodyToken)

        // Mark the flight terminal before releasing anything that may call back.
        pan.discardTrackedTouchSequence()
        flight.stopAssembly()
        flight.stopSettlement()
        flight.stopNavigationDeadline()
        flight.revealBoundary?.cancel()
        flight.revealBoundary = nil
        flight.releaseNavigationReceipt()
        flight.completeNativeHeader(animate: false)
        switch outcome {
        case .completed: break
        case .cancelled: flight.bodyHandoff.cancel()
        case let .aborted(reason): flight.bodyHandoff.cancel(reason: reason)
        }
        flight.removeSourceVisuals()
        flight.touchObserver?.remove(); flight.touchObserver = nil
        self.flight = nil

        switch outcome {
        case .completed: NavigationDiagnostics.mark(.edgeCommitted)
        case .cancelled: NavigationDiagnostics.mark(.edgeCancelled)
        case .aborted("return-pan-reset"): NavigationDiagnostics.mark(.edgePanReset)
        case .aborted("return-abandoned-on-new-touch"): NavigationDiagnostics.mark(.edgeOrphanedDragRecovered)
        case .aborted("return-assembly-timeout"): NavigationDiagnostics.mark(.edgeAssemblyTimeout)
        case .aborted("return-settlement-timeout"): NavigationDiagnostics.mark(.edgeSettlementTimeout)
        case .aborted("return-navigation-receipt-timeout"): NavigationDiagnostics.mark(.edgeNavigationTimeout)
        case .aborted("return-scene-inactive"): NavigationDiagnostics.mark(.edgeSceneInactive)
        case .aborted: NavigationDiagnostics.mark(.edgeAborted)
        }
        #if DEBUG && targetEnvironment(simulator)
        switch outcome {
        case .completed: recordQA(phase: "completed", flight: flight)
        case .cancelled: recordQA(phase: "cancelled", flight: flight)
        case let .aborted(reason): recordQA(phase: "aborted", flight: flight, reason: reason)
        }
        let heldCapture = flight.heldCaptureForQA
        flight.heldCaptureForQA = nil
        if outcome == .aborted("return-abandoned-on-new-touch"), let heldCapture {
            Task { @MainActor [self, flight] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                heldCapture(self, flight)
            }
        }
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    private func recordLateCaptureQA(_ result: PageCanvasSnapshot.CaptureResult, flight: PageReturnFlight) {
        guard let window = flight.window else { return }
        let label: UILabel
        if let existing = objc_getAssociatedObject(window, &Self.lateCaptureQAKey) as? UILabel {
            label = existing
        } else {
            label = UILabel(frame: CGRect(x: window.bounds.minX + 1, y: window.bounds.maxY - 1, width: 1, height: 1))
            label.alpha = 0.01
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = "page.return-late-capture.qa"
            label.accessibilityLabel = "Page return late capture"
            label.autoresizingMask = [.flexibleTopMargin]
            objc_setAssociatedObject(window, &Self.lateCaptureQAKey, label, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            window.addSubview(label)
        }
        let captured: Bool
        if case .captured = result { captured = true } else { captured = false }
        label.accessibilityValue = "delivered=true;rejected=true;captured=\(captured);receipt=\(flight.bodyToken)"
    }

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
        let sourceSnapshotTx = flight.liveSourceOffset ?? flight.snapshot?.transform.tx ?? 0
        let value = "phase=\(phase);navigationOutcome=\(navigationOutcome);visualOutcome=\(visualOutcome);event=\(event);reason=\(reason);receipt=\(flight.bodyToken);\(coordinates);assembled=\(flight.lifecycle.hasSourceCanvas);sourceSnapshotTx=\(sourceSnapshotTx);sourceMasked=\(flight.source.layer.mask != nil);\(target);targetLoaded=\(targetView != nil);targetHidden=\(targetHidden);targetWindow=\(targetView?.window != nil);targetWindowSame=\(targetView?.window === window);targetFrameSpace=\(targetSpace);sourceWindow=\(flight.source.window != nil);canYield=\(!flight.lifecycle.hasEnded);globalBlocked=\(PageInteractionShield.blocksNewTouches(in: window));targetUIEnabled=\(targetEnabled);sourceUIEnabled=\(flight.source.isUserInteractionEnabled);targetAncestors=\(targetAncestors);\(headerCoordinates);headerHit=\(headerHit);returnRoleOwns=\(ownsReturn);mediaBand=\(flight.preview.capturedMediaBandFrame != nil);mediaBandTop=\(flight.preview.capturedMediaBandFrame?.minY ?? -1);mediaBandHeight=\(flight.preview.capturedMediaBandFrame?.height ?? -1);previewKind=\(flight.preview.kind.rawValue);previewAttached=\(flight.preview.snapshot.superview === flight.parent);previewWindow=\(flight.preview.snapshot.window != nil)"
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
        let publishedValue = value + ";nativePop=\(native);nativeContentPop=\(content);nativeInteractive=\(flight.navigation?.transitionCoordinator?.isInteractive == true);corners=\(layers.joined(separator: "|"));sharedHeader=\(flight.headerRoute != nil);footerProtected=\(flight.footerProtected);mediaCanvasProtected=\(flight.mediaCanvasProtected);watchdogRecovered=\(flight.touchWatchRecoveredForQA);settlementDeferred=\(flight.lifecycle.settlementDeferred);liveSourceMotion=\(flight.liveSourceOffset != nil);firstMovement=\(flight.firstMovement);heldSourceTx=\(flight.qaHeldSourceOffset);heldFinger=\(abs(flight.qaHeldSourceOffset) > 1)"
        label.accessibilityValue = publishedValue
        if phase == "dragging" || phase == "tracking" || phase == "awaitingDisappearance"
            || ((phase == "cancelled" || phase == "aborted") && ProcessInfo.processInfo.arguments.contains("--qa-page-return")) {
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
        struct Settlement {
            let id = UUID()
            let translation: CGFloat
            let commit: Bool
        }

        enum Lifecycle {
            case assembling(translation: CGFloat)
            case awaitingCanvas(translation: CGFloat)
            case tracking(translation: CGFloat)
            case trackingNativeFallback
            case holdingSettlement(Settlement)
            case settling(Settlement)
            case awaitingNavigation
            case revealing
            case ended(assembled: Bool)

            var assembly: (translation: CGFloat, commitsOnArrival: Bool)? {
                switch self {
                case let .assembling(translation): (translation, false)
                case let .awaitingCanvas(translation): (translation, true)
                default: nil
                }
            }

            var isAssembling: Bool { assembly != nil }
            var waitsForCanvasCommit: Bool { assembly?.commitsOnArrival == true }

            var tracksPan: Bool {
                switch self {
                case .assembling, .tracking, .trackingNativeFallback: true
                default: false
                }
            }

            var hasSourceCanvas: Bool {
                switch self {
                case .tracking, .holdingSettlement, .settling, .awaitingNavigation, .revealing: true
                case let .ended(assembled): assembled
                default: false
                }
            }

            var isReturning: Bool {
                switch self {
                case .awaitingNavigation, .revealing: true
                default: false
                }
            }

            var hasEnded: Bool {
                if case .ended = self { return true }
                return false
            }

            func isSettling(_ settlement: Settlement) -> Bool {
                guard case let .settling(current) = self else { return false }
                return current.id == settlement.id
            }

            #if DEBUG && targetEnvironment(simulator)
            var settlementDeferred: Bool {
                if case .holdingSettlement = self { return true }
                return waitsForCanvasCommit
            }
            #endif
        }
        weak var owner: UIViewController?
        weak var navigation: UINavigationController?
        let source: UIView
        let parent: UIView
        let destination: UIViewController
        let preview: PageReturnPreview
        let previewGeneration: UInt64
        let canvasStyle: PageReturnCanvasStyle?
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
        var assemblyDeadline: Task<Void, Never>?
        var assemblyDelayTask: Task<Void, Never>?
        var sourceCanvasCaptureCancel: (() -> Void)?
        var sourceControls: UIView?
        var sourceHeaderCopies: [UIView] = []
        var lifecycle: Lifecycle = .assembling(translation: 0)
        var snapshot: UIView?
        var mountedPreview: UIView?
        var liveSourceOffset: CGFloat?
        var liveSourceBackdrop: UIView?
        var liveControlSuppression: PageControlCaptureLease?
        var firstMovement = false
        var mediaHeaderCanvas: UIView?
        var footerSurface: UIView?
        var mask: CAShapeLayer?
        var touchObserver: PageReturnTouchObserver?
        #if DEBUG && targetEnvironment(simulator)
        var qaMidRecorded = false
        var qaHeldSourceOffset: CGFloat = 0
        var qaHoldTravelTask: Task<Void, Never>?
        var holdsCaptureForQA = false
        var heldCaptureForQA: ((PageReturnDriver, PageReturnFlight) -> Void)?
        var mediaCanvasProtected = false
        var panFaultForQA: PanFault?
        var touchWatchRecoveredForQA = false
        #endif
        var footerProtected = false
        var headerRoute: UUID?
        var sharedTone: PageToneTransition?
        var nativeHeaderCompletion: ((Bool, @escaping (Bool) -> Void) -> Void)?
        let bodyHandoff = PageBodyHandoff()
        let receipt = PageTransitionReceipt()
        var bodyToken: UUID { receipt.id }
        var navigationReceipt: PageReturnNavigationReceipt?
        var navigationDeadline: Task<Void, Never>?
        var settlementDeadline: Task<Void, Never>?
        var animator: RenderProgressAnimation?
        var revealBoundary: RenderFrameBoundary?

        init(owner: UIViewController, source: UIView, parent: UIView,
             destination: Destination, viewportToken: UUID, identity: AnyHashable?, rect: CGRect,
             sign: CGFloat, preview: PageReturnPreview, generation: UInt64, canvasStyle: PageReturnCanvasStyle?) {
            self.owner = owner; self.source = source; self.parent = parent
            self.destination = destination.controller; navigation = destination.navigation
            self.preview = preview
            self.previewGeneration = generation
            self.canvasStyle = canvasStyle
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

        func moveLiveSource(to offset: CGFloat) {
            guard let liveSourceOffset,
                  source.transform == CGAffineTransform(translationX: liveSourceOffset, y: 0) else { return }
            self.liveSourceOffset = offset
            let transform = CGAffineTransform(translationX: offset, y: 0)
            source.transform = transform
            touchObserver?.pinControls(in: source, bodyOffset: offset)
            liveSourceBackdrop?.transform = transform
        }

        func stopAssembly() {
            assemblyDeadline?.cancel(); assemblyDeadline = nil
            assemblyDelayTask?.cancel(); assemblyDelayTask = nil
            let cancelCapture = sourceCanvasCaptureCancel; sourceCanvasCaptureCancel = nil
            cancelCapture?()
        }

        func stopSettlement() {
            #if DEBUG && targetEnvironment(simulator)
            qaHoldTravelTask?.cancel(); qaHoldTravelTask = nil
            #endif
            settlementDeadline?.cancel(); settlementDeadline = nil
            animator?.cancel(); animator = nil
        }

        func stopNavigationDeadline() {
            navigationDeadline?.cancel(); navigationDeadline = nil
        }

        func releaseNavigationReceipt() {
            let navigationReceipt = navigationReceipt
            self.navigationReceipt = nil
            navigationReceipt?.releaseBody(bodyToken)
        }

        func removeSourceVisuals() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Restore the real source before relinquishing either visual copy.
            moveLiveSource(to: 0)
            liveSourceOffset = nil
            liveSourceBackdrop?.removeFromSuperview(); liveSourceBackdrop = nil
            let suppression = liveControlSuppression; liveControlSuppression = nil
            if let mask, source.layer.mask === mask { source.layer.mask = oldMask }
            mask = nil
            snapshot?.removeFromSuperview(); snapshot = nil
            sourceControls?.removeFromSuperview(); sourceControls = nil
            sourceHeaderCopies.removeAll()
            if mediaHeaderCanvas?.superview === parent { restoreMediaHeaderCanvas() }
            if footerSurface?.superview === window {
                footerSurface?.removeFromSuperview(); footerSurface?.alpha = 1
            }
            // The cached view is already a copy of the destination. Remove only
            // our mounted copy, never the real destination's view or constraints.
            let mounted = mountedPreview
            mountedPreview = nil
            if mounted?.superview === parent { mounted?.removeFromSuperview() }
            suppression?.release()
            CATransaction.commit()
        }

        func completeNativeHeader(animate: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
            let finish = nativeHeaderCompletion
            nativeHeaderCompletion = nil
            if let finish { finish(animate, completion) }
            else { completion(true) }
        }
    }
}
