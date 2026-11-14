import Foundation
import Observation

/// Actual platform presentation only. The caller retains the latest requested
/// destination and business policy; UIKit callbacks carry this session's token.
@MainActor @Observable
final class PresentationLifecycle<Item: Identifiable> {
    enum Phase { case idle, preparing, mounting, visible, dismissing, finishing }
    struct Session: Identifiable {
        let id = UUID()
        let item: Item
        let requestRevision: UInt64
    }

    private(set) var phase: Phase = .idle
    private(set) var session: Session?
    private(set) var requestRevision: UInt64 = 0
    private(set) var sceneActive = true
    private(set) var ownerActive: Bool
    private(set) var requiresMountRecovery = false
    private var ownerToken: UUID?
    private var closeAfterMount = false
    private var finishingToken: UUID?

    init(ownerInitiallyActive: Bool = true) { ownerActive = ownerInitiallyActive }

    func attachOwner(_ token: UUID) { ownerToken = token; ownerActive = true }

    @discardableResult func detachOwner(_ token: UUID) -> Bool {
        guard ownerToken == token else { return false }
        ownerActive = false
        if phase == .mounting {
            requiresMountRecovery = true
            closeAfterMount = true
        }
        return true
    }

    var platformSession: Session? {
        phase == .mounting || phase == .visible ? session : nil
    }

    func setSceneActive(_ active: Bool) { sceneActive = active }

    func requestChanged() { requestRevision &+= 1 }

    func prepare(_ item: Item) -> Session? {
        guard ownerActive, sceneActive, phase == .idle else { return nil }
        let next = Session(item: item, requestRevision: requestRevision)
        session = next
        closeAfterMount = false
        requiresMountRecovery = false
        phase = .preparing
        return next
    }

    func commitMount(_ token: UUID) -> Bool {
        guard ownerActive, sceneActive, session?.id == token, phase == .preparing else { return false }
        phase = .mounting
        return true
    }

    /// Mounting must retain the platform request until UIKit has appeared;
    /// otherwise a coalesced nil binding may never produce onDismiss.
    func requestClose(_ token: UUID) -> Bool {
        guard session?.id == token else { return false }
        if phase == .mounting { closeAfterMount = true; return false }
        guard phase == .visible else { return false }
        phase = .dismissing
        return true
    }

    func appeared(_ token: UUID) -> Bool {
        guard session?.id == token, phase == .mounting else { return false }
        requiresMountRecovery = false
        phase = .visible
        return closeAfterMount
    }

    /// Only the UIKit adapter can supply actual absence evidence after a source
    /// reattaches. Not appearing yet, by itself, never proves a failed mount.
    func canRecoverUnmountedMount(_ token: UUID, platformIsAbsent: Bool) -> Bool {
        ownerActive && sceneActive && phase == .mounting && requiresMountRecovery
            && session?.id == token && platformIsAbsent
    }

    /// Also handles cancellation before committing a platform presentation.
    /// No onDismiss is awaited for a session that was never mounted.
    func finish(_ token: UUID) -> Session? {
        guard let current = session, current.id == token,
              phase != .idle, phase != .finishing else { return nil }
        session = nil
        closeAfterMount = false
        requiresMountRecovery = false
        finishingToken = token
        phase = .finishing
        return current
    }

    func callbacksFinished(_ token: UUID) {
        guard phase == .finishing, finishingToken == token else { return }
        finishingToken = nil
        phase = .idle
    }
}

// Navigation acceptance and visual cleanup are independent receipts. A renderer
// cannot turn a confirmed navigation into cancellation, or submit business work.
enum PageNavigationOutcome: Equatable { case committed, cancelled, aborted(String) }
enum PageVisualOutcome: Equatable { case completed, cancelled, aborted(String) }

@MainActor final class PageTransitionReceipt {
    let id: UUID
    private(set) var navigation: PageNavigationOutcome?
    private(set) var visual: PageVisualOutcome?
    init(id: UUID = UUID()) { self.id = id }
    @discardableResult func recordNavigation(_ outcome: PageNavigationOutcome, token: UUID) -> Bool {
        guard token == id, navigation == nil else { return false }
        navigation = outcome
        return true
    }
    @discardableResult func recordVisual(_ outcome: PageVisualOutcome, token: UUID) -> Bool {
        guard token == id, visual == nil else { return false }
        visual = outcome
        return true
    }
}

/// One actual presentation's exit receipt. It carries no controller or business
/// action; an edge attempt can temporarily claim the body visual independently.
@MainActor
final class PageReturnNavigationReceipt {
    let id: UUID
    private(set) var navigation: PageNavigationOutcome?
    private var bodyOwner: UUID?
    private var navigationObserver: ((PageNavigationOutcome) -> Void)?
    private var visualAbort: ((String) -> Void)?

    init(id: UUID) { self.id = id }
    var hasBodyOwner: Bool { bodyOwner != nil }

    func claimBody(_ token: UUID, navigation: @escaping (PageNavigationOutcome) -> Void,
                   abortVisual: @escaping (String) -> Void) -> Bool {
        guard self.navigation == nil, bodyOwner == nil else { return false }
        bodyOwner = token
        navigationObserver = navigation
        visualAbort = abortVisual
        return true
    }

    @discardableResult
    func recordNavigation(_ outcome: PageNavigationOutcome) -> Bool {
        guard navigation == nil else { return false }
        navigation = outcome
        let observer = navigationObserver
        navigationObserver = nil
        observer?(outcome)
        return true
    }

    func releaseBody(_ token: UUID) {
        guard bodyOwner == token else { return }
        bodyOwner = nil
        navigationObserver = nil
        visualAbort = nil
    }

    func abortVisual(reason: String) {
        guard let token = bodyOwner else { return }
        let abort = visualAbort
        releaseBody(token)
        abort?(reason)
    }
}

/// One scoped platform receipt, plus visual policy. A mounted receipt is retained
/// until actual onDismiss even if source ownership and visual resources end first.
@MainActor final class PagePresentationCleanup {
    private var token: UUID?
    private var currentReceipt: PageReturnNavigationReceipt?
    private var requestedReceipt: PageReturnNavigationReceipt?
    private var mountedReceipt: PageReturnNavigationReceipt?
    private var animateDismissal: Bool?
    var awaitingPlatformReceipt: Bool { mountedReceipt != nil }
    var callbackReceipt: PageReturnNavigationReceipt? { mountedReceipt ?? requestedReceipt ?? currentReceipt }
    func begin(_ token: UUID) {
        self.token = token
        currentReceipt = PageReturnNavigationReceipt(id: token)
        animateDismissal = nil
    }
    func receipt(for token: UUID) -> PageReturnNavigationReceipt? {
        currentReceipt?.id == token ? currentReceipt : nil
    }
    func requested(_ token: UUID) {
        guard requestedReceipt == nil, let receipt = receipt(for: token) else { return }
        requestedReceipt = receipt
    }
    func mounted(_ token: UUID) {
        guard mountedReceipt == nil, let receipt = receipt(for: token) else { return }
        mountedReceipt = receipt
        if requestedReceipt?.id == token { requestedReceipt = nil }
    }
    func platformDismissed(_ token: UUID) -> PageReturnNavigationReceipt? {
        guard let receipt = mountedReceipt ?? requestedReceipt, receipt.id == token else { return nil }
        if mountedReceipt?.id == token { mountedReceipt = nil }
        if requestedReceipt?.id == token { requestedReceipt = nil }
        receipt.recordNavigation(.committed)
        return receipt
    }
    func dismissalPolicy(_ token: UUID, requested: Bool) -> Bool {
        guard self.token == token else { return false }
        if animateDismissal == nil { animateDismissal = requested }
        return animateDismissal ?? requested
    }
    func finish(_ token: UUID) {
        guard self.token == token else { return }
        self.token = nil
        currentReceipt = nil
        if requestedReceipt?.id == token, mountedReceipt == nil { requestedReceipt = nil }
        animateDismissal = nil
    }
    deinit {
        MainActor.assumeIsolated {
            currentReceipt?.abortVisual(reason: "presentation-scope-released")
            requestedReceipt?.abortVisual(reason: "presentation-scope-released")
            mountedReceipt?.abortVisual(reason: "presentation-scope-released")
        }
    }
}
