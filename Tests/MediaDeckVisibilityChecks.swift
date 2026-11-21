import Foundation

private struct VisibilityBenchmarkReport: Codable {
    struct SizeResult: Codable {
        let sourceCount: Int
        let visibleCount: Int
        let oracleMatches: Bool
        let repeatedReadBuilds: Int
    }
    let checks: Int
    let sizes: [SizeResult]
    let repeatedReads: Int
    let repeatedFilterMilliseconds: Double
    let repeatedResolveMilliseconds: Double
    let buildsAfterRepeatedResolve: Int
    let checksum: Int
}

@main
struct MediaDeckVisibilityChecks {
    @MainActor
    static func main() throws {
        var checkCount = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checkCount += 1
        }
        func row(_ id: Int, urlSuffix: String? = nil, username: String? = "artist", creatorID: Int? = 50,
                 tags: [MediaTag]? = [.init(name: "clear")], type: String? = "image",
                 poster: String? = nil, duration: Double? = nil) -> MediaItem {
            MediaItem(id: id, url: "https://fixture.invalid/media/\(urlSuffix ?? String(id))",
                      width: 1024, height: 768, type: type, username: username,
                      browsingLevel: 1, thumbnail: poster.map { .init(url: $0) }, creatorID: creatorID,
                      tags: tags, metadata: duration.map { VideoTechnicalMetadata(duration: $0) })
        }
        func originalFilter(_ rows: [MediaItem], blockedTags: Set<String>, authors: [BlockedAuthor]) -> [MediaItem] {
            let blockedIDs = Set(authors.map(\.id))
            let byHandle = Dictionary(grouping: authors, by: { AuthorHandlePolicy.normalize($0.username) })
            let blockedHandles = Set(byHandle.compactMap { handle, matches in matches.count == 1 ? handle : nil })
            return rows.filter {
                !AuthorHandlePolicy.blocks(creatorID: $0.creatorID, username: $0.username,
                                           blockedIDs: blockedIDs, blockedHandles: blockedHandles) &&
                    TagPolicy.verdict(names: $0.tagNames, blocked: blockedTags) == .allowed
            }
        }

        let baseline = [row(1), row(2, tags: nil), row(3, tags: []), row(4, tags: [.init(name: "blocked")])]
        let memo = MediaDeckVisibility()
        let first = memo.resolve(items: baseline, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(first.items.map(\.id) == [1, 3] && first.ids == [1, 3] && first.idsWithEnd == [1, 3, -2],
              "Initial projection preserves source order, allowed empty tags, blocked tags, and unknown-tag fail-closed behavior")
        check(memo.projectionBuilds == 1, "First read builds the projection once")
        let sameBacking = memo.resolve(items: baseline, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == 1 && sameBacking.items.map(\.id) == first.items.map(\.id),
              "Repeated reads with the same CoW source reuse the snapshot")
        let equalCopy = Array(baseline.map { $0 })
        let equalCopySnapshot = memo.resolve(items: equalCopy, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == 1 && equalCopySnapshot.items.map(\.id) == first.items.map(\.id),
              "A distinct array with equal full MediaItem contents reuses the snapshot")
        let emptySnapshot = MediaDeckVisibility().resolve(items: [], identity: "empty", blockedTags: [], authors: [])
        check(emptySnapshot.items.isEmpty && emptySnapshot.ids.isEmpty && emptySnapshot.idsWithEnd == [-2] &&
              emptySnapshot.item(id: 1) == nil && emptySnapshot.index(id: 1) == nil,
              "An empty queue has no work IDs/lookups while retaining the optional end sentinel")
        let firstInstance = MediaDeckVisibility(), secondInstance = MediaDeckVisibility()
        let firstInstanceSnapshot = firstInstance.resolve(items: baseline, identity: "account:one", blockedTags: ["blocked"], authors: [])
        let secondInstanceSnapshot = secondInstance.resolve(items: baseline, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(firstInstance.projectionBuilds == 1 && secondInstance.projectionBuilds == 1 &&
              firstInstanceSnapshot.items == secondInstanceSnapshot.items,
              "Separate MediaDeck instances build independent session-local projections")

        let completionMemo = MediaDeckVisibility()
        var completionRows = [row(5_001, tags: nil)]
        let unknownCompletion = completionMemo.resolve(items: completionRows, identity: "completion", blockedTags: ["blocked"], authors: [])
        completionRows[0] = row(5_001, tags: [.init(name: "clear")])
        let knownCompletion = completionMemo.resolve(items: completionRows, identity: "completion", blockedTags: ["blocked"], authors: [])
        check(unknownCompletion.items.isEmpty && knownCompletion.items.map(\.id) == [5_001] && completionMemo.projectionBuilds == 2,
              "Same-ID tag metadata completion from unknown to known invalidates and updates visibility")

        let offlineMemo = MediaDeckVisibility()
        var offlineRow = row(5_002)
        let offlineBefore = offlineMemo.resolve(items: [offlineRow], identity: "offline", blockedTags: [], authors: [])
        offlineRow.offlineMediaURL = URL(fileURLWithPath: "/fixture/media/offline.mp4")
        offlineRow.offlinePosterURL = URL(fileURLWithPath: "/fixture/poster/offline.jpg")
        let offlineAfter = offlineMemo.resolve(items: [offlineRow], identity: "offline", blockedTags: [], authors: [])
        check(offlineMemo.projectionBuilds == 2 && offlineBefore.items[0].mediaURL != offlineAfter.items[0].mediaURL &&
              offlineBefore.items[0].posterURL != offlineAfter.items[0].posterURL,
              "Same-ID offline media and poster URL changes invalidate the projection")

        var changedRows = baseline
        changedRows[0] = row(1, tags: [.init(name: "blocked")])
        let invalidated = memo.resolve(items: changedRows, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == 2 && invalidated.items.map(\.id) == [3],
              "Same IDs and count with changed tags invalidates projection")
        changedRows[0] = row(1, tags: [.init(name: "clear")], type: "video")
        _ = memo.resolve(items: changedRows, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == 3, "Changing media type invalidates projection")
        changedRows[0] = row(1, urlSuffix: "changed-url", type: "image")
        _ = memo.resolve(items: changedRows, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == 4, "Changing media URL invalidates projection")
        changedRows[0] = row(1, poster: "https://fixture.invalid/poster/changed")
        _ = memo.resolve(items: changedRows, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == 5, "Changing poster URL invalidates projection")
        changedRows[0] = row(1, type: "video", duration: 7.5)
        _ = memo.resolve(items: changedRows, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == 6, "Changing media metadata invalidates projection")

        let authorRows = [
            row(20, username: "Twin", creatorID: 101),
            row(21, username: " twin ", creatorID: nil),
            row(22, username: "Twin", creatorID: 999),
        ]
        let duplicateHandles = [BlockedAuthor(id: 101, username: "Twin"), BlockedAuthor(id: 102, username: " twin ")]
        let ambiguous = memo.resolve(items: authorRows, identity: "account:one", blockedTags: [], authors: duplicateHandles)
        check(ambiguous.items.map(\.id) == [21, 22],
              "Duplicate normalized blocklist handles are ambiguous while creator IDs remain authoritative")
        let uniqueHandle = [BlockedAuthor(id: 101, username: "Twin")]
        let unique = memo.resolve(items: authorRows, identity: "account:one", blockedTags: [], authors: uniqueHandle)
        check(unique.items.map(\.id) == [22], "A unique handle blocks only rows without creator IDs and matching IDs block first")
        let buildsBeforeIdentity = memo.projectionBuilds
        _ = memo.resolve(items: authorRows, identity: "account:two", blockedTags: [], authors: uniqueHandle)
        check(memo.projectionBuilds == buildsBeforeIdentity + 1,
              "Session identity change invalidates an otherwise identical source and policy")

        let frozenTags: Set<String> = ["clear"]
        let frozen = memo.resolve(items: baseline, identity: "account:one", blockedTags: frozenTags, authors: [])
        let frozenBuild = memo.projectionBuilds
        let stillFrozen = memo.resolve(items: baseline, identity: "account:one", blockedTags: frozenTags, authors: [])
        check(memo.projectionBuilds == frozenBuild && frozen.items.map(\.id) == stillFrozen.items.map(\.id),
              "An open detail keeps using its effective frozen tag snapshot")
        let afterClose = memo.resolve(items: baseline, identity: "account:one", blockedTags: ["blocked"], authors: [])
        check(memo.projectionBuilds == frozenBuild + 1 && afterClose.items.map(\.id) == [1, 3],
              "Closing details with the current tag policy rebuilds once")

        let duplicateIDs = [row(30, urlSuffix: "first"), row(30, urlSuffix: "second"), row(31)]
        let duplicates = memo.resolve(items: duplicateIDs, identity: "account:one", blockedTags: [], authors: [])
        check(duplicates.ids == [30, 30, 31] && duplicates.item(id: 30)?.url == duplicateIDs[0].url &&
              duplicates.index(id: 30) == 0 && duplicates.idsWithEnd == [30, 30, 31, -2],
              "Duplicate IDs retain original rows/order while lookup resolves the first visible item")

        let twoPageMemo = MediaDeckVisibility()
        let firstPage = (0..<20).map { row(100 + $0) }
        let secondPage = (20..<40).map { row(100 + $0) }
        let pageOne = twoPageMemo.resolve(items: firstPage, identity: "account:pages", blockedTags: [], authors: [])
        let appended = twoPageMemo.resolve(items: firstPage + secondPage, identity: "account:pages", blockedTags: [], authors: [])
        check(pageOne.ids == Array(100..<120) && appended.ids == Array(100..<140) &&
              appended.items.first?.id == 100 && appended.items.last?.id == 139,
              "A 20-row append rebuild preserves all rows and their server order")

        var sizeResults: [VisibilityBenchmarkReport.SizeResult] = []
        var checksum = 0
        let authors = [BlockedAuthor(id: 50, username: "artist"), BlockedAuthor(id: 9_999, username: "unique-author")]
        let tags: Set<String> = ["tag-03", "tag-12", "tag-27"]
        for count in [300, 3_000] {
            let rows = (0..<count).map { index -> MediaItem in
                let tagCount = 10 + index % 11
                let rowTags = (0..<tagCount).map { offset in
                    let tagID = (index + offset) % 32
                    return MediaTag(id: 70_000 + tagID, name: String(format: "tag-%02d", tagID))
                }
                return row(20_000 + index, urlSuffix: "large-\(count)-\(index)",
                           username: index % 9 == 0 ? "unique-author" : "creator-\(index % 37)",
                           creatorID: index % 9 == 0 ? 9_999 : 100 + index % 37, tags: rowTags,
                           type: index % 7 == 0 ? "video" : "image", duration: index % 7 == 0 ? 4.5 : nil)
            }
            let oracle = originalFilter(rows, blockedTags: tags, authors: authors)
            let cached = MediaDeckVisibility()
            let initialSnapshot = cached.resolve(items: rows, identity: "large:\(count)", blockedTags: tags, authors: authors)
            check(initialSnapshot.ids == oracle.map(\.id) && initialSnapshot.items == oracle,
                  "The \(count)-row candidate matches the original filter result and order")
            let buildsBeforeReads = cached.projectionBuilds
            for _ in 0..<4 {
                let read = cached.resolve(items: rows, identity: "large:\(count)", blockedTags: tags, authors: authors)
                checksum &+= read.ids.count
                check(read.items == oracle, "Repeated \(count)-row read reuses the complete expected projection")
            }
            sizeResults.append(.init(sourceCount: count, visibleCount: oracle.count,
                                     oracleMatches: initialSnapshot.items == oracle,
                                     repeatedReadBuilds: cached.projectionBuilds - buildsBeforeReads))
        }

        let timingRows = (0..<3_000).map { index -> MediaItem in
            let tagCount = 10 + index % 11
            let rowTags = (0..<tagCount).map { offset in
                let tagID = (index + offset) % 32
                return MediaTag(id: tagID, name: String(format: "tag-%02d", tagID))
            }
            return row(50_000 + index, urlSuffix: "timing-\(index)",
                       username: "creator-\(index % 41)", creatorID: 200 + index % 41, tags: rowTags)
        }
        let timingIdentity = "timing:representative"
        let repeatedReads = 40
        let filterStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repeatedReads {
            let result = originalFilter(timingRows, blockedTags: tags, authors: authors)
            checksum &+= result.count + (result.first?.id ?? 0) + (result.last?.id ?? 0)
        }
        let filterMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - filterStart) / 1_000_000
        let timingMemo = MediaDeckVisibility()
        _ = timingMemo.resolve(items: timingRows, identity: timingIdentity, blockedTags: tags, authors: authors)
        let timingBuilds = timingMemo.projectionBuilds
        let resolveStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repeatedReads {
            let result = timingMemo.resolve(items: timingRows, identity: timingIdentity, blockedTags: tags, authors: authors)
            checksum &+= result.items.count + (result.ids.first ?? 0) + (result.ids.last ?? 0)
        }
        let resolveMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - resolveStart) / 1_000_000
        check(timingMemo.projectionBuilds == timingBuilds,
              "Forty repeated getter reads build the 3,000-row projection zero additional times")

        let report = VisibilityBenchmarkReport(checks: checkCount, sizes: sizeResults,
                                              repeatedReads: repeatedReads,
                                              repeatedFilterMilliseconds: filterMilliseconds,
                                              repeatedResolveMilliseconds: resolveMilliseconds,
                                              buildsAfterRepeatedResolve: timingMemo.projectionBuilds,
                                              checksum: checksum)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
