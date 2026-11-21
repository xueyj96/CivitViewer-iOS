import Foundation
import Combine

/// Shared preference contract for the settings UI and the prefetch scheduler.
enum MediaPrefetchConcurrency {
    static let defaultsKey = "mediaPrefetchConcurrency"
    static let defaultValue = 4
    static let steps = [2, 4, 6, 8]
    static func validated(_ value: Int) -> Int { steps.contains(value) ? value : defaultValue }
}

/// Bounded, view-independent preloading for a moving timeline window.
@MainActor
final class MediaPreloader: ObservableObject {
    struct Snapshot: Equatable {
        let active: Int
        let configuredConcurrency: Int
        let desired: Int
        let ready: Int
        let failed: Int
        let networkPaused: Int
    }

    private struct Key: Hashable {
        let url: URL
        let video: Bool
        let coverRequest: MediaPosterPolicy.CoverRequest?
        init(url: URL, video: Bool, coverRequest: MediaPosterPolicy.CoverRequest? = nil) {
            self.url = url; self.video = video; self.coverRequest = coverRequest
        }
    }
    private struct Candidate {
        let key: Key
        let priority: Int
        let coverRequest: MediaPosterPolicy.CoverRequest?
    }
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        let context: String
        let cacheGeneration: Int
        let networkRevision: Int
        let completionRevision: Int
    }

    private var targetUpdate: Task<Void, Never>?
    private var reconciliation: Task<Void, Never>?
    private var reconcileRevision = 0
    private let cache: MediaCache
    private let owner = UUID()
    private var networkValue = false
    private var networkRevision = 0
    private var completionRevision = 0
    private var networkCancellable: AnyCancellable?
    private var invalidationCancellable: AnyCancellable?
    private var playbackCancellable: AnyCancellable?
    private var playbackDemand = MediaCache.ForegroundVideoDemand()
    private var jobs: [Key: Job] = [:]
    private var desired: [Key] = []
    private var windowTarget = 6
    private var candidates: [Key: Candidate] = [:]
    private var attempted = Set<Key>()
    private var ready = Set<Key>()
    private var failed = Set<Key>()
    private var failureCodes: [Key: DiagnosticCode] = [:]
    private var spaceDeferred: [Key: Int] = [:]
    private var context: String?
    private var currentKey: Key?
    private var wifiOnly = true
    private var invalidationSeen = false
    private var invalidated = false
    private var stopped = false
    private var networkPaused = Set<Key>()
    private var concurrencyLimit = MediaPrefetchConcurrency.defaultValue
    private var coverOnlyMode = false
    var onCoverReady: ((String, Int, PreparedCoverPreview) -> Void)?

    convenience init() { self.init(cache: .shared) }

    init(cache: MediaCache, network: AnyPublisher<Bool, Never>? = nil) {
        self.cache = cache
        networkCancellable = (network ?? cache.prefetchNetwork)
            .sink { [weak self] allowed in
                guard let self else { return }
                self.networkValue = allowed
                self.networkRevision += 1
                // A path can change from offline to cellular while remaining
                // false for unmetered Wi-Fi. Retry failed remote media on each
                // path snapshot, while keeping successful and running work.
                let retryable = self.failed.filter { !$0.url.isFileURL }
                self.attempted.subtract(retryable); self.failed.subtract(retryable)
                for key in retryable { self.failureCodes[key] = nil; self.spaceDeferred[key] = nil }
                self.reconcile()
            }

        invalidationCancellable = cache.prefetchInvalidations
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.invalidationSeen {
                    self.invalidationSeen = true
                    return
                }
                self.invalidated = true
                self.cancelAll()
                self.desired = []
                self.candidates = [:]
                self.attempted = []
                self.ready = []
                self.failed = []
                self.failureCodes = [:]; self.spaceDeferred = [:]
                self.updateTargets(nil)
            }
        playbackCancellable = cache.foregroundVideoDemands.sink { [weak self] value in
            guard let self else { return }
            self.playbackDemand = value
            self.reconcile()
        }
    }

    var snapshot: Snapshot {
        Snapshot(active: jobs.count, configuredConcurrency: concurrencyLimit, desired: desired.count, ready: ready.count,
                 failed: failed.count,
                 networkPaused: networkPaused.count)
    }

    func update(_ items: [MediaItem], after index: Int, count: Int = 6,
                context newContext: String, wifiOnly newWifiOnly: Bool,
                concurrency newConcurrency: Int = MediaPrefetchConcurrency.defaultValue,
                coverOnly: Bool = false) {
        guard !Task.isCancelled else { return }
        stopped = false
        coverOnlyMode = coverOnly
        if context != newContext {
            cancelAll()
            context = newContext
            attempted = []
            ready = []
            failed = []
            failureCodes = [:]; spaceDeferred = [:]
            invalidated = false
        }
        let wasWifiOnly = wifiOnly
        wifiOnly = newWifiOnly
        if wasWifiOnly != newWifiOnly {
            attempted = attempted.filter { !$0.video }
            failed = failed.filter { !$0.video }
            failureCodes = failureCodes.filter { !$0.key.video }; spaceDeferred = spaceDeferred.filter { !$0.key.video }
        }

        let windowSize = [3, 6, 10].contains(count) ? count : 6
        windowTarget = windowSize
        concurrencyLimit = MediaPrefetchConcurrency.validated(newConcurrency)
        let normalizedIndex = items.indices.contains(index) ? index : -1
        let priorFocus = currentKey
        currentKey = normalizedIndex >= 0 ? makeCurrentKey(items[normalizedIndex], coverOnly: coverOnly) : nil
        if priorFocus != currentKey {
            // An explicit page advance is fresh demand. Give failed remote
            // targets one new attempt, including a previously full disk budget.
            let retryable = failed.filter { !$0.url.isFileURL }
            attempted.subtract(retryable); failed.subtract(retryable)
            for key in retryable { failureCodes[key] = nil; spaceDeferred[key] = nil }
        }
        let previousVideo: MediaItem? = {
            guard normalizedIndex > 0 else { return nil }
            let item = items[normalizedIndex - 1]
            return item.isVideo && makeMediaKey(item) != nil ? item : nil
        }()
        let futureCount = max(0, windowSize - (previousVideo == nil ? 0 : 1))
        let start = normalizedIndex >= 0 ? normalizedIndex + 1 : 0
        let futureWindow = Array(items.dropFirst(start).prefix(futureCount))
        let window = (previousVideo.map { [$0] } ?? []) + futureWindow
        var ordered: [Candidate] = []
        var newCandidates: [Key: Candidate] = [:]
        // Leave the two-slot setting available for adjacent media. At larger
        // settings, let the next work's poster start ahead of more distant files.
        let firstForwardOffset = previousVideo == nil ? 0 : 1
        for (offset, item) in window.enumerated() {
            guard let media = makeMediaKey(item) else { continue }
            let imageRequest = coverOnly && !item.isVideo
                ? MediaPosterPolicy.coverRequest(source: media.url, declared: item.posterURL, isVideo: false) : nil
            let mainKey = imageRequest.map { request in
                Key(url: request.candidates.first ?? request.source, video: false, coverRequest: request)
            } ?? media
            let main = Candidate(key: mainKey, priority: 2 * offset, coverRequest: imageRequest)
            if !(coverOnly && item.isVideo), newCandidates[mainKey] == nil {
                ordered.append(main); newCandidates[mainKey] = main
            }
            if item.isVideo, let source = item.mediaURL {
                let request = MediaPosterPolicy.coverRequest(source: source, declared: item.posterURL, isVideo: true)
                if !request.candidates.isEmpty || coverOnly {
                    let posterURL = request.candidates.first ?? source
                    let posterKey = Key(url: posterURL, video: false, coverRequest: request)
                    if newCandidates[posterKey] == nil {
                        let nearPoster = !coverOnly && concurrencyLimit >= 4 && offset == firstForwardOffset
                        let priority = nearPoster ? main.priority + 1 : 100 + offset
                        let poster = Candidate(key: posterKey, priority: priority, coverRequest: request)
                        ordered.append(poster)
                        newCandidates[posterKey] = poster
                    }
                }
            }
        }
        let newDesired = ordered.map(\.key)
        let newSet = Set(newDesired)
        // Newly exposed work may receive one attempt; unchanged targets keep their
        // result and in-flight task across page movement.
        attempted = attempted.intersection(newSet.union(currentKey.map { [$0] } ?? []))
        ready = ready.intersection(newSet)
        failed = failed.intersection(newSet)
        failureCodes = failureCodes.filter { newSet.contains($0.key) }
        spaceDeferred = spaceDeferred.filter { newSet.contains($0.key) }
        candidates = newCandidates
        desired = newDesired
        invalidated = false

        // A newly current remote video streams through AVPlayer; retaining its
        // unfinished full-file prefetch would create a second transfer.
        // Foreground images join the cache's existing file transfer, so retain
        // their writer while the visible image view attaches to it.
        let expiredJobs = jobs.keys.filter { !newSet.contains($0) && ($0 != currentKey || $0.video) }
        for key in expiredJobs { cancelJob(key) }
        var protectedKeys = newSet
        if let currentKey, jobs[currentKey] != nil { protectedKeys.insert(currentKey) }
        let protected = protectedKeys.flatMap { key -> [(URL, Bool)] in
            if let request = candidates[key]?.coverRequest {
                return request.candidates.filter { !$0.isFileURL }.map { ($0, false) }
            }
            guard !key.url.isFileURL else { return [] }
            return [(key.url, key.video)]
        }
        updateTargets(protected)
        reconcile()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        reconcileRevision += 1
        cancelAll()
        desired = []
        candidates = [:]
        attempted = []
        ready = []
        failed = []
        failureCodes = [:]; spaceDeferred = [:]
        networkPaused = []
        currentKey = nil
        onCoverReady = nil
        updateTargets(nil)
    }

    deinit {
        for job in jobs.values { job.task.cancel() }
        let cache = cache
        let owner = owner
        Task { @MainActor in await cache.removePrefetchTargets(owner: owner) }
    }

    private func makeMediaKey(_ item: MediaItem) -> Key? {
        guard let url = item.mediaURL else { return nil }
        return Key(url: url, video: item.isVideo)
    }

    private func makeCurrentKey(_ item: MediaItem, coverOnly: Bool) -> Key? {
        guard let media = makeMediaKey(item) else { return nil }
        guard coverOnly, !item.isVideo else { return media }
        let request = MediaPosterPolicy.coverRequest(source: media.url, declared: item.posterURL, isVideo: false)
        return Key(url: request.candidates.first ?? request.source, video: false, coverRequest: request)
    }

    private func cancelAll() {
        for key in Array(jobs.keys) { cancelJob(key) }
    }

    private func cancelJob(_ key: Key) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        job.task.cancel(); attempted.remove(key)
        // Cancellation releases a shared cache reservation asynchronously. Wake
        // the current window after that release, including across filter swaps.
        Task { @MainActor [weak self] in
            await job.task.value
            guard let self, !self.stopped, !self.invalidated else { return }
            self.completionRevision += 1
            self.reconcile()
        }
    }

    private func updateTargets(_ targets: [(URL, Bool)]?) {
        let previous = targetUpdate, cache = self.cache, owner = self.owner
        let generation = cache.repairGeneration
        targetUpdate = Task { @MainActor in
            await previous?.value
            guard generation == cache.repairGeneration else { return }
            if let targets { await cache.setPrefetchTargets(targets, owner: owner) }
            else { await cache.removePrefetchTargets(owner: owner) }
        }
    }
    private func reconcile() {
        reconcileRevision += 1
        guard reconciliation == nil else { return }
        reconciliation = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let revision = self.reconcileRevision
                await self.reconcile(revision: revision)
                if revision == self.reconcileRevision { break }
            }
            self.reconciliation = nil
        }
    }
    private func reconcile(revision: Int) async {
        guard !stopped, !invalidated else { return }
        await targetUpdate?.value
        let mediaFiles = desired.filter { $0.coverRequest == nil }
        var localKeys = Set<Key>()
        for key in mediaFiles {
            let local = if key.url.isFileURL { await cache.fileExists(key.url) }
                else { await cache.cached(key.url, video: key.video) != nil }
            if local { localKeys.insert(key) }
        }
        let budgetRetries = spaceDeferred.filter { $0.value < completionRevision }
        // A cover can come from the cache even when disk space is low. The
        // downloader checks quota before sending any network request. Probe
        // again only when completion can make a previously deferred cover fit.
        let needsImageSpace = !mediaFiles.isEmpty || !budgetRetries.isEmpty
        let imageSpace = needsImageSpace ? await cache.hasPrefetchSpace(video: false) : false
        let videoSpace = mediaFiles.isEmpty ? false : await cache.hasPrefetchSpace(video: true)
        guard revision == reconcileRevision, !stopped, !invalidated else { return }
        for key in budgetRetries.keys where key.video ? videoSpace : imageSpace {
            attempted.remove(key); failed.remove(key); failureCodes[key] = nil; spaceDeferred[key] = nil
        }
        // Disk reads are batched before committing this exact window revision.
        for key in desired where jobs[key] == nil && localKeys.contains(key) {
            attempted.insert(key); ready.insert(key); failed.remove(key); failureCodes[key] = nil; spaceDeferred[key] = nil
        }
        networkPaused = []
        for key in desired where key.video && wifiOnly && !networkValue && !ready.contains(key) {
            networkPaused.insert(key)
        }
        // Keep the two nearest future videos moving during a foreground wait. A
        // new page/rebuffer should not repeatedly discard every future file.
        let nextVideosWhileWaiting: Set<Key> = if playbackDemand.waiting {
            Set(desired.filter {
                $0.video && !playbackDemand.urls.contains($0.url) && !ready.contains($0) &&
                    !networkPaused.contains($0) && (!attempted.contains($0) || jobs[$0] != nil)
            }.prefix(2))
        } else { [] }
        defer { publishStatus(nextVideosWhileWaiting: nextVideosWhileWaiting) }
        let pausedJobs = jobs.keys.filter {
            ($0.video && wifiOnly && !networkValue) || playbackBlocks($0, allowing: nextVideosWhileWaiting)
        }
        for key in pausedJobs {
            cancelJob(key)
            failed.remove(key)
            failureCodes[key] = nil; spaceDeferred[key] = nil
        }
        // Recompute ranks from the current window, including running jobs. A
        // retained far download must yield to a newly nearest missing work.
        let ranked = desired.compactMap { candidates[$0] }
            .filter { !ready.contains($0.key) && (!attempted.contains($0.key) || jobs[$0.key] != nil) }
            .filter { !($0.key.video && wifiOnly && !networkValue) && !playbackBlocks($0.key, allowing: nextVideosWhileWaiting) }
            .sorted { $0.priority < $1.priority }
        let currentImages = Set(jobs.keys.filter { $0 == currentKey && !$0.video })
        let futureSlots = max(0, concurrencyLimit - currentImages.count)
        let preferred = currentImages.union(ranked.prefix(futureSlots).map(\.key))
        for key in jobs.keys.filter({ !preferred.contains($0) }) {
            cancelJob(key)
        }
        // Existing far reservations may be the very reason capacity is full;
        // yield them before testing admission of the newly nearest target.
        guard imageSpace || desired.contains(where: { candidates[$0]?.coverRequest != nil }) else { return }
        while jobs.count < concurrencyLimit {
            guard let candidate = desired.compactMap({ candidates[$0] })
                .filter({ !attempted.contains($0.key) && jobs[$0.key] == nil })
                .filter({ imageSpace || $0.coverRequest != nil })
                .filter({ !($0.key.video && wifiOnly && !networkValue) })
                .filter({ !playbackBlocks($0.key, allowing: nextVideosWhileWaiting) })
                .sorted(by: { $0.priority < $1.priority }).first else { break }
            let key = candidate.key
            if key.url.isFileURL && candidate.coverRequest == nil {
                attempted.insert(key)
                if localKeys.contains(key) { ready.insert(key) }
                else { failed.insert(key) }
                continue
            }
            if localKeys.contains(key) {
                attempted.insert(key); ready.insert(key)
                continue
            }
            launch(key)
        }
    }

    private func playbackBlocks(_ key: Key, allowing nextVideosWhileWaiting: Set<Key>) -> Bool {
        key.video && (playbackDemand.urls.contains(key.url) ||
                      (playbackDemand.waiting && !nextVideosWhileWaiting.contains(key)))
    }

    private func launch(_ key: Key) {
        let id = UUID()
        let cache = self.cache
        let jobContext = context ?? ""
        let jobGeneration = cache.repairGeneration
        let coverRequest = candidates[key]?.coverRequest
        attempted.insert(key)
        let task = Task { @MainActor [weak self, cache] in
            do {
                let cover: PreparedCoverPreview?
                if let coverRequest { cover = try await cache.loadCoverPreview(coverRequest, context: jobContext) }
                else { _ = try await cache.preloadFile(key.url, video: key.video); cover = nil }
                try Task.checkCancellation()
                self?.finish(key, id: id, success: true, cover: cover)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, self.jobs[key]?.id == id else { return }
                let code = cache.recordPreloadFailure(error)
                let space: Bool = if case ImageLoadError.lowSpace = error { true } else { false }
                self.finish(key, id: id, success: false, code: code, space: space)
            }
        }
        jobs[key] = Job(id: id, task: task, context: jobContext, cacheGeneration: jobGeneration,
                        networkRevision: networkRevision, completionRevision: completionRevision)
    }

    private func finish(_ key: Key, id: UUID, success: Bool, code: DiagnosticCode? = nil,
                        space: Bool = false, cover: PreparedCoverPreview? = nil) {
        guard let job = jobs[key], job.id == id else { return }
        jobs[key] = nil
        if success { completionRevision += 1 }
        let expectedCover = candidates[key]?.coverRequest
        let coverMatches = !success || (expectedCover.map { $0 == cover?.request } ?? (cover == nil))
        if desired.contains(key), job.context == context,
           job.cacheGeneration == cache.repairGeneration,
           coverMatches, cover == nil || (cover?.context == job.context && cover?.cacheGeneration == job.cacheGeneration) {
            if success {
                ready.insert(key); failureCodes[key] = nil; spaceDeferred[key] = nil
                if let cover { onCoverReady?(job.context, job.cacheGeneration, cover) }
            }
            else if !key.url.isFileURL && job.networkRevision != networkRevision { attempted.remove(key) }
            else {
                failed.insert(key); failureCodes[key] = code
                if space { spaceDeferred[key] = job.completionRevision }
            }
        }
        reconcile()
    }

    private func publishStatus(nextVideosWhileWaiting: Set<Key>) {
        guard !coverOnlyMode, context != nil, !stopped, !invalidated else { return }
        let primary = Set(candidates.values.filter { $0.coverRequest == nil }.map(\.key))
        let failures = primary.intersection(failed)
        let value = MediaPreloadStatus(ready: primary.intersection(ready).count, total: primary.count, target: windowTarget,
            running: primary.intersection(Set(jobs.keys)).count, failed: failures.count,
            networkPaused: primary.intersection(networkPaused).count,
            oversized: failures.filter { failureCodes[$0] == .limit }.count,
            spaceLimited: failures.filter { failureCodes[$0] == .storage }.count,
            networkFailed: failures.filter { failureCodes[$0] == .network || failureCodes[$0] == .http }.count)
        var status = value
        status.playbackDeferred = primary.filter { !ready.contains($0) && playbackBlocks($0, allowing: nextVideosWhileWaiting) }.count
        cache.setPreloadStatus(status, owner: owner)
    }
}
