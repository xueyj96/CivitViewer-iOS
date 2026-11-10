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
    private static var windowKey: UInt8 = 0

    private struct WeakProbe {
        weak var value: NativeHeaderProbe?
    }

    @MainActor
    private final class Flight {
        let from: UIViewController
        let to: UIViewController?
        let routeID: UUID?
        let handoff: HeaderHandoff
        let host: UIHostingController<Overlay>
        var completed = false
        weak var coordinator: AnyObject?
        var hiddenProbes: [WeakProbe] = []

        func matches(from source: UIViewController?, to destination: UIViewController?) -> Bool {
            from === source && (to == nil || to === destination)
        }

        func hide(_ probe: NativeHeaderProbe) {
            guard !hiddenProbes.contains(where: { $0.value === probe }) else { return }
            hiddenProbes.append(WeakProbe(value: probe))
            probe.setHandoff(handoff)
        }

        init(from: UIViewController, to: UIViewController?, routeID: UUID?, source: HeaderContent) {
            self.from = from
            self.to = to
            self.routeID = routeID
            let handoff = HeaderHandoff(source: source)
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
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private init(window: UIWindow) { self.window = window }

    static func forWindow(_ window: UIWindow) -> NativeHeaderMotion {
        if let existing = objc_getAssociatedObject(window, &windowKey) as? NativeHeaderMotion { return existing }
        let motion = NativeHeaderMotion(window: window)
        objc_setAssociatedObject(window, &windowKey, motion, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return motion
    }

    func register(_ probe: NativeHeaderProbe) {
        probes.removeAll { $0.value == nil }
        if !probes.contains(where: { $0.value === probe }) { probes.append(WeakProbe(value: probe)) }
        guard let flight else { return }
        let isDestination = flight.to.map { probe.belongs(to: $0) } ?? (probe.routeID == flight.routeID)
        if probe.belongs(to: flight.from) || isDestination {
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
                return
            }
            guard flight.completed, flight.routeID != nil || flight.from !== from || flight.to !== to else { return }
            remove(flight)
        }
        guard let flight = pin(from: from, to: to, routeID: nil) else { return }
        flight.coordinator = coordinator

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

    func beginRoute(from: UIViewController, to: UIViewController?, id: UUID) -> Bool {
        if let flight {
            guard flight.completed else { return false }
            remove(flight)
        }
        guard let flight = pin(from: from, to: to, routeID: id) else { return false }
        Task { [weak self, weak flight] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, let flight, self.flight === flight, !flight.completed else { return }
            self.completeRoute(id, animate: true)
        }
        return true
    }

    func completeRoute(_ id: UUID, animate: Bool) {
        guard let flight, flight.routeID == id, !flight.completed else { return }
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

    func releaseCompleted(routeID: UUID? = nil) {
        guard let flight, flight.completed, routeID == nil || flight.routeID == routeID else { return }
        remove(flight)
    }

    private func pin(from: UIViewController, to: UIViewController?, routeID: UUID?) -> Flight? {
        guard let window, let source = matching(from).compactMap(\.settledHeader).first else { return nil }
        let flight = Flight(from: from, to: to, routeID: routeID, source: source)
        self.flight = flight
        let overlay = flight.host.view!
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        overlay.layoutIfNeeded()
        matching(from).forEach { flight.hide($0) }
        if let to { matching(to).forEach { flight.hide($0) } }
        return flight
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
        await flight.handoff.replace(with: destination) { self.flight === flight }
        remove(flight)
    }

    private func remove(_ flight: Flight) {
        guard self.flight === flight else { return }
        self.flight = nil
        flight.hiddenProbes.forEach { $0.value?.setHandoff(nil) }
        // Let SwiftUI reveal the actual controls in the same display update.
        DispatchQueue.main.async { flight.host.view.removeFromSuperview() }
    }
}

@MainActor
final class NativeHeaderProbe: UIViewController {
    private var settledFrame: CGRect?
    private var settledCanGoBack = false
    private var handoff: HeaderHandoff?
    var onHandoffChange: ((HeaderHandoff?) -> Void)?
    var nativeMotionEnabled = true
    var showsChrome = true
    var routeID: UUID?
    var anchor: HeaderAnchor { view as! HeaderAnchor }

    override func loadView() {
        view = HeaderAnchor()
        view.isUserInteractionEnabled = false
    }

    var settledHeader: HeaderContent? {
        guard let frame = settledFrame ?? anchor.visibleFrame else { return nil }
        return header(frame: frame, canGoBack: settledCanGoBack)
    }

    var currentHeader: HeaderContent? {
        guard let frame = anchor.visibleFrame else { return nil }
        return header(frame: frame, canGoBack: navigationBackAvailable)
    }

    private var navigationBackAvailable: Bool {
        guard let nav = navigationController,
              let owner = nav.viewControllers.first(where: { belongs(to: $0) }) else { return false }
        return owner !== nav.viewControllers.first
    }

    private func header(frame: CGRect, canGoBack: Bool) -> HeaderContent? {
        guard let appearance = anchor.appearance else { return nil }
        return .init(frame: frame, appearance: .init(
            controls: showsChrome ? AnyView(appearance.controls.environment(\.headerPreviewCanGoBack, canGoBack)) : AnyView(EmptyView()),
            firstRowHeight: appearance.firstRowHeight,
            colorScheme: appearance.colorScheme,
            surfaceColor: showsChrome ? appearance.surfaceColor : .clear,
            borderColor: showsChrome ? appearance.borderColor : .clear
        ))
    }

    private func rememberFrame() {
        guard let frame = anchor.visibleFrame else { return }
        settledFrame = frame
        settledCanGoBack = navigationBackAvailable
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
    @Entry var headerPreviewCanGoBack: Bool? = nil
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

    private enum Phase { case entering, leaving }

    func preparePresentation() {
        guard let presenter, let from = owner(of: presenter), let window = presenter.viewIfLoaded?.window else { return }
        let motion = NativeHeaderMotion.forWindow(window)
        guard motion.beginRoute(from: from, to: nil, id: id) else { return }
        self.motion = motion
        phase = .entering
    }

    func prepareDismissal() {
        guard let presented, let presenter,
              let from = owner(of: presented), let to = owner(of: presenter),
              let window = presented.viewIfLoaded?.window else { return }
        let motion = NativeHeaderMotion.forWindow(window)
        motion.releaseCompleted()
        guard motion.beginRoute(from: from, to: to, id: id) else { return }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIViewController(context: Context) -> Boundary { Boundary() }

    func updateUIViewController(_ controller: Boundary, context: Context) {
        if isPresented {
            cover.presented = reduceMotion ? nil : controller
            controller.onAppear = { [weak cover] in cover?.appeared() }
        } else {
            cover.presenter = reduceMotion ? nil : controller
        }
    }

    final class Boundary: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }
}

extension View {
    func nativeHeaderRouteBoundary(_ cover: NativeHeaderRoute, isPresented: Bool) -> some View {
        background {
            NativeHeaderRouteBoundary(cover: cover, isPresented: isPresented)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .environment(\.nativeHeaderRouteID, isPresented ? cover.id : nil)
    }
}
