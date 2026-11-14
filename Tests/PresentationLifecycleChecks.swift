import Foundation

@main struct PresentationLifecycleChecks {
    struct Item: Identifiable { let id: Int }
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        let state = PresentationLifecycle<Item>()
        expect(state.phase == .idle && state.platformSession == nil, "starts without a platform request")
        state.requestChanged()
        let a = state.prepare(Item(id: 7))!
        expect(state.platformSession == nil, "preparation cannot mount implicitly")
        expect(state.prepare(Item(id: 8)) == nil, "one actual session at a time")
        expect(state.finish(a.id)?.id == a.id, "pre-mount cancellation is completed locally")
        expect(state.finish(a.id) == nil, "cancellation receipt is consumed once")
        state.callbacksFinished(a.id)
        expect(state.phase == .idle, "no UIKit callback is required for pre-mount cancellation")

        state.requestChanged()
        let b = state.prepare(Item(id: 7))!
        expect(b.id != a.id, "same business content has a new actual route instance")
        expect(state.commitMount(a.id) == false, "late old commit cannot mount a new session")
        expect(state.commitMount(b.id), "mount current session")
        expect(state.requestClose(b.id) == false, "close while mounting waits for appearance")
        expect(state.platformSession?.id == b.id, "retain platform request until UIKit can report back")
        expect(state.appeared(b.id), "appearance reports pending close")
        expect(state.requestClose(b.id), "mounted pending close begins real dismissal")
        expect(state.platformSession == nil && state.session?.id == b.id, "dismiss binding clears, actual identity remains")
        expect(!state.requestClose(b.id), "duplicate close does not start a second dismissal")
        let endedB = state.finish(b.id)
        expect(endedB?.id == b.id && state.phase == .finishing, "actual dismissal receipt")
        expect(state.prepare(Item(id: 8)) == nil, "callbacks cannot reenter actual presentation")
        expect(state.finish(b.id) == nil, "duplicate platform callback is ignored")
        state.callbacksFinished(b.id)

        state.requestChanged()
        let c = state.prepare(Item(id: 8))!
        expect(state.commitMount(c.id), "latest pending is committed after callbacks")
        expect(!state.appeared(c.id), "ordinary mount does not request close")
        expect(!state.requestClose(b.id), "late old close cannot close C")
        expect(state.finish(b.id) == nil && state.session?.id == c.id, "late old completion cannot clear C")
        state.requestChanged() // pending D (or nil), owned by the caller
        expect(state.requestRevision != c.requestRevision, "replacement remains distinct from C")
        expect(state.requestClose(c.id), "close C for caller's latest request")
        expect(state.finish(c.id)?.id == c.id, "finish C once")
        state.callbacksFinished(c.id)
        state.requestChanged()
        let d = state.prepare(Item(id: 8))!
        expect(d.id != c.id && d.requestRevision != c.requestRevision, "same ID replacement has fresh identities")
        expect(state.commitMount(d.id), "mount D")
        expect(!state.appeared(c.id) && state.phase == .mounting, "old appearance cannot complete D")
        expect(!state.appeared(d.id), "D ordinary appearance")
        expect(!state.appeared(d.id), "duplicate appearance is harmless")
        expect(state.requestClose(d.id), "close D")
        expect(state.finish(d.id)?.id == d.id, "D result")
        state.callbacksFinished(d.id)
        expect(state.phase == .idle && state.platformSession == nil, "all actual resources can be released")
        let removed = PresentationLifecycle<Item>(ownerInitiallyActive: false)
        expect(removed.prepare(Item(id: 1)) == nil, "unattached source cannot mount")
        let ownerA = UUID(), ownerB = UUID()
        removed.attachOwner(ownerA)
        let pending = removed.prepare(Item(id: 1))!
        expect(removed.detachOwner(ownerA), "stable source teardown is explicit")
        expect(!removed.commitMount(pending.id), "onBegin root removal cannot mount later")
        expect(removed.finish(pending.id)?.id == pending.id, "removed preparation has one local receipt")
        removed.callbacksFinished(pending.id)
        expect(removed.prepare(Item(id: 2)) == nil, "onEnd queued B cannot revive a removed source")
        removed.attachOwner(ownerB)
        expect(!removed.detachOwner(ownerA) && removed.ownerActive, "old source teardown cannot invalidate replacement")
        expect(removed.prepare(Item(id: 2)) != nil, "new source owner can present its own request")
        let unappeared = PresentationLifecycle<Item>(ownerInitiallyActive: false)
        let firstOwner = UUID(), reattachedOwner = UUID()
        unappeared.attachOwner(firstOwner)
        let requested = unappeared.prepare(Item(id: 31))!
        expect(unappeared.commitMount(requested.id), "request mount before source teardown")
        expect(unappeared.detachOwner(firstOwner), "detach while UIKit has not appeared")
        expect(unappeared.requiresMountRecovery && unappeared.phase == .mounting
               && unappeared.platformSession?.id == requested.id,
               "detach retains a terminable mount request rather than coalescing it to nil")
        expect(!unappeared.canRecoverUnmountedMount(requested.id, platformIsAbsent: true),
               "detached source cannot claim UIKit absence without reattachment")
        unappeared.attachOwner(reattachedOwner)
        expect(!unappeared.canRecoverUnmountedMount(requested.id, platformIsAbsent: false),
               "unknown or still-mounting UIKit state cannot be inferred as never-mounted")
        expect(!unappeared.canRecoverUnmountedMount(UUID(), platformIsAbsent: true),
               "foreign route cannot recover the current mount")
        expect(unappeared.canRecoverUnmountedMount(requested.id, platformIsAbsent: true),
               "reattached presenter with actual absence evidence can abort an unmounted request")
        expect(unappeared.finish(requested.id)?.id == requested.id, "never-mounted recovery has one local cleanup")
        unappeared.callbacksFinished(requested.id)
        expect(unappeared.phase == .idle && !unappeared.requiresMountRecovery,
               "no missing onDismiss is required to become reusable after proven absence")
        unappeared.requestChanged()
        let reopened = unappeared.prepare(Item(id: 32))!
        expect(unappeared.commitMount(reopened.id), "a new request can mount after recovery")
        expect(!unappeared.appeared(requested.id) && unappeared.session?.id == reopened.id,
               "late old appearance cannot consume the new request")
        expect(unappeared.finish(requested.id) == nil && unappeared.phase == .mounting,
               "late old dismissal cannot finish the new route")
        expect(!unappeared.appeared(reopened.id) && unappeared.phase == .visible,
               "new route appears normally without an inherited close flag")

        let lateAppearance = PresentationLifecycle<Item>()
        let liveOwner = UUID()
        lateAppearance.attachOwner(liveOwner)
        let eventual = lateAppearance.prepare(Item(id: 33))!
        expect(lateAppearance.commitMount(eventual.id), "request whose actual mount arrives late")
        expect(lateAppearance.detachOwner(liveOwner), "late mount loses source ownership first")
        expect(lateAppearance.appeared(eventual.id), "real late appearance requests an orderly close")
        expect(!lateAppearance.requiresMountRecovery && lateAppearance.requestClose(eventual.id),
               "an actually appeared page uses real dismissal instead of never-mounted recovery")
        let backgrounded = PresentationLifecycle<Item>()
        backgrounded.setSceneActive(false)
        expect(backgrounded.prepare(Item(id: 1)) == nil, "background cannot begin presentation")
        backgrounded.setSceneActive(true)
        let bg = backgrounded.prepare(Item(id: 1))!
        backgrounded.setSceneActive(false)
        expect(!backgrounded.commitMount(bg.id), "queued mount cannot commit after scene deactivation")
        expect(backgrounded.finish(bg.id) != nil, "background preparation can cancel locally")
        backgrounded.callbacksFinished(a.id)
        expect(backgrounded.phase == .finishing, "old visual completion cannot finish a different route")
        backgrounded.callbacksFinished(bg.id)
        expect(backgrounded.phase == .idle, "correct visual completion is consumed once")
        let receipt = PageTransitionReceipt()
        expect(!receipt.recordNavigation(.committed, token: UUID()), "foreign callback cannot commit")
        expect(receipt.recordNavigation(.committed, token: receipt.id), "actual navigation reports once")
        expect(receipt.recordVisual(.aborted("scene"), token: receipt.id), "visual may abort after navigation")
        expect(receipt.navigation == .committed, "visual abort cannot reverse navigation")
        expect(!receipt.recordNavigation(.cancelled, token: receipt.id), "duplicate outcome rejected")
        expect(!receipt.recordVisual(.completed, token: receipt.id), "old completion cannot replace abort")
        let cancelled = PageTransitionReceipt()
        expect(cancelled.recordNavigation(.cancelled, token: cancelled.id), "cancel before commit")
        expect(!cancelled.recordNavigation(.committed, token: cancelled.id), "cancelled navigation cannot submit late")

        checks += verifyScopedReturns()
        print("PresentationLifecycle: \(checks) checks passed")
    }
    @MainActor private static func verifyScopedReturns() -> Int {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
            checks += 1
            precondition(value(), "Scoped return receipt regression", file: file, line: line)
        }
        let receipt=PageReturnNavigationReceipt(id: UUID())
        let body=UUID(); var nav=0; var abort=0
        expect(receipt.claimBody(body, navigation: { _ in nav += 1 }, abortVisual: { _ in abort += 1 }))
        expect(!receipt.claimBody(UUID(), navigation: { _ in }, abortVisual: { _ in }))
        receipt.releaseBody(UUID()); expect(receipt.hasBodyOwner)
        expect(receipt.recordNavigation(.committed)); expect(nav == 1)
        receipt.abortVisual(reason: "scene"); expect(abort == 1 && !receipt.hasBodyOwner)
        expect(receipt.navigation == .committed)
        expect(!receipt.recordNavigation(.cancelled) && nav == 1)
        let cancelledVisual=PageReturnNavigationReceipt(id: UUID())
        expect(cancelledVisual.claimBody(UUID(), navigation: { _ in }, abortVisual: { _ in }))
        cancelledVisual.abortVisual(reason: "owner-removed")
        expect(cancelledVisual.navigation == nil)
        expect(cancelledVisual.recordNavigation(.committed))
        expect(cancelledVisual.navigation == .committed)
        let retry=PageReturnNavigationReceipt(id: UUID()); let first=UUID(), second=UUID()
        expect(retry.claimBody(first, navigation: { _ in }, abortVisual: { _ in }))
        retry.releaseBody(first)
        expect(retry.claimBody(second, navigation: { _ in }, abortVisual: { _ in }))
        retry.releaseBody(first); expect(retry.hasBodyOwner)
        let cleanup=PagePresentationCleanup(); let a=UUID(), b=UUID()
        cleanup.begin(a); let exact=cleanup.receipt(for: a)!
        cleanup.mounted(a); expect(cleanup.awaitingPlatformReceipt)
        exact.abortVisual(reason: "source-removed"); cleanup.finish(a)
        expect(cleanup.callbackReceipt === exact && cleanup.awaitingPlatformReceipt)
        expect(exact.navigation == nil)
        expect(cleanup.platformDismissed(UUID()) == nil && cleanup.awaitingPlatformReceipt)
        expect(cleanup.platformDismissed(a) === exact && exact.navigation == .committed)
        expect(!cleanup.awaitingPlatformReceipt && cleanup.platformDismissed(a) == nil)
        cleanup.begin(b); cleanup.mounted(b)
        expect(cleanup.platformDismissed(a) == nil && cleanup.awaitingPlatformReceipt)
        expect(cleanup.platformDismissed(b)?.id == b)
        let mountRequest=PagePresentationCleanup(); let requestedID=UUID(), nextID=UUID()
        mountRequest.begin(requestedID); mountRequest.requested(requestedID)
        let oldRequest=mountRequest.callbackReceipt!
        expect(!mountRequest.awaitingPlatformReceipt)
        expect(oldRequest.navigation == nil)
        mountRequest.finish(requestedID)
        expect(!mountRequest.awaitingPlatformReceipt && mountRequest.callbackReceipt == nil)
        mountRequest.begin(nextID); mountRequest.requested(nextID)
        expect(mountRequest.callbackReceipt?.id == nextID)
        oldRequest.recordNavigation(.committed)
        expect(mountRequest.platformDismissed(requestedID) == nil && mountRequest.callbackReceipt?.id == nextID)
        mountRequest.mounted(nextID)
        expect(mountRequest.awaitingPlatformReceipt)
        expect(mountRequest.platformDismissed(requestedID) == nil && mountRequest.awaitingPlatformReceipt)
        expect(mountRequest.platformDismissed(nextID)?.navigation == .committed)
        let dismissedBeforeAppearance=PagePresentationCleanup(); let earlyID=UUID()
        dismissedBeforeAppearance.begin(earlyID); dismissedBeforeAppearance.requested(earlyID)
        expect(dismissedBeforeAppearance.platformDismissed(earlyID)?.navigation == .committed)
        expect(!dismissedBeforeAppearance.awaitingPlatformReceipt)
        return checks
    }

}
