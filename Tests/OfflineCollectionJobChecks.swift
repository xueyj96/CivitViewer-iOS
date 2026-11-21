import Foundation

@MainActor final class JobGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async { if opened { return }; await withCheckedContinuation { continuation = $0 } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

// INSERT_RESOLVER

@MainActor final class SiteSession {
    var membershipCalls: [Int] = []
    var mediaCalls: [Int] = []
    var membership: (Int) async throws -> Set<Int> = { _ in [3, 8] }
    var metadata: (Int) async throws -> MediaItem? = { id in
        MediaItem(id: id, url: "https://example.invalid/item", width: nil, height: nil, type: "video", username: "target", browsingLevel: 1, thumbnail: nil)
    }
    func allSavedMembership(_ id: Int) async throws -> Set<Int> { membershipCalls.append(id); return try await membership(id) }
    func mediaItem(id: Int, includeTags: Bool) async throws -> MediaItem? {
        precondition(includeTags); mediaCalls.append(id); return try await metadata(id)
    }
}

final class OfflineWritePermit {
    var valid = true
    func invalidate() { valid = false }
    func check() throws { if !valid { throw CancellationError() } }
}

@MainActor final class OfflineJobHarness {
    enum Activity { case normal, attention }
    var records: [OfflineRecord] = []
    var omittedIDs = Set<Int>()
    var membershipVersions: [Int: Int] = [:]
    var accountID: Int? = 42
    var bindingID = UUID()
    var pausedByUser = false
    var pendingCollectionDownloadID: Int?
    var conditionalRemoval: (ids: Set<Int>, permit: OfflineWritePermit)?
    func acceptsBinding(_ scope: UUID) -> Bool { valid && scope == bindingID }
    func schedulePersist(force: Bool) { persists += 1 }
    // INSERT_ACCEPT_UPDATE
    var lastScan = Date(timeIntervalSince1970: 100)
    var valid = true
    var activity = Activity.normal
    var status = ""
    var downloads: [Int] = []
    var persists = 0
    var recordsByID: [Int: OfflineRecord] { Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }) }
    func check(_ owner: Int, _ revision: Int) throws {
        try Task.checkCancellation()
        precondition(owner == 42 && revision == 7)
        if !valid { throw CancellationError() }
    }
    func persist(force: Bool) async throws { precondition(force); persists += 1 }
    func download(_ sources: [Int: MediaItem], ids: [Int], owner: Int, revision: Int, permit: OfflineWritePermit) async throws {
        try check(owner, revision); try permit.check()
        precondition(Set(sources.keys) == Set(ids)); downloads += ids
    }
    // INSERT_SINGLE_ITEM_JOB
}

@main struct OfflineCollectionJobChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let unrelated = OfflineRecord(id: 999, video: false, username: "other", collectionIDs: [9], cloudState: .saved, fileState: .ready, bytes: 123)
        let existing = OfflineRecord(id: 123, video: true, username: "old", collectionIDs: [3], cloudState: .unknown)
        func harness() -> OfflineJobHarness { let value = OfflineJobHarness(); value.records = [existing, unrelated]; return value }
        let job = harness(), session = SiteSession(), permit = OfflineWritePermit()
        try await job.syncCollectionItem(123, session: session, owner: 42, revision: 7, permit: permit)
        check(session.membershipCalls == [123] && session.mediaCalls == [123], "A target reads only its own authorization and metadata")
        check(job.downloads == [123] && job.recordsByID[123]?.collectionIDs == [3, 8], "The requested job retains all authorized membership")
        check(job.recordsByID[999] == unrelated && job.lastScan == Date(timeIntervalSince1970: 100), "A partial result does not change another record or inventory timestamp")

        let added = OfflineJobHarness()
        try await added.syncCollectionItem(123, session: SiteSession(), owner: 42, revision: 7, permit: OfflineWritePermit())
        check(added.records.count == 1 && added.downloads == [123], "A newly saved target can download without an inventory scan")
        let removed = harness(), removedSession = SiteSession()
        removed.records[0].fileState = .ready; removed.records[0].bytes = 456
        removedSession.membership = { _ in [] }
        try await removed.syncCollectionItem(123, session: removedSession, owner: 42, revision: 7, permit: OfflineWritePermit())
        check(removedSession.mediaCalls.isEmpty && removed.downloads.isEmpty, "Confirmed missing membership does not fetch or download media")
        check(removed.recordsByID[123]?.cloudState == .localOnly && removed.recordsByID[123]?.bytes == 456 && removed.recordsByID[123]?.fileState == .ready && removed.recordsByID[999] == unrelated, "Missing membership preserves the local file and unrelated records")

        for stage in [0, 1, 2, 3] {
            let failed = harness(), failedSession = SiteSession()
            switch stage {
            case 0: failedSession.membership = { _ in throw URLError(.timedOut) }
            case 1: failedSession.metadata = { _ in throw URLError(.timedOut) }
            case 2: failedSession.metadata = { _ in nil }
            default: failedSession.metadata = { _ in MediaItem(id: 456, url: "", width: nil, height: nil, type: "image", username: nil, browsingLevel: nil, thumbnail: nil) }
            }
            do { try await failed.syncCollectionItem(123, session: failedSession, owner: 42, revision: 7, permit: OfflineWritePermit()); check(false, "Expected target lookup failure") }
            catch { check(failed.records == [existing, unrelated] && failed.downloads.isEmpty && failed.persists == 0, "A failed lookup is never treated as confirmed removal or a download source") }
        }
        for stage in [0, 1, 2, 3] {
            let stale = harness(), staleSession = SiteSession()
            if stage < 2 {
                staleSession.membership = { _ in stale.valid = false; if stage == 1 { throw URLError(.timedOut) }; return [3] }
            } else {
                staleSession.metadata = { _ in stale.valid = false; if stage == 3 { throw URLError(.timedOut) }; return nil }
            }
            do { try await stale.syncCollectionItem(123, session: staleSession, owner: 42, revision: 7, permit: OfflineWritePermit()); check(false, "An expired job must cancel") }
            catch is CancellationError { check(stale.records == [existing, unrelated] && stale.downloads.isEmpty && stale.persists == 0, "Success and failure of both reads revalidate the job before mutation") }
        }
        let updated = harness(), updatedSession = SiteSession()
        updatedSession.metadata = { _ in updated.membershipVersions[123] = 1; return nil }
        do { try await updated.syncCollectionItem(123, session: updatedSession, owner: 42, revision: 7, permit: OfflineWritePermit()); check(false, "A newer membership update wins over a stale job") }
        catch is CancellationError { check(updated.records == [existing, unrelated] && updated.downloads.isEmpty, "A target membership change cancels the stale resolution") }
        let newJob = OfflineJobHarness(), newSession = SiteSession(), metadataStarted = JobGate(), metadataRelease = JobGate()
        newSession.metadata = { id in
            metadataStarted.open(); await metadataRelease.wait()
            return MediaItem(id: id, url: "https://example.invalid/item", width: nil, height: nil, type: "image", username: "new", browsingLevel: 1, thumbnail: nil)
        }
        let newRun = Task { try await newJob.syncCollectionItem(123, session: newSession, owner: 42, revision: 7, permit: OfflineWritePermit()) }
        await metadataStarted.wait()
        newJob.accept(SavedMembershipUpdate(accountID: 42, imageID: 123, collectionIDs: []))
        metadataRelease.open()
        do { try await newRun.value; check(false, "Cancellation of a new favorite must invalidate its pending lookup") }
        catch is CancellationError {
            check(newJob.membershipVersions[123] == 1 && newJob.records.isEmpty && newJob.downloads.isEmpty && newJob.persists == 0,
                  "A real accepted cancellation during metadata lookup cannot append or download an item without an existing local record")
        }
        let omitted = harness(); omitted.omittedIDs = [123]
        try await omitted.syncCollectionItem(123, session: SiteSession(), owner: 42, revision: 7, permit: OfflineWritePermit())
        check(omitted.downloads.isEmpty && omitted.records == [existing, unrelated], "Manual omission cannot be bypassed by the resolver")
        let revoked = harness(), revokedPermit = OfflineWritePermit(); revokedPermit.valid = false
        do { try await revoked.syncCollectionItem(123, session: SiteSession(), owner: 42, revision: 7, permit: revokedPermit); check(false, "Expected revoked permit") }
        catch is CancellationError { check(revoked.records == [existing, unrelated] && revoked.downloads.isEmpty, "Revoked write permission cancels the job") }
        print("OfflineCollectionJobChecks: \(checks) regression checks passed")
    }
}
