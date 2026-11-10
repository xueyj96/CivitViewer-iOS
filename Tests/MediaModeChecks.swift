import Foundation

@main struct MediaModeChecks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1 }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let legacy: [String: Any] = ["kind": "all", "sort": "Most Comments", "period": "AllTime", "baseModel": "Flux.1 D", "onlyPG": true]
        let bytes = try JSONSerialization.data(withJSONObject: legacy, options: .sortedKeys)
        let migrated = try decoder.decode(FeedFilter.self, from: bytes)
        check(try decoder.decode(MediaKind.self, from: Data("\"all\"".utf8)) == .all, "Migration is scoped to filters; unrelated history-kind validation keeps its original discriminator")
        let mediaPage = try decoder.decode(MediaPage.self, from: Data(#"{"items":[{"id":11,"url":"https://example.invalid/image.jpeg","type":"image"},{"id":12,"url":"https://example.invalid/video.mp4","type":"video"}],"metadata":{"nextCursor":null}}"#.utf8))
        for kind in MediaKind.browsingCases {
            var request = URLComponents(string: "https://example.invalid/api/v1/images")!
            request.queryItems = FeedFilter(kind: kind).query(cursor: "opaque:cursor")
            let built = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            check(built.queryItems?.first(where: { $0.name == "type" })?.value == kind.rawValue, "Each actual browsing request URL explicitly carries its selected media type")
            var accumulator = FeedAccumulator(); accumulator.append(mediaPage, kind: kind)
            check(accumulator.items.map(\.id) == (kind == .image ? [11] : [12]), "Wrong-kind server results cannot enter the displayed queue")
        }
        check(MediaKind.browsingCases == [.image, .video], "Every browsing picker has exactly image and video")
        check(MediaKind.browsingCases.map(\.title) == ["图片", "视频"], "Visible media labels never include mixed all")
        check(migrated.kind == .image && migrated.effectiveKind == .image, "Legacy all migrates deterministically to images")
        check(migrated.sort == "Most Comments" && migrated.period == "AllTime" && migrated.baseModel == "Flux.1 D" && migrated.onlyPG, "Migration preserves unrelated filter conditions")
        check(migrated.videoDurationRange == nil, "Legacy filters without duration stay unrestricted by duration")
        check(migrated.query().contains(.init(name: "type", value: "image")), "Migrated browsing explicitly requests images")
        check(FeedFilter().kind == .image, "First-use default is images")
        check(FeedPeriod.allTime.title == "全部时间", "All-time range remains available")
        for context in [FilterContext.discovery, .following, .creator] {
            check(FeedFilter.defaults(for: context).kind == .image, "Each default context selects one media type")
            check(FeedFilter.defaults(for: context, kind: .video).kind == .video, "Explicit video defaults stay video")
        }
        let canonical = try JSONSerialization.jsonObject(with: encoder.encode(migrated)) as! [String: Any]
        check(canonical["kind"] as? String == "image", "New persistence never writes legacy all")
        check(try decoder.decode(FeedFilter.self, from: encoder.encode(migrated)) == migrated, "Migration is idempotent")
        var durationLegacy = legacy; durationLegacy["videoDurationRange"] = ["minimumSeconds": 120]
        let durationBytes = try JSONSerialization.data(withJSONObject: durationLegacy)
        let ranged = try decoder.decode(FeedFilter.self, from: durationBytes)
        check(ranged.effectiveKind == .video && ranged.videoDurationRange?.contains(120) == true, "Old mixed filters with a video range remain videos with the exact duration boundary")
        check(ranged.query().contains(.init(name: "type", value: "video")), "A migrated duration filter always requests videos")
        check(ranged.resetting(in: .discovery).kind == .video && ranged.resetting(in: .discovery).videoDurationRange == nil, "Reset keeps the currently visible video mode while removing its duration filter")
        check(ranged.selecting(kind: .image).videoDurationRange == nil, "Selecting images clears only the incompatible duration")
        check(ranged.selecting(kind: .video).videoDurationRange == ranged.videoDurationRange, "Selecting videos retains duration")
        check(migrated.selecting(kind: .all).kind == .image, "A legacy programmatic selection cannot reintroduce mixed browsing")
        var videoLegacy = legacy; videoLegacy["kind"] = "video"
        let video = try decoder.decode(FeedFilter.self, from: JSONSerialization.data(withJSONObject: videoLegacy))
        check(video.kind == .video, "Existing explicit video choice is not reset to images")
        let suite = "com.xueyj.civitviewer.media-mode-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(bytes, forKey: "defaultDiscoveryFilter"); defaults.set(durationBytes, forKey: "defaultFollowingFilter")
        defaults.set("untouched", forKey: "unrelated-user-setting")
        check(FeedFilter.saved(defaults: defaults) == migrated, "Recommendation defaults load the migration")
        check(FeedFilter.saved(followed: true, defaults: defaults).effectiveKind == .video, "Following defaults preserve active video ranges")
        check(defaults.data(forKey: "defaultDiscoveryFilter") == bytes && defaults.data(forKey: "defaultFollowingFilter") == durationBytes, "Reading old defaults never eagerly rewrites stored data")
        video.saveDefault(followed: false, defaults: defaults)
        check(FeedFilter.saved(defaults: defaults) == video, "An explicit new selection persists across reload")
        check(defaults.data(forKey: "defaultFollowingFilter") == durationBytes && defaults.string(forKey: "unrelated-user-setting") == "untouched", "Saving one scope leaves other defaults and data untouched")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("civit-mode-presets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilterPresetStore(root: root)
        let criteria = MediaSearchCriteria(text: "City", author: Creator(id: 91, username: "Fixture", image: nil), tags: [SearchTag(id: 7, name: "portrait", nsfwLevel: 1)])
        let saved = try store.save(ownerID: 17, scope: .search, name: "Preserve my preset", snapshot: .init(filter: migrated, criteria: criteria))
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
        var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var scopes = doc["scopes"] as! [String: Any], rows = scopes["search"] as! [[String: Any]]
        var snapshot = rows[0]["snapshot"] as! [String: Any], filter = snapshot["filter"] as! [String: Any]
        filter["kind"] = "all"; snapshot["filter"] = filter; rows[0]["snapshot"] = snapshot; scopes["search"] = rows; doc["scopes"] = scopes
        let presetBytes = try JSONSerialization.data(withJSONObject: doc, options: .sortedKeys); try presetBytes.write(to: file)
        let restored = try FilterPresetStore(root: root).list(ownerID: 17, scope: .search)
        check(restored.count == 1 && restored[0].id == saved.id && restored[0].name == saved.name, "Old preset identity and name survive migration")
        check(restored[0].snapshot.filter == migrated && restored[0].snapshot.criteria == criteria, "All search criteria and unrelated filters survive the old all mode")
        check(restored[0].createdAt == saved.createdAt && restored[0].updatedAt == saved.updatedAt, "Loading migration does not alter user timestamps")
        check(try Data(contentsOf: file) == presetBytes, "Reading old presets does not rewrite the file")
        check(FilterPresetSnapshot(filter: .init(kind: .all)).filter.kind == .image, "New preset snapshots normalize the legacy selection")
        let now = Date()
        let records = [HistoryRecord(id: 1, kind: .image, viewedAt: now), HistoryRecord(id: 2, kind: .video, viewedAt: now, positionSeconds: 8, durationSeconds: 30)]
        let continuation = TimelineContinuation(cursor: "old-mixed-cursor", capturedAt: now, reachedEnd: false)!
        func archiveBytes(filter: FeedFilter, focusedID: Int, rawKind: String) throws -> Data {
            let checkpoint = TimelineCheckpoint(lane: .recommendation, filter: filter, ids: [1, 2], focusedID: focusedID, updatedAt: now, continuation: continuation)
            let archive = HistoryArchive(records: records, checkpoints: [checkpoint])
            var value = try JSONSerialization.jsonObject(with: encoder.encode(archive)) as! [String: Any]
            var rows = value["checkpoints"] as! [[String: Any]], oldFilter = rows[0]["filter"] as! [String: Any]
            oldFilter["kind"] = rawKind; rows[0]["filter"] = oldFilter; value["checkpoints"] = rows
            return try JSONSerialization.data(withJSONObject: value)
        }
        let resumedVideo = try decoder.decode(HistoryArchive.self, from: archiveBytes(filter: migrated, focusedID: 2, rawKind: "all"))
        check(resumedVideo.records == records && resumedVideo.checkpoints[0].ids == [1, 2] && resumedVideo.checkpoints[0].focusedID == 2, "Legacy resume migration preserves every history record, saved ID and focus")
        check(resumedVideo.checkpoints[0].filter.kind == .video && resumedVideo.checkpoints[0].continuation == nil, "Old mixed video focus resumes videos without reusing an untyped cursor")
        let resumedImage = try decoder.decode(HistoryArchive.self, from: archiveBytes(filter: migrated, focusedID: 1, rawKind: "all"))
        check(resumedImage.checkpoints[0].filter.kind == .image && resumedImage.checkpoints[0].continuation == nil, "Old image focus stays images and also discards the incompatible cursor")
        let explicitImage = try decoder.decode(HistoryArchive.self, from: archiveBytes(filter: migrated, focusedID: 2, rawKind: "image"))
        check(explicitImage.checkpoints[0].filter.kind == .image && explicitImage.checkpoints[0].continuation == continuation, "Existing explicit selections are never broadened to fit a mismatching focus")
        let durationResume = try decoder.decode(HistoryArchive.self, from: archiveBytes(filter: ranged, focusedID: 2, rawKind: "all"))
        check(durationResume.checkpoints[0].filter.effectiveKind == .video && durationResume.checkpoints[0].continuation == continuation, "Old duration-filtered queries already requested video, so their valid cursor remains")
        let unknownFocus = try decoder.decode(HistoryArchive.self, from: archiveBytes(filter: migrated, focusedID: 99, rawKind: "all"))
        check(unknownFocus.checkpoints[0].filter.kind == .image && unknownFocus.checkpoints[0].continuation == nil, "Unknown old focus uses the safe default without inventing media type")
        check(try decoder.decode(HistoryArchive.self, from: encoder.encode(resumedVideo)) == resumedVideo, "History migration is idempotent after a normal save")
        print("Media mode migration: \(count) checks passed")
    }
}
