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
    private(set) var tone: PageToneTransition?
    private static var contextKey: UInt8 = 0
    private static let owners = NSMapTable<UIWindow, PageBodyHandoff>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private weak var window: UIWindow?
    private var token: UUID?
    private var overlay: UIView?
    private weak var bodyPixels: UIView?
    private weak var targetPixels: UIView?
    private var returnHeaderBand: UIView?
    private var returnHeaderBandRelease: (() -> Void)?
    private weak var sourceHeaderBandPixels: UIView?
    private weak var targetHeaderBandPixels: UIView?
    private weak var toneHeaderBand: UIView?
    private weak var targetScopeController: UIViewController?
    private var targetOwner: ObjectIdentifier?
    private var targetFrame = CGRect.zero
    private var fixedHeaderHost: UIHostingController<PageBodyFixedHeaderOverlay>?
    private var fixedHeaderHandoff: HeaderHandoff?
    private var safeAreaViews: [UIView] = []
    private var returnFooterCanvas: UIView?
    private var rootSourceCanvas: UIView?
    private var rootTargetCanvas: UIView?
    private var rootSourceFooter: UIImageView?
    private var rootTargetFooter: UIImageView?
    private var rootBodyClip: UIView?
    private var rootFooterFrame: CGRect?
    private var rootTargetBodyStart: CGFloat = 0
    private var rootTargetBodyEnd: CGFloat = 0

    private var destinationCanvasColor: UIColor?
    private var sourceCanvasColor = UIColor.systemBackground
    private var frameBoundary: RenderFrameBoundary?
    private var animator: RenderProgressAnimation?
    private var settleCompletion: ((Bool) -> Void)?
    private var releaseCompletion: ((PageVisualOutcome) -> Void)?
    private var liveBodyCompletion: ((Bool) -> Void)?
    private var bodyHandedToLivePage = false
    private var interaction: PageInteractionShield.Lease?
    private var completion: ((PageVisualOutcome) -> Void)?
    private var bounds = CGRect.zero
    private var orientation = UIInterfaceOrientation.unknown
    private var safeArea = UIEdgeInsets.zero
    private var bodyFrame = CGRect.zero
    private var capturedPixels = false
    private var capturedTargetPixels = false
    private var capturedSourceHeaderPixels = false
    private var capturedTargetHeaderPixels = false
    private var interactiveProgress = 0.0
    private var interactiveDirection: CGFloat = -1
    private var motionAccepted = false
    private var settleFrames = 0
    private var slideOffset: CGFloat = 0
    private var sourceBandOffset: CGFloat = 0
    private var targetBandOffset: CGFloat = 0
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
    static var qaState: (kind: String, phase: String)?
    static let qaStateDidChange = Notification.Name("CivitBodyMotionQAStateChanged")
    #endif

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

    func prepare(_ token: UUID, source: UIViewController?, kind: String, enabled: Bool, fallback: UIColor, sourceScheme: ColorScheme, sourceIsMedia: Bool) {
        cancel()
        #if DEBUG && targetEnvironment(simulator)
        let captureStarted = CACurrentMediaTime()
        residentBefore = residentMiB()
        residentPeak = residentBefore
        #endif
        guard enabled, let source, let geometry = PageBodyViewports.geometry(containing: source),
              let view = geometry.owner.viewIfLoaded, let window = view.window,
              window.windowScene?.activationState == .foregroundActive, view.layer.mask == nil else { return }
        let rect = geometry.rect
        let isRoot = kind == "tab" || kind == "tab-edge"
        let capture = isRoot ? rootCaptureRect(body: rect, view: view, window: window) : rect
        let body = view.resizableSnapshotView(from: capture, afterScreenUpdates: false, withCapInsets: .zero)
        install(token, window: window, frame: view.convert(rect, to: window), pixels: body,
                kind: kind, fallback: fallback, sourceScheme: sourceScheme, sourceIsMedia: sourceIsMedia)
        if isRoot { bodyPixels?.frame = view.convert(capture, to: window) }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-body-motion") {
            NSLog("BODY_PERF capture_ms=\((CACurrentMediaTime() - captureStarted) * 1000);pixels=\(capturedPixels);width=\(rect.width);height=\(rect.height);residentBeforeMiB=\(residentBefore)")
        }
        #endif
    }

    @discardableResult
    func refreshRootSource(_ token: UUID, source: UIViewController) -> Bool {
        guard self.token == token, rootSourceCanvas != nil,
              let window, geometryMatches(window), let clip = rootBodyClip,
              let geometry = resolvedGeometry(for: source, in: window), let view = geometry.owner.viewIfLoaded else { return false }
        let capture = rootCaptureRect(body: geometry.rect, view: view, window: window)
        guard let pixels = view.resizableSnapshotView(from: capture, afterScreenUpdates: false, withCapInsets: .zero) else { return false }
        pixels.frame = view.convert(capture, to: window)
        pixels.isUserInteractionEnabled = false; pixels.accessibilityElementsHidden = true
        clip.addSubview(pixels)
        bodyPixels?.removeFromSuperview(); bodyPixels = pixels
        capturedPixels = true
        return true
    }

    /// Promote only the visible destination body copy before its old UIKit
    /// parent is removed. The reusable whole-page cache remains untouched.
    func preparePreview(_ token: UUID, snapshot: UIView, frame: CGRect, in window: UIWindow,
                        sourceScheme: ColorScheme, sourceIsMedia: Bool, sharedTone: PageToneTransition? = nil) {
        cancel()
        guard snapshot.window === window, window.windowScene?.activationState == .foregroundActive,
              frame.width > 1, frame.height > 1 else { return }
        var pixels = snapshot.resizableSnapshotView(from: snapshot.convert(frame, from: window),
                                                    afterScreenUpdates: false, withCapInsets: .zero)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-return-promotion-fails172") { pixels = nil }
        #endif
        install(token, window: window, frame: frame, pixels: pixels, kind: "edge-return",
                fallback: sourceIsMedia ? .black : .systemBackground,
                sourceScheme: sourceScheme, sourceIsMedia: sourceIsMedia, sharedTone: sharedTone)
    }

    private func install(_ token: UUID, window: UIWindow, frame: CGRect, pixels: UIView?, kind: String,
                         fallback: UIColor, sourceScheme: ColorScheme, sourceIsMedia: Bool, sharedTone: PageToneTransition? = nil) {
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
        frames = 0
        settleFrames = 0
        capturedTargetPixels = false
        bodyHandedToLivePage = false
        capturedSourceHeaderPixels = false
        capturedTargetHeaderPixels = false
        sourceHeaderBandPixels = nil
        targetHeaderBandPixels = nil
        capturedSourceHeaderPixels = false
        capturedTargetHeaderPixels = false
        targetScopeController = nil
        targetOwner = nil
        targetFrame = .zero
        interactiveProgress = 0
        motionAccepted = false
        slideOffset = 0
        sourceBandOffset = 0
        targetBandOffset = 0
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        surface.accessibilityElementsHidden = true
        surface.backgroundColor = .clear
        capturedPixels = pixels != nil
        // The fallback is tied to the visible source's role/traits; it cannot
        // introduce a system light background into a dark playback canvas.
        let sourceTraits = UITraitCollection(userInterfaceStyle: sourceScheme == .dark ? .dark : .light)
        let sourceColor = (sourceIsMedia ? UIColor.black : UIColor.systemBackground).resolvedColor(with: sourceTraits)
        sourceCanvasColor = sourceColor
        tone = sharedTone ?? PageToneTransition(source: Color(uiColor: sourceColor),
                                  sourceScheme: sourceScheme, sourceIsMedia: sourceIsMedia, suspended: true,
                                  headerCanvasBand: CGRect(x: 0, y: safeArea.top, width: bounds.width,
                                                           height: max(0, bodyFrame.minY - safeArea.top)))
        if let media = sharedTone?.destinationIsMedia {
            let style: UIUserInterfaceStyle = sharedTone?.destinationScheme == .dark ? .dark : .light
            destinationCanvasColor = media ? .black : UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        }
        Self.toneContext(in: window).owner = self
        let toneBand = UIView(frame: CGRect(x: 0, y: safeArea.top, width: bounds.width,
                                            height: max(0, bodyFrame.minY - safeArea.top)))
        toneBand.backgroundColor = sourceColor
        surface.addSubview(toneBand)
        self.toneHeaderBand = toneBand
        let pixels = pixels ?? UIView()
        pixels.backgroundColor = capturedPixels ? .clear : fallback
        pixels.frame = bodyFrame
        pixels.isUserInteractionEnabled = false
        pixels.accessibilityElementsHidden = true
        surface.addSubview(pixels)
        bodyPixels = pixels
        // Blend only the system safe-area background, never fixed bar controls.
        for rect in [CGRect(x: 0, y: 0, width: bounds.width, height: window.safeAreaInsets.top),
                     CGRect(x: 0, y: bounds.height - window.safeAreaInsets.bottom,
                            width: bounds.width, height: window.safeAreaInsets.bottom)] where rect.height > 0 {
            let safeArea = UIView(frame: rect)
            safeArea.backgroundColor = sourceColor
            surface.addSubview(safeArea)
            safeAreaViews.append(safeArea)
        }
        updateSafeAreaTone(progress: tone?.clock.progress ?? 0)
        overlay = surface
        window.addSubview(surface)
        interaction = PageInteractionShield.acquire(in: window)
        keepVisible()
        publish("holding", progress: tone?.clock.progress ?? 0)
    }

    /// The target may have a taller fixed header. Reveal that header without
    /// translating or scaling the outgoing body pixels beneath it.
    func clipBody(to frame: CGRect) {
        guard let bodyPixels else { return }
        let visible = bodyFrame.intersection(frame)
        let mask = CAShapeLayer()
        mask.frame = bodyPixels.bounds
        mask.path = visible.isNull ? UIBezierPath().cgPath
            : UIBezierPath(rect: visible.offsetBy(dx: -bodyFrame.minX, dy: -bodyFrame.minY)).cgPath
        bodyPixels.layer.mask = mask
    }

    /// At an accepted navigation return's endpoint, pin the destination's
    /// canonical fixed footer above UIKit's remaining page visuals. Its media
    /// canvas and controls leave in the same receipt as the promoted body.
    @discardableResult
    func installReturnFooter(_ token: UUID, footer: PageReturnFooterPreview) -> Bool {
        guard self.token == token, kind == "edge-return", let window, let overlay,
              geometryMatches(window), footer.surface.superview == nil || footer.surface.window === window,
              let current = PageBodyViewports.fixedBottomBarFrame(in: window),
              abs(current.minY - footer.frame.minY) <= 2,
              abs(current.width - footer.frame.width) <= 2,
              abs(current.height - footer.frame.height) <= 2 else { return false }
        let container = footer.surface
        container.frame = footer.canvasFrame; container.alpha = 1
        overlay.addSubview(container)
        returnFooterCanvas = container
        keepVisible()
        return true
    }

    /// Transfer the already-rendered full header band without another snapshot.
    /// It remains in this receipt until the live header/body fence releases it.
    @discardableResult
    func installReturnHeaderBand(_ token: UUID, band: UIView, frame: CGRect, release: @escaping () -> Void) -> Bool {
        guard self.token == token, kind == "edge-return", capturedPixels,
              let overlay, let window, geometryMatches(window), band.window === window,
              returnHeaderBand == nil, frame.width > 1, frame.height > 1,
              abs(frame.maxY - bodyFrame.minY) <= 2,
              abs(frame.minX - bodyFrame.minX) <= 2, abs(frame.width - bodyFrame.width) <= 2 else { return false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        band.alpha = 1; band.transform = .identity; band.frame = frame
        overlay.addSubview(band)
        returnHeaderBand = band; returnHeaderBandRelease = release
        CATransaction.commit()
        keepVisible()
        return true
    }

    /// Root-only full canvas ownership. Fixed controls are separate layers;
    /// media behind transparent bars belongs to the same moving page copy.
    @discardableResult
    func installRootCanvas(_ token: UUID, target: Bool, canvas: UIView?,
                           footer: UIImage, media: Bool, bodyStartOffset: CGFloat = 0, bodyEndOffset: CGFloat = 0) -> Bool {
        guard self.token == token, let window, let overlay, geometryMatches(window),
              target ? capturedTargetPixels : capturedPixels,
              let footerFrame = PageBodyViewports.fixedBottomBarFrame(in: window) else { return false }
        let color = target ? (destinationCanvasColor ?? sourceCanvasColor) : sourceCanvasColor
        let plane = UIView(frame: bounds)
        plane.backgroundColor = color
        plane.isUserInteractionEnabled = false
        plane.accessibilityElementsHidden = true
        if let canvas {
            guard canvas.window === window else { return false }
            if media {
                // One bounded media canvas copy supplies pixels behind every
                // possible intermediate header clip. It shares the same x
                // mapping as the body, including the area under fixed bars.
                let local = canvas.convert(bounds, from: window).intersection(canvas.bounds)
                guard !local.isNull, local.width > 1, local.height > 1,
                      let copy = canvas.resizableSnapshotView(from: local, afterScreenUpdates: false, withCapInsets: .zero) else { return false }
                copy.frame = canvas.convert(local, to: window)
                plane.addSubview(copy)
            }
        }
        let pixels = UIImageView(image: footer)
        pixels.frame = footerFrame
        pixels.isUserInteractionEnabled = false
        pixels.accessibilityElementsHidden = true
        if target {
            rootTargetCanvas?.removeFromSuperview(); rootTargetFooter?.removeFromSuperview()
            rootTargetCanvas = plane; rootTargetFooter = pixels
            rootTargetBodyStart = bodyStartOffset
            rootTargetBodyEnd = bodyEndOffset
            capturedTargetHeaderPixels = media && canvas != nil
        } else {
            rootSourceCanvas?.removeFromSuperview(); rootSourceFooter?.removeFromSuperview()
            rootSourceCanvas = plane; rootSourceFooter = pixels
            rootFooterFrame = footerFrame
            let clip = UIView(frame: CGRect(x: bounds.minX, y: bounds.minY,
                                             width: bounds.width, height: bounds.height))
            clip.clipsToBounds = true
            clip.isUserInteractionEnabled = false
            clip.accessibilityElementsHidden = true
            if let bodyPixels { clip.addSubview(bodyPixels) }
            overlay.addSubview(clip)
            rootBodyClip = clip
            capturedSourceHeaderPixels = media && canvas != nil
            // The root canvas, rather than solid safe-area bands, owns all
            // pixels outside the measured body throughout this flight.
            safeAreaViews.forEach { $0.removeFromSuperview() }
            toneHeaderBand?.removeFromSuperview(); toneHeaderBand = nil
            safeAreaViews.removeAll()
        }
        if let source = rootSourceCanvas { overlay.insertSubview(source, at: 0) }
        if let target = rootTargetCanvas { overlay.insertSubview(target, aboveSubview: rootSourceCanvas ?? overlay.subviews[0]) }
        if let source = rootSourceFooter { overlay.addSubview(source) }
        if let target = rootTargetFooter { overlay.addSubview(target) }
        applySlide(progress: interactiveProgress, direction: interactiveDirection)
        return true
    }

    /// Called during target layout, before its first visible frame, so UIKit's
    /// newly attached presentation cannot cover the outgoing body copy.
    func keepVisible() {
        guard let overlay, let window, overlay.superview === window else { return }
        guard geometryMatches(window) else { cancel(); return }
        NativeHeaderMotion.forWindow(window).positionBodyOverlay(overlay)
        if let header = fixedHeaderHost?.view, header.superview === window, window.subviews.last !== header {
            window.bringSubviewToFront(header)
        }
    }

    func isPrepared(_ token: UUID) -> Bool { self.token == token && overlay != nil }
    func hasCapturedReturnPixels(_ token: UUID) -> Bool {
        self.token == token && kind == "edge-return" && overlay != nil && capturedPixels
    }


    /// Capture the media-only strip behind the fixed source header.
    /// The returned copy joins the same body layer and horizontal transform.
    @discardableResult
    func installSourceHeaderCanvas(_ token: UUID, canvas: UIView) -> Bool {
        guard self.token == token, let window, let overlay, geometryMatches(window),
              canvas.window === window, bodyFrame.minY > safeArea.top else { return false }
        sourceHeaderBandPixels?.removeFromSuperview()
        capturedSourceHeaderPixels = false
        guard let copy = snapshotHeaderBand(canvas: canvas, bodyFrame: bodyFrame, in: window) else {
            return false
        }
        overlay.addSubview(copy)
        sourceHeaderBandPixels = copy
        capturedSourceHeaderPixels = true
        applySlide(progress: interactiveProgress, direction: interactiveDirection)
        return true
    }

    /// Capture the prepared media-only strip behind the fixed target header.
    @discardableResult
    func installTargetHeaderCanvas(_ token: UUID, canvas: UIView) -> Bool {
        guard self.token == token, let window, let overlay, geometryMatches(window),
              canvas.window === window, targetFrame.minY > safeArea.top else { return false }
        targetHeaderBandPixels?.removeFromSuperview()
        capturedTargetHeaderPixels = false
        guard let copy = snapshotHeaderBand(canvas: canvas, bodyFrame: targetFrame, in: window) else {
            return false
        }
        overlay.addSubview(copy)
        targetHeaderBandPixels = copy
        capturedTargetHeaderPixels = true
        updateToneHeaderBandGeometry()
        applySlide(progress: interactiveProgress, direction: interactiveDirection)
        return true
    }

    private func snapshotHeaderBand(canvas: UIView, bodyFrame: CGRect, in window: UIWindow) -> UIView? {
        let windowRect = CGRect(x: bodyFrame.minX, y: window.bounds.minY,
                                width: bodyFrame.width, height: bodyFrame.minY - window.bounds.minY)
        let local = canvas.convert(windowRect, from: window).intersection(canvas.bounds)
        guard !local.isNull, local.width > 1, local.height > 1,
              let snapshot = canvas.resizableSnapshotView(from: local, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        snapshot.frame = canvas.convert(local, to: window)
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        snapshot.backgroundColor = .clear
        return snapshot
    }

    private func updateToneHeaderBandGeometry() {
        guard let toneHeaderBand else { return }
        let lowestBodyTop = max(bodyFrame.minY, targetFrame.minY)
        toneHeaderBand.frame = CGRect(x: 0, y: safeArea.top, width: bounds.width,
                                      height: max(0, lowestBodyTop - safeArea.top))
    }

    /// Mount the fixed header copy inside this body's existing visual session.
    /// It shares the body token, tone clock, and interaction lease.
    func installFixedHeader(token: UUID, handoff: HeaderHandoff) {
        guard self.token == token, let overlay, let window, geometryMatches(window) else { return }
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
            window.addSubview(host.view)
        }
        updateSafeAreaTone(progress: tone?.clock.progress ?? 0)
        keepVisible()
    }

    /// Capture the exact navigation owner after it has rendered in the window.
    /// The target copy is clipped to its own final viewport; fixed chrome remains
    /// outside both moving body snapshots.
    func stageTarget(_ token: UUID, destination: UIViewController) -> Bool {
        guard self.token == token, let window, geometryMatches(window),
              let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded else { return false }
        targetPixels?.removeFromSuperview()
        targetHeaderBandPixels?.removeFromSuperview()
        targetHeaderBandPixels = nil
        capturedTargetHeaderPixels = false
        let capture = rootSourceCanvas != nil ? rootCaptureRect(body: geometry.rect, view: view, window: window) : geometry.rect
        let pixels = view.resizableSnapshotView(from: capture, afterScreenUpdates: false, withCapInsets: .zero)
        if rootSourceCanvas != nil, pixels == nil { return false }
        let copy = pixels ?? UIView()
        copy.frame = view.convert(capture, to: window)
        copy.backgroundColor = pixels == nil
            ? UIColor.systemBackground.resolvedColor(with: geometry.owner.traitCollection) : .clear
        copy.isUserInteractionEnabled = false
        copy.accessibilityElementsHidden = true
        (rootBodyClip ?? overlay)?.addSubview(copy)
        if let source = rootSourceFooter { overlay?.addSubview(source) }
        if let target = rootTargetFooter { overlay?.addSubview(target) }
        targetPixels = copy
        targetScopeController = destination
        targetOwner = ObjectIdentifier(geometry.owner)
        targetFrame = view.convert(geometry.rect, to: window)
        destinationCanvasColor = canvasColor(for: geometry.owner)
        updateToneHeaderBandGeometry()
        updateSafeAreaTone(progress: tone?.clock.progress ?? 0)
        capturedTargetPixels = pixels != nil
        if kind == "edge-return" {
            bodyPixels?.transform = .identity
            copy.alpha = 0
        } else {
            applySlide(progress: interactiveProgress, direction: interactiveDirection)
        }
        return true
    }

    /// Drive the two body copies directly from the owning gesture's progress.
    func updateInteractive(_ token: UUID, progress: Double, direction: CGFloat) {
        guard self.token == token, overlay != nil,
              progress.isFinite, direction.isFinite else { return }
        interactiveProgress = min(1, max(0, progress))
        motionAccepted = false
        interactiveDirection = direction < 0 ? -1 : 1
        applySlide(progress: interactiveProgress, direction: interactiveDirection)
        tone?.clock.setInteractiveProgress(interactiveProgress)
        updateSafeAreaTone(progress: interactiveProgress)
        publish("interactive", progress: interactiveProgress)
    }

    /// Animate from the current interactive position to either endpoint.
    /// The terminal copy remains installed until releaseInteractive observes
    /// the destination's real frame.
    func settleInteractive(_ token: UUID, toDestination: Bool, direction: CGFloat,
                           completion: @escaping (Bool) -> Void) {
        guard self.token == token else { completion(false); return }
        guard overlay != nil, targetPixels != nil, interactiveTargetIsValid(token) else {
            cancel(reason: "interactive-target-invalid-before-settle")
            completion(false)
            return
        }
        settleCompletion?(false)
        settleCompletion = completion
        animator?.cancel(); animator = nil
        let start = interactiveProgress
        let end = toDestination ? 1.0 : 0.0
        motionAccepted = toDestination
        interactiveDirection = direction < 0 ? -1 : 1
        let distance = abs(end - start)
        if toDestination { tone?.clock.start() }
        guard distance > 0.0001 else {
            let finished = settleCompletion
            settleCompletion = nil
            applySettled(end, completion: finished ?? { _ in })
            return
        }
        let duration = (UIAccessibility.isReduceMotionEnabled ? 0.12 : PageToneTransition.duration) * distance
        animator = RenderProgressAnimation(duration: duration) { [weak self] elapsed in
            guard let self, self.token == token else { return }
            guard self.interactiveTargetIsValid(token) else { self.cancel(reason: "interactive-target-invalid-during-settle"); return }
            let fraction = min(1, max(0, elapsed / max(duration, 0.001)))
            let eased = UnitCurve.easeInOut.value(at: fraction)
            let progress = start + (end - start) * eased
            self.interactiveProgress = progress
            self.applySlide(progress: progress, direction: self.interactiveDirection)
            self.tone?.clock.setInteractiveProgress(progress)
            self.updateSafeAreaTone(progress: progress)
            self.settleFrames += 1
            self.frames += 1
            self.publish("settling", progress: progress)
        } completion: { [weak self] in
            guard let self, self.token == token else { return }
            guard self.interactiveTargetIsValid(token) else { self.cancel(reason: "interactive-target-invalid-at-settle-end"); return }
            self.animator = nil
            let finished = self.settleCompletion
            self.settleCompletion = nil
            self.applySettled(end, completion: finished ?? { _ in })
        }
    }

    private func applySettled(_ progress: Double, completion: (Bool) -> Void) {
        interactiveProgress = progress
        applySlide(progress: progress, direction: interactiveDirection)
        tone?.clock.setInteractiveProgress(progress)
        updateSafeAreaTone(progress: progress)
        publish(progress == 1 ? "settled-target" : "settled-source", progress: progress)
        completion(true)
    }

    /// The horizontal flight has reached the same live pane. Give it the body
    /// pixels while this session still owns fixed chrome, tone and input. This
    /// is a layout barrier, not a successful visual terminal receipt.
    func handoffInteractiveBody(_ token: UUID, destination: UIViewController,
                                completion: @escaping (Bool) -> Void) {
        guard self.token == token, liveBodyCompletion == nil,
              !bodyHandedToLivePage, interactiveProgress >= 1, targetPixels != nil,
              interactiveTargetIsValid(token, requestedScope: destination) else {
            completion(false)
            return
        }
        liveBodyCompletion = completion
        frameBoundary?.cancel()
        frameBoundary = RenderFrameBoundary { [weak self, weak destination] in
            guard let self, self.token == token, let destination,
                  let window = self.window, self.geometryMatches(window),
                  self.interactiveTargetIsValid(token, requestedScope: destination) else {
                self?.cancel(reason: "target-changed-before-live-body")
                return
            }
            self.frameBoundary = nil
            self.bodyPixels?.removeFromSuperview(); self.bodyPixels = nil
            self.targetPixels?.removeFromSuperview(); self.targetPixels = nil
            self.sourceHeaderBandPixels?.removeFromSuperview(); self.sourceHeaderBandPixels = nil
            self.targetHeaderBandPixels?.removeFromSuperview(); self.targetHeaderBandPixels = nil
            self.toneHeaderBand?.removeFromSuperview(); self.toneHeaderBand = nil
            self.bodyHandedToLivePage = true
            self.publish("live-body", progress: 1)
            let ready = self.liveBodyCompletion
            self.liveBodyCompletion = nil
            ready?(true)
        }
    }

    /// Release only after the true destination has rendered at its final frame.
    func releaseInteractive(_ token: UUID, destination: UIViewController,
                            completion: @escaping (PageVisualOutcome) -> Void) {
        guard self.token == token else { completion(.aborted("interactive-token-mismatch")); return }
        guard releaseCompletion == nil else { completion(.aborted("interactive-release-already-pending")); return }
        releaseCompletion = completion
        guard interactiveProgress >= 1, (targetPixels != nil || bodyHandedToLivePage),
              interactiveTargetIsValid(token, requestedScope: destination), let window else {
            cancel(reason: "interactive-target-not-ready"); return
        }
        frameBoundary?.cancel()
        frameBoundary = RenderFrameBoundary { [weak self, weak destination] in
            guard let self, self.token == token, let destination, let window = self.window,
                  self.interactiveTargetIsValid(token, requestedScope: destination),
                  destination.viewIfLoaded != nil, self.geometryMatches(window) else {
                self?.cancel(reason: "interactive-target-changed-before-frame"); return
            }
            if self.rootSourceCanvas != nil {
                guard self.rootFinalGeometryMatches(destination, in: window) else {
                    self.cancel(reason: "root-final-geometry-mismatch")
                    return
                }
            }
            self.publish("completed", progress: 1)
            self.remove(outcome: .completed)
        }
    }

    /// Fixed controls live outside the page owner. Include its drawable pixels
    /// under the footer in the same body copy so vertical clearance changes
    /// cannot splice in a stationary tail from another content coordinate.
    private func rootCaptureRect(body: CGRect, view: UIView, window: UIWindow) -> CGRect {
        let visible = view.convert(window.bounds, from: window).intersection(view.bounds)
        return visible
    }

    private func rootFinalGeometryMatches(_ destination: UIViewController, in window: UIWindow) -> Bool {
        guard let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded,
              let footer = PageBodyViewports.fixedBottomBarFrame(in: window), let expectedFooter = rootFooterFrame,
              let handoff = fixedHeaderHandoff, let staged = handoff.destination else { return false }
        let live = view.convert(geometry.rect, to: window)
        let expected = CGRect(x: targetFrame.minX, y: targetFrame.minY + rootTargetBodyEnd,
                              width: targetFrame.width, height: targetFrame.height - rootTargetBodyEnd)
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
                && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        guard close(live, expected), close(footer, expectedFooter), abs(handoff.height - staged.frame.height) <= 1 else { return false }
        var pending = [destination]
        var headers: [NativeHeaderProbe] = []
        while let owner = pending.popLast() {
            if let probe = owner as? NativeHeaderProbe, PageViewportGeometry.owner(of: probe) === geometry.owner { headers.append(probe) }
            pending.append(contentsOf: owner.children)
        }
        return headers.contains { probe in
            guard let current = probe.currentHeader ?? probe.settledHeader else { return false }
            return close(current.frame, staged.frame)
                && current.appearance.layoutIdentity == staged.appearance.layoutIdentity
                && current.appearance.canvasRole == staged.appearance.canvasRole
                && current.appearance.colorScheme == staged.appearance.colorScheme
        }
    }

    private func resolvedGeometry(for destination: UIViewController, in window: UIWindow) -> PageBodyViewports.Geometry? {
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
        return true
    }

    private func applySlide(progress: Double, direction: CGFloat) {
        guard let bodyPixels else { return }
        let p = CGFloat(min(1, max(0, progress)))
        if rootSourceCanvas != nil {
            fixedHeaderHandoff?.updateRootProgress(progress)
            let sign: CGFloat = direction < 0 ? -1 : 1
            if UIAccessibility.isReduceMotionEnabled {
                rootSourceCanvas?.transform = .identity
                rootTargetCanvas?.transform = .identity
                rootSourceCanvas?.alpha = 1 - p
                rootTargetCanvas?.alpha = p
            } else {
                rootSourceCanvas?.transform = CGAffineTransform(translationX: sign * bounds.width * p, y: 0)
                rootTargetCanvas?.transform = CGAffineTransform(translationX: -sign * bounds.width * (1 - p), y: 0)
            }
            rootSourceFooter?.alpha = 1 - p
            rootTargetFooter?.alpha = p
            if let clip = rootBodyClip {
                let mask = (clip.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                mask.frame = clip.bounds
                mask.path = UIBezierPath(rect: clip.bounds).cgPath
                clip.layer.mask = mask
                CATransaction.commit()
            }
        }
        if kind == "edge-return" {
            bodyPixels.transform = .identity
            targetPixels?.transform = .identity
            targetPixels?.alpha = 0
            sourceHeaderBandPixels?.transform = .identity
            targetHeaderBandPixels?.transform = .identity
            slideOffset = 0
            sourceBandOffset = 0
            targetBandOffset = 0
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            bodyPixels.transform = .identity
            bodyPixels.alpha = motionAccepted ? 1 - p : 1
            targetPixels?.transform = .identity
            targetPixels?.alpha = motionAccepted ? p : 0
            sourceHeaderBandPixels?.transform = .identity
            sourceHeaderBandPixels?.alpha = motionAccepted ? 1 - p : 1
            targetHeaderBandPixels?.transform = .identity
            targetHeaderBandPixels?.alpha = motionAccepted ? p : 0
            slideOffset = 0
            sourceBandOffset = 0
            targetBandOffset = 0
            return
        }
        bodyPixels.alpha = 1
        targetPixels?.alpha = 1
        sourceHeaderBandPixels?.alpha = 1
        targetHeaderBandPixels?.alpha = 1
        let signedDirection: CGFloat = direction < 0 ? -1 : 1
        let sourceOffset = signedDirection * (rootSourceCanvas != nil ? bounds.width : bodyFrame.width) * p
        let targetOffset = -signedDirection * (rootSourceCanvas != nil ? bounds.width : targetFrame.width) * (1 - p)
        bodyPixels.transform = CGAffineTransform(translationX: sourceOffset, y: 0)
        sourceHeaderBandPixels?.transform = CGAffineTransform(translationX: sourceOffset, y: 0)
        if let targetPixels {
            targetPixels.transform = CGAffineTransform(translationX: targetOffset, y: rootTargetBodyStart * (1 - p) + rootTargetBodyEnd * p)
        }
        targetHeaderBandPixels?.transform = CGAffineTransform(translationX: targetOffset, y: 0)
        slideOffset = sourceOffset
        sourceBandOffset = sourceOffset
        targetBandOffset = targetOffset
    }

    /// The edge is already at rest. Prepare its actual target and start the
    /// shared tone without withdrawing the promoted body before header resize.
    func startReturnTone(_ token: UUID, destination: UIViewController) -> Bool {
        guard kind == "edge-return", stageTarget(token, destination: destination) else { return false }
        if returnHeaderBand == nil {
            guard let window, NativeHeaderMotion.forWindow(window).hasSuppressedHeader(for: destination),
                  let geometry = resolvedGeometry(for: destination, in: window),
                  let canvas = geometry.owner.viewIfLoaded,
                  installTargetHeaderCanvas(token, canvas: canvas) else { return false }
        }
        publish("handoff", progress: 1)
        guard self.token == token else { return false }
        tone?.clock.start()
        animator = RenderProgressAnimation(duration: tone?.clock.remaining ?? PageToneTransition.duration) { [weak self, weak destination] _ in
            guard let self, self.token == token, let destination,
                  let window = self.window, self.geometryMatches(window),
                  self.resolvedGeometry(for: destination, in: window) != nil else {
                self?.cancel(reason: "return-tone-target-changed"); return
            }
            self.updateSafeAreaTone(progress: self.tone?.clock.progress ?? 1)
        } completion: { [weak self] in
            guard let self, self.token == token else { return }
            self.animator = nil
        }
        return true
    }

    /// Native header readiness has already fenced both live surfaces. Remove
    /// the body and its opaque header band in that same terminal transaction.
    func finishReturnReveal(_ token: UUID, destination: UIViewController,
                            completion: @escaping (PageVisualOutcome) -> Void) {
        guard self.token == token, kind == "edge-return", overlay != nil else {
            completion(.aborted("missing-return-body")); return
        }
        self.completion = completion
        guard interactiveTargetIsValid(token, requestedScope: destination),
              let window, window.windowScene?.activationState == .foregroundActive,
              let geometry = resolvedGeometry(for: destination, in: window),
              let view = geometry.owner.viewIfLoaded else {
            cancel(reason: "return-target-changed-before-terminal"); return
        }
        let currentFrame = view.convert(geometry.rect, to: window)
        guard abs(currentFrame.minX - targetFrame.minX) <= 2,
              abs(currentFrame.width - targetFrame.width) <= 2,
              abs(currentFrame.minY - targetFrame.minY) <= 2,
              abs(currentFrame.height - targetFrame.height) <= 2 else {
            cancel(reason: "return-viewport-changed-before-terminal"); return
        }
        publish("completed", progress: 1)
        remove(outcome: .completed)
    }

    func reveal(_ token: UUID, destination: UIViewController?, direction: CGFloat? = nil,
                completion: ((PageVisualOutcome) -> Void)? = nil) {
        guard self.token == token, overlay != nil else { completion?(.aborted("missing-prepared-body")); return }
        self.completion = completion
        guard let destination, let window, geometryMatches(window),
              resolvedGeometry(for: destination, in: window) != nil else { cancel(reason: "target-not-ready"); return }
        let motionDirection = direction ?? (kind == "return" ? 1 : -1)
        interactiveDirection = motionDirection < 0 ? -1 : 1
        motionAccepted = true
        keepVisible()
        if kind == "edge-return" { publish("handoff", progress: interactiveProgress) }
        frameBoundary = RenderFrameBoundary { [weak self, weak destination] in
            guard let self else { return }
            self.frameBoundary = nil
            guard self.token == token, let destination, let window = self.window,
                  self.resolvedGeometry(for: destination, in: window) != nil else {
                self.cancel(reason: "target-changed-before-frame"); return
            }
            guard self.stageTarget(token, destination: destination) else {
                self.cancel(reason: "target-viewport-unavailable"); return
            }
            // UIKit may apply the incoming tab's preferred style during these
            // first layout frames. Establish its baseline now, then reject any
            // further external appearance change while revealing.
            guard let targetOwner = self.resolvedGeometry(for: destination, in: window)?.owner else {
                self.cancel(reason: "target-owner-unavailable"); return
            }
            let targetStyle = targetOwner.traitCollection.userInterfaceStyle
            self.tone?.clock.start()
            if self.kind == "edge-return" {
                // PageEdgeReturn already moved both bodies to the terminal
                // coordinate. The destination has now produced its true frame.
                self.interactiveProgress = 1
                self.publish("completed", progress: 1)
                self.remove(outcome: .completed)
                return
            }
            self.animator = RenderProgressAnimation(duration: PageToneTransition.duration) { [weak self, weak destination, weak targetOwner] elapsed in
                guard let self, self.token == token, let window = self.window,
                      let destination, let targetOwner, self.geometryMatches(window),
                      self.resolvedGeometry(for: destination, in: window)?.owner === targetOwner,
                      targetOwner.traitCollection.userInterfaceStyle == targetStyle else { self?.cancel(reason: "target-style-or-scope-changed"); return }
                self.frames += 1
                let progress = self.tone?.clock.progress ?? 1
                self.updateSafeAreaTone(progress: progress)
                let slideProgress = UnitCurve.easeInOut.value(at: min(1, max(0, elapsed / PageToneTransition.duration)))
                self.interactiveProgress = slideProgress
                self.applySlide(progress: slideProgress, direction: self.interactiveDirection)
                self.publish("revealing", progress: progress)
            } completion: { [weak self] in
                guard let self, self.token == token else { return }
                self.publish("completed", progress: 1)
                self.remove(outcome: .completed)
            }
        }
    }

    private func geometryMatches(_ window: UIWindow) -> Bool {
        window.bounds == bounds && window.safeAreaInsets == safeArea
            && window.windowScene?.interfaceOrientation == orientation
    }

    func cancel(reason: String = "cancelled") {
        cancellationReason = reason
        let outcome: PageVisualOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
        if token != nil { publish("cancelled", progress: interactiveProgress) }
        remove(outcome: outcome)
    }

    private func remove(outcome: PageVisualOutcome?) {
        frameBoundary?.cancel(); frameBoundary = nil
        animator?.cancel(); animator = nil
        fixedHeaderHost?.view.removeFromSuperview()
        returnFooterCanvas?.removeFromSuperview(); returnFooterCanvas = nil
        overlay?.removeFromSuperview(); overlay = nil; bodyPixels = nil; targetPixels = nil
        returnHeaderBand?.removeFromSuperview(); returnHeaderBand = nil
        let releaseHeaderBand = returnHeaderBandRelease; returnHeaderBandRelease = nil
        releaseHeaderBand?()
        sourceHeaderBandPixels = nil; targetHeaderBandPixels = nil; toneHeaderBand = nil
        fixedHeaderHost = nil
        rootSourceCanvas = nil; rootTargetCanvas = nil
        rootSourceFooter = nil; rootTargetFooter = nil
        rootBodyClip = nil; rootFooterFrame = nil
        rootTargetBodyStart = 0; rootTargetBodyEnd = 0
        fixedHeaderHandoff = nil
        destinationCanvasColor = nil
        safeAreaViews.removeAll()
        interaction?.release(); interaction = nil
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
        bodyHandedToLivePage = false
        interactiveProgress = 0
        motionAccepted = false
        slideOffset = 0
        sourceBandOffset = 0
        targetBandOffset = 0
        let settled = completion
        completion = nil
        if let outcome { settled?(outcome) }
        let didSettle = settleCompletion
        settleCompletion = nil
        didSettle?(false)
        let didRelease = releaseCompletion
        releaseCompletion = nil
        didRelease?(outcome ?? .aborted("interactive-session-removed"))
        let liveBody = liveBodyCompletion
        liveBodyCompletion = nil
        liveBody?(false)
    }

    private func updateSafeAreaTone(progress: Double) {
        let p = CGFloat(min(1, max(0, progress.isFinite ? progress : 0)))
        let appearance = fixedHeaderHandoff?.surfaceDestination?.appearance
            ?? fixedHeaderHandoff?.destination?.appearance
        let destinationColor: UIColor
        if let appearance, appearance.canvasRole == .playback {
            destinationColor = .black
        } else if let appearance {
            let style: UIUserInterfaceStyle = appearance.colorScheme == .dark ? .dark : .light
            destinationColor = UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        } else {
            destinationColor = destinationCanvasColor ?? sourceCanvasColor
        }
        let blended = Self.blend(sourceCanvasColor, destinationColor, progress: p)
        safeAreaViews.forEach { $0.backgroundColor = blended }
        toneHeaderBand?.backgroundColor = blended
    }

    /// Read the target's registered chrome within its exact viewport owner.
    /// Cover routes share the same color contract without installing a root header.
    private func canvasColor(for owner: UIViewController) -> UIColor {
        var pending = [owner]
        var headers: [NativeHeaderProbe] = []
        while let current = pending.popLast() {
            if let probe = current as? NativeHeaderProbe,
               PageViewportGeometry.owner(of: probe) === owner { headers.append(probe) }
            pending.append(contentsOf: current.children)
        }
        let appearance = headers.compactMap { $0.currentHeader?.appearance }.first
            ?? headers.compactMap { $0.settledHeader?.appearance }.first
        if appearance?.canvasRole == .playback { return .black }
        let traits = appearance.map {
            UITraitCollection(userInterfaceStyle: $0.colorScheme == .dark ? .dark : .light)
        } ?? owner.traitCollection
        return UIColor.systemBackground.resolvedColor(with: traits)
    }

    private static func blend(_ source: UIColor, _ destination: UIColor, progress: CGFloat) -> UIColor {
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
        var dr: CGFloat = 0, dg: CGFloat = 0, db: CGFloat = 0, da: CGFloat = 0
        guard source.getRed(&sr, green: &sg, blue: &sb, alpha: &sa),
              destination.getRed(&dr, green: &dg, blue: &db, alpha: &da) else {
            return progress < 0.5 ? source : destination
        }
        return UIColor(red: sr + (dr - sr) * progress,
                       green: sg + (dg - sg) * progress,
                       blue: sb + (db - sb) * progress,
                       alpha: sa + (da - sa) * progress)
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
            NSLog("BODY_PERF kind=\(kind);phase=\(phase);frames=\(frames);slideOffset=\(slideOffset);sourceBandOffset=\(sourceBandOffset);targetBandOffset=\(targetBandOffset);settleFrames=\(settleFrames);sourceHeaderSnapshot=\(capturedSourceHeaderPixels);targetHeaderSnapshot=\(capturedTargetHeaderPixels);residentPeakMiB=\(residentPeak);residentDeltaMiB=\(residentPeak - residentBefore)")
        }
        readback?.accessibilityValue = "kind=\(kind);phase=\(phase);reason=\(cancellationReason);progress=\(progress);frames=\(frames);slideOffset=\(slideOffset);sourceBandOffset=\(sourceBandOffset);targetBandOffset=\(targetBandOffset);settleFrames=\(settleFrames);snapshotAvailable=\(capturedPixels ? 1 : 0);targetSnapshotAvailable=\(capturedTargetPixels ? 1 : 0);sourceHeaderSnapshot=\(capturedSourceHeaderPixels ? 1 : 0);targetHeaderSnapshot=\(capturedTargetHeaderPixels ? 1 : 0);liveBody=\(bodyHandedToLivePage ? 1 : 0);top=\(bodyFrame.minY);bottom=\(bodyFrame.maxY)"
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
