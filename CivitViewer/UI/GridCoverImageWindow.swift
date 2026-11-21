import SwiftUI
import Observation

@MainActor @Observable final class GridCoverImageSlot {
    private(set) var admission: GridCoverImageAdmission?
    func assign(_ admission: GridCoverImageAdmission?) {
        if self.admission?.result !== admission?.result { self.admission?.result.clear() }
        self.admission = admission
    }
}

@MainActor final class GridCoverImageAdmission {
    let ticket: Int
    let result: CachedPosterLoadResult
    init(ticket: Int, result: CachedPosterLoadResult? = nil) {
        self.ticket = ticket
        self.result = result ?? CachedPosterLoadResult()
    }
}

@MainActor private final class WeakGridCoverSlot {
    weak var value: GridCoverImageSlot?
    init(_ value: GridCoverImageSlot) { self.value = value }
}

/// Holds decoded results for at most twelve two-column rows.
/// Admission changes invalidate only the matching cell slot.
@MainActor final class GridCoverImageWindow {
    nonisolated static let visibleWindowLimit = 24
    private var enabled = false
    private var frozen = false
    private var usesActualVisibility = false
    private var visibleOrder: [Int] = []
    private var fallbackStamps: [Int: UInt64] = [:]
    private var slots: [Int: WeakGridCoverSlot] = [:]
    private var admittedIDs = Set<Int>()
    private var nextTicket = 0
    private var fallbackClock: UInt64 = 0
    private let fallbackCandidateLimit = visibleWindowLimit * 2
    private let limit: Int

    init(limit: Int = GridCoverImageWindow.visibleWindowLimit) {
        self.limit = min(Self.visibleWindowLimit, max(1, limit))
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        reconcile()
    }

    func setFrozen(_ frozen: Bool) {
        guard self.frozen != frozen else { return }
        self.frozen = frozen
        if !frozen { reconcile() }
    }

    func register(_ id: Int, slot: GridCoverImageSlot) {
        if let prior = slots[id]?.value, prior !== slot {
            prior.assign(nil)
            admittedIDs.remove(id)
        }
        slots[id] = WeakGridCoverSlot(slot)
        reconcile()
    }

    func unregister(_ id: Int, slot: GridCoverImageSlot) {
        guard slots[id]?.value === slot else { return }
        slot.assign(nil)
        slots[id] = nil
        fallbackStamps[id] = nil
        admittedIDs.remove(id)
        reconcile()
    }

    func updateVisible(_ ids: [Int]) {
        guard !frozen else { return }
        let switchedToActualVisibility = !usesActualVisibility
        usesActualVisibility = true
        fallbackStamps.removeAll(keepingCapacity: true)
        guard switchedToActualVisibility || visibleOrder != ids else { return }
        visibleOrder = ids
        reconcile()
    }

    func fallbackAppeared(_ id: Int) {
        guard !frozen, !usesActualVisibility else { return }
        fallbackClock &+= 1
        fallbackStamps[id] = fallbackClock
        if fallbackStamps.count > fallbackCandidateLimit,
           let oldest = fallbackStamps.min(by: { $0.value < $1.value })?.key {
            fallbackStamps[oldest] = nil
        }
        reconcile()
    }

    func fallbackDisappeared(_ id: Int) {
        guard !frozen, !usesActualVisibility else { return }
        fallbackStamps[id] = nil
        reconcile()
    }

    func clear() {
        enabled = false
        frozen = false
        usesActualVisibility = false
        visibleOrder = []
        fallbackStamps.removeAll(keepingCapacity: true)
        for id in admittedIDs { slots[id]?.value?.assign(nil) }
        admittedIDs.removeAll(keepingCapacity: true)
        slots.removeAll(keepingCapacity: true)
        reconcile()
    }

    private func reconcile() {
        guard !frozen else { return }
        let candidates: [Int]
        if !enabled { candidates = [] }
        else if usesActualVisibility { candidates = visibleOrder }
        else { candidates = fallbackStamps.sorted { $0.value > $1.value }.map(\.key) }
        var desired = Set<Int>()
        var orderedDesired: [Int] = []
        for id in candidates where slots[id]?.value != nil {
            guard desired.insert(id).inserted else { continue }
            orderedDesired.append(id)
            if orderedDesired.count == limit { break }
        }

        for id in admittedIDs.subtracting(desired) {
            slots[id]?.value?.assign(nil)
            admittedIDs.remove(id)
        }
        for id in orderedDesired where !admittedIDs.contains(id) {
            nextTicket &+= 1
            slots[id]?.value?.assign(GridCoverImageAdmission(ticket: nextTicket))
            admittedIDs.insert(id)
        }
    }
}
