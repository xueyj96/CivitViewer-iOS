import SwiftUI
import UIKit

extension View {
    func existingFeedbackToast(
        _ message: String?,
        id: AnyHashable? = nil,
        active: Bool = true,
        global: Bool = false,
        scope: AnyHashable? = nil,
        dismissOnClear: Bool = false,
        file: StaticString = #fileID, line: UInt = #line,
        onShown: ((String) -> Void)? = nil
    ) -> some View {
        modifier(ExistingFeedbackToastModifier(message: message, id: id, active: active,
                                               global: global, scope: scope, namespace: "\(file):\(line)",
                                               dismissOnClear: dismissOnClear, onShown: onShown))
    }
}

private struct ExistingFeedbackToastModifier: ViewModifier {
    let message: String?
    let id: AnyHashable?
    let active: Bool
    let global: Bool
    let scope: AnyHashable?
    let namespace: String
    let dismissOnClear: Bool
    let onShown: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rootPageParticipation) private var participation
    @State private var sourceActivated = false

    func body(content: Content) -> some View {
        content.background {
            if global || message != nil || sourceActivated {
            ExistingFeedbackToastAnchor(message: message, id: id,
                                        active: active && (global || participation.isActive),
                                        global: global, scope: scope, namespace: namespace,
                                        dismissOnClear: dismissOnClear,
                                        colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
                                        reduceMotion: reduceMotion, onShown: onShown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onAppear { if message != nil { sourceActivated = true } }
        .onChange(of: message) { _, value in if value != nil { sourceActivated = true } }
    }
}

private struct ExistingFeedbackToastAnchor: UIViewControllerRepresentable {
    let message: String?
    let id: AnyHashable?
    let active: Bool
    let global: Bool
    let scope: AnyHashable?
    let namespace: String
    let dismissOnClear: Bool
    let colorScheme: ColorScheme
    let dynamicTypeSize: DynamicTypeSize
    let reduceMotion: Bool
    let onShown: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AnchorController {
        let controller = AnchorController()
        controller.layoutChanged = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            coordinator.layoutChanged(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: AnchorController, context: Context) {
        context.coordinator.update(from: controller, message: message, id: id, active: active,
                                   global: global, scope: scope, namespace: namespace, colorScheme: colorScheme,
                                   dismissOnClear: dismissOnClear,
                                   dynamicTypeSize: dynamicTypeSize, reduceMotion: reduceMotion,
                                   onShown: onShown)
    }

    static func dismantleUIViewController(_ controller: AnchorController, coordinator: Coordinator) {
        controller.layoutChanged = nil
        coordinator.close()
    }

    @MainActor
    final class AnchorController: UIViewController {
        var layoutChanged: (() -> Void)?

        override func loadView() {
            let marker = UIView()
            marker.backgroundColor = .clear
            marker.isUserInteractionEnabled = false
            marker.accessibilityElementsHidden = true
            view = marker
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            layoutChanged?()
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); layoutChanged?() }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); layoutChanged?() }
    }

    @MainActor
    final class Coordinator {
        private struct Pending {
            let message: String
            let event: EventKey
            let revision: Int
        }

        private let source = UUID()
        private weak var controller: AnchorController?
        private weak var window: UIWindow?
        private weak var host: AppFeedbackToastHost?
        private var message: String?
        private var id: AnyHashable?
        private var scope: AnyHashable?
        private var namespace = ""
        private var eventOwner: UUID?
        private var deliveryScheduled = false
        private var removeCurrent = false
        private var active = false
        private var global = false
        private var dismissOnClear = false
        private var colorScheme: ColorScheme = .light
        private var dynamicTypeSize: DynamicTypeSize = .large
        private var reduceMotion = false
        private var onShown: ((String) -> Void)?
        private var lastEvent: EventKey?
        private var hasUpdated = false
        private var pending: Pending?
        private var revision = 0

        func update(from controller: AnchorController, message: String?, id: AnyHashable?, active: Bool,
                    global: Bool, scope: AnyHashable?, namespace: String, colorScheme: ColorScheme, dismissOnClear: Bool,
                    dynamicTypeSize: DynamicTypeSize, reduceMotion: Bool, onShown: ((String) -> Void)?) {
            self.controller = controller
            if let attached = controller.viewIfLoaded?.window { window = attached }
            let scopeChanged = hasUpdated && (self.scope != scope || self.namespace != namespace)
            let retainedOldMessage = scopeChanged && self.message == message && self.id == id
            if scopeChanged {
                revision += 1; pending = nil; lastEvent = nil; removeCurrent = true
            }
            let nextEvent = message.map { EventKey(message: $0, id: id, scope: scope, namespace: namespace) }
            if message == nil {
                revision += 1; pending = nil
                if let lastEvent, let eventOwner { host?.forget(lastEvent, owner: eventOwner) }
                lastEvent = nil
                if dismissOnClear { removeCurrent = true }
            }
            self.message = message; self.id = id; self.scope = scope; self.namespace = namespace
            self.active = active; self.global = global; self.dismissOnClear = dismissOnClear
            self.colorScheme = colorScheme; self.dynamicTypeSize = dynamicTypeSize
            self.reduceMotion = reduceMotion; self.onShown = onShown; hasUpdated = true
            if retainedOldMessage { lastEvent = nextEvent }
            else if let message, let nextEvent, lastEvent != nextEvent {
                revision += 1; lastEvent = nextEvent
                pending = Pending(message: message, event: nextEvent, revision: revision)
            }
            if !active { removeCurrent = true }
            scheduleDelivery()
        }

        func layoutChanged(from controller: AnchorController) {
            if let attached = controller.viewIfLoaded?.window { window = attached }
            scheduleDelivery()
        }

        private func scheduleDelivery() {
            guard !deliveryScheduled else { return }
            deliveryScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deliveryScheduled = false
                if self.removeCurrent {
                    self.host?.remove(source: self.source, animated: !self.reduceMotion)
                    self.removeCurrent = false
                }
                guard let controller = self.controller else { return }
                let visibleWindow = controller.viewIfLoaded?.window ?? (self.global ? self.window : nil)
                guard self.active, let visibleWindow, Self.isForeground(visibleWindow),
                      self.global || Self.hasVisibleSource(controller, in: visibleWindow) else {
                    self.host?.remove(source: self.source, animated: !self.reduceMotion)
                    return
                }
                if self.pending != nil { self.presentIfVisible(from: controller) }
            }
        }

        func close() {
            revision += 1; pending = nil
            let existing = host, source = source, animated = !reduceMotion
            DispatchQueue.main.async { existing?.remove(source: source, animated: animated) }
            host = nil; controller = nil; window = nil; onShown = nil
        }

        private func presentIfVisible(from controller: AnchorController) {
            guard let pending, pending.revision == revision,
                  message == pending.message, lastEvent == pending.event,
                  active, let window = controller.viewIfLoaded?.window ?? (global ? self.window : nil) else { return }

            if let oldWindow = self.window, oldWindow !== window {
                host?.remove(source: source, animated: !reduceMotion)
                host = nil
            }
            self.window = window
            guard Self.isForeground(window) else { return }
            guard global || Self.hasVisibleSource(controller, in: window) else { return }
            let owner = PageViewportGeometry.owner(of: controller) ?? controller
            let eventOwner = AppFeedbackToastHost.identity(for: owner)
            self.eventOwner = eventOwner

            let host = AppFeedbackToastHost.forWindow(window)
            self.host = host
            let result = host.present(message: pending.message, event: pending.event, owner: eventOwner, source: source,
                                      colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
                                      reduceMotion: reduceMotion)
            self.pending = nil
            guard result.shouldCallOnShown else { return }
            let presentedRevision = revision
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host,
                      self.revision == presentedRevision,
                      self.message == pending.message,
                      self.lastEvent == pending.event,
                      host.isShowing(message: pending.message, source: self.source) else { return }
                self.onShown?(pending.message)
            }
        }

        private static func isForeground(_ window: UIWindow) -> Bool {
            guard !window.isHidden, window.alpha > 0.01,
                  window.windowScene?.activationState == .foregroundActive else { return false }
            return true
        }

        private static func hasVisibleSource(_ controller: AnchorController, in window: UIWindow) -> Bool {
            guard hasVisibleAnchor(controller, in: window), let owner = PageViewportGeometry.owner(of: controller),
                  owner.viewIfLoaded?.window === window,
                  owner.navigationController.map({ $0.topViewController === owner }) ?? true else { return false }
            var current: UIViewController? = owner
            while let candidate = current {
                if candidate.presentedViewController != nil { return false }
                current = candidate.parent
            }
            return true
        }

        private static func hasVisibleAnchor(_ controller: AnchorController, in window: UIWindow) -> Bool {
            guard let view = controller.viewIfLoaded, view.window === window else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden || current.alpha <= 0.01 { return false }
                if current === window { break }
                ancestor = current.superview
            }
            guard ancestor === window else { return false }
            let rect = view.convert(view.bounds, to: window)
            if view.bounds.isEmpty {
                let origin = view.convert(CGPoint.zero, to: window)
                return window.bounds.contains(origin)
            }
            return rect.intersects(window.bounds)
        }
    }
}

private struct EventKey: Hashable {
    let namespace: String
    let scope: AnyHashable?
    let id: AnyHashable?
    let message: String

    init(message: String, id: AnyHashable?, scope: AnyHashable?, namespace: String) {
        self.namespace = namespace
        self.scope = scope
        self.id = id
        self.message = message
    }
}

private struct ToastDisplay: Identifiable {
    let id: UUID
    let message: String
    let colorScheme: ColorScheme
    let dynamicTypeSize: DynamicTypeSize
    let reduceMotion: Bool
    var sources: Set<UUID>
}

@MainActor
private final class AppFeedbackToastState: ObservableObject {
    @Published var display: ToastDisplay?
}

@MainActor
private final class AppFeedbackToastHost {
    enum PresentResult {
        case shown, coalesced, alreadySeen
        var shouldCallOnShown: Bool {
            switch self {
            case .shown, .coalesced: true
            case .alreadySeen: false
            }
        }
    }

    private struct ScopedEvent: Hashable { let event: EventKey; let owner: UUID }
    private final class OwnerIdentity { let id = UUID() }
    private static var ownerKey: UInt8 = 0
    static func identity(for owner: UIViewController) -> UUID {
        if let identity = objc_getAssociatedObject(owner, &ownerKey) as? OwnerIdentity { return identity.id }
        let identity = OwnerIdentity()
        objc_setAssociatedObject(owner, &ownerKey, identity, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return identity.id
    }
    private static var associationKey: UInt8 = 0
    private let state = AppFeedbackToastState()
    private var display: ToastDisplay? {
        get { state.display }
        set { state.display = newValue }
    }
    private var seenEvents: [ScopedEvent: Date] = [:]
    private weak var window: UIWindow?
    private let passthrough = ToastPassthroughView()
    private lazy var controller = UIHostingController(rootView: ToastWindowContent(state: state))
    private var expiry: DispatchWorkItem?

    private init(window: UIWindow) {
        self.window = window
        controller.view.backgroundColor = .clear
        controller.view.accessibilityViewIsModal = false
        if #available(iOS 16.4, *) { controller.safeAreaRegions = [] }
        passthrough.backgroundColor = .clear
        passthrough.isAccessibilityElement = false
        passthrough.accessibilityViewIsModal = false
        passthrough.frame = window.bounds
        passthrough.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(passthrough)
        controller.view.frame = passthrough.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        passthrough.addSubview(controller.view)
    }

    static func forWindow(_ window: UIWindow) -> AppFeedbackToastHost {
        if let host = objc_getAssociatedObject(window, &associationKey) as? AppFeedbackToastHost { return host }
        let host = AppFeedbackToastHost(window: window)
        objc_setAssociatedObject(window, &associationKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return host
    }

    func present(message: String, event: EventKey, owner: UUID, source: UUID, colorScheme: ColorScheme,
                 dynamicTypeSize: DynamicTypeSize, reduceMotion: Bool) -> PresentResult {
        pruneSeenEvents()
        if let window { window.bringSubviewToFront(passthrough) }
        let key = ScopedEvent(event: event, owner: owner)
        let alreadySeen = seenEvents[key] != nil
        seenEvents[key] = Date()
        if var current = display, current.message == message {
            current.sources.insert(source)
            display = current
            if !alreadySeen { scheduleExpiry(for: current) }
            return alreadySeen ? .alreadySeen : .coalesced
        }
        guard !alreadySeen else { return .alreadySeen }
        expiry?.cancel()
        let next = ToastDisplay(id: UUID(), message: message, colorScheme: colorScheme,
                                dynamicTypeSize: dynamicTypeSize, reduceMotion: reduceMotion,
                                sources: [source])
        setDisplay(next, reduceMotion: reduceMotion)
        scheduleExpiry(for: next)
        return .shown
    }

    private func scheduleExpiry(for toast: ToastDisplay) {
        expiry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.display?.id == toast.id else { return }
            self.setDisplay(nil, reduceMotion: toast.reduceMotion)
            self.expiry = nil
        }
        expiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: item)
    }

    func isShowing(message: String, source: UUID) -> Bool {
        display?.message == message && display?.sources.contains(source) == true
    }

    func forget(_ event: EventKey, owner: UUID) {
        seenEvents.removeValue(forKey: ScopedEvent(event: event, owner: owner))
    }

    func remove(source: UUID, animated: Bool) {
        guard var current = display, current.sources.remove(source) != nil else { return }
        if current.sources.isEmpty {
            expiry?.cancel(); expiry = nil
            setDisplay(nil, reduceMotion: !animated)
        } else {
            display = current
        }
    }

    private func setDisplay(_ value: ToastDisplay?, reduceMotion: Bool) {
        if reduceMotion { display = value }
        else { withAnimation(.easeInOut(duration: 0.15)) { display = value } }
    }

    private func pruneSeenEvents() {
        let cutoff = Date().addingTimeInterval(-600)
        seenEvents = seenEvents.filter { $0.value >= cutoff }
        if seenEvents.count > 128 {
            for key in seenEvents.sorted(by: { $0.value < $1.value }).prefix(seenEvents.count - 128).map(\.key) {
                seenEvents.removeValue(forKey: key)
            }
        }
    }
}

@MainActor
private final class ToastPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private struct ToastWindowContent: View {
    @ObservedObject var state: AppFeedbackToastState

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let display = state.display {
                    Text(display.message)
                        .font(FloatingPageChrome.controlFont)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(FloatingPageChrome.cardInset)
                        .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
                        .overlay {
                            FloatingPageChrome.controlShape.strokeBorder(Color.primary.opacity(0.08),
                                                                         lineWidth: ContentMetrics.Optical.hairline)
                        }
                        .shadow(color: .black.opacity(display.colorScheme == .dark ? 0.22 : 0.12), radius: 14, y: 6)
                        .frame(maxWidth: max(0, min(340, geometry.size.width - 32)))
                        .environment(\.colorScheme, display.colorScheme)
                        .environment(\.dynamicTypeSize, display.dynamicTypeSize)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("app.toast")
                        .accessibilityLabel(display.message)
                        .accessibilityValue(display.message)
                        .accessibilityAddTraits(.isStaticText)
                        .transition(.opacity)
                        .id(display.id)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}
