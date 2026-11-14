import SwiftUI
import UIKit

@MainActor
@Observable
final class TabPageMotion {
    enum RootSwitchBeginResult {
        case started
        case temporarilyNotReady(String)
        case blocked(String)
        case invalid(String)
    }
    @ObservationIgnored private var anchors: [Int: [WeakHeaderProbe]] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let bodyHandoff = PageBodyHandoff()
    @ObservationIgnored private var timelineCanvasToken: UUID?
    @ObservationIgnored private var timelineCanvasProvider: ((UIViewController) -> UIView?)?
    @ObservationIgnored var rootFooterRenderer: ((Int, Bool) -> UIImage?)?
    private var canvasRoleDeclarations: [Int: CanvasRoleDeclaration] = [:]
    @ObservationIgnored weak var rootHost: RootTabHostController?
    private(set) var preparedTab: Int?
    private struct ContentLayoutPlan {
        let targetTab: Int
        let targetContentOwner: UUID?
        let sourceClearance: CGFloat
        let targetClearance: CGFloat
        let sourceHeight: CGFloat
        let targetHeight: CGFloat
        let resizesContent: Bool
        var captureClearance: CGFloat { resizesContent ? min(sourceClearance, targetClearance) : targetClearance }
    }
    private struct ContentLayout {
        let plan: ContentLayoutPlan
        var resizing = false
    }
    private var contentLayout: ContentLayout?
    @ObservationIgnored private var rootFlight: RootFlight?
    @ObservationIgnored private var pendingRootSwitch: PendingRootSwitch?
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private weak var beginReadback: UILabel?
    #endif
    @MainActor private final class RootFlight {
        let receipt: PageTransitionReceipt
        let source: Int
        let destination: Int
        let sign: CGFloat
        let interactive: Bool
        let commit: (Int) -> Void
        weak var sourceOwner: UIViewController?
        weak var targetOwner: UIViewController?
        let sourceToken: UUID?
        let scopeIdentity: String
        weak var window: UIWindow?
        weak var scene: UIWindowScene?
        var targetToken: UUID?
        var translation: CGFloat = 0
        var pendingDecision: Bool?
        var ready = false
        var sourceCanvasReady = false
        var settling = false
        var preparationFrames = 0
        var boundary: RenderFrameBoundary?
        var contentPlan: ContentLayoutPlan?
        init(source: Int, destination: Int, sign: CGFloat, interactive: Bool,
             owner: UIViewController, sourceToken: UUID?, targetToken: UUID?, scopeIdentity: String,
             window: UIWindow, receipt: PageTransitionReceipt? = nil, commit: @escaping (Int) -> Void) {
            self.receipt = receipt ?? PageTransitionReceipt()
            self.source = source; self.destination = destination; self.sign = sign
            self.interactive = interactive; self.sourceOwner = owner; self.sourceToken = sourceToken
            self.targetToken = targetToken; self.scopeIdentity = scopeIdentity
            self.window = window; self.scene = window.windowScene
            self.commit = commit
            pendingDecision = interactive ? nil : true
        }
    }
    @MainActor private final class PendingRootSwitch {
        let id = UUID()
        let source: Int
        let destination: Int
        let sign: CGFloat
        let commit: (Int) -> Void
        let receipt = PageTransitionReceipt()
        weak var rootHost: RootTabHostController?
        weak var window: UIWindow?
        weak var scene: UIWindowScene?
        var sourceToken: UUID?
        let scopeIdentity: String
        var attempts = 1
        var waitingForKeyboard = false
        var keyboardFrames = 0
        var stableGeometryFrames = 0
        var lastGeometry: RootTabGeometry?
        var boundary: RenderFrameBoundary?
        var interaction: PageInteractionShield.Lease?
        var deactivation: NSObjectProtocol?
        var finished = false

        init(source: Int, destination: Int, sign: CGFloat, commit: @escaping (Int) -> Void,
             rootHost: RootTabHostController, window: UIWindow) {
            self.source = source; self.destination = destination; self.sign = sign
            self.commit = commit; self.rootHost = rootHost; self.window = window
            scene = window.windowScene; sourceToken = rootHost.token(for: source)
            scopeIdentity = rootHost.feedIdentity ?? ""
        }
    }
    private struct RootTabGeometry: Equatable {
        let windowBounds: CGRect
        let windowSafeArea: UIEdgeInsets
        let hostBounds: CGRect
        let sourceBounds: CGRect?
    }
    private(set) var handoff: HeaderHandoff?
    @ObservationIgnored private var tone: PageToneTransition?
    @ObservationIgnored private var canvasTone: PageToneTransition?
    @ObservationIgnored private weak var canvasSource: UIViewController?

    /// Only the incoming root page consumes a flight's temporary clearance.
    /// Source pages and middle-of-list destinations keep their own geometry.
    func contentClearance(for tab: Int, owner: UUID) -> CGFloat? {
        guard let layout = contentLayout, layout.plan.targetTab == tab,
              layout.plan.targetContentOwner == owner else { return nil }
        let plan = layout.plan
        guard plan.resizesContent else { return plan.targetClearance }
        return layout.resizing ? plan.targetClearance : plan.captureClearance
    }

    @MainActor private final class CanvasRoleDeclaration {
        weak var owner: UIViewController?
        let token: UUID
        let role: PageCanvasRole

        init(owner: UIViewController, token: UUID, role: PageCanvasRole) {
            self.owner = owner
            self.token = token
            self.role = role
        }

        func matches(owner: UIViewController, token: UUID, role: PageCanvasRole) -> Bool {
            self.owner === owner && self.token == token && Self.sameRole(self.role, role)
        }

        static func sameRole(_ lhs: PageCanvasRole, _ rhs: PageCanvasRole) -> Bool {
            switch (lhs, rhs) {
            case (.ordinary, .ordinary), (.playback, .playback): return true
            default: return false
            }
        }
    }

    func register(_ probe: NativeHeaderProbe, tab: Int) {
        var entries = (anchors[tab] ?? []).filter { $0.probe != nil }
        if !entries.contains(where: { $0.probe === probe }) {
            entries.append(WeakHeaderProbe(probe: probe))
        }
        anchors[tab] = entries

        guard let token = probe.rootToken, let role = probe.anchor.appearance?.canvasRole else { return }
        Task { @MainActor [weak self, weak probe] in
            await Task.yield()
            guard let self, let probe,
                  let host = self.rootHost,
                  host.selected == tab, host.token(for: tab) == token,
                  probe.rootToken == token,
                  let owner = PageViewportGeometry.owner(of: probe),
                  host.owns(owner, tab: tab),
                  let nav = owner.navigationController, nav.topViewController === owner,
                  let window = owner.viewIfLoaded?.window,
                  host.viewIfLoaded?.window === window,
                  let latestRole = probe.anchor.appearance?.canvasRole,
                  CanvasRoleDeclaration.sameRole(latestRole, role) else { return }
            if self.canvasRoleDeclarations[tab]?.matches(owner: owner, token: token, role: role) == true { return }
            self.canvasRoleDeclarations[tab] = CanvasRoleDeclaration(owner: owner, token: token, role: role)
        }
    }

    func currentCanvasRole(tab: Int) -> PageCanvasRole? {
        guard let host = rootHost, host.selected == tab,
              let declaration = canvasRoleDeclarations[tab],
              let owner = declaration.owner,
              host.token(for: tab) == declaration.token,
              host.owns(owner, tab: tab),
              let nav = owner.navigationController, nav.topViewController === owner,
              let window = owner.viewIfLoaded?.window,
              host.viewIfLoaded?.window === window else {
            return nil
        }
        return declaration.role
    }

    func registerTimelineCanvas(token: UUID?, provider: @escaping (UIViewController) -> UIView?) {
        guard let token else { return }
        timelineCanvasToken = token
        timelineCanvasProvider = provider
    }

    private func timelineCanvas(for owner: UIViewController) -> UIView? {
        guard let token = timelineCanvasToken, rootHost?.token(for: 0) == token else { return nil }
        return timelineCanvasProvider?(owner)
    }

    func switchPage(from source: Int, to destination: Int,
                    select: @escaping () -> Void) {
        let order = [0, 2, 4, 3]
        let sign: CGFloat = (order.firstIndex(of: destination) ?? 0) > (order.firstIndex(of: source) ?? 0) ? -1 : 1
        let result = beginRootSwitch(from: source, to: destination, sign: sign, interactive: false,
                                     commit: { _ in select() })
        if case .temporarilyNotReady(let reason) = result {
            queueRootSwitch(from: source, to: destination, sign: sign, reason: reason,
                            commit: { _ in select() })
        }
    }

    func rootGestureFrame(tab: Int, in view: UIView) -> CGRect? {
        guard tab != 0, rootFlight == nil, handoff == nil,
              let rootHost, let owner = probe(for: tab).flatMap(PageViewportGeometry.owner),
              rootHost.owns(owner, tab: tab), let nav = owner.navigationController,
              nav.topViewController === owner, nav.viewControllers.first === owner,
              owner.transitionCoordinator == nil, !rootHost.hasInputEditingOrKeyboard(tab: tab),
              !blocksContentActivation(tab: tab),
              let window = owner.viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive,
              window.rootViewController?.presentedViewController == nil,
              let geometry = PageBodyViewports.geometry(containing: owner), geometry.owner === owner,
              let source = owner.viewIfLoaded else { return nil }
        return source.convert(geometry.rect, to: view)
    }

    @discardableResult
    func beginRootSwitch(from source: Int, to destination: Int, sign: CGFloat,
                         interactive: Bool, commit: @escaping (Int) -> Void) -> RootSwitchBeginResult {
        let result = beginRootSwitchAttempt(from: source, to: destination, sign: sign,
                                            interactive: interactive, commit: commit)
        publishBegin(result, source: source, destination: destination,
                     requestID: pendingRootSwitch?.id, attempt: pendingRootSwitch?.attempts ?? 1)
        return result
    }

    private func beginRootSwitchAttempt(from source: Int, to destination: Int, sign: CGFloat,
                                        interactive: Bool, receipt: PageTransitionReceipt? = nil,
                                        commit: @escaping (Int) -> Void) -> RootSwitchBeginResult {
        guard pendingRootSwitch == nil, rootFlight == nil, handoff == nil else { return .blocked("transition-active") }
        let validTabs = [0, 2, 4, 3]
        guard validTabs.contains(source), validTabs.contains(destination), source != destination else {
            return .invalid("invalid-tab-route")
        }
        guard let rootHost else { return .temporarilyNotReady("root-host-unavailable") }
        guard rootHost.selected == source else { return .invalid("source-tab-changed") }
        if rootHost.hasInputEditingOrKeyboard(tab: source) {
            return interactive ? .blocked("keyboard-or-input-active") : .temporarilyNotReady("keyboard-active")
        }
        guard let sourceToken = rootHost.token(for: source), let scopeIdentity = rootHost.feedIdentity,
              let window = rootHost.viewIfLoaded?.window else { return .temporarilyNotReady("source-slot-not-mounted") }
        guard window.windowScene?.activationState == .foregroundActive else { return .blocked("scene-inactive") }
        guard window.rootViewController?.presentedViewController == nil else { return .blocked("system-presentation-active") }
        guard !PageInteractionShield.isActive(in: window) else { return .blocked("input-lease-active") }
        guard let sourceProbe = probe(for: source),
              let owner = PageViewportGeometry.owner(of: sourceProbe) else {
            return .temporarilyNotReady("source-header-owner-not-registered")
        }
        guard rootHost.owns(owner, tab: source) else { return .invalid("source-owner-mismatch") }
        guard let nav = owner.navigationController else { return .invalid("source-navigation-owner-missing") }
        if interactive, nav.viewControllers.first !== owner { return .invalid("edge-source-not-root-navigation-owner") }
        guard owner.transitionCoordinator == nil else { return .blocked("source-transition-active") }
        guard nav.topViewController === owner else { return .invalid("source-not-navigation-top") }
        guard let geometry = PageBodyViewports.geometry(containing: owner), geometry.owner === owner else {
            return .temporarilyNotReady("source-viewport-not-ready")
        }
        guard let outgoing = header(for: source), let fixedHeader = HeaderHandoff(source: outgoing) else {
            return .temporarilyNotReady("source-header-not-rendered")
        }
        guard let sourceFooter = rootFooterRenderer?(source, outgoing.appearance.canvasRole == .playback) else {
            return .temporarilyNotReady("source-footer-not-rendered")
        }
        let sourceCanvas = outgoing.appearance.canvasRole == .playback ? timelineCanvas(for: owner) : owner.viewIfLoaded
        if outgoing.appearance.canvasRole == .playback, sourceCanvas == nil {
            return .temporarilyNotReady("source-media-canvas-not-ready")
        }
        let flight = RootFlight(source: source, destination: destination, sign: sign, interactive: interactive,
                                owner: owner, sourceToken: sourceToken,
                                targetToken: rootHost.token(for: destination), scopeIdentity: scopeIdentity,
                                window: window, receipt: receipt, commit: commit)
        let scheme = outgoing.appearance.colorScheme
        bodyHandoff.prepare(flight.receipt.id, source: owner, kind: interactive ? "tab-edge" : "tab", enabled: true,
                            fallback: scheme == .dark ? .black : .systemBackground,
                            sourceScheme: scheme, sourceIsMedia: outgoing.appearance.canvasRole == .playback)
        guard bodyHandoff.isPrepared(flight.receipt.id) else {
            bodyHandoff.cancel(reason: "source-body-not-ready")
            return .temporarilyNotReady("source-body-not-ready")
        }
        takeHeaderOwnership(from: source)
        guard bodyHandoff.installRootCanvas(flight.receipt.id, target: false, canvas: sourceCanvas, footer: sourceFooter, media: outgoing.appearance.canvasRole == .playback) else {
            bodyHandoff.cancel(reason: "source-canvas-not-ready")
            return .temporarilyNotReady("source-canvas-not-ready")
        }
        rootFlight = flight
        handoff = fixedHeader
        tone = bodyHandoff.tone
        handoff?.joinTone(tone)
        // The initial full source copy owns the header pixels until the live
        // header is hidden and a controls-free canvas has rendered.
        withoutPageAnimation { preparedTab = destination }
        prepareRootTarget(flight)
        return .started
    }

    private func queueRootSwitch(from source: Int, to destination: Int, sign: CGFloat,
                                 reason: String, commit: @escaping (Int) -> Void) {
        guard pendingRootSwitch == nil, rootFlight == nil, handoff == nil,
              let rootHost, rootHost.selected == source,
              let feedIdentity = rootHost.feedIdentity,
              let window = rootHost.viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive,
              !PageInteractionShield.isActive(in: window) else {
            publishBegin(.blocked("pending-owner-unavailable"), source: source, destination: destination,
                         requestID: nil, attempt: 1)
            return
        }
        let request = PendingRootSwitch(source: source, destination: destination, sign: sign,
                                         commit: commit, rootHost: rootHost, window: window)
        guard request.scopeIdentity == feedIdentity else {
            publishBegin(.invalid("pending-scope-not-captured"), source: source, destination: destination,
                         requestID: request.id, attempt: 1)
            return
        }
        request.interaction = PageInteractionShield.acquire(in: window)
        request.waitingForKeyboard = rootHost.dismissInputForRootSwitch(tab: source)
        request.deactivation = NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification, object: window.windowScene, queue: .main
        ) { [weak self, weak request] _ in
            Task { @MainActor [weak self, weak request] in
                guard let self, let request else { return }
                self.finishPendingRootSwitch(request, reason: "scene-deactivated")
            }
        }
        pendingRootSwitch = request
        publishBegin(.temporarilyNotReady(reason), source: source,
                     destination: destination, requestID: request.id, attempt: request.attempts)
        schedulePendingRootSwitch(request)
    }

    private func schedulePendingRootSwitch(_ request: PendingRootSwitch) {
        guard pendingRootSwitch === request, request.boundary == nil else { return }
        request.boundary = RenderFrameBoundary { [weak self, weak request] in
            guard let self, let request else { return }
            request.boundary = nil
            self.attemptPendingRootSwitch(request)
        }
    }

    private func attemptPendingRootSwitch(_ request: PendingRootSwitch) {
        guard pendingRootSwitch === request else { return }
        guard let reason = pendingRootSwitchInvalidReason(request) else {
            guard let host = request.rootHost, let window = request.window else {
                finishPendingRootSwitch(request, reason: "pending-window-lost")
                return
            }
            if host.hasInputEditingOrKeyboard(tab: request.source) { request.waitingForKeyboard = true }
            if request.waitingForKeyboard {
                request.keyboardFrames += 1
                guard request.keyboardFrames <= 90 else {
                    finishPendingRootSwitch(request, reason: "keyboard-dismiss-timeout")
                    return
                }
                if host.hasInputEditingOrKeyboard(tab: request.source) {
                    schedulePendingRootSwitch(request)
                    return
                }
                let geometry = rootTabGeometry(host: host, source: request.source, window: window)
                if geometry == request.lastGeometry { request.stableGeometryFrames += 1 }
                else { request.lastGeometry = geometry; request.stableGeometryFrames = 0 }
                guard request.stableGeometryFrames >= 2 else {
                    schedulePendingRootSwitch(request)
                    return
                }
                request.waitingForKeyboard = false
            }
            request.attempts += 1
            request.interaction?.release(); request.interaction = nil
            pendingRootSwitch = nil
            let result = beginRootSwitchAttempt(from: request.source, to: request.destination, sign: request.sign,
                                                interactive: false, receipt: request.receipt, commit: request.commit)
            publishBegin(result, source: request.source, destination: request.destination,
                         requestID: request.id, attempt: request.attempts)
            switch result {
            case .started:
                request.finished = true
                removePendingObserver(request)
                return
            case .temporarilyNotReady(let reason):
                if request.attempts >= 12 {
                    finishPendingRootSwitch(request, reason: "source-not-ready-timeout:\(reason)")
                    return
                }
                guard let window = request.window,
                      request.rootHost?.viewIfLoaded?.window === window,
                      window.windowScene === request.scene,
                      window.windowScene?.activationState == .foregroundActive else {
                    finishPendingRootSwitch(request, reason: "pending-window-or-scene-changed")
                    return
                }
                request.interaction = PageInteractionShield.acquire(in: window)
                pendingRootSwitch = request
                schedulePendingRootSwitch(request)
            case .blocked(let reason), .invalid(let reason):
                finishPendingRootSwitch(request, reason: "retry-\(reason)")
            }
            return
        }
        finishPendingRootSwitch(request, reason: reason)
    }

    private func rootTabGeometry(host: RootTabHostController, source: Int, window: UIWindow) -> RootTabGeometry {
        let sourceBounds = probe(for: source).flatMap(PageViewportGeometry.owner).flatMap { $0.viewIfLoaded?.bounds }
        return RootTabGeometry(windowBounds: window.bounds, windowSafeArea: window.safeAreaInsets,
                              hostBounds: host.viewIfLoaded?.bounds ?? .zero, sourceBounds: sourceBounds)
    }

    private func pendingRootSwitchInvalidReason(_ request: PendingRootSwitch) -> String? {
        guard request.rootHost === rootHost, let host = request.rootHost else { return "root-host-changed" }
        guard let window = request.window, host.viewIfLoaded?.window === window else { return "window-changed" }
        guard window.windowScene === request.scene,
              window.windowScene?.activationState == .foregroundActive else { return "scene-changed-or-inactive" }
        guard host.selected == request.source else { return "source-tab-changed" }
        guard host.feedIdentity == request.scopeIdentity else { return "session-scope-changed" }
        if let sourceToken = request.sourceToken {
            guard host.token(for: request.source) == sourceToken else { return "source-slot-token-changed" }
        } else if let token = host.token(for: request.source) {
            request.sourceToken = token
        }
        return nil
    }

    private func finishPendingRootSwitch(_ request: PendingRootSwitch, reason: String) {
        guard !request.finished else { return }
        request.finished = true
        if pendingRootSwitch === request { pendingRootSwitch = nil }
        request.boundary?.cancel(); request.boundary = nil
        request.interaction?.release(); request.interaction = nil
        removePendingObserver(request)
        let navigation: PageNavigationOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
        let visual: PageVisualOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
        _ = request.receipt.recordNavigation(navigation, token: request.receipt.id)
        _ = request.receipt.recordVisual(visual, token: request.receipt.id)
        publishBegin(.invalid(reason), source: request.source, destination: request.destination,
                     requestID: request.id, attempt: request.attempts)
    }

    private func removePendingObserver(_ request: PendingRootSwitch) {
        if let observer = request.deactivation {
            NotificationCenter.default.removeObserver(observer)
            request.deactivation = nil
        }
    }

    func rootHostDidUpdate() {
        guard let request = pendingRootSwitch else { return }
        if let reason = pendingRootSwitchInvalidReason(request) {
            finishPendingRootSwitch(request, reason: reason)
        }
    }

    private func publishBegin(_ result: RootSwitchBeginResult, source: Int, destination: Int,
                              requestID: UUID?, attempt: Int) {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--qa-header-motion"),
              let window = pendingRootSwitch?.window ?? rootHost?.viewIfLoaded?.window else { return }
        let resultName: String
        let reason: String
        switch result {
        case .started: resultName = "started"; reason = "none"
        case .temporarilyNotReady(let value): resultName = "temporarilyNotReady"; reason = value
        case .blocked(let value): resultName = "blocked"; reason = value
        case .invalid(let value): resultName = "invalid"; reason = value
        }
        if beginReadback?.superview !== window {
            let label = UILabel(frame: CGRect(x: 1, y: window.bounds.height - 1, width: 1, height: 1))
            label.textColor = .clear; label.font = .systemFont(ofSize: 1)
            label.isUserInteractionEnabled = false; label.isAccessibilityElement = true
            label.accessibilityIdentifier = "header.motion.begin.qa"
            window.addSubview(label); beginReadback = label
        }
        let scopeMatches: Bool
        if let request = pendingRootSwitch { scopeMatches = request.scopeIdentity == rootHost?.feedIdentity }
        else if let flight = rootFlight { scopeMatches = flight.scopeIdentity == rootHost?.feedIdentity }
        else { scopeMatches = true }
        let inputLease = rootHost?.viewIfLoaded?.window.map { PageInteractionShield.isActive(in: $0) } ?? false
        let value = "phase=begin;result=\(resultName);reason=\(reason);request=\(requestID?.uuidString ?? "none");attempt=\(attempt)/12;source=\(source);destination=\(destination);selected=\(rootHost?.selected ?? -1);sourceToken=\(rootHost?.token(for: source)?.uuidString ?? "unbound");scopeMatches=\(scopeMatches);keyboard=\(rootHost?.hasInputEditingOrKeyboard(tab: source) ?? false);inputLease=\(inputLease);rootFlight=\(rootFlight != nil)"
        beginReadback?.accessibilityValue = value
        NSLog("HEADER_BEGIN \(value)")
        #endif
    }

    private func prepareRootTarget(_ flight: RootFlight) {
        flight.boundary = RenderFrameBoundary { [weak self, weak flight] in
            guard let self, let flight, self.rootFlight === flight else { return }
            flight.boundary = nil
            guard self.rootFlightIsValid(flight), self.bodyHandoff.isPrepared(flight.receipt.id) else {
                self.cancel(reason: "source-scope-invalid-before-target-frame"); return
            }
            guard self.probe(for: flight.source, includingHidden: true)?.rendersLiveControls == false else {
                self.retryPreparingRootTarget(flight); return
            }
            if !flight.sourceCanvasReady {
                guard let source = flight.sourceOwner, let header = self.handoff else {
                    self.cancel(reason: "source-canvas-owner-lost"); return
                }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                let refreshed = self.bodyHandoff.refreshRootSource(flight.receipt.id, source: source)
                if refreshed { self.bodyHandoff.installFixedHeader(token: flight.receipt.id, handoff: header) }
                CATransaction.commit()
                guard refreshed else { self.cancel(reason: "source-clean-canvas-unavailable"); return }
                flight.sourceCanvasReady = true
            }
            guard self.probe(for: flight.destination, includingHidden: true)?.rendersLiveControls == false else {
                self.retryPreparingRootTarget(flight); return
            }
            if let target = self.probe(for: flight.destination, includingHidden: true).flatMap(PageViewportGeometry.owner),
               self.rootHost?.owns(target, tab: flight.destination) == true,
               let incoming = self.header(for: flight.destination), let outgoing = self.handoff?.source {
                if flight.contentPlan == nil {
                    let targetClearance = incoming.appearance.contentClearance
                        ?? incoming.frame.height + FloatingPageChrome.topInset + FloatingPageChrome.bottomInset
                    let sourceClearance = outgoing.appearance.contentClearance
                        ?? outgoing.frame.height + targetClearance - incoming.frame.height
                    let plan = ContentLayoutPlan(targetTab: flight.destination,
                        targetContentOwner: incoming.appearance.contentOwner,
                        sourceClearance: sourceClearance, targetClearance: targetClearance,
                        sourceHeight: outgoing.frame.height, targetHeight: incoming.frame.height,
                        resizesContent: incoming.appearance.canvasRole == .ordinary
                            && incoming.appearance.contentOwner != nil
                            && !incoming.appearance.retainsViewport
                            && abs(sourceClearance - targetClearance) > 1
                            && abs(outgoing.frame.height - incoming.frame.height) > 1)
                    flight.contentPlan = plan
                    // Capture the larger of both body viewports. Its pixels
                    // move inside a fixed clip; they never leave a bottom gap.
                    self.contentLayout = ContentLayout(plan: plan)
                    if plan.resizesContent && abs(plan.captureClearance - plan.targetClearance) > 1 {
                        self.prepareRootTarget(flight)
                        return
                    }

                }
                if let plan = flight.contentPlan, plan.resizesContent {
                    guard let geometry = PageBodyViewports.geometry(containing: target),
                          let view = geometry.owner.viewIfLoaded,
                          abs(geometry.rect.minY - (view.bounds.minY + view.safeAreaInsets.top + plan.captureClearance)) <= 2 else {
                        self.retryPreparingRootTarget(flight)
                        return
                    }
                }
                guard self.bodyHandoff.stageTarget(flight.receipt.id, destination: target) else {
                    self.retryPreparingRootTarget(flight)
                    return
                }
                flight.targetToken = self.rootHost?.token(for: flight.destination)
                flight.targetOwner = target
                let isMedia = incoming.appearance.canvasRole == .playback
                let canvas = isMedia ? self.timelineCanvas(for: target) : target.viewIfLoaded
                guard (!isMedia || canvas != nil),
                      let footer = self.rootFooterRenderer?(flight.destination, isMedia),
                      self.handoff?.stageRoot(incoming) == true else {
                    self.retryPreparingRootTarget(flight)
                    return
                }
                self.handoff?.usePreparedCanvas()
                let startOffset = flight.contentPlan.map { $0.resizesContent ? $0.sourceClearance - $0.captureClearance : 0 } ?? 0
                let endOffset = flight.contentPlan.map { $0.resizesContent ? $0.targetClearance - $0.captureClearance : 0 } ?? 0
                guard self.bodyHandoff.installRootCanvas(flight.receipt.id, target: true, canvas: canvas,
                                                        footer: footer, media: isMedia, bodyStartOffset: startOffset, bodyEndOffset: endOffset) else {
                    self.retryPreparingRootTarget(flight)
                    return
                }
                flight.ready = true
                self.updateRootSwitch(translation: flight.translation)
                if let decision = flight.pendingDecision { self.settleRoot(flight, accepted: decision) }
            } else {
                self.retryPreparingRootTarget(flight)
            }
        }
    }

    private func retryPreparingRootTarget(_ flight: RootFlight) {
        flight.preparationFrames += 1
        if flight.preparationFrames < 12 { prepareRootTarget(flight) }
        else { cancel(reason: "target-not-ready-timeout") }
    }

    private func rootFlightIsValid(_ flight: RootFlight) -> Bool {
        guard rootFlight === flight, let host = rootHost, let window = flight.window,
              host.selected == flight.source, host.token(for: flight.source) == flight.sourceToken,
              host.feedIdentity == flight.scopeIdentity,
              host.viewIfLoaded?.window === window, window.windowScene === flight.scene,
              window.windowScene?.activationState == .foregroundActive,
              let owner = flight.sourceOwner, host.owns(owner, tab: flight.source) else { return false }
        return true
    }

    func updateRootSwitch(translation: CGFloat) {
        guard let flight = rootFlight, !flight.settling else { return }
        flight.translation = translation
        guard flight.ready, let source = flight.sourceOwner?.viewIfLoaded else { return }
        let progress = min(1, max(0, translation * flight.sign / max(1, source.bounds.width)))
        bodyHandoff.updateInteractive(flight.receipt.id, progress: Double(progress), direction: flight.sign)
    }
    func endRootSwitch(velocity: CGFloat, cancelled: Bool) {
        guard let flight = rootFlight, !flight.settling else { return }
        let width = flight.sourceOwner?.viewIfLoaded?.bounds.width ?? 1
        let distance = max(0, flight.translation * flight.sign)
        let accepted = !cancelled && (distance > width * 0.28 || (distance > 14 && velocity * flight.sign > 650))
        flight.pendingDecision = accepted
        if flight.ready { settleRoot(flight, accepted: accepted) }
    }

    private func settleRoot(_ flight: RootFlight, accepted: Bool) {
        guard rootFlight === flight, !flight.settling else { return }
        guard rootFlightIsValid(flight) else { cancel(reason: "source-scope-changed-before-settle"); return }
        flight.settling = true
        bodyHandoff.settleInteractive(flight.receipt.id, toDestination: accepted, direction: flight.sign) { [weak self, weak flight] finished in
            guard let self, let flight, self.rootFlight === flight else { return }
            guard self.rootFlightIsValid(flight) else { self.cancel(reason: "source-scope-changed-during-settle"); return }
            guard accepted, finished, let target = flight.targetOwner,
                  self.rootHost?.owns(target, tab: flight.destination) == true,
                  self.rootHost?.token(for: flight.destination) == flight.targetToken else { self.cancel(); return }
            flight.receipt.recordNavigation(.committed, token: flight.receipt.id)
            withoutPageAnimation {
                self.contentLayout?.resizing = true
                flight.commit(flight.destination)
            }
            // At p=1 the fixed header, footer, canvas and body already show
            // the target. Commit once, then keep those exact pixels until the
            // live target has drawn the same final geometry.
            self.pending = Task { [weak self, weak flight, weak target] in
                guard let self, let flight, let target, self.rootFlight === flight else { return }
                self.bodyHandoff.releaseInteractive(flight.receipt.id, destination: target) { [weak self, weak flight] outcome in
                    guard let self, let flight, self.rootFlight === flight else { return }
                    flight.receipt.recordVisual(outcome, token: flight.receipt.id)
                    self.rootFlight = nil
                    withoutPageAnimation { self.preparedTab = nil; self.handoff = nil; self.contentLayout = nil }
                    self.tone = nil
                }
            }
        }
    }

    @discardableResult
    func prepareHeaderLayout(tab: Int, expectedHeight: CGFloat, identity: AnyHashable?, commit: @escaping () -> Void) -> Bool {
        guard let probe = (anchors[tab] ?? []).reversed().compactMap(\.probe).first(where: { probe in
            guard probe.anchor.visibleFrame != nil else { return false }
            if let rootHost {
                guard probe.rootToken == rootHost.token(for: tab),
                      let owner = PageViewportGeometry.owner(of: probe), rootHost.owns(owner, tab: tab) else { return false }
            }
            return probe.navigationController?.topViewController.map { probe.belongs(to: $0) } ?? true
        }) else { return false }
        guard let window = probe.viewIfLoaded?.window else { return false }
        NativeHeaderMotion.forWindow(window).prepareLayoutChange(from: probe, expectedHeight: expectedHeight, identity: identity, commit: commit)
        return true
    }

    func navigationTone(from role: PageCanvasRole, tab: Int) -> PageToneTransition? {
        for window in (anchors[tab] ?? []).compactMap({ $0.probe?.viewIfLoaded?.window }) {
            if let tone = NativeHeaderMotion.forWindow(window).navigationTone(from: role) { return tone }
        }
        return nil
    }

    func rememberCanvasTone(_ tone: PageToneTransition, tab: Int) {
        canvasTone = tone
        let role: PageCanvasRole = tone.sourceIsMedia ? .playback : .ordinary
        canvasSource = (anchors[tab] ?? []).compactMap(\.probe).reversed().first {
            $0.anchor.visibleFrame != nil && $0.settledHeader?.appearance.canvasRole == role
        }.flatMap { PageViewportGeometry.owner(of: $0) }
    }
    func clearCanvasTone(_ id: UUID) {
        guard canvasTone?.id == id else { return }
        canvasTone = nil; canvasSource = nil
    }
    func canvasTone(for source: UIViewController) -> PageToneTransition? {
        guard canvasSource === source, let canvasTone, !canvasTone.clock.finished, canvasTone.clock.progress < 1 else { return nil }
        return canvasTone
    }

    /// Check the existing window lease at action dispatch, including the touch
    /// that was delivered before a drag's shield was installed.
    func blocksContentActivation(tab: Int?) -> Bool {
        let entries = tab.map { anchors[$0] ?? [] } ?? anchors.values.flatMap { $0 }
        return entries.compactMap { $0.probe?.viewIfLoaded?.window }
            .contains { PageInteractionShield.isActive(in: $0) }
    }

    var hasActiveBodyHandoff: Bool {
        anchors.values.flatMap { $0 }.compactMap { $0.probe?.viewIfLoaded?.window }
            .contains { PageBodyHandoff.toneContext(in: $0).tone != nil }
    }

    func markRootTabDeparture(from tab: Int) {
        guard let probe = anchors[tab]?.reversed().compactMap({ $0.probe }).first,
              let owner = probe.navigationController?.topViewController else { return }
        PageEdgeReturnPolicy.markRootTabDeparture(owner: owner)
    }

    func takeHeaderOwnership(from tab: Int) {
        guard let window = anchors[tab]?.compactMap({ $0.probe?.viewIfLoaded?.window }).first else { return }
        NativeHeaderMotion.forWindow(window).yieldToTabSwitch()
    }

    func cancel(reason: String = "cancelled") {
        if let request = pendingRootSwitch { finishPendingRootSwitch(request, reason: reason) }
        if let flight = rootFlight {
            publishBegin(.invalid(reason), source: flight.source, destination: flight.destination,
                         requestID: flight.receipt.id, attempt: flight.preparationFrames)
            rootFlight = nil
            flight.boundary?.cancel()
            let navigation: PageNavigationOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
            let visual: PageVisualOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
            flight.receipt.recordNavigation(navigation, token: flight.receipt.id)
            flight.receipt.recordVisual(visual, token: flight.receipt.id)
        }
        preparedTab = nil
        contentLayout = nil
        pending?.cancel()
        pending = nil
        bodyHandoff.cancel(reason: reason)
        let outgoing = handoff
        withoutPageAnimation {
            handoff = nil
        }
        outgoing?.cancel()
        let oldTone = tone; tone = nil
        oldTone?.clock.finish()
    }

    private func probe(for tab: Int, includingHidden: Bool = false) -> NativeHeaderProbe? {
        anchors[tab]?.reversed().compactMap(\.probe).first { probe in
            // This flight deliberately hides real header controls. That alpha
            // must not make the mounted destination owner unavailable.
            guard probe.viewIfLoaded?.window != nil, probe.anchor.bounds.width > 1,
                  includingHidden || probe.anchor.visibleFrame != nil else { return false }
            if let rootHost {
                guard probe.rootToken == rootHost.token(for: tab),
                      let owner = PageViewportGeometry.owner(of: probe), rootHost.owns(owner, tab: tab) else { return false }
            }
            return probe.navigationController?.topViewController.map { probe.belongs(to: $0) } ?? true
        }
    }

    private func header(for tab: Int) -> HeaderContent? {
        guard let probe = probe(for: tab, includingHidden: true), probe.showsChrome else { return nil }
        if let current = probe.currentHeader { return current }
        if let source = handoff?.source { return probe.headerForFixedHost(alignedTo: source) }
        return probe.settledHeader
    }

}

@MainActor
final class HeaderAnchor: UIView {
    var onWindowChange: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
    var appearance: HeaderAppearance?

    var visibleFrame: CGRect? {
        guard let window, !bounds.isEmpty else { return nil }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return nil }
            view = current.superview
        }
        let frame = convert(bounds, to: window)
        return window.bounds.insetBy(dx: -24, dy: 0).contains(frame) ? frame : nil
    }
}

private struct WeakHeaderProbe {
    weak var probe: NativeHeaderProbe?
}

private struct HeaderProbe: UIViewControllerRepresentable {
    let motion: TabPageMotion?
    let tab: Int?
    let appearance: HeaderAppearance
    let nativeMotionEnabled: Bool
    let showsChrome: Bool
    let liveControlsVisible: Bool
    @Environment(\.nativeHeaderRouteID) private var routeID
    @Environment(\.rootPageParticipation) private var participation
    let onHandoffChange: (HeaderHandoff?) -> Void

    func makeUIViewController(context: Context) -> NativeHeaderProbe { NativeHeaderProbe() }

    static func dismantleUIViewController(_ controller: NativeHeaderProbe, coordinator: ()) {
        controller.invalidateControlsReadiness()
    }

    func updateUIViewController(_ controller: NativeHeaderProbe, context: Context) {
        controller.nativeMotionEnabled = nativeMotionEnabled && participation.isActive
        controller.rootToken = participation.token
        controller.showsChrome = showsChrome
        controller.updateAppearance(appearance)
        controller.routeID = routeID
        controller.onHandoffChange = onHandoffChange
        controller.updateControlsVisibility(liveControlsVisible)
        if let motion, let tab { motion.register(controller, tab: tab) }
    }
}

extension EnvironmentValues {
    @Entry var tabPageMotion: TabPageMotion? = nil
    @Entry var motionTab: Int? = nil
}

private struct TabHeaderSurfaceRegistration: ViewModifier {
    let appearance: HeaderAppearance
    let verticalInset: CGFloat
    let enabled: Bool
    let participatesInTabs: Bool
    var onNativeHandoff: (HeaderHandoff?) -> Void
    @State private var nativeHandoff: HeaderHandoff?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabPageMotion) private var motion
    @Environment(\.motionTab) private var tab

    func body(content: Content) -> some View {
        let tabHandoff = enabled && participatesInTabs && motion?.handoff != nil
        let blocksInteraction = tabHandoff || nativeHandoff != nil
        content
            .opacity(blocksInteraction ? 0 : 1)
            .animation(nil, value: blocksInteraction)
            .allowsHitTesting(!blocksInteraction)
            .accessibilityHidden(blocksInteraction)
            .background {
                HeaderProbe(motion: enabled && participatesInTabs ? motion : nil, tab: tab, appearance: appearance,
                            nativeMotionEnabled: !reduceMotion && motion?.handoff == nil, showsChrome: enabled,
                            liveControlsVisible: !blocksInteraction,
                            onHandoffChange: {
                                nativeHandoff = $0
                                onNativeHandoff($0)
                            })
                    .padding(.vertical, verticalInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func tabHeaderSurface(_ appearance: HeaderAppearance, verticalInset: CGFloat,
                          enabled: Bool = true, participatesInTabs: Bool = true,
                          onNativeHandoff: @escaping (HeaderHandoff?) -> Void = { _ in }) -> some View {
        modifier(TabHeaderSurfaceRegistration(appearance: appearance, verticalInset: verticalInset,
                                              enabled: enabled, participatesInTabs: participatesInTabs,
                                              onNativeHandoff: onNativeHandoff))
    }
}

/// Owns only new touches during an app transition. Existing drags retain their
/// original touch target, so they can still complete or cancel normally.
@MainActor final class PageInteractionShield {
    @MainActor final class Lease {
        private weak var owner: PageInteractionShield?
        private let id: UUID
        fileprivate init(owner: PageInteractionShield, id: UUID) { self.owner = owner; self.id = id }
        func release() { owner?.release(id); owner = nil }
    }
    private static var windowKey: UInt8 = 0
    private weak var window: UIWindow?
    private let blocker = UIView()
    private var owners = Set<UUID>()
    #if DEBUG && targetEnvironment(simulator)
    private var readback: UILabel?
    private var acquired = 0
    private var blockedSamples = 0
    #endif
    private init(window: UIWindow) {
        self.window = window
        blocker.backgroundColor = .clear
        blocker.isAccessibilityElement = true
        blocker.accessibilityLabel = "正在切换"
        blocker.accessibilityViewIsModal = true
        blocker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    static func acquire(in window: UIWindow) -> Lease {
        let shield: PageInteractionShield
        if let current = objc_getAssociatedObject(window, &windowKey) as? PageInteractionShield { shield = current }
        else {
            shield = PageInteractionShield(window: window)
            objc_setAssociatedObject(window, &windowKey, shield, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let id = UUID(); shield.owners.insert(id)
        shield.blocker.frame = window.bounds
        window.addSubview(shield.blocker)
        #if DEBUG && targetEnvironment(simulator)
        shield.acquired += 1
        if blocksNewTouches(in: window) { shield.blockedSamples += 1 }
        shield.updateReadback()
        #endif
        return Lease(owner: shield, id: id)
    }
    static func isActive(in window: UIWindow) -> Bool {
        guard let shield = objc_getAssociatedObject(window, &windowKey) as? PageInteractionShield else { return false }
        return !shield.owners.isEmpty
    }

    static func blocksNewTouches(in window: UIWindow) -> Bool {
        guard let shield = objc_getAssociatedObject(window, &windowKey) as? PageInteractionShield,
              !shield.owners.isEmpty else { return false }
        return window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: nil) === shield.blocker
    }
    private func release(_ id: UUID) {
        owners.remove(id)
        if owners.isEmpty { blocker.removeFromSuperview() }
        #if DEBUG && targetEnvironment(simulator)
        updateReadback()
        #endif
    }
    #if DEBUG && targetEnvironment(simulator)
    private func updateReadback() {
        guard let window, ProcessInfo.processInfo.arguments.contains("--qa-segment-edge") || ProcessInfo.processInfo.arguments.contains("--qa-header-motion") else { return }
        if readback == nil {
            let label = UILabel(frame: CGRect(x: 0, y: window.bounds.height - 2, width: 1, height: 1))
            label.alpha = 0.01; label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true; label.accessibilityIdentifier = "page.interaction-lock"
            label.autoresizingMask = [.flexibleTopMargin]
            window.addSubview(label); readback = label
        }
        readback?.accessibilityValue = "locks=\(owners.count);acquired=\(acquired);blocked=\(blockedSamples)"
    }
    #endif
}
