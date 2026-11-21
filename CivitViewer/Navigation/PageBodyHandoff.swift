import SwiftUI
import UIKit
import Darwin

enum PageCanvasRole { case ordinary, playback }

/// A window-local read-only bridge to the existing visual owner. Ancestor bars
/// and separate native hosts can read its clock without owning another flight.
@MainActor @Observable final class PageSurfaceToneContext {
    fileprivate weak var owner: PageBodyHandoff?
    private(set) var returnTone: PageToneTransition?
    var tone: PageToneTransition? { returnTone ?? owner?.tone }
    func installReturnTone(_ tone: PageToneTransition) { returnTone = tone }
    func clearReturnTone(_ id: UUID) { if returnTone?.id == id { returnTone = nil } }
}

/// A short-lived, viewport-only visual copy. It never owns navigation or a
/// business completion. The real destination renders beneath it; chrome stays live.
@MainActor @Observable final class PageBodyHandoff {
    @MainActor private struct LiveTargetLease {
        let owner: UIViewController
        let view: UIView
        let window: UIWindow
        let scene: ObjectIdentifier?
        let navigation: UINavigationController?
        let navigationTop: UIViewController?
        let superview: UIView
        let bounds: CGRect
        let center: CGPoint
        let transform: CGAffineTransform
        let backgroundColor: UIColor?
        let accessibilityElementsHidden: Bool
        let isUserInteractionEnabled: Bool
        var assignedTransform: CGAffineTransform
        var targetBackgroundColor: UIColor?
        var assignedBackgroundColor: UIColor?

        func isValid() -> Bool {
            guard view.window === window, view.superview === superview,
                  view.bounds == bounds, view.center == center,
                  view.transform == assignedTransform,
                  window.windowScene.map(ObjectIdentifier.init) == scene,
                  navigation?.topViewController === navigationTop else { return false }
            return owner.viewIfLoaded === view && (navigation == nil || navigationTop === owner)
        }

        mutating func set(progress: CGFloat, direction: CGFloat, width: CGFloat) -> Bool {
            guard isValid() else { return false }
            let dx = -direction * width * (1 - min(1, max(0, progress)))
            assignedTransform = transform.concatenating(CGAffineTransform(translationX: dx, y: 0))
            view.transform = assignedTransform
            if let targetBackgroundColor {
                assignedBackgroundColor = targetBackgroundColor
                view.backgroundColor = targetBackgroundColor
            }
            return true
        }

        mutating func restore() {
            guard owner.viewIfLoaded === view else { return }
            // A layout/containment change ends eligibility for movement, not
            // ownership of each property that this lease has already written.
            if view.transform == assignedTransform { view.transform = transform }
            if let assignedBackgroundColor, view.backgroundColor == assignedBackgroundColor {
                view.backgroundColor = backgroundColor
            }
            if view.accessibilityElementsHidden { view.accessibilityElementsHidden = accessibilityElementsHidden }
            if !view.isUserInteractionEnabled { view.isUserInteractionEnabled = isUserInteractionEnabled }
            assignedTransform = view.transform
        }
    }

    private(set) var tone: PageToneTransition?
    private static var contextKey: UInt8 = 0
    private static let owners = NSMapTable<UIWindow, PageBodyHandoff>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private weak var window: UIWindow?
    private var token: UUID?
    private var isRemoving = false
    private var pendingCanvasToken: UUID?
    private var pendingCanvasCaptureCancel: (() -> Void)?
    private var pendingPrepareCompletion: ((Bool) -> Void)?
    private var pendingEntryCanvas: CapturedPageCanvas?
    private var pendingEntryCanvasIdentity: AnyHashable?
    private var pendingEntryCanvasWindow: UIWindow?
    private var targetLiveLease: LiveTargetLease?
    private var canvasControlsBegun = false
    private var canvasControlsStaged = false
    private var activationLease: PageVisualActivationLease?
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private var returnFooterProtectionQA: ((UUID, Bool) -> Void)?

    func observeReturnFooterProtectionForQA(_ token: UUID, callback: @escaping (UUID, Bool) -> Void) {
        guard self.token == token, ProcessInfo.processInfo.arguments.contains("--qa-page-return") else { return }
        returnFooterProtectionQA = callback
    }
    #endif
    private var overlay: UIView?
    private weak var bodyPixels: UIView?
    private weak var sourceCanvasOwnerView: UIView?
    private weak var sourceCanvasOwnerSuperview: UIView?
    private var sourceCanvasOwnerBounds = CGRect.zero
    private var sourceCanvasOwnerCenter = CGPoint.zero
    private var sourceCanvasOwnerTransform = CGAffineTransform.identity
    private weak var targetScopeController: UIViewController?
    private var targetOwner: ObjectIdentifier?
    private var targetFrame = CGRect.zero
    private var fixedHeaderHost: UIHostingController<PageBodyFixedHeaderOverlay>?
    private var fixedHeaderHandoff: HeaderHandoff?
    private var rootHeaderVisibilityCancel: (() -> Void)?
    private var returnFooterCanvas: UIView?
    private var returnFooterRootLease: PageControlCaptureLease?
    private var targetFooterRootLease: PageControlCaptureLease?
    private var returnFooterExpectedEndpoint: RootFooterEndpoint?
    private weak var targetFooterOwner: UIViewController?
    private weak var targetFooterDrawable: UIView?
    private weak var targetFooterExpectedSuperview: UIView?
    private var targetFooterExpectedFrame: CGRect?
    private var targetFooterExpectedBounds: CGRect?
    private var targetFooterExpectedCenter: CGPoint?
    private var targetFooterStableFrame: CGRect?
    private var targetFooterStaged = false
    private var returnFooterStableEndpoint: RootFooterEndpoint?
    private var returnFooterStableFrames = 0
    private var returnFooterWaitFrames = 0
    private var returnFooterBoundary: RenderFrameBoundary?
    private var returnFooterCompletion: (() -> Void)?
    private var footerCaptureLeases: [PageControlCaptureLease] = []
    private var rootLiveControls = false
    private var rootLiveTargetGeometry: CGRect?
    private var rootLiveSourceFooter: RootFooterEndpoint?
    private var rootLiveTargetTab: Int?
    private var rootLiveTargetMedia = false
    let rootFooterMotion = RootFooterMotion()
    private var rootLiveEndpointProgress = 1.0
    private weak var rootFooterProbe: NativeHeaderProbe?
    private var rootFooterReveal: (() -> Bool)?
    private var rootFooterAcknowledge: ((NativeHeaderProbe) -> Bool)?
    #if DEBUG && targetEnvironment(simulator)
    private var heldSearchTerminalForQA: UUID?
    private var releasedSearchTerminalForQA: UUID?
    #endif
    private var rootHeaderRendered = false
    private var rootFooterRendered = false
    private var rootHeaderRevealStarted = false
    private var rootTerminalCommitted = false
    private var rootTerminalIsCurrent: (() -> Bool)?

    private var frameBoundary: RenderFrameBoundary?
    private var animator: RenderProgressAnimation?
    private var releaseCompletion: ((PageVisualOutcome) -> Void)?
    private var rootHeaderReadinessCancel: (() -> Void)?
    private var rootHeaderAckBoundary: RenderFrameBoundary?
    private var rootHeaderAckFrames = 0
    private var interaction: PageTransitionInput?
    private var terminalHandoffDeadline: Task<Void, Never>?
    private var completion: ((PageVisualOutcome) -> Void)?
    private var bounds = CGRect.zero
    private var orientation = UIInterfaceOrientation.unknown
    private var safeArea = UIEdgeInsets.zero
    private var bodyFrame = CGRect.zero
    private var targetCanvasFrame = CGRect.zero
    private var capturedPixels = false
    private var capturedTargetPixels = false
    private var interactiveProgress = 0.0
    private var interactiveDirection: CGFloat = -1
    private var slideOffset: CGFloat = 0
    private var frames = 0
    private var kind = "entry"
    private var cancellationReason = "none"
    private var deactivation: NSObjectProtocol?
    #if DEBUG && targetEnvironment(simulator)
    private var residentBefore = 0.0
    private var residentPeak = 0.0
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private var readback: UILabel?
    #endif

    /// Account replacement invalidates every old visual copy, including a
    /// terminal edge return whose source controller has already been removed.
    static func cancelAll() {
        let active = owners.objectEnumerator()?.allObjects.compactMap { $0 as? PageBodyHandoff } ?? []
        let windows = active.compactMap(\.window)
        active.forEach { $0.cancel() }
        windows.forEach { NativeHeaderMotion.forWindow($0).yieldToTabSwitch() }
    }
    #if DEBUG && targetEnvironment(simulator)
    static func qaHasEntryOverlay(in window: UIWindow) -> Bool {
        guard let owner = owners.object(forKey: window) else { return false }
        return owner.kind == "entry" && owner.overlay != nil
    }
    static var qaState: (kind: String, phase: String)?
    static let qaStateDidChange = Notification.Name("CivitBodyMotionQAStateChanged")
    #endif

    static func hasActiveFlight(in window: UIWindow) -> Bool {
        guard let owner = owners.object(forKey: window) else { return false }
        return owner.token != nil || owner.interaction != nil
    }

    static func toneContext(in window: UIWindow) -> PageSurfaceToneContext {
        if let context = objc_getAssociatedObject(window, &contextKey) as? PageSurfaceToneContext { return context }
        let context = PageSurfaceToneContext()
        objc_setAssociatedObject(window, &contextKey, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return context
    }

    init() {
        deactivation = NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let scene = notification.object as? UIWindowScene else { return }
                Task { @MainActor [weak self, weak scene] in
                    guard let self, scene === self.window?.windowScene else { return }
                    self.cancel()
                }
            }
    }
    deinit {
        MainActor.assumeIsolated {
            if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
            remove(outcome: nil)
        }
    }

    func prepare(_ token: UUID, source: UIViewController?, kind: String, enabled: Bool,
                 sourceScheme: ColorScheme, sourceIsMedia: Bool, identity: AnyHashable? = nil,
                 completion: @escaping (Bool) -> Void) {
        guard !isRemoving else { completion(false); return }
        cancel()
        #if DEBUG && targetEnvironment(simulator)
        let captureStarted = CACurrentMediaTime()
        residentBefore = residentMiB()
        residentPeak = residentBefore
        #endif
        guard enabled, let source, let geometry = PageBodyViewports.geometry(containing: source),
              let view = geometry.owner.viewIfLoaded, let window = view.window,
              window.windowScene?.activationState == .foregroundActive, view.layer.mask == nil else {
            completion(false); return
        }
        pendingCanvasToken = token
        pendingPrepareCompletion = completion
        guard let canvasRect = geometry.canvasRect else {
            pendingCanvasToken = nil; pendingPrepareCompletion = nil; completion(false); return
        }
        let expectedCanvas = view.convert(canvasRect, to: window)
        let expectedReading = view.convert(geometry.rect, to: window)
        let cancelCapture = PageCanvasSnapshot.capture(owner: geometry.owner, token: token) { [weak self, weak window] capture in
            guard let self, let window, self.pendingCanvasToken == token else { return }
            self.pendingCanvasCaptureCancel = nil
            self.pendingCanvasToken = nil
            let result = self.pendingPrepareCompletion; self.pendingPrepareCompletion = nil
            guard case let .captured(canvas) = capture, canvas.owner === geometry.owner,
                  geometry.owner.viewIfLoaded?.window === window,
                  self.close(canvas.frame, expectedCanvas, tolerance: 2),
                  self.close(canvas.readingFrame, expectedReading, tolerance: 2),
                  canvas.frame.width > 1, canvas.frame.height > 1 else { result?(false); return }
            canvas.pixels.frame = canvas.frame
            guard self.install(token, window: window, frame: canvas.frame, pixels: canvas.pixels,
                kind: kind, sourceScheme: sourceScheme, sourceIsMedia: sourceIsMedia,
                sourceOwner: canvas.owner) else {
                result?(false); return
            }
            self.pendingEntryCanvas = kind == "entry" ? canvas : nil
            self.pendingEntryCanvasIdentity = kind == "entry" ? identity : nil
            self.pendingEntryCanvasWindow = kind == "entry" ? window : nil
            self.installCanvasFooter(canvas.footer, owner: canvas.owner, token: token)
            self.beginCanvasControls(token, source: canvas.owner, tone: self.tone, in: window)
            guard self.token == token else { result?(false); return }
            if canvas.header != nil && !self.canvasControlsBegun {
                self.cancel(reason: "source-controls-could-not-be-held")
                result?(false); return
            }
            result?(self.capturedPixels)
        }
        if pendingCanvasToken == token { pendingCanvasCaptureCancel = cancelCapture }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-body-motion") {
            NSLog("BODY_PERF capture_ms=\((CACurrentMediaTime() - captureStarted) * 1000);pixels=\(capturedPixels);width=\(geometry.rect.width);height=\(geometry.rect.height);residentBeforeMiB=\(residentBefore)")
        }
        #endif
    }

    /// Root-tab navigation moves its existing host views. This adapter owns
    /// only the fixed header handoff and input lease; it never captures a page,
    /// canvas, footer, or safe-area image.
    @discardableResult
    func prepareRootLive(_ token: UUID, source: UIViewController, sourceTab: Int, destinationTab: Int,
                         kind: String, sourceMedia: Bool, sourceFooter: RootFooterEndpoint) -> Bool {
        guard !isRemoving else { return false }
        cancel()
        guard let geometry = PageBodyViewports.geometry(containing: source),
              let ownerView = geometry.owner.viewIfLoaded, let window = ownerView.window,
              window.windowScene?.activationState == .foregroundActive,
              sourceFooter.selectedTab == sourceTab,
              sourceFooter.overMedia == sourceMedia,
              PageBodyViewports.rootFooterEndpoint(in: window) == sourceFooter else { return false }
        Self.owners.object(forKey: window)?.cancel(reason: "superseded")
        Self.owners.setObject(self, forKey: window)
        self.window = window; self.token = token; self.kind = kind
        cancellationReason = "none"; bounds = window.bounds
        orientation = window.windowScene?.interfaceOrientation ?? .unknown
        safeArea = window.safeAreaInsets; bodyFrame = window.bounds
        targetScopeController = source; targetOwner = ObjectIdentifier(geometry.owner)
        targetFrame = ownerView.convert(geometry.rect, to: window)
        rootLiveControls = true; rootLiveTargetGeometry = nil
        rootLiveEndpointProgress = 1
        rootLiveSourceFooter = sourceFooter; rootLiveTargetTab = destinationTab
        rootLiveTargetMedia = false
        capturedPixels = false; capturedTargetPixels = false
        interactiveProgress = 0
        let input = PageTransitionInput(token: token)
        interaction = input
        guard input.acquire(in: window, source: .bodyHandoff,
                           hitTarget: { [weak self, weak window] point, event in
                               guard let self, let window else { return nil }
                               return self.rootTerminalHitTarget(token, in: window, point: point, event: event)
                           }), self.token == token else { return false }
        publish("holding", progress: 0)
        return true
    }

    /// Promote only the visible destination body copy before its old UIKit
    /// parent is removed. The reusable whole-page cache remains untouched.
    @discardableResult
    func preparePreview(_ token: UUID, snapshot: UIView, frame: CGRect, in window: UIWindow,
                        canvas: CapturedPageCanvas? = nil, sourceScheme: ColorScheme,
                        sourceIsMedia: Bool, sharedTone: PageToneTransition? = nil,
                        controlSource: UIViewController? = nil) -> Bool {
        guard !isRemoving else { return false }
        cancel()
        guard window.windowScene?.activationState == .foregroundActive,
              frame.width > 1, frame.height > 1 else { return false }
        let pixels: UIView
        if let canvas {
            guard canvas.pixels === snapshot, snapshot.superview == nil || snapshot.window === window else { return false }
            pixels = snapshot
        } else {
            // Surface previews already carry the selected light/dark/media
            // neutral. Transfer that exact plane so no second neutral is
            // composed during promotion.
            pixels = snapshot
        }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-return-promotion-fails172") { return false }
        #endif
        pixels.transform = .identity
        pixels.frame = frame
        let heldFooter = canvas?.footer ?? controlSource.flatMap {
            PageReturnFooterPreview.capture(for: $0, header: NativeHeaderMotion.forWindow(window).settledContent(for: $0), in: window)
        }
        guard install(token, window: window, frame: frame, pixels: pixels, kind: "edge-return",
                sourceScheme: sourceScheme, sourceIsMedia: sourceIsMedia, sharedTone: sharedTone,
                sourceOwner: canvas?.owner, blocksNewTouches: false) else { return false }
        capturedPixels = canvas != nil
        pendingEntryCanvas = nil; pendingEntryCanvasWindow = nil; pendingEntryCanvasIdentity = nil
        if let heldFooter, let footerOwner = canvas?.owner ?? controlSource {
            installCanvasFooter(heldFooter, owner: footerOwner, token: token, targetPreview: canvas?.footer != nil)
        }
        let nativeSource = sharedTone == nil ? controlSource : (canvas?.owner ?? controlSource)
        if let nativeSource {
            beginCanvasControls(token, source: nativeSource, tone: sharedTone ?? tone, in: window)
        }
        return self.token == token && overlay != nil
    }

    private func beginCanvasControls(_ token: UUID, source: UIViewController, tone: PageToneTransition?,
                                     in window: UIWindow) {
        guard self.token == token, overlay != nil else { return }
        let motion = NativeHeaderMotion.forWindow(window)
        let started = motion.beginCanvasControls(token: token, source: source, tone: tone)
        guard self.token == token else {
            if started { motion.consumeCanvasControls(token: token) }
            return
        }
        canvasControlsBegun = started
    }

    private func install(_ token: UUID, window: UIWindow, frame: CGRect, pixels: UIView, kind: String,
                         sourceScheme: ColorScheme, sourceIsMedia: Bool,
                         sharedTone: PageToneTransition? = nil, sourceOwner: UIViewController? = nil,
                         blocksNewTouches: Bool = true) -> Bool {
        Self.owners.object(forKey: window)?.cancel()
        Self.owners.setObject(self, forKey: window)
        self.window = window
        self.token = token
        self.kind = kind
        cancellationReason = "none"
        bounds = window.bounds
        orientation = window.windowScene?.interfaceOrientation ?? .unknown
        safeArea = window.safeAreaInsets
        bodyFrame = frame
        sourceCanvasOwnerView = sourceOwner?.viewIfLoaded
        sourceCanvasOwnerSuperview = sourceCanvasOwnerView?.superview
        sourceCanvasOwnerBounds = sourceCanvasOwnerView?.bounds ?? .zero
        sourceCanvasOwnerCenter = sourceCanvasOwnerView?.center ?? .zero
        sourceCanvasOwnerTransform = sourceCanvasOwnerView?.transform ?? .identity
        targetFooterStaged = false
        targetCanvasFrame = .zero
        frames = 0
        capturedTargetPixels = false
        targetScopeController = nil
        targetOwner = nil
        targetFrame = .zero
        interactiveProgress = 0
        slideOffset = 0
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        surface.accessibilityElementsHidden = true
        surface.backgroundColor = .clear
        capturedPixels = true
        // The fallback is tied to the visible source's role/traits; it cannot
        // introduce a system light background into a dark playback canvas.
        let sourceTraits = UITraitCollection(userInterfaceStyle: sourceScheme == .dark ? .dark : .light)
        let sourceColor = (sourceIsMedia ? UIColor.black : UIColor.systemBackground).resolvedColor(with: sourceTraits)
        tone = sharedTone ?? PageToneTransition(source: Color(uiColor: sourceColor),
                                  sourceScheme: sourceScheme, sourceIsMedia: sourceIsMedia, suspended: true)
        Self.toneContext(in: window).owner = self
        pixels.frame = bodyFrame
        pixels.isUserInteractionEnabled = false
        pixels.accessibilityElementsHidden = true
        surface.addSubview(pixels)
        bodyPixels = pixels
        overlay = surface
        window.addSubview(surface)
        guard self.token == token else { return false }
        if blocksNewTouches {
            let input = PageTransitionInput(token: token)
            interaction = input
            guard input.acquire(in: window, source: .bodyHandoff), self.token == token else { return false }
        }
        keepVisible()
        publish("holding", progress: tone?.clock.progress ?? 0)
        return self.token == token
    }

    private func installCanvasFooter(_ footer: PageReturnFooterPreview?, owner: UIViewController, token: UUID,
                                     targetPreview: Bool = false) {
        guard let footer, let window, let overlay, footer.frame.width > 1, footer.frame.height > 1 else { return }
        let container = footer.surface
        container.frame = footer.canvasFrame
        container.alpha = 1
        if targetPreview { returnFooterExpectedEndpoint = footer.endpoint }
        if let endpoint = footer.endpoint, endpoint.frame.width > 1 {
            let lease = PageBodyViewports.suppressRootFooter(in: window, token: UUID())
            if let lease {
                if targetPreview {
                    if targetFooterRootLease == nil { targetFooterRootLease = lease }
                    else { footerCaptureLeases.append(lease) }
                }
                else { returnFooterRootLease = lease }
            } else if targetPreview {
                returnFooterExpectedEndpoint = nil
            }
        } else if !PageBodyViewports.floatingControlViews(in: owner, kind: .footer, includePresentationFooter: true).isEmpty {
            footerCaptureLeases.append(PageBodyViewports.suppressFloatingControls(in: owner, token: UUID(), includePresentationFooter: true))
        }
        overlay.addSubview(container)
        returnFooterCanvas = container
    }

    @discardableResult
    private func prepareTargetFooter(owner: UIViewController, header: HeaderContent?, token: UUID) -> Bool {
        guard let window else { return false }
        let localFooters = PageBodyViewports.floatingControlViews(in: owner, kind: .footer, includePresentationFooter: true)
        var preview = PageReturnFooterPreview.capture(for: owner, header: header, in: window)
        if preview == nil, localFooters.isEmpty,
           let appearance = header?.appearance,
           let current = PageBodyViewports.rootFooterEndpoint(in: window, includingSuppressed: true),
           let motion = appearance.environment?.tabPageMotion,
           let selected = motion.rootHost?.selected,
           let controls = motion.rootFooterRenderer?(selected, appearance.canvasRole == .playback) {
            let endpoint = RootFooterEndpoint(selectedTab: selected,
                overMedia: appearance.canvasRole == .playback,
                selectionOwner: current.selectionOwner, frame: current.frame)
            preview = PageReturnFooterPreview(controls: controls, frame: current.frame, endpoint: endpoint)
        }

        if let preview {
            returnFooterExpectedEndpoint = preview.endpoint
            targetFooterOwner = owner
            targetFooterDrawable = nil
            targetFooterExpectedSuperview = nil
            targetFooterExpectedFrame = nil
            targetFooterExpectedBounds = nil
            targetFooterExpectedCenter = nil
            targetFooterStableFrame = nil
            returnFooterStableEndpoint = nil
            returnFooterStableFrames = 0; returnFooterWaitFrames = 0
            if let endpoint = preview.endpoint, endpoint.frame.width > 1 {
                let lease = PageBodyViewports.suppressRootFooter(in: window, token: UUID())
                if let lease {
                    if targetFooterRootLease == nil { targetFooterRootLease = lease }
                    else { footerCaptureLeases.append(lease) }
                }
                else if targetFooterRootLease == nil && returnFooterRootLease == nil {
                    returnFooterExpectedEndpoint = nil
                }
            } else if let drawable = localFooters.first {
                targetFooterOwner = owner
                targetFooterDrawable = drawable
                targetFooterExpectedSuperview = drawable.superview
                targetFooterExpectedFrame = drawable.convert(drawable.bounds, to: window)
                targetFooterExpectedBounds = drawable.bounds
                targetFooterExpectedCenter = drawable.center
                footerCaptureLeases.append(PageBodyViewports.suppressFloatingControls(in: owner, token: UUID(), includePresentationFooter: true))
            }
            // Keep one controls-only layer over the canvas. Never snapshot the
            // target page body to obtain its footer.
            preview.surface.frame = preview.canvasFrame
            if returnFooterCanvas !== preview.surface {
                returnFooterCanvas?.removeFromSuperview()
                overlay?.addSubview(preview.surface)
                returnFooterCanvas = preview.surface
            }
            targetFooterStaged = true
            return true
        }

        guard localFooters.isEmpty else { return false }
        if kind == "edge-return", let expected = returnFooterExpectedEndpoint,
           let endpoint = PageBodyViewports.rootFooterEndpoint(in: window, includingSuppressed: true),
           endpoint.selectedTab == expected.selectedTab,
           endpoint.overMedia == expected.overMedia,
           endpoint.selectionOwner == expected.selectionOwner,
           close(endpoint.frame, expected.frame, tolerance: 2) {
            // The return cache supplied the destination footer before its
            // owner became visible; verify the actual root endpoint at stage.
            targetFooterStaged = true
            return true
        }
        returnFooterExpectedEndpoint = nil
        targetFooterRootLease?.release(); targetFooterRootLease = nil
        targetFooterOwner = nil; targetFooterDrawable = nil; targetFooterExpectedSuperview = nil
        targetFooterExpectedFrame = nil; targetFooterExpectedBounds = nil
        targetFooterExpectedCenter = nil; targetFooterStableFrame = nil
        returnFooterCanvas?.removeFromSuperview(); returnFooterCanvas = nil
        targetFooterStaged = true
        return true
    }

    /// Called during target layout, before its first visible frame, so UIKit's
    /// newly attached presentation cannot cover the outgoing body copy.
    func keepVisible() {
        guard let window else { return }
        if let overlay, overlay.superview === window {
            guard geometryMatches(window) else { cancel(); return }
            NativeHeaderMotion.forWindow(window).positionBodyOverlay(overlay)
        }
        if let header = fixedHeaderHost?.view, header.superview === window, window.subviews.last !== header {
            window.bringSubviewToFront(header)
        }
    }

    func attachActivationLease(_ lease: PageVisualActivationLease?) {
        if activationLease !== lease { activationLease?.release() }
        activationLease = lease
    }

    func isPrepared(_ token: UUID) -> Bool {
        self.token == token && (overlay != nil || rootLiveControls)
    }
    func hasCapturedReturnPixels(_ token: UUID) -> Bool {
        self.token == token && kind == "edge-return" && overlay != nil && capturedPixels
    }

    /// A rejected close restores the same visual plane to the still-present source.
    func reclaimPreviewPlane(_ token: UUID, parent: UIView, below source: UIView,
                             frame: CGRect) -> Bool {
        guard self.token == token, kind == "edge-return", let overlay,
              let plane = bodyPixels, source.superview === parent,
              overlay.window === window, frame.width > 1, frame.height > 1 else { return false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plane.transform = .identity
        plane.frame = frame
        parent.insertSubview(plane, belowSubview: source)
        CATransaction.commit()
        guard self.token == token else { return false }
        bodyPixels = nil
        return true
    }


    /// Mount the fixed header copy inside this body's existing visual session.
    /// It shares the body token, tone clock, and interaction lease.
    func installFixedHeader(token: UUID, handoff: HeaderHandoff) {
        guard self.token == token, rootLiveControls,
              let window, geometryMatches(window) else { return }
        if fixedHeaderHandoff === handoff, fixedHeaderHost != nil {
            // The existing host already observes this same reference. Staging
            // a destination needs no new rootView or forced synchronous layout.
            rootLiveTargetMedia = handoff.destination?.appearance.canvasRole == .playback
            keepVisible()
            return
        }
        fixedHeaderHandoff = handoff
        let host: UIHostingController<PageBodyFixedHeaderOverlay>
        if let existing = fixedHeaderHost {
            host = existing
            host.rootView = PageBodyFixedHeaderOverlay(handoff: handoff)
        } else {
            host = UIHostingController(rootView: PageBodyFixedHeaderOverlay(handoff: handoff))
            fixedHeaderHost = host
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.accessibilityElementsHidden = true
            host.view.frame = window.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.alpha = 0
            window.addSubview(host.view)
        }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        rootLiveTargetMedia = handoff.destination?.appearance.canvasRole == .playback
        keepVisible()
    }

    /// The actual controls drawable and this fixed copy exchange visibility
    /// inside the same UIKit transaction. Render ACKs only govern cleanup.
    @discardableResult
    func bindRootHeaderVisibility(_ token: UUID, probe: NativeHeaderProbe,
                                  owner: UIViewController, rootToken: UUID,
                                  isCurrent: @escaping () -> Bool) -> Bool {
        guard self.token == token, rootLiveControls, let window,
              geometryMatches(window), probe.rootToken == rootToken,
              probe.viewIfLoaded?.window === window, probe.belongs(to: owner),
              fixedHeaderHost?.viewIfLoaded?.window === window, isCurrent() else { return false }
        let contentOwner = probe.anchor.appearance?.contentOwner
        rootHeaderVisibilityCancel?()
        rootHeaderVisibilityCancel = probe.observeControlsVisibility(owner: owner, contentOwner: contentOwner,
            window: window, token: token) { [weak self, weak probe, weak owner, weak window] visible in
            guard let self, self.token == token, self.rootLiveControls,
                  let probe, let owner, let window, self.window === window,
                  probe.rootToken == rootToken, probe.belongs(to: owner),
                  probe.viewIfLoaded?.window === window, self.geometryMatches(window),
                  isCurrent() else { return }
            self.fixedHeaderHost?.view.alpha = visible ? 0 : 1
        }
        return true
    }

    /// Record the destination's settled layout before moving the retained roots.
    func stageRootTarget(_ token: UUID, destination: UIViewController) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("targetSnapshot", cost174) }
        #endif
        guard self.token == token, rootLiveControls, let window, geometryMatches(window),
              let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded else { return false }
        targetScopeController = destination
        targetOwner = ObjectIdentifier(geometry.owner)
        targetFrame = view.convert(geometry.rect, to: window)
        rootLiveTargetGeometry = targetFrame
        rootLiveTargetMedia = fixedHeaderHandoff?.destination?.appearance.canvasRole == .playback
        return true
    }

    private func stageLiveCanvasTarget(_ token: UUID, destination: UIViewController) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("targetSnapshot", cost174) }
        #endif
        guard self.token == token, let window, geometryMatches(window),
              let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded, let canvasRect = geometry.canvasRect,
              canvasRect.width > 1, canvasRect.height > 1, view.layer.mask == nil,
              geometry.owner.transitionCoordinator == nil,
              geometry.owner.navigationController?.transitionCoordinator == nil,
              (view.layer.animationKeys()?.isEmpty ?? true) else { return false }
        let readingFrame = view.convert(geometry.rect, to: window)
        let canvasFrame = view.convert(canvasRect, to: window)
        guard canvasFrame.width > 1, canvasFrame.height > 1,
              abs(canvasFrame.width - bodyFrame.width) <= 2,
              abs(canvasFrame.height - bodyFrame.height) <= 2 else { return false }
        targetLiveLease?.restore()
        let navigation = geometry.owner.navigationController
        var lease = LiveTargetLease(owner: geometry.owner, view: view, window: window,
            scene: window.windowScene.map(ObjectIdentifier.init), navigation: navigation,
            navigationTop: navigation?.topViewController, superview: view.superview ?? view,
            bounds: view.bounds, center: view.center, transform: view.transform,
            backgroundColor: view.backgroundColor, accessibilityElementsHidden: view.accessibilityElementsHidden,
            isUserInteractionEnabled: view.isUserInteractionEnabled, assignedTransform: view.transform,
            targetBackgroundColor: nil, assignedBackgroundColor: nil)
        let header = NativeHeaderMotion.forWindow(window).settledContent(for: geometry.owner)
        let targetColor = AppTheme.returnCanvasColor(appearance: header?.appearance
            ?? NativeHeaderMotion.forWindow(window).appearance(for: geometry.owner), in: window)
        lease.targetBackgroundColor = lease.backgroundColor ?? targetColor
        view.accessibilityElementsHidden = true
        view.isUserInteractionEnabled = false
        targetLiveLease = lease
        targetScopeController = destination
        targetOwner = ObjectIdentifier(geometry.owner)
        targetFrame = readingFrame
        targetCanvasFrame = canvasFrame
        capturedTargetPixels = true
        let hasHeader = header != nil
        let stagedControls = NativeHeaderMotion.forWindow(window).stageCanvasControls(token: token, destination: geometry.owner)
        canvasControlsStaged = canvasControlsBegun ? stagedControls : !hasHeader
        guard canvasControlsStaged else { targetLiveLease?.restore(); targetLiveLease = nil; return false }
        guard prepareTargetFooter(owner: geometry.owner, header: header, token: token) else {
            targetLiveLease?.restore(); targetLiveLease = nil
            return false
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let positioned = targetLiveLease?.set(progress: interactiveProgress, direction: interactiveDirection, width: canvasFrame.width) == true
        CATransaction.commit()
        guard positioned else { cancel(reason: "target-view-taken-over-during-stage"); return false }
        keepVisible()
        return targetLiveLease?.isValid() ?? false
    }

    /// The root host moves the retained pages. Fixed chrome uses its progress.
    func updateRootChrome(_ token: UUID, progress: Double) {
        guard self.token == token, rootLiveControls, progress.isFinite else { return }
        interactiveProgress = min(1, max(0, progress))
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("applySlide", cost174) }
        #endif
        fixedHeaderHandoff?.updateRootProgress(interactiveProgress)
        if let source = rootLiveSourceFooter, let target = rootLiveTargetTab {
            rootFooterMotion.update(source: source, targetTab: target, targetMedia: rootLiveTargetMedia,
                                    progress: interactiveProgress)
        }
        publish("interactive", progress: interactiveProgress)
    }

    /// Keep input and fixed chrome until the live target acknowledges its final frame.
    func releaseRootInteractive(_ token: UUID, destination: UIViewController,
                                isCurrent: @escaping () -> Bool,
                                reveal: @escaping () -> Bool,
                                acknowledge: @escaping (NativeHeaderProbe) -> Bool,
                                completion: @escaping (PageVisualOutcome) -> Void) {
        guard self.token == token, rootLiveControls else { completion(.aborted("root-live-token-mismatch")); return }
        guard releaseCompletion == nil else { return }
        releaseCompletion = completion
        guard abs(interactiveProgress - rootLiveEndpointProgress) < 0.0001, fixedHeaderHandoff?.destination != nil,
              interactiveTargetIsValid(token, requestedScope: destination),
              let window, geometryMatches(window) else {
            cancel(reason: "root-live-target-not-ready")
            return
        }
        rootFooterReveal = reveal
        rootFooterAcknowledge = acknowledge
        rootTerminalCommitted = rootLiveEndpointProgress == 1
        rootTerminalIsCurrent = rootTerminalCommitted ? isCurrent : nil
        rootFooterProbe = nil
        rootHeaderRendered = false
        rootFooterRendered = false
        rootHeaderRevealStarted = false
        rootHeaderAckFrames = 0
        boundTerminalHandoff(token)
        #if DEBUG && targetEnvironment(simulator)
        if rootLiveEndpointProgress == 1,
           ProcessInfo.processInfo.arguments.contains("--qa-drop-root-terminal-frame") { return }
        #endif
        frameBoundary?.cancel()
        frameBoundary = RenderFrameBoundary { [weak self, weak destination] in
            guard let self, self.token == token else { return }
            guard let destination, let window = self.window,
                  self.interactiveTargetIsValid(token, requestedScope: destination),
                  self.geometryMatches(window), isCurrent(),
                  self.rootLiveGeometryMatches(destination, in: window),
                  let probe = self.rootHeaderProbe(for: destination, in: window) else {
                self.cancel(reason: "root-live-target-changed-before-fence")
                return
            }
            self.frameBoundary = nil
            self.rootFooterProbe = probe
            self.watchRootHeaderAcknowledgement(token, destination: destination, isCurrent: isCurrent)
        }
    }

    @discardableResult
    func prepareRootRebound(_ token: UUID, source: UIViewController, header: HeaderContent) -> Bool {
        guard self.token == token, rootLiveControls, let footer = rootLiveSourceFooter,
              let handoff = fixedHeaderHandoff, handoff.stageRoot(header) else { return false }
        rootLiveTargetTab = footer.selectedTab
        rootLiveTargetMedia = footer.overMedia
        rootLiveEndpointProgress = 0
        interactiveProgress = 0
        guard stageRootTarget(token, destination: source) else { return false }
        installFixedHeader(token: token, handoff: handoff)
        return true
    }

    private func watchRootHeaderAcknowledgement(_ token: UUID, destination: UIViewController,
                                                isCurrent: @escaping () -> Bool) {
        guard self.token == token, releaseCompletion != nil else { return }
        guard let window = self.window, self.geometryMatches(window),
              self.interactiveTargetIsValid(token, requestedScope: destination), isCurrent(),
              self.rootLiveGeometryMatches(destination, in: window) else {
            self.cancel(reason: "root-live-header-scope-invalid")
            return
        }
        self.rootHeaderAckFrames += 1
        guard self.rootHeaderAckFrames < 12 else {
            self.cancel(reason: "root-live-header-ack-timeout")
            return
        }
        guard let probe = self.rootFooterProbe,
              self.rootHeaderProbe(for: destination, in: window) === probe else {
            self.cancel(reason: "root-live-header-probe-changed")
            return
        }
        // The footer endpoint is the actual root control marker, not the
        // fixed handoff copy. A display-link callback has already crossed one
        // rendered frame, so a matching endpoint is sufficient; the old
        // two-consecutive-frame rule added a serial fence after header
        // readiness without proving a stronger invariant.
        self.rootFooterRendered = self.rootLiveFooterEndpoint(in: window) != nil
        if !self.rootHeaderRevealStarted {
            guard let reveal = self.rootFooterReveal, reveal(),
                  let owner = PageViewportGeometry.owner(of: probe),
                  self.rootFooterAcknowledge != nil else {
                self.cancel(reason: "root-live-header-reveal-rejected")
                return
            }
            self.rootHeaderRevealStarted = true
            self.rootHeaderReadinessCancel = probe.afterLiveControlsRendered(
                owner: owner, contentOwner: self.fixedHeaderHandoff?.destination?.appearance.contentOwner,
                window: window
            ) { [weak self, weak destination, weak probe, weak window] ready in
                guard let self, self.token == token else { return }
                guard self.releaseCompletion != nil, let destination, let probe, let window,
                      self.interactiveTargetIsValid(token, requestedScope: destination),
                      self.geometryMatches(window), isCurrent(), ready,
                      self.rootLiveGeometryMatches(destination, in: window),
                      self.rootHeaderProbe(for: destination, in: window) === probe else {
                    self.cancel(reason: "root-live-header-ack-invalid")
                    return
                }
                // Header readiness and footer endpoint observation run in
                // parallel. Recheck the footer at the exact completion
                // boundary so a stale old footer can never unlock input.
                self.rootHeaderRendered = true
                self.rootFooterRendered = self.rootLiveFooterEndpoint(in: window) != nil
                self.completeRootTerminalIfReady(token, probe: probe, destination: destination,
                                                 isCurrent: isCurrent)
            }
        }
        self.completeRootTerminalIfReady(token, probe: probe, destination: destination,
                                         isCurrent: isCurrent)
        guard self.releaseCompletion != nil else { return }
        // Only a missing half of the shared terminal state needs another
        // frame. There is no second stability fence after live controls ack.
        #if DEBUG && targetEnvironment(simulator)
        if heldSearchTerminalForQA == token { return }
        #endif
        self.rootHeaderAckBoundary = RenderFrameBoundary { [weak self] in
            guard let self, self.token == token, self.releaseCompletion != nil else { return }
            self.rootHeaderAckBoundary = nil
            self.watchRootHeaderAcknowledgement(token, destination: destination, isCurrent: isCurrent)
        }
    }

    private func completeRootTerminalIfReady(_ token: UUID, probe: NativeHeaderProbe,
                                             destination: UIViewController,
                                             isCurrent: @escaping () -> Bool) {
        guard self.token == token, releaseCompletion != nil,
              rootHeaderRendered, rootFooterRendered,
              let window, geometryMatches(window), isCurrent(),
              interactiveTargetIsValid(token, requestedScope: destination),
              rootLiveGeometryMatches(destination, in: window),
              rootHeaderProbe(for: destination, in: window) === probe,
              rootLiveFooterEndpoint(in: window) != nil,
              let acknowledge = rootFooterAcknowledge else { return }
        #if DEBUG && targetEnvironment(simulator)
        if rootLiveEndpointProgress == 1, rootLiveTargetTab == RootTab.search.rawValue,
           ProcessInfo.processInfo.arguments.contains("--qa-delay-search-terminal196"),
           releasedSearchTerminalForQA != token {
            guard heldSearchTerminalForQA != token else { return }
            heldSearchTerminalForQA = token
            rootHeaderAckBoundary?.cancel(); rootHeaderAckBoundary = nil
            terminalHandoffDeadline?.cancel(); terminalHandoffDeadline = nil
            boundTerminalHandoff(token, timeout: .seconds(8))
            publish("waiting-search-terminal196", progress: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak probe, weak destination] in
                guard let self, let probe, let destination, self.token == token else { return }
                self.releasedSearchTerminalForQA = token
                self.completeRootTerminalIfReady(token, probe: probe, destination: destination, isCurrent: isCurrent)
            }
            return
        }
        #endif
        guard acknowledge(probe) else { cancel(reason: "root-footer-endpoint-ack-rejected"); return }
        rootHeaderAckBoundary?.cancel(); rootHeaderAckBoundary = nil
        rootHeaderReadinessCancel?(); rootHeaderReadinessCancel = nil
        publish("root-live-header", progress: 1)
        publish(rootLiveEndpointProgress == 0 ? "cancelled" : "completed", progress: rootLiveEndpointProgress)
        remove(outcome: .completed)
    }

    private func rootLiveGeometryMatches(_ destination: UIViewController, in window: UIWindow) -> Bool {
        guard self.window === window, targetScopeController === destination,
              let expected = rootLiveTargetGeometry,
              let geometry = resolvedGeometry(for: destination, in: window),
              targetOwner == ObjectIdentifier(geometry.owner),
              let ownerView = geometry.owner.viewIfLoaded else { return false }
        let actual = ownerView.convert(geometry.rect, to: window)
        return close(actual, expected, tolerance: 2)
    }

    private func rootLiveFooterEndpoint(in window: UIWindow) -> RootFooterEndpoint? {
        guard rootLiveControls, let expectedTab = rootLiveTargetTab,
              let source = rootLiveSourceFooter,
              let endpoint = PageBodyViewports.rootFooterEndpoint(in: window),
              endpoint.selectedTab == expectedTab, endpoint.overMedia == rootLiveTargetMedia,
              endpoint.frame.width > 1, endpoint.frame.height > 1,
              close(endpoint.frame, source.frame, tolerance: 2) else { return nil }
        return endpoint
    }

    /// Keep the transition shield in place while allowing only the real root
    /// footer to receive a touch during the committed terminal tail. The
    /// callback is installed on the same body lease and is disabled whenever
    /// another lease shares the window, so no other transition surface leaks
    /// input through the blocker.
    private func rootTerminalHitTarget(_ token: UUID, in window: UIWindow,
                                       point: CGPoint, event: UIEvent?) -> UIView? {
        guard self.token == token, rootLiveControls, rootTerminalCommitted,
              releaseCompletion != nil,
              self.window === window,
              window.windowScene?.activationState == .foregroundActive,
              rootTerminalIsCurrent?() == true,
              let destination = targetScopeController,
              destination.viewIfLoaded?.window === window,
              geometryMatches(window),
              rootLiveGeometryMatches(destination, in: window),
              let endpoint = rootLiveFooterEndpoint(in: window),
              endpoint.selectionOwner == nil,
              endpoint.frame.contains(point),
              let drawable = PageBodyViewports.rootFooterControl(in: window),
              drawable.isDrawable,
              let host = drawable.view,
              host.window === window else { return nil }
        let frame = host.convert(host.bounds, to: window)
        guard frame.contains(point) else { return nil }
        return host.hitTest(host.convert(point, from: window), with: event)
    }

    private func close(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private func rootHeaderProbe(for destination: UIViewController, in window: UIWindow) -> NativeHeaderProbe? {
        guard let geometry = resolvedGeometry(for: destination, in: window),
              let expected = fixedHeaderHandoff?.destination else { return nil }
        var pending = [destination]
        while let owner = pending.popLast() {
            if let probe = owner as? NativeHeaderProbe,
               PageViewportGeometry.owner(of: probe) === geometry.owner,
               let current = probe.currentHeader ?? probe.settledHeader,
               abs(current.frame.minX - expected.frame.minX) <= 2,
               abs(current.frame.minY - expected.frame.minY) <= 2,
               abs(current.frame.width - expected.frame.width) <= 2,
               abs(current.frame.height - expected.frame.height) <= 1,
               current.appearance.contentOwner == expected.appearance.contentOwner,
               current.appearance.layoutIdentity == expected.appearance.layoutIdentity,
               current.appearance.canvasRole == expected.appearance.canvasRole,
               current.appearance.colorScheme == expected.appearance.colorScheme {
                return probe
            }
            pending.append(contentsOf: owner.children)
        }
        return nil
    }

    private func resolvedGeometry(for destination: UIViewController, in window: UIWindow) -> PageBodyViewports.Geometry? {
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("geometry", cost174) }
        #endif
        guard let geometry = PageBodyViewports.geometry(containing: destination),
              let ownerView = geometry.owner.viewIfLoaded, ownerView.window === window,
              geometry.owner.navigationController.map({ $0.topViewController === geometry.owner }) ?? true else { return nil }
        return geometry
    }

    private func interactiveTargetIsValid(_ token: UUID, requestedScope: UIViewController? = nil) -> Bool {
        guard self.token == token, let window, geometryMatches(window),
              let scope = targetScopeController,
              requestedScope.map({ $0 === scope }) ?? true,
              let geometry = resolvedGeometry(for: scope, in: window),
              targetOwner == ObjectIdentifier(geometry.owner) else { return false }
        if !rootLiveControls, kind != "edge-return" {
            return targetLiveLease?.isValid() == true
        }
        return true
    }

    private func positionCover(progress: Double, direction: CGFloat) {
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("applySlide", cost174) }
        #endif
        let p = CGFloat(min(1, max(0, progress)))
        guard let bodyPixels else { return }
        let signedDirection: CGFloat = direction < 0 ? -1 : 1
        guard targetLiveLease?.isValid() == true else {
            cancel(reason: "target-view-taken-over-during-motion")
            return
        }
        bodyPixels.alpha = 1
        bodyPixels.transform = CGAffineTransform(translationX: signedDirection * bodyFrame.width * p, y: 0)
        if targetLiveLease?.set(progress: p, direction: signedDirection, width: targetCanvasFrame.width) != true {
            cancel(reason: "target-view-taken-over-during-motion")
            return
        }
        if canvasControlsBegun, let token, let window {
            NativeHeaderMotion.forWindow(window).updateCanvasControls(token: token, progress: Double(p))
        }
        slideOffset = signedDirection * bodyFrame.width * p
    }

    /// The edge is already at rest. Prepare its actual target and start the
    /// shared tone without withdrawing the promoted body before header resize.
    func startReturnTone(_ token: UUID, destination: UIViewController) -> Bool {
        guard kind == "edge-return", self.token == token, let window,
              overlay != nil,
              let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded, let canvasRect = geometry.canvasRect else { return false }
        targetScopeController = destination
        targetOwner = ObjectIdentifier(geometry.owner)
        targetFrame = view.convert(geometry.rect, to: window)
        targetCanvasFrame = view.convert(canvasRect, to: window)
        let motion = NativeHeaderMotion.forWindow(window)
        let header = motion.settledContent(for: geometry.owner)
        if !canvasControlsStaged {
            let staged = canvasControlsBegun && motion.stageCanvasControls(token: token, destination: geometry.owner)
            canvasControlsStaged = canvasControlsBegun ? staged : header == nil
        }
        guard canvasControlsStaged else { return false }
        if !targetFooterStaged, !prepareTargetFooter(owner: geometry.owner, header: header, token: token) {
            return false
        }
        motion.updateCanvasControls(token: token, progress: 1)
        publish("handoff", progress: 1)
        return self.token == token
    }

    /// Keep the promoted body until the committed destination can take over.
    @discardableResult
    func awaitCommittedReturnHandoff(_ token: UUID, completion: @escaping (PageVisualOutcome) -> Void) -> Bool {
        guard self.token == token, kind == "edge-return", overlay != nil else { return false }
        self.completion = completion
        boundTerminalHandoff(token, timeout: .milliseconds(900))
        return true
    }

    func finishReturnReveal(_ token: UUID, destination: UIViewController) {
        guard self.token == token, kind == "edge-return", overlay != nil else { return }
        guard startReturnTone(token, destination: destination) else {
            cancel(reason: "return-target-stage-failed")
            return
        }
        guard interactiveTargetIsValid(token, requestedScope: destination),
              let window, window.windowScene?.activationState == .foregroundActive,
              let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded, let canvasRect = geometry.canvasRect else {
            cancel(reason: "return-target-changed-before-terminal"); return
        }
        let currentFrame = view.convert(geometry.rect, to: window)
        guard abs(currentFrame.minX - targetFrame.minX) <= 2,
              abs(currentFrame.width - targetFrame.width) <= 2,
              abs(currentFrame.minY - targetFrame.minY) <= 2,
              abs(currentFrame.height - targetFrame.height) <= 2,
              close(view.convert(canvasRect, to: window), targetCanvasFrame, tolerance: 2) else {
            cancel(reason: "return-viewport-changed-before-terminal"); return
        }
        prepareCanvasTerminal(token, destination: destination)
    }

    private func waitForReturnFooter(_ token: UUID) {
        guard self.token == token, let window,
              returnFooterExpectedEndpoint != nil || targetFooterDrawable != nil else {
            cancel(reason: "return-footer-owner-missing-at-terminal"); return
        }
        returnFooterBoundary?.cancel()
        returnFooterBoundary = RenderFrameBoundary { [weak self] in
            guard let self, self.token == token, let window = self.window else { return }
            self.returnFooterBoundary = nil
            self.returnFooterWaitFrames += 1
            var matches = false
            if let expected = self.returnFooterExpectedEndpoint {
                let endpoint = PageBodyViewports.rootFooterEndpoint(in: window, includingSuppressed: true)
                matches = endpoint.map {
                    $0.selectedTab == expected.selectedTab &&
                    $0.overMedia == expected.overMedia &&
                    $0.selectionOwner == expected.selectionOwner &&
                    self.close($0.frame, expected.frame, tolerance: 2)
                } ?? false
                if matches, endpoint == self.returnFooterStableEndpoint {
                    self.returnFooterStableFrames += 1
                } else {
                    self.returnFooterStableEndpoint = matches ? endpoint : nil
                    self.returnFooterStableFrames = matches ? 1 : 0
                }
            } else {
                guard let owner = self.targetFooterOwner, let drawable = self.targetFooterDrawable,
                      let expectedFrame = self.targetFooterExpectedFrame,
                      let expectedBounds = self.targetFooterExpectedBounds,
                      let expectedCenter = self.targetFooterExpectedCenter,
                      owner.viewIfLoaded?.window === window,
                      drawable.window === window, drawable.superview === self.targetFooterExpectedSuperview,
                      drawable.bounds == expectedBounds, drawable.center == expectedCenter,
                      self.close(drawable.convert(drawable.bounds, to: window), expectedFrame, tolerance: 2) else {
                    matches = false
                    self.targetFooterStableFrame = nil
                    self.returnFooterStableFrames = 0
                    if self.returnFooterWaitFrames >= 12 { self.cancel(reason: "return-footer-endpoint-not-stable") }
                    else { self.waitForReturnFooter(token) }
                    return
                }
                matches = true
                if let stable = self.targetFooterStableFrame, self.close(stable, expectedFrame, tolerance: 0.5) {
                    self.returnFooterStableFrames += 1
                } else {
                    self.targetFooterStableFrame = expectedFrame
                    self.returnFooterStableFrames = 1
                }
            }
            if matches, self.returnFooterStableFrames >= 2 {
                #if DEBUG && targetEnvironment(simulator)
                if let confirmation = self.returnFooterProtectionQA {
                    self.returnFooterProtectionQA = nil
                    let copy = self.returnFooterCanvas
                    let copyIsFixed = copy.map {
                        $0.window === window && $0.superview === self.overlay && $0.transform == .identity
                    } ?? false
                    let holdsControls = self.returnFooterRootLease != nil || self.targetFooterRootLease != nil || !self.footerCaptureLeases.isEmpty
                    confirmation(token, copyIsFixed && holdsControls)
                }
                #endif
                let ready = self.returnFooterCompletion; self.returnFooterCompletion = nil
                ready?()
            } else if self.returnFooterWaitFrames >= 12 {
                self.cancel(reason: "return-footer-endpoint-not-stable")
            } else {
                self.waitForReturnFooter(token)
            }
        }
    }

    private func completeReturnReveal(_ token: UUID) {
        guard self.token == token else { return }
        publish("completed", progress: 1)
        remove(outcome: .completed)
    }

    private func prepareCanvasTerminal(_ token: UUID, destination: UIViewController) {
        guard self.token == token else { return }
        guard overlay != nil, let window,
              interactiveTargetIsValid(token, requestedScope: destination),
              window.windowScene?.activationState == .foregroundActive,
              let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded, let canvasRect = geometry.canvasRect,
              targetFooterStaged else {
            cancel(reason: "canvas-terminal-owner-invalid")
            return
        }
        let currentReading = view.convert(geometry.rect, to: window)
        let currentCanvas = view.convert(canvasRect, to: window)
        let targetLeaseValid = targetLiveLease.map { $0.isValid() } ?? (kind == "edge-return")
        guard close(currentReading, targetFrame, tolerance: 2),
              close(currentCanvas, targetCanvasFrame, tolerance: 2),
              targetLeaseValid else {
            cancel(reason: "canvas-terminal-geometry-changed")
            return
        }
        boundTerminalHandoff(token)
        let revealControls: (Bool) -> Void = { [weak self, weak destination, weak window, weak owner = geometry.owner] ready in
            guard let self, let destination, let window, let owner, self.token == token,
                  self.window === window else { return }
            guard ready, self.interactiveTargetIsValid(token, requestedScope: destination) else {
                self.cancel(reason: "canvas-controls-not-ready")
                return
            }
            if self.returnFooterExpectedEndpoint != nil || self.targetFooterDrawable != nil {
                self.returnFooterCompletion = { [weak self] in self?.completeReturnReveal(token) }
                self.waitForReturnFooter(token)
            } else {
                self.completeReturnReveal(token)
            }
        }
        guard canvasControlsBegun else { revealControls(true); return }
        NativeHeaderMotion.forWindow(window).prepareCanvasControlsForReveal(token: token,
            destination: geometry.owner, completion: revealControls)
    }

    func reveal(_ token: UUID, destination: UIViewController?, direction: CGFloat? = nil,
                completion: ((PageVisualOutcome) -> Void)? = nil) {
        guard self.token == token, overlay != nil else { completion?(.aborted("missing-prepared-body")); return }
        if let completion { self.completion = completion }
        guard let destination, let window, geometryMatches(window),
              resolvedGeometry(for: destination, in: window) != nil else { cancel(reason: "target-not-ready"); return }
        let motionDirection = direction ?? (kind == "return" ? 1 : -1)
        interactiveDirection = motionDirection < 0 ? -1 : 1
        keepVisible()
        if kind == "edge-return" { publish("handoff", progress: interactiveProgress) }
        frameBoundary?.cancel()
        frameBoundary = RenderFrameBoundary { [weak self, weak destination] in
            guard let self, self.token == token else { return }
            self.frameBoundary = nil
            guard let destination, let window = self.window,
                  self.resolvedGeometry(for: destination, in: window) != nil else {
                self.cancel(reason: "target-changed-before-frame"); return
            }
            if self.kind == "edge-return" {
                guard self.startReturnTone(token, destination: destination) else {
                    self.cancel(reason: "return-target-stage-failed"); return
                }
                guard self.interactiveTargetIsValid(token, requestedScope: destination),
                      let geometry = self.resolvedGeometry(for: destination, in: window),
                      let view = geometry.owner.viewIfLoaded, let canvasRect = geometry.canvasRect else {
                    self.cancel(reason: "return-target-unavailable-at-terminal"); return
                }
                let actual = view.convert(geometry.rect, to: window)
                guard self.close(actual, self.targetFrame, tolerance: 2),
                      self.close(view.convert(canvasRect, to: window), self.targetCanvasFrame, tolerance: 2) else {
                    self.cancel(reason: "return-reading-frame-changed-at-terminal"); return
                }
                self.interactiveProgress = 1
                self.prepareCanvasTerminal(token, destination: destination)
                return
            }
            let staged = self.stageLiveCanvasTarget(token, destination: destination)
            guard self.token == token else { return }
            guard staged, let owner = self.resolvedGeometry(for: destination, in: window)?.owner else {
                self.cancel(reason: "target-canvas-unavailable"); return
            }
            self.startRevealAnimation(token, destination: destination, owner: owner)
        }
    }

    private func startRevealAnimation(_ token: UUID, destination: UIViewController, owner targetOwner: UIViewController) {
        let targetStyle = targetOwner.traitCollection.userInterfaceStyle
        let duration = 0.26
        animator = RenderProgressAnimation(duration: duration) { [weak self, weak targetOwner] elapsed in
            guard let self, self.token == token else { return }
            guard let window = self.window, let targetOwner, self.geometryMatches(window),
                  targetOwner.traitCollection.userInterfaceStyle == targetStyle else {
                self.cancel(reason: "target-style-or-scope-changed"); return
            }
            guard self.targetLiveLease?.owner === targetOwner,
                  self.targetLiveLease?.isValid() == true else {
                self.cancel(reason: "target-view-taken-over-during-motion"); return
            }
            self.frames += 1
            let slideProgress = UnitCurve.easeInOut.value(at: min(1, max(0, elapsed / duration)))
            self.interactiveProgress = slideProgress
            self.positionCover(progress: slideProgress, direction: self.interactiveDirection)
            self.publish("revealing", progress: slideProgress)
        } completion: { [weak self] in
            guard let self, self.token == token else { return }
            self.interactiveProgress = 1
            self.positionCover(progress: 1, direction: self.interactiveDirection)
            self.prepareCanvasTerminal(token, destination: destination)
        }
    }

    private func geometryMatches(_ window: UIWindow) -> Bool {
        guard window.bounds == bounds, window.safeAreaInsets == safeArea,
              window.windowScene?.interfaceOrientation == orientation else { return false }
        guard !rootLiveControls, kind == "entry" else { return true }
        guard let view = sourceCanvasOwnerView, view.window != nil else { return true }
        guard view.window === window,
              view.superview === sourceCanvasOwnerSuperview,
              view.bounds == sourceCanvasOwnerBounds, view.center == sourceCanvasOwnerCenter,
              view.transform == sourceCanvasOwnerTransform else { return false }
        return true
    }

    private func boundTerminalHandoff(_ token: UUID, timeout: Duration = .milliseconds(500)) {
        guard self.token == token, terminalHandoffDeadline == nil else { return }
        // The animation has reached its endpoint. Render fences still
        // confirm the live controls, but no frame callback is guaranteed.
        terminalHandoffDeadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.token == token else { return }
            self.cancel(reason: "terminal-handoff-timeout")
        }
    }

    func cancel(reason: String = "cancelled") {
        cancellationReason = reason
        let outcome: PageVisualOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
        if token != nil { publish("cancelled", progress: interactiveProgress) }
        let cancelCapture = pendingCanvasCaptureCancel; pendingCanvasCaptureCancel = nil
        pendingCanvasToken = nil
        let prepareCallback = pendingPrepareCompletion; pendingPrepareCompletion = nil
        cancelCapture?()
        prepareCallback?(false)
        remove(outcome: outcome)
    }

    private func remove(outcome: PageVisualOutcome?) {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        let completedEntryCanvas = outcome == .completed && kind == "entry" ? pendingEntryCanvas : nil
        let completedEntryIdentity = pendingEntryCanvasIdentity
        let completedEntryWindow = pendingEntryCanvasWindow
        let cleanupToken = token
        token = nil
        let cleanupWindow = window
        terminalHandoffDeadline?.cancel(); terminalHandoffDeadline = nil
        #if DEBUG && targetEnvironment(simulator)
        returnFooterProtectionQA = nil
        #endif
        frameBoundary?.cancel(); frameBoundary = nil
        returnFooterBoundary?.cancel(); returnFooterBoundary = nil
        returnFooterCompletion = nil
        rootHeaderAckBoundary?.cancel(); rootHeaderAckBoundary = nil
        rootHeaderAckFrames = 0
        let cancelRootHeaderReadiness = rootHeaderReadinessCancel; rootHeaderReadinessCancel = nil
        cancelRootHeaderReadiness?()
        rootHeaderVisibilityCancel?(); rootHeaderVisibilityCancel = nil
        animator?.cancel(); animator = nil
        fixedHeaderHost?.view.removeFromSuperview()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        returnFooterCanvas?.removeFromSuperview(); returnFooterCanvas = nil
        returnFooterRootLease?.release(); returnFooterRootLease = nil
        targetFooterRootLease?.release(); targetFooterRootLease = nil
        footerCaptureLeases.forEach { $0.release() }; footerCaptureLeases.removeAll()
        targetLiveLease?.restore(); targetLiveLease = nil
        bodyPixels?.transform = .identity
        bodyPixels?.frame = bodyFrame
        if let cleanupToken, canvasControlsBegun, let cleanupWindow {
            NativeHeaderMotion.forWindow(cleanupWindow).consumeCanvasControls(token: cleanupToken)
        }
        activationLease?.release(); activationLease = nil
        overlay?.removeFromSuperview(); overlay = nil; bodyPixels = nil
        CATransaction.commit()
        if let canvas = completedEntryCanvas, let cacheWindow = completedEntryWindow {
            canvas.pixels.transform = .identity
            canvas.pixels.frame = canvas.frame
            PageEdgeReturnPolicy.cachePreparedCanvas(canvas, identity: completedEntryIdentity, window: cacheWindow)
        }
        returnFooterExpectedEndpoint = nil; returnFooterStableEndpoint = nil
        returnFooterStableFrames = 0; returnFooterWaitFrames = 0
        targetFooterOwner = nil; targetFooterDrawable = nil; targetFooterExpectedSuperview = nil
        targetFooterExpectedFrame = nil; targetFooterExpectedBounds = nil
        targetFooterExpectedCenter = nil; targetFooterStableFrame = nil; targetFooterStaged = false
        fixedHeaderHost = nil
        rootLiveControls = false; rootLiveTargetGeometry = nil
        rootLiveEndpointProgress = 1
        rootLiveSourceFooter = nil; rootLiveTargetTab = nil; rootLiveTargetMedia = false
        rootFooterMotion.clear()
        rootFooterProbe = nil
        rootFooterReveal = nil; rootFooterAcknowledge = nil
        rootHeaderRendered = false; rootFooterRendered = false; rootHeaderRevealStarted = false
        rootTerminalCommitted = false; rootTerminalIsCurrent = nil
        fixedHeaderHandoff = nil
        if let cleanupToken { interaction?.release(cleanupToken) }
        interaction = nil
        if let window {
            if Self.owners.object(forKey: window) === self { Self.owners.removeObject(forKey: window) }
            let context = Self.toneContext(in: window)
            if context.owner === self { context.owner = nil }
        }
        tone?.clock.finish(); tone = nil
        token = nil
        window = nil
        targetScopeController = nil
        targetOwner = nil
        targetFrame = .zero
        bodyFrame = .zero; targetCanvasFrame = .zero
        sourceCanvasOwnerView = nil; sourceCanvasOwnerSuperview = nil
        sourceCanvasOwnerBounds = .zero; sourceCanvasOwnerCenter = .zero
        sourceCanvasOwnerTransform = .identity
        pendingEntryCanvas = nil; pendingEntryCanvasIdentity = nil; pendingEntryCanvasWindow = nil
        targetLiveLease = nil
        canvasControlsBegun = false; canvasControlsStaged = false
        interactiveProgress = 0
        slideOffset = 0
        let settled = completion
        completion = nil
        if let outcome { settled?(outcome) }
        let didRelease = releaseCompletion
        releaseCompletion = nil
        didRelease?(outcome ?? .aborted("interactive-session-removed"))
    }

    #if DEBUG && targetEnvironment(simulator)
    private func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
    #endif

    private func publish(_ phase: String, progress: Double) {
        #if DEBUG && targetEnvironment(simulator)
        Self.qaState = (kind, phase)
        if ProcessInfo.processInfo.arguments.contains("--qa-body-identity164") {
            NotificationCenter.default.post(name: Self.qaStateDidChange, object: nil,
                                            userInfo: ["kind": kind, "phase": phase])
        }
        guard ProcessInfo.processInfo.arguments.contains("--qa-body-motion"), let window else { return }
        if readback?.superview !== window {
            window.subviews.filter { $0.accessibilityIdentifier == "body.motion.qa" }.forEach { $0.removeFromSuperview() }
            let label = UILabel(frame: CGRect(x: 1, y: window.bounds.height - 1, width: 1, height: 1))
            label.textColor = .clear; label.font = .systemFont(ofSize: 1)
            label.isUserInteractionEnabled = false; label.isAccessibilityElement = true
            label.accessibilityIdentifier = "body.motion.qa"
            window.addSubview(label); readback = label
        }
        residentPeak = max(residentPeak, residentMiB())
        if phase == "completed" || phase == "cancelled" {
            NSLog("BODY_PERF kind=\(kind);phase=\(phase);frames=\(frames);slideOffset=\(slideOffset);sourceBandOffset=0;targetBandOffset=0;settleFrames=0;sourceHeaderSnapshot=false;targetHeaderSnapshot=false;residentPeakMiB=\(residentPeak);residentDeltaMiB=\(residentPeak - residentBefore)")
        }
        readback?.accessibilityValue = "kind=\(kind);phase=\(phase);reason=\(cancellationReason);progress=\(progress);frames=\(frames);slideOffset=\(slideOffset);sourceBandOffset=0;targetBandOffset=0;settleFrames=0;snapshotAvailable=\(capturedPixels ? 1 : 0);targetSnapshotAvailable=\(capturedTargetPixels ? 1 : 0);sourceHeaderSnapshot=0;targetHeaderSnapshot=0;liveBody=0;top=\(bodyFrame.minY);bottom=\(bodyFrame.maxY)"
        #endif
    }
}

@MainActor private struct PageBodyFixedHeaderOverlay: View {
    let handoff: HeaderHandoff

    var body: some View {
        HeaderHandoffView(handoff: handoff)
            .offset(x: handoff.source.frame.minX, y: handoff.source.frame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
