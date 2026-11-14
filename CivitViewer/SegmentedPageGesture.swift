import SwiftUI
import UIKit

@MainActor
@Observable
final class SegmentedPageMotion {
    enum Phase { case idle, dragging, settling }
    var identifier: String
    private(set) var phase: Phase = .idle
    private(set) var position: Double?
    private(set) var sourceIndex: Int?
    private(set) var targetIndex: Int?
    private(set) var contentSign = 1
    private(set) var viewportSize: CGSize = .zero
    var viewportWidth: CGFloat { viewportSize.width }
    var isInteracting: Bool { phase != .idle }

    #if DEBUG && targetEnvironment(simulator)
    var decision = "initial"
    @ObservationIgnored private(set) var lifecycle = "initial"
    private(set) var samples = 0
    private(set) var peakProgress = 0.0
    @ObservationIgnored private var startPosition = 0.0
    @ObservationIgnored private var paneFrames: [Int: CGRect] = [:]
    @ObservationIgnored private var canvasFrame: CGRect = .zero
    @ObservationIgnored private var startingFrame: CGRect = .zero
    @ObservationIgnored private(set) var renderedPeak: CGFloat = 0
    @ObservationIgnored private(set) var sawBothPanes = false
    @ObservationIgnored private(set) var intermediateSamples = 0
    @ObservationIgnored private(set) var blockedIntermediateSamples = 0
    @ObservationIgnored private var releaseX: CGFloat = 0
    @ObservationIgnored private var destinationX: CGFloat = 0
    @ObservationIgnored private var lastSettleX: CGFloat = 0
    @ObservationIgnored private(set) var settlingSamples = 0
    @ObservationIgnored private(set) var settlingTravel: CGFloat = 0
    @ObservationIgnored private(set) var settlingBlockedSamples = 0
    @ObservationIgnored private let profileEnabled = ProcessInfo.processInfo.arguments.contains("--qa-drag-performance167")
    @ObservationIgnored private var profileStarted = false
    @ObservationIgnored private(set) var moves = 0
    @ObservationIgnored private(set) var nativeHostSubmissions = 0
    @ObservationIgnored private(set) var leaderboardBodyEvaluations = 0
    #endif
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var committedIndex: Int?
    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private var interaction: PageInteractionShield.Lease?
    @ObservationIgnored private var pendingFrame: RenderFrameBoundary?
    func bind(to window: UIWindow?) { self.window = window }
    @ObservationIgnored var onInteractionBegan: (() -> Void)?

    init(identifier: String) { self.identifier = identifier }

    @discardableResult
    func begin(at index: Int, target: Int, direction: Int, contentSign: Int? = nil) -> Int {
        #if DEBUG && targetEnvironment(simulator)
        lifecycle = "begin-\(index)-\(target)"
        profileStarted = profileEnabled
        moves = 0; nativeHostSubmissions = 0; leaderboardBodyEvaluations = 0
        #endif
        onInteractionBegan?()
        pendingFrame?.cancel(); pendingFrame = nil
        interaction?.release()
        interaction = window.map(PageInteractionShield.acquire)
        revision += 1
        committedIndex = nil
        sourceIndex = index
        targetIndex = target
        self.contentSign = contentSign ?? direction
        phase = .dragging
        position = Double(index)
        #if DEBUG && targetEnvironment(simulator)
        samples = 0; peakProgress = 0; startPosition = Double(index)
        startingFrame = paneFrames[index] ?? .zero
        renderedPeak = 0; sawBothPanes = false
        intermediateSamples = 0; blockedIntermediateSamples = 0
        settlingSamples = 0; settlingTravel = 0; settlingBlockedSamples = 0
        #endif
        return revision
    }

    func isCurrent(_ revision: Int) -> Bool { self.revision == revision }

    func resize(to size: CGSize) {
        guard size.width > 0 else { return }
        if viewportWidth > 0, (abs(viewportSize.width - size.width) > 1 || abs(viewportSize.height - size.height) > 1) { cancel() }
        viewportSize = size
    }

    #if DEBUG && targetEnvironment(simulator)
    func recordCanvas(_ frame: CGRect) { canvasFrame = frame }
    func recordProfileHostSubmission() {
        guard profileEnabled, profileStarted, phase == .dragging || phase == .settling else { return }
        nativeHostSubmissions += 1
    }
    func recordProfileBodyEvaluation() {
        guard profileEnabled, profileStarted, phase == .dragging || phase == .settling else { return }
        leaderboardBodyEvaluations += 1
    }
    func recordPane(_ frame: CGRect, index: Int) {
        paneFrames[index] = frame
        guard isInteracting, let sourceIndex, let targetIndex else { return }
        if index == sourceIndex {
            let distance = abs(frame.minX - startingFrame.minX)
            renderedPeak = max(renderedPeak, distance)
            if phase == .settling {
                settlingTravel = max(settlingTravel, abs(frame.minX - releaseX))
                if abs(frame.minX - releaseX) > 1, abs(frame.minX - destinationX) > 1,
                   abs(frame.minX - lastSettleX) > 0.25 {
                    settlingSamples += 1
                    if let window, PageInteractionShield.blocksNewTouches(in: window) { settlingBlockedSamples += 1 }
                }
                lastSettleX = frame.minX
            }
            if distance > 1, distance < viewportWidth - 1 {
                intermediateSamples += 1
                if let window, PageInteractionShield.blocksNewTouches(in: window) { blockedIntermediateSamples += 1 }
            }
        }
        if let source = paneFrames[sourceIndex], let target = paneFrames[targetIndex],
           source.intersection(canvasFrame).width > 2, target.intersection(canvasFrame).width > 2 {
            sawBothPanes = true
        }
    }
    #endif

    func move(to position: Double, revision: Int) {
        guard isCurrent(revision) else { return }
        self.position = position
        #if DEBUG && targetEnvironment(simulator)
        samples += 1; peakProgress = max(peakProgress, abs(position - startPosition))
        if profileEnabled, profileStarted { moves += 1 }
        #endif
    }

    func settle(at position: Double?, revision: Int, reduceMotion: Bool, afterSelectionCommit: Bool = false) {
        guard isCurrent(revision) else { return }
        #if DEBUG && targetEnvironment(simulator)
        releaseX = sourceIndex.flatMap { paneFrames[$0]?.minX } ?? startingFrame.minX
        lastSettleX = releaseX
        destinationX = startingFrame.minX + CGFloat(contentSign) * CGFloat(abs((position ?? Double(sourceIndex ?? 0)) - Double(sourceIndex ?? 0))) * viewportWidth
        #endif
        phase = .settling
        if reduceMotion {
            self.position = position
            // End visual motion immediately, but keep this touch-end mutually
            // exclusive with SwiftUI actions until event dispatch has finished.
            DispatchQueue.main.async { [weak self] in self?.finish(revision: revision) }
            return
        }
        if afterSelectionCommit {
            // Render the committed selection with the release position intact.
            // Its nonanimated transaction must finish before the offset animates.
            pendingFrame?.cancel()
            pendingFrame = RenderFrameBoundary { [weak self] in
                guard let self, self.isCurrent(revision) else { return }
                self.pendingFrame = nil
                self.animateSettlement(to: position, revision: revision)
            }
        } else {
            animateSettlement(to: position, revision: revision)
        }
    }

    private func animateSettlement(to position: Double?, revision: Int) {
        guard isCurrent(revision) else { return }
        withAnimation(.timingCurve(0.22, 0.8, 0.32, 1, duration: 0.26), completionCriteria: .removed) {
            self.position = position
        } completion: { [weak self] in self?.finish(revision: revision) }
    }

    func prepareCommit(to index: Int, revision: Int) {
        guard isCurrent(revision) else { return }
        committedIndex = index
    }

    func select(from oldIndex: Int, to newIndex: Int, reduceMotion: Bool, commit: () -> Void) {
        guard oldIndex != newIndex, !isInteracting else { return }
        let direction = newIndex > oldIndex ? 1 : -1
        let revision = begin(at: oldIndex, target: newIndex, direction: direction, contentSign: -direction)
        committedIndex = newIndex
        withoutPageAnimation(commit)
        settle(at: Double(oldIndex + direction), revision: revision, reduceMotion: reduceMotion,
               afterSelectionCommit: true)
    }

    func selected(from oldIndex: Int, to newIndex: Int, reduceMotion: Bool) {
        guard oldIndex != newIndex else { return }
        if isInteracting {
            // Only the recognizer's own commit belongs to this flight. Search,
            // account or another programmatic selection replaces that intent.
            if committedIndex != newIndex { cancel() }
            return
        }
        select(from: oldIndex, to: newIndex, reduceMotion: reduceMotion, commit: {})
    }

    private func finish(revision: Int) {
        guard isCurrent(revision) else { return }
        #if DEBUG && targetEnvironment(simulator)
        lifecycle += ":finished"
        logProfile(outcome: "finished")
        #endif
        pendingFrame?.cancel(); pendingFrame = nil
        interaction?.release(); interaction = nil
        phase = .idle
        position = nil
        sourceIndex = nil
        targetIndex = nil
        committedIndex = nil
    }

    func cancel() {
        guard isInteracting else { return }
        #if DEBUG && targetEnvironment(simulator)
        lifecycle += ":cancelled"
        logProfile(outcome: "cancelled")
        #endif
        pendingFrame?.cancel(); pendingFrame = nil
        interaction?.release(); interaction = nil
        revision += 1
        phase = .idle
        position = nil
        sourceIndex = nil
        targetIndex = nil
        committedIndex = nil
    }

    #if DEBUG && targetEnvironment(simulator)
    private func logProfile(outcome: String) {
        guard profileEnabled, profileStarted else { return }
        profileStarted = false
        NSLog("DRAG167 counters identifier=%@ outcome=%@ moves=%d nativeHostSubmissions=%d leaderboardBodyEvaluations=%d",
              identifier, outcome, moves, nativeHostSubmissions, leaderboardBodyEvaluations)
    }
    #endif
}

/// Keeps real, independently identified panes mounted. Navigation chrome stays
/// outside this viewport; only its source and destination content move.
/// UIKit-backed List containers need an actual controller boundary: hiding an
/// outer SwiftUI group alone does not hide their native accessibility subtree.
private final class SegmentedNativePaneController: UIViewController {
    let host: UIHostingController<AnyView>

    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct SegmentedNativePane<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let participating: Bool
    let exposed: Bool
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> SegmentedNativePaneController {
        let controller = SegmentedNativePaneController(content: AnyView(content.disabled(!exposed)
            .environment(\.segmentedContentTransitionLocked, !exposed).environment(\.self, environment)))
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: SegmentedNativePaneController, context: Context) {
        #if DEBUG && targetEnvironment(simulator)
        environment.segmentedPageMotion?.recordProfileHostSubmission()
        #endif
        controller.host.rootView = AnyView(content.disabled(!exposed)
            .environment(\.segmentedContentTransitionLocked, !exposed).environment(\.self, environment))
        configure(controller)
    }

    private func configure(_ controller: SegmentedNativePaneController) {
        let style: UIUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
        controller.overrideUserInterfaceStyle = style
        controller.host.overrideUserInterfaceStyle = style
        controller.view.accessibilityElementsHidden = !exposed
        controller.view.accessibilityElements = exposed ? nil : []
        controller.view.isUserInteractionEnabled = exposed
        controller.host.view.accessibilityElementsHidden = !exposed
        // Hiding an idle offscreen native view preserves its controller/scroll
        // state, while preventing UIKit List's independent AX roots escaping.
        controller.host.view.isHidden = !participating
    }
}

struct SegmentedContentPager<Value: Hashable, Content: View>: View {
    let selection: Value
    let options: [Value]
    let identifier: String
    var isolatesNativeLists = false
    var onInteractionBegan: () -> Void = {}
    @ViewBuilder let content: (Value, Bool) -> Content
    @Environment(\.segmentedPageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pageMotion: SegmentedPageMotion? { motion?.identifier == identifier ? motion : nil }

    var body: some View {
        GeometryReader { geometry in
            let selected = options.firstIndex(of: selection) ?? 0
            let source = pageMotion?.sourceIndex
            let target = pageMotion?.targetIndex
            let sign = CGFloat(pageMotion?.contentSign ?? 1)
            ZStack(alignment: .topLeading) {
                ForEach(Array(options.enumerated()), id: \.element) { index, value in
                    let participating = index == selected || index == source || index == target
                    pane(value, active: participating, exposed: index == selected && pageMotion?.isInteracting != true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        #if DEBUG && targetEnvironment(simulator)
                        .background {
                            if ProcessInfo.processInfo.arguments.contains("--qa-segment-edge"), let pageMotion {
                                SegmentPaneGeometrySampler(motion: pageMotion, index: index)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        #endif
                        .modifier(SegmentedPageOffset(motion: pageMotion, index: index, selected: selected,
                                                      source: source, target: target, sign: sign,
                                                      width: geometry.size.width))
                        .allowsHitTesting(index == selected && pageMotion?.isInteracting != true)
                        .accessibilityHidden(index != selected || pageMotion?.isInteracting == true)
                }
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in pageMotion?.resize(to: size) }
            #if DEBUG && targetEnvironment(simulator)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in pageMotion?.recordCanvas(frame) }
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--qa-segment-edge") {
                    SegmentedPageQAReadback(identifier: identifier, motion: pageMotion, width: geometry.size.width,
                                            source: source, target: target)
                }
            }
            #endif
        }
        .onAppear { pageMotion?.onInteractionBegan = onInteractionBegan }
        .onDisappear { pageMotion?.onInteractionBegan = nil }
        .onChange(of: selection) { old, new in
            guard let from = options.firstIndex(of: old), let to = options.firstIndex(of: new) else { pageMotion?.cancel(); return }
            pageMotion?.selected(from: from, to: to, reduceMotion: reduceMotion)
        }
        .onChange(of: options) { _, _ in pageMotion?.cancel() }
    }

    @ViewBuilder private func pane(_ value: Value, active: Bool, exposed: Bool) -> some View {
        if isolatesNativeLists {
            SegmentedNativePane(content: content(value, active), participating: active, exposed: exposed)
        } else {
            content(value, active)
                .disabled(!exposed)
                .environment(\.segmentedContentTransitionLocked, !exposed)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(!exposed)
        }
    }

}

private struct SegmentedPageOffset: ViewModifier {
    let motion: SegmentedPageMotion?
    let index: Int
    let selected: Int
    let source: Int?
    let target: Int?
    let sign: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        let progress = abs((motion?.position ?? Double(selected)) - Double(source ?? selected))
        let translation = sign * CGFloat(progress) * width
        let x: CGFloat
        if index == source { x = translation }
        else if index == target { x = translation - sign * width }
        else { x = index == selected ? 0 : width }
        return content.offset(x: x)
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct SegmentedPageQAReadback: View {
    let identifier: String
    let motion: SegmentedPageMotion?
    let width: CGFloat
    let source: Int?
    let target: Int?

    var body: some View {
        let selected = source ?? 0
        let progress = abs((motion?.position ?? Double(selected)) - Double(selected))
        let translation = CGFloat(motion?.contentSign ?? 1) * CGFloat(progress) * width
        Text("content pager").font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityIdentifier("segment.content." + identifier)
            .accessibilityValue("width=\(width);offset=\(translation);renderedPeak=\(motion?.renderedPeak ?? 0);both=\(motion?.sawBothPanes == true ? 1 : 0);intermediate=\(motion?.intermediateSamples ?? 0);blockedMid=\(motion?.blockedIntermediateSamples ?? 0);settleFrames=\(motion?.settlingSamples ?? 0);settleTravel=\(motion?.settlingTravel ?? 0);settleBlocked=\(motion?.settlingBlockedSamples ?? 0);lifecycle=\(motion?.lifecycle ?? "missing");phase=\(String(describing: motion?.phase ?? .idle));source=\(source ?? -1);target=\(target ?? -1)")
    }
}

private struct SegmentedGestureQAReadback: View {
    let identifier: String
    let enabled: Bool
    let motion: SegmentedPageMotion

    var body: some View {
        Text("edge samples")
            .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityIdentifier("segment.trace." + identifier)
            .accessibilityValue("enabled=\(enabled);samples=\(motion.samples);peak=\(motion.peakProgress);decision=\(motion.decision)")
    }
}
#endif

extension EnvironmentValues {
    @Entry var segmentedPageMotion: SegmentedPageMotion? = nil
    @Entry var segmentedContentTransitionLocked = false
}

extension View {
    func edgeSwitchingSegments<Value: Hashable>(
        selection: Binding<Value>,
        options: [Value],
        identifier: String,
        enabled: Bool = true,
        reservesPageEdges: Bool = true,
        leftEdge: Bool = true,
        rightEdge: Bool = true,
        centerSwipe: Bool = false
    ) -> some View {
        modifier(SegmentedPageGestureModifier(selection: selection, options: options, identifier: identifier,
                                              enabled: enabled, reservesPageEdges: reservesPageEdges,
                                              leftEdge: leftEdge, rightEdge: rightEdge, centerSwipe: centerSwipe))
    }
}

private struct SegmentedPageGestureModifier<Value: Hashable>: ViewModifier {
    @Binding var selection: Value
    let options: [Value]
    let identifier: String
    let enabled: Bool
    let reservesPageEdges: Bool
    let leftEdge: Bool
    let rightEdge: Bool
    let centerSwipe: Bool
    @State private var motion: SegmentedPageMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mediaTabs) private var mediaTabs
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: SiteSession

    init(selection: Binding<Value>, options: [Value], identifier: String, enabled: Bool,
         reservesPageEdges: Bool = true,
         leftEdge: Bool, rightEdge: Bool, centerSwipe: Bool) {
        self._selection = selection
        self.options = options
        self.identifier = identifier
        self.enabled = enabled
        self.reservesPageEdges = reservesPageEdges
        self.leftEdge = leftEdge
        self.rightEdge = rightEdge
        self.centerSwipe = centerSwipe
        self._motion = State(initialValue: SegmentedPageMotion(identifier: identifier))
    }

    private var reducesGestureMotion: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-reduce-motion") { return true }
        #endif
        return reduceMotion
    }

    func body(content: Content) -> some View {
        content
            .background {
                SegmentedPageGestureLayer(selection: $selection, options: options, identifier: identifier,
                                          enabled: enabled, reservesPageEdges: reservesPageEdges,
                                          leftEdge: leftEdge, rightEdge: rightEdge, centerSwipe: centerSwipe,
                                          topExclusion: PageHeaderLayout.singleRow.reservedHeight,
                                          bottomExclusion: mediaTabs?.height ?? 0,
                                          reduceMotion: reducesGestureMotion, motion: motion)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .environment(\.segmentedPageMotion, motion)
            #if DEBUG && targetEnvironment(simulator)
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--qa-segment-edge") {
                    SegmentedGestureQAReadback(identifier: identifier, enabled: enabled, motion: motion)
                }
            }
            #endif
            // Page eligibility comes from the owning controller at touch time.
            // Reappearance during interactive back must not mutate the source
            // navigation parent's state and reassert its still-bound route.
            .onDisappear { motion.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { motion.cancel() }
            }
            .onChange(of: identifier) { _, value in
                motion.identifier = value
                motion.cancel()
            }
            .onChange(of: session.feedIdentity) { _, _ in motion.cancel() }
            .onChange(of: enabled) { _, value in
                if !value { motion.cancel() }
            }
    }
}

private struct SegmentedPageGestureLayer<Value: Hashable>: UIViewRepresentable {
    let selection: Binding<Value>
    let options: [Value]
    let identifier: String
    let enabled: Bool
    let reservesPageEdges: Bool
    let leftEdge: Bool
    let rightEdge: Bool
    let centerSwipe: Bool
    let topExclusion: CGFloat
    let bottomExclusion: CGFloat
    let reduceMotion: Bool
    let motion: SegmentedPageMotion

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        context.coordinator.probe = probe
        probe.onWindowChange = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.attach()
    }

    static func dismantleUIView(_ probe: Probe, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Probe: UIView {
        var onWindowChange: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?()
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: SegmentedPageGestureLayer<Value>
        weak var probe: Probe?
        private weak var host: UIView?
        private weak var owner: UIViewController?
        private let browsingPolicyToken = UUID()
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        private var touchOrigin: CGPoint?
        private var sourceIndex: Int?
        private var sourceSelection: Value?
        private var sourceOptions: [Value]?
        private var direction = 0
        private var dragSign = 1
        private var dragRevision: Int?

        init(_ configuration: SegmentedPageGestureLayer<Value>) {
            self.configuration = configuration
            super.init()
        }

        deinit {
            MainActor.assumeIsolated {
                if let owner {
                    PageEdgeReturnPolicy.setSegmentedBrowsing(owner: owner, token: browsingPolicyToken, active: false)
                }
                host?.removeGestureRecognizer(pan)
                configuration.motion.cancel()
            }
        }

        func attach() {
            guard let probe, probe.window != nil,
                  let page = owningPage(from: probe), let pageView = page.viewIfLoaded else {
                detach()
                return
            }
            if host !== pageView || owner !== page {
                detach()
                host = pageView
                owner = page
                pan.delegate = self
                pan.maximumNumberOfTouches = 1
                pan.cancelsTouchesInView = true
                pan.delaysTouchesBegan = false
                pan.delaysTouchesEnded = false
                pageView.addGestureRecognizer(pan)
            }
            if sourceIndex != nil {
                let selectionChanged = sourceSelection.map { configuration.selection.wrappedValue != $0 } ?? false
                if selectionChanged || sourceOptions != configuration.options { cancelDrag() }
            }
            configuration.motion.bind(to: pageView.window)
            PageEdgeReturnPolicy.setSegmentedBrowsing(owner: page, token: browsingPolicyToken,
                                                      active: configuration.reservesPageEdges)
            pan.isEnabled = configuration.enabled
            if !pan.isEnabled, sourceIndex != nil { cancelDrag() }
        }

        private var isVisiblePage: Bool {
            guard let host, let owner, let window = host.window,
                  owner.isViewLoaded, owner.viewIfLoaded?.window === window,
                  owner.presentedViewController == nil else { return false }
            var controller: UIViewController? = owner
            while let current = controller {
                if current.presentedViewController != nil { return false }
                controller = current.parent
            }
            var view: UIView? = host
            while let current = view {
                if current.isHidden || current.alpha < 0.01 { return false }
                view = current.superview
            }
            if let navigation = owner.navigationController {
                return navigation.topViewController === owner && navigation.transitionCoordinator == nil
                    && navigation.presentedViewController == nil
            }
            return true
        }

        private func owningPage(from view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    guard let pageView = controller.viewIfLoaded, view.isDescendant(of: pageView) else { return nil }
                    if let navigation = controller.navigationController,
                       let page = navigation.viewControllers.first(where: { candidate in
                           candidate.viewIfLoaded.map { view.isDescendant(of: $0) } ?? false
                       }) { return page }
                    return controller
                }
                responder = current.next
            }
            return nil
        }

        func detach() {
            if let owner {
                PageEdgeReturnPolicy.setSegmentedBrowsing(owner: owner, token: browsingPolicyToken, active: false)
            }
            host?.removeGestureRecognizer(pan)
            host = nil
            owner = nil
            cancelDrag()
        }

        private func cancelDrag() {
            touchOrigin = nil
            sourceIndex = nil
            sourceSelection = nil
            sourceOptions = nil
            direction = 0
            dragRevision = nil
            configuration.motion.cancel()
        }

        private func valid(_ point: CGPoint) -> Bool {
            guard configuration.enabled, isVisiblePage, let host else { return false }
            return point.x >= 0 && point.x <= host.bounds.width
                && point.y >= host.safeAreaInsets.top + configuration.topExclusion
                && point.y < host.bounds.height - host.safeAreaInsets.bottom - configuration.bottomExclusion
        }

        private func edge(at point: CGPoint) -> Int? {
            guard let host else { return nil }
            if configuration.centerSwipe, point.x > ScreenEdgeGesture.width,
               point.x < host.bounds.width - ScreenEdgeGesture.width { return 0 }
            if configuration.leftEdge && ScreenEdgeGesture.contains(distance: point.x - host.bounds.minX) { return -1 }
            if configuration.rightEdge && ScreenEdgeGesture.contains(distance: host.bounds.maxX - point.x) { return 1 }
            return nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === pan { touchOrigin = nil }
            #if DEBUG && targetEnvironment(simulator)
            configuration.motion.decision = "receive-visible-\(isVisiblePage)-enabled-\(configuration.enabled)"
            #endif
            guard gestureRecognizer === pan, let host, isVisiblePage else { return false }
            var touchedView = touch.view
            while let candidate = touchedView {
                if candidate is UIControl || candidate is UITextInput {
                    #if DEBUG && targetEnvironment(simulator)
                    configuration.motion.decision = "control-" + String(describing: type(of: candidate))
                    #endif
                    return false
                }
                if candidate === host { break }
                touchedView = candidate.superview
            }
            let point = touch.location(in: host)
            #if DEBUG && targetEnvironment(simulator)
            configuration.motion.decision = "nav-\(owner?.navigationController.map { String(describing: ObjectIdentifier($0)) } ?? "nil")-depth-\(owner?.navigationController?.viewControllers.count ?? 0)-point-\(Int(point.x))-\(Int(point.y))-width-\(Int(host.bounds.width))-valid-\(valid(point))-edge-\(edge(at: point) ?? 0)"
            #endif
            guard valid(point), edge(at: point) != nil else { return false }
            touchOrigin = point
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // SwiftUI scroll/drag recognizers may recognize before UIKit asks
            // for failure precedence. Our inward-edge gate still owns commits.
            gestureRecognizer === pan
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            #if DEBUG && targetEnvironment(simulator)
            configuration.motion.decision = "begin-velocity-\(Int(pan.velocity(in: host).x))-\(Int(pan.velocity(in: host).y))"
            #endif
            guard gestureRecognizer === pan, isVisiblePage, !configuration.motion.isInteracting, let host,
                  let start = touchOrigin, valid(start), let edge = edge(at: start) else { return false }
            guard let pageDirection = inwardDirection(edge: edge, in: host),
                  let source = configuration.options.firstIndex(of: configuration.selection.wrappedValue) else { return false }
            let destination = wrapped(source + pageDirection)
            guard destination != source else { return false }
            sourceIndex = source
            sourceSelection = configuration.selection.wrappedValue
            sourceOptions = configuration.options
            direction = pageDirection
            dragSign = configuration.centerSwipe ? -pageDirection : pageDirection
            dragRevision = configuration.motion.begin(at: source, target: destination, direction: pageDirection, contentSign: dragSign)
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                              shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pan, isVisiblePage, let start = touchOrigin, valid(start),
                  let edge = edge(at: start), let host,
                  inwardDirection(edge: edge, in: host) != nil,
                  let source = configuration.options.firstIndex(of: configuration.selection.wrappedValue),
                  wrapped(source + (edge < 0 ? 1 : -1)) != source else { return false }
            if otherGestureRecognizer is UIPanGestureRecognizer { return true }
            guard configuration.leftEdge, edge == -1,
                  let navigation = owner?.navigationController else { return false }
            return otherGestureRecognizer === navigation.interactivePopGestureRecognizer
        }

        @objc private func panned() {
            guard let host, touchOrigin != nil else { return }
            let translation = pan.translation(in: host).x
            switch pan.state {
            case .began:
                updatePosition(translation)
            case .changed:
                updatePosition(translation)
            case .ended:
                finish(translation: translation, velocity: pan.velocity(in: host).x)
            case .cancelled, .failed:
                configuration.motion.settle(at: sourceIndex.map(Double.init), revision: dragRevision ?? -1,
                                             reduceMotion: configuration.reduceMotion)
                clearDragState()
            default:
                break
            }
        }

        private func inwardDirection(edge: Int, in host: UIView) -> Int? {
            let velocity = pan.velocity(in: host)
            guard abs(velocity.x) > abs(velocity.y) * 1.4 else { return nil }
            if configuration.centerSwipe { return velocity.x < 0 ? 1 : -1 }
            let inward = edge < 0 ? velocity.x > 0 : velocity.x < 0
            guard inward else { return nil }
            return edge < 0 ? 1 : -1
        }

        private func updatePosition(_ translation: CGFloat) {
            guard let sourceIndex, let revision = dragRevision else { return }
            let travel = Double(translation) * Double(dragSign)
            let width = configuration.motion.viewportWidth > 0 ? configuration.motion.viewportWidth : (host?.bounds.width ?? 1)
            let progress = min(max(travel / max(Double(width), 1), 0), 1)
            configuration.motion.move(to: Double(sourceIndex) + Double(direction) * progress, revision: revision)
        }

        private func finish(translation: CGFloat, velocity: CGFloat) {
            guard let sourceIndex, let sourceSelection, let revision = dragRevision,
                  configuration.motion.isCurrent(revision), isVisiblePage,
                  configuration.selection.wrappedValue == sourceSelection,
                  sourceOptions == configuration.options else {
                cancelDrag()
                return
            }
            let signedDistance = Double(translation) * Double(dragSign)
            let signedVelocity = Double(velocity) * Double(dragSign)
            let commits = signedDistance >= 45 || (signedVelocity >= 450 && signedDistance >= 12)
            // Keep the unwrapped visual endpoint separate from the cyclic
            // selection index. clearDragState resets the recognizer direction.
            let destinationPosition = sourceIndex + direction
            let destinationIndex = wrapped(destinationPosition)
            if commits, let destination = configuration.options[safe: destinationIndex] {
                configuration.motion.prepareCommit(to: destinationIndex, revision: revision)
                clearDragState()
                if configuration.selection.wrappedValue == sourceSelection {
                    withoutPageAnimation { configuration.selection.wrappedValue = destination }
                }
                configuration.motion.settle(at: Double(destinationPosition), revision: revision,
                                            reduceMotion: configuration.reduceMotion, afterSelectionCommit: true)
            } else {
                configuration.motion.settle(at: Double(sourceIndex), revision: revision,
                                            reduceMotion: configuration.reduceMotion)
                clearDragState()
            }
        }

        private func wrapped(_ index: Int) -> Int {
            let count = configuration.options.count
            guard count > 0 else { return 0 }
            return (index % count + count) % count
        }

        private func clearDragState() {
            touchOrigin = nil
            sourceIndex = nil
            sourceSelection = nil
            sourceOptions = nil
            direction = 0
            dragRevision = nil
        }
    }
}

/// Temporary paging locks cancel button touches without washing out content.
/// Real disabled states outside that transition retain their visual treatment.
/// Navigation rows require a tap, not a drag that happens to end inside the
/// same wide button. The page's existing lease also rejects an older touch
/// whose tap callback was already scheduled before the visual flight began.
struct SegmentedContentButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.segmentedContentTransitionLocked) private var transitionLocked
    @Environment(\.segmentedPageMotion) private var segmentMotion
    @Environment(\.tabPageMotion) private var pageMotion
    @Environment(\.motionTab) private var tab

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(transitionLocked ? 1 : (enabled ? 1 : 0.45))
            .contentShape(Rectangle())
            .onTapGesture { activate(configuration) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate(configuration) }
    }
    private func activate(_ configuration: Configuration) {
        guard enabled, !transitionLocked, segmentMotion?.isInteracting != true,
              pageMotion?.blocksContentActivation(tab: tab) != true else { return }
        configuration.trigger()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct SegmentPaneGeometrySampler: UIViewRepresentable {
    let motion: SegmentedPageMotion
    let index: Int
    func makeCoordinator() -> Coordinator { Coordinator(motion: motion, index: index) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        context.coordinator.view = view; context.coordinator.start()
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.stop() }
    @MainActor final class Coordinator: NSObject {
        let motion: SegmentedPageMotion
        let index: Int
        weak var view: UIView?
        private var link: CADisplayLink?
        init(motion: SegmentedPageMotion, index: Int) { self.motion = motion; self.index = index }
        func start() { let link = CADisplayLink(target: self, selector: #selector(sample)); link.add(to: .main, forMode: .common); self.link = link }
        @objc private func sample() {
            guard let view, let window = view.window, view.bounds.width > 0 else { return }
            let layer = view.layer.presentation() ?? view.layer
            motion.recordPane(layer.convert(layer.bounds, to: window.layer), index: index)
        }
        func stop() { link?.invalidate(); link = nil }
    }
}
#endif
