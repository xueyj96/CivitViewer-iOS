import Foundation

@main struct GridCoverWindowChecks {
    static func main() {
        let window = GridCoverImageWindow()
        window.setEnabled(true)
        let ids = Array(1...25)
        window.updateVisible(Array(1...5))
        var slots = Dictionary(uniqueKeysWithValues: ids.map { ($0, GridCoverImageSlot()) })
        for id in ids { window.register(id, slot: slots[id]!) }
        expect(admitted(slots, ids: 1...5), "five visible items are admitted")

        window.updateVisible(ids)
        expect(admitted(slots, ids: 1...24), "first 24 of 25 visible items stay within cap")
        expect(slots[25]?.admission == nil, "25th item waits for an admission")
        let oldOne = slots[1]?.admission
        let oldTicket = oldOne?.ticket ?? 0

        window.updateVisible(Array(2...25))
        expect(admitted(slots, ids: 2...25), "newly visible 25th item is promoted when a slot opens")
        expect(slots[1]?.admission == nil, "departed item loses its admission")
        expect(oldOne?.result.clearCount == 1, "revocation clears the old task result")

        window.updateVisible(Array(26...40))
        for id in 26...40 {
            let slot = GridCoverImageSlot()
            slots[id] = slot
            window.register(id, slot: slot)
        }
        expect(admitted(slots, ids: 26...40), "fast forward admits the whole visible window")
        expect(admittedCount(slots) <= GridCoverImageWindow.visibleWindowLimit, "fast forward remains bounded")

        window.updateVisible(Array(1...10))
        let returned = slots[1]?.admission
        expect(returned != nil && returned?.ticket != oldTicket, "back navigation receives a fresh ticket")
        expect(returned?.result !== oldOne?.result, "back navigation receives a fresh result identity")

        let fallback = GridCoverImageWindow()
        fallback.setEnabled(true)
        let fallbackSlots = Dictionary(uniqueKeysWithValues: (1...30).map { ($0, GridCoverImageSlot()) })
        for id in 1...30 {
            fallback.register(id, slot: fallbackSlots[id]!)
            fallback.fallbackAppeared(id)
        }
        expect(admitted(fallbackSlots, ids: 7...30), "fallback prioritizes recent arrivals within the cap")
        fallback.updateVisible(Array(1...5))
        expect(admitted(fallbackSlots, ids: 1...5), "actual visible IDs override stale fallback appearances")
        expect(fallbackSlots[30]?.admission == nil, "offscreen early appearances cannot occupy actual visibility slots")

        let frozen = GridCoverImageWindow()
        frozen.setEnabled(true); frozen.updateVisible(ids)
        var coveredSlots = Dictionary(uniqueKeysWithValues: ids.map { ($0, GridCoverImageSlot()) })
        for id in ids { frozen.register(id, slot: coveredSlots[id]!) }
        let retained = coveredSlots[2]!.admission!
        frozen.setFrozen(true)
        frozen.updateVisible([])
        frozen.unregister(1, slot: coveredSlots[1]!)
        expect(coveredSlots[25]!.admission == nil, "a covered vacated slot must not start another request")
        let recreated = GridCoverImageSlot(); coveredSlots[1] = recreated
        frozen.register(1, slot: recreated)
        expect(recreated.admission == nil, "a recreated covered cell must wait for foreground admission")
        expect(coveredSlots[2]!.admission === retained && retained.result.clearCount == 0,
               "covering preserves the existing result and ignores transient empty visibility")
        frozen.setFrozen(false)
        expect(recreated.admission != nil, "revealing reconciles without requiring a changed enabled flag")
        expect(admittedCount(coveredSlots) == 24, "revealing preserves the same bounded capacity")
        frozen.setFrozen(true); frozen.clear()
        expect(admittedCount(coveredSlots) == 0, "actual disappearance clears even a frozen window")
        print("GridCoverWindowChecks: capacity, scroll, identity, visibility, cover retention, frozen admission, and teardown passed")
    }

    private static func admitted(_ slots: [Int: GridCoverImageSlot], ids: ClosedRange<Int>) -> Bool {
        ids.allSatisfy { slots[$0]?.admission != nil }
    }

    private static func admittedCount(_ slots: [Int: GridCoverImageSlot]) -> Int {
        slots.values.filter { $0.admission != nil }.count
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("GridCoverWindowChecks failed: \(message)") }
    }
}
