import Foundation
import Observation

// INSERT_GRID_LOADER

@MainActor private final class RequestBarrier {
    var starts = 0
    var cancelled = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func load(advances: Bool = true) async -> Bool {
        starts += 1; let index = starts
        await withCheckedContinuation { pending[index] = $0 }
        if Task.isCancelled { cancelled += 1; return false }
        return advances
    }
    func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
}

@main struct GridContinuationChecks {
    @MainActor static func main() async {
        func drain() async { for _ in 0..<20 { await Task.yield() } }
        let visibility = MediaGridVisibility()
        var nearEndNotifications = 0
        func trackNearEnd() {
            withObservationTracking {
                _ = visibility.nearEnd
            } onChange: {
                Task { @MainActor in
                    nearEndNotifications += 1
                    trackNearEnd()
                }
            }
        }
        trackNearEnd()
        visibility.updateTail(Array(1_000..<1_008))
        for id in 0..<200 {
            visibility.insert(id)
            visibility.remove(id)
        }
        await drain()
        precondition(!visibility.nearEnd && nearEndNotifications == 0,
                     "Non-tail row appearance and disappearance must not notify grid observers")

        visibility.insert(1_007); await drain()
        precondition(visibility.nearEnd && nearEndNotifications == 1, "Entering the tail range notifies once")
        visibility.insert(1_007); visibility.insert(1_006); visibility.remove(1_007)
        visibility.updateTail(Array(1_000..<1_008)); await drain()
        precondition(visibility.nearEnd && nearEndNotifications == 1, "Duplicate and overlapping tail membership is silent")
        visibility.remove(1_006); await drain()
        precondition(!visibility.nearEnd && nearEndNotifications == 2, "Leaving the final visible tail item notifies once")

        visibility.insert(1_007); await drain()
        precondition(nearEndNotifications == 3, "The old tail can re-enter after append")
        visibility.updateTail(Array(1_001..<1_009)); await drain()
        precondition(visibility.nearEnd && nearEndNotifications == 3, "Appending keeps demand while a visible item remains in the new tail")
        visibility.updateTail(Array(1_010..<1_018)); await drain()
        precondition(!visibility.nearEnd && nearEndNotifications == 4, "A disjoint appended tail exits demand")
        visibility.insert(1_017); await drain()
        visibility.clear(); await drain()
        precondition(!visibility.nearEnd && nearEndNotifications == 6, "Clear removes visible membership and notifies only the exit")
        visibility.insert(1_017); await drain()
        precondition(visibility.nearEnd && nearEndNotifications == 7, "Reappearing tail cells restore demand after clear")
        visibility.updateTail([4, 5, 6]); await drain()
        precondition(!visibility.nearEnd && nearEndNotifications == 8, "Short queues use their entire tail")
        visibility.insert(5); await drain()
        visibility.insert(5); visibility.remove(4); await drain()
        precondition(visibility.nearEnd && nearEndNotifications == 9, "Short queue duplicate membership notifies only on entry")
        visibility.clear(); await drain()
        precondition(!visibility.nearEnd && nearEndNotifications == 10, "Short queue clear notifies only on exit")

        let loader = GridContinuationLoader<String>(), barrier = RequestBarrier()
        loader.update(scope: "author-A", enabled: true, demanded: true, canLoad: true) { await barrier.load() }
        await drain(); precondition(barrier.starts == 1)
        loader.update(scope: "author-A", enabled: true, demanded: false, canLoad: true) { await barrier.load() }
        loader.update(scope: "author-A", enabled: true, demanded: true, canLoad: true) { await barrier.load() }
        await drain(); precondition(barrier.starts == 1 && barrier.cancelled == 0, "Leaving and returning to the prefetch range must keep one in-flight request")
        barrier.release(1); await drain()
        precondition(loader.completion == 1 && barrier.cancelled == 0, "The same accepted request commits after the trigger moves")

        loader.update(scope: "author-A", enabled: true, demanded: true, canLoad: false) { await barrier.load() }
        await drain(); precondition(barrier.starts == 1, "Another feed owner blocks a second request")
        loader.update(scope: "author-A", enabled: true, demanded: true, canLoad: true) { await barrier.load() }
        await drain(); precondition(barrier.starts == 2, "Readiness returning schedules demand even when the tail is unchanged")
        loader.update(scope: "author-B", enabled: true, demanded: true, canLoad: true) { await barrier.load() }
        await drain(); precondition(barrier.starts == 3)
        barrier.release(2); await drain()
        precondition(barrier.cancelled == 1 && loader.completion == 1, "A cancelled old scope cannot commit or clear the replacement owner")
        loader.update(scope: "author-B", enabled: true, demanded: true, canLoad: true) { await barrier.load() }
        await drain(); precondition(barrier.starts == 3, "A late old completion must not allow duplicate replacement requests")
        barrier.release(3); await drain(); precondition(loader.completion == 2)

        loader.update(scope: "author-B", enabled: true, demanded: true, canLoad: true) { await barrier.load(advances: false) }
        await drain(); barrier.release(4); await drain()
        precondition(loader.completion == 2, "A no-op or failure does not manufacture new automatic demand")
        loader.update(scope: "author-B", enabled: true, demanded: true, canLoad: true) { await barrier.load() }
        await drain()
        loader.update(scope: "author-B", enabled: false, demanded: true, canLoad: true) { await barrier.load() }
        barrier.release(5); await drain()
        precondition(barrier.cancelled == 2 && loader.completion == 2, "A hidden, backgrounded or disabled grid cancels its owner")
        print("GridContinuationChecks: visibility boundaries and preserved request, single owner, readiness, scope cancellation, stale completion, no-op and inactivity checks passed")
    }
}
