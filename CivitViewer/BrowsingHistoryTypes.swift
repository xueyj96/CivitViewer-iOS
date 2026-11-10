import Foundation

struct HistoryRecord: Codable, Equatable, Identifiable {
    let id: Int
    var kind: MediaKind
    var authorName: String? = nil
    var creatorID: Int? = nil
    var viewedAt: Date
    var positionSeconds: Double? = nil
    var durationSeconds: Double? = nil
}

enum HistoryLane: String, Codable, CaseIterable, Identifiable {
    case recommendation, following
    var id: Self { self }
    var title: String { self == .recommendation ? "推荐" : "关注" }
}

/// Opaque site cursor captured only when the checkpoint retains the exact loaded tail.
/// Validation in Codable keeps schema-1 snapshots without this optional value readable.
struct TimelineContinuation: Codable, Equatable {
    let cursor: String?
    let capturedAt: Date
    let reachedEnd: Bool

    init?(cursor: String?, capturedAt: Date = Date(), reachedEnd: Bool) {
        guard Self.valid(cursor: cursor, capturedAt: capturedAt, reachedEnd: reachedEnd) else { return nil }
        self.cursor = cursor; self.capturedAt = capturedAt; self.reachedEnd = reachedEnd
    }
    private enum CodingKeys: String, CodingKey { case cursor, capturedAt, reachedEnd }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
        let capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        let reachedEnd = try values.decode(Bool.self, forKey: .reachedEnd)
        guard Self.valid(cursor: cursor, capturedAt: capturedAt, reachedEnd: reachedEnd) else {
            throw DecodingError.dataCorruptedError(forKey: .cursor, in: values, debugDescription: "Invalid timeline continuation")
        }
        self.cursor = cursor; self.capturedAt = capturedAt; self.reachedEnd = reachedEnd
    }
    func encode(to encoder: Encoder) throws {
        guard Self.valid(cursor: cursor, capturedAt: capturedAt, reachedEnd: reachedEnd) else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid timeline continuation"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(cursor, forKey: .cursor)
        try values.encode(capturedAt, forKey: .capturedAt)
        try values.encode(reachedEnd, forKey: .reachedEnd)
    }
    private static func valid(cursor: String?, capturedAt: Date, reachedEnd: Bool) -> Bool {
        guard capturedAt.timeIntervalSince1970.isFinite else { return false }
        if reachedEnd { return cursor == nil }
        guard let cursor, !cursor.isEmpty, cursor.utf8.count <= 8_192,
              !cursor.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !cursor.contains("://"), URLComponents(string: cursor)?.scheme == nil else { return false }
        return true
    }
}

struct TimelineCheckpoint: Codable, Equatable {
    var lane: HistoryLane
    var filter: FeedFilter
    var ids: [Int]
    var focusedID: Int
    var updatedAt: Date
    var continuation: TimelineContinuation? = nil
}

struct HistoryArchive: Codable, Equatable {
    var records: [HistoryRecord] = []
    var checkpoints: [TimelineCheckpoint] = []
    var recordingEnabled = true
}

extension HistoryArchive {
    private enum CodingKeys: String, CodingKey { case records, checkpoints, recordingEnabled }
    private struct StoredCheckpointKind: Decodable {
        struct Filter: Decodable { let kind: String }
        let filter: Filter
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decode([HistoryRecord].self, forKey: .records)
        checkpoints = try values.decode([TimelineCheckpoint].self, forKey: .checkpoints)
        recordingEnabled = try values.decode(Bool.self, forKey: .recordingEnabled)
        let stored = try values.decode([StoredCheckpointKind].self, forKey: .checkpoints)
        for index in checkpoints.indices where stored[index].filter.kind == "all" && checkpoints[index].filter.videoDurationRange == nil {
            // Preserve the original focus when a trusted visit records its actual type.
            // A cursor captured without a type cannot be reused under the new typed query.
            let focus = checkpoints[index].focusedID
            checkpoints[index].filter.kind = records.first(where: { $0.id == focus })?.kind.browsingSelection ?? .image
            checkpoints[index].continuation = nil
        }
    }
}

enum BrowsingHistoryError: LocalizedError {
    case invalidOwner, ownerMismatch, incompatibleSchema, corrupted, invalidRecord, invalidProgress, invalidCheckpoint, writeFailed
    var errorDescription: String? {
        switch self {
        case .invalidOwner: "浏览记录账号标识无效。"
        case .ownerMismatch: "浏览记录文件属于其他账号，未读取或覆盖。"
        case .incompatibleSchema: "浏览记录文件版本不受支持，原文件已保留。"
        case .corrupted: "浏览记录文件损坏或无法解码，原文件已保留。"
        case .invalidRecord: "浏览记录字段超出允许范围。"
        case .invalidProgress: "播放进度必须为有限的非负数，时长必须为正数。"
        case .invalidCheckpoint: "时间线快照超出允许范围。"
        case .writeFailed: "浏览记录暂时无法保存。"
        }
    }
}

enum PlaybackResumePolicy {
    static func waitsForDuration(position: Double?, duration: Double?) -> Bool {
        guard position != nil else { return false }
        guard let duration else { return true }
        return !duration.isFinite || duration <= 0
    }
    static func position(position: Double?, duration: Double?) -> Double? {
        guard let position, let duration, position.isFinite, duration.isFinite,
              position >= 0, duration > 0 else { return nil }
        guard duration - position > 2, position / duration < 0.98 else { return nil }
        return position
    }
}

/// Initial history position is a one-time seed. Releasing a resumed player
/// retains its latest visit position, including a completed/reset position.
struct PlaybackResumeCursor {
    private var hasRetained = false
    private var retained: Double?
    func requested(initial: Double?, recovery: Double?) -> Double? {
        recovery ?? (hasRetained ? retained : initial)
    }
    func target(initial: Double?, recovery: Double?, duration: Double) -> Double? {
        if recovery == nil, let interruptionPosition, interruptionPosition < duration {
            return interruptionPosition
        }
        return PlaybackResumePolicy.position(position: requested(initial: initial, recovery: recovery), duration: duration)
    }
    private var interruptionPosition: Double?

    mutating func capture(position: Double, duration: Double, enabled: Bool, interrupted: Bool = false) {
        guard enabled || hasRetained, position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return }
        hasRetained = true
        interruptionPosition = interrupted && position < duration ? position : nil
        retained = interruptionPosition ?? PlaybackResumePolicy.position(position: position, duration: duration)
    }
    mutating func reset() { self = Self() }
}

enum HistoryProgressPolicy {
    static func allows(qualifiedVisit: Bool, existingVideo: Bool, contextIsCurrent: Bool, recordingEnabled: Bool) -> Bool {
        contextIsCurrent && recordingEnabled && (qualifiedVisit || existingVideo)
    }
}

/// Explicit pause/play survives a temporary interruption in the same viewer;
/// a new ordinary visit still uses the user's autoplay preference.
struct PlaybackUserIntent {
    private var explicit: Bool?
    func shouldPlay(autoplay: Bool) -> Bool { explicit ?? autoplay }
    mutating func setPlaying(_ value: Bool) { explicit = value }
    mutating func reset() { explicit = nil }
}
