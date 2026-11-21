import Foundation
@main struct Checks {
    @MainActor static func main() async throws {
        let cache = ScopedDetailRead<Int>(capacity: 2, lifetime: 60)
        var count = 0
        let one = Task { @MainActor in try await cache.value(id: 1, scope: "a") { count += 1; try await Task.sleep(for: .milliseconds(30)); return 7 } }
        let two = Task { @MainActor in try await cache.value(id: 1, scope: "a") { count += 1; return 8 } }
        let first = try await one.value, second = try await two.value
        precondition(first == 7 && second == 7 && count == 1)
        let hit = try await cache.value(id: 1, scope: "a") { count += 1; return 9 }
        precondition(hit == 7 && count == 1)
        let cancel = Task { @MainActor in try await cache.value(id: 2, scope: "a") { count += 1; try await Task.sleep(for: .milliseconds(30)); return 11 } }
        try await Task.sleep(for: .milliseconds(5)); cancel.cancel()
        let survivor = Task { @MainActor in try await cache.value(id: 2, scope: "a") { count += 1; return 12 } }
        do { _ = try await cancel.value; preconditionFailure("Cancelled page accepted result") } catch is CancellationError {}
        let kept = try await survivor.value
        precondition(kept == 11 && count == 2)
        let old = Task { @MainActor in try await cache.value(id: 3, scope: "a") { try? await Task.sleep(for: .milliseconds(30)); return 13 } }
        try await Task.sleep(for: .milliseconds(5))
        precondition(cache.cached(id: 1, scope: "b") == nil)
        do { _ = try await old.value; preconditionFailure("Old scope published") } catch is CancellationError {}
        precondition(cache.cached(id: 3, scope: "b") == nil)
        _ = try await cache.value(id: 1, scope: "b") { 1 }
        _ = try await cache.value(id: 2, scope: "b") { 2 }
        _ = cache.cached(id: 1, scope: "b")
        _ = try await cache.value(id: 3, scope: "b") { 3 }
        precondition(cache.cached(id: 2, scope: "b") == nil && cache.cached(id: 1, scope: "b") == 1)
        _ = try await cache.value(id: 1, scope: "b", now: Date.timeIntervalSinceReferenceDate + 120) { nil }
        precondition(cache.cached(id: 1, scope: "b") == 1, "Unknown result erased cached tags")
        enum Failure: Error { case request }
        do { _ = try await cache.value(id: 1, scope: "b", now: Date.timeIntervalSinceReferenceDate + 120) { throw Failure.request }; preconditionFailure() } catch Failure.request {}
        precondition(cache.cached(id: 1, scope: "b") == 1)
        let refreshed = try await cache.value(id: 1, scope: "b", now: Date.timeIntervalSinceReferenceDate + 120) { 0 }
        precondition(refreshed == 0 && cache.cached(id: 1, scope: "b") == 0)
        cache.invalidate(); precondition(cache.cached(id: 1, scope: "b") == nil)
        print("ScopedDetailRead: coalescing, warm hit, single-consumer cancellation, scope fencing, LRU, unknown/error preservation, explicit empty, invalidation passed")
    }
}
