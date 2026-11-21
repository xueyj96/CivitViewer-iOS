import Foundation

/// One server read shared by passive indicators and the open collection picker.
/// Invalidating at a write boundary prevents an older response from publishing.
@MainActor
final class CollectionRead<Value> {
    private var generation = 0
    private var flight: (id: UUID, task: Task<Value, Error>)?

    func task(load: @escaping @MainActor () async throws -> Value,
              commit: @escaping @MainActor (Value) -> Void) -> Task<Value, Error> {
        if let flight { return flight.task }
        let id = UUID(), generation = self.generation
        let task = Task { @MainActor in
            defer { if self.flight?.id == id { self.flight = nil } }
            try Task.checkCancellation()
            let value = try await load()
            guard generation == self.generation else { throw CancellationError() }
            try Task.checkCancellation()
            commit(value)
            return value
        }
        flight = (id, task)
        return task
    }

    func invalidate() {
        generation += 1
        flight?.task.cancel()
        flight = nil
    }
}

/// Small session-owned detail DTO cache. Page cancellation does not cancel a
/// shared read; account/permission scope changes invalidate the entire flight.
@MainActor
final class ScopedDetailRead<Value> {
    private struct Entry { let value: Value; let saved: TimeInterval; var access: UInt64 }
    private let capacity: Int
    private let lifetime: TimeInterval
    private var scope: String?
    private var entries: [Int: Entry] = [:]
    private var reads: [Int: (id: UUID, task: Task<Value?, Error>)] = [:]
    private var serial: UInt64 = 0
    init(capacity: Int = 32, lifetime: TimeInterval = 60) {
        self.capacity = max(1, capacity); self.lifetime = max(0, lifetime)
    }
    func invalidate() {
        for read in reads.values { read.task.cancel() }
        entries.removeAll(); reads.removeAll(); scope = nil
    }
    private func bind(_ scope: String) {
        if self.scope != scope { invalidate(); self.scope = scope }
    }
    func cached(id: Int, scope: String) -> Value? {
        bind(scope)
        guard var entry = entries[id] else { return nil }
        serial &+= 1; entry.access = serial; entries[id] = entry
        return entry.value
    }
    func value(id: Int, scope: String, now: TimeInterval = Date.timeIntervalSinceReferenceDate,
               load: @escaping @MainActor () async throws -> Value?) async throws -> Value? {
        bind(scope)
        if let entry = entries[id], now - entry.saved >= 0, now - entry.saved < lifetime {
            return cached(id: id, scope: scope)
        }
        let task: Task<Value?, Error>
        if let read = reads[id] { task = read.task }
        else {
            guard reads.count < capacity else { throw CancellationError() }
            let token = UUID()
            task = Task { @MainActor in
                defer {
                    if self.scope == scope, self.reads[id]?.id == token { self.reads.removeValue(forKey: id) }
                }
                try Task.checkCancellation()
                let value = try await load()
                guard self.scope == scope, self.reads[id]?.id == token else { throw CancellationError() }
                try Task.checkCancellation()
                if let value {
                    self.serial &+= 1
                    self.entries[id] = Entry(value: value, saved: Date.timeIntervalSinceReferenceDate, access: self.serial)
                    while self.entries.count > self.capacity {
                        guard let oldest = self.entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
                        self.entries.removeValue(forKey: oldest)
                    }
                }
                return value
            }
            reads[id] = (token, task)
        }
        let value = try await task.value
        guard self.scope == scope else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    }
}
