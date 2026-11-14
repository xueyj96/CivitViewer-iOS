import SwiftUI
import UIKit

/// The timeline has two independent axes, chosen once at touch-down.
enum TimelinePageTarget: Equatable {
    case source(Bool)
    case kind(MediaKind)
}

/// Owns only a short-lived body preview. Feed models and the single active
/// player remain with their existing owners; bars never enter this container.
@MainActor final class TimelinePageMotion {
    private struct Entry { weak var probe: UIViewController?; weak var model: TimelineModel? }
    private var entries: [Bool: Entry] = [:]
    private let sourcePreloader = MediaPreloader()
    private let kindPreloader = MediaPreloader()
    private weak var window: UIWindow?
    private var windowBounds = CGRect.zero
    private var safeArea = UIEdgeInsets.zero
    private struct WeakView { weak var value: UIView? }
    private struct Visual {
        let container: UIView
        let source: UIView
        let target: UIView
        let image: UIImageView
    }
    private var canvases: [Bool: WeakView] = [:]
    private var stages: [Bool: WeakView] = [:]
    private var visuals: [Visual] = []
    private var sourceCopy: UIView? {
        if committed, case .source = target, visuals.count > 1 { return visuals[1].source }
        return visuals.first?.source
    }
    private var container: UIView? { visuals.first?.container }
    private var previewTask: Task<Void, Never>?
    private var animator: UIViewPropertyAnimator?
    private var boundary: RenderFrameBoundary?
    private var interaction: PageInteractionShield.Lease?
    private var flightID: UUID?
    private var from: Bool?
    private var target: TimelinePageTarget?
    private var sign: CGFloat = 1
    private var width: CGFloat = 0
    private var committed = false
    private var settling = false
    #if DEBUG && targetEnvironment(simulator)
    private var qaSampler: RenderProgressAnimation?
    private var qaLabel: UILabel?
    private var qaPeak: CGFloat = 0
    private var qaRelease: CGFloat = 0
    private var qaTravel: CGFloat = 0
    private var qaLastX: CGFloat = 0
    private var qaSettleFrames = 0
    private var qaBlocked = 0
    private func sampleQA(phase: String? = nil) {
        guard let label = qaLabel else { return }
        let x = sourceCopy?.layer.presentation()?.affineTransform().tx ?? sourceCopy?.transform.tx ?? 0
        qaPeak = max(qaPeak, abs(x))
        if settling {
            qaTravel = max(qaTravel, abs(x - qaRelease))
            let endpoint = committed ? sign * width : 0
            if abs(x - qaRelease) > 1, abs(x - endpoint) > 1, abs(x - qaLastX) > 0.25 {
                qaSettleFrames += 1
                if let window, PageInteractionShield.blocksNewTouches(in: window) { qaBlocked += 1 }
            }
        }
        qaLastX = x
        label.accessibilityValue = "phase=\(phase ?? (settling ? "settling" : "dragging"));peak=\(qaPeak);settleFrames=\(qaSettleFrames);settleTravel=\(qaTravel);blocked=\(qaBlocked);x=\(x);width=\(width);top=\(container?.frame.minY ?? 0);canvasTop=\(container.map { $0.convert($0.bounds, to: window).minY } ?? -1);canvasBottom=\(container.map { $0.convert($0.bounds, to: window).maxY } ?? -1);stages=\(visuals.count);windowHosted=\(container?.superview === window)"
    }
    private func startQA(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-pager-touch-trace") else { return }
        qaPeak = 0; qaRelease = 0; qaTravel = 0; qaLastX = 0; qaSettleFrames = 0; qaBlocked = 0
        let label = qaLabel ?? UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        label.text = "timeline body motion"; label.alpha = 0.01; label.isAccessibilityElement = true
        label.accessibilityIdentifier = "timeline.page-motion.qa"
        label.isUserInteractionEnabled = false
        if label.superview !== window { window.addSubview(label) }
        qaLabel = label
        qaSampler = RenderProgressAnimation(duration: 30, update: { [weak self] _ in self?.sampleQA() }, completion: {})
    }
    #endif
    var isInteracting: Bool { flightID != nil }

    func register(_ probe: UIViewController, model: TimelineModel, followed: Bool) {
        entries[followed] = Entry(probe: probe, model: model)
    }

    func registerCanvas(_ view: UIView, followed: Bool) { canvases[followed] = WeakView(value: view) }
    func registerStage(_ view: UIView, followed: Bool) { stages[followed] = WeakView(value: view) }

    /// Return only the registered media canvas for this exact timeline owner.
    /// Root-tab transitions may snapshot a narrow band from it without starting
    /// this motion's own gesture, animation, or interaction lease.
    func rootTabCanvas(followed: Bool, owner: UIViewController) -> UIView? {
        guard let entry = entries[followed], let probe = entry.probe,
              PageViewportGeometry.owner(of: probe) === owner,
              let ownerView = owner.viewIfLoaded, let window = ownerView.window,
              let canvas = canvases[followed]?.value, canvas.window === window,
              canvas.isDescendant(of: ownerView), window.windowScene?.activationState == .foregroundActive else { return nil }
        return canvas
    }

    func prepareNeighbors(from followed: Bool, session: SiteSession, blockedTags: Set<String>) async {
        guard let model = entries[followed]?.model else { return }
        let identity = session.feedIdentity, filter = model.filter
        async let kind: Void = model.warm(session: session, blockedTags: blockedTags, otherKind: true)
        async let source: Void? = entries[!followed]?.model?.warm(session: session, blockedTags: blockedTags, otherKind: false)
        _ = await (kind, source)
        guard !Task.isCancelled, identity == session.feedIdentity, model.filter == filter else { return }
        let defaults = UserDefaults.standard
        let wifi = defaults.object(forKey: "wifiVideoPrefetch") as? Bool ?? true
        let concurrency = defaults.object(forKey: MediaPrefetchConcurrency.defaultsKey) as? Int ?? MediaPrefetchConcurrency.defaultValue
        kindPreloader.update(model.previewItem(otherKind: true, identity: identity).map { [$0] } ?? [],
                             after: -1, count: 3, context: identity + ":timeline-kind:\(followed):\(filter.effectiveKind.rawValue)",
                             wifiOnly: wifi, concurrency: concurrency)
        sourcePreloader.update(entries[!followed]?.model?.previewItem(otherKind: false, identity: identity).map { [$0] } ?? [],
                               after: -1, count: 3, context: identity + ":timeline-source:\(followed)",
                               wifiOnly: wifi, concurrency: concurrency)
    }

    @discardableResult
    func begin(from followed: Bool, target: TimelinePageTarget, translation: Double,
               session: SiteSession) -> Bool {
        guard flightID == nil, let canvas = canvases[followed]?.value, let window = canvas.window,
              window.windowScene?.activationState == .foregroundActive,
              let sourceStage = stages[followed]?.value, sourceStage.window === window else { return false }
        if case .source(let next) = target {
            guard stages[next]?.value?.window === window else { return false }
        }
        let hosts = [followed, !followed].compactMap { stages[$0]?.value }.filter { $0.window === window }
        guard !hosts.isEmpty else { return false }
        let id = UUID()
        let crop = canvas.convert(window.bounds, from: window).intersection(canvas.bounds)
        guard crop.width > 1, crop.height > 1 else { return false }
        var prepared: [Visual] = []
        // Each mounted lane has a stage below its fixed chrome. Both stages
        // share the same image and transforms, so changing the visible lane
        // cannot detach a flight or expose a stationary strip behind the bar.
        for host in hosts {
            guard let copy = canvas.resizableSnapshotView(from: crop, afterScreenUpdates: false, withCapInsets: .zero) else { return false }
            let frame = host.convert(window.bounds, from: window)
            let pane = UIView(frame: frame)
            pane.backgroundColor = .black; pane.clipsToBounds = true
            pane.isUserInteractionEnabled = false; pane.accessibilityElementsHidden = true
            let targetPane = UIView(frame: pane.bounds)
            targetPane.clipsToBounds = true
            let image = UIImageView(frame: pane.bounds)
            image.contentMode = .scaleAspectFit; image.clipsToBounds = true; image.backgroundColor = .black
            targetPane.addSubview(image)
            copy.frame = canvas.convert(crop, to: window).offsetBy(dx: -window.bounds.minX, dy: -window.bounds.minY)
            pane.addSubview(targetPane); pane.addSubview(copy)
            prepared.append(Visual(container: pane, source: copy, target: targetPane, image: image))
        }
        self.flightID = id; from = followed; self.target = target
        self.window = window; windowBounds = window.bounds; safeArea = window.safeAreaInsets
        sign = translation < 0 ? -1 : 1; width = window.bounds.width
        visuals = prepared
        committed = false; settling = false
        for (host, visual) in zip(hosts, prepared) { host.addSubview(visual.container) }
        interaction = PageInteractionShield.acquire(in: window)
        #if DEBUG && targetEnvironment(simulator)
        startQA(in: window)
        #endif
        let item: MediaItem?
        switch target {
        case .source(let other): item = entries[other]?.model?.previewItem(otherKind: false, identity: session.feedIdentity)
        case .kind: item = entries[followed]?.model?.previewItem(otherKind: true, identity: session.feedIdentity)
        }
        if let item {
            if (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0) {
                for visual in visuals {
                    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                    blur.frame = visual.image.bounds; blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    visual.image.addSubview(blur)
                }
            }
            previewTask = Task { [weak self] in
                let pixels: UIImage?
                if let poster = item.isVideo ? item.posterURL : item.mediaURL { pixels = await MediaCache.shared.image(poster) }
                else if let source = item.mediaURL { pixels = await MediaCache.shared.transitionFrame(for: source) }
                else { pixels = nil }
                guard !Task.isCancelled, self?.flightID == id else { return }
                self?.visuals.forEach { $0.image.image = pixels }
            }
        }
        move(0)
        return true
    }

    func validateGeometry() {
        guard flightID != nil else { return }
        guard let window, window.bounds == windowBounds, window.safeAreaInsets == safeArea,
              window.windowScene?.activationState == .foregroundActive else { cancel(); return }
    }
    func move(_ translation: Double) {
        validateGeometry()
        guard flightID != nil, !settling else { return }
        let travel = min(width, max(0, CGFloat(translation) * sign)) * sign
        for visual in visuals {
            visual.source.transform = CGAffineTransform(translationX: travel, y: 0)
            visual.target.transform = CGAffineTransform(translationX: travel - sign * width, y: 0)
        }
    }

    func end(_ translation: Double, preserveRelease: Bool = false, forceCommit: Bool = false, commit: () -> Void) {
        guard let id = flightID, !settling else { return }
        validateGeometry()
        if !preserveRelease { move(translation) }
        guard flightID == id else { return }
        let accepts = forceCommit || CGFloat(translation) * sign >= ScreenEdgeGesture.commitDistance
        #if DEBUG && targetEnvironment(simulator)
        qaRelease = sourceCopy?.layer.presentation()?.affineTransform().tx ?? sourceCopy?.transform.tx ?? 0
        qaLastX = qaRelease
        #endif
        committed = accepts; settling = true
        if accepts { withoutPageAnimation(commit) }
        // Commit selection without resetting the release position, then settle.
        boundary = RenderFrameBoundary { [weak self] in
            guard let self, self.flightID == id else { return }
            self.boundary = nil
            let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.26,
                controlPoint1: CGPoint(x: 0.22, y: 0.8), controlPoint2: CGPoint(x: 0.32, y: 1)) {
                    let end = accepts ? self.sign * self.width : 0
                    for visual in self.visuals {
                        visual.source.transform = CGAffineTransform(translationX: end, y: 0)
                        visual.target.transform = CGAffineTransform(translationX: end - self.sign * self.width, y: 0)
                    }
                }
            self.animator = animator
            animator.addCompletion { [weak self] _ in
                guard let self, self.flightID == id else { return }
                self.boundary = RenderFrameBoundary { [weak self] in
                    guard let self, self.flightID == id else { return }
                    self.boundary = nil
                    guard accepts, !UIAccessibility.isReduceMotionEnabled else {
                        self.cancel(phase: accepts ? "completed" : "cancelled"); return
                    }
                    // A poster is not a decoded video frame. Hand the body to
                    // the now-settled live deck with a short, fixed-position blend.
                    let reveal = UIViewPropertyAnimator(duration: 0.12, curve: .easeInOut) { self.visuals.forEach { $0.container.alpha = 0 } }
                    self.animator = reveal
                    reveal.addCompletion { [weak self] _ in
                        if self?.flightID == id { self?.cancel(phase: "completed") }
                    }
                    reveal.startAnimation()
                }
            }
            animator.startAnimation()
        }
    }

    func select(from followed: Bool, target: TimelinePageTarget, session: SiteSession, commit: () -> Void) {
        guard !isInteracting else { return }
        let direction: Double
        switch target {
        case .source(let following): direction = following ? 1 : -1
        case .kind(let kind): direction = kind == .video ? -1 : 1
        }
        guard begin(from: followed, target: target, translation: direction, session: session) else { commit(); return }
        end(0, forceCommit: true, commit: commit)
    }

    func sourceHidden(_ followed: Bool) { if from == followed && !committed { cancel() } }
    func cancel(phase: String = "cancelled") {
        #if DEBUG && targetEnvironment(simulator)
        sampleQA(phase: phase)
        qaSampler?.cancel(); qaSampler = nil
        #endif
        flightID = nil
        boundary?.cancel(); boundary = nil
        animator?.stopAnimation(true); animator = nil
        previewTask?.cancel(); previewTask = nil
        visuals.forEach { $0.container.removeFromSuperview() }; visuals.removeAll()
        from = nil; target = nil; window = nil
        interaction?.release(); interaction = nil
        settling = false; committed = false
    }
    func stop() {
        cancel(); sourcePreloader.stop(); kindPreloader.stop()
        #if DEBUG && targetEnvironment(simulator)
        qaLabel?.removeFromSuperview(); qaLabel = nil
        #endif
    }
}

private final class TimelineMotionProbe: UIViewController {
    weak var motion: TimelinePageMotion?
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); motion?.validateGeometry() }
}
private struct TimelinePageAnchor: UIViewControllerRepresentable {
    let motion: TimelinePageMotion
    let model: TimelineModel
    let followed: Bool
    func makeUIViewController(context: Context) -> TimelineMotionProbe {
        let controller = TimelineMotionProbe(); controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }
    func updateUIViewController(_ controller: TimelineMotionProbe, context: Context) {
        controller.motion = motion
        motion.register(controller, model: model, followed: followed)
    }
}
extension EnvironmentValues { @Entry var timelinePageMotion: TimelinePageMotion? = nil }
extension View {
    func timelinePageAnchor(_ motion: TimelinePageMotion?, model: TimelineModel, followed: Bool) -> some View {
        background { if let motion { TimelinePageAnchor(motion: motion, model: model, followed: followed).allowsHitTesting(false).accessibilityHidden(true) } }
    }
}


/// Lives inside the lane, above media and below header/feedback chrome.
struct TimelineMotionStage: UIViewRepresentable {
    let motion: TimelinePageMotion
    let followed: Bool
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        motion.registerStage(view, followed: followed)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { motion.registerStage(view, followed: followed) }
}
