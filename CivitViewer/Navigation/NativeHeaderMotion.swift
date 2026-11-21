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
        var nativeProgress: NativeNavigationProgress?
        var nativeRouteAnimation: Bool?
        var activationLease: PageVisualActivationLease?
        var sharesCanvasTone = false
        var canvasToken: UUID?
        var canvasReadiness: RenderFrameBoundary?
        var canvasReadinessCompletion: ((Bool) -> Void)?
        let ownsNavigationTone: Bool
        let id = UUID()
        var layoutRevision = 0
        var expectedLayoutHeight: CGFloat?
        var expectedLayoutIdentity: AnyHashable?
        var interaction: PageTransitionInput?
        weak var coordinator: AnyObject?
        var hiddenProbes: [WeakProbe] = []
        var toneFrameBoundary: RenderFrameBoundary?
        var layoutCommitBoundary: RenderFrameBoundary?
        var preservesDestinationViewport = false
        var visualCompletion: ((Bool) -> Void)?
        var prepareBody: (() -> Bool)?
        var releasing = false
        var cancelLiveReadiness: (() -> Void)?
        var liveReadinessDeadline: Task<Void, Never>?
        var navigationDeadline: Task<Void, Never>?
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

        deinit {
            liveReadinessDeadline?.cancel()
            navigationDeadline?.cancel()
            MainActor.assumeIsolated { nativeProgress?.stop(); activationLease?.release() }
        }
    }

    @MainActor
    private final class NativeNavigationProgress: NSObject {
        private let proxy = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        private var link: CADisplayLink?
        private weak var motion: NativeHeaderMotion?
        private weak var flight: Flight?

        func start(in container: UIView, motion: NativeHeaderMotion, flight: Flight) {
            self.motion = motion
            self.flight = flight
            proxy.backgroundColor = .clear
            proxy.isOpaque = false
            proxy.isUserInteractionEnabled = false
            proxy.isAccessibilityElement = false
            proxy.accessibilityElementsHidden = true
            container.addSubview(proxy)
            // UIKit applies its transition timing to this one-point transform.
            proxy.transform = CGAffineTransform(translationX: 1, y: 0)
            let link = CADisplayLink(target: self, selector: #selector(sample))
            self.link = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func sample() {
            guard let motion, let flight else { stop(); return }
            motion.sampleNativeNavigation(flight, proxy: proxy)
        }

        func stop() {
            link?.invalidate()
            link = nil
            proxy.layer.removeAllAnimations()
            proxy.removeFromSuperview()
        }
    }

    private struct Overlay: View {
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
            if isDestination, flight.nativeProgress == nil,
               let incoming = probe.headerForFixedHost(alignedTo: flight.handoff.source) {
                flight.handoff.stageContentLayout(incoming, preservesViewport: flight.preservesDestinationViewport)
                if flight.ownsNavigationTone { stageSurface(incoming, for: flight) }
            }
            flight.hide(probe)
            if flight.routeID != nil, let window, let overlay = flight.host.viewIfLoaded,
               overlay.superview === window, window.subviews.last !== overlay {
                window.bringSubviewToFront(overlay)
            }
        }
    }

    func start(_ transition: UIViewControllerTransitionCoordinator, from probe: NativeHeaderProbe) {
        if flight?.canvasToken != nil { return }
        let coordinator = transition as AnyObject
        guard coordinator !== displacedTransition, transition.isAnimated,
              let navigation = probe.navigationController, let navigationView = navigation.viewIfLoaded,
              transition.containerView.isDescendant(of: navigationView),
              let from = transition.viewController(forKey: .from),
              let to = transition.viewController(forKey: .to), from !== to,
              probe.belongs(to: from) || probe.belongs(to: to) else { return }
        let usesNativeProgress = transition.presentationStyle == .none && transition.targetTransform.isIdentity
            && !transition.initiallyInteractive && !transition.isInteractive
        let stack = navigation.viewControllers
        let isPush = stack.last === to && stack.dropLast().contains { $0 === from }
        if let flight {
            guard flight.coordinator !== coordinator else { return }
            if flight.routeID != nil, flight.coordinator == nil, flight.matches(from: from, to: to) {
                flight.coordinator = coordinator
                flight.interactive = transition.isInteractive
                let acceptsNativeProgress = usesNativeProgress && (flight.to != nil || isPush)
                // UIKit now supplies the exact destination owner. A SwiftUI
                // destination may register its probe before route environment
                // propagation; do not keep matching it by an optional route ID.
                flight.to = to
                if acceptsNativeProgress { useNativeProgress(for: flight) }
                matching(to).forEach { register($0) }
                if flight.nativeProgress != nil { observeNavigation(transition, flight: flight, isPush: isPush) }
                return
            }
            guard flight.completed, flight.routeID != nil || flight.from !== from || flight.to !== to else { return }
            remove(flight)
        }
        // UIKit owns input arbitration for its navigation. The pinned header
        // is visual only and cannot hold input while waiting for a callback.
        guard let flight = pin(from: from, to: to, routeID: nil, interactive: transition.isInteractive,
                               nativeNavigation: usesNativeProgress, holdsWindowInput: false) else { return }
        flight.coordinator = coordinator
        flight.interactive = transition.isInteractive
        observeNavigation(transition, flight: flight, isPush: isPush)
    }

    private func observeNavigation(_ transition: UIViewControllerTransitionCoordinator, flight: Flight, isPush: Bool) {
        let registered = transition.animate(alongsideTransition: { [weak self, weak flight] context in
            guard let self, let flight, self.flight === flight else { return }
            self.window?.bringSubviewToFront(flight.host.view)
            flight.nativeProgress?.start(in: context.containerView, motion: self, flight: flight)
        }, completion: { [weak self, weak flight] context in
            guard let self, let flight, self.flight === flight else { return }
            #if DEBUG && targetEnvironment(simulator)
            if isPush, ProcessInfo.processInfo.arguments.contains("--qa-drop-native-push-completion") {
                TransitionCostQA174.record("nativeHeader.pushCompletionDropped", TransitionCostQA174.start)
                return
            }
            if !isPush, ProcessInfo.processInfo.arguments.contains("--qa-drop-native-pop-completion") {
                TransitionCostQA174.record("nativeHeader.popCompletionDropped", TransitionCostQA174.start)
                return
            }
            #endif
            flight.completed = true
            flight.navigationDeadline?.cancel()
            flight.navigationDeadline = nil
            if flight.nativeProgress == nil { boundNativeFlight(flight, after: .milliseconds(650)) }
            flight.nativeProgress?.stop()
            let cancelled = context.isCancelled
            Task { @MainActor in await self.finish(flight, cancelled: cancelled) }
        })
        guard registered else { remove(flight); return }
        if transition.isInteractive {
            transition.notifyWhenInteractionChanges { [weak self, weak flight] _ in
                if let self, let flight, !flight.completed { self.boundNativeFlight(flight) }
            }
        } else {
            if !flight.completed { boundNativeFlight(flight) }
        }
    }

    private func boundNativeFlight(_ flight: Flight, after duration: Duration = .milliseconds(900)) {
        guard self.flight === flight, flight.navigationDeadline == nil else { return }
        flight.navigationDeadline = Task { [weak self, weak flight] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, let flight, self.flight === flight else { return }
            #if DEBUG && targetEnvironment(simulator)
            TransitionCostQA174.record("nativeHeader.deadline", TransitionCostQA174.start)
            #endif
            // UIKit still owns the route. Only this copy and its input hold expire.
            self.remove(flight)
        }
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
                    preservesDestinationViewport: Bool = false, inputOwnedByBody: Bool = false,
                    layoutWithDestination: Bool = false) -> Bool {
        if let flight {
            guard flight.completed else { return false }
            remove(flight)
        }
        guard let flight = pin(from: from, to: to, routeID: id, tone: tone,
                               preservesDestinationViewport: preservesDestinationViewport,
                               holdsWindowInput: !inputOwnedByBody, layoutWithDestination: layoutWithDestination) else { return false }
        boundNativeFlight(flight)
        return true
    }

    var canBeginBodyReturn: Bool { flight == nil }

    /// The body driver owns this route's progress and cancellation. It starts
    /// only at an idle chrome boundary, never by stealing a forward flight.
    func beginBodyReturn(from: UIViewController, to: UIViewController, id: UUID, cachedTarget: HeaderContent?) -> PageToneTransition? {
        guard flight == nil, let window,
              let source = matching(from).compactMap(\.settledHeader).first else { return nil }
        let target: HeaderContent?
        if let saved = cachedTarget,
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
        guard abs(source.frame.width - target.frame.width) <= 2,
              abs(source.frame.minY - target.frame.minY) <= 2 else { return nil }
        let tone = PageToneTransition(source: source.appearance.canvasRole == .playback ? .black : AppTheme.pageBackground(for: source.appearance.colorScheme),
            sourceScheme: source.appearance.colorScheme, sourceIsMedia: source.appearance.canvasRole == .playback,
            suspended: true, destinationScheme: target.appearance.colorScheme,
            destinationIsMedia: target.appearance.canvasRole == .playback)
        guard let flight = pin(from: from, to: to, routeID: id, tone: tone, interactive: true,
                               preservesDestinationViewport: true, holdsWindowInput: false) else { return nil }
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
        guard let flight, flight.routeID == id else { completion?(false); return }
        if flight.nativeProgress != nil, !flight.releasing {
            guard flight.nativeRouteAnimation == nil else { completion?(false); return }
            // The child can appear before UIKit's animation has finished.
            flight.nativeRouteAnimation = animate
            flight.visualCompletion = completion
            flight.prepareBody = prepareBody
            return
        }
        guard !flight.completed else { completion?(false); return }
        flight.visualCompletion = completion
        flight.prepareBody = prepareBody
        flight.completed = true
        if let token = flight.canvasToken, !animate {
            let callback = flight.visualCompletion; flight.visualCompletion = nil
            consumeCanvasControls(token: token)
            callback?(false)
            return
        }
        if flight.canvasToken != nil {
            let prepared = prepareBody?() ?? true
            let callback = flight.visualCompletion; flight.visualCompletion = nil
            if callback != nil {
                callback?(animate && prepared)
                if !prepared && self.flight === flight { remove(flight) }
            }
            else if let token = flight.canvasToken { consumeCanvasControls(token: token) }
            return
        }
        if flight.followsBodyProgress {
            let prepared = animate && (prepareBody?() ?? true)
            let callback = flight.visualCompletion; flight.visualCompletion = nil
            if callback != nil { callback?(prepared) }
            if self.flight === flight { remove(flight) }
            return
        }
        if animate {
            flight.navigationDeadline?.cancel()
            flight.navigationDeadline = nil
            boundNativeFlight(flight, after: .milliseconds(650))
            Task { @MainActor in await finish(flight, cancelled: false) }
        }
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
        guard let flight, flight.canvasToken == nil, flight.completed, routeID == nil || flight.routeID == routeID else { return }
        remove(flight)
    }

    /// Full-canvas presentations have one visual owner. UIKit still supplies
    /// the mount/pop receipt; it does not start a second controls animation.
    @discardableResult
    func beginCanvasControls(token: UUID, source: UIViewController, tone: PageToneTransition?) -> Bool {
        guard let window, window.windowScene?.activationState == .foregroundActive else { return false }
        if let existing = flight {
            if existing.canvasToken == token { return true }
            if existing.followsBodyProgress,
               let expected = tone?.id, existing.handoff.surfaceTone?.id == expected {
                existing.canvasToken = token
                return true
            }
            guard existing.completed else { return false }
            remove(existing)
        }
        guard let current = pin(from: source, to: nil, routeID: nil, tone: tone,
                                interactive: true, preservesDestinationViewport: true,
                                holdsWindowInput: false) else { return false }
        current.canvasToken = token
        return true
    }

    @discardableResult
    func stageCanvasControls(token: UUID, destination: UIViewController) -> Bool {
        guard let current = flight, current.canvasToken == token, let window,
              window.bounds == current.windowBounds, destination.viewIfLoaded?.window === window,
              let probe = matching(destination).first(where: { PageViewportGeometry.owner(of: $0) === destination }),
              let content = probe.headerForFixedHost(alignedTo: current.handoff.source),
              current.handoff.stageRoot(content) else { return false }
        current.to = destination
        current.handoff.stageContentLayout(content, preservesViewport: true)
        matching(destination).forEach { current.hide($0) }
        return true
    }

    func updateCanvasControls(token: UUID, progress: Double) {
        guard let current = flight, current.canvasToken == token else { return }
        current.handoff.surfaceTone?.clock.setInteractiveProgress(progress)
        current.handoff.updatePageProgress(progress)
    }

    func prepareCanvasControlsForReveal(token: UUID, destination: UIViewController,
                                       completion: @escaping (Bool) -> Void) {
        guard let current = flight, current.canvasToken == token else { completion(true); return }
        guard let window, current.to === destination, window.bounds == current.windowBounds,
              destination.viewIfLoaded?.window === window,
              let probe = matching(destination).first(where: { PageViewportGeometry.owner(of: $0) === destination }),
              let expected = current.handoff.destination else { completion(false); return }
        finishCanvasReadiness(current, ready: false)
        guard self.flight === current else { completion(false); return }
        current.canvasReadinessCompletion = completion
        current.canvasReadiness = RenderFrameBoundary { [weak self, weak current, weak probe, weak destination, weak window] in
            guard let self, let current, let probe, let destination, let window,
                  self.flight === current, current.canvasToken == token,
                  window.bounds == current.windowBounds,
                  window.windowScene?.activationState == .foregroundActive,
                  destination.viewIfLoaded?.window === window, current.to === destination,
                  probe.belongs(to: destination), probe.controlsArePrepared(in: window),
                  probe.anchor.appearance?.contentOwner == expected.appearance.contentOwner,
                  probe.anchor.appearance?.layoutIdentity == expected.appearance.layoutIdentity,
                  probe.anchor.appearance?.canvasRole == expected.appearance.canvasRole else {
                if let self, let current, self.flight === current {
                    self.finishCanvasReadiness(current, ready: false)
                    if self.flight === current { self.remove(current) }
                }
                return
            }
            self.finishCanvasReadiness(current, ready: true)
        }
    }

    private func finishCanvasReadiness(_ flight: Flight, ready: Bool) {
        flight.canvasReadiness?.cancel(); flight.canvasReadiness = nil
        let completion = flight.canvasReadinessCompletion
        flight.canvasReadinessCompletion = nil
        completion?(ready)
    }

    /// Called inside the body owner's terminal transaction, while the body and
    /// footer are handed to their real target. No visible ACK overlap follows.
    func consumeCanvasControls(token: UUID) {
        guard let current = flight, current.canvasToken == token else { return }
        finishCanvasReadiness(current, ready: false)
        guard self.flight === current else { return }
        current.canvasToken = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current.host.view.alpha = 0
        current.hiddenProbes.forEach { $0.value?.setHandoff(nil) }
        current.hiddenProbes.removeAll()
        release(current, completed: true)
        CATransaction.commit()
    }

    private func pin(from: UIViewController, to: UIViewController?, routeID: UUID?, isLayoutChange: Bool = false,
                     sourceOverride: HeaderContent? = nil, tone: PageToneTransition? = nil, interactive: Bool = false,
                     preservesDestinationViewport: Bool = false, nativeNavigation: Bool = false,
                     holdsWindowInput: Bool = true, layoutWithDestination: Bool = false) -> Flight? {
        #if DEBUG && targetEnvironment(simulator)
        let pinStart = TransitionCostQA174.start
        defer { TransitionCostQA174.record("nativeHeader.pin", pinStart) }
        #endif
        let sourceProbe = sourceOverride == nil ? matching(from).first { $0.settledHeader != nil } : nil
        guard let window, window.windowScene?.activationState == .foregroundActive,
              let source = sourceOverride ?? sourceProbe?.settledHeader else { return nil }
        if let previous = self.flight { remove(previous) }
        let bodyTone = PageBodyHandoff.toneContext(in: window).tone
        let ownsNavigationTone = tone == nil && bodyTone == nil && !isLayoutChange
        let existingCanvasTone = ownsNavigationTone ? source.appearance.environment?.tabPageMotion?.canvasTone(for: from) : nil
        let sharedTone = tone ?? bodyTone ?? (ownsNavigationTone ? (
            existingCanvasTone
            ?? PageToneTransition(source: AppTheme.pageBackground(for: source.appearance.colorScheme),
                                  sourceScheme: source.appearance.colorScheme,
                                  sourceIsMedia: source.appearance.canvasRole == .playback, suspended: true)) : nil)
        guard let flight = Flight(from: from, to: to, routeID: routeID, source: source,
                                  isLayoutChange: isLayoutChange, windowBounds: window.bounds, tone: sharedTone,
                                  ownsNavigationTone: ownsNavigationTone) else { return nil }
        flight.interactive = interactive
        flight.preservesDestinationViewport = preservesDestinationViewport
        flight.sharesCanvasTone = existingCanvasTone != nil
        self.flight = flight
        if nativeNavigation, sourceProbe?.hasVisibleChrome == true { useNativeProgress(for: flight) }
        let overlay = flight.host.view!
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.alpha = 0
        window.addSubview(overlay)
        guard self.flight === flight else { return nil }
        if holdsWindowInput {
            let input = PageTransitionInput(token: flight.id)
            flight.interaction = input
            guard input.acquire(in: window, source: .nativeHeader), self.flight === flight else { return nil }
        }
        #if DEBUG && targetEnvironment(simulator)
        let layoutStart = TransitionCostQA174.start
        #endif
        // A forward push already schedules a window layout in this transaction.
        // Its pinned source raster has a known frame and needs no measurement here.
        if layoutWithDestination { overlay.setNeedsLayout() }
        else { overlay.layoutIfNeeded() }
        #if DEBUG && targetEnvironment(simulator)
        TransitionCostQA174.record("nativeHeader.overlayLayout", layoutStart)
        #endif
        guard self.flight === flight else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        matching(from).forEach { flight.hide($0) }
        if let to {
            matching(to).forEach {
                if flight.nativeProgress == nil, let incoming = $0.headerForFixedHost(alignedTo: source) {
                    flight.handoff.stageContentLayout(incoming, preservesViewport: flight.preservesDestinationViewport)
                    if flight.ownsNavigationTone { stageSurface(incoming, for: flight) }
                }
                flight.hide($0)
            }
        }
        overlay.alpha = 1
        CATransaction.commit()
        NavigationDiagnostics.mark(.headerInstalled, owner: .nativeHeader)
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
        // A detached page may have a valid palette before its frame is settled.
        matching(controller).compactMap { ($0.viewIfLoaded as? HeaderAnchor)?.appearance }.first
    }

    private func matching(_ controller: UIViewController) -> [NativeHeaderProbe] {
        probes.reversed().compactMap(\.value).filter { $0.belongs(to: controller) }
    }

    private func useNativeProgress(for flight: Flight) {
        guard !flight.completed, !flight.handoff.isLayoutChange, !flight.followsBodyProgress,
              flight.canvasToken == nil, flight.ownsNavigationTone, !flight.sharesCanvasTone,
              let window, window.bounds == flight.windowBounds,
              !PageBodyHandoff.hasActiveFlight(in: window), PageBodyHandoff.toneContext(in: window).tone == nil else { return }
        let activation = flight.to.flatMap { PageBodyViewports.suspendActivation(in: $0, token: flight.id) }
            ?? PageBodyViewports.suspendActivation(in: flight.from, token: flight.id)
        guard let activation else { return }
        flight.activationLease = activation
        flight.nativeProgress = NativeNavigationProgress()
        // Each navigation endpoint keeps its own final viewport. Only an
        // in-page row-count change interpolates the page's content clearance.
        flight.preservesDestinationViewport = true
        flight.toneFrameBoundary?.cancel()
        flight.toneFrameBoundary = nil
        flight.handoff.surfaceTone?.clock.setInteractiveProgress(0)
    }

    private func nativeDestination(for flight: Flight, in window: UIWindow) -> (NativeHeaderProbe, HeaderContent)? {
        guard let to = flight.to, to.viewIfLoaded?.window === window else { return nil }
        return matching(to).lazy.compactMap { probe -> (NativeHeaderProbe, HeaderContent)? in
            guard probe.nativeMotionEnabled, probe.hasVisibleChrome, probe.viewIfLoaded?.window === window,
                  PageViewportGeometry.owner(of: probe) === to,
                  let content = probe.headerForFixedHost(alignedTo: flight.handoff.source) else { return nil }
            return (probe, content)
        }.first
    }

    private func sampleNativeNavigation(_ flight: Flight, proxy: UIView) {
        guard self.flight === flight, !flight.completed else { return }
        guard let window, proxy.window === window, window.bounds == flight.windowBounds,
              window.windowScene?.activationState == .foregroundActive else { remove(flight); return }
        // The model transform already holds the endpoint during a UIKit animation.
        guard let progress = proxy.layer.presentation()?.transform.m41, progress.isFinite else { return }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-header-motion") {
            flight.handoff.nativeNavigationProgress181 = Double(progress)
        }
        #endif
        if flight.handoff.destination == nil {
            guard let (_, incoming) = nativeDestination(for: flight, in: window) else { return }
            flight.handoff.stageContentLayout(incoming, preservesViewport: flight.preservesDestinationViewport)
            guard flight.handoff.stageRoot(incoming) else { remove(flight); return }
            let source = flight.handoff.source.appearance
            if incoming.appearance.colorScheme == source.colorScheme && incoming.appearance.canvasRole == source.canvasRole {
                flight.handoff.discardTone()
            }
        }
        let value = Double(progress)
        flight.handoff.surfaceTone?.clock.setInteractiveProgress(value)
        flight.handoff.updatePageProgress(value)
    }

    private func finishNativeNavigation(_ flight: Flight, cancelled: Bool) {
        let progress = cancelled ? 0.0 : 1.0
        #if DEBUG && targetEnvironment(simulator)
        flight.handoff.nativeNavigationProgress181 = progress
        #endif
        flight.handoff.surfaceTone?.clock.setInteractiveProgress(progress)
        flight.handoff.updatePageProgress(progress)
        // Late or replaced targets hand straight back to live controls.
        guard !cancelled, flight.nativeRouteAnimation != false, let window, window.bounds == flight.windowBounds,
              window.windowScene?.activationState == .foregroundActive,
              let staged = flight.handoff.destination,
              let (probe, _) = nativeDestination(for: flight, in: window), let live = probe.currentHeader,
              probe.canReleaseNativeHandoff(in: window),
              live.appearance.canvasRole == staged.appearance.canvasRole,
              live.appearance.contentOwner == staged.appearance.contentOwner,
              live.appearance.layoutIdentity == staged.appearance.layoutIdentity,
              abs(live.frame.minX - staged.frame.minX) <= 2, abs(live.frame.minY - staged.frame.minY) <= 2,
              abs(live.frame.width - staged.frame.width) <= 2, abs(live.frame.height - staged.frame.height) <= 1 else {
            remove(flight)
            return
        }
        guard flight.prepareBody?() ?? true else { remove(flight); return }
        guard self.flight === flight else { return }
        flight.readyProbe = probe
        remove(flight, completed: true)
    }

    private func finish(_ flight: Flight, cancelled: Bool) async {
        guard self.flight === flight else { return }
        if flight.nativeProgress != nil {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-native-activation181"),
               !cancelled, flight.handoff.destination?.appearance.canvasRole == .playback {
                flight.handoff.updatePageProgress(1)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.flight === flight else { return }
            }
            #endif
            finishNativeNavigation(flight, cancelled: cancelled)
            return
        }
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
        if let coordinator = flight.coordinator { displacedTransition = coordinator }
        flight.nativeProgress?.stop()
        flight.navigationDeadline?.cancel()
        flight.navigationDeadline = nil
        finishCanvasReadiness(flight, ready: false)
        guard self.flight === flight else { return }
        flight.toneFrameBoundary?.cancel()
        flight.toneFrameBoundary = nil
        flight.layoutCommitBoundary?.cancel()
        flight.layoutCommitBoundary = nil
        flight.handoff.cancel()
        flight.prepareBody = nil
        if flight.ownsNavigationTone { flight.handoff.surfaceTone?.clock.finish() }
        let candidates = flight.to.map(matching) ?? probes.reversed().compactMap(\.value).filter { $0.routeID == flight.routeID }
        let live = flight.readyProbe ?? candidates.first {
            $0.anchor.appearance?.contentOwner == flight.handoff.destination?.appearance.contentOwner
        }
        if completed, let window, window.windowScene?.activationState == .foregroundActive, let live,
           let owner = flight.to ?? PageViewportGeometry.owner(of: live) {
            // The SwiftUI state callback is asynchronous. Its representable
            // must acknowledge visible controls before the final frame fence.
            flight.readyProbe = live
            flight.cancelLiveReadiness = live.afterLiveControlsRendered(owner: owner,
                contentOwner: flight.handoff.destination?.appearance.contentOwner, window: window) { [weak self, weak flight, weak live, weak owner, weak window] ready in
                guard let self, let flight else { return }
                #if DEBUG && targetEnvironment(simulator)
                if ready, ProcessInfo.processInfo.arguments.contains("--qa-drop-author-live-ack183") { return }
                #endif
                let current = ready && window?.bounds == flight.windowBounds
                    && window?.windowScene?.activationState == .foregroundActive
                    && live?.viewIfLoaded?.window === window
                    && owner.map { live?.belongs(to: $0) == true } == true
                    && live?.anchor.appearance?.contentOwner == flight.handoff.destination?.appearance.contentOwner
                self.release(flight, completed: current)
            }
            // UIKit already finished. Bound the remaining visual wait even
            // if the probe disappears or its render confirmation is dropped.
            flight.liveReadinessDeadline = Task { [weak self, weak flight] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let flight, self.flight === flight else { return }
                self.release(flight, completed: false)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flight.host.view.alpha = 0
        flight.hiddenProbes.forEach { $0.value?.setHandoff(nil) }
        if completed {
            // The live page already owns navigation. A hidden header copy
            // waiting for render confirmation cannot keep blocking its input.
            flight.interaction?.release(flight.id)
            flight.interaction = nil
        }
        CATransaction.commit()
        if flight.cancelLiveReadiness == nil { release(flight, completed: false) }
    }

    private func release(_ flight: Flight, completed: Bool) {
        guard self.flight === flight else { return }
        if flight.followsBodyProgress, let id = flight.handoff.surfaceTone?.id, let window {
            PageBodyHandoff.toneContext(in: window).clearReturnTone(id)
        }
        self.flight = nil
        flight.liveReadinessDeadline?.cancel(); flight.liveReadinessDeadline = nil
        flight.cancelLiveReadiness?(); flight.cancelLiveReadiness = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flight.host.view.removeFromSuperview()
        flight.activationLease?.release(); flight.activationLease = nil
        let completion = flight.visualCompletion
        flight.visualCompletion = nil
        flight.interaction?.release(flight.id)
        flight.interaction = nil
        completion?(completed)
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
    private var controlsHostingController: UIHostingController<AnyView>?
    private var controlsDrawable: PageControlDrawable?
    private var controlsVerticalInset: CGFloat = 0
    private var controlsTopConstraint: NSLayoutConstraint?
    private var controlsBottomConstraint: NSLayoutConstraint?
    private final class VisibilityObserver {
        weak var owner: UIViewController?
        weak var window: UIWindow?
        let scene: ObjectIdentifier?
        let contentOwner: UUID?
        let callback: (Bool) -> Void
        init(owner: UIViewController, window: UIWindow, contentOwner: UUID?, callback: @escaping (Bool) -> Void) {
            self.owner = owner; self.window = window
            self.scene = window.windowScene.map { ObjectIdentifier($0) }
            self.contentOwner = contentOwner; self.callback = callback
        }
    }
    private var controlsVisibilityObservers: [UUID: VisibilityObserver] = [:]
    private let nativeHandoffSuppressionToken = UUID()
    var rendersLiveControls: Bool { controlsDrawable?.isDrawable ?? false }
    fileprivate var hasVisibleChrome: Bool { showsChrome && liveControlsVisible }
    func controlsArePrepared(in window: UIWindow) -> Bool {
        guard viewIfLoaded?.window === window, let content = controlsHostingController?.viewIfLoaded,
              content.window === window, content.bounds.width > 1, content.bounds.height > 1,
              anchor.bounds.width > 1, anchor.bounds.height > 1 else { return false }
        content.layoutIfNeeded()
        return true
    }
    fileprivate func canReleaseNativeHandoff(in window: UIWindow) -> Bool {
        guard controlsArePrepared(in: window), let drawable = controlsDrawable,
              drawable.view === controlsHostingController?.viewIfLoaded,
              drawable.baseVisible else { return false }
        return drawable.captureSuppression.subtracting([nativeHandoffSuppressionToken]).isEmpty
    }
    private var controlsReady: ((Bool) -> Void)?
    private var controlsReadinessID: UUID?
    private var controlsReadyBoundary: RenderFrameBoundary?
    private weak var controlsOwner: UIViewController?
    private weak var controlsWindow: UIWindow?
    private var controlsContentOwner: UUID?

    func updateControlsVisibility(_ visible: Bool) {
        liveControlsVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controlsDrawable?.setBaseVisible(visible && showsChrome)
        notifyControlsVisibilityObservers()
        CATransaction.commit()
        if !visible { controlsReadyBoundary?.cancel(); controlsReadyBoundary = nil }
        scheduleControlsReadiness()
    }

    /// Installs the transparent live-control drawing child. The anchor remains
    /// the navigation identity and measures the same inset frame as before.
    func updateControlsContent(_ content: AnyView, verticalInset: CGFloat) {
        loadViewIfNeeded()
        controlsVerticalInset = verticalInset.isFinite ? max(0, verticalInset) : 0
        anchor.verticalInset = controlsVerticalInset
        if let hosting = controlsHostingController {
            hosting.rootView = AnyView(content.frame(maxWidth: .infinity))
        } else {
            let hosting = UIHostingController(rootView: AnyView(content.frame(maxWidth: .infinity)))
            hosting.view.backgroundColor = .clear
            hosting.view.isOpaque = false
            hosting.safeAreaRegions = []
            addChild(hosting)
            anchor.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            let top = hosting.view.topAnchor.constraint(equalTo: anchor.topAnchor)
            let bottom = hosting.view.bottomAnchor.constraint(equalTo: anchor.bottomAnchor)
            controlsTopConstraint = top; controlsBottomConstraint = bottom
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: anchor.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
                top, bottom
            ])
            hosting.didMove(toParent: self)
            controlsHostingController = hosting
            let drawable = PageControlDrawable(view: hosting.view, kind: .header, visible: liveControlsVisible && showsChrome)
            drawable.onVisibilityChange = { [weak self] in
                self?.notifyControlsVisibilityObservers()
                self?.scheduleControlsReadiness()
            }
            controlsDrawable = drawable
            if handoff != nil { drawable.suppress(nativeHandoffSuppressionToken) }
            PageBodyViewports.register(drawable)
        }
        anchor.setNeedsLayout()
        if anchor.appearance != nil { notifyControlsVisibilityObservers() }
    }

    func controlsSizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let width = proposal.width ?? anchor.bounds.width
        if let declared = anchor.appearance?.surfaceHeight, declared.isFinite, declared > 0 {
            return CGSize(width: width, height: declared + 2 * controlsVerticalInset)
        }
        let available = CGSize(width: width > 0 ? width : UIView.layoutFittingCompressedSize.width,
                               height: .greatestFiniteMagnitude)
        let measured = controlsHostingController?.sizeThatFits(in: available)
            ?? CGSize(width: width, height: FloatingPageChrome.controlHeight)
        return CGSize(width: proposal.width ?? measured.width,
                      height: measured.height)
    }

    @discardableResult
    func observeControlsVisibility(owner: UIViewController, contentOwner: UUID?, window: UIWindow, token: UUID,
                                   callback: @escaping (Bool) -> Void) -> () -> Void {
        let observer = VisibilityObserver(owner: owner, window: window, contentOwner: contentOwner, callback: callback)
        controlsVisibilityObservers[token] = observer
        notifyControlsVisibilityObservers()
        return { [weak self, weak observer] in
            guard let self, let observer, self.controlsVisibilityObservers[token] === observer else { return }
            self.controlsVisibilityObservers.removeValue(forKey: token)
        }
    }

    private func notifyControlsVisibilityObservers() {
        let window = viewIfLoaded?.window
        controlsVisibilityObservers = controlsVisibilityObservers.filter { $0.value.owner != nil && $0.value.window != nil }
        for observer in controlsVisibilityObservers.values {
            guard let owner = observer.owner, let expectedWindow = observer.window,
                  let currentWindow = window, currentWindow === expectedWindow,
                  owner.viewIfLoaded?.window === expectedWindow,
                  expectedWindow.windowScene.map({ ObjectIdentifier($0) }) == observer.scene,
                  belongs(to: owner), anchor.appearance?.contentOwner == observer.contentOwner else {
                observer.callback(false)
                continue
            }
            observer.callback(rendersLiveControls)
        }
    }

    func afterLiveControlsRendered(owner: UIViewController, contentOwner: UUID?, window: UIWindow,
                                  _ completion: @escaping (Bool) -> Void) -> () -> Void {
        finishControlsReadiness(false)
        let request = UUID()
        controlsReadinessID = request
        controlsReady = completion
        controlsOwner = owner; controlsContentOwner = contentOwner; controlsWindow = window
        scheduleControlsReadiness()
        return { [weak self] in
            guard let self, self.controlsReadinessID == request else { return }
            _ = self.takeControlsReadiness()
        }
    }

    private var controlsScopeIsCurrent: Bool {
        guard let owner = controlsOwner, let window = controlsWindow else { return false }
        return viewIfLoaded?.window === window && owner.viewIfLoaded?.window === window
            && belongs(to: owner) && anchor.appearance?.contentOwner == controlsContentOwner
    }

    func invalidateControlsReadiness() { finishControlsReadiness(false) }

    private func takeControlsReadiness() -> ((Bool) -> Void)? {
        controlsReadyBoundary?.cancel(); controlsReadyBoundary = nil
        let completion = controlsReady
        controlsReadinessID = nil
        controlsReady = nil; controlsOwner = nil; controlsWindow = nil; controlsContentOwner = nil
        return completion
    }

    private func finishControlsReadiness(_ ready: Bool) {
        guard let completion = takeControlsReadiness() else { return }
        // Detach can arrive inside a SwiftUI update; report its failed ack
        // after that update rather than mutating the overlay reentrantly.
        DispatchQueue.main.async { completion(ready) }
    }

    private func scheduleControlsReadiness() {
        guard let request = controlsReadinessID else { return }
        guard controlsScopeIsCurrent else { finishControlsReadiness(false); return }
        guard rendersLiveControls, controlsReadyBoundary == nil else { return }
        controlsReadyBoundary = RenderFrameBoundary { [weak self] in
            guard let self, self.controlsReadinessID == request else { return }
            controlsReadyBoundary = nil
            guard controlsScopeIsCurrent else { finishControlsReadiness(false); return }
            guard rendersLiveControls else { return }
            finishControlsReadiness(anchor.visibleFrame != nil)
        }
    }
    var anchor: HeaderAnchor { view as! HeaderAnchor }

    override func loadView() {
        let anchor = HeaderAnchor()
        anchor.onWindowChange = { [weak self] in
            self?.scheduleControlsReadiness()
            self?.notifyControlsVisibilityObservers()
        }
        view = anchor
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = true
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controlsDrawable?.setBaseVisible(liveControlsVisible && showsChrome)
        notifyControlsVisibilityObservers()
        CATransaction.commit()
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if handoff == nil { controlsDrawable?.release(nativeHandoffSuppressionToken) }
        else { controlsDrawable?.suppress(nativeHandoffSuppressionToken) }
        notifyControlsVisibilityObservers()
        CATransaction.commit()
        scheduleControlsReadiness()
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

    func preparePresentation(tone: PageToneTransition? = nil, layoutWithDestination: Bool = false) {
        if let boundary = pageReturnPresenterBoundary ?? presenter, let from = owner(of: boundary) {
            let identity = pageReturnIdentity
            PageEdgeReturnPolicy.cacheVisiblePage(owner: from, identity: identity, cause: .cover,
                isCurrent: { [weak self, weak boundary, weak from] in
                    guard let self, let boundary, let from,
                          (self.pageReturnPresenterBoundary ?? self.presenter) === boundary,
                          self.pageReturnIdentity == identity,
                          self.owner(of: boundary) === from else { return false }
                    return true
                })
        }
        guard let presenter, let from = owner(of: presenter), let window = presenter.viewIfLoaded?.window else { return }
        let motion = NativeHeaderMotion.forWindow(window)
        guard motion.beginRoute(from: from, to: nil, id: id, tone: tone, layoutWithDestination: layoutWithDestination) else { return }
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
