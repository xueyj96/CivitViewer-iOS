import Foundation

@MainActor protocol FeedPageReading: AnyObject {
    var feedIdentity: String { get }
    var tagEvidenceIdentity: String { get }
    var siteRetryAvailableAt: Date? { get }
    func videoDurationMetadata(ids: [Int], postIDs: [Int], onlyPG: Bool) async throws -> [VideoDurationRecord]
    func mediaPage(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool, includeTags: Bool) async throws -> MediaPage
    func collectionPage(id: Int, filter: FeedFilter, cursor: String?, allAccessibleLevels: Bool, includeTags: Bool) async throws -> MediaPage
    func searchMediaPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage
}

/// Rotates through selected folders in small batches. Each folder keeps its own
/// upstream cursor and order while the feed handles deduplication and retries.
@MainActor enum CollectionSelectionPager {
    private struct Lane: Codable {
        let id: Int
        let cursor: String?
    }

    static func page(ids: Set<Int>, cursor: String?, read: (Int, String?) async throws -> MediaPage) async throws -> MediaPage {
        let lanes: [Lane]
        if let cursor {
            guard let data = Data(base64Encoded: cursor),
                  let decoded = try? JSONDecoder().decode([Lane].self, from: data),
                  !decoded.isEmpty else { throw ClientError.invalidResponse }
            let activeIDs = Set(decoded.map(\.id))
            guard activeIDs.count == decoded.count, activeIDs.isSubset(of: ids) else { throw ClientError.invalidResponse }
            lanes = decoded
        } else {
            lanes = ids.sorted().map { Lane(id: $0, cursor: nil) }
        }

        let batch = lanes.prefix(2)
        var next = Array(lanes.dropFirst(batch.count))
        var pages: [[MediaItem]] = []
        var cursorKeys: [String] = []
        for lane in batch {
            try Task.checkCancellation()
            let page = try await read(lane.id, lane.cursor)
            try Task.checkCancellation()
            if page.durationEnrichmentFailed { return page }
            pages.append(page.items)
            if let cursor = page.metadata.nextCursor {
                next.append(Lane(id: lane.id, cursor: cursor))
                cursorKeys.append("\(lane.id):\(cursor)")
            }
        }

        var items: [MediaItem] = []
        for offset in 0..<(pages.map(\.count).max() ?? 0) {
            for page in pages where offset < page.count { items.append(page[offset]) }
        }
        let token = next.isEmpty ? nil : try JSONEncoder().encode(next).base64EncodedString()
        return MediaPage(items: items, metadata: .init(nextCursor: token), collectionCursorKeys: cursorKeys)
    }
}

@MainActor protocol HistoryMediaReading: AnyObject {
    var feedIdentity: String { get }
    var followingMemberIDs: Set<Int> { get }
    func mediaItems(ids: [Int], includeTags: Bool) async throws -> [MediaItem]
    func creator(username: String) async throws -> Creator
}

@MainActor protocol TimelineReading: FeedPageReading, HistoryMediaReading {
    var account: Account? { get }
    var tagLibraryOwnerID: Int? { get }
}

// Read-only doubles and readers without duration support retain UNKNOWN values.
extension FeedPageReading {
    var tagEvidenceIdentity: String { feedIdentity }
    var siteRetryAvailableAt: Date? { nil }
    func videoDurationMetadata(ids: [Int], postIDs: [Int], onlyPG: Bool) async throws -> [VideoDurationRecord] { [] }

    /// Saved reading segments contain at most 30 works. Restore both bounded
    /// batches before applying duration policy and reusing the segment's cursor.
    func enrichRestoredVideoDurations(_ items: [MediaItem], filter: FeedFilter, isCurrent: @MainActor () -> Bool) async throws -> [MediaItem] {
        guard filter.videoDurationRange != nil else { return items }
        var result = items
        let limit = min(30, items.count)
        for start in stride(from: 0, to: limit, by: 20) {
            let end = min(start + 20, limit)
            let page = MediaPage(items: Array(items[start..<end]), metadata: .init(nextCursor: nil))
            let resolved = try await enrichVideoDurations(in: page, filter: filter, isCurrent: isCurrent)
            result.replaceSubrange(start..<end, with: resolved.items)
        }
        return result
    }

    /// At most one metadata request for the first 20 unknown videos with original post IDs.
    func enrichVideoDurations(in page: MediaPage, filter: FeedFilter, isCurrent: @MainActor () -> Bool = { true }) async throws -> MediaPage {
        guard filter.videoDurationRange != nil else { return page }
        let identity = feedIdentity
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard identity == feedIdentity, isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        let batch = VideoDurationBatch(items: page.items)
        guard !batch.ids.isEmpty else { return page }
        var result = page
        do {
            let records = try await videoDurationMetadata(ids: batch.ids, postIDs: batch.postIDs, onlyPG: filter.onlyPG)
            try checkCurrent()
            result = MediaPage(items: batch.merging(records, into: page.items), metadata: page.metadata, searchProgress: page.searchProgress)
        } catch {
            try checkCurrent()
            result.durationEnrichmentFailed = true
            if case ClientError.http(let status) = error { result.durationEnrichmentHTTPStatus = status }
        }
        return result
    }
}
