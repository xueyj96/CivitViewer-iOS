import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var pageCoverScope: UUID? = nil
}

/// Effects owned by a closing cover run after its root handoff, not between
/// platform dismissals while that handoff still owns fixed window geometry.
@MainActor enum PageCoverExitEffects {
    static func deferUntilFinished(scope: UUID, action: @escaping () -> Void) -> Bool {
        MountedPageCovers.shared.deferExitEffect(scope, action: action)
    }
}

/// Only a mounted platform cover may register here. A business onEnd can run
/// before UIKit removes that cover, so it is deliberately not a dismissal receipt.
@MainActor private final class MountedPageCovers {
    static let shared = MountedPageCovers()
    @MainActor final class Entry {
        let id: UUID
        let parent: UUID?
        let identity: SiteSession.AccountSessionID?
        weak var scope: UIViewController?
        weak var window: UIWindow?
        let permit: PageVisualActivationPermit
        let close: (UUID) -> Bool
        var externalExit: UUID?
        var dismissed: (() -> Void)?
        init(id: UUID, parent: UUID?, identity: SiteSession.AccountSessionID?, scope: UIViewController, window: UIWindow,
             permit: PageVisualActivationPermit, close: @escaping (UUID) -> Bool) {
            self.id = id; self.parent = parent; self.identity = identity
            self.scope = scope; self.window = window; self.permit = permit; self.close = close
        }
    }
    private var entries: [UUID: Entry] = [:]
    private struct ActiveExit { let id: UUID; weak var window: UIWindow? }
    private var activeExits: [ObjectIdentifier: ActiveExit] = [:]
    private var deferred: [ObjectIdentifier: (exit: UUID, action: () -> Void)] = [:]
    private var deferredEffects: [UUID: [(scope: UUID, action: () -> Void)]] = [:]

    func mount(_ id: UUID, parent: UUID?, identity: SiteSession.AccountSessionID?, owner: UIViewController?,
               permit: PageVisualActivationPermit, close: @escaping (UUID) -> Bool) {
        guard let owner, let window = owner.viewIfLoaded?.window else { return }
        var scope = owner
        while let parent = scope.parent { scope = parent }
        guard scope.viewIfLoaded?.window === window, scope.presentingViewController != nil else { return }
        entries = entries.filter { $0.value.scope != nil && $0.value.window != nil }
        guard entries[id] == nil else { return }
        entries[id] = Entry(id: id, parent: parent, identity: identity, scope: scope,
                            window: window, permit: permit, close: close)
    }

    func chain(from id: UUID, identity: SiteSession.AccountSessionID?, root: RootTabHostController, selected: Int) -> [Entry]? {
        guard root.selected == selected else { return nil }
        var chain: [Entry] = [], visited = Set<UUID>(), next: UUID? = id
        var expectedWindow: UIWindow?
        while let current = next {
            guard visited.insert(current).inserted, let entry = entries[current],
                  entry.identity == identity, entry.externalExit == nil,
                  let scope = entry.scope, let window = entry.window,
                  (!chain.isEmpty || scope.viewIfLoaded?.window === window),
                  expectedWindow == nil || expectedWindow === window else { return nil }
            expectedWindow = window
            chain.append(entry); next = entry.parent
        }
        guard let last = chain.last, let presenter = last.scope?.presentingViewController,
              let rootView = root.viewIfLoaded, let presenterView = presenter.viewIfLoaded,
              rootView === presenterView || rootView.isDescendant(of: presenterView)
                || root.owns(presenter, tab: selected) else { return nil }
        for (child, parent) in zip(chain, chain.dropFirst()) {
            guard let scope = child.scope, let parentScope = parent.scope,
                  let presenter = scope.presentingViewController,
                  contains(presenter, in: parentScope) else { return nil }
        }
        return chain
    }

    private func contains(_ child: UIViewController, in scope: UIViewController) -> Bool {
        var current: UIViewController? = child
        while let owner = current {
            if owner === scope { return true }
            current = owner.parent
        }
        return false
    }

    private func hasPresentedChild(_ scope: UIViewController) -> Bool {
        scope.presentedViewController != nil || scope.children.contains { hasPresentedChild($0) }
    }

    func beginExit(_ id: UUID, window: UIWindow) {
        activeExits[ObjectIdentifier(window)] = ActiveExit(id: id, window: window)
    }

    func deferReconcile(_ cleanup: PagePresentationCleanup, parent: UUID?, owner: UIViewController?, action: @escaping () -> Void) -> Bool {
        let window = owner?.viewIfLoaded?.window ?? parent.flatMap { entries[$0]?.window }
            ?? cleanup.callbackReceipt.flatMap { entries[$0.id]?.window }
        guard let window, let exit = activeExits[ObjectIdentifier(window)], exit.window === window else { return false }
        deferred[ObjectIdentifier(cleanup)] = (exit.id, action)
        return true
    }

    func requestClose(_ id: UUID, exit: UUID, dismissed: @escaping () -> Void) -> Bool {
        guard let entry = entries[id], entry.externalExit == nil, let scope = entry.scope,
              let window = entry.window, scope.viewIfLoaded?.window === window,
              !hasPresentedChild(scope), !scope.isBeingDismissed, !scope.isBeingPresented,
              scope.transitionCoordinator == nil else { return false }
        entry.externalExit = exit; entry.dismissed = dismissed
        guard entry.close(exit) else {
            entry.externalExit = nil; entry.dismissed = nil
            return false
        }
        return true
    }

    func isExternallyClosing(_ id: UUID) -> Bool { entries[id]?.externalExit != nil }

    func deferExitEffect(_ id: UUID, action: @escaping () -> Void) -> Bool {
        guard let entry = entries[id], let window = entry.window,
              let exit = activeExits[ObjectIdentifier(window)], exit.window === window,
              entry.externalExit == exit.id else { return false }
        if let index = deferredEffects[exit.id]?.firstIndex(where: { $0.scope == id }) {
            deferredEffects[exit.id]?[index].action = action
        } else {
            // Dismissals arrive from the innermost cover to the outermost.
            // Preserve that order so the outer playback orientation wins.
            deferredEffects[exit.id, default: []].append((id, action))
        }
        return true
    }

    func platformDismissed(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        let callback = entry.dismissed; entry.dismissed = nil
        callback?()
    }

    func abandon(_ exit: UUID) {
        // Keep the policy until the actual receipt arrives, even if the visual
        // watchdog has released its plane. Do not start an intermediate return.
        for entry in entries.values where entry.externalExit == exit { entry.dismissed = nil }
        activeExits = activeExits.filter { $0.value.id != exit && $0.value.window != nil }
        let pending = deferred.filter { $0.value.exit == exit }.map { $0.value.action }
        deferred = deferred.filter { $0.value.exit != exit }
        let effects = deferredEffects.removeValue(forKey: exit) ?? []
        if !pending.isEmpty || !effects.isEmpty {
            DispatchQueue.main.async {
                effects.forEach { $0.action() }
                pending.forEach { $0() }
            }
        }
    }
}

/// A covered footer selects a root only after each mounted cover has actually
/// dismissed. The one source plane stays above UIKit's nonanimated teardown;
/// PageBodyHandoff then slides the real root under it and owns terminal reveal.
@MainActor final class CoveredRootTransition {
    @MainActor private final class Flight {
        let id: UUID
        let identity: String
        let target: Int
        let selected: Int
        let direction: CGFloat
        let chain: [UUID]
        let sourceSlot: UUID?
        var targetSlot: UUID?
        weak var host: RootTabHostController?
        weak var window: UIWindow?
        weak var scene: UIWindowScene?
        let bounds: CGRect
        let isCurrent: () -> Bool
        let commit: () -> Void
        let fallback: () -> Void
        let reduceMotion: Bool
        var remaining: ArraySlice<UUID>
        var permits: [PageVisualActivationLease]
        var boundary: RenderFrameBoundary?
        var watchdog: DispatchWorkItem?
        var targetWaitFrames = 0
        #if DEBUG && targetEnvironment(simulator)
        var qaHoldTask: Task<Void, Never>?
        #endif
        init(identity: String, target: Int, selected: Int, chain: [MountedPageCovers.Entry],
             host: RootTabHostController, window: UIWindow, isCurrent: @escaping () -> Bool,
             commit: @escaping () -> Void, fallback: @escaping () -> Void, reduceMotion: Bool,
             rootPermit: PageVisualActivationPermit) {
            let token = UUID()
            id = token
            self.identity = identity; self.target = target; self.selected = selected
            let order = RootTab.order
            direction = (order.firstIndex(of: target) ?? 0) >= (order.firstIndex(of: selected) ?? 0) ? -1 : 1
            let chainIDs = chain.map(\.id)
            self.chain = chainIDs; remaining = ArraySlice(chainIDs)
            self.host = host; self.window = window; scene = window.windowScene; bounds = window.bounds
            sourceSlot = host.token(for: selected); targetSlot = host.token(for: target)
            self.isCurrent = isCurrent; self.commit = commit; self.fallback = fallback
            self.reduceMotion = reduceMotion
            permits = chain.map { $0.permit.block(token) }
            permits.append(rootPermit.block(token))
        }
    }
    private var flight: Flight?
    private let body = PageBodyHandoff()
    var isActive: Bool { flight != nil }

    @discardableResult
    func select(_ target: Int, scope: UUID, host: RootTabHostController?, identity: String,
                account: SiteSession.AccountSessionID?, reduceMotion: Bool,
                selected: Int, ordinaryScheme: ColorScheme, rootPermit: PageVisualActivationPermit,
                isCurrent: @escaping () -> Bool, commit: @escaping () -> Void,
                fallback: @escaping () -> Void) -> Bool {
        guard flight == nil, let host, let chain = MountedPageCovers.shared.chain(from: scope, identity: account, root: host, selected: selected),
              let first = chain.first, let window = first.window, let sourceScope = first.scope,
              let source = PageBodyViewports.geometry(containing: sourceScope)?.owner,
              window.windowScene?.activationState == .foregroundActive,
              !PageBodyHandoff.hasActiveFlight(in: window),
              !PageInteractionShield.isActive(in: window), host.feedIdentity == identity,
              RootTab(rawValue: target) != nil, isCurrent() else { return false }
        let current = Flight(identity: identity, target: target, selected: selected, chain: chain,
                             host: host, window: window, isCurrent: isCurrent,
                             commit: commit, fallback: fallback, reduceMotion: reduceMotion, rootPermit: rootPermit)
        flight = current
        MountedPageCovers.shared.beginExit(current.id, window: window)
        let timeout = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, self.flight === current else { return }
            self.cancel(reason: "cover-root-platform-timeout")
        }
        current.watchdog = timeout
        #if DEBUG && targetEnvironment(simulator)
        let timeoutSeconds = ProcessInfo.processInfo.arguments.contains("--qa-cover-root-hold181") ? 6.0 : 3.0
        #else
        let timeoutSeconds = 3.0
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        let header = NativeHeaderMotion.forWindow(window).settledContent(for: source)
        let overMedia = header?.appearance.canvasRole == .playback
        body.prepare(current.id, source: source, kind: "cover-tab", enabled: true,
                     sourceScheme: header?.appearance.colorScheme ?? ordinaryScheme, sourceIsMedia: overMedia,
                     identity: AnyHashable(identity)) { [weak self, weak current] captured in
            guard let self, let current, self.flight === current else { return }
            guard self.valid(current) else { self.cancel(reason: "cover-root-source-changed"); return }
            guard captured, self.body.isPrepared(current.id) else {
                self.cancel(reason: "cover-root-capture-unavailable")
                // No platform action has happened yet. Execute the original
                // business intent once; a later failure never closes more pages.
                if current.isCurrent(), current.scene?.activationState == .foregroundActive { current.fallback() }
                return
            }
            self.body.attachActivationLease(current.permits.last)
            self.closeNext(current)
        }
        return true
    }

    private func valid(_ current: Flight) -> Bool {
        guard flight === current, current.isCurrent(), let host = current.host,
              host.feedIdentity == current.identity, host.token(for: current.selected) == current.sourceSlot,
              let window = current.window, window.windowScene === current.scene,
              current.scene?.activationState == .foregroundActive, window.bounds == current.bounds else { return false }
        return true
    }

    private func closeNext(_ current: Flight) {
        guard flight === current else { return }
        guard valid(current), body.isPrepared(current.id) else { cancel(reason: "cover-root-chain-changed"); return }
        guard let next = current.remaining.first else {
            withoutPageAnimation { current.commit() }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-cover-root-hold181") {
                current.qaHoldTask = Task { @MainActor [weak self, weak current] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, let current, self.flight === current else { return }
                    current.qaHoldTask = nil
                    self.waitForTarget(current)
                }
                return
            }
            #endif
            waitForTarget(current)
            return
        }
        guard MountedPageCovers.shared.requestClose(next, exit: current.id, dismissed: { [weak self, weak current] in
            guard let self, let current, self.flight === current, current.remaining.first == next else { return }
            current.remaining = current.remaining.dropFirst()
            current.boundary = RenderFrameBoundary { [weak self, weak current] in
                guard let self, let current, self.flight === current else { return }
                current.boundary = nil
                self.closeNext(current)
            }
        }) else { cancel(reason: "cover-root-dismissal-rejected"); return }
    }

    private func waitForTarget(_ current: Flight) {
        guard flight === current else { return }
        guard valid(current) else { cancel(reason: "cover-root-target-changed"); return }
        current.boundary = RenderFrameBoundary { [weak self, weak current] in
            guard let self, let current, self.flight === current else { return }
            guard self.valid(current), let host = current.host, let window = current.window else {
                self.cancel(reason: "cover-root-target-unavailable"); return
            }
            current.boundary = nil; current.targetWaitFrames += 1
            if host.selected == current.target, host.viewIfLoaded?.window === window,
               let slot = host.token(for: current.target), current.targetSlot == nil || slot == current.targetSlot,
               let owner = host.navigationOwner(tab: current.target), host.owns(owner, tab: current.target),
               owner.transitionCoordinator == nil, owner.navigationController?.transitionCoordinator == nil,
               PageBodyViewports.geometry(containing: owner) != nil {
                current.targetSlot = slot
                guard self.body.isPrepared(current.id) else { self.finish(current); return }
                if current.reduceMotion {
                    self.finish(current, cancellationReason: "cover-root-reduced-motion")
                    return
                }
                self.body.reveal(current.id, destination: owner, direction: current.direction) { [weak self, weak current] _ in
                    guard let self, let current, self.flight === current else { return }
                    self.finish(current)
                }
            } else if current.targetWaitFrames < 18 { self.waitForTarget(current) }
            else { self.cancel(reason: "cover-root-target-layout-timeout") }
        }
    }

    func cancel(reason: String = "cover-root-cancelled") {
        guard let current = flight else { return }
        finish(current, cancellationReason: reason)
    }

    private func finish(_ current: Flight, cancellationReason: String? = nil) {
        guard flight === current else { return }
        // Invalidate callbacks before cancelling a pending capture, whose
        // completion may run synchronously from PageBodyHandoff.cancel.
        flight = nil
        current.boundary?.cancel(); current.boundary = nil
        current.watchdog?.cancel(); current.watchdog = nil
        #if DEBUG && targetEnvironment(simulator)
        current.qaHoldTask?.cancel(); current.qaHoldTask = nil
        #endif
        MountedPageCovers.shared.abandon(current.id)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let cancellationReason { body.cancel(reason: cancellationReason) }
        current.permits.forEach { $0.release() }; current.permits.removeAll()
        CATransaction.commit()
    }
}

/// Reads the cover identity at the actual footer host, including WK/native
/// pager roots which explicitly forward the presentation environment.
struct CoveredRootTabControls<Content: View>: View {
    let select: (Int, UUID?) -> Void
    @ViewBuilder let content: (@escaping (Int) -> Void) -> Content
    @Environment(\.pageCoverScope) private var scope
    var body: some View { content { select($0, scope) } }
}

/// Owns the platform lifecycle. Business intent and visual settlement are
/// separate; a callback can close only the session that created it.
private struct PinnedPageCover<Item: Identifiable>: ViewModifier {
    @Binding var item: Item?
    let route: NativeHeaderRoute
    let requestIdentity: AnyHashable?
    let destinationRole: PageCanvasRole
    let sourceRole: PageCanvasRole?
    let animateDismissal: Bool
    let onBegin: (Item, UUID) -> Void
    let onEnd: (Item, UUID) -> Void
    let presented: (Item, UUID, @escaping () -> Bool) -> AnyView
    @State private var lifecycle = PresentationLifecycle<Item>(ownerInitiallyActive: false)
    @State private var cleanup = PagePresentationCleanup()
    @State private var bodyHandoff = PageBodyHandoff()
    @State private var entryPermit = PageVisualActivationPermit()
    @State private var pendingEntryActivation: PageVisualActivationLease?
    @State private var pendingReturnActivation: PageVisualActivationLease?
    @State private var pendingClose: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageSurfaceTone) private var inheritedTone
    @Environment(\.pageCanvasRole) private var inheritedRole
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.pageCoverScope) private var parentCoverScope
    @EnvironmentObject private var session: SiteSession

    func body(content: Content) -> some View {
        let callbackReceipt = cleanup.callbackReceipt
        // This describes entry only. A later return tone must never hide
        // already-visible content while the page is being dismissed.
        let entryClock = lifecycle.phase == .mounting || lifecycle.phase == .visible
            ? bodyHandoff.tone?.clock : nil
        content
            .nativeHeaderRouteBoundary(route, isPresented: false,
                                       onLayout: {
                                           if lifecycle.requiresMountRecovery {
                                               DispatchQueue.main.async { reconcile() }
                                           }
                                       },
                                       onAttach: {
                                           lifecycle.attachOwner($0)
                                           tracePresentation("source-attach")
                                           reconcile()
                                       }, onDetach: sourceRemoved)
            .background {
                Color.clear.fullScreenCover(item: platformPresentation, onDismiss: { [cleanup, callbackReceipt] in
                    // This is the platform receipt. The mounted slot survives
                    // probe teardown and cannot be replaced by a newer request.
                    if let callbackReceipt {
                        // A late actual receipt can update its own history even
                        // after recovery, but cannot consume a newer session.
                        callbackReceipt.recordNavigation(.committed)
                    }
                    if let callbackReceipt, let receipt = cleanup.platformDismissed(callbackReceipt.id) {
                        let currentID = lifecycle.session?.id
                        finish(receipt.id, platformWasMounted: true)
                        MountedPageCovers.shared.platformDismissed(receipt.id)
                        if currentID == nil || currentID == receipt.id { reconcile() }
                    }
                }) { session in
                    presented(item?.id == session.item.id ? (item ?? session.item) : session.item,
                              session.id, { mayClose(session.id) })
                        .environment(\.pageCanvasRole, destinationRole)
                        .environment(\.pageCoverScope, session.id)
                        .environment(\.pageVisualActivationPermit, entryPermit)
                        .environment(\.pageEntryVisualClock, entryClock)
                        .environment(\.pageReturnNavigationReceipt, cleanup.receipt(for: session.id))
                        .environment(\.pageMayRetryEdgeClose, { lifecycle.phase == .visible && mayClose(session.id) })
                        .nativeHeaderRouteBoundary(route, isPresented: true,
                                                   onAppear: { appeared(session.id) },
                                                   onLayout: { if lifecycle.session?.id == session.id { bodyHandoff.keepVisible() } })
                }
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
            .environment(\.pageSurfaceTone, bodyHandoff.tone ?? inheritedTone)
            .onChange(of: item.map { requestIdentity ?? AnyHashable($0.id) }, initial: true) { _, _ in
                lifecycle.requestChanged()
                reconcile()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                lifecycle.setSceneActive(phase == .active)
                if phase == .active { reconcile() } else {
                    bodyHandoff.cancel()
                    pendingEntryActivation?.release(); pendingEntryActivation = nil
                    pendingReturnActivation?.release(); pendingReturnActivation = nil
                }
            }
            .onChange(of: session.accountSessionID) { _, _ in
                bodyHandoff.cancel()
                pendingEntryActivation?.release(); pendingEntryActivation = nil
                pendingReturnActivation?.release(); pendingReturnActivation = nil
            }
    }

    private var platformPresentation: Binding<PresentationLifecycle<Item>.Session?> {
        let expectedToken = lifecycle.session?.id
        return Binding(get: {
            guard lifecycle.session?.id == expectedToken else { return nil }
            return lifecycle.platformSession
        }, set: { value in
            if value == nil, let expectedToken { close(expectedToken) }
        })
    }

    private func reconcile() {
        guard lifecycle.ownerActive, lifecycle.sceneActive else { return }
        if MountedPageCovers.shared.deferReconcile(cleanup, parent: parentCoverScope,
            owner: route.sourcePageController, action: reconcile) { return }
        if let active = lifecycle.session, lifecycle.requiresMountRecovery,
           lifecycle.canRecoverUnmountedMount(active.id, platformIsAbsent: platformPresentationIsAbsent) {
            finish(active.id, platformWasMounted: false)
            return
        }
        if lifecycle.phase == .idle, !cleanup.awaitingPlatformReceipt, let item, let session = lifecycle.prepare(item) {
            tracePresentation("prepare")
            cleanup.begin(session.id)
            onBegin(item, session.id)
            // Cancellation before this platform commit finishes locally; it
            // must not wait for a UIKit onDismiss that can never arrive.
            DispatchQueue.main.async {
                guard lifecycle.session?.id == session.id else { return }
                guard lifecycle.ownerActive, lifecycle.sceneActive, itemStillRequested(session) else { finish(session.id, platformWasMounted: false); return }
                let capturedAccountID = self.session.accountSessionID
                bodyHandoff.prepare(session.id, source: route.sourcePageController, kind: "entry",
                                    enabled: !reduceMotion,
                                    sourceScheme: (sourceRole ?? inheritedRole) == .playback ? .dark : ordinaryScheme,
                                    sourceIsMedia: (sourceRole ?? inheritedRole) == .playback,
                                    identity: capturedAccountID.map(AnyHashable.init)) { _ in
                    guard lifecycle.session?.id == session.id else { return }
                    guard self.session.accountSessionID == capturedAccountID else {
                        finish(session.id, platformWasMounted: false); return
                    }
                    guard lifecycle.ownerActive, lifecycle.sceneActive, itemStillRequested(session) else {
                        finish(session.id, platformWasMounted: false); return
                    }
                    let activation = entryPermit.block(session.id)
                    if bodyHandoff.isPrepared(session.id) {
                        bodyHandoff.attachActivationLease(activation)
                    } else {
                        pendingEntryActivation = activation
                    }
                    route.preparePresentation(tone: bodyHandoff.tone)
                    withoutPageAnimation {
                        if lifecycle.commitMount(session.id) { cleanup.requested(session.id) }
                    }
                }
            }
        } else if let session = lifecycle.session, !itemStillRequested(session) {
            close(session.id)
        }
    }

    private func sourceRemoved(_ token: UUID) {
        tracePresentation("source-detach")
        guard lifecycle.detachOwner(token) else { return }
        bodyHandoff.cancel()
        guard let active = lifecycle.session else { return }
        cleanup.receipt(for: active.id)?.abortVisual(reason: "presentation-owner-removed")
        // Keep the request terminable until actual appearance, dismissal, or a
        // reattached live presenter proves that UIKit has no such presentation.
        if lifecycle.phase == .mounting { return }
        finish(active.id, platformWasMounted: lifecycle.phase != .preparing)
    }

    private var platformPresentationIsAbsent: Bool {
        guard let source = route.sourcePageController, let view = source.viewIfLoaded,
              let window = view.window, window.windowScene?.activationState == .foregroundActive,
              view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var destination = route.destinationPageController
        while let current = destination {
            if current.viewIfLoaded?.window != nil || current.presentingViewController != nil
                || current.isBeingPresented || current.isBeingDismissed || current.transitionCoordinator != nil { return false }
            destination = current.parent
        }
        var presenter: UIViewController? = source
        while let current = presenter {
            if current.presentedViewController != nil || current.isBeingPresented
                || current.isBeingDismissed || current.transitionCoordinator != nil { return false }
            if current.parent == nil { return current.viewIfLoaded?.window === window }
            presenter = current.parent
        }
        return false
    }

    private func itemStillRequested(_ session: PresentationLifecycle<Item>.Session) -> Bool {
        item?.id == session.item.id && lifecycle.requestRevision == session.requestRevision
    }

    private func mayClose(_ token: UUID) -> Bool {
        guard let session = lifecycle.session, session.id == token else { return false }
        return itemStillRequested(session) && (lifecycle.phase == .visible || lifecycle.phase == .mounting)
    }

    private func appeared(_ token: UUID) {
        guard lifecycle.session?.id == token, lifecycle.phase == .mounting else { return }
        cleanup.mounted(token)
        MountedPageCovers.shared.mount(token, parent: parentCoverScope, identity: session.accountSessionID,
            owner: route.destinationPageController, permit: entryPermit,
            close: { exit in closeForRootExit(token, exit: exit) })
        let closeAfterMount = lifecycle.appeared(token)
        route.appeared()
        if let activation = pendingEntryActivation {
            pendingEntryActivation = nil
            if bodyHandoff.isPrepared(token) { bodyHandoff.attachActivationLease(activation) }
            else { activation.release() }
        }
        if closeAfterMount { close(token, preserveEntryBody: true) }
        else { bodyHandoff.reveal(token, destination: route.destinationPageController) }
    }

    private func closeForRootExit(_ token: UUID, exit: UUID) -> Bool {
        guard lifecycle.session?.id == token, lifecycle.phase == .visible,
              pendingClose == nil, MountedPageCovers.shared.isExternallyClosing(token) else { return false }
        bodyHandoff.cancel()
        route.prepareDismissal(animate: false)
        var accepted = false
        withoutPageAnimation { accepted = lifecycle.requestClose(token) }
        return accepted
    }

    private func close(_ token: UUID, preserveEntryBody: Bool = false) {
        guard lifecycle.session?.id == token, pendingClose != token,
              lifecycle.phase != .dismissing,
              !MountedPageCovers.shared.isExternallyClosing(token) else { return }
        if lifecycle.phase == .preparing { finish(token, platformWasMounted: false); return }
        let receipt = cleanup.receipt(for: token)
        let policy = cleanup.dismissalPolicy(token, requested: animateDismissal)
        let beginDismissal = {
            guard lifecycle.session?.id == token else {
                pendingClose = nil
                pendingReturnActivation?.release(); pendingReturnActivation = nil
                return
            }
            pendingClose = nil
            guard lifecycle.requestClose(token) else { return }
            let edgeOwnsClose = receipt?.hasEdgeClose == true
            if !policy || reduceMotion || edgeOwnsClose || preserveEntryBody {
                bodyHandoff.cancel()
            }
            route.prepareDismissal(animate: policy && !edgeOwnsClose, tone: bodyHandoff.tone)
        }
        guard policy, !reduceMotion, receipt?.hasEdgeClose != true, !preserveEntryBody else {
            beginDismissal(); return
        }
        pendingClose = token
        pendingReturnActivation = route.sourcePageController.flatMap {
            PageBodyViewports.suspendActivation(in: $0, token: token)
        }
        let capturedAccountID = session.accountSessionID
        bodyHandoff.prepare(token, source: route.destinationPageController, kind: "return", enabled: true,
                            sourceScheme: destinationRole == .playback ? .dark : ordinaryScheme,
                            sourceIsMedia: destinationRole == .playback,
                            identity: capturedAccountID.map(AnyHashable.init)) { _ in
            guard pendingClose == token, lifecycle.session?.id == token else { return }
            guard session.accountSessionID == capturedAccountID else { beginDismissal(); return }
            if bodyHandoff.isPrepared(token), let activation = pendingReturnActivation {
                pendingReturnActivation = nil
                bodyHandoff.attachActivationLease(activation)
            }
            beginDismissal()
        }
    }

    private func finish(_ token: UUID, platformWasMounted: Bool) {
        guard lifecycle.session?.id == token else { return }
        tracePresentation("finish")
        let externalRootExit = MountedPageCovers.shared.isExternallyClosing(token)
        let edgeOwnsClose = cleanup.receipt(for: token)?.hasEdgeClose == true
        guard let ended = lifecycle.finish(token) else { return }
        if pendingClose == token { pendingClose = nil }
        pendingEntryActivation?.release(); pendingEntryActivation = nil
        if platformWasMounted {
            route.dismissed(animate: !externalRootExit && !edgeOwnsClose && cleanup.dismissalPolicy(token, requested: animateDismissal))
        }
        cleanup.finish(token)
        if item?.id == ended.item.id, lifecycle.requestRevision == ended.requestRevision { item = nil }
        onEnd(ended.item, ended.id)
        let finishVisual: () -> Void = {
            DispatchQueue.main.async {
                lifecycle.callbacksFinished(token)
                reconcile() // Re-read pending after all callbacks and visual cleanup.
            }
        }
        if platformWasMounted, !edgeOwnsClose, !externalRootExit {
            if let activation = pendingReturnActivation {
                pendingReturnActivation = nil
                if bodyHandoff.isPrepared(token) { bodyHandoff.attachActivationLease(activation) }
                else { activation.release() }
            }
            bodyHandoff.reveal(token, destination: route.sourcePageController, completion: { _ in finishVisual() })
        } else {
            pendingReturnActivation?.release(); pendingReturnActivation = nil
            bodyHandoff.cancel()
            finishVisual()
        }
    }

    private func tracePresentation(_ event: String) {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") else { return }
        PagerGestureTraceQA.lifecycle("cover." + event, ["session": lifecycle.session?.id.uuidString ?? "none",
            "phase": String(describing: lifecycle.phase), "request": lifecycle.requestRevision,
            "item": item.map { String(describing: $0.id) } ?? "none"])
        NSLog("PRESENT169 event=%@ session=%@ phase=%@", event,
              lifecycle.session?.id.uuidString ?? "none", String(describing: lifecycle.phase))
        #endif
    }
}

struct BusinessPageSurface<Content: View>: View {
    var fromMedia = false
    let onTab: (MediaTabExit) -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.ordinaryColorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                content()
                    .environment(\.overlaidTabBarHeight, tabs?.height ?? 0)
                    .environment(\.floatingPageSafeInsets, geometry.safeAreaInsets)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
            .ordinaryPresentationAppearance()
            .overlay(alignment: .bottom) {
                if let tabs { tabs.render(false, "business.tabs", nil, { onTab(.init(id: $0, fromMedia: false)) }) }
            }
            .environment(\.exitMediaCoverToTab, onTab)
        }
    }
}

/// A removed authorization/access page must not leave playback suspended.
private final class BusinessPageLease: ObservableObject {
    let id = UUID()
    deinit {
        let id = id
        Task { @MainActor in ViewingChromeController.shared.resume(after: id) }
    }
}

private struct BusinessPageToken: Identifiable { let id = 0 }

private struct BusinessPagePresentation<Item: Identifiable, Presented: View>: ViewModifier {
    @Binding var requested: Item?
    let onDismiss: () -> Void
    let presented: (Item, @escaping () -> Void) -> Presented
    private struct Context { let token: UUID; let wasOverMedia: Bool }
    @State private var context: Context?
    @State private var route = NativeHeaderRoute()
    @StateObject private var lease = BusinessPageLease()
    @State private var exitingToTab = false
    private let chrome = ViewingChromeController.shared
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var parentExit
    @Environment(\.colorScheme) private var sourceScheme
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .pagePresentation(item: $requested, route: route, animateDismissal: !exitingToTab,
                              onBegin: begin, onEnd: end) { payload, token, mayClose in
                BusinessPageSurface(fromMedia: context?.wasOverMedia == true, onTab: { selectTab($0, token: token, mayClose: mayClose) }) {
                    presented(payload, { close(token, mayClose: mayClose) })
                }
            }
            .onDisappear { if context == nil { chrome.resume(after: lease.id) } }
    }

    private func begin(_ payload: Item, token: UUID) {
        context = Context(token: token, wasOverMedia: sourceScheme == .dark && ordinaryScheme == .light)
        exitingToTab = false
        chrome.suspend(for: lease.id)
    }

    private func close(_ token: UUID, mayClose: () -> Bool) {
        guard context?.token == token, mayClose() else { return }
        withoutPageAnimation {
            requested = nil
        }
    }

    private func selectTab(_ exit: MediaTabExit, token: UUID, mayClose: () -> Bool) {
        guard context?.token == token, mayClose() else { return }
        let select = parentExit ?? tabs?.select
        withoutPageAnimation {
            exitingToTab = true
            chrome.resume(after: lease.id)
            requested = nil
            select?(.init(id: exit.id, fromMedia: false))
        }
    }

    private func end(_ payload: Item, token: UUID) {
        guard context?.token == token else { return }
        context = nil
        chrome.resume(after: lease.id)
        onDismiss()
    }
}

extension View {
    /// Stable item identity permits live payload updates. A new intent for the
    /// same item must supply a fresh requestIdentity (or a UUID request envelope).
    func pagePresentation<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, route: NativeHeaderRoute, requestIdentity: AnyHashable? = nil,
        destinationRole: PageCanvasRole = .ordinary, sourceRole: PageCanvasRole? = nil, animateDismissal: Bool = true,
        onBegin: @escaping (Item, UUID) -> Void = { _, _ in },
        onEnd: @escaping (Item, UUID) -> Void = { _, _ in },
        @ViewBuilder content: @escaping (Item, UUID, @escaping () -> Bool) -> Presented
    ) -> some View {
        modifier(PinnedPageCover(item: item, route: route, requestIdentity: requestIdentity, destinationRole: destinationRole, sourceRole: sourceRole, animateDismissal: animateDismissal,
                                 onBegin: onBegin, onEnd: onEnd, presented: { payload, token, mayClose in
                                     AnyView(content(payload, token, mayClose))
                                 }))
    }

    func pinnedPageCover<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, route: NativeHeaderRoute, destinationRole: PageCanvasRole = .ordinary, sourceRole: PageCanvasRole? = nil,
        animateDismissal: Bool = true, onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping (Item) -> Presented
    ) -> some View {
        pagePresentation(item: item, route: route, destinationRole: destinationRole, sourceRole: sourceRole, animateDismissal: animateDismissal,
                         onEnd: { _, _ in onDismiss() }) { payload, _, _ in content(payload) }
    }

    func businessPage<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item, @escaping () -> Void) -> Presented
    ) -> some View {
        modifier(BusinessPagePresentation(requested: item, onDismiss: onDismiss, presented: content))
    }

    func businessPage<Presented: View>(
        isPresented: Binding<Bool>, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (@escaping () -> Void) -> Presented
    ) -> some View {
        businessPage(item: Binding(
            get: { isPresented.wrappedValue ? BusinessPageToken() : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        ), onDismiss: onDismiss) { _, close in content(close) }
    }
}


extension EnvironmentValues {
    @Entry var requestSignIn: ((Bool) -> Void)? = nil
}

/// A covered player presents login from its own stable navigation owner.
/// Ordinary pages retain the MainTabs login presenter.
private struct PlaybackLoginPresentation: ViewModifier {
    @EnvironmentObject private var session: SiteSession
    @State private var shown = false
    @State private var includesCollections = false

    func body(content: Content) -> some View {
        content
            .businessPage(isPresented: $shown, onDismiss: { session.oauth.cancel() }) { close in
                LoginView(forCollections: includesCollections, onClose: close)
            }
            .environment(\.requestSignIn, { collections in
                includesCollections = collections || session.oauth.hasCollectionAccess
                shown = true
            })
    }
}

extension View {
    func playbackLoginPage() -> some View { modifier(PlaybackLoginPresentation()) }
}
