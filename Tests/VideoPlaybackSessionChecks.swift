import AVFoundation
import Foundation

@main
struct VideoPlaybackSessionChecks {
    @MainActor
    static func main() async {
        let pool = VideoPlaybackSessions.shared
        var pins = 0
        var unpins = 0
        var checks = 0

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
        }

        func waitUntil(_ description: String, timeout: TimeInterval = 5,
                       condition: @MainActor () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            print("OPTIONAL READINESS GAP: \(description) was not observed within \(timeout)s")
            return condition()
        }

        func makeKey(owner: UUID, scope: String, workID: Int, url: URL,
                     revision: String? = "fixture-v1", rootSlot: UUID? = nil) -> VideoPlaybackSessionKey {
            VideoPlaybackSessionKey(owner: owner, scope: scope, workID: workID,
                                    requestedURL: url, sourceURL: url, sourceRevision: revision,
                                    rootSlot: rootSlot)
        }

        func acquire(_ key: VideoPlaybackSessionKey) -> VideoPlaybackSessions.Entry? {
            pool.acquireCurrent(key: key, pin: { pins += 1 }, unpin: { unpins += 1 })
        }

        func waitForReady(_ entry: VideoPlaybackSessions.Entry, label: String) async -> Bool {
            await waitUntil("\(label) AVPlayerItem readiness") {
                entry.item.status == .readyToPlay && entry.player.status == .readyToPlay
            }
        }

        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        check(fixture.isFileURL && FileManager.default.fileExists(atPath: fixture.path),
              "fixture is a present local file")
        check(makeKey(owner: UUID(), scope: "legacy", workID: 0, url: fixture).rootSlot == nil,
              "rootSlot defaults to nil for existing key callers")

        // Current + one local candidate: silent loading only, with no play() calls.
        let owner = UUID()
        let currentKey = makeKey(owner: owner, scope: "feed", workID: 101, url: fixture)
        guard let current = acquire(currentKey) else { fatalError("could not acquire current playback entry") }
        current.player.isMuted = true
        check(current.valid && current.state == .active && pool.isActive(current),
              "current entry owns the active lease")
        _ = await waitForReady(current, label: "current")
        check(current.item.status == .readyToPlay && current.player.status == .readyToPlay,
              "current fixture becomes ready")

        let candidateKey = makeKey(owner: owner, scope: "feed", workID: 102, url: fixture)
        guard let candidate = pool.prepareCandidate(key: candidateKey, expectedCurrentWorkID: currentKey.workID,
                                                     pin: { pins += 1 }, unpin: { unpins += 1 }) else {
            fatalError("could not prepare local candidate")
        }
        candidate.player.isMuted = true
        check(candidate !== current && candidate.item !== current.item && candidate.player !== current.player,
              "candidate has its own player and item")
        check(pool.isActive(current) && !pool.isActive(candidate),
              "preparing candidate preserves current active lease")
        check(current.state == .active && current.player.timeControlStatus != .playing,
              "current remains active and silent")
        _ = await waitForReady(candidate, label: "candidate")
        _ = await waitUntil("candidate preroll completion", timeout: 5) {
            candidate.prerollFinished || !candidate.valid
        }
        check(candidate.valid && candidate.state == .candidate,
              "candidate remains available after readiness attempt")
        check(pool.isActive(current), "candidate readiness does not steal active lease")

        let pinsBeforeRemote = pins
        let wrongOwnerKey = makeKey(owner: UUID(), scope: "feed", workID: 103, url: fixture)
        let wrongScopeKey = makeKey(owner: owner, scope: "other-scope", workID: 103, url: fixture)
        let sameWorkKey = makeKey(owner: owner, scope: "feed", workID: currentKey.workID, url: fixture,
                                  revision: "different-work-revision")
        check(pool.prepareCandidate(key: wrongOwnerKey, expectedCurrentWorkID: currentKey.workID,
                                    pin: { pins += 1 }, unpin: { unpins += 1 }) == nil,
              "candidate from another owner is rejected")
        check(pool.prepareCandidate(key: wrongScopeKey, expectedCurrentWorkID: currentKey.workID,
                                    pin: { pins += 1 }, unpin: { unpins += 1 }) == nil,
              "candidate from another scope is rejected")
        check(pool.prepareCandidate(key: sameWorkKey, expectedCurrentWorkID: currentKey.workID,
                                    pin: { pins += 1 }, unpin: { unpins += 1 }) == nil,
              "current work cannot be prepared as its own candidate")
        let remoteURL = URL(string: "https://example.invalid/video.mp4")!
        let remoteKey = makeKey(owner: owner, scope: "feed", workID: 103, url: remoteURL)
        let remoteCandidate = pool.prepareCandidate(key: remoteKey, expectedCurrentWorkID: currentKey.workID,
                                                     pin: { pins += 1 }, unpin: { unpins += 1 })
        check(remoteCandidate == nil && pins == pinsBeforeRemote,
              "remote candidate is rejected without pinning")

        // Acquiring the candidate key promotes the existing entry without replacing its player/item.
        guard let promoted = acquire(candidateKey) else { fatalError("could not promote candidate via acquireCurrent") }
        check(promoted === candidate && promoted.player === candidate.player && promoted.item === candidate.item,
              "acquireCurrent reuses candidate entry, player, and item")
        check(pool.isActive(promoted) && !pool.isActive(current),
              "promotion gives exactly one entry the active lease")
        check(current.player.timeControlStatus != .playing,
              "previous current is paused when candidate is promoted")

        // Cover and reacquire the same key; identity and timeline must remain intact.
        let seekFinished = await promoted.player.seek(
            to: CMTime(seconds: 5, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        check(seekFinished, "silent seek establishes a nonzero retained position")
        _ = await waitUntil("position after silent seek", condition: {
            abs(promoted.player.currentTime().seconds - 5) < 0.1
        })
        let retainedTime = promoted.player.currentTime()
        check(retainedTime.isNumeric && retainedTime.seconds > 4.9,
              "entry has a nonzero position before being covered")
        pool.retainCovered(promoted)
        check(!pool.isActive(promoted) && promoted.state == .coveredPaused,
              "covered entry releases active qualification")
        guard let reacquired = acquire(candidateKey) else { fatalError("could not reacquire covered entry") }
        check(reacquired === promoted && reacquired.player === promoted.player && reacquired.item === promoted.item,
              "reacquiring covered entry reuses player and item")
        check(CMTimeCompare(reacquired.player.currentTime(), retainedTime) == 0,
              "reacquiring covered entry preserves its position")

        // Same owner/scope with a changed identity for one work retires only that work's old entry.
        let changedCurrentKey = makeKey(owner: owner, scope: "feed", workID: 102,
                                        url: fixture, revision: "fixture-v2")
        guard let changedCurrent = acquire(changedCurrentKey) else { fatalError("could not acquire changed work identity") }
        check(!reacquired.valid && pool.lookup(key: candidateKey) == nil,
              "changed identity retires old entry for the same work")
        check(current.valid && pool.lookup(key: currentKey) === current,
              "same-scope entry for another work is preserved")
        pool.release(changedCurrent)

        // A scope change retires all old-scope entries for this owner, but leaves another owner alone.
        let otherOwner = UUID()
        let otherOwnerKey = makeKey(owner: otherOwner, scope: "feed", workID: 201, url: fixture)
        guard let otherOwnerEntry = acquire(otherOwnerKey) else { fatalError("could not acquire second owner") }
        let newScopeKey = makeKey(owner: owner, scope: "detail", workID: 102, url: fixture)
        guard let newScopeEntry = acquire(newScopeKey) else { fatalError("could not acquire changed scope") }
        check(!current.valid && !changedCurrent.valid,
              "scope change retires prior-scope entries for that owner")
        check(otherOwnerEntry.valid && pool.lookup(key: otherOwnerKey) === otherOwnerEntry,
              "scope change preserves entries belonging to another owner")
        check(pool.isActive(newScopeEntry) && !pool.isActive(otherOwnerEntry),
              "scope change leaves one active lease")

        pool.reset()
        check(pool.entries.isEmpty, "reset empties pool")
        check(pins == unpins, "reset balances all pins and unpins")
        let pinsAfterReset = pins
        let unpinsAfterReset = unpins
        pool.reset()
        check(pins == pinsAfterReset && unpins == unpinsAfterReset,
              "repeated reset is idempotent for pin ownership")

        // A -> B focus handoff must commit before B may prepare C.
        let focusOwner = UUID()
        let focusScope = "focus-feed:timeline"
        let focusAKey = makeKey(owner: focusOwner, scope: focusScope, workID: 151, url: fixture)
        let focusBKey = makeKey(owner: focusOwner, scope: focusScope, workID: 152, url: fixture)
        let focusCKey = makeKey(owner: focusOwner, scope: focusScope, workID: 153, url: fixture)
        guard let focusA = acquire(focusAKey) else { fatalError("could not acquire focus A") }
        _ = await waitForReady(focusA, label: "focus A")
        guard let candidateB = pool.prepareCandidate(
            key: focusBKey, expectedCurrentWorkID: focusAKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 }) else {
            fatalError("could not prepare focus B")
        }
        let candidateBPlayer = candidateB.player
        let candidateBItem = candidateB.item
        let prematureC = pool.prepareCandidate(
            key: focusCKey, expectedCurrentWorkID: focusBKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 })
        check(prematureC == nil && candidateB.valid && pool.lookup(key: focusBKey) === candidateB,
              "B cannot prepare C before B owns focus; candidate B is retained")
        guard let focusB = acquire(focusBKey) else { fatalError("could not acquire focus B") }
        check(focusB === candidateB && focusB.player === candidateBPlayer && focusB.item === candidateBItem
              && pool.isActive(focusB),
              "acquiring B commits focus while preserving candidate B player and item")
        _ = await waitForReady(focusB, label: "focus B after acquisition")
        guard let candidateC = pool.prepareCandidate(
            key: focusCKey, expectedCurrentWorkID: focusBKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 }) else {
            fatalError("could not prepare C after B acquired focus")
        }
        check(candidateC.valid && candidateC.state == .candidate && pool.isActive(focusB)
              && focusB.player === candidateBPlayer && focusB.item === candidateBItem,
              "C preparation succeeds after B owns focus without replacing B")
        pool.reset()
        check(pins == unpins, "focus handoff cleanup balances pins")

        // A speculative candidate cannot evict a retained covered entry; a real current can.
        let coveredOwner = UUID()
        let coveredCurrentKey = makeKey(owner: coveredOwner, scope: "s", workID: 11, url: fixture)
        guard let covered = acquire(coveredCurrentKey) else { fatalError("could not acquire covered-stage current") }
        _ = await waitForReady(covered, label: "covered-stage current")
        pool.retainCovered(covered)
        let secondCurrentKey = makeKey(owner: coveredOwner, scope: "s", workID: 12, url: fixture)
        guard let secondCurrent = acquire(secondCurrentKey) else { fatalError("could not acquire second current") }
        _ = await waitForReady(secondCurrent, label: "second current")
        let coveredStagePins = pins
        let blockedCandidate = pool.prepareCandidate(
            key: makeKey(owner: coveredOwner, scope: "s", workID: 13, url: fixture),
            expectedCurrentWorkID: secondCurrentKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 })
        check(blockedCandidate == nil && pins == coveredStagePins,
              "candidate does not evict a covered entry to make room")
        guard let replacementCurrent = acquire(makeKey(owner: coveredOwner, scope: "s", workID: 13, url: fixture)) else {
            fatalError("real current could not use covered-entry capacity")
        }
        check(replacementCurrent.valid && !covered.valid && pool.entries.count == VideoPlaybackSessions.capacity,
              "real current may evict a covered entry within capacity")
        pool.reset()
        check(pins == unpins, "covered-entry cleanup balances pins")

        // Capacity is global across owners; memory pressure keeps only the active entry.
        let capacityOwnerA = UUID()
        let capacityOwnerB = UUID()
        let capacityOwnerC = UUID()
        guard let entryA = acquire(makeKey(owner: capacityOwnerA, scope: "s", workID: 1, url: fixture)),
              let entryB = acquire(makeKey(owner: capacityOwnerB, scope: "s", workID: 2, url: fixture)) else {
            fatalError("could not fill pool across owners")
        }
        check(pool.entries.count == VideoPlaybackSessions.capacity && entryA.valid && entryB.valid,
              "capacity of two is shared across owners")
        guard let entryC = acquire(makeKey(owner: capacityOwnerC, scope: "s", workID: 3, url: fixture)) else {
            fatalError("could not acquire third owner within capacity")
        }
        _ = await waitForReady(entryC, label: "capacity active entry")
        check(pool.entries.count == VideoPlaybackSessions.capacity && entryC.valid,
              "third owner acquisition stays within pool capacity")
        check(!(entryA.valid && entryB.valid), "capacity eviction retires an inactive owner entry")
        let beforePressure = Set(pool.entries.map(\.token))
        pool.handleMemoryPressure()
        check(pool.entries.count == 1 && pool.isActive(entryC) && entryC.valid,
              "memory pressure keeps the active entry and retires inactive entries")
        check(beforePressure.contains(entryC.token), "active entry existed before memory pressure")

        // Memory pressure suppresses speculative work until the active key changes.
        let pinsBeforeSuppressedCandidate = pins
        let suppressedCandidate = pool.prepareCandidate(
            key: makeKey(owner: capacityOwnerC, scope: "s", workID: 4, url: fixture),
            expectedCurrentWorkID: entryC.key.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 })
        check(suppressedCandidate == nil && pins == pinsBeforeSuppressedCandidate,
              "memory pressure suppresses candidate preparation without pinning")
        pool.retainCovered(entryC)
        guard let sameKeyReacquired = acquire(entryC.key) else {
            fatalError("could not reacquire covered entry after memory pressure")
        }
        check(sameKeyReacquired === entryC && pool.isActive(entryC),
              "same-key reacquisition reuses the retained entry after memory pressure")
        let pinsAfterSameKeyReacquire = pins
        let stillSuppressedCandidate = pool.prepareCandidate(
            key: makeKey(owner: capacityOwnerC, scope: "s", workID: 4, url: fixture),
            expectedCurrentWorkID: entryC.key.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 })
        check(stillSuppressedCandidate == nil && pins == pinsAfterSameKeyReacquire,
              "same-key reacquisition does not clear memory-pressure candidate suppression")
        let nextActiveKey = makeKey(owner: capacityOwnerC, scope: "s", workID: 5, url: fixture)
        guard let nextActive = acquire(nextActiveKey) else { fatalError("could not activate a new key after pressure") }
        _ = await waitForReady(nextActive, label: "post-pressure active entry")

        pool.setForegroundBusy(nextActive, true)
        let pinsWhileBusy = pins
        let busyCandidate = pool.prepareCandidate(
            key: makeKey(owner: capacityOwnerC, scope: "s", workID: 6, url: fixture),
            expectedCurrentWorkID: nextActiveKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 })
        check(busyCandidate == nil && pins == pinsWhileBusy,
              "foreground-busy current suppresses speculative candidate preparation")
        pool.setForegroundBusy(nextActive, false)

        // Background suspends the active lease and removes any candidate.
        guard let backgroundCandidate = pool.prepareCandidate(
            key: makeKey(owner: capacityOwnerC, scope: "s", workID: 7, url: fixture),
            expectedCurrentWorkID: nextActiveKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 }) else {
            fatalError("could not prepare background candidate")
        }
        backgroundCandidate.player.isMuted = true
        pool.suspendForBackground()
        check(pool.entries.count == 1 && !backgroundCandidate.valid,
              "background suspension removes candidate")
        check(nextActive.valid && nextActive.state == .readyPaused && !pool.isActive(nextActive),
              "background suspension clears active qualification")
        check(pool.entries.allSatisfy { $0.player.timeControlStatus != .playing },
              "background suspension pauses every remaining player")

        pool.reset()
        check(pool.entries.isEmpty && pins == unpins,
              "final cleanup leaves no entries and balances pins")

        // Root departure requires both the exact slot and feed identity prefix boundary.
        let rootOwner = UUID()
        let rootSlot = UUID()
        let rootScope = "feed-alpha:timeline"
        let rootCurrentKey = makeKey(owner: rootOwner, scope: rootScope, workID: 301,
                                     url: fixture, rootSlot: rootSlot)
        guard let rootCurrent = acquire(rootCurrentKey) else { fatalError("could not acquire root current") }
        _ = await waitForReady(rootCurrent, label: "root current")
        let nilSlotCandidateKey = makeKey(owner: rootOwner, scope: rootScope, workID: 302, url: fixture)
        guard let nilSlotCandidate = pool.prepareCandidate(
            key: nilSlotCandidateKey, expectedCurrentWorkID: rootCurrentKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 }) else {
            fatalError("could not prepare default nil-slot candidate")
        }
        let wrongSlot = UUID()
        pool.pauseForRootDeparture(rootSlot: wrongSlot, feedIdentity: "feed-alpha")
        check(pool.isActive(rootCurrent) && rootCurrent.state == .active && nilSlotCandidate.valid,
              "wrong root slot leaves active entry and candidate unchanged")
        pool.pauseForRootDeparture(rootSlot: rootSlot, feedIdentity: "feed-alphabeta")
        check(pool.isActive(rootCurrent) && rootCurrent.state == .active && nilSlotCandidate.valid,
              "nonmatching feed identity prefix leaves entries unchanged")
        pool.pauseForRootDeparture(rootSlot: rootSlot, feedIdentity: "feed-alpha")
        check(rootCurrent.state == .rootPaused && !pool.isActive(rootCurrent),
              "matching root slot and feed identity pauses active into rootPaused")
        check(nilSlotCandidate.valid && pool.lookup(key: nilSlotCandidateKey) === nilSlotCandidate,
              "root departure preserves a candidate without the matching root slot")
        check(pool.hasRootPaused(owner: rootOwner, rootSlot: rootSlot),
              "rootPaused entry is discoverable by owner and slot")
        check(!pool.isActive(rootCurrent),
              "root-paused entry has no active-event qualification before reacquisition")
        check(rootCurrent.player.timeControlStatus != .playing,
              "root departure pauses the retained player")

        guard let restoredRootCurrent = acquire(rootCurrentKey) else {
            fatalError("could not reacquire root-paused entry")
        }
        check(restoredRootCurrent === rootCurrent && restoredRootCurrent.player === rootCurrent.player
              && restoredRootCurrent.item === rootCurrent.item && restoredRootCurrent.state == .active
              && pool.isActive(restoredRootCurrent),
              "same-key reacquisition restores rootPaused entry without replacing player or item")
        pool.reset()

        // A same-slot candidate is removed by departure; rootPaused is reclaimable by candidate capacity.
        let candidateRootOwner = UUID()
        let candidateRootSlot = UUID()
        let candidateRootScope = "feed-beta:detail"
        let candidateRootKey = makeKey(owner: candidateRootOwner, scope: candidateRootScope,
                                       workID: 311, url: fixture, rootSlot: candidateRootSlot)
        guard let candidateRootCurrent = acquire(candidateRootKey) else {
            fatalError("could not acquire candidate-root current")
        }
        _ = await waitForReady(candidateRootCurrent, label: "candidate-root current")
        let sameSlotCandidateKey = makeKey(owner: candidateRootOwner, scope: candidateRootScope,
                                           workID: 312, url: fixture, rootSlot: candidateRootSlot)
        guard let sameSlotCandidate = pool.prepareCandidate(
            key: sameSlotCandidateKey, expectedCurrentWorkID: candidateRootKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 }) else {
            fatalError("could not prepare same-slot candidate")
        }
        pool.pauseForRootDeparture(rootSlot: candidateRootSlot, feedIdentity: "feed-beta")
        check(candidateRootCurrent.state == .rootPaused && !pool.isActive(candidateRootCurrent),
              "same-slot root departure clears the active lease")
        check(!sameSlotCandidate.valid && pool.lookup(key: sameSlotCandidateKey) == nil,
              "same-slot candidate is removed on root departure")

        guard let restoredCandidateRoot = acquire(candidateRootKey) else {
            fatalError("could not reacquire root-paused current")
        }
        check(restoredCandidateRoot === candidateRootCurrent,
              "root-paused current remains reusable before eviction")
        pool.pauseForRootDeparture(rootSlot: candidateRootSlot, feedIdentity: "feed-beta")
        let replacementRootKey = makeKey(owner: candidateRootOwner, scope: candidateRootScope,
                                         workID: 313, url: fixture, rootSlot: candidateRootSlot)
        guard let replacementRootCurrent = acquire(replacementRootKey) else {
            fatalError("could not acquire replacement root current")
        }
        _ = await waitForReady(replacementRootCurrent, label: "replacement root current")
        let evictionCandidateKey = makeKey(owner: candidateRootOwner, scope: candidateRootScope,
                                           workID: 314, url: fixture, rootSlot: candidateRootSlot)
        guard let evictionCandidate = pool.prepareCandidate(
            key: evictionCandidateKey, expectedCurrentWorkID: replacementRootKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 }) else {
            fatalError("candidate could not reclaim rootPaused capacity")
        }
        check(!candidateRootCurrent.valid && evictionCandidate.valid && replacementRootCurrent.valid,
              "candidate capacity may evict rootPaused but keeps active entry")
        pool.reset()

        // Covered entries survive root departure and remain protected from speculative eviction.
        let coveredRootOwner = UUID()
        let coveredRootSlot = UUID()
        let coveredRootScope = "feed-gamma:grid"
        let coveredRootKey = makeKey(owner: coveredRootOwner, scope: coveredRootScope,
                                     workID: 321, url: fixture, rootSlot: coveredRootSlot)
        guard let coveredRoot = acquire(coveredRootKey) else { fatalError("could not acquire covered root entry") }
        _ = await waitForReady(coveredRoot, label: "covered root entry")
        pool.retainCovered(coveredRoot)
        pool.pauseForRootDeparture(rootSlot: coveredRootSlot, feedIdentity: "feed-gamma")
        check(coveredRoot.valid && coveredRoot.state == .coveredPaused && !pool.isActive(coveredRoot),
              "root departure does not downgrade a covered entry")
        let coveredRootActiveKey = makeKey(owner: coveredRootOwner, scope: coveredRootScope,
                                           workID: 322, url: fixture, rootSlot: coveredRootSlot)
        guard let coveredRootActive = acquire(coveredRootActiveKey) else {
            fatalError("could not acquire active entry beside covered root entry")
        }
        _ = await waitForReady(coveredRootActive, label: "active beside covered root")
        let candidateBlockedByCovered = pool.prepareCandidate(
            key: makeKey(owner: coveredRootOwner, scope: coveredRootScope,
                         workID: 323, url: fixture, rootSlot: coveredRootSlot),
            expectedCurrentWorkID: coveredRootActiveKey.workID,
            pin: { pins += 1 }, unpin: { unpins += 1 })
        check(candidateBlockedByCovered == nil && coveredRoot.valid,
              "candidate cannot evict covered entry after root departure")
        pool.reset()

        // Root-slot retirement is token-scoped and leaves legacy entries without a slot alone.
        let retireSlot = UUID()
        let retiredOwner = UUID()
        let otherOwnerWithoutSlot = UUID()
        guard let slotEntry = acquire(makeKey(owner: retiredOwner, scope: "feed-delta:root", workID: 331,
                                              url: fixture, rootSlot: retireSlot)),
              let noSlotEntry = acquire(makeKey(owner: otherOwnerWithoutSlot, scope: "legacy", workID: 332,
                                                url: fixture)) else {
            fatalError("could not prepare root-slot retirement entries")
        }
        pool.retireRootSlots([retireSlot])
        check(!slotEntry.valid && pool.lookup(key: slotEntry.key) == nil,
              "retireRootSlots removes entries with the requested token")
        check(noSlotEntry.valid && pool.lookup(key: noSlotEntry.key) === noSlotEntry,
              "retireRootSlots preserves another owner entry without a root slot")
        pool.reset()

        let slotA = UUID()
        let slotB = UUID()
        guard let slotAEntry = acquire(makeKey(owner: UUID(), scope: "feed-epsilon:a", workID: 341,
                                               url: fixture, rootSlot: slotA)),
              let slotBEntry = acquire(makeKey(owner: UUID(), scope: "feed-zeta:b", workID: 342,
                                               url: fixture, rootSlot: slotB)) else {
            fatalError("could not prepare distinct root-slot entries")
        }
        pool.retireRootSlots([slotA])
        check(!slotAEntry.valid && slotBEntry.valid && pool.lookup(key: slotBEntry.key) === slotBEntry,
              "retireRootSlots preserves entries assigned to other tokens")
        pool.reset()
        check(pool.entries.isEmpty && pins == unpins,
              "root-slot lifecycle cleanup balances all pins")

        print("PASS: \(checks) native playback pool checks")
        print("PREROLL: \(candidate.prerollFinished ? "finished" : "not observed; optional readiness gap")")
    }
}
