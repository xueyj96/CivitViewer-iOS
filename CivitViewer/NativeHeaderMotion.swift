import SwiftUI
import UIKit

/// Pins the outgoing header while UIKit moves the pages. UIKit still owns
/// the push, presentation, interactive gesture and cancellation.
@MainActor
final class NativeHeaderMotion {
    private weak var window: UIWindow?
    private var probes: [WeakProbe] = []
    private var flight: Flight?
    private weak var displacedTransition: AnyObject?
    private var inactivityObserver: NSObjectProtocol?
    private static var windowKey: UInt8 = 0

    private struct WeakProbe {
        weak var value: NativeHeaderProbe?
    }

    @MainActor
    private final class Flight {
        let from: UIViewController
        var to: UIViewController?
        let routeID: UUID?
        let windowBounds: CGRect
        let handoff: HeaderHandoff
        let host: UIHostingController<Overlay>
        var completed = false
        var interactive = false
        var followsBodyProgress = false
        let ownsNavigationTone: Bool
        var layoutRevision = 0
        var expectedLayoutHeight: CGFloat?
        var expectedLayoutIdentity: AnyHashable?
        var interactionShield: PageInteractionShield.Lease?
        weak var coordinator: AnyObject?
        var hiddenProbes: [WeakProbe] = []
        var toneFrameBoundary: RenderFrameBoundary?
        var layoutCommitBoundary: RenderFrameBoundary?
        var preservesDestinationViewport = false
        var visualCompletion: ((Bool) -> Void)?
        var prepareBody: (() -> Bool)?
        var releasing = false
        var cancelLiveReadiness: (() -> Void)?
        weak var readyProbe: NativeHeaderProbe?

        func matches(from source: UIViewController?, to destination: UIViewController?) -> Bool {
            from === source && (to == nil || to === destination)
        }

        func hide(_ probe: NativeHeaderProbe) {
            guard !hiddenProbes.contains(where: { $0.value === probe }) else { return }
            hiddenProbes.append(WeakProbe(value: probe))
            probe.setHandoff(handoff)
        }

        init?(from: UIViewController, to: UIViewController?, routeID: UUID?, source: HeaderContent, isLayoutChange: Bool, windowBounds: CGRect, tone: PageToneTransition? = nil, ownsNavigationTone: Bool = false) {
            guard let handoff = HeaderHandoff(source: source, isLayoutChange: isLayoutChange, tone: tone) else { return nil }
            self.windowBounds = windowBounds
            self.ownsNavigationTone = ownsNavigationTone
            self.from = from
            self.to = to
            self.routeID = routeID
            self.handoff = handoff
            host = UIHostingController(rootView: Overlay(handoff: handoff))
        }
    }

    private struct Overlay: View {
        let handoff: HeaderHandoff

        var body: some View {
            HeaderHandoffView(handoff: handoff)
                .offset(x: handoff.source.frame.minX, y: handoff.source.frame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(alignment: .topLeading) {
                    if let tone = handoff.surfaceTone, let band = tone.headerCanvasBand {
                        PageToneBlend(tone: tone, coversSafeArea: false)
                            .frame(width: band.width, height: band.height)
                            .offset(x: band.minX, y: band.minY)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private init(window: UIWindow) {
        self.window = window
        inactivityObserver = NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] notification in
            guard let scene = notification.object as? UIWindowScene else { return }
            Task { @MainActor [weak self, weak scene] in
                guard let self, scene === self.window?.windowScene else { return }
                self.yieldToTabSwitch()
            }
        }
    }

    deinit { if let inactivityObserver { NotificationCenter.default.removeObserver(inactivityObserver) } }

    static func forWindow(_ window: UIWindow) -> NativeHeaderMotion {
        if let existing = objc_getAssociatedObject(window, &windowKey) as? NativeHeaderMotion { return existing }
        let motion = NativeHeaderMotion(window: window)
        objc_setAssociatedObject(window, &windowKey, motion, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return motion
    }

    /// Preserve one stable z-order rather than moving body/header twice on
    /// every layout pass. Both copies remain noninteractive.
    func positionBodyOverlay(_ body: UIView) {
        guard let window, body.superview === window else { return }
        if let header = flight?.host.viewIfLoaded, header.superview === window {
            if window.subviews.last !== header { window.bringSubviewToFront(header) }
            if window.subviews.dropLast().last !== body { window.insertSubview(body, belowSubview: header) }
        } else if window.subviews.last !== body { window.bringSubviewToFront(body) }
    }

    func register(_ probe: NativeHeaderProbe) {
        probes.removeAll { $0.value == nil }
        if !probes.contains(where: { $0.value === probe }) { probes.append(WeakProbe(value: probe)) }
        guard let flight else { return }
        guard window?.bounds == flight.windowBounds else { remove(flight); return }
        if flight.releasing {
            if let to = flight.to, probe.belongs(to: to), probe !== flight.readyProbe { remove(flight) }
            return
        }
        let isDestination = flight.to.map { probe.belongs(to: $0) } ?? (probe.routeID == flight.routeID)
        if probe.belongs(to: flight.from) || isDestination {
            if isDestination, let incoming = probe.headerForFixedHost(alignedTo: flight.handoff.source) {
                flight.handoff.stageContentLayout(incoming, preservesViewport: flight.preservesDestinationViewport)
            }
            if isDestination, flight.ownsNavigationTone,
               let incoming = probe.headerForFixedHost(alignedTo: flight.handoff.source) {
                stageSurface(incoming, for: flight)
            }
            flight.hide(probe)
            if flight.routeID != nil, let window, let overlay = flight.host.viewIfLoaded,
               overlay.superview === window, window.subviews.last !== overlay {
                window.bringSubviewToFront(overlay)
            }
        }
    }

    func start(_ transition: UIViewControllerTransitionCoordinator, from probe: NativeHeaderProbe) {
        let coordinator = transition as AnyObject
        guard coordinator !== displacedTransition, transition.isAnimated,
              let navigationView = probe.navigationController?.viewIfLoaded,
              transition.containerView.isDescendant(of: navigationView),
              let from = transition.viewController(forKey: .from),
              let to = transition.viewController(forKey: .to), from !== to,
              probe.belongs(to: from) || probe.belongs(to: to) else { return }
        if let flight {
            guard flight.coordinator !== coordinator else { return }
            if flight.routeID != nil, flight.coordinator == nil, flight.matches(from: from, to: to) {
                flight.coordinator = coordinator
                flight.interactive = transition.isInteractive
                // UIKit now supplies the exact destination owner. A SwiftUI
                // destination may register its probe before route environment
                // propagation; do not keep matching it by an optional route ID.
                flight.to = to
                matching(to).forEach { register($0) }
                return
            }
            guard flight.completed, flight.routeID != nil || flight.from !== from || flight.to !== to else { return }
            remove(flight)
        }
        guard let flight = pin(from: from, to: to, routeID: nil, interactive: transition.isInteractive) else { return }
        flight.coordinator = coordinator
        flight.interactive = transition.isInteractive

        let registered = transition.animate(alongsideTransition: { [weak self, weak flight] _ in
            guard let self, let flight, self.flight === flight else { return }
            self.window?.bringSubviewToFront(flight.host.view)
        }, completion: { [weak self, weak flight] context in
            guard let self, let flight, self.flight === flight else { return }
            flight.completed = true
            let cancelled = context.isCancelled
            Task { @MainActor in await self.finish(flight, cancelled: cancelled) }
        })
        if !registered { remove(flight) }
    }

    /// A row-count change within the same page uses the same pinned surface as
    /// navigation, rather than animating the whole live header's opacity/frame.
    func prepareLayoutChange(from probe: NativeHeaderProbe, expectedHeight: CGFloat, identity: AnyHashable?, commit: @escaping () -> Void) {
        beginLayoutChange(from: probe, expectedHeight: expectedHeight, identity: identity)
        guard let flight, flight.handoff.isLayoutChange, probe.belongs(to: flight.from) else { commit(); return }
        flight.layoutCommitBoundary?.cancel()
        flight.layoutCommitBoundary = RenderFrameBoundary { [weak self, weak flight] in
            guard let self, let flight, self.flight === flight else { return }
            flight.layoutCommitBoundary = nil
            withoutPageAnimation(commit)
        }
    }

    func beginLayoutChange(from probe: NativeHeaderProbe, expectedHeight: CGFloat, identity: AnyHashable?) {
        guard let owner = probe.navigationController?.topViewController, probe.belongs(to: owner) else { return }
        if let flight {
            if flight.handoff.isLayoutChange, flight.from === owner {
                flight.layoutRevision += 1
                flight.expectedLayoutHeight = expectedHeight
                flight.expectedLayoutIdentity = identity
            }
            return
        }
        guard let source = probe.layoutChangeSource,
              let flight = pin(from: owner, to: owner, routeID: UUID(), isLayoutChange: true,
                               sourceOverride: source) else { return }
        flight.expectedLayoutHeight = expectedHeight
        flight.expectedLayoutIdentity = identity
        flight.completed = true
        Task { [weak self, weak probe, weak flight] in
            guard let self, let flight, self.flight === flight else { return }
            guard let probe else { self.remove(flight); return }
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(16))
                guard self.flight === flight else { return }
                if let incoming = probe.currentHeader, abs(incoming.frame.height - (flight.expectedLayoutHeight ?? expectedHeight)) <= 1,
                   incoming.appearance.layoutIdentity == flight.expectedLayoutIdentity { break }
            }
            guard self.flight === flight else { return }
            await finish(flight, cancelled: false)
        }
    }

    func beginRoute(from: UIViewController, to: UIViewController?, id: UUID, tone: PageToneTransition? = nil,
                    preservesDestinationViewport: Bool = false) -> Bool {
        if let flight {
            guard flight.completed else { return false }
            remove(flight)
        }
        guard let flight = pin(from: from, to: to, routeID: id, tone: tone,
                               preservesDestinationViewport: preservesDestinationViewport) else { return false }
        Task { [weak self, weak flight] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, let flight, self.flight === flight, !flight.completed else { return }
            // No platform receipt arrived. Release only this pinned visual;
            // a deadline cannot report pageTransitionDidComplete or navigation.
            self.remove(flight)
        }
        return true
    }

    var canBeginBodyReturn: Bool { flight == nil }

    /// The body driver owns this route's progress and cancellation. It starts
    /// only at an idle chrome boundary, never by stealing a forward flight.
    func beginBodyReturn(from: UIViewController, to: UIViewController, id: UUID, cachedTarget: HeaderContent?) -> PageToneTransition? {
        guard flight == nil, let window,
              let source = matching(from).compactMap(\.settledHeader).first else { return nil }
        let target: HeaderContent?
        if let saved = cachedTarget, saved.appearance.hasCompositedHeaderSnapshot,
           abs(saved.frame.width - source.frame.width) <= 2 {
            target = HeaderContent(frame: CGRect(origin: source.frame.origin, size: saved.frame.size), appearance: saved.appearance)
        } else if let live = matching(to).compactMap({ $0.headerForFixedHost(alignedTo: source) }).first { target = live }
        else if let saved = cachedTarget,
                abs(saved.frame.width - source.frame.width) <= 2 {
            // UINavigationController detaches the previous view. Its trusted
            // cached preview and settled header remain valid for this gesture;
            // the actual target still passes the live-frame fence after pop.
            target = HeaderContent(frame: CGRect(origin: source.frame.origin, size: saved.frame.size), appearance: saved.appearance)
        } else { target = nil }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
            NSLog("RETURN171_HEADER source=%.2f;target=%.2f;sourceRow=%.2f;targetRow=%.2f;sourceCount=%d;targetCount=%d;cached=%d", source.frame.height, target?.frame.height ?? -1, source.appearance.firstRowHeight, target?.appearance.firstRowHeight ?? -1, matching(from).count, matching(to).count, cachedTarget == nil ? 0 : 1)
        }
        #endif
        guard let target else { return nil }
        guard abs(source.frame.height - target.frame.height) <= 1,
              abs(source.appearance.firstRowHeight - target.appearance.firstRowHeight) <= 1,
              abs(source.frame.minY - target.frame.minY) <= 2 else { return nil }
        let tone = PageToneTransition(source: source.appearance.canvasRole == .playback ? .black : AppTheme.pageBackground(for: source.appearance.colorScheme),
            sourceScheme: source.appearance.colorScheme, sourceIsMedia: source.appearance.canvasRole == .playback,
            suspended: true, destinationScheme: target.appearance.colorScheme,
            destinationIsMedia: target.appearance.canvasRole == .playback)
        guard let flight = pin(from: from, to: to, routeID: id, tone: tone, interactive: true,
                               preservesDestinationViewport: true) else { return nil }
        guard flight.handoff.stageRoot(target) else { remove(flight); return nil }
        flight.followsBodyProgress = true
        PageBodyHandoff.toneContext(in: window).installReturnTone(tone)
        return tone
    }

    func updateBodyReturn(_ id: UUID, progress: Double) {
        guard let flight, flight.routeID == id, flight.followsBodyProgress, !flight.completed else { return }
        flight.handoff.surfaceTone?.clock.setInteractiveProgress(progress)
        flight.handoff.updateRootProgress(progress)
    }

    func completeRoute(_ id: UUID, animate: Bool, prepareBody: (() -> Bool)? = nil,
                       completion: ((Bool) -> Void)? = nil) {
        guard let flight, flight.routeID == id, !flight.completed else { completion?(false); return }
        flight.visualCompletion = completion
        flight.prepareBody = prepareBody
        flight.completed = true
        if animate { Task { @MainActor in await finish(flight, cancelled: false) } }
        else { remove(flight) }
    }

    func yieldToTabSwitch() {
        guard let flight else { return }
        // A late layout from this UIKit transition must not reclaim the
        // header after the root tab has changed.
        if let coordinator = flight.coordinator {
            displacedTransition = coordinator
        } else if let transition = flight.from.transitionCoordinator,
                  flight.matches(from: transition.viewController(forKey: .from), to: transition.viewController(forKey: .to)) {
            displacedTransition = transition as AnyObject
        }
        remove(flight)
    }

    func markPreparedCanvas(routeID: UUID) {
        guard let flight, flight.routeID == routeID else { return }
        flight.handoff.usePreparedCanvas()
    }

    func hasSuppressedHeader(for owner: UIViewController) -> Bool {
        matching(owner).contains { !$0.rendersLiveControls }
    }

    func releaseCompleted(routeID: UUID? = nil) {
        guard let flight, flight.completed, routeID == nil || flight.routeID == routeID else { return }
        remove(flight)
    }

    private func pin(from: UIViewController, to: UIViewController?, routeID: UUID?, isLayoutChange: Bool = false,
                     sourceOverride: HeaderContent? = nil, tone: PageToneTransition? = nil, interactive: Bool = false,
                     preservesDestinationViewport: Bool = false) -> Flight? {
        guard let window, window.windowScene?.activationState == .foregroundActive,
              let source = sourceOverride ?? matching(from).compactMap(\.settledHeader).first else { return nil }
        if let previous = self.flight { remove(previous) }
        let bodyTone = PageBodyHandoff.toneContext(in: window).tone
        let ownsNavigationTone = tone == nil && bodyTone == nil && !isLayoutChange
        let sharedTone = tone ?? bodyTone ?? (ownsNavigationTone ? (
            source.appearance.environment?.tabPageMotion?.canvasTone(for: from)
            ?? PageToneTransition(source: AppTheme.pageBackground(for: source.appearance.colorScheme),
                                  sourceScheme: source.appearance.colorScheme,
                                  sourceIsMedia: source.appearance.canvasRole == .playback, suspended: true)) : nil)
        guard let flight = Flight(from: from, to: to, routeID: routeID, source: source,
                                  isLayoutChange: isLayoutChange, windowBounds: window.bounds, tone: sharedTone,
                                  ownsNavigationTone: ownsNavigationTone) else { return nil }
        flight.interactive = interactive
        flight.preservesDestinationViewport = preservesDestinationViewport
        self.flight = flight
        let overlay = flight.host.view!
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        flight.interactionShield = PageInteractionShield.acquire(in: window)
        overlay.layoutIfNeeded()
        matching(from).forEach { flight.hide($0) }
        if let to {
            matching(to).forEach {
                if let incoming = $0.headerForFixedHost(alignedTo: source) {
                    flight.handoff.stageContentLayout(incoming, preservesViewport: preservesDestinationViewport)
                }
                if flight.ownsNavigationTone, let incoming = $0.headerForFixedHost(alignedTo: source) {
                    stageSurface(incoming, for: flight)
                }
                flight.hide($0)
            }
        }
        return flight
    }

    func navigationTone(from role: PageCanvasRole) -> PageToneTransition? {
        guard let flight, flight.ownsNavigationTone,
              flight.handoff.source.appearance.canvasRole == role else { return nil }
        return flight.handoff.surfaceTone
    }

    private func stageSurface(_ incoming: HeaderContent, for flight: Flight) {
        guard self.flight === flight else { return }
        let source = flight.handoff.source.appearance
        flight.handoff.stageSurface(incoming)
        if source.colorScheme == incoming.appearance.colorScheme && source.canvasRole == incoming.appearance.canvasRole {
            flight.handoff.discardTone()
        } else if !flight.interactive {
            startToneAfterHeaderFrame(flight)
        }
    }

    private func startToneAfterHeaderFrame(_ flight: Flight) {
        guard let clock = flight.handoff.surfaceTone?.clock,
              clock.startedAt == nil, !clock.finished, flight.toneFrameBoundary == nil else { return }
        // Staging writes observable state into a separate hosting controller.
        // Hold the source canvas until that host has committed the target copy.
        flight.toneFrameBoundary = RenderFrameBoundary { [weak self, weak flight] in
            guard let self, let flight else { return }
            flight.toneFrameBoundary = nil
            guard self.flight === flight, !flight.interactive || flight.completed else { return }
            clock.start()
        }
    }

    func settledContent(for controller: UIViewController) -> HeaderContent? {
        matching(controller).compactMap(\.settledHeader).first
    }

    func appearance(for controller: UIViewController) -> HeaderAppearance? {
        matching(controller).compactMap(\.settledHeader).first?.appearance
    }

    private func matching(_ controller: UIViewController) -> [NativeHeaderProbe] {
        probes.reversed().compactMap(\.value).filter { $0.belongs(to: controller) }
    }

    private func finish(_ flight: Flight, cancelled: Bool) async {
        guard self.flight === flight else { return }
        let sourceFrame = flight.handoff.source.frame
        let candidates = flight.to.map(matching) ?? probes.reversed().compactMap(\.value).filter { $0.routeID == flight.routeID }
        guard !cancelled,
              let destination = candidates.compactMap(\.currentHeader).first,
              abs(destination.frame.minX - sourceFrame.minX) <= 2,
              abs(destination.frame.minY - sourceFrame.minY) <= 2,
              abs(destination.frame.width - sourceFrame.width) <= 2 else {
            remove(flight)
            return
        }
        if flight.ownsNavigationTone {
            stageSurface(destination, for: flight)
            startToneAfterHeaderFrame(flight)
        }
        flight.handoff.stageContentLayout(destination, preservesViewport: flight.preservesDestinationViewport)
        var incoming = destination
        if flight.followsBodyProgress {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-page-return") {
                NSLog("RETURN172_LIVE cached=%@;actual=%@;role=%@",
                      HeaderHandoff.qaPixelSignature(flight.handoff.destinationControls),
                      HeaderHandoff.qaPixelSignature(HeaderHandoff.renderControls(destination)),
                      String(describing: destination.appearance.canvasRole))
            }
            #endif
            guard let staged = flight.handoff.destination,
                  abs(staged.frame.height - destination.frame.height) <= 1,
                  staged.appearance.layoutIdentity == destination.appearance.layoutIdentity,
                  staged.appearance.canvasRole == destination.appearance.canvasRole,
                  flight.prepareBody?() ?? true else { remove(flight); return }
        } else {
        while self.flight === flight {
            let revision = flight.layoutRevision
            guard await flight.handoff.replace(with: incoming, while: { self.flight === flight },
                                                prepareBody: flight.prepareBody) else {
                remove(flight)
                return
            }
            guard self.flight === flight else { return }
            guard flight.handoff.isLayoutChange, revision != flight.layoutRevision else { break }
            // Keep the pinned surface alive until the newest same-page layout
            // has completed; a rapid reversal must not reveal a stale height.
            for _ in 0..<12 {
                if let latest = candidates.compactMap(\.currentHeader).first,
                   abs(latest.frame.height - (flight.expectedLayoutHeight ?? latest.frame.height)) <= 1,
                   latest.appearance.layoutIdentity == flight.expectedLayoutIdentity {
                    incoming = latest
                    break
                }
                try? await Task.sleep(for: .milliseconds(16))
                guard self.flight === flight else { return }
            }
            if let latest = candidates.compactMap(\.currentHeader).first { incoming = latest }
            flight.handoff.continueFromDestination()
        }
        }
        remove(flight, completed: true)
    }

    private func remove(_ flight: Flight, completed: Bool = false) {
        guard self.flight === flight else { return }
        if flight.releasing {
            if !completed { release(flight, completed: false) }
            return
        }
        flight.releasing = true
        flight.toneFrameBoundary?.cancel()
        flight.toneFrameBoundary = nil
        flight.layoutCommitBoundary?.cancel()
        flight.layoutCommitBoundary = nil
        flight.handoff.cancel()
        flight.prepareBody = nil
        if flight.ownsNavigationTone { flight.handoff.surfaceTone?.clock.finish() }
        let candidates = flight.to.map(matching) ?? probes.reversed().compactMap(\.value).filter { $0.routeID == flight.routeID }
        let live = candidates.first { $0.anchor.appearance?.contentOwner == flight.handoff.destination?.appearance.contentOwner }
        if completed, let window, window.windowScene?.activationState == .foregroundActive, let live,
           let owner = flight.to ?? PageViewportGeometry.owner(of: live) {
            // The SwiftUI state callback is asynchronous. Its representable
            // must acknowledge visible controls before the final frame fence.
            flight.readyProbe = live
            flight.cancelLiveReadiness = live.afterLiveControlsRendered(owner: owner,
                contentOwner: flight.handoff.destination?.appearance.contentOwner, window: window) { [weak self, weak flight, weak live, weak owner, weak window] ready in
                guard let self, let flight else { return }
                let current = ready && window?.bounds == flight.windowBounds
                    && window?.windowScene?.activationState == .foregroundActive
                    && live?.viewIfLoaded?.window === window
                    && owner.map { live?.belongs(to: $0) == true } == true
                    && live?.anchor.appearance?.contentOwner == flight.handoff.destination?.appearance.contentOwner
                self.release(flight, completed: current)
            }
        }
        flight.hiddenProbes.forEach { $0.value?.setHandoff(nil) }
        if flight.cancelLiveReadiness == nil { release(flight, completed: false) }
    }

    private func release(_ flight: Flight, completed: Bool) {
        guard self.flight === flight else { return }
        if flight.followsBodyProgress, let id = flight.handoff.surfaceTone?.id, let window {
            PageBodyHandoff.toneContext(in: window).clearReturnTone(id)
        }
        self.flight = nil
        flight.cancelLiveReadiness?(); flight.cancelLiveReadiness = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flight.host.view.removeFromSuperview()
        let completion = flight.visualCompletion
        flight.visualCompletion = nil
        completion?(completed)
        flight.interactionShield?.release(); flight.interactionShield = nil
        CATransaction.commit()
    }
}

@MainActor
final class NativeHeaderProbe: UIViewController {
    private var settledFrame: CGRect?
    private var handoff: HeaderHandoff?
    var onHandoffChange: ((HeaderHandoff?) -> Void)?
    var rootToken: UUID?
    var nativeMotionEnabled = true
    var showsChrome = true
    var routeID: UUID?
    private var liveControlsVisible = true
    var rendersLiveControls: Bool { liveControlsVisible }
    private var controlsReady: ((Bool) -> Void)?
    private var controlsReadyBoundary: RenderFrameBoundary?
    private weak var controlsOwner: UIViewController?
    private weak var controlsWindow: UIWindow?
    private var controlsContentOwner: UUID?

    func updateControlsVisibility(_ visible: Bool) {
        liveControlsVisible = visible
        if !visible { controlsReadyBoundary?.cancel(); controlsReadyBoundary = nil }
        scheduleControlsReadiness()
    }

    func afterLiveControlsRendered(owner: UIViewController, contentOwner: UUID?, window: UIWindow,
                                  _ completion: @escaping (Bool) -> Void) -> () -> Void {
        controlsReadyBoundary?.cancel(); controlsReadyBoundary = nil
        controlsReady = completion
        controlsOwner = owner; controlsContentOwner = contentOwner; controlsWindow = window
        scheduleControlsReadiness()
        return { [weak self] in
            self?.controlsReadyBoundary?.cancel(); self?.controlsReadyBoundary = nil
            self?.controlsReady = nil
            self?.controlsOwner = nil; self?.controlsWindow = nil; self?.controlsContentOwner = nil
        }
    }

    private var controlsScopeIsCurrent: Bool {
        guard let owner = controlsOwner, let window = controlsWindow else { return false }
        return viewIfLoaded?.window === window && owner.viewIfLoaded?.window === window
            && belongs(to: owner) && anchor.appearance?.contentOwner == controlsContentOwner
    }

    func invalidateControlsReadiness() { finishControlsReadiness(false) }

    private func finishControlsReadiness(_ ready: Bool) {
        controlsReadyBoundary?.cancel(); controlsReadyBoundary = nil
        let completion = controlsReady
        controlsReady = nil; controlsOwner = nil; controlsWindow = nil; controlsContentOwner = nil
        // Detach can arrive inside a SwiftUI update; report its failed ack
        // after that update rather than mutating the overlay reentrantly.
        DispatchQueue.main.async { completion?(ready) }
    }

    private func scheduleControlsReadiness() {
        guard controlsReady != nil else { return }
        guard controlsScopeIsCurrent else { finishControlsReadiness(false); return }
        guard liveControlsVisible, controlsReadyBoundary == nil else { return }
        controlsReadyBoundary = RenderFrameBoundary { [weak self] in
            guard let self else { return }
            controlsReadyBoundary = nil
            guard controlsScopeIsCurrent else { finishControlsReadiness(false); return }
            guard liveControlsVisible else { return }
            finishControlsReadiness(anchor.visibleFrame != nil)
        }
    }
    var anchor: HeaderAnchor { view as! HeaderAnchor }

    override func loadView() {
        let anchor = HeaderAnchor()
        anchor.onWindowChange = { [weak self] in self?.scheduleControlsReadiness() }
        view = anchor
        view.isUserInteractionEnabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        invalidateControlsReadiness()
    }

    var settledHeader: HeaderContent? {
        guard let frame = settledFrame ?? anchor.visibleFrame else { return nil }
        return header(frame: frame)
    }

    /// A same-page update can lay out the new frame before its appearance is
    /// delivered. Preserve the outgoing surface height for this path only;
    /// native navigation continues to use the settled on-screen geometry.
    var layoutChangeSource: HeaderContent? {
        guard let source = settledHeader else { return nil }
        guard let height = source.appearance.surfaceHeight, height.isFinite, height > 0 else { return source }
        var frame = source.frame
        frame.size.height = height
        return HeaderContent(frame: frame, appearance: source.appearance)
    }

    func updateAppearance(_ appearance: HeaderAppearance) {
        if nativeMotionEnabled, showsChrome, activeTransition == nil,
           let old = anchor.appearance?.surfaceHeight, let next = appearance.surfaceHeight,
           (abs(old - next) > 1 || anchor.appearance?.layoutIdentity != appearance.layoutIdentity),
           let window = viewIfLoaded?.window, window.windowScene?.activationState == .foregroundActive {
            NativeHeaderMotion.forWindow(window).beginLayoutChange(from: self, expectedHeight: next, identity: appearance.layoutIdentity)
        }
        anchor.appearance = appearance
    }

    var currentHeader: HeaderContent? {
        guard let frame = anchor.visibleFrame else { return nil }
        return header(frame: frame)
    }

    /// UIKit translates the page during push, not the fixed header host. Use
    /// measured local width and declared row height in the common pinned space;
    /// final cleanup still requires the real destination's global alignment.
    func headerForFixedHost(alignedTo source: HeaderContent) -> HeaderContent? {
        guard anchor.window != nil, let appearance = anchor.appearance,
              anchor.bounds.width.isFinite, anchor.bounds.width > 1,
              abs(anchor.bounds.width - source.frame.width) <= 2 else { return nil }
        let height = appearance.surfaceHeight ?? anchor.bounds.height
        guard height.isFinite, height > 1 else { return nil }
        return header(frame: CGRect(origin: source.frame.origin, size: CGSize(width: anchor.bounds.width, height: height)))
    }

    private func header(frame: CGRect) -> HeaderContent? {
        guard let appearance = anchor.appearance else { return nil }
        return .init(frame: frame, appearance: .init(
            controls: showsChrome ? appearance.controls : AnyView(EmptyView()),
            firstRowHeight: appearance.firstRowHeight,
            colorScheme: appearance.colorScheme,
            surfaceColor: showsChrome ? appearance.surfaceColor : .clear,
            borderColor: showsChrome ? appearance.borderColor : .clear,
            surfaceHeight: appearance.surfaceHeight, environment: appearance.environment, layoutIdentity: appearance.layoutIdentity,
            canvasRole: appearance.canvasRole, contentClearance: appearance.contentClearance,
            retainsViewport: appearance.retainsViewport, contentOwner: appearance.contentOwner
        ))
    }

    private func rememberFrame() {
        guard let frame = anchor.visibleFrame else { return }
        settledFrame = frame
    }

    func belongs(to controller: UIViewController) -> Bool {
        guard let hostView = controller.viewIfLoaded, let probeView = viewIfLoaded else { return false }
        return probeView.isDescendant(of: hostView)
    }

    func setHandoff(_ handoff: HeaderHandoff?) {
        guard self.handoff !== handoff else { return }
        self.handoff = handoff
        // UIKit can call a child appearance callback during a SwiftUI update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handoff === handoff else { return }
            self.onHandoffChange?(handoff)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleControlsReadiness()
        if let transition = activeTransition {
            observeTransition(transition)
        } else {
            register()
            if handoff == nil { rememberFrame() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if animated { observeAppearanceTransition() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if animated { observeAppearanceTransition() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        register()
        rememberFrame()
    }

    private func register() {
        guard nativeMotionEnabled, let window = viewIfLoaded?.window else { return }
        NativeHeaderMotion.forWindow(window).register(self)
    }

    private var activeTransition: UIViewControllerTransitionCoordinator? {
        var controller: UIViewController? = self
        while let current = controller {
            if let transition = current.transitionCoordinator { return transition }
            controller = current.parent
        }
        return nil
    }

    private func observeAppearanceTransition() {
        if let transition = activeTransition {
            observeTransition(transition)
        } else {
            // SwiftUI can attach a representable before its full-screen
            // hosting controller gets UIKit's presentation coordinator.
            DispatchQueue.main.async { [weak self] in
                guard let self, let transition = self.activeTransition else { return }
                self.observeTransition(transition)
            }
        }
    }

    private func observeTransition(_ transition: UIViewControllerTransitionCoordinator) {
        guard nativeMotionEnabled else { return }
        let window = viewIfLoaded?.window ?? transition.viewController(forKey: .from)?.viewIfLoaded?.window
        guard let window else { return }
        let motion = NativeHeaderMotion.forWindow(window)
        motion.register(self)
        motion.start(transition, from: self)
    }
}

extension EnvironmentValues {
    @Entry var isHeaderRasterPreview = false
    @Entry var nativeHeaderRouteID: UUID? = nil
}

/// Captures the exact source before navigation changes the page hierarchy or
/// appearance. The destination registers under this route's identity.
@MainActor
final class NativeHeaderRoute {
    let id = UUID()
    weak var presenter: UIViewController?
    weak var presented: UIViewController?
    private weak var motion: NativeHeaderMotion?
    private var phase: Phase?
    // Lifecycle identity is retained weakly even when Reduce Motion disables
    // header handoff. It never changes presenter/presented animation eligibility.
    fileprivate weak var pageReturnBoundary: UIViewController?
    fileprivate weak var pageReturnPresenterBoundary: UIViewController?
    fileprivate var pageReturnIdentity: AnyHashable?

    private enum Phase { case entering, leaving }

    func preparePresentation(tone: PageToneTransition? = nil) {
        if let boundary = pageReturnPresenterBoundary ?? presenter, let from = owner(of: boundary) {
            PageEdgeReturnPolicy.cacheVisiblePage(owner: from, identity: pageReturnIdentity, cause: .cover)
        }
        guard let presenter, let from = owner(of: presenter), let window = presenter.viewIfLoaded?.window else { return }
        let motion = NativeHeaderMotion.forWindow(window)
        guard motion.beginRoute(from: from, to: nil, id: id, tone: tone) else { return }
        self.motion = motion
        phase = .entering
    }

    func prepareDismissal(animate: Bool = true, tone: PageToneTransition? = nil) {
        guard animate else {
            motion?.completeRoute(id, animate: false)
            phase = nil
            return
        }
        guard let presented, let presenter,
              let from = owner(of: presented), let to = owner(of: presenter),
              let window = presented.viewIfLoaded?.window else { return }
        let motion = NativeHeaderMotion.forWindow(window)
        motion.releaseCompleted()
        guard motion.beginRoute(from: from, to: to, id: id, tone: tone) else { return }
        self.motion = motion
        phase = .leaving
    }

    func appeared() {
        guard phase == .entering else { return }
        motion?.completeRoute(id, animate: true)
        phase = nil
    }

    func dismissed(animate: Bool) {
        // Finish synchronously before a chained author or tab route starts.
        motion?.completeRoute(id, animate: animate && phase == .leaving)
        if !animate { motion?.releaseCompleted(routeID: id) }
        phase = nil
        pageReturnBoundary = nil
    }

    var sourcePageController: UIViewController? {
        (pageReturnPresenterBoundary ?? presenter).flatMap { owner(of: $0) }
    }
    var destinationPageController: UIViewController? {
        (pageReturnBoundary ?? presented).flatMap { owner(of: $0) }
    }

    private func owner(of boundary: UIViewController) -> UIViewController? {
        if let nav = boundary.navigationController, let view = boundary.viewIfLoaded {
            return nav.viewControllers.reversed().first {
                guard let root = $0.viewIfLoaded else { return false }
                return view.isDescendant(of: root)
            }
        }
        return boundary.parent
    }
}

private struct NativeHeaderRouteBoundary: UIViewControllerRepresentable {
    let cover: NativeHeaderRoute
    let isPresented: Bool
    var onAppear: (() -> Void)?
    var onLayout: (() -> Void)?
    var onAttach: ((UUID) -> Void)?
    var onDetach: ((UUID) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: SiteSession

    func makeUIViewController(context: Context) -> Boundary {
        let controller = Boundary()
        controller.onAttach = onAttach
        controller.onDetach = onDetach
        DispatchQueue.main.async { [weak controller] in controller?.attachOwnership() }
        return controller
    }

    static func dismantleUIViewController(_ controller: Boundary, coordinator: ()) {
        controller.detachOwnership()
    }

    func updateUIViewController(_ controller: Boundary, context: Context) {
        controller.onAttach = onAttach
        controller.onDetach = onDetach
        controller.onLayout = onLayout
        cover.pageReturnIdentity = session.accountSessionID
        if isPresented {
            cover.pageReturnBoundary = controller
            cover.presented = reduceMotion ? nil : controller
            controller.onAppear = { [weak cover] in
                if let onAppear { onAppear() } else { cover?.appeared() }
            }
        } else {
            cover.pageReturnPresenterBoundary = controller
            cover.presenter = reduceMotion ? nil : controller
        }
    }

    final class Boundary: UIViewController {
        let ownershipToken = UUID()
        var onAttach: ((UUID) -> Void)?
        var onDetach: ((UUID) -> Void)?
        private var detached = false
        func attachOwnership() { if !detached { onAttach?(ownershipToken) } }
        func detachOwnership() {
            guard !detached else { return }
            detached = true
            onDetach?(ownershipToken)
        }
        var onAppear: (() -> Void)?
        var onLayout: (() -> Void)?
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onLayout?()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }
}

extension View {
    func nativeHeaderRouteBoundary(_ cover: NativeHeaderRoute, isPresented: Bool, onAppear: (() -> Void)? = nil, onLayout: (() -> Void)? = nil,
                                   onAttach: ((UUID) -> Void)? = nil, onDetach: ((UUID) -> Void)? = nil) -> some View {
        background {
            NativeHeaderRouteBoundary(cover: cover, isPresented: isPresented, onAppear: onAppear, onLayout: onLayout,
                                      onAttach: onAttach, onDetach: onDetach)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .environment(\.nativeHeaderRouteID, isPresented ? cover.id : nil)
    }
}
