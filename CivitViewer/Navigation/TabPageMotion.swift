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
    var rootFooterMotion: RootFooterMotion { bodyHandoff.rootFooterMotion }
    @ObservationIgnored var rootFooterRenderer: ((Int, Bool) -> UIImage?)?
    private var canvasRoleDeclarations: [Int: CanvasRoleDeclaration] = [:]
    private struct AcceptedCanvas {
        let flightID: UUID
        let tab: Int
        let token: UUID
        let owner: ObjectIdentifier
        let window: ObjectIdentifier
        let scope: String
        let role: PageCanvasRole
    }
    private var acceptedCanvas: AcceptedCanvas?
    @ObservationIgnored weak var rootHost: RootTabHostController?
    var preparedTab: Int? { preparation?.tab }
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
    private struct RootPreparation {
        let tab: Int
        var layout: ContentLayout?
    }
    private struct RootHeaderReveal {
        let flightID: UUID
        let tab: Int
        let targetToken: UUID
        let owner: ObjectIdentifier
        let window: ObjectIdentifier
        let contentOwner: UUID?
        let layoutIdentity: AnyHashable?
        let canvasRole: PageCanvasRole
        let colorScheme: ColorScheme
    }
    private var preparation: RootPreparation?
    private var contentLayout: ContentLayout? {
        get { preparation?.layout }
        set {
            guard var value = preparation else { return }
            value.layout = newValue
            preparation = value
        }
    }
    private struct HeaderLayoutStamp: Equatable {
        let frame: CGRect
        let firstRow: CGFloat
        let surfaceHeight: CGFloat?
        let clearance: CGFloat?
        let contentOwner: UUID?
        let layoutIdentity: AnyHashable?
        let retainsViewport: Bool
        let media: Bool
        let scheme: ColorScheme
        init(_ header: HeaderContent) {
            frame = header.frame; firstRow = header.appearance.firstRowHeight
            surfaceHeight = header.appearance.surfaceHeight; clearance = header.appearance.contentClearance
            contentOwner = header.appearance.contentOwner; layoutIdentity = header.appearance.layoutIdentity
            retainsViewport = header.appearance.retainsViewport; media = header.appearance.canvasRole == .playback
            scheme = header.appearance.colorScheme
        }
    }
    private struct WarmLayoutSignature: Equatable {
        let scope: String
        let sourceToken: UUID
        var targetToken: UUID
        let sourceOwner: ObjectIdentifier
        let targetOwner: ObjectIdentifier
        let window: ObjectIdentifier
        let scene: ObjectIdentifier?
        let windowBounds: CGRect
        let windowInsets: UIEdgeInsets
        let sourceBounds: CGRect
        let targetBounds: CGRect
        let sourceInsets: UIEdgeInsets
        let targetInsets: UIEdgeInsets
        let sourceAnchorFrame: CGRect
        let targetAnchorFrame: CGRect
        let sourceHeader: HeaderLayoutStamp
        let targetHeader: HeaderLayoutStamp
        let contentSize: UIContentSizeCategory
        let scale: CGFloat
        let direction: UIUserInterfaceLayoutDirection
        let orientation: UIInterfaceOrientation
    }
    @ObservationIgnored private var rootFlight: RootFlight?
    @ObservationIgnored private var pendingRootSwitch: PendingRootSwitch?
    @ObservationIgnored private var queuedRootIntent: QueuedRootIntent?
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
        var fixedControlsReady = false
        var visualPairStarted = false
        var progress = 0.0
        var settling = false
        var destinationCommitted = false
        var rebounding = false
        var settleAnimator: RenderProgressAnimation?
        var preparationFrames = 0
        var boundary: RenderFrameBoundary?
        var contentPlan: ContentLayoutPlan?
        var warmLayout: WarmLayoutSignature?
        #if DEBUG && targetEnvironment(simulator)
        let readyStart175 = TransitionCostQA174.start
        #endif
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
        weak var sourceOwner: UIViewController?
        let scopeIdentity: String
        var attempts = 1
        var waitingForKeyboard = false
        var keyboardFrames = 0
        var stableGeometryFrames = 0
        var lastGeometry: RootTabGeometry?
        var boundary: RenderFrameBoundary?
        var deactivation: NSObjectProtocol?
        var finished = false

        init(source: Int, destination: Int, sign: CGFloat, commit: @escaping (Int) -> Void,
             rootHost: RootTabHostController, window: UIWindow) {
            self.source = source; self.destination = destination; self.sign = sign
            self.commit = commit; self.rootHost = rootHost; self.window = window
            scene = window.windowScene; sourceToken = rootHost.token(for: source)
            sourceOwner = rootHost.navigationOwner(tab: source)
            scopeIdentity = rootHost.feedIdentity ?? ""
        }
    }

    /// A tab tap that arrives after selection has committed but before the
    /// visual pair has handed the live top/bottom controls back. Keep only the
    /// latest intent. The captured scope, source slot token, and navigation
    /// owner are rechecked before replay so an old completion cannot navigate
    /// a newly logged-in account or a replaced root page.
    @MainActor private final class QueuedRootIntent {
        let source: Int
        let destination: Int
        let sourceToken: UUID
        let sourceOwner: ObjectIdentifier
        let scopeIdentity: String
        let commit: () -> Void

        init(source: Int, destination: Int, sourceToken: UUID, sourceOwner: UIViewController,
             scopeIdentity: String, commit: @escaping () -> Void) {
            self.source = source; self.destination = destination
            self.sourceToken = sourceToken
            self.sourceOwner = ObjectIdentifier(sourceOwner)
            self.scopeIdentity = scopeIdentity
            self.commit = commit
        }
    }
    private struct RootTabGeometry: Equatable {
        let windowBounds: CGRect
        let windowSafeArea: UIEdgeInsets
        let hostBounds: CGRect
        let sourceBounds: CGRect?
    }
    private(set) var handoff: HeaderHandoff?
    private var liveRootHeaderReveal: RootHeaderReveal?
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
            guard let self, let probe else { return }
            _ = self.installCanvasRoleDeclaration(probe, tab: tab, token: token, role: role)
        }
    }

    @discardableResult
    private func installCanvasRoleDeclaration(_ probe: NativeHeaderProbe, tab: Int, token: UUID,
                                              role: PageCanvasRole, matching expected: HeaderContent? = nil) -> Bool {
        guard let host = rootHost,
              host.selected == tab, host.token(for: tab) == token,
              probe.rootToken == token,
              let owner = PageViewportGeometry.owner(of: probe),
              host.owns(owner, tab: tab),
              let nav = owner.navigationController, nav.topViewController === owner,
              let window = owner.viewIfLoaded?.window,
              host.viewIfLoaded?.window === window,
              let latestRole = probe.anchor.appearance?.canvasRole,
              CanvasRoleDeclaration.sameRole(latestRole, role) else { return false }
        if let expected {
            guard let current = probe.currentHeader ?? probe.settledHeader,
                  abs(current.frame.minX - expected.frame.minX) <= 2,
                  abs(current.frame.minY - expected.frame.minY) <= 2,
                  abs(current.frame.width - expected.frame.width) <= 2,
                  abs(current.frame.height - expected.frame.height) <= 1,
                  current.appearance.contentOwner == expected.appearance.contentOwner,
                  current.appearance.layoutIdentity == expected.appearance.layoutIdentity,
                  current.appearance.colorScheme == expected.appearance.colorScheme,
                  CanvasRoleDeclaration.sameRole(current.appearance.canvasRole, role) else { return false }
        }
        if canvasRoleDeclarations[tab]?.matches(owner: owner, token: token, role: role) != true {
            canvasRoleDeclarations[tab] = CanvasRoleDeclaration(owner: owner, token: token, role: role)
        }
        if let acceptedCanvas, acceptedCanvas.tab == tab, acceptedCanvas.token == token,
           acceptedCanvas.owner == ObjectIdentifier(owner),
           CanvasRoleDeclaration.sameRole(acceptedCanvas.role, role) {
            self.acceptedCanvas = nil
        }
        return true
    }

    func committedRootCanvasRole(tab: Int) -> PageCanvasRole? {
        guard let acceptedCanvas, acceptedCanvas.tab == tab,
              let host = rootHost, host.feedIdentity == acceptedCanvas.scope,
              host.token(for: tab) == acceptedCanvas.token,
              let window = host.viewIfLoaded?.window,
              ObjectIdentifier(window) == acceptedCanvas.window,
              let owner = host.navigationOwner(tab: tab),
              ObjectIdentifier(owner) == acceptedCanvas.owner else { return nil }
        // This projection is published with the binding commit. UIKit's
        // selected value is a later acknowledgement, not its input.
        return acceptedCanvas.role
    }

    func revealsLiveRootHeader(tab: Int, token: UUID?, appearance: HeaderAppearance) -> Bool {
        guard let reveal = liveRootHeaderReveal,
              token == reveal.targetToken, reveal.tab == tab,
              let flight = rootFlight, flight.receipt.id == reveal.flightID,
              let host = rootHost, host.selected == tab, host.token(for: tab) == reveal.targetToken,
              let target = flight.destinationCommitted ? flight.targetOwner : flight.sourceOwner,
              (flight.destinationCommitted ? flight.destination : flight.source) == tab,
              ObjectIdentifier(target) == reveal.owner,
              host.owns(target, tab: tab),
              let window = flight.window, ObjectIdentifier(window) == reveal.window,
              window.windowScene === flight.scene, window.windowScene?.activationState == .foregroundActive,
              target.viewIfLoaded?.window === window, host.viewIfLoaded?.window === window,
              appearance.contentOwner == reveal.contentOwner,
              appearance.layoutIdentity == reveal.layoutIdentity,
              appearance.colorScheme == reveal.colorScheme,
              CanvasRoleDeclaration.sameRole(appearance.canvasRole, reveal.canvasRole) else { return false }
        return true
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

    func switchPage(from source: Int, to destination: Int,
                    select: @escaping () -> Void) {
        if source == destination {
            // A same-page re-press is the newest user intent. It must not
            // leave an older committed-tail replay queued behind it.
            queuedRootIntent = nil
            return
        }
        let order = RootTab.order
        let sign: CGFloat = (order.firstIndex(of: destination) ?? 0) > (order.firstIndex(of: source) ?? 0) ? -1 : 1
        // Selection is published before the live top/bottom controls finish
        // rendering. Keep a button tap made in that short terminal interval;
        // replay only after the current flight has cleaned up and revalidated
        // its source owner and account-bound feed scope.
        if let flight = rootFlight, flight.destinationCommitted, source == flight.destination {
            queueRootIntent(source: source, destination: destination, commit: select)
            return
        }
        if rootFlight != nil || handoff != nil { return }
        queuedRootIntent = nil
        if let pending = pendingRootSwitch {
            let sameOwner = pendingRootSwitchInvalidReason(pending) == nil
            if sameOwner, pending.source == source, pending.destination == destination { return }
            let waitingForKeyboard = sameOwner && pending.source == source && pending.waitingForKeyboard
            finishPendingRootSwitch(pending, reason: "superseded-by-tab")
            if waitingForKeyboard {
                queueRootSwitch(from: source, to: destination, sign: sign, reason: "keyboard-settling",
                                preservingKeyboardWait: true, commit: { _ in select() })
                return
            }
        }
        let result = beginRootSwitch(from: source, to: destination, sign: sign, interactive: false,
                                     commit: { _ in select() })
        if case .temporarilyNotReady(let reason) = result {
            queueRootSwitch(from: source, to: destination, sign: sign, reason: reason,
                            commit: { _ in select() })
        }
    }

    private func queueRootIntent(source: Int, destination: Int, commit: @escaping () -> Void) {
        guard source != destination,
              let host = rootHost,
              host.selected == source,
              let scopeIdentity = host.feedIdentity,
              let sourceToken = host.token(for: source),
              let sourceOwner = host.navigationOwner(tab: source),
              let window = host.viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive else {
            queuedRootIntent = nil
            return
        }
        queuedRootIntent = QueuedRootIntent(source: source, destination: destination,
            sourceToken: sourceToken, sourceOwner: sourceOwner,
            scopeIdentity: scopeIdentity, commit: commit)
    }

    private func replayQueuedRootIntentIfCurrent() {
        guard rootFlight == nil, handoff == nil, pendingRootSwitch == nil,
              let intent = queuedRootIntent else { return }
        queuedRootIntent = nil
        guard let host = rootHost,
              host.selected == intent.source,
              host.feedIdentity == intent.scopeIdentity,
              host.token(for: intent.source) == intent.sourceToken,
              host.navigationOwner(tab: intent.source).map(ObjectIdentifier.init) == intent.sourceOwner,
              let window = host.viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive else { return }
        // Re-enter the normal route path so keyboard, presentation, input
        // lease, header ownership, and target readiness are checked afresh.
        switchPage(from: intent.source, to: intent.destination, select: intent.commit)
    }

    func rootGestureFrame(tab: Int, in view: UIView) -> CGRect? {
        guard tab != 0, pendingRootSwitch == nil, rootFlight == nil, handoff == nil,
              let rootHost, let owner = probe(for: tab).flatMap(PageViewportGeometry.owner),
              rootHost.owns(owner, tab: tab), let nav = owner.navigationController,
              nav.topViewController === owner, nav.viewControllers.first === owner,
              owner.transitionCoordinator == nil, !rootHost.hasInputEditingOrKeyboard(tab: tab),
              !blocksContentActivation(tab: tab),
              let window = owner.viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive,
              window.rootViewController?.presentedViewController == nil,
              let geometry = PageBodyViewports.geometry(containing: owner), geometry.owner === owner,
              // Readiness is metadata only. Screenshots and ImageRenderer run
              // after recognition, never in shouldReceive / shouldBegin.
              let header = header(for: tab),
              let footer = PageBodyViewports.rootFooterEndpoint(in: window),
              footer.selectedTab == tab,
              footer.overMedia == (header.appearance.canvasRole == .playback),
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
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("rootBegin", cost174) }
        #endif
        guard pendingRootSwitch == nil, rootFlight == nil, handoff == nil else { return .blocked("transition-active") }
        guard RootTab(rawValue: source) != nil, RootTab(rawValue: destination) != nil, source != destination else {
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
        guard let sourceFooter = PageBodyViewports.rootFooterEndpoint(in: window),
              sourceFooter.selectedTab == source,
              sourceFooter.overMedia == (outgoing.appearance.canvasRole == .playback) else {
            return .temporarilyNotReady("source-footer-not-rendered")
        }
        let flight = RootFlight(source: source, destination: destination, sign: sign, interactive: interactive,
                                owner: owner, sourceToken: sourceToken,
                                targetToken: rootHost.token(for: destination), scopeIdentity: scopeIdentity,
                                window: window, receipt: receipt, commit: commit)
        guard bodyHandoff.prepareRootLive(flight.receipt.id, source: owner, sourceTab: source,
                                          destinationTab: destination,
                                          kind: interactive ? "tab-edge" : "tab",
                                          sourceMedia: outgoing.appearance.canvasRole == .playback,
                                          sourceFooter: sourceFooter) else {
            bodyHandoff.cancel(reason: "source-controls-not-ready")
            return .temporarilyNotReady("source-controls-not-ready")
        }
        takeHeaderOwnership(from: source)
        rootFlight = flight
        rootHost.cancelPrewarming()
        bodyHandoff.installFixedHeader(token: flight.receipt.id, handoff: fixedHeader)
        guard bodyHandoff.bindRootHeaderVisibility(flight.receipt.id, probe: sourceProbe,
                owner: owner, rootToken: sourceToken, isCurrent: { [weak self, weak flight] in
                    guard let self, let flight else { return false }
                    return self.rootFlightIsValid(flight)
                }) else {
            cancel(reason: "source-control-owner-not-ready")
            return .temporarilyNotReady("source-control-owner-not-ready")
        }
        flight.fixedControlsReady = true
        handoff = fixedHeader
        tone = nil
        var prelayout: ContentLayout?
        #if DEBUG && targetEnvironment(simulator)
        let allowsWarmLayout = !ProcessInfo.processInfo.arguments.contains("--qa-root-layout-plan-control175")
        #else
        let allowsWarmLayout = true
        #endif
        if allowsWarmLayout, let targetProbe = probe(for: destination, includingHidden: true),
           let incoming = targetProbe.settledHeader ?? targetProbe.headerForFixedHost(alignedTo: outgoing),
           let signature = warmLayoutSignature(flight, targetProbe: targetProbe, incoming: incoming, outgoing: outgoing) {
            let plan = contentPlan(destination: destination, incoming: incoming, outgoing: outgoing)
            var expected = signature
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-root-layout-mismatch175") { expected.targetToken = UUID() }
            #endif
            // Equal-height warm pages need their final clearance too. Publish
            // it with the prepared role rather than adding a second frame for
            // an otherwise identical plan after the first geometry check.
            flight.contentPlan = plan; flight.warmLayout = expected
            prelayout = ContentLayout(plan: plan, resizing: true)
        }
        // Role and clearance share one observed preparation value. No view can
        // consume a prepared role with a different publication's layout plan.
        withoutPageAnimation { preparation = RootPreparation(tab: destination, layout: prelayout) }
        prepareRootTarget(flight)
        return .started
    }

    private func queueRootSwitch(from source: Int, to destination: Int, sign: CGFloat,
                                 reason: String, preservingKeyboardWait: Bool = false,
                                 commit: @escaping (Int) -> Void) {
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
        // Publish the exact intent before ending editing. UIKit may report
        // a host update synchronously during the resignation.
        pendingRootSwitch = request
        request.deactivation = NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification, object: window.windowScene, queue: .main
        ) { [weak self, weak request] _ in
            Task { @MainActor [weak self, weak request] in
                guard let self, let request else { return }
                self.finishPendingRootSwitch(request, reason: "scene-deactivated")
            }
        }
        let dismissedInput = rootHost.dismissInputForRootSwitch(tab: source)
        guard pendingRootSwitch === request else { return }
        request.waitingForKeyboard = dismissedInput || preservingKeyboardWait
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
                guard pendingRootSwitch == nil else {
                    finishPendingRootSwitch(request, reason: "superseded-by-tab")
                    return
                }
                if request.attempts >= 12 {
                    if !commitPendingRootSwitchWithoutAnimation(request) {
                        finishPendingRootSwitch(request, reason: "source-not-ready-timeout:\(reason)")
                    }
                    return
                }
                guard let window = request.window,
                      request.rootHost?.viewIfLoaded?.window === window,
                      window.windowScene === request.scene,
                      window.windowScene?.activationState == .foregroundActive else {
                    finishPendingRootSwitch(request, reason: "pending-window-or-scene-changed")
                    return
                }
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
        if let owner = request.sourceOwner {
            guard host.navigationOwner(tab: request.source) === owner else { return "source-navigation-owner-changed" }
        }
        if let sourceToken = request.sourceToken {
            guard host.token(for: request.source) == sourceToken else { return "source-slot-token-changed" }
        } else if let token = host.token(for: request.source) {
            request.sourceToken = token
        }
        return nil
    }

    /// A button remains actionable when only its visual capture is unavailable.
    /// No pointer gesture reaches this path, and every captured ownership fence
    /// must still match before the one nonanimated route commit.
    private func commitPendingRootSwitchWithoutAnimation(_ request: PendingRootSwitch) -> Bool {
        guard !request.finished, pendingRootSwitchInvalidReason(request) == nil,
              pendingRootSwitch == nil || pendingRootSwitch === request,
              rootFlight == nil, handoff == nil,
              let host = request.rootHost, let window = request.window,
              !host.hasInputEditingOrKeyboard(tab: request.source),
              window.rootViewController?.presentedViewController == nil,
              !PageInteractionShield.isActive(in: window),
              let owner = request.sourceOwner,
              host.navigationOwner(tab: request.source) === owner,
              host.owns(owner, tab: request.source),
              owner.transitionCoordinator == nil,
              owner.navigationController?.topViewController === owner else { return false }
        request.finished = true
        if pendingRootSwitch === request { pendingRootSwitch = nil }
        request.boundary?.cancel(); request.boundary = nil
        removePendingObserver(request)
        takeHeaderOwnership(from: request.source)
        request.receipt.recordNavigation(.committed, token: request.receipt.id)
        withoutPageAnimation { request.commit(request.destination) }
        request.receipt.recordVisual(.completed, token: request.receipt.id)
        publishBegin(.started, source: request.source, destination: request.destination,
                     requestID: request.id, attempt: request.attempts)
        return true
    }

    private func finishPendingRootSwitch(_ request: PendingRootSwitch, reason: String) {
        guard !request.finished else { return }
        request.finished = true
        if pendingRootSwitch === request { pendingRootSwitch = nil }
        request.boundary?.cancel(); request.boundary = nil
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
        if let request = pendingRootSwitch, let reason = pendingRootSwitchInvalidReason(request) {
            finishPendingRootSwitch(request, reason: reason)
        }
        guard let flight = rootFlight else { return }
        if flight.destinationCommitted {
            guard let target = flight.targetOwner, rootCommittedTargetIsCurrent(flight, target: target) else {
                cancel(reason: "committed-root-host-updated-out-of-scope")
                return
            }
        } else if !rootFlightIsValid(flight) {
            cancel(reason: "root-host-updated-out-of-scope")
        }
    }

    private func publishBegin(_ result: RootSwitchBeginResult, source: Int, destination: Int,
                              requestID: UUID?, attempt: Int) {
        let event: NavigationTrace.Event
        switch result {
        case .started: event = .rootStarted
        case .temporarilyNotReady: event = .rootPreparing
        case .blocked, .invalid: event = .rootRejected
        }
        NavigationDiagnostics.mark(event, tab: destination)
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

    private func contentPlan(destination: Int, incoming: HeaderContent, outgoing: HeaderContent) -> ContentLayoutPlan {
        let targetClearance = incoming.appearance.contentClearance
            ?? incoming.frame.height + FloatingPageChrome.topInset + FloatingPageChrome.bottomInset
        let sourceClearance = outgoing.appearance.contentClearance
            ?? outgoing.frame.height + targetClearance - incoming.frame.height
        return ContentLayoutPlan(targetTab: destination, targetContentOwner: incoming.appearance.contentOwner,
            sourceClearance: sourceClearance, targetClearance: targetClearance,
            sourceHeight: outgoing.frame.height, targetHeight: incoming.frame.height,
            resizesContent: incoming.appearance.canvasRole == .ordinary && incoming.appearance.contentOwner != nil
                && !incoming.appearance.retainsViewport && abs(sourceClearance - targetClearance) > 1
                && abs(outgoing.frame.height - incoming.frame.height) > 1)
    }

    private func pageCanvasColor(_ appearance: HeaderAppearance) -> UIColor {
        guard appearance.canvasRole == .ordinary else { return .black }
        let style: UIUserInterfaceStyle = appearance.colorScheme == .dark ? .dark : .light
        return UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func warmLayoutSignature(_ flight: RootFlight, targetProbe: NativeHeaderProbe,
                                     incoming: HeaderContent, outgoing: HeaderContent) -> WarmLayoutSignature? {
        guard let host = rootHost, let window = flight.window, let source = flight.sourceOwner,
              let target = PageViewportGeometry.owner(of: targetProbe),
              let sourceProbe = probe(for: flight.source, includingHidden: true),
              PageViewportGeometry.owner(of: sourceProbe) === source,
              let sourceToken = host.token(for: flight.source), let targetToken = host.token(for: flight.destination),
              sourceToken == flight.sourceToken, targetToken == flight.targetToken,
              targetProbe.rootToken == targetToken, sourceProbe.rootToken == sourceToken,
              host.feedIdentity == flight.scopeIdentity, host.owns(target, tab: flight.destination),
              let sourceView = source.viewIfLoaded, let targetView = target.viewIfLoaded,
              sourceView.window === window, targetView.window === window,
              source.navigationController?.topViewController === source,
              target.navigationController?.topViewController === target,
              targetProbe.anchor.window === window, sourceProbe.anchor.window === window,
              abs(incoming.frame.width - outgoing.frame.width) <= 2 else { return nil }
        return WarmLayoutSignature(scope: flight.scopeIdentity, sourceToken: sourceToken, targetToken: targetToken,
            sourceOwner: ObjectIdentifier(source), targetOwner: ObjectIdentifier(target), window: ObjectIdentifier(window),
            scene: window.windowScene.map(ObjectIdentifier.init), windowBounds: window.bounds, windowInsets: window.safeAreaInsets,
            sourceBounds: sourceView.bounds, targetBounds: targetView.bounds,
            sourceInsets: sourceView.safeAreaInsets, targetInsets: targetView.safeAreaInsets,
            sourceAnchorFrame: sourceProbe.anchor.convert(sourceProbe.anchor.bounds, to: window),
            targetAnchorFrame: targetProbe.anchor.convert(targetProbe.anchor.bounds, to: window),
            sourceHeader: HeaderLayoutStamp(outgoing), targetHeader: HeaderLayoutStamp(incoming),
            contentSize: window.traitCollection.preferredContentSizeCategory, scale: window.traitCollection.displayScale,
            direction: window.effectiveUserInterfaceLayoutDirection,
            orientation: window.windowScene?.interfaceOrientation ?? .unknown)
    }

    private func prepareRootTarget(_ flight: RootFlight) {
        flight.boundary = RenderFrameBoundary { [weak self, weak flight] in
        #if DEBUG && targetEnvironment(simulator)
        let cost174 = TransitionCostQA174.start
        defer { TransitionCostQA174.record("targetPrepare", cost174) }
        #endif
            guard let self, let flight, self.rootFlight === flight else { return }
            flight.boundary = nil
            guard self.rootFlightIsValid(flight), self.bodyHandoff.isPrepared(flight.receipt.id) else {
                self.cancel(reason: "source-scope-invalid-before-target-frame"); return
            }
            guard self.probe(for: flight.source, includingHidden: true)?.rendersLiveControls == false else {
                self.retryPreparingRootTarget(flight); return
            }
            if !flight.fixedControlsReady {
                guard let header = self.handoff else {
                    self.cancel(reason: "source-header-owner-lost"); return
                }
                self.bodyHandoff.installFixedHeader(token: flight.receipt.id, handoff: header)
                guard self.bodyHandoff.isPrepared(flight.receipt.id) else {
                    self.cancel(reason: "fixed-header-overlay-unavailable"); return
                }
                flight.fixedControlsReady = true
            }
            guard self.probe(for: flight.destination, includingHidden: true)?.rendersLiveControls == false else {
                self.retryPreparingRootTarget(flight); return
            }
            if let target = self.probe(for: flight.destination, includingHidden: true).flatMap(PageViewportGeometry.owner),
               self.rootHost?.owns(target, tab: flight.destination) == true,
               let incoming = self.header(for: flight.destination), let outgoing = self.handoff?.source {
                if let expected = flight.warmLayout {
                    let actual = self.probe(for: flight.destination, includingHidden: true).flatMap {
                        self.warmLayoutSignature(flight, targetProbe: $0, incoming: incoming, outgoing: outgoing)
                    }
                    flight.warmLayout = nil
                    if actual != expected {
                        flight.contentPlan = nil; self.contentLayout = nil
                        #if DEBUG && targetEnvironment(simulator)
                        TransitionCostQA174.record("warmLayoutRejected175", cost174)
                        #endif
                        self.prepareRootTarget(flight)
                        return
                    }
                    #if DEBUG && targetEnvironment(simulator)
                    TransitionCostQA174.record("warmLayoutHit175", cost174)
                    #endif
                }
                if flight.contentPlan == nil {
                    let plan = self.contentPlan(destination: flight.destination, incoming: incoming, outgoing: outgoing)
                    flight.contentPlan = plan
                    // A page without a clearance owner (the timeline) uses its
                    // own final viewport. No view can consume this publication,
                    // so validate that viewport below without an unused frame
                    // boundary. Pages with a recipient still render the plan.
                    if plan.targetContentOwner != nil {
                        self.contentLayout = ContentLayout(plan: plan, resizing: true)
                        self.prepareRootTarget(flight)
                        return
                    }
                }
                if let plan = flight.contentPlan, plan.resizesContent {
                    guard let geometry = PageBodyViewports.geometry(containing: target),
                          let view = geometry.owner.viewIfLoaded,
                          abs(geometry.rect.minY - (view.bounds.minY + view.safeAreaInsets.top + plan.targetClearance)) <= 2 else {
                        self.retryPreparingRootTarget(flight)
                        return
                    }
                }
                flight.targetToken = self.rootHost?.token(for: flight.destination)
                flight.targetOwner = target
                guard let targetToken = flight.targetToken,
                      self.bodyHandoff.stageRootTarget(flight.receipt.id, destination: target),
                      let header = self.handoff, header.stageRoot(incoming) else {
                    self.retryPreparingRootTarget(flight)
                    return
                }
                self.bodyHandoff.installFixedHeader(token: flight.receipt.id, handoff: header)
                guard let host = self.rootHost,
                      let source = flight.sourceOwner,
                      let sourceToken = flight.sourceToken,
                      host.beginVisualPair(id: flight.receipt.id, source: flight.source,
                          destination: flight.destination, sourceToken: sourceToken, targetToken: targetToken,
                          scopeIdentity: flight.scopeIdentity, sourceOwner: source, targetOwner: target,
                          sourceColor: self.pageCanvasColor(outgoing.appearance),
                          targetColor: self.pageCanvasColor(incoming.appearance), sign: flight.sign) else {
                    self.retryPreparingRootTarget(flight)
                    return
                }
                flight.visualPairStarted = true
                flight.ready = true
                #if DEBUG && targetEnvironment(simulator)
                TransitionCostQA174.record("rootReady175", flight.readyStart175)
                #endif
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
        if flight.visualPairStarted, !host.hasVisualPair(id: flight.receipt.id) { return false }
        return true
    }

    func updateRootSwitch(translation: CGFloat) {
        guard let flight = rootFlight, !flight.settling, !flight.rebounding else { return }
        flight.translation = translation
        guard flight.ready, flight.visualPairStarted,
              let host = rootHost else { return }
        let progress = min(1, max(0, translation * flight.sign / max(1, host.view.bounds.width)))
        guard host.setVisualPairProgress(id: flight.receipt.id, progress: progress) else {
            cancel(reason: "root-visual-pair-lost-during-update")
            return
        }
        flight.progress = progress
        bodyHandoff.updateRootChrome(flight.receipt.id, progress: Double(progress))
    }
    var interactiveRootDragID: UUID? {
        guard let flight = rootFlight, flight.interactive, flight.pendingDecision == nil,
              !flight.settling, !flight.rebounding else { return nil }
        return flight.receipt.id
    }

    func recoverLostRootDrag(id: UUID) {
        guard interactiveRootDragID == id else { return }
        NavigationDiagnostics.mark(.touchTrackingRecovered, owner: .bodyHandoff)
        cancelImmediately(reason: "root-touch-ended-without-terminal")
    }

    func endRootSwitch(velocity: CGFloat, cancelled: Bool) {
        guard let flight = rootFlight, !flight.settling, !flight.rebounding else { return }
        let width = rootHost?.viewIfLoaded?.bounds.width ?? flight.sourceOwner?.viewIfLoaded?.bounds.width ?? 1
        let distance = max(0, flight.translation * flight.sign)
        let accepted = !cancelled && (distance > width * 0.28 || (distance > 14 && velocity * flight.sign > 650))
        flight.pendingDecision = accepted
        if !accepted && !flight.visualPairStarted {
            // Do not replay a positive drag when its preparation finishes
            // after the finger already rejected it. Source ACK and input
            // release still use the ordinary rebound terminal path.
            finishRootRebound(flight, reason: "cancelled")
            return
        }
        if flight.ready { settleRoot(flight, accepted: accepted) }
    }

    private func settleRoot(_ flight: RootFlight, accepted: Bool) {
        guard rootFlight === flight, !flight.settling else { return }
        guard rootFlightIsValid(flight) else { cancel(reason: "source-scope-changed-before-settle"); return }
        guard flight.ready, flight.visualPairStarted else {
            flight.pendingDecision = accepted
            return
        }
        flight.settling = true
        flight.settleAnimator?.cancel(); flight.settleAnimator = nil
        let start = flight.progress
        let end = accepted ? 1.0 : 0.0
        let distance = abs(end - start)
        let duration = (UIAccessibility.isReduceMotionEnabled ? 0.12 : PageToneTransition.duration) * distance
        guard distance > 0.0001 else {
            applyRootSettle(flight, progress: end)
            finishRootSettle(flight, accepted: accepted)
            return
        }
        flight.settleAnimator = RenderProgressAnimation(duration: duration) { [weak self, weak flight] elapsed in
            guard let self, let flight, self.rootFlight === flight else { return }
            guard self.rootFlightIsValid(flight) else {
                self.cancel(reason: "root-visual-pair-invalid-during-settle")
                return
            }
            let progress = start + (end - start) * UnitCurve.easeInOut.value(at: min(1, max(0, elapsed / max(duration, 0.001))))
            self.applyRootSettle(flight, progress: progress)
        } completion: { [weak self, weak flight] in
            guard let self, let flight, self.rootFlight === flight else { return }
            flight.settleAnimator = nil
            guard self.rootFlightIsValid(flight) else { self.cancel(reason: "root-scope-changed-at-settle-end"); return }
            self.applyRootSettle(flight, progress: end)
            self.finishRootSettle(flight, accepted: accepted)
        }
    }

    private func applyRootSettle(_ flight: RootFlight, progress: Double) {
        guard let host = rootHost,
              host.setVisualPairProgress(id: flight.receipt.id, progress: progress) else {
            cancel(reason: "root-visual-pair-missing-at-endpoint")
            return
        }
        flight.progress = progress
        bodyHandoff.updateRootChrome(flight.receipt.id, progress: progress)
    }

    private func finishRootSettle(_ flight: RootFlight, accepted: Bool) {
        guard rootFlight === flight else { return }
        guard accepted else {
            finishRootRebound(flight, reason: "cancelled")
            return
        }
        guard rootFlightIsValid(flight), let target = flight.targetOwner,
              let host = rootHost, host.owns(target, tab: flight.destination),
              host.token(for: flight.destination) == flight.targetToken,
              bodyHandoff.isPrepared(flight.receipt.id) else {
            cancel(reason: "root-target-invalid-after-settle")
            return
        }
        // Selection makes the destination logically active before live chrome
        // has acknowledged its frame. Hold only that terminal interval; source
        // playback remains untouched throughout preparation and dragging.
        guard let activation = PageBodyViewports.suspendActivation(in: target, token: flight.receipt.id) else {
            cancel(reason: "root-target-activation-owner-missing")
            return
        }
        bodyHandoff.attachActivationLease(activation)
        flight.receipt.recordNavigation(.committed, token: flight.receipt.id)
        withoutPageAnimation {
            flight.destinationCommitted = true
            if let token = flight.targetToken, let window = flight.window, let expected = handoff?.destination {
                acceptedCanvas = AcceptedCanvas(flightID: flight.receipt.id, tab: flight.destination,
                    token: token, owner: ObjectIdentifier(target), window: ObjectIdentifier(window),
                    scope: flight.scopeIdentity, role: expected.appearance.canvasRole)
            }
            flight.commit(flight.destination)
        }
        self.pending = Task { [weak self, weak flight, weak target] in
            guard let self, let flight, self.rootFlight === flight else { return }
            guard let target else { self.cancel(reason: "root-target-removed-after-commit"); return }
            #if DEBUG && targetEnvironment(simulator)
            if flight.destination == 0, ProcessInfo.processInfo.arguments.contains("--qa-root-activation181") {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.rootFlight === flight, self.rootCommittedTargetIsCurrent(flight, target: target) else {
                    if self.rootFlight === flight { self.cancel(reason: "root-activation-qa-target-changed") }
                    return
                }
            }
            #endif
            guard let expected = self.handoff?.destination else { self.cancel(reason: "target-header-missing-after-commit"); return }
            self.bodyHandoff.releaseRootInteractive(flight.receipt.id, destination: target,
                isCurrent: { [weak self, weak flight, weak target] in
                    guard let self, let flight, let target else { return false }
                    return self.rootCommittedTargetIsCurrent(flight, target: target)
                }, reveal: { [weak self, weak flight, weak target] in
                    guard let self, let flight, let target else { return false }
                    return self.beginRootHeaderReveal(flight, target: target, expected: expected)
                }, acknowledge: { [weak self, weak flight] probe in
                    guard let self, let flight, let token = flight.targetToken,
                          let host = self.rootHost,
                          host.finishVisualPair(id: flight.receipt.id, confirmedSelected: flight.destination) else { return false }
                    return self.installCanvasRoleDeclaration(probe, tab: flight.destination,
                                                             token: token, role: expected.appearance.canvasRole,
                                                             matching: expected)
                }) { [weak self, weak flight] outcome in
                guard let self, let flight, self.rootFlight === flight else { return }
                if flight.visualPairStarted, let host = self.rootHost {
                    _ = host.finishVisualPair(id: flight.receipt.id, confirmedSelected: host.selected)
                }
                flight.visualPairStarted = false
                flight.receipt.recordVisual(outcome, token: flight.receipt.id)
                self.liveRootHeaderReveal = nil
                self.rootFlight = nil
                withoutPageAnimation { self.preparation = nil; self.handoff = nil }
                self.tone = nil
                DispatchQueue.main.async { [weak self] in self?.replayQueuedRootIntentIfCurrent() }
            }
        }
    }

    private func finishRootRebound(_ flight: RootFlight, reason: String) {
        guard rootFlight === flight, !flight.destinationCommitted, !flight.rebounding,
              let source = flight.sourceOwner, let expected = handoff?.source,
              rootSourceIsCurrent(flight, source: source) else {
            cancelImmediately(reason: reason)
            return
        }
        flight.rebounding = true
        flight.boundary?.cancel(); flight.boundary = nil
        flight.settleAnimator?.cancel(); flight.settleAnimator = nil
        pending?.cancel(); pending = nil
        if flight.visualPairStarted,
           rootHost?.setVisualPairProgress(id: flight.receipt.id, progress: 0) != true {
            cancelImmediately(reason: "root-rebound-pair-lost")
            return
        }
        flight.progress = 0
        guard bodyHandoff.prepareRootRebound(flight.receipt.id, source: source, header: expected) else {
            cancelImmediately(reason: "root-rebound-controls-lost")
            return
        }
        let navigation: PageNavigationOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
        flight.receipt.recordNavigation(navigation, token: flight.receipt.id)
        bodyHandoff.releaseRootInteractive(flight.receipt.id, destination: source,
            isCurrent: { [weak self, weak flight, weak source] in
                guard let self, let flight, let source else { return false }
                return self.rootSourceIsCurrent(flight, source: source)
            }, reveal: { [weak self, weak flight, weak source] in
                guard let self, let flight, let source else { return false }
                return self.beginRootHeaderReveal(flight, target: source, expected: expected, tab: flight.source)
            }, acknowledge: { [weak self, weak flight] probe in
                guard let self, let flight, let host = self.rootHost, let token = flight.sourceToken else { return false }
                if flight.visualPairStarted,
                   !host.finishVisualPair(id: flight.receipt.id, confirmedSelected: flight.source) { return false }
                return self.installCanvasRoleDeclaration(probe, tab: flight.source, token: token,
                    role: expected.appearance.canvasRole, matching: expected)
            }) { [weak self, weak flight] outcome in
                guard let self, let flight, self.rootFlight === flight else { return }
                if flight.visualPairStarted, let host = self.rootHost {
                    _ = host.finishVisualPair(id: flight.receipt.id, confirmedSelected: host.selected)
                }
                flight.visualPairStarted = false
                let result: PageVisualOutcome
                if case .completed = outcome { result = reason == "cancelled" ? .cancelled : .aborted(reason) }
                else { result = outcome }
                flight.receipt.recordVisual(result, token: flight.receipt.id)
                self.liveRootHeaderReveal = nil
                self.rootFlight = nil
                withoutPageAnimation { self.preparation = nil; self.handoff = nil }
                self.tone = nil
                DispatchQueue.main.async { [weak self] in self?.replayQueuedRootIntentIfCurrent() }
            }
    }

    private func rootSourceIsCurrent(_ flight: RootFlight, source: UIViewController) -> Bool {
        guard rootFlight === flight, !flight.destinationCommitted,
              let host = rootHost, let window = flight.window,
              host.selected == flight.source, host.token(for: flight.source) == flight.sourceToken,
              host.feedIdentity == flight.scopeIdentity, host.viewIfLoaded?.window === window,
              window.windowScene === flight.scene, window.windowScene?.activationState == .foregroundActive,
              source === flight.sourceOwner, host.owns(source, tab: flight.source),
              source.navigationController?.topViewController === source,
              source.viewIfLoaded?.window === window else { return false }
        return !flight.visualPairStarted || host.hasVisualPair(id: flight.receipt.id)
    }

    private func rootCommittedTargetIsCurrent(_ flight: RootFlight, target: UIViewController) -> Bool {
        guard rootFlight === flight, flight.destinationCommitted,
              let host = rootHost, let window = flight.window,
              let targetToken = flight.targetToken,
              host.selected == flight.destination, host.token(for: flight.destination) == targetToken,
              host.feedIdentity == flight.scopeIdentity,
              host.viewIfLoaded?.window === window, window.windowScene === flight.scene,
              window.windowScene?.activationState == .foregroundActive,
              flight.targetOwner === target, host.owns(target, tab: flight.destination),
              flight.visualPairStarted, host.hasVisualPair(id: flight.receipt.id),
              target.navigationController?.topViewController === target,
              target.viewIfLoaded?.window === window else { return false }
        return true
    }

    private func beginRootHeaderReveal(_ flight: RootFlight, target: UIViewController,
                                       expected: HeaderContent, tab: Int? = nil) -> Bool {
        let targetTab = tab ?? flight.destination
        let endpointCurrent = targetTab == flight.source && !flight.destinationCommitted
            ? rootSourceIsCurrent(flight, source: target) : rootCommittedTargetIsCurrent(flight, target: target)
        let endpointToken = targetTab == flight.source ? flight.sourceToken : flight.targetToken
        guard endpointCurrent,
              let host = rootHost, let window = flight.window,
              let targetToken = endpointToken,
              let targetProbe = probe(for: targetTab, includingHidden: true),
              let owner = PageViewportGeometry.owner(of: targetProbe),
              owner === target, host.owns(owner, tab: targetTab),
              let destination = handoff?.destination,
              abs(destination.frame.minX - expected.frame.minX) <= 2,
              abs(destination.frame.minY - expected.frame.minY) <= 2,
              abs(destination.frame.width - expected.frame.width) <= 2,
              abs(destination.frame.height - expected.frame.height) <= 1,
              destination.appearance.contentOwner == expected.appearance.contentOwner,
              destination.appearance.layoutIdentity == expected.appearance.layoutIdentity,
              destination.appearance.colorScheme == expected.appearance.colorScheme,
              CanvasRoleDeclaration.sameRole(destination.appearance.canvasRole, expected.appearance.canvasRole),
              bodyHandoff.bindRootHeaderVisibility(flight.receipt.id, probe: targetProbe, owner: owner,
                rootToken: targetToken, isCurrent: { [weak self, weak flight, weak target] in
                    guard let self, let flight, let target else { return false }
                    return targetTab == flight.source && !flight.destinationCommitted
                        ? self.rootSourceIsCurrent(flight, source: target) : self.rootCommittedTargetIsCurrent(flight, target: target)
                }) else { return false }
        liveRootHeaderReveal = RootHeaderReveal(flightID: flight.receipt.id, tab: targetTab,
            targetToken: targetToken, owner: ObjectIdentifier(owner), window: ObjectIdentifier(window),
            contentOwner: expected.appearance.contentOwner,
            layoutIdentity: expected.appearance.layoutIdentity, canvasRole: expected.appearance.canvasRole,
            colorScheme: expected.appearance.colorScheme)
        return true
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
            .contains { PageBodyHandoff.hasActiveFlight(in: $0) }
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
        if let flight = rootFlight, !flight.rebounding, !flight.destinationCommitted,
           let source = flight.sourceOwner, rootSourceIsCurrent(flight, source: source),
           bodyHandoff.isPrepared(flight.receipt.id) {
            finishRootRebound(flight, reason: reason)
            return
        }
        cancelImmediately(reason: reason)
    }

    private func cancelImmediately(reason: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // An immediate invalidation has no trusted source from which to
        // replay a queued tap. Rebound/normal terminal paths preserve the
        // queue and call replayQueuedRootIntentIfCurrent after cleanup.
        queuedRootIntent = nil
        if let request = pendingRootSwitch { finishPendingRootSwitch(request, reason: reason) }
        if let flight = rootFlight {
            publishBegin(.invalid(reason), source: flight.source, destination: flight.destination,
                         requestID: flight.receipt.id, attempt: flight.preparationFrames)
            rootFlight = nil
            flight.boundary?.cancel()
            flight.settleAnimator?.cancel(); flight.settleAnimator = nil
            if flight.visualPairStarted, let host = rootHost {
                _ = host.finishVisualPair(id: flight.receipt.id, confirmedSelected: host.selected)
            }
            flight.visualPairStarted = false
            let navigation: PageNavigationOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
            let visual: PageVisualOutcome = reason == "cancelled" ? .cancelled : .aborted(reason)
            flight.receipt.recordNavigation(navigation, token: flight.receipt.id)
            flight.receipt.recordVisual(visual, token: flight.receipt.id)
        }
        liveRootHeaderReveal = nil
        preparation = nil
        pending?.cancel()
        pending = nil
        if let host = rootHost, let window = host.viewIfLoaded?.window,
           window.windowScene?.activationState == .foregroundActive,
           let selectedProbe = probe(for: host.selected, includingHidden: true),
           selectedProbe.rootToken == host.token(for: host.selected),
           let owner = PageViewportGeometry.owner(of: selectedProbe),
           host.owns(owner, tab: host.selected), owner.navigationController?.topViewController === owner {
            selectedProbe.updateControlsVisibility(true)
        }
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
    var verticalInset: CGFloat = 0
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
    var appearance: HeaderAppearance?

    var visibleFrame: CGRect? {
        guard let window else { return nil }
        let measuredBounds = bounds.insetBy(dx: 0, dy: max(0, verticalInset))
        guard !measuredBounds.isEmpty else { return nil }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return nil }
            view = current.superview
        }
        let frame = convert(measuredBounds, to: window)
        return window.bounds.insetBy(dx: -24, dy: 0).contains(frame) ? frame : nil
    }
}

private struct WeakHeaderProbe {
    weak var probe: NativeHeaderProbe?
}

private struct HeaderProbe: UIViewControllerRepresentable {
    let controls: AnyView
    let motion: TabPageMotion?
    let tab: Int?
    let appearance: HeaderAppearance
    let nativeMotionEnabled: Bool
    let showsChrome: Bool
    let liveControlsVisible: Bool
    let verticalInset: CGFloat
    @Environment(\.nativeHeaderRouteID) private var routeID
    @EnvironmentObject private var session: SiteSession
    @Environment(\.rootPageParticipation) private var participation
    let onHandoffChange: (HeaderHandoff?) -> Void

    func makeUIViewController(context: Context) -> NativeHeaderProbe { NativeHeaderProbe() }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: NativeHeaderProbe, context: Context) -> CGSize? {
        uiViewController.controlsSizeThatFits(proposal)
    }

    static func dismantleUIViewController(_ controller: NativeHeaderProbe, coordinator: ()) {
        controller.invalidateControlsReadiness()
    }

    func updateUIViewController(_ controller: NativeHeaderProbe, context: Context) {
        controller.nativeMotionEnabled = nativeMotionEnabled && participation.isActive
        controller.rootToken = participation.token
        controller.showsChrome = showsChrome
        controller.updateAppearance(appearance)
        controller.updateControlsContent(AnyView(controls
            .pageControlHostingEnvironment(from: context.environment, session: session)
            .pageHeaderHostingEnvironment(from: context.environment)), verticalInset: verticalInset)
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
    @Environment(\.rootPageParticipation) private var participation

    func body(content: Content) -> some View {
        let tabHandoff = enabled && participatesInTabs && motion?.handoff != nil
        let rootReveal = tabHandoff && motion?.revealsLiveRootHeader(tab: tab ?? -1,
            token: participation.token, appearance: appearance) == true
        let controlsHidden = tabHandoff && !rootReveal
        HeaderProbe(controls: AnyView(content), motion: enabled && participatesInTabs ? motion : nil, tab: tab, appearance: appearance,
                    nativeMotionEnabled: !reduceMotion && motion?.handoff == nil, showsChrome: enabled,
                    liveControlsVisible: !controlsHidden, verticalInset: verticalInset,
                    onHandoffChange: {
                        nativeHandoff = $0
                        onNativeHandoff($0)
                    })
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
