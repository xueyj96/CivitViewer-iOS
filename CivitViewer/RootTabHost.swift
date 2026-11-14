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

@MainActor @Observable fileprivate final class RootPageContent {
    var page: AnyView
    @ObservationIgnored private(set) var revision = 0

    init(page: AnyView) { self.page = page }

    func update(page: AnyView) {
        self.page = page
        #if DEBUG && targetEnvironment(simulator)
        revision &+= 1
        #endif
    }
}

@MainActor fileprivate struct RootPageHostView: View {
    let content: RootPageContent
    var body: some View { content.page }
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
    let motion: TabPageMotion
    let commit: (Int) -> Void
    @Environment(\.self) private var environment
    @EnvironmentObject private var session: SiteSession

    func makeUIViewController(context: Context) -> RootTabHostController { RootTabHostController() }
    func updateUIViewController(_ controller: RootTabHostController, context: Context) {
        controller.update(selected: selected, prepared: prepared, pages: pages,
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
        let host: UIHostingController<RootPageHostView>
    }
    private var slots: [Int: Slot] = [:]
    private(set) var selected = 0
    private(set) var feedIdentity: String?
    private var preparing = false
    private weak var motion: TabPageMotion?
    private var commit: (Int) -> Void = { _ in }
    private var origin: CGPoint?
    private var sign: CGFloat = 0
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
    private weak var keyboardWindow: UIWindow?
    private var keyboardVisible = false
    private var keyboardObservers: [NSObjectProtocol] = []

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = false
        pan.delegate = self
        pan.cancelsTouchesInView = true
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG && targetEnvironment(simulator)
        if let window = view.window { DragCadenceQA172.attach(to: window) }
        #endif
    }
    func update(selected: Int, prepared: Int?, pages: [Int: AnyView], environment: EnvironmentValues,
                session: SiteSession, motion: TabPageMotion, commit: @escaping (Int) -> Void) {
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
            let slot: Slot
            let isNew: Bool
            if let retained = slots[id] {
                slot = retained
                isNew = false
            }
            else {
                let token = UUID()
                let initial = hostedPage(page, tab: id, token: token, role: role,
                                         environment: environment, session: session, motion: motion)
                let content = RootPageContent(page: initial)
                let host = UIHostingController(rootView: RootPageHostView(content: content))
                slot = Slot(token: token, content: content, host: host); slots[id] = slot
                isNew = true
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
                RootPageQARecorder.rootInstall(tab: id, token: token, revision: content.revision)
            }
            if !isNew {
                slot.content.update(page: hostedPage(page, tab: id, token: slot.token, role: role,
                                                     environment: environment, session: session, motion: motion))
                RootPageQARecorder.rootUpdate(tab: id, token: slot.token, revision: slot.content.revision)
            }
            slot.host.view.isHidden = role == .inactive
            slot.host.view.isUserInteractionEnabled = role == .active && prepared == nil
            slot.host.view.isAccessibilityElement = false
            slot.host.view.accessibilityElements = nil
            slot.host.view.accessibilityElementsHidden = role != .active || prepared != nil
        }
        // A prepared target renders behind the unchanged source. A cancelled
        // gesture never makes UIKit switch the source stack's appearance.
        if let source = slots[selected]?.host.view {
            view.bringSubviewToFront(source)
            view.accessibilityElements = prepared == nil ? [source] : []
        }
        motion.rootHostDidUpdate()
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
    private func hostedPage(_ page: AnyView, tab: Int, token: UUID, role: RootPageParticipation.Role,
                            environment: EnvironmentValues, session: SiteSession, motion: TabPageMotion) -> AnyView {
        AnyView(page.environmentObject(session).environmentObject(session.oauth)
            .environment(\.scenePhase, environment.scenePhase)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.ordinaryColorScheme, environment.ordinaryColorScheme)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.tabPageMotion, motion)
            .environment(\.motionTab, tab)
            .environment(\.mediaTabs, environment.mediaTabs)
            .environment(\.favoriteSelectionBar, environment.favoriteSelectionBar)
            .environment(\.viewingControlsReferenceInset, environment.viewingControlsReferenceInset)
            .environment(\.floatingPageSafeInsets, environment.floatingPageSafeInsets)
            .environment(\.floatingPageContentInsets, environment.floatingPageContentInsets)
            .environment(\.pageCanvasRole, environment.pageCanvasRole)
            .environment(\.rootPageParticipation, RootPageParticipation(token: token, role: role))
            .accessibilityHidden(role != .active || preparing))
    }

    func token(for tab: Int) -> UUID? { slots[tab]?.token }
    func owns(_ owner: UIViewController, tab: Int) -> Bool {
        guard let slot = slots[tab], let page = owner.viewIfLoaded else { return false }
        return page === slot.host.view || page.isDescendant(of: slot.host.view)
    }
    func detach() {
        VideoPlaybackSessions.shared.retireRootSlots(Set(slots.values.map(\.token)))
        motion?.cancel(); motion?.rootHost = nil
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers.removeAll()
        keyboardWindow = nil; keyboardVisible = false
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        motion?.cancel()
        super.viewWillTransition(to: size, with: coordinator)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        origin = nil; sign = 0
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
            let order = [0, 2, 4, 3]
            guard let index = order.firstIndex(of: selected) else { return }
            let next = order[(index + (sign < 0 ? 1 : order.count - 1)) % order.count]
            motion.beginRootSwitch(from: selected, to: next, sign: sign, interactive: true, commit: commit)
            motion.updateRootSwitch(translation: pan.translation(in: view).x)
        case .changed: motion.updateRootSwitch(translation: pan.translation(in: view).x)
        case .ended: motion.endRootSwitch(velocity: pan.velocity(in: view).x, cancelled: false)
        case .cancelled, .failed: motion.endRootSwitch(velocity: 0, cancelled: true)
        default: break
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
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
        let data = try? JSONSerialization.data(withJSONObject: ["ticks": ticks, "gaps": gaps, "capacity": 4096])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
#endif
