import SwiftUI
import UIKit

enum MediaPanPhase { case began, changed, ended, cancelled }

/// Observe only the owning page's touches without putting a hit-testing view
/// over SwiftUI buttons. Navigation may retain enabled pages behind another one.
/// Reject vertical pans before recognition so paging still owns them.
struct MediaGestureLayer: UIViewRepresentable {
    let active: Bool
    let isVideo: Bool
    var topExclusion: CGFloat = 110
    var bottomExclusion: CGFloat = 120
    var excludedFrames: [CGRect] = []
    var onKindSwipe: ((Int) -> Void)?
    var onKindDrag: ((Double, MediaPanPhase) -> Void)? = nil
    var onSeek: ((Double, MediaPanPhase) -> Void)? = nil
    var onRateHold: ((Bool) -> Void)? = nil
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var onChromeHold: (() -> Void)? = nil
    @Environment(\.viewingChromeToggle) private var inheritedChromeHold
    @Environment(\.viewingChromeBottomExclusion) private var inheritedBottomExclusion

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.isUserInteractionEnabled = false
        context.coordinator.probe = view
        context.coordinator.chromeAction = onChromeHold ?? inheritedChromeHold
        context.coordinator.bottomExclusionOverride = inheritedBottomExclusion
        view.onWindowChange = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.chromeAction = onChromeHold ?? inheritedChromeHold
        context.coordinator.bottomExclusionOverride = inheritedBottomExclusion
        context.coordinator.attach()
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }

    final class Probe: UIView {
        var onWindowChange: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onWindowChange?() }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: MediaGestureLayer
        var chromeAction: (() -> Void)?
        var bottomExclusionOverride: CGFloat?
        weak var probe: Probe?
        private weak var host: UIView?
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        private lazy var centerHold = UILongPressGestureRecognizer(target: self, action: #selector(centerHeld))
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        private var edgePan = false
        private var panTouchOrigin: CGPoint?
        private var holding = false
        init(_ configuration: MediaGestureLayer) { self.configuration = configuration; super.init() }
        func attach() {
            guard let view = probe, view.window != nil, let owner = owningPageView(from: view) else {
                detach(); return
            }
            if host === owner { updateEnabledState(); return }
            detach(); host = owner
            pan.delegate = self; pan.maximumNumberOfTouches = 1
            hold.delegate = self; hold.minimumPressDuration = 0.35; hold.allowableMovement = 12
            centerHold.delegate = self; centerHold.minimumPressDuration = 0.45; centerHold.allowableMovement = 8
            centerHold.cancelsTouchesInView = true
            tap.delegate = self; tap.cancelsTouchesInView = false
            doubleTap.delegate = self; doubleTap.numberOfTapsRequired = 2; doubleTap.cancelsTouchesInView = false
            tap.require(toFail: pan); tap.require(toFail: hold); tap.require(toFail: centerHold)
            doubleTap.require(toFail: pan); doubleTap.require(toFail: hold); doubleTap.require(toFail: centerHold); tap.require(toFail: doubleTap)
            owner.addGestureRecognizer(pan); owner.addGestureRecognizer(hold); owner.addGestureRecognizer(centerHold); owner.addGestureRecognizer(tap); owner.addGestureRecognizer(doubleTap)
            updateEnabledState()
        }
        private func owningPageView(from view: UIView) -> UIView? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    guard let owner = controller.viewIfLoaded, view.isDescendant(of: owner) else { return nil }
                    return owner
                }
                responder = current.next
            }
            return nil
        }
        private func updateEnabledState() {
            let recognizers: [UIGestureRecognizer] = [pan, hold, centerHold, tap, doubleTap]
            for recognizer in recognizers { recognizer.isEnabled = configuration.active }
            if !configuration.active { panTouchOrigin = nil }
        }
        func detach() {
            host?.removeGestureRecognizer(pan); host?.removeGestureRecognizer(hold); host?.removeGestureRecognizer(centerHold); host?.removeGestureRecognizer(tap); host?.removeGestureRecognizer(doubleTap); host = nil
            panTouchOrigin = nil
            if holding { holding = false; configuration.onRateHold?(false) }
        }
        private func valid(_ point: CGPoint) -> Bool {
            guard configuration.active, let view = probe else { return false }
            return point.x >= 0 && point.x <= view.bounds.width && point.y >= configuration.topExclusion && point.y < view.bounds.height - (bottomExclusionOverride ?? configuration.bottomExclusion) &&
                !configuration.excludedFrames.contains(where: { $0.contains(point) })
        }
        private func edge(_ point: CGPoint) -> Bool {
            guard let view = probe else { return false }
            return point.x < 30 || point.x > view.bounds.width - 30
        }
        private func center(_ point: CGPoint) -> Bool {
            guard let view = probe, !edge(point) else { return false }
            return point.x >= view.bounds.width * 0.2 && point.x <= view.bounds.width * 0.8 &&
                point.y >= view.bounds.height * 0.2 && point.y <= view.bounds.height * 0.8
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            #if DEBUG && targetEnvironment(simulator)
            traceGesture(recognizer, stage: "shouldBegin")
            #endif
            guard let view = probe else { return false }
            let point = recognizer.location(in: view)
            if recognizer === pan {
                let velocity = pan.velocity(in: view)
                guard abs(velocity.x) > abs(velocity.y) * 1.4 else { return false }
                // UIPan's initial movement can be absent from its translation.
                // Use the received touch origin instead of reconstructing it.
                guard let start = panTouchOrigin, valid(start) else { return false }
                edgePan = edge(start)
                return edgePan ? configuration.onKindSwipe != nil : configuration.isVideo
            }
            guard valid(point) else { return false }
            if recognizer === centerHold { return chromeAction != nil && center(point) }
            if recognizer === tap { return configuration.onTap != nil }
            if recognizer === doubleTap { return configuration.onDoubleTap != nil }
            return configuration.isVideo && edge(point)
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            #if DEBUG && targetEnvironment(simulator)
            traceGesture(recognizer, stage: "shouldReceive")
            #endif
            if recognizer === pan { panTouchOrigin = nil }
            guard let view = probe else { return false }
            var target = touch.view
            while let candidate = target {
                if candidate is UIControl { return false }
                target = candidate.superview
            }
            let point = touch.location(in: view)
            guard valid(point) else { return false }
            if recognizer === pan { panTouchOrigin = point }
            if recognizer === centerHold { return chromeAction != nil && center(point) }
            if recognizer === hold { return configuration.isVideo && edge(point) }
            return true
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The vertical ScrollView must not pre-empt a horizontal seek or edge swipe.
            // Our pan rejects vertical motion in shouldBegin before it can affect paging.
            recognizer === pan && other is UIPanGestureRecognizer
        }
        @objc private func tapped() {
            #if DEBUG && targetEnvironment(simulator)
            traceGesture(tap, stage: "action")
            #endif
            if tap.state == .ended { configuration.onTap?() }
        }
        @objc private func doubleTapped() {
            #if DEBUG && targetEnvironment(simulator)
            traceGesture(doubleTap, stage: "action")
            #endif
            if doubleTap.state == .ended { configuration.onDoubleTap?() }
        }
        @objc private func panned() {
            #if DEBUG && targetEnvironment(simulator)
            traceGesture(pan, stage: "action")
            #endif
            guard let view = probe else { return }
            let delta = Double(pan.translation(in: view).x)
            if edgePan {
                switch pan.state {
                case .began: configuration.onKindDrag?(delta, .began)
                case .changed: configuration.onKindDrag?(delta, .changed)
                case .ended: configuration.onKindDrag?(delta, .ended)
                case .cancelled, .failed: configuration.onKindDrag?(delta, .cancelled)
                default: break
                }
                if pan.state == .ended && abs(delta) >= 45 { configuration.onKindSwipe?(delta < 0 ? 1 : -1) }
                return
            }
            switch pan.state {
            case .began: configuration.onSeek?(delta, .began)
            case .changed: configuration.onSeek?(delta, .changed)
            case .ended: configuration.onSeek?(delta, .ended)
            case .cancelled, .failed: configuration.onSeek?(delta, .cancelled)
            default: break
            }
        }
        @objc private func centerHeld() {
            #if DEBUG && targetEnvironment(simulator)
            traceGesture(centerHold, stage: "action")
            #endif
            // Began fires once per stationary press. End/changed never toggles,
            // and no playback, rate, seek or paging callback is invoked here.
            if centerHold.state == .began { chromeAction?() }
        }
        @objc private func held() {
            #if DEBUG && targetEnvironment(simulator)
            traceGesture(hold, stage: "action")
            #endif
            if hold.state == .began { holding = true; configuration.onRateHold?(true) }
            else if hold.state == .ended || hold.state == .cancelled || hold.state == .failed {
                if holding { holding = false; configuration.onRateHold?(false) }
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        private func traceGesture(_ recognizer: UIGestureRecognizer, stage: String) {
            guard let trace = PagerGestureTraceQA.active else { return }
            let name = recognizer === pan ? "pan" : recognizer === tap ? "tap" : recognizer === doubleTap ? "doubleTap" : recognizer === hold ? "edgeHold" : "centerHold"
            var fields: [String: Any] = ["name": name, "state": recognizer.state.rawValue, "active": configuration.active]
            if let view = probe {
                let p = recognizer.location(in: view)
                fields["location"] = ["x": Double(p.x), "y": Double(p.y)]
            }
            if let pan = recognizer as? UIPanGestureRecognizer {
                let v = pan.velocity(in: probe)
                fields["velocity"] = ["x": Double(v.x), "y": Double(v.y)]
            }
            trace.record("window.\(stage)", fields, sampleKey: stage == "action" && recognizer.state == .changed ? "window.\(name).changed" : nil)
        }
        #endif
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Retain an enabled media page below another controller, as navigation can do
/// before its cached SwiftUI content receives a new visibility value.
@MainActor private final class MediaGestureScopeQAState: ObservableObject {
    @Published var covered = true
    @Published var switches = 0
}

struct MediaGestureScopeQAView: View {
    @StateObject private var state = MediaGestureScopeQAState()
    var body: some View { MediaGestureScopeQAContainer(state: state) }
}

private struct MediaGestureScopeQAContainer: UIViewControllerRepresentable {
    @ObservedObject var state: MediaGestureScopeQAState
    func makeUIViewController(context: Context) -> MediaGestureScopeQAController {
        MediaGestureScopeQAController(state: state)
    }
    func updateUIViewController(_ controller: MediaGestureScopeQAController, context: Context) {
        controller.cover.isHidden = !state.covered
    }
}

@MainActor private final class MediaGestureScopeQAController: UIViewController {
    let cover: UIView
    private let content: UIHostingController<AnyView>
    private let author: UIHostingController<AnyView>
    init(state: MediaGestureScopeQAState) {
        let mediaController = UIHostingController(rootView: AnyView(MediaGestureScopeQAPage(state: state, author: false)))
        let authorController = UIHostingController(rootView: AnyView(MediaGestureScopeQAPage(state: state, author: true)))
        content = mediaController; author = authorController; cover = authorController.view
        super.init(nibName: nil, bundle: nil)
    }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [content, author] {
            addChild(child); view.addSubview(child.view); child.didMove(toParent: self)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.view.frame = view.bounds; author.view.frame = view.bounds
    }
}

private struct MediaGestureScopeQAPage: View {
    @ObservedObject var state: MediaGestureScopeQAState
    let author: Bool
    var body: some View {
        VStack(spacing: 20) {
            Text(author ? "作者页面" : "当前播放页").font(.title2)
            Text("backgroundSwitches=\(state.switches)")
                .accessibilityIdentifier(author ? "gesture68.cover.state" : "gesture68.page.state")
            if author { Button("返回播放页") { state.covered = false } }
            Spacer()
        }
        .padding(.top, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(author ? Color.blue.opacity(0.85) : Color.black).foregroundStyle(.white)
        .background {
            if !author {
                MediaGestureLayer(active: true, isVideo: false, onKindSwipe: { _ in state.switches += 1 })
            }
        }
    }
}
#endif
