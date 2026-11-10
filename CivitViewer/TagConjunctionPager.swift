import Foundation

@MainActor protocol TagCandidateSource: AnyObject {
    var feedIdentity: String { get }
    func tagCandidates(tagID: Int, author: Creator?, filter: FeedFilter, cursor: String?, limit: Int) async throws -> MediaPage
}

/// Legacy public API paths can match any tag. Check every selected ID on a
/// single-tag lane, whose complete results already cover the intersection.
@MainActor enum TagConjunctionPager {
    static let pageSize = 100
    private struct Position: Codable {
        let identity: String
        let criteriaID: String
        let filter: FeedFilter
        let anchor: Int
        var upstream: String?
        var visited = Set<String>()
        var pages: Int
        var candidates: Int
        var matches: Int
    }
    static func page(criteria: MediaSearchCriteria, filter: FeedFilter, cursor: String?, source: any TagCandidateSource) async throws -> MediaPage {
        guard criteria.valid, criteria.normalizedText.isEmpty, criteria.tags.count > 1,
              Set(criteria.tags.map(\.id)).count == criteria.tags.count else { throw ClientError.invalidResponse }
        try Task.checkCancellation()
        var position: Position
        let raw: MediaPage
        let matches: [MediaItem]
        if let cursor {
            guard cursor.hasPrefix("tags1."), cursor.utf8.count <= 65_536,
                  let data = Data(base64Encoded: String(cursor.dropFirst(6))),
                  let value = try? JSONDecoder().decode(Position.self, from: data),
                  value.identity == source.feedIdentity, value.criteriaID == criteria.id, value.filter == filter,
                  criteria.tagIDs.contains(value.anchor), let upstream = value.upstream else { throw ClientError.accountChanged }
            position = value
            guard position.visited.insert(upstream).inserted else { throw ClientError.format("标签搜索的候选游标重复，请重新搜索。") }
            raw = try await source.tagCandidates(tagID: position.anchor, author: criteria.author, filter: filter, cursor: upstream, limit: pageSize)
            try Task.checkCancellation()
            guard position.identity == source.feedIdentity else { throw ClientError.accountChanged }
            try validate(raw, anchor: position.anchor, author: criteria.author)
            if let next = raw.metadata.nextCursor, position.visited.contains(next) { throw ClientError.format("标签搜索的候选游标重复，请重新搜索。") }
            matches = try raw.items.filter { try criteria.matches($0) }
            position.pages += 1
            position.candidates += raw.items.count
        } else {
            let identity = source.feedIdentity
            var selected: (id: Int, page: MediaPage, matches: [MediaItem])?
            var probedPages = 0
            for tag in criteria.tags {
                try Task.checkCancellation()
                let page = try await source.tagCandidates(tagID: tag.id, author: criteria.author, filter: filter, cursor: nil, limit: pageSize)
                try Task.checkCancellation()
                guard identity == source.feedIdentity else { throw ClientError.accountChanged }
                try validate(page, anchor: tag.id, author: criteria.author)
                probedPages += 1
                let candidate = (id: tag.id, page: page, matches: try page.items.filter { try criteria.matches($0) })
                if page.metadata.nextCursor == nil {
                    // Every AND match is in this exhausted lane, so other lanes cannot add a result.
                    selected = candidate
                    break
                }
                if let old = selected {
                    if candidate.matches.count * max(1, old.page.items.count) > old.matches.count * max(1, page.items.count) {
                        selected = candidate
                    }
                } else { selected = candidate }
            }
            guard let selected else { throw ClientError.invalidResponse }
            raw = selected.page
            matches = selected.matches
            position = .init(identity: identity, criteriaID: criteria.id, filter: filter, anchor: selected.id,
                             upstream: raw.metadata.nextCursor, pages: probedPages, candidates: raw.items.count, matches: 0)
        }
        position.matches += matches.count
        position.upstream = raw.metadata.nextCursor
        let next: String?
        if position.upstream != nil {
            let data = try JSONEncoder().encode(position)
            next = "tags1." + data.base64EncodedString()
        } else { next = nil }
        return .init(items: matches, metadata: .init(nextCursor: next), searchProgress: .init(pages: position.pages, candidates: position.candidates, matches: position.matches, anchorTagID: position.anchor))
    }
    private static func validate(_ page: MediaPage, anchor: Int, author: Creator?) throws {
        guard page.items.count <= pageSize,
              page.items.allSatisfy({ $0.tags?.contains(where: { $0.id == anchor }) == true }) else { throw ClientError.format("标签候选返回范围待核实，请重试。") }
        if let author, !page.items.allSatisfy({ $0.username?.lowercased() == author.username.lowercased() }) { throw ClientError.format("作者搜索返回范围不符") }
    }
}
