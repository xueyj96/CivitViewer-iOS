import SwiftUI
import UIKit
import Observation

/// Mounting a preview is not a business activation. Each stack keeps one host
/// and identity; only the selected stack may interact or own active media.
struct RootPageParticipation: Equatable {
    enum Role { case active, prepared, inactive }
    let token: UUID?
    let role: Role
    static let standalone = Self(token: nil, role: .active)
    var isActive: Bool { role == .active }
    var canPrepare: Bool { role != .inactive }
}
extension EnvironmentValues {
    @Entry var rootPageParticipation = RootPageParticipation.standalone
}

/// The caller declares value-input changes; callbacks are forwarded through a
/// stable bridge and are deliberately not compared for equality.
fileprivate struct RootPageInputs: Equatable {
    let contentRevision: AnyHashable
    let role: RootPageParticipation.Role
    let scene: ScenePhase
    let scheme: ColorScheme
    let ordinaryScheme: ColorScheme
    let textSize: DynamicTypeSize
    let locale: Locale
    let direction: LayoutDirection
    let safeInsets: EdgeInsets
    let contentInsets: EdgeInsets
    let controlsInset: CGFloat
    let displayScale: CGFloat
    let horizontalSizeClass: UserInterfaceSizeClass?
    let verticalSizeClass: UserInterfaceSizeClass?
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let playbackCanvas: Bool
    let session: ObjectIdentifier
    let oauth: ObjectIdentifier
    let feedIdentity: String
    let selectionBar: ObjectIdentifier?
    let mediaTabsHeight: CGFloat?
    let activationPermit: ObjectIdentifier?

    @MainActor init(revision: AnyHashable, role: RootPageParticipation.Role,
         environment: EnvironmentValues, session: SiteSession) {
        contentRevision = revision; self.role = role
        scene = environment.scenePhase; scheme = environment.colorScheme
        ordinaryScheme = environment.ordinaryColorScheme; textSize = environment.dynamicTypeSize
        locale = environment.locale; direction = environment.layoutDirection
        safeInsets = environment.floatingPageSafeInsets; contentInsets = environment.floatingPageContentInsets
        controlsInset = environment.viewingControlsReferenceInset; displayScale = environment.displayScale
        horizontalSizeClass = environment.horizontalSizeClass; verticalSizeClass = environment.verticalSizeClass
        reduceMotion = environment.accessibilityReduceMotion; reduceTransparency = environment.accessibilityReduceTransparency
        if case .playback = environment.pageCanvasRole { playbackCanvas = true } else { playbackCanvas = false }
        self.session = ObjectIdentifier(session); oauth = ObjectIdentifier(session.oauth)
        feedIdentity = session.feedIdentity
        selectionBar = environment.favoriteSelectionBar.map(ObjectIdentifier.init)
        mediaTabsHeight = environment.mediaTabs?.height
        activationPermit = environment.pageVisualActivationPermit.map(ObjectIdentifier.init)
    }
}

@MainActor fileprivate final class RootPageCallbacks {
    var mediaTabs: MediaTabs?
    func bridgedTabs() -> MediaTabs? {
        guard let mediaTabs else { return nil }
        return MediaTabs(height: mediaTabs.height, render: { [weak self] media, identifier, selection, onSelect in
            self?.mediaTabs?.render(media, identifier, selection, onSelect) ?? AnyView(EmptyView())
        }, select: { [weak self] exit in self?.mediaTabs?.select(exit) })
    }
}

@MainActor @Observable fileprivate final class RootPageContent {
    var page: AnyView
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private var inputs: RootPageInputs

    init(page: AnyView, inputs: RootPageInputs) { self.page = page; self.inputs = inputs }

    @discardableResult
    func update(inputs: RootPageInputs, page: () -> AnyView) -> Bool {
        guard self.inputs != inputs else { return false }
        self.inputs = inputs
        self.page = page()
        revision &+= 1
        return true
    }
}

@MainActor fileprivate struct RootPageHostView: View {
    let content: RootPageContent
    var body: some View {
        content.page
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor private enum RootPageQARecorder {
    private struct Counts { var installs = 0; var updates = 0 }
    private static var counts: [Int: Counts] = [:]

    static func rootInstall(tab: Int, token: UUID, revision: Int) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") else { return }
        var count = counts[tab, default: Counts()]
        count.installs += 1
        counts[tab] = count
        NSLog("ROOT_PAGE_QA event=rootInstall tab=%d token=%@ revision=%d installCount=%d updateCount=%d",
              tab, token.uuidString, revision, count.installs, count.updates)
    }

    static func rootUpdate(tab: Int, token: UUID, revision: Int) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") else { return }
        var count = counts[tab, default: Counts()]
        count.updates += 1
        counts[tab] = count
        NSLog("ROOT_PAGE_QA event=rootUpdate tab=%d token=%@ revision=%d installCount=%d updateCount=%d",
              tab, token.uuidString, revision, count.installs, count.updates)
    }
}
#else
@MainActor private enum RootPageQARecorder {
    static func rootInstall(tab: Int, token: UUID, revision: Int) {}
    static func rootUpdate(tab: Int, token: UUID, revision: Int) {}
}
#endif

struct RootTabHost: UIViewControllerRepresentable {
    let selected: Int
    let prepared: Int?
    let pages: [Int: AnyView]
    let contentRevisions: [Int: AnyHashable]
    let motion: TabPageMotion
    let commit: (Int) -> Void
    @Environment(\.self) private var environment
    @EnvironmentObject private var session: SiteSession

    func makeUIViewController(context: Context) -> RootTabHostController { RootTabHostController() }
    func updateUIViewController(_ controller: RootTabHostController, context: Context) {
        controller.update(selected: selected, prepared: prepared, pages: pages, contentRevisions: contentRevisions,
                          environment: environment, session: session, motion: motion, commit: commit)
    }
    static func dismantleUIViewController(_ controller: RootTabHostController, coordinator: ()) {
        controller.detach()
    }
}

@MainActor final class RootTabHostController: UIViewController, UIGestureRecognizerDelegate {
    private struct Slot {
        let token: UUID
        let content: RootPageContent
        let callbacks: RootPageCallbacks
        let host: UIHostingController<RootPageHostView>
    }
    private struct VisualPairLease {
        let id: UUID
        let sourceTab: Int
        let destinationTab: Int
        let sourceToken: UUID
        let destinationToken: UUID
        let scopeIdentity: String
        let sourceOwner: ObjectIdentifier
        let destinationOwner: ObjectIdentifier
        let window: ObjectIdentifier
        let scene: ObjectIdentifier
        let sign: CGFloat
        let width: CGFloat
        let height: CGFloat
        let reduceMotion: Bool
        var progress: CGFloat
    }
    private var slots: [Int: Slot] = [:]
    private var visualPair: VisualPairLease?
    private(set) var selected = 0
    private(set) var feedIdentity: String?
    private var preparing = false
    private weak var motion: TabPageMotion?
    private var commit: (Int) -> Void = { _ in }
    private var origin: CGPoint?
    private var sign: CGFloat = 0
    private var rootDragID: UUID?
    private lazy var pan: PageMotionPanGestureRecognizer = {
        let recognizer = PageMotionPanGestureRecognizer(target: self, action: #selector(dragged))
        recognizer.onTouchSequenceFinished = { [weak self] in self?.reconcileRootDrag() }
        recognizer.onReset = { [weak self] in self?.rootPanDidReset() }
        return recognizer
    }()
    #if DEBUG && targetEnvironment(simulator)
    private var droppedRootPanTerminal = false
    private var suppressedRootPanReset: UUID?
    #endif
    private weak var keyboardWindow: UIWindow?
    private var keyboardVisible = false
    private var keyboardObservers: [NSObjectProtocol] = []
    /// Retain at most the existing four root slots. Idle mounting only builds
    /// adjacent ordinary hosts; it never selects a page or prepares its data.
    private struct IdleMountInputs {
        let source: Int
        let sourceToken: UUID
        let pages: [Int: AnyView]
        let revisions: [Int: AnyHashable]
        let environment: EnvironmentValues
        let session: SiteSession
        let identity: String
    }
    private var idleMountInputs: IdleMountInputs?
    private var idleMountGeneration = UUID()
    private var idleMountBoundary: RenderFrameBoundary?
    private var idleMountTimer: Timer?
    private var idleMountAttempts = 0
    #if DEBUG && targetEnvironment(simulator)
    private weak var idleMountSession178: SiteSession?
    private weak var idleMountReadback178: UILabel?
    private weak var rootMotionReadback181: UILabel?
    private var rootMotionFlight181: [String: String] = [:]
    private var rootMotionMoveSamples181 = 0
    private var rootMotionMaxSourceX181: CGFloat = 0
    private var rootMotionMaxTargetX181: CGFloat = 0
    private var rootMotionLastEndpoint181 = "none"
    private var rootMotionOutcome181 = "none"
    private final class RootMotionReadback181: UILabel {
        weak var host: RootTabHostController?
        override var accessibilityValue: String? {
            get { host?.rootMotionValue181 }
            set { }
        }
    }
    private var rootMotionValue181: String {
        let visible = slots.keys.sorted().filter { tab in
            guard let host = slots[tab]?.host, let hostedView = host.viewIfLoaded else { return false }
            return !hostedView.isHidden && hostedView.alpha > 0 && hostedView.superview === view
        }
        let tokens = slots.keys.sorted().compactMap { tab in slots[tab].map { "\(tab):\($0.token.uuidString)" } }.joined(separator: ",")
        guard !rootMotionFlight181.isEmpty else {
            return "pair=none;selected=\(selected);visibleSlots=\(visible.map(String.init).joined(separator: ","));slotCount=\(slots.count);tokens=\(tokens)"
        }
        let fields = rootMotionFlight181.keys.sorted().map { "\($0)=\(rootMotionFlight181[$0] ?? "")" }.joined(separator: ";")
        return "\(fields);moveSamples=\(rootMotionMoveSamples181);maxMoveSourceX=\(String(format: "%.2f", rootMotionMaxSourceX181));maxMoveTargetX=\(String(format: "%.2f", rootMotionMaxTargetX181));lastEndpoint=\(rootMotionLastEndpoint181);outcome=\(rootMotionOutcome181);selected=\(selected);visibleSlots=\(visible.map(String.init).joined(separator: ","));slotCount=\(slots.count);tokens=\(tokens)"
    }
    private func installRootMotionReadback181() {
        guard ProcessInfo.processInfo.arguments.contains("--qa-root-motion181"),
              let window = viewIfLoaded?.window, rootMotionReadback181 == nil else { return }
        let label = RootMotionReadback181(frame: CGRect(x: 1, y: window.bounds.height - 1, width: 1, height: 1))
        label.host = self; label.text = "root motion"; label.textColor = .clear
        label.font = .systemFont(ofSize: 1); label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true; label.accessibilityIdentifier = "root.motion181.qa"
        window.addSubview(label); rootMotionReadback181 = label
    }
    private func recordRootMotion181(_ pair: VisualPairLease, sourceView: UIView, targetView: UIView,
                                     outcome: String? = nil) {
        let sourceTransform = sourceView.transform, targetTransform = targetView.transform
        let progress = pair.progress
        if progress > 0 && progress < 1 && (abs(sourceTransform.tx) > 0.5 || abs(targetTransform.tx) > 0.5) {
            rootMotionMoveSamples181 += 1
            rootMotionMaxSourceX181 = max(rootMotionMaxSourceX181, abs(sourceTransform.tx))
            rootMotionMaxTargetX181 = max(rootMotionMaxTargetX181, abs(targetTransform.tx))
        }
        rootMotionFlight181 = [
            "pair": pair.id.uuidString,
            "source": String(pair.sourceTab), "destination": String(pair.destinationTab),
            "sourceToken": pair.sourceToken.uuidString, "destinationToken": pair.destinationToken.uuidString,
            "progress": String(format: "%.4f", progress),
            "sourceX": String(format: "%.2f", sourceTransform.tx),
            "targetX": String(format: "%.2f", targetTransform.tx),
            "sourceY": String(format: "%.2f", sourceTransform.ty),
            "targetY": String(format: "%.2f", targetTransform.ty),
            "sourceWidth": String(format: "%.2f", sourceView.bounds.width),
            "sourceHeight": String(format: "%.2f", sourceView.bounds.height),
            "targetWidth": String(format: "%.2f", targetView.bounds.width),
            "targetHeight": String(format: "%.2f", targetView.bounds.height),
            "sourceAlpha": String(format: "%.3f", sourceView.alpha),
            "targetAlpha": String(format: "%.3f", targetView.alpha),
            "sourceHidden": sourceView.isHidden ? "1" : "0",
            "targetHidden": targetView.isHidden ? "1" : "0"
        ]
        if let outcome { rootMotionOutcome181 = outcome }
    }
    private final class IdleMountReadback178: UILabel {
        weak var host: RootTabHostController?
        override var accessibilityValue: String? {
            get { host?.idleMountValue178 }
            set { }
        }
    }
    private var idleMountValue178: String {
        let keys = slots.keys.sorted()
        let hidden = keys.filter { slots[$0]?.host.viewIfLoaded?.isHidden == true }
        let interactive = keys.filter { slots[$0]?.host.viewIfLoaded?.isUserInteractionEnabled == true }
        return "selected=\(selected);slots=\(keys.map(String.init).joined(separator: ","));hidden=\(hidden.map(String.init).joined(separator: ","));interactive=\(interactive.map(String.init).joined(separator: ","));collectionsKnown=\(idleMountSession178?.collectionsKnown ?? false);folders=\(idleMountSession178?.collectionRefreshStarts178 ?? -1);pages=\(idleMountSession178?.collectionPageStarts178 ?? -1);attempts=\(idleMountAttempts);pending=\(idleMountInputs != nil)"
    }
    private func installIdleMountReadback178() {
        guard ProcessInfo.processInfo.arguments.contains("--qa-root-idle178"),
              let window = viewIfLoaded?.window, idleMountReadback178 == nil else { return }
        let label = IdleMountReadback178(frame: CGRect(x: 1, y: window.bounds.height - 1, width: 1, height: 1))
        label.host = self; label.text = "idle mount"; label.textColor = .clear
        label.font = .systemFont(ofSize: 1); label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true; label.accessibilityIdentifier = "root.idle178.qa"
        window.addSubview(label); idleMountReadback178 = label
    }
    #endif

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = false
        pan.delegate = self
        // Input ownership belongs to a successfully prepared flight. A failed
        // capture must leave child touches intact; successful flights install
        // the existing window input shield before handling any drag move.
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG && targetEnvironment(simulator)
        if let window = view.window { DragCadenceQA172.attach(to: window) }
        installIdleMountReadback178()
        installRootMotionReadback181()
        #endif
    }
    func update(selected: Int, prepared: Int?, pages: [Int: AnyView], contentRevisions: [Int: AnyHashable], environment: EnvironmentValues,
                session: SiteSession, motion: TabPageMotion, commit: @escaping (Int) -> Void) {
        cancelPrewarming()
        if selected != self.selected, let previous = slots[self.selected],
           let window = viewIfLoaded?.window, previous.host.viewIfLoaded?.window === window,
           let identity = feedIdentity, identity == session.feedIdentity {
            VideoPlaybackSessions.shared.pauseForRootDeparture(rootSlot: previous.token, feedIdentity: identity)
        }
        self.selected = selected; self.preparing = prepared != nil; self.motion = motion; self.commit = commit
        feedIdentity = session.feedIdentity
        motion.rootHost = self
        loadViewIfNeeded()
        registerKeyboardNotifications()
        for id in Set(slots.keys).union([selected]).union(prepared.map { [$0] } ?? []) {
            guard let page = pages[id] else { continue }
            let role: RootPageParticipation.Role = id == selected ? .active : id == prepared ? .prepared : .inactive
            let inputs = RootPageInputs(revision: contentRevisions[id] ?? AnyHashable(0), role: role,
                                        environment: environment, session: session)
            let slot: Slot
            let isNew: Bool
            if let retained = slots[id] {
                slot = retained
                isNew = false
            }
            else {
                slot = installSlot(page, tab: id, inputs: inputs, environment: environment, session: session, motion: motion)
                isNew = true
            }
            slot.callbacks.mediaTabs = environment.mediaTabs
            if !isNew, slot.content.update(inputs: inputs, page: {
                hostedPage(page, tab: id, token: slot.token, role: role, callbacks: slot.callbacks,
                           environment: environment, session: session, motion: motion)
            }) {
                RootPageQARecorder.rootUpdate(tab: id, token: slot.token, revision: slot.content.revision)
            }
            let pairOwnsVisibility = visualPair.map { pair in
                (pair.sourceTab == id && pair.sourceToken == slot.token)
                    || (pair.destinationTab == id && pair.destinationToken == slot.token)
            } ?? false
            if !pairOwnsVisibility { slot.host.view.isHidden = role == .inactive }
            slot.host.view.isUserInteractionEnabled = role == .active && prepared == nil
            slot.host.view.isAccessibilityElement = false
            slot.host.view.accessibilityElements = nil
            slot.host.view.accessibilityElementsHidden = role != .active || prepared != nil
        }
        // A prepared target renders behind the unchanged source. A cancelled
        // gesture never makes UIKit switch the source stack's appearance.
        if visualPair == nil, let source = slots[selected]?.host.view {
            view.bringSubviewToFront(source)
            view.accessibilityElements = prepared == nil ? [source] : []
        } else if let pair = visualPair {
            view.accessibilityElements = prepared == nil ? slots[selected].map { [$0.host.view] } : []
            if !visualPairIsCurrent(pair) {
                _ = finishVisualPair(id: pair.id, confirmedSelected: selected)
            }
        }
        motion.rootHostDidUpdate()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-root-idle178") {
            idleMountSession178 = session
            installIdleMountReadback178()
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let allowsIdleMount = !ProcessInfo.processInfo.arguments.contains("--qa-root-idle-control178")
        #else
        let allowsIdleMount = true
        #endif
        if allowsIdleMount, prepared == nil, selected != 0, environment.scenePhase == .active,
           let token = slots[selected]?.token {
            idleMountInputs = IdleMountInputs(source: selected, sourceToken: token, pages: pages,
                revisions: contentRevisions, environment: environment, session: session, identity: session.feedIdentity)
            scheduleIdleMountAfterFrame()
        }
    }

    private func installSlot(_ page: AnyView, tab: Int, inputs: RootPageInputs, environment: EnvironmentValues,
                             session: SiteSession, motion: TabPageMotion) -> Slot {
        let token = UUID()
        let callbacks = RootPageCallbacks(); callbacks.mediaTabs = environment.mediaTabs
        let initial = hostedPage(page, tab: tab, token: token, role: inputs.role, callbacks: callbacks,
                                 environment: environment, session: session, motion: motion)
        let content = RootPageContent(page: initial, inputs: inputs)
        let host = UIHostingController(rootView: RootPageHostView(content: content))
        let slot = Slot(token: token, content: content, callbacks: callbacks, host: host)
        slots[tab] = slot
        // Set the inactive role and UIKit visibility before appearance can run.
        host.view.frame = view.bounds
        host.view.backgroundColor = .clear
        host.view.isHidden = inputs.role == .inactive
        host.view.isUserInteractionEnabled = inputs.role == .active && !preparing
        host.view.isAccessibilityElement = false
        host.view.accessibilityElementsHidden = inputs.role != .active || preparing
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        RootPageQARecorder.rootInstall(tab: tab, token: token, revision: content.revision)
        return slot
    }

    func cancelPrewarming() {
        idleMountGeneration = UUID()
        idleMountBoundary?.cancel(); idleMountBoundary = nil
        idleMountTimer?.invalidate(); idleMountTimer = nil
        idleMountInputs = nil
        idleMountAttempts = 0
    }

    private func nextIdleMount(_ inputs: IdleMountInputs) -> Int? {
        let order = RootTab.order
        guard let index = order.firstIndex(of: inputs.source) else { return nil }
        return [index + 1, index - 1].filter { order.indices.contains($0) }.map { order[$0] }
            .first { $0 != 0 && slots[$0] == nil && inputs.pages[$0] != nil }
    }

    private func scheduleIdleMountAfterFrame() {
        guard let inputs = idleMountInputs, nextIdleMount(inputs) != nil else { idleMountInputs = nil; return }
        let generation = idleMountGeneration
        idleMountBoundary = RenderFrameBoundary { [weak self] in
            guard let self, self.idleMountGeneration == generation else { return }
            self.idleMountBoundary = nil
            self.scheduleIdleMountTimer(generation)
        }
    }

    private func scheduleIdleMountTimer(_ generation: UUID) {
        // Default run-loop mode defers work while UIKit tracks a scroll. A
        // bounded retry also covers deceleration and navigation completion.
        let timer = Timer(timeInterval: 0.20, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.mountNextIdlePage(generation) }
        }
        idleMountTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private func mountNextIdlePage(_ generation: UUID) {
        guard generation == idleMountGeneration, let inputs = idleMountInputs,
              selected == inputs.source, slots[selected]?.token == inputs.sourceToken,
              feedIdentity == inputs.identity, inputs.session.feedIdentity == inputs.identity,
              !preparing, let motion, motion.rootHost === self else { return }
        idleMountTimer = nil
        guard let tab = nextIdleMount(inputs) else { idleMountInputs = nil; return }
        let source = slots[selected]?.host.viewIfLoaded
        guard viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              case .ordinary? = motion.currentCanvasRole(tab: selected),
              motion.rootGestureFrame(tab: selected, in: view) != nil,
              !motion.hasActiveBodyHandoff, motion.interactiveRootDragID == nil,
              source.map({ !hasMovingContent($0) }) == true else {
            idleMountAttempts += 1
            if idleMountAttempts < 8 { scheduleIdleMountTimer(generation) }
            else { idleMountInputs = nil }
            return
        }
        guard let page = inputs.pages[tab] else { return }
        #if DEBUG && targetEnvironment(simulator)
        let cost178 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("rootIdleMount178", cost178) }
        #endif
        let pageInputs = RootPageInputs(revision: inputs.revisions[tab] ?? AnyHashable(0), role: .inactive,
            environment: inputs.environment, session: inputs.session)
        let slot = installSlot(page, tab: tab, inputs: pageInputs, environment: inputs.environment,
                               session: inputs.session, motion: motion)
        slot.host.view.layoutIfNeeded()
        if let source { view.bringSubviewToFront(source) }
        // One new host per idle callback, with a new frame before another.
        idleMountAttempts = 0
        scheduleIdleMountAfterFrame()
    }

    private func hasMovingContent(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        if let scroll = view as? UIScrollView, scroll.isTracking || scroll.isDragging || scroll.isDecelerating { return true }
        if view.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true { return true }
        return view.subviews.contains(where: hasMovingContent)
    }

    func hasInputEditingOrKeyboard(tab: Int) -> Bool {
        guard let slot = slots[tab] else { return false }
        let focused = containsFirstResponder(slot.host.view)
        let visible = keyboardVisible && keyboardWindow === viewIfLoaded?.window
        return focused || visible
    }

    @discardableResult
    func dismissInputForRootSwitch(tab: Int) -> Bool {
        guard let slot = slots[tab] else { return false }
        let active = hasInputEditingOrKeyboard(tab: tab)
        _ = slot.host.view.endEditing(true)
        return active
    }

    private func containsFirstResponder(_ view: UIView) -> Bool {
        if view.isFirstResponder { return true }
        return view.subviews.contains(where: containsFirstResponder)
    }

    private func registerKeyboardNotifications() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for (name, visible, terminal) in [
            (UIResponder.keyboardWillShowNotification, true, false),
            (UIResponder.keyboardDidShowNotification, true, false),
            (UIResponder.keyboardWillHideNotification, true, false),
            (UIResponder.keyboardDidHideNotification, false, true)
        ] {
            keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.updateKeyboardState(note, visible: visible, terminal: terminal) }
            })
        }
    }

    private func updateKeyboardState(_ note: Notification, visible: Bool, terminal: Bool) {
        guard let window = viewIfLoaded?.window else { return }
        if terminal {
            guard keyboardWindow === window else { return }
            keyboardVisible = false
            keyboardWindow = nil
            motion?.rootHostDidUpdate()
            return
        }
        if !visible {
            guard keyboardWindow === window else { return }
            keyboardVisible = true
            return
        }
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let localFrame = window.convert(frame, from: nil)
        guard localFrame.intersects(window.bounds),
              keyboardWindow === window || slots.values.contains(where: { containsFirstResponder($0.host.view) }) else { return }
        keyboardWindow = window
        keyboardVisible = true
    }
    /// Transfer application context explicitly. A second hosting root must not
    /// inherit the representable's private navigation/accessibility environment.
    private func hostedPage(_ page: AnyView, tab: Int, token: UUID, role: RootPageParticipation.Role, callbacks: RootPageCallbacks,
                            environment: EnvironmentValues, session: SiteSession, motion: TabPageMotion) -> AnyView {
        AnyView(page.environmentObject(session).environmentObject(session.oauth)
            .environment(\.scenePhase, environment.scenePhase)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.ordinaryColorScheme, environment.ordinaryColorScheme)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.displayScale, environment.displayScale)
            .environment(\.horizontalSizeClass, environment.horizontalSizeClass)
            .environment(\.verticalSizeClass, environment.verticalSizeClass)
            .environment(\.tabPageMotion, motion)
            .environment(\.motionTab, tab)
            .environment(\.mediaTabs, callbacks.bridgedTabs())
            .environment(\.favoriteSelectionBar, environment.favoriteSelectionBar)
            .environment(\.viewingControlsReferenceInset, environment.viewingControlsReferenceInset)
            .environment(\.floatingPageSafeInsets, environment.floatingPageSafeInsets)
            .environment(\.floatingPageContentInsets, environment.floatingPageContentInsets)
            .environment(\.pageCanvasRole, environment.pageCanvasRole)
            .environment(\.pageVisualActivationPermit, environment.pageVisualActivationPermit)
            .environment(\.rootPageParticipation, RootPageParticipation(token: token, role: role))
            // UIKit owns the temporary preparation shield/AX suppression;
            // that transient bit must not regenerate the active page tree.
            .accessibilityHidden(role != .active))
    }

    func token(for tab: Int) -> UUID? { slots[tab]?.token }

    /// Positions the two existing root hosts as one clipped, token-bound
    /// visual pair. Navigation state and hosting-controller identity remain
    /// owned by their existing slots.
    @discardableResult
    func beginVisualPair(id: UUID, source: Int, destination: Int,
                         sourceToken: UUID, targetToken: UUID, scopeIdentity: String,
                         sourceOwner: UIViewController, targetOwner: UIViewController,
                         sourceColor: UIColor, targetColor: UIColor, sign: CGFloat) -> Bool {
        guard visualPair == nil, source != destination, selected == source,
              feedIdentity == scopeIdentity,
              let window = viewIfLoaded?.window, let scene = window.windowScene,
              scene.activationState == .foregroundActive,
              let sourceSlot = slots[source], sourceSlot.token == sourceToken,
              let targetSlot = slots[destination], targetSlot.token == targetToken,
              navigationOwner(tab: source) === sourceOwner,
              navigationOwner(tab: destination) === targetOwner,
              let sourceView = sourceSlot.host.viewIfLoaded,
              let targetView = targetSlot.host.viewIfLoaded,
              sourceView.superview === view, targetView.superview === view,
              sourceView.window === window, targetView.window === window else { return false }
        view.layoutIfNeeded()
        sourceView.layoutIfNeeded(); targetView.layoutIfNeeded()
        let width = view.bounds.width
        guard width.isFinite, width > 1,
              abs(sourceView.bounds.width - width) <= 2,
              abs(targetView.bounds.width - width) <= 2,
              abs(sourceView.bounds.height - view.bounds.height) <= 2,
              abs(targetView.bounds.height - view.bounds.height) <= 2,
              sourceView.transform == .identity, targetView.transform == .identity,
              CATransform3DIsIdentity(sourceView.layer.transform), CATransform3DIsIdentity(targetView.layer.transform) else { return false }
        let lease = VisualPairLease(id: id, sourceTab: source, destinationTab: destination,
            sourceToken: sourceToken, destinationToken: targetToken, scopeIdentity: scopeIdentity,
            sourceOwner: ObjectIdentifier(sourceOwner), destinationOwner: ObjectIdentifier(targetOwner),
            window: ObjectIdentifier(window), scene: ObjectIdentifier(scene),
            sign: sign < 0 ? -1 : 1, width: width, height: view.bounds.height,
            reduceMotion: UIAccessibility.isReduceMotionEnabled, progress: 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sourceView.backgroundColor = sourceColor; sourceView.isOpaque = true
        targetView.backgroundColor = targetColor; targetView.isOpaque = true
        sourceView.isHidden = false; targetView.isHidden = false
        targetView.alpha = 1; sourceView.alpha = 1
        view.insertSubview(targetView, belowSubview: sourceView)
        view.bringSubviewToFront(sourceView)
        visualPair = lease
        applyVisualPair(lease, sourceView: sourceView, targetView: targetView)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-root-motion181") {
            rootMotionMoveSamples181 = 0; rootMotionMaxSourceX181 = 0; rootMotionMaxTargetX181 = 0
            rootMotionLastEndpoint181 = "none"; rootMotionOutcome181 = "active"
            recordRootMotion181(lease, sourceView: sourceView, targetView: targetView)
        }
        #endif
        CATransaction.commit()
        return true
    }

    @discardableResult
    func setVisualPairProgress(id: UUID, progress: CGFloat) -> Bool {
        guard let pair = visualPair, pair.id == id,
              visualPairIsCurrent(pair), progress.isFinite,
              let sourceView = slots[pair.sourceTab]?.host.viewIfLoaded,
              let targetView = slots[pair.destinationTab]?.host.viewIfLoaded else { return false }
        var updated = pair
        updated.progress = min(1, max(0, progress))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyVisualPair(updated, sourceView: sourceView, targetView: targetView)
        CATransaction.commit()
        visualPair = updated
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-root-motion181") {
            recordRootMotion181(updated, sourceView: sourceView, targetView: targetView)
        }
        #endif
        return true
    }

    /// Clears the pair only after the currently selected route is confirmed.
    /// A stale flight can never clear a newer pair because its id must match.
    @discardableResult
    func finishVisualPair(id: UUID, confirmedSelected: Int) -> Bool {
        guard let pair = visualPair, pair.id == id else { return false }
        guard confirmedSelected == selected, slots[selected] != nil else { return false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-root-motion181"),
           let sourceView = slots[pair.sourceTab]?.host.viewIfLoaded,
           let targetView = slots[pair.destinationTab]?.host.viewIfLoaded {
            recordRootMotion181(pair, sourceView: sourceView, targetView: targetView,
                                outcome: confirmedSelected == pair.destinationTab ? "completed" : "cancelled")
            rootMotionLastEndpoint181 = "progress=\(String(format: "%.4f", pair.progress)),sourceX=\(String(format: "%.2f", sourceView.transform.tx)),targetX=\(String(format: "%.2f", targetView.transform.tx)),selected=\(confirmedSelected)"
        }
        #endif
        if let sourceView = slots[pair.sourceTab]?.host.viewIfLoaded {
            sourceView.transform = .identity; sourceView.alpha = 1
            sourceView.isHidden = selected != pair.sourceTab
        }
        if let targetView = slots[pair.destinationTab]?.host.viewIfLoaded {
            targetView.transform = .identity; targetView.alpha = 1
            targetView.isHidden = selected != pair.destinationTab
        }
        if let selectedView = slots[selected]?.host.view {
            selectedView.transform = .identity
            selectedView.isHidden = false
            view.bringSubviewToFront(selectedView)
        }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-root-motion181"),
           let sourceView = slots[pair.sourceTab]?.host.viewIfLoaded,
           let targetView = slots[pair.destinationTab]?.host.viewIfLoaded {
            // Refresh terminal UIView state after the nonanimated reset while
            // retaining the pre-reset endpoint separately above.
            recordRootMotion181(pair, sourceView: sourceView, targetView: targetView)
        }
        #endif
        visualPair = nil
        CATransaction.commit()
        return true
    }

    func hasVisualPair(id: UUID) -> Bool {
        guard let pair = visualPair, pair.id == id else { return false }
        return visualPairIsCurrent(pair)
    }

    private func visualPairIsCurrent(_ pair: VisualPairLease) -> Bool {
        guard let window = viewIfLoaded?.window,
              ObjectIdentifier(window) == pair.window,
              let scene = window.windowScene, ObjectIdentifier(scene) == pair.scene,
              scene.activationState == .foregroundActive,
              feedIdentity == pair.scopeIdentity,
              abs(view.bounds.width - pair.width) <= 2,
              abs(view.bounds.height - pair.height) <= 2,
              slots[pair.sourceTab]?.token == pair.sourceToken,
              slots[pair.destinationTab]?.token == pair.destinationToken,
              slots[pair.sourceTab]?.host.viewIfLoaded?.superview === view,
              slots[pair.destinationTab]?.host.viewIfLoaded?.superview === view,
              abs((slots[pair.sourceTab]?.host.viewIfLoaded?.bounds.width ?? 0) - pair.width) <= 2,
              abs((slots[pair.destinationTab]?.host.viewIfLoaded?.bounds.width ?? 0) - pair.width) <= 2,
              abs((slots[pair.sourceTab]?.host.viewIfLoaded?.bounds.height ?? 0) - pair.height) <= 2,
              abs((slots[pair.destinationTab]?.host.viewIfLoaded?.bounds.height ?? 0) - pair.height) <= 2,
              slots[pair.sourceTab]?.host.viewIfLoaded?.window === window,
              slots[pair.destinationTab]?.host.viewIfLoaded?.window === window,
              navigationOwner(tab: pair.sourceTab).map(ObjectIdentifier.init) == pair.sourceOwner,
              navigationOwner(tab: pair.destinationTab).map(ObjectIdentifier.init) == pair.destinationOwner else { return false }
        return true
    }

    private func applyVisualPair(_ pair: VisualPairLease, sourceView: UIView, targetView: UIView) {
        let progress = min(1, max(0, pair.progress))
        if pair.reduceMotion {
            sourceView.transform = .identity; targetView.transform = .identity
            sourceView.alpha = 1 - progress; targetView.alpha = 1
            return
        }
        sourceView.alpha = 1; targetView.alpha = 1
        sourceView.transform = CGAffineTransform(translationX: pair.sign * pair.width * progress, y: 0)
        targetView.transform = CGAffineTransform(translationX: -pair.sign * pair.width * (1 - progress), y: 0)
    }
    /// Async view work must recheck the live slot after await; its Environment
    /// value may describe the role at task creation, before a root departure.
    func permitsDataPreparation(token: UUID, identity: String) -> Bool {
        guard feedIdentity == identity, let tab = slots.first(where: { $0.value.token == token })?.key else { return false }
        return selected == tab || motion?.preparedTab == tab
    }
    func owns(_ owner: UIViewController, tab: Int) -> Bool {
        guard let slot = slots[tab], let page = owner.viewIfLoaded else { return false }
        return page === slot.host.view || page.isDescendant(of: slot.host.view)
    }
    /// Resolve the live navigation owner independently of header rendering.
    /// This is used only by ordinary tap fallback, never to force a gesture.
    func navigationOwner(tab: Int) -> UIViewController? {
        guard let slot = slots[tab], let window = viewIfLoaded?.window else { return nil }
        func candidates(_ controller: UIViewController) -> [UIViewController] {
            if let navigation = controller as? UINavigationController {
                guard let owner = navigation.topViewController,
                      owner.viewIfLoaded?.window === window, owns(owner, tab: tab) else { return [] }
                return [owner]
            }
            return controller.children.flatMap(candidates)
        }
        let owners = candidates(slot.host)
        return owners.count == 1 ? owners.first : nil
    }
    func detach() {
        cancelPrewarming()
        rootDragID = nil
        pan.stopWatchingTouchSequence()
        if let pair = visualPair { _ = finishVisualPair(id: pair.id, confirmedSelected: selected) }
        #if DEBUG && targetEnvironment(simulator)
        idleMountReadback178?.removeFromSuperview(); idleMountReadback178 = nil
        idleMountSession178 = nil
        rootMotionReadback181?.removeFromSuperview(); rootMotionReadback181 = nil
        #endif
        VideoPlaybackSessions.shared.retireRootSlots(Set(slots.values.map(\.token)))
        if motion?.rootHost === self {
            motion?.cancel()
            motion?.rootHost = nil
        }
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers.removeAll()
        keyboardWindow = nil; keyboardVisible = false
        slots.values.forEach { $0.callbacks.mediaTabs = nil }
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        cancelPrewarming()
        motion?.cancel()
        super.viewWillTransition(to: size, with: coordinator)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard rootDragID == nil || rootDragID != motion?.interactiveRootDragID else { return false }
        origin = nil; sign = 0; rootDragID = nil
        guard selected != 0, let frame = motion?.rootGestureFrame(tab: selected, in: view) else { return false }
        let point = touch.location(in: view)
        guard frame.contains(point) else { return false }
        if point.x <= frame.minX + 30 { sign = 1 }
        else if point.x >= frame.maxX - 30 { sign = -1 }
        else { return false }
        origin = point
        return true
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: view)
        return origin != nil && velocity.x * sign > 0 && abs(velocity.x) > abs(velocity.y) * 1.4
            && motion?.rootGestureFrame(tab: selected, in: view) != nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        origin != nil && other.view.map { $0 === view || $0.isDescendant(of: view) } == true
    }
    @objc private func dragged() {
        guard let motion else { return }
        switch pan.state {
        case .began:
            let order = RootTab.order
            guard let index = order.firstIndex(of: selected) else { return }
            let next = order[(index + (sign < 0 ? 1 : order.count - 1)) % order.count]
            let generation = pan.resetGeneration
            let result = motion.beginRootSwitch(from: selected, to: next, sign: sign, interactive: true, commit: commit)
            guard case .started = result, let id = motion.interactiveRootDragID else {
                rootDragID = nil
                // No flight owns this gesture; never deliver later move/end
                // callbacks as if navigation had begun.
                pan.isEnabled = false; pan.isEnabled = true
                return
            }
            guard pan.resetGeneration == generation, pan.state == .began || pan.state == .changed else {
                motion.recoverLostRootDrag(id: id)
                return
            }
            rootDragID = id
            pan.watchTouchSequence()
            motion.updateRootSwitch(translation: pan.translation(in: view).x)
        case .changed:
            if let id = rootDragID, motion.interactiveRootDragID == id {
                motion.updateRootSwitch(translation: pan.translation(in: view).x)
            }
        case .ended, .cancelled, .failed:
            guard let id = rootDragID else { return }
            #if DEBUG && targetEnvironment(simulator)
            if !droppedRootPanTerminal, pan.state == .ended,
               ProcessInfo.processInfo.arguments.contains("--qa-drop-root-pan-terminal-and-reset") {
                droppedRootPanTerminal = true
                suppressedRootPanReset = id
                return
            }
            #endif
            rootDragID = nil
            pan.stopWatchingTouchSequence()
            guard motion.interactiveRootDragID == id else { return }
            let cancelled = pan.state != .ended
            motion.endRootSwitch(velocity: cancelled ? 0 : pan.velocity(in: view).x, cancelled: cancelled)
        default: break
        }
    }

    private func rootPanDidReset() {
        #if DEBUG && targetEnvironment(simulator)
        if let ignored = suppressedRootPanReset {
            suppressedRootPanReset = nil
            if rootDragID == ignored { return }
        }
        #endif
        reconcileRootDrag()
    }

    private func reconcileRootDrag() {
        guard let id = rootDragID, let motion else { return }
        Task { @MainActor [weak self, weak motion] in
            guard let self, let motion, self.rootDragID == id else { return }
            self.rootDragID = nil
            self.pan.stopWatchingTouchSequence()
            motion.recoverLostRootDrag(id: id)
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Bounded simulator-only attribution; no per-frame logging or Release work.
@MainActor enum TransitionCostQA174 {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--qa-drag-performance167")
    private static var totals: [String: [Double]] = [:]
    private static var spans: [[Any]] = []
    static var start: Double? { enabled ? CACurrentMediaTime() : nil }
    static func record(_ name: String, _ start: Double?) {
        guard let start else { return }
        let end = CACurrentMediaTime(), ms = (end - start) * 1000
        var row = totals[name] ?? [0, 0, 0]
        row[0] += 1; row[1] += ms; row[2] = max(row[2], ms); totals[name] = row
        if ms >= 4, spans.count < 512 {
            spans.append([name, Date().timeIntervalSince1970 - (end - start), ms])
        }
    }
    static var summary: [String: Any] { ["totals": totals, "spans": spans] }
}

/// Main-thread display callbacks, not GPU frame-rate telemetry. The same
/// bounded passive probe runs in both controlled A/B workloads.
@MainActor private final class DragCadenceQA172: NSObject {
    private static var current: DragCadenceQA172?
    private weak var window: UIWindow?
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var ticks = 0
    private let epochOffset = Date().timeIntervalSince1970 - CACurrentMediaTime()
    private var gaps: [[Double]] = []
    private var observer: NSObjectProtocol?
    private final class Label: UILabel {
        weak var probe: DragCadenceQA172?
        override var accessibilityValue: String? {
            get { probe?.value }
            set { }
        }
    }
    static func attach(to window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-drag-performance167") else { return }
        if let current, current.window === window { return }
        current?.stop()
        current = DragCadenceQA172(window: window)
    }
    private init(window: UIWindow) {
        self.window = window
        super.init()
        let label = Label(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        label.probe = self; label.text = "cadence"; label.font = .systemFont(ofSize: 1)
        label.textColor = .clear; label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true; label.accessibilityTraits = .staticText
        label.accessibilityIdentifier = "performance.cadence172"
        window.addSubview(label)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
        observer = NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification,
            object: window.windowScene, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
    }
    private func stop() {
        link?.invalidate(); link = nil; previous = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        defer { previous = now; ticks += 1 }
        guard let previous else { return }
        let duration = now - previous
        if duration > 0.025, gaps.count < 4096 { gaps.append([previous + epochOffset, duration * 1000]) }
    }
    private var value: String {
        let data = try? JSONSerialization.data(withJSONObject: ["ticks": ticks, "gaps": gaps, "capacity": 4096, "cost174": TransitionCostQA174.summary])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
#endif
