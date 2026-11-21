import Foundation
import Combine

// INSERT_PROJECTION_TYPES

private struct OfflineWritePermit: Sendable {
    func check() throws {}
}

@MainActor private final class FileVerificationQueue {
    var beforeOperation: (() -> Void)?

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) -> Task<T, Error> {
        Task {
            beforeOperation?()
            return try await Task.detached(operation: operation).value
        }
    }
}

@MainActor final class OfflineLibrary: ObservableObject {
    static let shared = OfflineLibrary()

    enum CollectionDownloadState: Equatable {
        case waiting, downloading(Double?), paused, failed
    }

    @Published var bindingID = UUID()
    @Published var accountID: Int?
    @Published var loading = false
    @Published var records: [OfflineRecord] = [] {
        didSet { recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    var recordsByID: [Int: OfflineRecord] = [:]
    @Published var posterIDs = Set<Int>()
    @Published var currentID: Int?
    @Published var busy = false
    @Published var progress: Double?
    @Published var pausedTaskID: Int?
    @Published var pausedByUser = false
    var directory: URL?
    private let files = FileVerificationQueue()
    private let bindingPermit = OfflineWritePermit()

    private func acceptsBinding(_ scope: UUID) -> Bool { bindingID == scope }

    func beforeVerification(_ handler: @escaping () -> Void) { files.beforeOperation = handler }

    // INSERT_COLLECTION_CONTENT_STATE

    func collectionDownloadState(_ id: Int, owner: Int?) -> CollectionDownloadState? {
        guard let owner, accountID == owner, !loading else { return nil }
        guard let record = recordsByID[id] else { return .waiting }
        if record.fileState == .ready { return nil }
        if currentID == id && busy { return .downloading(progress) }
        if record.fileState == .failed { return .failed }
        if pausedByUser || pausedTaskID == id { return .paused }
        return .waiting
    }
}

// INSERT_PROJECTION

@main struct OfflineCollectionProjectionChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            if !value { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)) }
            precondition(value, message)
            checks += 1
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        func work(_ id: Int) -> MediaItem {
            MediaItem(id: id, url: "https://example.invalid/\(id)", width: nil, height: nil, type: "image",
                      username: "u\(id)", browsingLevel: 1, thumbnail: nil, creatorID: 7)
        }
        func record(_ id: Int, state: OfflineFileState = .ready, video: Bool = false) -> OfflineRecord {
            OfflineRecord(id: id, video: video, username: "u\(id)", creatorID: 7,
                          browsingLevel: 1, collectionIDs: [3], cloudState: .saved, fileState: state)
        }

        let library = OfflineLibrary()
        let directory = URL(fileURLWithPath: "/tmp/offline-projection-fixture", isDirectory: true)
        library.directory = directory
        library.accountID = 42
        library.records = [record(101, video: true)]
        library.posterIDs = [101]
        let ready = OfflineCollectionContentProjection(workID: 101, owner: 42, library: library)
        let readyState = ready.state
        check(readyState.mediaURL == directory.appendingPathComponent("101.mp4"), "Ready init resolves media URL synchronously")
        check(readyState.posterURL == directory.appendingPathComponent("101.poster.img"), "Ready init resolves declared local poster synchronously")
        check(readyState.bindingID == library.bindingID && readyState.downloadState == nil,
              "Ready projection carries its binding and no download badge")
        let localItem = readyState.displayItem(MediaItem(id: 101, url: "https://example.invalid/v", width: nil,
                                                         height: nil, type: "video", username: "u101", browsingLevel: 1,
                                                         thumbnail: .init(url: "https://example.invalid/poster"), creatorID: 7))
        check(localItem.mediaURL == readyState.mediaURL && localItem.posterURL == readyState.posterURL && localItem.collectionLocalPlayback,
              "Display item uses the local media and poster")

        library.posterIDs = []
        let noLocalPoster = OfflineCollectionContentProjection(workID: 101, owner: 42, library: library)
        let sourcePoster = URL(string: "https://example.invalid/original-poster")!
        let preservedPoster = noLocalPoster.state.displayItem(MediaItem(id: 101, url: "https://example.invalid/v", width: nil,
                                                                         height: nil, type: "video", username: "u101", browsingLevel: 1,
                                                                         thumbnail: .init(url: sourcePoster.absoluteString), creatorID: 7))
        check(noLocalPoster.state.posterURL == nil, "Absent local poster remains absent in the projection")
        check(preservedPoster.posterURL == sourcePoster, "Missing local poster preserves the input poster")

        library.records = [record(101, state: .pending), record(202, state: .pending)]
        library.currentID = 202
        library.busy = true
        library.progress = 0.1
        let current = OfflineCollectionContentProjection(workID: 202, owner: 42, library: library)
        let other = OfflineCollectionContentProjection(workID: 101, owner: 42, library: library)
        check(current.state.downloadState == .downloading(0.1), "Current work starts with the existing progress value")
        check(other.state.downloadState == .waiting, "A different pending work remains waiting")
        var currentPublications = 0
        var otherPublications = 0
        let currentToken = current.$state.dropFirst().sink { _ in currentPublications += 1 }
        let otherToken = other.$state.dropFirst().sink { _ in otherPublications += 1 }
        library.progress = 0.2
        await settle()
        check(otherPublications == 0, "Non-current work ignores progress broadcasts")
        check(current.state.downloadState == .downloading(0.2) && currentPublications == 1,
              "Current work publishes its progress update")

        library.currentID = 101
        await settle()
        currentPublications = 0
        otherPublications = 0
        library.progress = 0.3
        await settle()
        check(currentPublications == 0, "Previous current work unsubscribes from later progress")
        check(other.state.downloadState == .downloading(0.3) && otherPublications == 1,
              "New current work receives its active download state")

        let pendingLibrary = OfflineLibrary()
        pendingLibrary.directory = directory
        pendingLibrary.accountID = 42
        pendingLibrary.records = [record(303, state: .pending)]
        let pending = OfflineCollectionContentProjection(workID: 303, owner: 42, library: pendingLibrary)
        check(pending.state.mediaURL == nil, "Pending record has no local media URL")
        var recordsPublisherSawPrecommitIndex = false
        let precommitToken = pendingLibrary.$records.dropFirst().sink { _ in
            recordsPublisherSawPrecommitIndex = pendingLibrary.recordsByID[303]?.fileState == .pending
        }
        pendingLibrary.records = [record(303)]
        check(recordsPublisherSawPrecommitIndex, "Published records emits before the didSet index commit")
        await settle()
        check(pending.state.mediaURL == directory.appendingPathComponent("303.img"),
              "Projection yields past willSet and reads the committed ready index")

        let wrongOwner = OfflineCollectionContentProjection(workID: 303, owner: 7, library: pendingLibrary)
        check(wrongOwner.state.mediaURL == nil && wrongOwner.state.downloadState == nil,
              "Owner mismatch cannot expose another account's local resource")
        let priorBinding = pending.state.bindingID
        pendingLibrary.bindingID = UUID()
        await settle()
        check(pending.state.bindingID != priorBinding, "Binding replacement refreshes the work projection")
        check(pending.state.mediaURL == directory.appendingPathComponent("303.img"),
              "New binding preserves ready resource lookup for the same owner")

        let loadingLibrary = OfflineLibrary()
        loadingLibrary.accountID = 42
        loadingLibrary.loading = true
        let waiting = OfflineCollectionContentProjection(workID: 404, owner: 42, library: loadingLibrary)
        check(waiting.state.downloadState == nil, "Loading index temporarily suppresses download badge state")
        loadingLibrary.loading = false
        await settle()
        check(waiting.state.downloadState == .waiting, "Loading completion wakes the waiting badge")

        weak var releasedProjection: OfflineCollectionContentProjection?
        do {
            let shortLived = OfflineCollectionContentProjection(workID: 505, owner: 42, library: loadingLibrary)
            releasedProjection = shortLived
            check(releasedProjection === shortLived, "Projection exists while owned by its caller")
        }
        await settle()
        check(releasedProjection == nil, "Projection subscriptions do not create a global strong cache")

        let playbackLibrary = OfflineLibrary()
        playbackLibrary.accountID = 42
        playbackLibrary.directory = directory
        playbackLibrary.records = [record(701), record(702, state: .pending), record(703)]
        let works = [work(703), work(702), work(701), work(704)]
        let playback = await playbackLibrary.localCollectionPlayback(works, openingID: 701, owner: 42)
        check(playback?.items.map(\.id) == [703, 701] && playback?.opening.id == 701,
              "Playback retains displayed order and skips works without a ready file")
        check(playback?.items.allSatisfy { $0.collectionLocalPlayback && $0.mediaURL?.isFileURL == true } == true,
              "Projected playback queue resolves only local media")
        let missing = await playbackLibrary.localCollectionPlayback(works, openingID: 702, owner: 42)
        let wrongPlaybackOwner = await playbackLibrary.localCollectionPlayback(works, openingID: 701, owner: 7)
        check(missing == nil && wrongPlaybackOwner == nil, "Playback rejects pending openings and other accounts")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        playbackLibrary.directory = temporary
        let file = temporary.appendingPathComponent("701.img")
        let beforeSave = await playbackLibrary.verifiedCollectionMediaURL(701, owner: 42)
        check(beforeSave == nil, "Ready metadata alone is insufficient when the selected file is missing")
        try! Data([1]).write(to: file)
        let present = await playbackLibrary.verifiedCollectionMediaURL(701, owner: 42)
        let wrongVerificationOwner = await playbackLibrary.verifiedCollectionMediaURL(701, owner: 7)
        check(present == file && wrongVerificationOwner == nil, "Selected file verification is scoped to the account")
        playbackLibrary.beforeVerification { [weak playbackLibrary] in playbackLibrary?.bindingID = UUID() }
        let stale = await playbackLibrary.verifiedCollectionMediaURL(701, owner: 42)
        check(stale == nil, "A file verification finishing after a binding change cannot reopen the old account")

        withExtendedLifetime([currentToken, otherToken, precommitToken]) {}
        print("OfflineCollectionProjectionChecks: \(checks) projection, progress, playback, file verification and lifetime checks passed")
    }
}
