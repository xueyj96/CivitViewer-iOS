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

/// One input hold for a navigation attempt. Temporarily moving the hold from
/// one renderer to another does not acquire a second window shield.
@MainActor final class PageTransitionInput {
    let token: UUID
    private var acquireStarted = false
    private var ended = false
    private var relinquish: (@MainActor () -> Void)?

    init(token: UUID) { self.token = token }
    var isHeld: Bool { relinquish != nil }

    @discardableResult
    func acquire(_ acquireShield: () -> (@MainActor () -> Void)) -> Bool {
        guard !acquireStarted, !ended else { return false }
        acquireStarted = true
        let release = acquireShield()
        // Installing a UIKit view can synchronously invalidate the action.
        guard !ended else { release(); return false }
        relinquish = release
        return true
    }

    func release(_ token: UUID) {
        guard token == self.token, !ended else { return }
        ended = true
        let release = relinquish
        relinquish = nil
        release?()
    }

    isolated deinit { relinquish?() }
}

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

/// Suppresses only another Back on the page that already submitted a pop.
/// A departing visual can release independently of the UIKit receipt.
@MainActor final class PageNativeReturnGate {
    private(set) var receipt: PageTransitionReceipt?
    private var deadline: Task<Void, Never>?
    var blocksBack: Bool { receipt != nil }

    func submit(_ receipt: PageTransitionReceipt, timeout: Duration = .seconds(2)) -> Bool {
        guard self.receipt == nil else { return false }
        self.receipt = receipt
        let token = receipt.id
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.release(token)
        }
        return true
    }

    func release(_ token: UUID) {
        guard receipt?.id == token else { return }
        receipt = nil
        deadline?.cancel()
        deadline = nil
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
    private enum EdgeClose {
        case invoking(PageTransitionReceipt)
        case accepted(PageTransitionReceipt, requested: Bool, retryAfter: ContinuousClock.Instant)
    }
    private var edgeClose: EdgeClose?

    init(id: UUID) { self.id = id }
    var hasBodyOwner: Bool { bodyOwner != nil }
    var hasEdgeClose: Bool {
        switch edgeClose {
        case .invoking: true
        case let .accepted(_, requested, _): requested
        case nil: false
        }
    }

    func claimBody(_ token: UUID, visibleAndRequested: Bool = false,
                   navigation: @escaping (PageNavigationOutcome) -> Void,
                   abortVisual: @escaping (String) -> Void) -> Bool {
        guard self.navigation == nil, bodyOwner == nil else { return false }
        if let edgeClose {
            // Retry only when the exact session still wants to be visible and
            // the earlier accepted attempt has had time to dismiss.
            guard visibleAndRequested, case let .accepted(_, _, retryAfter) = edgeClose,
                  ContinuousClock.now >= retryAfter else { return false }
            self.edgeClose = nil
        }
        bodyOwner = token
        navigationObserver = navigation
        visualAbort = abortVisual
        return true
    }

    func beginEdgeClose(_ receipt: PageTransitionReceipt) -> Bool {
        guard navigation == nil, bodyOwner == receipt.id, edgeClose == nil else { return false }
        edgeClose = .invoking(receipt)
        return true
    }

    func resolveEdgeClose(_ token: UUID, accepted: Bool, requested: Bool, retryDelay: Duration = .seconds(2)) {
        guard case let .invoking(receipt) = edgeClose, receipt.id == token else { return }
        if accepted {
            let ownsClose = requested || navigation != nil
            edgeClose = .accepted(receipt, requested: ownsClose, retryAfter: ContinuousClock.now.advanced(by: retryDelay))
            if ownsClose, let navigation { receipt.recordNavigation(navigation, token: token) }
        } else {
            edgeClose = nil
        }
    }

    @discardableResult
    func recordNavigation(_ outcome: PageNavigationOutcome) -> Bool {
        guard navigation == nil else { return false }
        navigation = outcome
        let observer = navigationObserver
        navigationObserver = nil
        if case .accepted(_, false, _) = edgeClose {
            abortVisual(reason: "unrelated-presentation-close")
        } else {
            observer?(outcome)
        }
        if case let .accepted(receipt, true, _) = edgeClose { receipt.recordNavigation(outcome, token: receipt.id) }
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
