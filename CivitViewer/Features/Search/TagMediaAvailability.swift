import Foundation
import Combine
import CryptoKit

enum TagMediaAvailabilityState: Equatable { case enough, sparse, unknown }

enum TagMediaAvailabilityReason: String {
    case thresholdReached, exhausted, pageLimit, requestFailed, http, tagMismatch, invalidMedia
    case repeatedPage, repeatedCursor, metadataMissing, contextChanged, cancelled, searchEmpty, authUnavailable
}

struct TagAvailabilityPolicy: Hashable, Sendable {
    var blockedTags: Set<String> = []
    var blockedAuthorIDs: Set<Int> = []
    var blockedAuthorHandles: Set<String> = []
    var deduplicateMediaAssets: Bool = true

    var normalizedBlockedTags: Set<String> { Set(blockedTags.map(TagPolicy.normalize)) }
    var normalizedBlockedAuthorHandles: Set<String> { Set(blockedAuthorHandles.map(AuthorHandlePolicy.normalize)) }
}

struct TagMediaAvailabilityResult: Equatable {
    let state: TagMediaAvailabilityState
    let countLowerBound: Int
    let exhausted: Bool
    let checkedAt: Date
    let reason: TagMediaAvailabilityReason
    let httpStatus: Int?
    let pages: Int
    let rawCount: Int
    let hasMore: Bool
}

/// Bounded metadata-only availability probe for tag directory rows.
@MainActor final class TagMediaAvailability: ObservableObject {
    static let shared = TagMediaAvailability(diagnostics: .shared)
    @Published private(set) var revision = 0
    private struct Key: Hashable { let identity: String; let tagID: Int; let policy: TagAvailabilityPolicy }
    private struct Entry { let result: TagMediaAvailabilityResult; let expiresAt: Date; var touched: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    private var batchActive = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let now: () -> Date
    private let maxEntries: Int
    private let maxTagsPerBatch: Int
    private let maxConcurrency: Int
    private let minimumVisible = 3
    private let requestLimit = 20
    private let maxPages = 3
    private let diagnostics: LocalDiagnosticsStore?

    init(maxEntries: Int = 256, maxTagsPerBatch: Int = 12, maxConcurrency: Int = 2, now: @escaping () -> Date = Date.init,
         diagnostics: LocalDiagnosticsStore? = nil) {
        self.maxEntries = min(256, max(1, maxEntries)); self.maxTagsPerBatch = min(12, max(1, maxTagsPerBatch))
        self.maxConcurrency = min(2, max(1, maxConcurrency)); self.now = now
        self.diagnostics = diagnostics
    }

    func result(tagID: Int, identity: String, policy: TagAvailabilityPolicy = .init()) -> TagMediaAvailabilityResult? {
        let key = Key(identity: identity, tagID: tagID, policy: policy)
        guard let entry = entries[key], entry.expiresAt > now() else { entries.removeValue(forKey: key); return nil }
        tick &+= 1; entries[key]?.touched = tick
        return entry.result
    }
    func isSparse(tagID: Int, identity: String, policy: TagAvailabilityPolicy = .init()) -> Bool { result(tagID: tagID, identity: identity, policy: policy)?.state == .sparse }
    func isRecommended(tagID: Int, identity: String, policy: TagAvailabilityPolicy = .init()) -> Bool { result(tagID: tagID, identity: identity, policy: policy)?.state == .enough }
    func recordEmptySearch(tagID: Int, identity: String, policy: TagAvailabilityPolicy) {
        guard result(tagID: tagID, identity: identity, policy: policy)?.state == .enough else { return }
        put(.init(state: .unknown, countLowerBound: 0, exhausted: true, checkedAt: now(), reason: .searchEmpty,
                  httpStatus: nil, pages: 1, rawCount: 0, hasMore: false), tagID: tagID, identity: identity, policy: policy)
    }
    func checkedCount(identity: String) -> Int {
        let keys = entries.keys.filter { $0.identity == identity }
        return keys.filter { result(tagID: $0.tagID, identity: identity, policy: $0.policy) != nil }.count
    }

    /// Callers wait for the admitted batch and recheck its cache afterwards.
    /// A cancelled owner can therefore be replaced even for identical IDs,
    /// without temporarily doubling the network concurrency.
    func verify(tags: [SearchTag], source: any TagCandidateSource, policy: TagAvailabilityPolicy = .init()) async {
        let identity = source.feedIdentity
        var seen = Set<Int>()
        let ids = tags.map(\.id).filter { $0 > 0 && seen.insert($0).inserted }
        func pending() -> [Int] { Array(ids.filter { result(tagID: $0, identity: identity, policy: policy) == nil }.prefix(maxTagsPerBatch)) }
        while batchActive {
            guard !Task.isCancelled, identity == source.feedIdentity else { return }
            guard waiters.count < 16 else { return }
            await waitForBatch()
        }
        guard !Task.isCancelled, identity == source.feedIdentity else { return }
        let candidates = pending()
        guard !candidates.isEmpty else { return }
        batchActive = true
        defer {
            batchActive = false
            let completed = Array(waiters.values); waiters.removeAll()
            completed.forEach { $0.resume() }
        }
        await withTaskGroup(of: (Int, TagMediaAvailabilityResult).self) { group in
            var next = 0
            func add(_ id: Int) { group.addTask {
                return (id, await self.probe(tagID: id, identity: identity, source: source, policy: policy))
            } }
            while next < min(maxConcurrency, candidates.count) { add(candidates[next]); next += 1 }
            while let (id, value) = await group.next() {
                guard !Task.isCancelled, source.feedIdentity == identity else { group.cancelAll(); return }
                put(value, tagID: id, identity: identity, policy: policy)
                if next < candidates.count { add(candidates[next]); next += 1 }
            }
        }
        if source.feedIdentity == identity { revision &+= 1 }
    }

    private func waitForBatch() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !batchActive { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func probe(tagID: Int, identity: String, source: any TagCandidateSource, policy: TagAvailabilityPolicy) async -> TagMediaAvailabilityResult {
        var cursor: String?; var seenCursors = Set<String>(); var seenPageIDs = Set<String>(); var seenSourceIDs = Set<Int>()
        var pages = 0; var rawCount = 0; var exhausted = false; var hasMore = false
        var uncertainMetadata = false
        var invalidMedia = false
        let normalizedTags = policy.normalizedBlockedTags
        var accumulator = FeedAccumulator(blockedTags: normalizedTags, deduplicateMediaAssets: policy.deduplicateMediaAssets)
        accumulator.applyBlockedAuthors(ids: policy.blockedAuthorIDs, handles: policy.normalizedBlockedAuthorHandles)
        func result(_ state: TagMediaAvailabilityState, _ reason: TagMediaAvailabilityReason, httpStatus: Int? = nil) -> TagMediaAvailabilityResult {
            .init(state: state, countLowerBound: accumulator.items.count, exhausted: exhausted, checkedAt: now(), reason: reason,
                  httpStatus: httpStatus, pages: pages, rawCount: rawCount, hasMore: hasMore)
        }
        guard tagID > 0 else { return result(.unknown, .tagMismatch) }
        do {
            while pages < maxPages {
                try Task.checkCancellation()
                guard identity == source.feedIdentity else { return result(.unknown, .contextChanged) }
                let page = try await source.tagCandidates(tagID: tagID, author: nil,
                    filter: FeedFilter(kind: .all, sort: "Newest", period: "AllTime", baseModel: "", onlyPG: false, videoDurationRange: nil),
                    cursor: cursor, limit: requestLimit)
                try Task.checkCancellation()
                guard identity == source.feedIdentity else { return result(.unknown, .contextChanged) }
                guard page.items.count <= requestLimit else { return result(.unknown, .invalidMedia) }
                pages += 1; rawCount += page.items.count
                hasMore = page.metadata.nextCursor != nil
                var pageIDs = Set<Int>()
                for item in page.items {
                    guard item.id > 0 else { return result(.unknown, .invalidMedia) }
                    guard let tags = item.tags, !tags.isEmpty else { return result(.unknown, .metadataMissing) }
                    guard tags.contains(where: { $0.id == tagID }) else { return result(.unknown, .tagMismatch) }
                    if !item.isSupported { invalidMedia = true }
                    if item.mediaURL == nil || (!normalizedTags.isEmpty && item.tagNames == nil) { uncertainMetadata = true }
                    pageIDs.insert(item.id)
                }
                let pageSignature = page.items.map { String($0.id) }.joined(separator: ",")
                if !page.items.isEmpty && !seenPageIDs.insert(pageSignature).inserted { return result(.unknown, .repeatedPage) }
                if !pageIDs.isEmpty && pageIDs.isSubset(of: seenSourceIDs) { return result(.unknown, .repeatedPage) }
                seenSourceIDs.formUnion(pageIDs)
                accumulator.append(page, kind: .all)
                if accumulator.items.count >= minimumVisible { return result(.enough, .thresholdReached) }
                guard let next = page.metadata.nextCursor else {
                    exhausted = true; hasMore = false
                    if uncertainMetadata { return result(.unknown, .metadataMissing) }
                    if invalidMedia { return result(.unknown, .invalidMedia) }
                    return result(.sparse, .exhausted)
                }
                guard !next.isEmpty, next != cursor, seenCursors.insert(next).inserted else { return result(.unknown, .repeatedCursor) }
                cursor = next
            }
            return result(.unknown, .pageLimit)
        } catch is CancellationError { return result(.unknown, .cancelled) }
        catch ClientError.signedOut { return result(.unknown, .authUnavailable, httpStatus: 401) }
        catch ClientError.http(let status) { return result(.unknown, .http, httpStatus: status) }
        catch { return result(.unknown, .requestFailed) }
    }

    private func put(_ value: TagMediaAvailabilityResult, tagID: Int, identity: String, policy: TagAvailabilityPolicy) {
        guard identity.isEmpty == false else { return }
        tick &+= 1
        let ttl: TimeInterval
        if value.reason == .searchEmpty { ttl = 600 }
        else { ttl = switch value.state { case .sparse: 600; case .enough: 3600; case .unknown: 30 } }
        entries[Key(identity: identity, tagID: tagID, policy: policy)] = Entry(result: value, expiresAt: now().addingTimeInterval(ttl), touched: tick)
        while entries.count > maxEntries, let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key { entries.removeValue(forKey: oldest) }
        revision &+= 1
        let context = TagSearchDiagnostic(stage: "availability", tagIDs: [tagID], outcome: String(describing: value.state),
            reason: value.reason.rawValue, rawCount: value.rawCount, visibleCount: value.state == .unknown ? nil : value.countLowerBound,
            pages: value.pages, hasMore: value.hasMore, browsingLevel: nil, kind: "all", period: "AllTime", hasAuthor: false, hasText: false,
            blockedTags: policy.blockedTags.count, blockedAuthors: policy.blockedAuthorIDs.count)
        diagnostics?.note(area: .search, code: .tagProbe, httpStatus: value.httpStatus, tagSearch: context)
    }
}

struct TagObservationEstimate: Equatable {
    let countLowerBound: Int
    let lastSeen: Date?
    let emptyUntil: Date?
    var isRecommended: Bool { countLowerBound >= 3 && emptyUntil == nil }
}

/// Local bounded evidence gathered only from items already admitted to a visible feed.
/// This is a lower bound over recent examples, never a total-count estimate.
@MainActor final class TagObservationStore: ObservableObject {
    static let shared: TagObservationStore = {
        #if DEBUG && targetEnvironment(simulator)
        if AuthorPaging176QA.stressesTagIndex { return TagObservationStore() }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TagObservationStore(rootURL: base.appendingPathComponent("CivitTagLibrary/Observed", isDirectory: true))
    }()

    @Published private(set) var revision = 0

    // The UI owns the last completed read snapshot and the ordered mailbox.
    // A feed can submit a committed page without waiting for indexing or persistence.
    private let worker: TagObservationIndex
    private let now: () -> Date
    private var records: TagObservationIndex.Records = [:]
    private var pending: [TagObservationIndex.Observation] = []
    private var drain: Task<Void, Never>?
    private var readContext: (scope: String, policy: TagAvailabilityPolicy, hash: String)?

    init(rootURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.worker = TagObservationIndex(rootURL: rootURL)
        self.now = now
    }

    func activate() async {
        await drain?.value
        publish(await worker.activate())
    }

    func observe(items: [MediaItem], scope: String, policy: TagAvailabilityPolicy) {
        guard !items.isEmpty else { return }
        enqueue(.visible(items, scope: scope, policy: policy, stamp: now()))
    }

    func recordEmpty(tagID: Int, scope: String, policy: TagAvailabilityPolicy) {
        guard tagID > 0 else { return }
        enqueue(.empty(tagID, scope: scope, policy: policy, stamp: now()))
    }

    func estimate(tagID: Int, scope: String, policy: TagAvailabilityPolicy) -> TagObservationEstimate? {
        guard tagID > 0, !records.isEmpty else { return nil }
        if readContext?.scope != scope || readContext?.policy != policy {
            readContext = (scope, policy, TagObservationIndex.contextHash(scope: scope, policy: policy))
        }
        guard let context = readContext?.hash, let record = records[context]?[tagID] else { return nil }
        let instant = now()
        let cutoff = instant.addingTimeInterval(-30 * 24 * 60 * 60)
        let recent = record.witnesses.filter { $0.seenAt >= cutoff && $0.seenAt <= instant }
        let last = record.witnesses.map(\.seenAt).max()
        let activeEmpty = record.emptyUntil.flatMap { $0 > instant ? $0 : nil }
        return .init(countLowerBound: recent.count, lastSeen: last, emptyUntil: activeEmpty)
    }

    func flush() async {
        await drain?.value
        publish(await worker.flush())
    }

    private func enqueue(_ observation: TagObservationIndex.Observation) {
        pending.append(observation)
        guard drain == nil else { return }
        drain = Task(priority: .utility) {
            while !self.pending.isEmpty {
                let batch = self.pending
                self.pending = []
                self.publish(await self.worker.apply(batch))
            }
            self.drain = nil
        }
    }

    private func publish(_ snapshot: TagObservationIndex.Snapshot) {
        guard snapshot.revision > revision else { return }
        records = snapshot.records
        revision = snapshot.revision
    }
}

/// Serial ownership for tag indexing, eviction and persistence. The read model
/// uses value snapshots grouped by context so touching one account/policy only
/// copies that context when the view still holds a previous snapshot.
private actor TagObservationIndex {
    enum Observation: Sendable {
        case visible([MediaItem], scope: String, policy: TagAvailabilityPolicy, stamp: Date)
        case empty(Int, scope: String, policy: TagAvailabilityPolicy, stamp: Date)
    }
    typealias Records = [String: [Int: TagRecord]]
    struct Snapshot: Sendable {
        let revision: Int
        let records: Records
    }
    struct Witness: Codable, Equatable, Sendable {
        let key: String
        let seenAt: Date
    }
    struct TagRecord: Codable, Sendable {
        var witnesses: [Witness]
        var emptyUntil: Date?
        var touchedAt: Date
    }
    private struct DiskTag: Codable, Sendable {
        let tagID: Int
        let record: TagRecord
    }
    private struct DiskContext: Codable, Sendable {
        let hash: String
        let touchedAt: Date
        let tags: [DiskTag]
    }
    private struct DiskFile: Codable, Sendable {
        let version: Int
        var contexts: [DiskContext]
    }
    private struct ContextTouch {
        let date: Date
        let order: Int
    }
    private enum LoadedFile: Sendable { case missing, decoded(DiskFile), invalid }

    private let rootURL: URL?
    private static let maxWitnesses = 8
    private static let maxTagsPerContext = 5_000
    private static let maxContexts = 4
    private let fileName = "observations-v1.json"
    private var records: Records = [:]
    private var revision = 0
    private var contextTouches: [String: ContextTouch] = [:]
    private var touchOrder = 0
    private var loadTask: Task<LoadedFile, Never>?
    private var loaded = false
    private var persistenceWritable = true
    private var debounceTask: Task<Void, Never>?
    private var pendingWrite: (id: UUID, task: Task<(Int, Bool), Never>)?
    private var persistedRevision = 0
    private let fileQueue = DispatchQueue(label: "CivitViewer.tag-observation-files", qos: .utility)

    init(rootURL: URL?) {
        self.rootURL = rootURL
        self.loaded = rootURL == nil
    }

    private var snapshot: Snapshot { .init(revision: revision, records: records) }

    func activate() async -> Snapshot {
        await loadIfNeeded()
        return snapshot
    }

    private func loadIfNeeded() async {
        guard let rootURL, !loaded else { return }
        if loadTask == nil {
            let fileURL = rootURL.appendingPathComponent(fileName)
            loadTask = fileTask {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 8 * 1024 * 1024 else { return .invalid }
                    let data = try Data(contentsOf: fileURL)
                    guard data.count <= 8 * 1024 * 1024,
                          let file = try? JSONDecoder().decode(DiskFile.self, from: data),
                          file.version == 1, Self.isValid(file) else { return .invalid }
                    return .decoded(file)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
                catch { return .invalid }
            }
        }
        guard let task = loadTask else { return }
        let file = await task.value
        guard !loaded else { return }
        loadTask = nil
        switch file {
        case .invalid: persistenceWritable = false
        case .missing: break
        case .decoded(let value):
            merge(value)
            for context in Array(records.keys) { trimTags(in: context) }
            trimContexts()
        }
        loaded = true
        revision &+= 1
    }

    func apply(_ observations: [Observation]) async -> Snapshot {
        let previousRevision = revision
        for observation in observations {
            switch observation {
            case .visible(let items, let scope, let policy, let stamp):
                observe(items, context: Self.contextHash(scope: scope, policy: policy), policy: policy, stamp: stamp)
            case .empty(let tagID, let scope, let policy, let stamp):
                let context = Self.contextHash(scope: scope, policy: policy)
                var record = records[context]?[tagID] ?? TagRecord(witnesses: [], emptyUntil: nil, touchedAt: stamp)
                record.emptyUntil = stamp.addingTimeInterval(24 * 60 * 60)
                record.touchedAt = stamp
                records[context, default: [:]][tagID] = record
                finishObservation(context: context, stamp: stamp)
            }
        }
        if revision != previousRevision {
            await loadIfNeeded()
            scheduleWriteIfNeeded()
        }
        return snapshot
    }

    private func observe(_ items: [MediaItem], context: String, policy: TagAvailabilityPolicy, stamp: Date) {
        var observed = false
        for item in items where item.id > 0 {
            guard let tags = item.tags, !tags.isEmpty else { continue }
            let witness = witnessKey(item: item, deduplicate: policy.deduplicateMediaAssets)
            for tag in tags {
                guard let tagID = tag.id, tagID > 0 else { continue }
                var record = records[context]?[tagID] ?? TagRecord(witnesses: [], emptyUntil: nil, touchedAt: stamp)
                record.witnesses.removeAll { $0.key == witness }
                record.witnesses.append(Witness(key: witness, seenAt: stamp))
                record.witnesses.sort { $0.seenAt > $1.seenAt }
                if record.witnesses.count > Self.maxWitnesses { record.witnesses.removeLast() }
                record.emptyUntil = nil
                record.touchedAt = stamp
                records[context, default: [:]][tagID] = record
                observed = true
            }
        }
        if observed { finishObservation(context: context, stamp: stamp) }
    }

    private func finishObservation(context: String, stamp: Date) {
        touch(context, at: stamp)
        trimTags(in: context)
        trimContexts()
        revision &+= 1
    }

    func flush() async -> Snapshot {
        await loadIfNeeded()
        debounceTask?.cancel()
        debounceTask = nil
        let targetRevision = revision
        while rootURL != nil && persistenceWritable && persistedRevision < targetRevision {
            if let writer = pendingWrite {
                let (writtenRevision, success) = await writer.task.value
                if pendingWrite?.id == writer.id { pendingWrite = nil }
                if success { persistedRevision = max(persistedRevision, writtenRevision) }
                else { persistenceWritable = false }
            } else {
                startWriter()
            }
        }
        return snapshot
    }

    private func scheduleWriteIfNeeded() {
        guard rootURL != nil, persistenceWritable else { return }
        debounceTask?.cancel()
        debounceTask = Task(priority: .utility) {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self.debounceElapsed()
        }
    }

    private func debounceElapsed() async {
        debounceTask = nil
        guard persistenceWritable else { return }
        guard loaded, persistenceWritable else { return }
        while let writer = pendingWrite {
            let (writtenRevision, success) = await writer.task.value
            if pendingWrite?.id == writer.id { pendingWrite = nil }
            if success { persistedRevision = max(persistedRevision, writtenRevision) }
            else { persistenceWritable = false; return }
        }
        if persistedRevision < revision { startWriter() }
    }

    private func startWriter() {
        guard let rootURL, persistenceWritable, loaded, pendingWrite == nil else { return }
        let snapshot = makeDiskFile()
        let snapshotRevision = revision
        let fileURL = rootURL.appendingPathComponent(fileName)
        let writerID = UUID()
        let writer = fileTask {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var diskSnapshot = snapshot
                var data = try encoder.encode(diskSnapshot)
                // Keep the full in-memory LRU state; only the persisted snapshot sheds
                // oldest whole contexts until it fits the bounded file budget.
                while data.count > 8 * 1024 * 1024, !diskSnapshot.contexts.isEmpty {
                    diskSnapshot.contexts.removeLast()
                    data = try encoder.encode(diskSnapshot)
                }
                guard data.count <= 8 * 1024 * 1024 else { return (snapshotRevision, false) }
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
                try Self.applyProtection(to: rootURL)
                try data.write(to: fileURL, options: .atomic)
                try Self.applyProtection(to: fileURL)
                return (snapshotRevision, true)
            } catch { return (snapshotRevision, false) }
        }
        pendingWrite = (writerID, writer)
    }

    // Foundation file calls can block a thread. A dedicated file queue points
    // that wait away from both the UI and the Swift cooperative executor.
    private func fileTask<Value: Sendable>(_ work: @escaping @Sendable () -> Value) -> Task<Value, Never> {
        let queue = fileQueue
        return Task {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: work()) }
            }
        }
    }

    nonisolated private static func applyProtection(to url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func isValid(_ file: DiskFile) -> Bool {
        guard file.contexts.count <= maxContexts else { return false }
        var contextHashes = Set<String>()
        for context in file.contexts {
            guard context.hash.count == 64,
                  context.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  contextHashes.insert(context.hash).inserted,
                  context.tags.count <= maxTagsPerContext,
                  context.touchedAt.timeIntervalSince1970.isFinite else { return false }
            var tagIDs = Set<Int>()
            for tag in context.tags {
                guard tag.tagID > 0, tagIDs.insert(tag.tagID).inserted,
                      tag.record.witnesses.count <= maxWitnesses,
                      tag.record.touchedAt.timeIntervalSince1970.isFinite,
                      tag.record.emptyUntil.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return false }
                var witnessKeys = Set<String>()
                for witness in tag.record.witnesses {
                    guard witness.seenAt.timeIntervalSince1970.isFinite, isValidWitnessKey(witness.key),
                          witnessKeys.insert(witness.key).inserted else { return false }
                }
            }
        }
        return true
    }

    private static func isValidWitnessKey(_ key: String) -> Bool {
        if key.hasPrefix("id:") {
            let digits = key.dropFirst(3)
            return !digits.isEmpty && digits.utf8.allSatisfy { (48...57).contains($0) } && (Int(digits) ?? 0) > 0
        }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "civitai" && ["image", "video"].contains(String(parts[1])) &&
            UUID(uuidString: String(parts[2])) != nil
    }

    private func witnessKey(item: MediaItem, deduplicate: Bool) -> String {
        guard deduplicate, let asset = item.mediaAssetKey else { return "id:\(item.id)" }
        let parts = asset.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "civitai", ["image", "video"].contains(String(parts[1])),
              UUID(uuidString: String(parts[2])) != nil else { return "id:\(item.id)" }
        return asset
    }

    nonisolated static func contextHash(scope: String, policy: TagAvailabilityPolicy) -> String {
        let tags = policy.blockedTags.map(TagPolicy.normalize).sorted().joined(separator: "\u{1f}")
        let authorIDs = policy.blockedAuthorIDs.sorted().map(String.init).joined(separator: ",")
        let handles = policy.blockedAuthorHandles.map(AuthorHandlePolicy.normalize).sorted().joined(separator: "\u{1f}")
        let canonical = [scope, tags, authorIDs, handles, policy.deduplicateMediaAssets ? "1" : "0"].joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func touch(_ context: String, at date: Date) {
        touchOrder += 1
        contextTouches[context] = ContextTouch(date: date, order: touchOrder)
    }

    private func contextIsOlder(_ lhs: String, than rhs: String) -> Bool {
        let earlier = contextTouches[lhs] ?? ContextTouch(date: .distantPast, order: 0)
        let later = contextTouches[rhs] ?? ContextTouch(date: .distantPast, order: 0)
        if earlier.date != later.date { return earlier.date < later.date }
        if earlier.order != later.order { return earlier.order < later.order }
        return lhs < rhs
    }

    private func trimContexts() {
        while records.count > Self.maxContexts {
            guard let oldest = records.keys.min(by: { contextIsOlder($0, than: $1) }) else { break }
            records.removeValue(forKey: oldest)
            contextTouches.removeValue(forKey: oldest)
        }
    }

    private func trimTags(in context: String) {
        guard let tags = records[context], tags.count > Self.maxTagsPerContext else { return }
        let remove = tags.sorted {
            $0.value.touchedAt == $1.value.touchedAt ? $0.key < $1.key : $0.value.touchedAt < $1.value.touchedAt
        }.prefix(tags.count - Self.maxTagsPerContext)
        for tag in remove { records[context]?.removeValue(forKey: tag.key) }
    }

    private func makeDiskFile() -> DiskFile {
        let contexts = records.map { hash, tags in
            DiskContext(hash: hash, touchedAt: contextTouches[hash]?.date ?? .distantPast,
                        tags: tags.map { DiskTag(tagID: $0.key, record: $0.value) }.sorted { $0.tagID < $1.tagID })
        }.sorted { contextIsOlder($1.hash, than: $0.hash) }
        return DiskFile(version: 1, contexts: contexts)
    }

    private func merge(_ file: DiskFile) {
        for (index, context) in file.contexts.enumerated() where !context.tags.isEmpty {
            if context.touchedAt > (contextTouches[context.hash]?.date ?? .distantPast) {
                // The v1 file lists newest contexts first. Runtime touches win equal-date ties.
                contextTouches[context.hash] = ContextTouch(date: context.touchedAt, order: -index)
            }
            for diskTag in context.tags where diskTag.tagID > 0 {
                guard let current = records[context.hash]?[diskTag.tagID] else {
                    records[context.hash, default: [:]][diskTag.tagID] = diskTag.record
                    continue
                }
                let merged = Dictionary((current.witnesses + diskTag.record.witnesses).map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.seenAt >= b.seenAt ? a : b })
                var record = current
                record.witnesses = merged.values.sorted { $0.seenAt > $1.seenAt }.prefix(Self.maxWitnesses).map { $0 }
                if diskTag.record.touchedAt > current.touchedAt {
                    record.emptyUntil = diskTag.record.emptyUntil
                } else {
                    record.emptyUntil = current.emptyUntil
                }
                record.touchedAt = max(current.touchedAt, diskTag.record.touchedAt)
                records[context.hash, default: [:]][diskTag.tagID] = record
            }
        }
    }

}
