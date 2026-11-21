import Foundation
import Darwin
import UIKit
import CryptoKit
import Network
import Combine
import ImageIO
import AVFoundation

/// URL resource values can retain an earlier size/mtime/volume reading.
/// Authority reads and returned leases use a new URL with no cached values.
private enum MediaFileValues {
    nonisolated static func fresh(_ url: URL) -> URL {
        var result = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        result.removeAllCachedResourceValues()
        return result
    }
}

struct CachedImageResource {
    let file: URL
    let preview: UIImage
    let frameCount: Int
    let lease: MediaFileLease?
}

struct CachedImageResourceIdentity: Equatable {
    let url: URL
    let fallbackURLs: [URL]
}

struct PreparedCoverPreview {
    let request: MediaPosterPolicy.CoverRequest
    let context: String
    let cacheGeneration: Int
    let image: UIImage
}

enum PreviewRetryPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        if case MediaDownloadError.http(let status) = error { return [408, 500, 502, 503, 504].contains(status) }
        let native = error as NSError
        guard native.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut.rawValue, URLError.networkConnectionLost.rawValue,
                URLError.cannotConnectToHost.rawValue].contains(native.code)
    }
}

struct MediaPreloadStatus: Equatable {
    var ready = 0, total = 0, target = 0, running = 0, failed = 0
    var networkPaused = 0, oversized = 0, spaceLimited = 0, networkFailed = 0
    var playbackDeferred = 0
    var paused = false
    var summary: String {
        guard target > 0 else { return "暂无预载任务" }
        return (paused ? "上次准备 " : "已准备 ") + "\(ready)/\(target)" + (paused ? " · 已暂停" : (running > 0 ? " · 下载中 \(running)" : ""))
    }
    var detail: String {
        var parts: [String] = []
        if total < target { parts.append("当前列表仅有 \(total) 条后续作品") }
        if playbackDeferred > 0 { parts.append("当前视频优先缓冲，随后继续预载") }
        if networkPaused > 0 { parts.append("\(networkPaused) 条等待允许的网络") }
        if oversized > 0 { parts.append("\(oversized) 条超过单条预取上限") }
        if spaceLimited > 0 { parts.append("\(spaceLimited) 条空间或缓存写入受限") }
        if networkFailed > 0 { parts.append("\(networkFailed) 条网络读取失败") }
        if failed > oversized + spaceLimited + networkFailed { parts.append("另有作品读取失败") }
        if paused { parts.append("返回观看页后继续") }
        return parts.joined(separator: "；")
    }
}

enum PosterDiagnosticPolicy {
    static func failure(_ error: Error, stage: PosterDiagnosticStage) -> PosterFailureKind {
        if let error = error as? ImageLoadError {
            switch error {
            case .queueFull: return .queueFull
            case .decode: return .decode
            case .lowSpace: return .lowSpace
            case .missingLocal: return .missingLocal
            case .cacheWrite: return .cacheWrite
            case .animationLimit: return .animationLimit
            }
        }
        if let error = error as? MediaDownloadError {
            switch error {
            case .limitExceeded: return .limitExceeded
            case .http: return .http
            case .notImage: return .notImage
            case .videoContent: return .videoContent
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return .network }
        if stage == .localFrame || stage == .decodedFrame { return .nativeFrame }
        if stage == .cacheWrite { return .cacheWrite }
        return .unknown
    }
}

/// MainActor owns request lifetimes and observable projections. All filesystem
/// truth, eviction and reservations belong to MediaDiskStore.
@MainActor final class MediaCache: ObservableObject {
    struct ForegroundVideoDemand: Equatable { var urls = Set<URL>(); var waiting = false }
    private struct PlaybackOwner { let url: URL; let waiting: Bool }
    private var playbackOwners: [UUID: PlaybackOwner] = [:]
    private let playbackDemand = CurrentValueSubject<ForegroundVideoDemand, Never>(.init())
    var foregroundVideoDemands: AnyPublisher<ForegroundVideoDemand, Never> { playbackDemand.eraseToAnyPublisher() }
    func setForegroundVideoDemand(url: URL, owner: UUID, waiting: Bool) {
        guard !url.isFileURL else { removeForegroundVideoDemand(owner: owner); return }
        playbackOwners[owner] = .init(url: url, waiting: waiting); publishPlaybackDemand()
    }
    func removeForegroundVideoDemand(owner: UUID) {
        guard playbackOwners.removeValue(forKey: owner) != nil else { return }; publishPlaybackDemand()
    }
    private func publishPlaybackDemand() {
        let value = ForegroundVideoDemand(urls: Set(playbackOwners.values.map(\.url)), waiting: playbackOwners.values.contains { $0.waiting })
        if value != playbackDemand.value { playbackDemand.send(value) }
    }
    static let shared = MediaCache()
    nonisolated static let imageDownloadMaximum: Int64 = 64 * 1024 * 1024
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var diskUsageKnown = false
    @Published private(set) var cacheHits = 0
    @Published private(set) var preloadStatus: MediaPreloadStatus?
    private var preloadStatusOwner: UUID?
    private let posterWrites = PassthroughSubject<String, Never>()
    var posterUpdates: AnyPublisher<String, Never> { posterWrites.eraseToAnyPublisher() }
    private let videoPreloadWrites = PassthroughSubject<URL, Never>()
    var videoPreloadUpdates: AnyPublisher<URL, Never> { videoPreloadWrites.eraseToAnyPublisher() }
    private struct Flight {
        let id: UUID; let task: Task<URL, Error>; var maximum: Int64
        var consumers: Set<UUID>; var foregroundConsumers: Set<UUID>; var handoff: MediaFileLease? = nil
    }
    private struct PreloadQuotaFailure: Error { let maximum: Int64 }
    private var inFlight: [String: Flight] = [:]
    private let downloads = MediaLoadQueue(limit: 10, maximumWaiting: 64, backgroundLimit: 8, foregroundLimit: 4)
    private let posterJobs = MediaLoadQueue(limit: 1, maximumWaiting: 2)
    private let decoder = MediaDecodeScheduler()
    private let directory: URL
    private let disk: MediaDiskStore
    private let directoryReady: Task<Void, Never>
    private var initialization: Task<Void, Never>?
    private var clearBarrier: Task<Void, Never>?
    private var snapshotRevision: UInt64 = 0
    private var legacyReservations: [MediaBudgetReservation] = []
    private(set) var pendingDownloadBudget: Int64 = 0
    var decodeCount: Int { decoder.decoded }
    private let diagnostics: LocalDiagnosticsStore?
    private let availableBytesProvider: (() -> Int64?)?
    private let monitor = NWPathMonitor()
    @Published private(set) var unmetered = false
    @Published private(set) var generation = 0
    var prefetchNetwork: AnyPublisher<Bool, Never> { $unmetered.eraseToAnyPublisher() }
    var prefetchInvalidations: AnyPublisher<Int, Never> { $generation.eraseToAnyPublisher() }
    var repairGeneration: Int { generation }
    var repairDirectory: URL { directory }
    var capacity: Int64 {
        let selected = UserDefaults.standard.object(forKey: "cacheLimitGB") as? Int ?? 5
        return Int64([1, 5, 10, 20].contains(selected) ? selected : 5) * 1_000_000_000
    }
    private var policy: MediaDiskPolicy {
        .init(capacity: capacity, injectedSpace: availableBytesProvider?(), usesInjectedSpace: availableBytesProvider != nil)
    }
    init(directoryURL: URL? = nil, monitorNetwork: Bool = true, diagnostics: LocalDiagnosticsStore? = .shared,
         availableBytesProvider: (() -> Int64?)? = nil) {
        directory = directoryURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
        disk = MediaDiskStore(directory: directory)
        self.diagnostics = diagnostics; self.availableBytesProvider = availableBytesProvider
        let disk = self.disk
        let directoryReady = Task { await disk.prepareDirectory() }
        self.directoryReady = directoryReady
        let initialPolicy = policy
        initialization = Task { [weak self] in
            await directoryReady.value
            await disk.trim(initialPolicy)
            await self?.refresh()
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.unmetered = allowed }
        }
        if monitorNetwork { monitor.start(queue: DispatchQueue(label: "CivitViewer.network")) }
    }
    private func ready() async { await initialization?.value; await waitForClear() }

    // Reading a particular file needs its directory and current generation.
    // Writes still await startup accounting before reserving or evicting bytes.
    private func readyForRead() async {
        await directoryReady.value
        await waitForClear()
    }

    private func waitForClear() async {
        while let barrier = clearBarrier {
            let expected = generation
            await barrier.value
            if generation == expected { return }
        }
    }
    private func refresh() async {
        let value = await disk.snapshot()
        guard value.generation == generation, value.revision >= snapshotRevision else { return }
        snapshotRevision = value.revision
        if diskBytes != value.bytes { diskBytes = value.bytes }
        if diskUsageKnown != value.known { diskUsageKnown = value.known }
        pendingDownloadBudget = value.pending
    }
    private func key(_ url: URL, video: Bool) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + (video ? ".mp4" : ".img")
    }
    private func posterTarget(_ source: URL) -> URL {
        let name = SHA256.hash(data: Data((source.absoluteString + "#first-frame.v1").utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
        return directory.appendingPathComponent(name)
    }
    func posterCacheKey(for source: URL) -> String { posterTarget(source).lastPathComponent }
    func collectionPreviewKeys(for item: MediaItem) -> [String] {
        guard let source = item.mediaURL, !source.isFileURL else { return [] }
        guard item.isVideo else { return [key(source, video: false)] }
        var keys: [String] = []
        if let poster = item.posterURL, !poster.isFileURL { keys.append(key(poster, video: false)) }
        keys.append(posterCacheKey(for: source)); return keys
    }
    func cachedCollectionPreviews(keys: [[String]]) async -> [URL?] { await ready(); return await disk.previews(keys) }
    func cachedCollectionPreview(keys: [String]) async -> URL? { await cachedCollectionPreviews(keys: [keys]).first ?? nil }
    func cached(_ url: URL, video: Bool) async -> URL? {
        await ready(); let result = await disk.cached(key(url, video: video))
        if result != nil { cacheHits += 1 }; return result
    }
    func leaseCached(_ url: URL, video: Bool) async -> MediaFileLease? {
        await readyForRead(); let result = await disk.cachedLease(key(url, video: video), generation: generation)
        if result != nil { cacheHits += 1 }; return result
    }
    func leaseFile(_ file: URL, protecting source: URL? = nil,
                   expectedIdentity: MediaRepairStore.Identity? = nil) async -> MediaFileLease? {
        await readyForRead()
        return await disk.lease(file, protecting: source.map { key($0, video: true) }, expected: expectedIdentity, generation: generation)
    }
    func release(_ lease: MediaFileLease) async { await disk.release(lease); await refresh() }
    func maintenanceYieldCount() async -> Int { await disk.maintenanceYields }
    func fileIdentity(_ file: URL) async -> MediaRepairStore.Identity? { await ready(); return await disk.identity(file) }
    func fileExists(_ file: URL) async -> Bool { await ready(); return await disk.exists(file) }
    func availableSpace() async -> Int64? { await ready(); return await disk.free(policy) }
    func volumeAvailableSpace(at directory: URL) async -> Int64? { await disk.volumeSpace(directory) }
    func removeTemporary(_ file: URL) async { await disk.remove(file) }
    func moveTemporary(_ file: URL, to target: URL) async throws { try await disk.move(file, to: target) }
    func pin(_ url: URL) async { await ready(); await disk.pin(key(url, video: true), repair: false, adding: true) }
    func unpin(_ url: URL) async { await disk.pin(key(url, video: true), repair: false, adding: false) }
    func protectRepairFile(_ file: URL) async {
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        await ready(); await disk.pin(file.lastPathComponent, repair: true, adding: true)
    }
    func unprotectRepairFile(_ file: URL) async {
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        await disk.pin(file.lastPathComponent, repair: true, adding: false)
    }
    func repairReservation() async throws -> MediaBudgetReservation {
        await ready(); let token = try await disk.reserveRepair(generation: generation, policy: policy); await refresh(); return token
    }
    func releaseReservation(_ token: MediaBudgetReservation) async { await disk.releaseBudget(token, policy: policy); await refresh() }
    func reserveRepairBudget() async -> Int64 {
        guard let token = try? await repairReservation() else { return 0 }; legacyReservations.append(token); return token.bytes
    }
    func releaseRepairBudget(_ bytes: Int64) async {
        guard let index = legacyReservations.firstIndex(where: { $0.bytes == bytes }) else { return }
        let token = legacyReservations.remove(at: index); await releaseReservation(token)
    }
    func repairOriginal(_ url: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let lease = try await fetchFile(url, video: true, videoMaximum: 536_870_912, progress: progress)
        await release(lease); return lease.file
    }
    func discardBrokenVideo(_ address: URL, expected: MediaRepairStore.Identity) async {
        await ready(); await disk.remove(directory.appendingPathComponent(key(address, video: true)), expected: expected); await refresh()
    }
    private func decode(_ lease: MediaFileLease, pixels: Int, resource: URL? = nil,
                        prefetching: Bool = false, publishPreview: Bool = true) async throws -> UIImage? {
        try await decoder.image(lease, pixels: pixels, resource: (resource ?? lease.file).absoluteString,
                                priority: prefetching ? .background : .foreground, publishPreview: publishPreview)
    }
    /// Returns only a scheduler-memory image at this exact resource and tier.
    /// It checks the local cache index and acquires/releases a lease, but does
    /// not read image bytes, decode, or start a network request.
    func decodedCoverPreview(_ request: MediaPosterPolicy.CoverRequest) async -> UIImage? {
        let expected = generation
        let generated = request.isVideo ? [posterTarget(request.source)] : []
        let resources = generated + request.candidates
        for resource in resources {
            guard !Task.isCancelled, expected == generation else { return nil }
            let lease = resource.isFileURL ? await leaseFile(resource) : await leaseCached(resource, video: false)
            guard let lease else { continue }
            let image = decoder.cachedImage(lease, pixels: request.decodePixels,
                                            resource: request.isVideo && resource == posterTarget(request.source) ? lease.file.absoluteString : resource.absoluteString)
            await release(lease)
            if let image, expected == generation, !Task.isCancelled { return image }
        }
        return nil
    }

    /// Pure in-memory lookup for ready previews. It reads only the scheduler's
    /// request index and NSCache; it does not inspect disk or start work.
    func preparedCoverMemory(_ request: MediaPosterPolicy.CoverRequest) -> UIImage? {
        guard !request.candidates.contains(where: \.isFileURL) else { return nil }
        let generated = request.isVideo ? [posterTarget(request.source)] : []
        return decoder.memoryPreview(generation: generation,
            resources: generated.map(\.absoluteString) + request.candidates.map(\.absoluteString),
            pixels: request.decodePixels)
    }

    /// Prepares a cover through the formal poster candidate sequence at the
    /// shared 512px tier. Only the existing poster target and safe candidates
    /// are considered; no video extraction or original-video download occurs.
    func loadCoverPreview(_ request: MediaPosterPolicy.CoverRequest, context: String) async throws -> PreparedCoverPreview {
        let expected = generation
        let generated = posterTarget(request.source)
        var image: UIImage?
        if request.isVideo, let lease = await leaseFile(generated) {
            do {
                image = try await decode(lease, pixels: request.decodePixels, prefetching: true)
                await release(lease)
                try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
            } catch { await release(lease); throw error }
        }
        if image == nil {
            guard !request.candidates.isEmpty else { throw MediaDownloadError.videoContent }
            image = try await loadPreviewImage(candidates: request.candidates, pixels: request.decodePixels,
                                               prefetching: true, retryTransient: false)
        }
        try Task.checkCancellation(); guard expected == generation, let image else { throw CancellationError() }
        return PreparedCoverPreview(request: request, context: context, cacheGeneration: expected, image: image)
    }

    func image(_ url: URL, pixels: Int = 2048) async -> UIImage? { try? await loadImage(url, pixels: pixels) }
    func loadImage(_ url: URL, pixels: Int = 2048, prefetching: Bool = false) async throws -> UIImage {
        try Task.checkCancellation(); await readyForRead(); let expected = generation
        if !url.isFileURL, await disk.isVideo(directory.appendingPathComponent(key(url, video: true))) { throw MediaDownloadError.videoContent }
        let existing = url.isFileURL ? await leaseFile(url) : await leaseCached(url, video: false)
        if let lease = existing {
            do {
                let image = try await decode(lease, pixels: pixels, resource: url, prefetching: prefetching)
                try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
                if let image { await release(lease); return image }
                if url.isFileURL {
                    if await disk.document(url) { throw MediaDownloadError.notImage }
                    if await disk.isVideo(url) { throw MediaDownloadError.videoContent }
                    throw ImageLoadError.decode
                }
                await disk.remove(lease.file, expected: lease.identity); await release(lease)
            } catch { await release(lease); throw error }
        } else if url.isFileURL { throw ImageLoadError.missingLocal }
        let tier = MediaDecodeScheduler.tier(pixels)
        let validationPixels = tier <= 1024 ? tier : 256
        let lease = try await fetchFile(url, video: false, prefetching: prefetching,
                                        imageValidationPixels: validationPixels, reuseInstalledImage: existing == nil)
        do {
            let image = try await decode(lease, pixels: pixels, resource: url, prefetching: prefetching)
            try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
            guard let image else { throw ImageLoadError.decode }
            await release(lease); return image
        } catch { await release(lease); throw error }
    }
    func imageResource(_ url: URL, pixels: Int = 2048) async throws -> CachedImageResource {
        let expected = generation, preview = try await loadImage(url, pixels: pixels)
        let lease: MediaFileLease
        if let existing = url.isFileURL ? await leaseFile(url) : await leaseCached(url, video: false) { lease = existing }
        else { lease = try await fetchFile(url, video: false, reuseInstalledImage: true) }
        let file = lease.file
        let info = await Task.detached(priority: .userInitiated) { MediaImageDecoder.info(file) }.value
        guard !Task.isCancelled, expected == generation else { await release(lease); throw CancellationError() }
        guard let info else { await release(lease); throw ImageLoadError.decode }
        return CachedImageResource(file: file, preview: preview, frameCount: info.frameCount, lease: lease)
    }
    func hasGeneratedPoster(_ source: URL) async -> Bool {
        guard let lease = await leaseFile(posterTarget(source)) else { return false }
        let image = try? await decode(lease, pixels: 512); await release(lease)
        return image != nil && lease.generation == generation && !Task.isCancelled
    }
    private func publishRetainedPoster(_ target: URL, generation expected: Int) async {
        guard let lease = await leaseFile(target) else { return }
        let image = try? await decode(lease, pixels: 512); await release(lease)
        if image != nil, generation == expected, !Task.isCancelled { posterWrites.send(target.lastPathComponent) }
    }
    func storeGeneratedPoster(_ data: Data, source: URL, expectedGeneration: Int,
                              expectedSourceIdentity: MediaRepairStore.Identity? = nil) async throws {
        try Task.checkCancellation(); await ready()
        guard expectedGeneration == generation else { throw CancellationError() }
        var identity = expectedSourceIdentity
        if source.isFileURL, identity == nil { identity = await fileIdentity(source) }
        let valid = await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled, !data.isEmpty, data.count <= 1_048_576,
                  let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(image) as String? == "public.jpeg",
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...512).contains(width), (1...512).contains(height) else { return false }; return true
        }.value
        try Task.checkCancellation(); guard expectedGeneration == generation else { throw CancellationError() }
        guard valid else { throw ImageLoadError.decode }
        let target = posterTarget(source)
        decoder.invalidate(resource: target.absoluteString)
        do {
            let retained = try await disk.poster(data, target: target, source: source, identity: identity,
                generation: expectedGeneration, requireAdmission: true, policy: policy)
            await refresh(); if retained { await publishRetainedPoster(target, generation: expectedGeneration) }
            try Task.checkCancellation(); guard expectedGeneration == generation else { throw CancellationError() }
        } catch { await refresh(); throw error }
    }
    func loadPoster(source: URL, declared: URL?, allowExtraction: Bool, allowLocalExtraction: Bool = false,
                    reusePreparedPreview: Bool = false,
                    onStage: ((PosterDiagnosticStage) -> Void)? = nil) async throws -> UIImage {
        try Task.checkCancellation()
        let expected = generation
        onStage?(.cachedPoster)
        if reusePreparedPreview,
           let preview = preparedCoverMemory(MediaPosterPolicy.coverRequest(source: source, declared: declared, isVideo: true)) {
            return preview
        }
        if let lease = await leaseFile(posterTarget(source)) {
            do {
                let image = try await decode(lease, pixels: 512); await release(lease)
                try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
                if let image { return image }
            } catch { await release(lease); throw error }
        }
        let candidates = MediaPosterPolicy.posterCandidates(source: source, declared: declared)
        var decodeFailure: PosterDiagnosticStage?
        for candidate in candidates {
            let stage: PosterDiagnosticStage = candidate == declared ? .declaredImage : .staticVariant
            onStage?(stage)
            do { return try await loadPreviewImage(candidate) }
            catch MediaDownloadError.videoContent { }
            catch MediaDownloadError.http(let code) where [404, 410].contains(code) { }
            catch ImageLoadError.decode { decodeFailure = stage }
        }
        if let decodeFailure {
            if allowLocalExtraction {
                return try await recoverLocalPosterAfterDecode(source: source, failedStage: decodeFailure, onStage: onStage)
            }
            onStage?(decodeFailure); throw ImageLoadError.decode
        }
        onStage?(.localLookup)
        guard allowExtraction || allowLocalExtraction else { throw MediaDownloadError.videoContent }
        return try await extractPoster(source: source, allowDownload: allowExtraction, onStage: onStage)
    }
    /// Retry a transient preview transport failure once, inside the same view
    /// request. Permanent failures and cancellation never create a retry loop.
    func loadPreviewImage(_ url: URL, pixels: Int = 512, prefetching: Bool = false,
                          retryTransient: Bool = true) async throws -> UIImage {
        do { return try await loadImage(url, pixels: pixels, prefetching: prefetching) }
        catch {
            try Task.checkCancellation()
            guard retryTransient, PreviewRetryPolicy.shouldRetry(error), !url.isFileURL else { throw error }
            try await Task.sleep(for: .milliseconds(300))
            return try await loadImage(url, pixels: pixels, prefetching: prefetching)
        }
    }
    /// Try at most two explicitly supplied preview resources. Only missing,
    /// video, or undecodable content advances to the next candidate.
    func loadPreviewImage(candidates: [URL], pixels: Int = 512, prefetching: Bool = false,
                          retryTransient: Bool = true) async throws -> UIImage {
        var lastFailure: Error = ImageLoadError.decode
        for (index, candidate) in candidates.prefix(2).enumerated() {
            try Task.checkCancellation()
            do { return try await loadPreviewImage(candidate, pixels: pixels, prefetching: prefetching,
                                                   retryTransient: retryTransient) }
            catch is CancellationError { throw CancellationError() }
            catch MediaDownloadError.http(let status) where status == 404 || status == 410 { lastFailure = MediaDownloadError.http(status) }
            catch MediaDownloadError.videoContent { lastFailure = MediaDownloadError.videoContent }
            catch ImageLoadError.decode { lastFailure = ImageLoadError.decode }
            catch { throw error }
            if index == candidates.prefix(2).count - 1 { throw lastFailure }
        }
        throw lastFailure
    }
    private func recoverLocalPosterAfterDecode(source: URL, failedStage: PosterDiagnosticStage,
                    onStage: ((PosterDiagnosticStage) -> Void)?) async throws -> UIImage {
        do { return try await extractPoster(source: source, allowDownload: false, onStage: onStage) }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); onStage?(failedStage); throw ImageLoadError.decode }
    }
    func cachedRepair(_ source: URL, original: URL?, scope: URL, touch: Bool = true) async -> (URL, Bool, MediaFileLease)? {
        await readyForRead(); let expected = generation
        let result = await disk.repairMatch(source, original: original, scope: scope, touch: touch, generation: expected)
        guard expected == generation, !Task.isCancelled else { if let result { await release(result.2) }; return nil }
        return result
    }
    private func localVideoLease(_ source: URL) async -> MediaFileLease? {
        let originalLease = source.isFileURL ? await leaseFile(source) : await leaseCached(source, video: true)
        let scope = source.isFileURL ? source.deletingLastPathComponent() : directory
        let repaired = await cachedRepair(source, original: originalLease?.file, scope: scope)
        if let repaired { if let originalLease { await release(originalLease) }; return repaired.2 }
        return originalLease
    }
    private func extractPoster(source: URL, allowDownload: Bool, onStage: ((PosterDiagnosticStage) -> Void)?) async throws -> UIImage {
        onStage?(.localLookup)
        let id = UUID(), expected = generation
        try await posterJobs.acquire(id); defer { posterJobs.release(id) }
        var temporary: URL?, lease: MediaFileLease?
        do {
            try Task.checkCancellation(); lease = await localVideoLease(source)
            if lease == nil {
                guard allowDownload else { throw MediaDownloadError.videoContent }
                onStage?(.originalDownload)
                guard await availableSpace().map({ $0 >= 1_000_000_000 + 8 * 1024 * 1024 }) ?? true else { throw ImageLoadError.lowSpace }
                let downloaded = try await BoundedDownload.fetch(source, maxBytes: 8 * 1024 * 1024)
                temporary = downloaded
                let file = downloaded.appendingPathExtension("mp4")
                try await moveTemporary(downloaded, to: file); temporary = file; lease = await leaseFile(file)
            }
            guard let input = lease else { throw ImageLoadError.missingLocal }
            let originalSourceIdentity = source.isFileURL ? await fileIdentity(source) : nil
            onStage?(.localFrame)
            let image = try await Self.firstFrame(input.file)
            try Task.checkCancellation()
            guard expected == generation, await fileIdentity(input.file) == input.identity else { throw CancellationError() }
            let data = await Task.detached(priority: .userInitiated) { image.jpegData(compressionQuality: 0.85) }.value
            guard let data else { throw ImageLoadError.decode }
            onStage?(.cacheWrite)
            let sourceIdentity = originalSourceIdentity
            let target = posterTarget(source)
            decoder.invalidate(resource: target.absoluteString)
            let retained = try await disk.poster(data, target: target, source: source, identity: sourceIdentity,
                producedFrom: input, generation: expected, requireAdmission: false, policy: policy)
            await release(input); lease = nil
            if let temporary { await removeTemporary(temporary) }
            await refresh(); if retained { await publishRetainedPoster(target, generation: expected) }
            return image
        } catch {
            if let lease { await release(lease) }; if let temporary { await removeTemporary(temporary) }
            await trim(); throw error
        }
    }
    func transitionFrame(for source: URL) async -> UIImage? {
        let id = UUID(), expected = generation
        do { try await posterJobs.acquire(id) } catch { return nil }; defer { posterJobs.release(id) }
        guard !Task.isCancelled, let lease = await localVideoLease(source) else { return nil }
        let frame = try? await Self.firstFrame(lease.file, forTransition: true)
        let currentIdentity = await fileIdentity(lease.file)
        let valid = !Task.isCancelled && expected == generation && currentIdentity == lease.identity
        await release(lease); return valid ? frame : nil
    }
    nonisolated private static func firstFrame(_ file: URL, forTransition: Bool = false) async throws -> UIImage {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        let edge: CGFloat = forTransition ? 960 : 512
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: edge, height: edge)
        if forTransition {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: UIImage.self) { tasks in
                tasks.addTask { let frame = try await generator.image(at: .zero); return UIImage(cgImage: frame.image) }
                tasks.addTask { try await Task.sleep(for: .seconds(8)); generator.cancelAllCGImageGeneration(); throw ImageLoadError.decode }
                defer { tasks.cancelAll() }
                guard let image = try await tasks.next() else { throw ImageLoadError.decode }; return image
            }
        } onCancel: { generator.cancelAllCGImageGeneration() }
    }
    func fetch(_ url: URL, video: Bool) async -> URL? {
        do { let lease = try await fetchFile(url, video: video); await release(lease); return lease.file }
        catch is CancellationError { return nil }
        catch MediaDownloadError.http(let status) { diagnostics?.note(area: .cache, code: .http, httpStatus: status); return nil }
        catch { diagnostics?.note(area: .cache, code: .loadFailed); return nil }
    }
    func preloadFile(_ url: URL, video: Bool) async throws -> URL {
        let lease = try await fetchFile(url, video: video, videoMaximum: video ? 512 * 1024 * 1024 : Self.imageDownloadMaximum, prefetching: true)
        if video && !url.isFileURL && !Task.isCancelled { videoPreloadWrites.send(url) }
        await release(lease); return lease.file
    }
    func recordPreloadFailure(_ error: Error) -> DiagnosticCode {
        let code: DiagnosticCode
        switch error {
        case MediaDownloadError.limitExceeded: code = .limit
        case MediaDownloadError.http: code = .http
        case ImageLoadError.lowSpace, ImageLoadError.cacheWrite: code = .storage
        case ImageLoadError.queueFull: code = .queueFull
        case ImageLoadError.decode: code = .decode
        default: code = (error as NSError).domain == NSURLErrorDomain ? .network : .loadFailed
        }
        let status: Int?; if case MediaDownloadError.http(let value) = error { status = value } else { status = nil }
        diagnostics?.note(area: .cache, code: code, httpStatus: status); return code
    }
    func setPreloadStatus(_ value: MediaPreloadStatus, owner: UUID) {
        preloadStatusOwner = owner; if preloadStatus != value { preloadStatus = value }
    }
    private func pausePreloadStatus(owner: UUID) {
        guard preloadStatusOwner == owner, var value = preloadStatus else { return }; value.paused = true; value.running = 0
        if preloadStatus != value { preloadStatus = value }
    }
    private func fetchFile(_ url: URL, video: Bool, videoMaximum: Int64 = 64 * 1024 * 1024,
                           progress: (@Sendable (Int64, Int64) -> Void)? = nil, prefetching: Bool = false,
                           imageValidationPixels: Int = 256, reuseInstalledImage: Bool = false,
                           allowQuotaUpgrade: Bool = true) async throws -> MediaFileLease {
        try Task.checkCancellation(); await ready()
        if url.isFileURL { guard let lease = await leaseFile(url) else { throw ImageLoadError.missingLocal }; return lease }
        if video, let lease = await leaseCached(url, video: true) { return lease }
        if video && url.pathExtension.lowercased() == "m3u8" { throw ImageLoadError.decode }
        let downloadKey = key(url, video: video), consumer = UUID(), expected = generation
        let flightID: UUID, task: Task<URL, Error>, inheritedMaximum: Int64
        if var flight = inFlight[downloadKey] {
            flight.consumers.insert(consumer); if !prefetching { flight.foregroundConsumers.insert(consumer) }
            inFlight[downloadKey] = flight; flightID = flight.id; task = flight.task; inheritedMaximum = flight.maximum
            if !prefetching { downloads.setPriority(.foreground, for: flight.id) }
        } else {
            let id = UUID(); flightID = id; inheritedMaximum = video ? videoMaximum : Self.imageDownloadMaximum
            task = Task<URL, Error> {
                // A caller may have missed before another flight installed this file.
                // Recheck inside the registered producer so later callers join the same decision.
                if reuseInstalledImage, let installed = await disk.cachedLease(downloadKey, generation: expected) {
                    guard !Task.isCancelled, expected == generation, inFlight[downloadKey]?.id == id else {
                        await release(installed)
                        throw CancellationError()
                    }
                    inFlight[downloadKey]?.handoff = installed
                    return installed.file
                }
                try Task.checkCancellation()
                guard expected == generation else { throw CancellationError() }
                decoder.invalidate(resource: url.absoluteString)
                let existingForeground = inFlight[downloadKey]?.id == id && inFlight[downloadKey]?.foregroundConsumers.isEmpty == false
                try await downloads.acquire(id, priority: (!prefetching || existingForeground) ? .foreground : .background)
                defer { downloads.release(id) }
                try Task.checkCancellation()
                let requested = video ? videoMaximum : Self.imageDownloadMaximum
                let token: MediaBudgetReservation
                do { token = try await disk.reserveDownload(video: video, requested: requested, prefetching: prefetching,
                    generation: expected, policy: policy) }
                catch ImageLoadError.lowSpace where prefetching { throw PreloadQuotaFailure(maximum: 0) }
                await refresh()
                if var flight = inFlight[downloadKey], flight.id == id { flight.maximum = token.maximum; inFlight[downloadKey] = flight }
                var temporary: URL?
                do {
                    let file: URL
                    do {
                        file = try await BoundedDownload.fetch(url, maxBytes: token.maximum,
                            reserveBytes: videoMaximum > 64 * 1024 * 1024 ? 1_000_000_000 : 0,
                            expectedImage: !video, progress: progress)
                    } catch MediaDownloadError.limitExceeded where prefetching && token.maximum < requested {
                        throw PreloadQuotaFailure(maximum: token.maximum)
                    }
                    temporary = file
                    try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
                    if !video {
                        guard let lease = await leaseFile(file) else { throw ImageLoadError.decode }
                        let valid: Bool
                        let foreground = inFlight[downloadKey]?.foregroundConsumers.isEmpty == false
                        do {
                            // On the installed lease the same identity can reuse these pixels.
                            // The temporary file must not appear in the preview lookup.
                            valid = try await decode(lease, pixels: imageValidationPixels, resource: url,
                                                     prefetching: prefetching && !foreground, publishPreview: false) != nil
                            await release(lease)
                        }
                        catch { await release(lease); throw error }
                        if !valid {
                            if await disk.document(file) { throw MediaDownloadError.notImage }
                            if await disk.isVideo(file) {
                                let probe = file.appendingPathExtension("mp4")
                                try await moveTemporary(file, to: probe); temporary = probe
                                guard (try? await AVURLAsset(url: probe).load(.isPlayable)) == true else { throw ImageLoadError.decode }
                                try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
                                let converted = try await disk.install(probe, name: key(url, video: true), reservation: token, generation: expected, policy: policy)
                                await release(converted)
                                throw MediaDownloadError.videoContent
                            }
                            throw ImageLoadError.decode
                        }
                    }
                    try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
                    let handoff = try await disk.install(file, name: downloadKey, reservation: token, generation: expected, policy: policy)
                    temporary = nil
                    if var flight = inFlight[downloadKey], flight.id == id {
                        flight.handoff = handoff; inFlight[downloadKey] = flight
                    } else { await release(handoff); throw CancellationError() }
                    await releaseReservation(token); return handoff.file
                } catch {
                    if let temporary { await removeTemporary(temporary) }; await releaseReservation(token); throw error
                }
            }
            inFlight[downloadKey] = .init(id: id, task: task, maximum: inheritedMaximum, consumers: [consumer], foregroundConsumers: prefetching ? [] : [consumer])
        }
        defer { leave(downloadKey, flightID: flightID, consumer: consumer) }
        do {
            let result = try await withTaskCancellationHandler {
                let result = try await task.value; try Task.checkCancellation()
                if video, let identity = await fileIdentity(result), identity.size > videoMaximum { throw MediaDownloadError.limitExceeded }
                return result
            } onCancel: { Task { @MainActor in self.leave(downloadKey, flightID: flightID, consumer: consumer) } }
            guard expected == generation, inFlight[downloadKey]?.id == flightID, let handoff = inFlight[downloadKey]?.handoff,
                  let consumerLease = await disk.lease(result, expected: handoff.identity, generation: expected) else { throw CancellationError() }
            await refresh(); return consumerLease
        } catch let quota as PreloadQuotaFailure {
            try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
            guard !prefetching else { throw ImageLoadError.lowSpace }
            let ownMaximum: Int64 = video ? videoMaximum : Self.imageDownloadMaximum
            guard ownMaximum > quota.maximum else { throw MediaDownloadError.limitExceeded }
            guard allowQuotaUpgrade else { throw ImageLoadError.lowSpace }
            if let handoff = removeFlight(downloadKey, id: flightID) { await release(handoff) }
            return try await fetchFile(url, video: video, videoMaximum: videoMaximum, progress: progress, prefetching: false,
                                       imageValidationPixels: imageValidationPixels, reuseInstalledImage: reuseInstalledImage,
                                       allowQuotaUpgrade: false)
        } catch MediaDownloadError.limitExceeded where video && videoMaximum > inheritedMaximum {
            try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
            if let handoff = removeFlight(downloadKey, id: flightID) { await release(handoff) }
            return try await fetchFile(url, video: true, videoMaximum: videoMaximum, progress: progress, prefetching: prefetching, allowQuotaUpgrade: allowQuotaUpgrade)
        }
    }
    @discardableResult private func removeFlight(_ key: String, id: UUID) -> MediaFileLease? {
        guard let flight = inFlight[key], flight.id == id else { return nil }
        inFlight[key] = nil; flight.task.cancel(); return flight.handoff
    }
    private func leave(_ key: String, flightID: UUID, consumer: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.consumers.remove(consumer); let wasForeground = flight.foregroundConsumers.remove(consumer) != nil
        if flight.consumers.isEmpty {
            if let handoff = removeFlight(key, id: flightID) { Task { await self.release(handoff) } }
        }
        else {
            inFlight[key] = flight
            if wasForeground { downloads.setPriority(flight.foregroundConsumers.isEmpty ? .background : .foreground, for: flight.id) }
        }
    }
    func setPrefetchTargets(_ targets: [(URL, Bool)], owner: UUID) async {
        let expected = generation
        await readyForRead()
        guard generation == expected else { return }
        await disk.targets(Set(targets.prefix(24).filter { !$0.0.isFileURL }.map { key($0.0, video: $0.1) }), owner: owner, generation: expected)
    }
    func removePrefetchTargets(owner: UUID) async {
        pausePreloadStatus(owner: owner)
        await ready()
        let expected = generation
        guard await disk.targets(nil, owner: owner, generation: expected), expected == generation else { return }
        await disk.trim(policy, forceScan: false)
        await refresh()
    }
    func hasPrefetchSpace(video: Bool = true) async -> Bool {
        await ready()
        let result = try? await disk.preloadMaximum(video: video, requested: video ? 512 * 1024 * 1024 : Self.imageDownloadMaximum, policy: policy)
        await refresh(); return result != nil
    }
    func clear() async {
        preloadStatus = nil; preloadStatusOwner = nil; generation += 1
        let next = generation, previous = clearBarrier, initialization = self.initialization, disk = self.disk, policy = self.policy
        let handoffs = Array(inFlight).compactMap { key, flight in removeFlight(key, id: flight.id) }
        decoder.clear(); cacheHits = 0
        let barrier = Task {
            await initialization?.value; await previous?.value
            for handoff in handoffs { await disk.release(handoff) }
            await disk.clear(generation: next, policy: policy)
        }
        clearBarrier = barrier; await barrier.value; await refresh()
    }
    func trim() async { await ready(); await disk.trim(policy); await refresh() }
    func commitRepair(_ source: URL, original: URL, identity: MediaRepairStore.Identity, partial: URL, target: URL,
                      content: String, transcoded: Bool, reservation: MediaBudgetReservation, expectedGeneration: Int) async throws -> MediaFileLease {
        await ready()
        return try await disk.commitRepair(source, original: original, expectedIdentity: identity, partial: partial, target: target,
            content: content, transcoded: transcoded, reservation: reservation, generation: expectedGeneration)
    }
}

/// Stop oversized downloads while in progress; never load a whole video into RAM.
enum MediaDownloadError: LocalizedError {
    case limitExceeded, http(Int), notImage, videoContent
    var errorDescription: String? {
        switch self {
        case .limitExceeded: "文件超过下载限制"
        case .http(let code): [404, 410].contains(code) ? "封面地址暂不可用" : (code == 429 ? "请求较多，请稍后重试" : "网络请求失败（\(code)）")
        case .notImage: "站点返回的封面不是图片"
        case .videoContent: "此地址是视频，正在切换播放"
        }
    }
}

final class BoundedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int64
    private let reserveBytes: Int64
    private let expectedImage: Bool
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var activeTask: URLSessionDownloadTask?
    private var limited = false
    private var spaceLimited = false
    private var lastSpaceCheck = Date.distantPast
    private var lastProgress = Date.distantPast
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var session: URLSession?

    private init(maxBytes: Int64, reserveBytes: Int64, expectedImage: Bool, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.maxBytes = maxBytes; self.reserveBytes = reserveBytes; self.expectedImage = expectedImage; self.progress = progress
    }
    static func fetch(_ url: URL, maxBytes: Int64, reserveBytes: Int64 = 0, expectedImage: Bool = false,
                      progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let downloader = BoundedDownload(maxBytes: maxBytes, reserveBytes: reserveBytes, expectedImage: expectedImage, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { downloader.begin(url, continuation: $0) }
        } onCancel: { downloader.cancel() }
    }
    private func begin(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = reserveBytes > 0 ? 600 : 90
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.downloadTask(with: url); activeTask = task
        lock.unlock(); task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = activeTask; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes { limited = true; downloadTask.cancel(); return }
        if reserveBytes > 0 && Date().timeIntervalSince(lastSpaceCheck) > 1 {
            lastSpaceCheck = Date()
            let space = try? MediaFileValues.fresh(FileManager.default.temporaryDirectory).resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let free = space?.volumeAvailableCapacity, Int64(free) < reserveBytes { spaceLimited = true; downloadTask.cancel(); return }
        }
        if Date().timeIntervalSince(lastProgress) > 0.2 || totalBytesWritten == totalBytesExpectedToWrite {
            lastProgress = Date(); progress?(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            result = .failure(MediaDownloadError.http(response.statusCode)); return
        }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
              expectedImage || response.mimeType.map({ $0.hasPrefix("image/") || $0.hasPrefix("video/") || $0 == "application/octet-stream" }) == true,
              let size = try? MediaFileValues.fresh(location).resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, Int64(size) <= maxBytes else {
            result = .failure(ClientError.invalidResponse); return
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: target); result = .success(target) }
        catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let userCancelled = cancelled; activeTask = nil; lock.unlock()
        if limited || spaceLimited || userCancelled || error != nil, case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
        if userCancelled { continuation?.resume(throwing: CancellationError()) }
        else if spaceLimited { continuation?.resume(throwing: ImageLoadError.lowSpace) }
        else if limited { continuation?.resume(throwing: MediaDownloadError.limitExceeded) }
        else if let error { continuation?.resume(throwing: error) }
        else if let result { continuation?.resume(with: result) }
        else { continuation?.resume(throwing: ClientError.invalidResponse) }
        continuation = nil; session.finishTasksAndInvalidate(); self.session = nil
    }
}

/// A verified file and its eviction protection travel together. A lease is
/// released by ID, including after clear; old releases cannot debit new work.
struct MediaFileLease: Sendable {
    let id: UUID
    let file: URL
    let identity: MediaRepairStore.Identity
    let generation: Int
}

private struct MediaDiskPolicy: Sendable, Equatable {
    let capacity: Int64
    let injectedSpace: Int64?
    let usesInjectedSpace: Bool
}
private struct MediaDiskSnapshot: Sendable {
    let generation: Int
    let revision: UInt64
    let bytes: Int64
    let known: Bool
    let pending: Int64
}
struct MediaBudgetReservation: Sendable {
    let id: UUID
    let bytes: Int64
    let maximum: Int64
    let generation: Int
}

/// The cache directory has exactly one mutating owner. Methods containing file
/// transactions do not suspend: protection, admission and install are ordered
/// with clear. The actor never executes on MainActor and never decodes pixels.
private actor MediaDiskStore {
    let directory: URL
    private var initialized = false
    private var generation = 0
    private var revision: UInt64 = 0
    private var contentRevision: UInt64 = 0
    private var latestPolicy: MediaDiskPolicy?
    private struct MaintenanceDemand: Equatable {
        let generation: Int
        let contentRevision: UInt64
        let reclaimRevision: UInt64
        let logical: Int64
        let physical: Int64
        let policy: MediaDiskPolicy?
    }
    private var maintenance: (id: UUID, task: Task<MaintenanceDemand, Never>)?
    /// New protections are checked at unlink; released protections require a
    /// fresh pass over entries an earlier job may already have skipped.
    private var reclaimRevision: UInt64 = 0
    private var touches: [URL: Date] = [:]
    private var inventory: [URL: Entry]?
    private var inventoryRevision: UInt64 = 0
    private var bytes: Int64 = 0
    private var known = false
    private var pins: [String: Int] = [:]
    private var repairPins: [String: Int] = [:]
    private var leases: [UUID: Set<String>] = [:]
    private var clearDeferred: [String: MediaRepairStore.Identity] = [:]
    private(set) var maintenanceYields = 0
    private var upcoming: [UUID: Set<String>] = [:]
    private struct Reservation {
        let bytes: Int64
        let repair: Bool
        /// Already staged files consume logical quota, but need no more writes.
        let physical: Int64
    }
    private var reservations: [UUID: Reservation] = [:]
    private let reserve: Int64 = 1_000_000_000
    private var repairReserved: Int64 { reservations.values.filter(\.repair).reduce(0) { $0 + $1.bytes } }
    private var downloadReserved: Int64 { reservations.values.filter { !$0.repair }.reduce(0) { $0 + $1.bytes } }
    private var physicalReserved: Int64 { reservations.values.reduce(0) { $0 + $1.physical } }
    private var maintenanceDemand: MaintenanceDemand {
        .init(generation: generation, contentRevision: contentRevision, reclaimRevision: reclaimRevision,
              logical: repairReserved + downloadReserved, physical: physicalReserved, policy: latestPolicy)
    }
    init(directory: URL) { self.directory = directory }
    func initialize(_ policy: MediaDiskPolicy) async {
        prepareDirectory()
        await trim(policy)
    }
    func prepareDirectory() {
        guard !initialized else { return }; initialized = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = directory; try? folder.setResourceValues(values)
    }
    func snapshot() -> MediaDiskSnapshot {
        .init(generation: generation, revision: revision, bytes: bytes, known: known, pending: downloadReserved)
    }
    private func changed(files: Bool = false) { revision &+= 1; if files { contentRevision &+= 1; known = false } }
    private func check(_ expected: Int) throws {
        try Task.checkCancellation(); guard expected == generation else { throw CancellationError() }
    }
    func free(_ policy: MediaDiskPolicy) -> Int64? {
        if policy.usesInjectedSpace { return policy.injectedSpace }
        let values = try? MediaFileValues.fresh(directory).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }
    func volumeSpace(_ directory: URL) -> Int64? {
        (try? MediaFileValues.fresh(directory).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }
    func identity(_ file: URL) -> MediaRepairStore.Identity? { MediaRepairStore.identity(file) }
    func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }
    func touch(_ file: URL) {
        let now = Date()
        if let last = touches[file], now.timeIntervalSince(last) < 5 { return }
        touches[file] = now
        if touches.count > 4096 { touches = touches.filter { now.timeIntervalSince($0.value) < 5 } }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
    func cached(_ name: String) -> URL? {
        let file = directory.appendingPathComponent(name)
        guard exists(file) else { return nil }; touch(file); return file
    }
    func previews(_ groups: [[String]]) -> [URL?] {
        groups.map { names in
            for name in names.prefix(2) {
                let digest = name.dropLast(4)
                guard (name.hasSuffix(".img") || name.hasSuffix(".jpg")), digest.utf8.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
                let file = directory.appendingPathComponent(name)
                if let values = try? MediaFileValues.fresh(file).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                   values.isRegularFile == true, values.isSymbolicLink != true { return file }
            }
            return nil
        }
    }
    private func cacheName(_ file: URL) -> String? {
        file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL ? file.lastPathComponent : nil
    }
    private func protected(_ name: String) -> Bool {
        pins[name] != nil || repairPins[name] != nil || leases.values.contains { $0.contains(name) }
    }
    private func evictionProtected(_ name: String) -> Bool {
        protected(name) || upcoming.values.contains { $0.contains(name) }
    }
    func lease(_ file: URL, protecting: String? = nil, expected: MediaRepairStore.Identity? = nil,
               generation expectedGeneration: Int) -> MediaFileLease? {
        let file = MediaFileValues.fresh(file)
        guard expectedGeneration == generation, let identity = identity(file), expected == nil || expected == identity else { return nil }
        let id = UUID()
        var names = Set<String>(); if let name = cacheName(file) { names.insert(name) }
        if let protecting { names.insert(protecting) }
        leases[id] = names
        if cacheName(file) != nil { touch(file) }
        return .init(id: id, file: file, identity: identity, generation: generation)
    }
    func cachedLease(_ name: String, generation expected: Int) -> MediaFileLease? {
        lease(directory.appendingPathComponent(name), generation: expected)
    }
    func release(_ lease: MediaFileLease) {
        guard let names = leases.removeValue(forKey: lease.id) else { return }
        if names.contains(where: { !evictionProtected($0) }) { reclaimRevision &+= 1 }
        for name in names { finishDeferredClear(name) }
    }
    private func finishDeferredClear(_ name: String) {
        guard !protected(name), let expected = clearDeferred.removeValue(forKey: name) else { return }
        let file = directory.appendingPathComponent(name)
        guard identity(file) == expected else { return }
        try? FileManager.default.removeItem(at: file); recordFile(file)
    }
    func pin(_ name: String, repair: Bool, adding: Bool) {
        let wasProtected = evictionProtected(name)
        if repair {
            let count = (repairPins[name] ?? 0) + (adding ? 1 : -1)
            repairPins[name] = count > 0 ? count : nil
        } else {
            let count = (pins[name] ?? 0) + (adding ? 1 : -1)
            pins[name] = count > 0 ? count : nil
        }
        if wasProtected, !evictionProtected(name) { reclaimRevision &+= 1 }
        if !adding { finishDeferredClear(name) }
    }
    @discardableResult
    func targets(_ names: Set<String>?, owner: UUID, generation expected: Int) -> Bool {
        guard expected == generation else { return false }
        let removed = (upcoming[owner] ?? []).subtracting(names ?? [])
        upcoming[owner] = names
        guard removed.contains(where: { !evictionProtected($0) }) else { return false }
        reclaimRevision &+= 1
        return true
    }
    /// Scan-only versions compare raw birthtime precision; they never replace
    /// the Foundation identity used by leases, decoders or repair receipts.
    private struct FileVersion: Equatable {
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }
    private struct FileMetadata {
        let size: Int64
        let modified: Date
        let identity: FileVersion
    }
    /// One uncached C path stat supplies size/mtime/inode/birthtime together,
    /// without a per-file NSDictionary or URL resource-value cache. lstat does
    /// not follow symlinks. Failures/nonregular types stay UNKNOWN; zero-byte
    /// regular files retain their raw inode/birthtime version.
    private func metadata(_ file: URL) throws -> FileMetadata {
        var attributes = stat()
        let failure: Int32 = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            guard Darwin.lstat(path, &attributes) == 0 else { return errno }
            return 0
        }
        guard failure == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_size >= 0 else {
            throw ImageLoadError.cacheWrite
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(attributes.st_mtimespec.tv_sec) +
            TimeInterval(attributes.st_mtimespec.tv_nsec) / 1_000_000_000)
        let identity = FileVersion(inode: UInt64(attributes.st_ino),
            birthSeconds: Int64(attributes.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(attributes.st_birthtimespec.tv_nsec))
        return .init(size: Int64(attributes.st_size), modified: modified, identity: identity)
    }
    private func missingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain &&
            [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
    }
    private struct Entry {
        let file: URL; let size: Int64; let date: Date
        let identity: FileVersion
    }
    private struct OldestFirst {
        private var values: [Entry] = []
        mutating func insert(_ entry: Entry) {
            values.append(entry); var child = values.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard values[child].date < values[parent].date else { break }
                values.swapAt(child, parent); child = parent
            }
        }
        mutating func pop() -> Entry? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let first = values[0]; values[0] = values.removeLast(); var parent = 0
            while parent * 2 + 1 < values.count {
                let left = parent * 2 + 1, right = left + 1
                let child = right < values.count && values[right].date < values[left].date ? right : left
                guard values[child].date < values[parent].date else { break }
                values.swapAt(child, parent); parent = child
            }
            return first
        }
    }
    func trim(_ policy: MediaDiskPolicy, forceScan: Bool = true) async {
        latestPolicy = policy
        if forceScan, inventory != nil { inventory = nil; changed(files: true) }
        if !forceScan, inventoryRevision == contentRevision, inventory != nil, withinBudget(policy) { return }
        for _ in 0..<3 {
            let job: (id: UUID, task: Task<MaintenanceDemand, Never>)
            if let maintenance { job = maintenance }
            else {
                job = (UUID(), Task { await self.scanAndTrim() })
                maintenance = job
            }
            let covered = await job.task.value
            if maintenance?.id == job.id { maintenance = nil }
            if covered == maintenanceDemand { return }
            if let current = latestPolicy, withinBudget(current) { return }
            // A joined job may have finished before this admission arrived.
            // Apply the new pressure with a fresh bounded pass, never accept
            // its stale result or let an old waiter clear a newer job.
        }
        known = false; changed()
    }
    private func withinBudget(_ policy: MediaDiskPolicy) -> Bool {
        known && bytes + repairReserved + downloadReserved <= policy.capacity &&
            free(policy).map { $0 >= reserve + physicalReserved } == true
    }
    private func scanAndTrim() async -> MaintenanceDemand {
        // A content mutation invalidates accounting, but a new pin/lease can be
        // honored directly at deletion. Repeated external mutation is UNKNOWN,
        // never a fabricated zero or an unbounded retry loop.
        for _ in 0..<3 {
            var expectedRevision = contentRevision
            let expectedGeneration = generation
            var failed = false, heap = OldestFirst(), total: Int64 = 0, count = 0
            var scanned: [URL: Entry] = [:]
            if let inventory, inventoryRevision == expectedRevision {
                for entry in inventory.values {
                    scanned[entry.file] = entry; heap.insert(entry); total += entry.size; count += 1
                    if count.isMultiple(of: 64) { maintenanceYields += 1; await Task.yield() }
                    if generation != expectedGeneration || contentRevision != expectedRevision { break }
                }
            } else {
            guard (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
                  let files = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [],
                    options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else {
                known = false; changed(); return maintenanceDemand
            }
            while let file = files.nextObject() as? URL {
                guard let values = try? metadata(file) else { failed = true; break }
                let entry = Entry(file: file, size: values.size, date: values.modified, identity: values.identity)
                scanned[file] = entry; heap.insert(entry)
                total += values.size; count += 1
                if count.isMultiple(of: 64) {
                    maintenanceYields += 1; await Task.yield()
                    if generation != expectedGeneration || contentRevision != expectedRevision { break }
                }
            }
            }
            if generation != expectedGeneration || contentRevision != expectedRevision { continue }
            guard !failed else { known = false; changed(); return maintenanceDemand }
            // Inventory records file identities and sizes. Protection changes
            // matter only once eviction starts skipping protected entries.
            let expectedReclaim = reclaimRevision
            var removed = 0, restart = false
            while let entry = heap.pop() {
                guard let policy = latestPolicy else { break }
                let reserved = repairReserved + downloadReserved
                let budget = min(max(0, policy.capacity - reserved), max(0, total + (free(policy) ?? reserve) - reserve - physicalReserved))
                if total <= budget { break }
                let name = entry.file.lastPathComponent
                guard !evictionProtected(name) else { continue }
                guard let values = try? metadata(entry.file),
                      values.size == entry.size, values.identity == entry.identity else { restart = true; break }
                let currentDate = values.modified
                if currentDate > entry.date {
                    heap.insert(.init(file: entry.file, size: entry.size, date: currentDate, identity: entry.identity)); continue
                }
                // No suspension between protection/identity recheck and unlink.
                if (try? FileManager.default.removeItem(at: entry.file)) != nil {
                    total -= entry.size; scanned[entry.file] = nil; touches[entry.file] = nil
                    changed(files: true); expectedRevision = contentRevision
                }
                removed += 1
                if removed.isMultiple(of: 32) {
                    maintenanceYields += 1; await Task.yield()
                    if generation != expectedGeneration || contentRevision != expectedRevision || reclaimRevision != expectedReclaim { restart = true; break }
                }
            }
            if restart || reclaimRevision != expectedReclaim { continue }
            inventory = scanned; inventoryRevision = contentRevision
            bytes = total; known = true; changed(); return maintenanceDemand
        }
        known = false; changed(); return maintenanceDemand
    }
    private func recordFile(_ file: URL) {
        guard cacheName(file) != nil else { changed(); return }
        let previousRevision = contentRevision, wasKnown = known
        changed(files: true)
        guard var index = inventory, inventoryRevision == previousRevision else { known = false; return }
        let oldSize = index[file]?.size ?? 0
        do {
            let values = try metadata(file)
            index[file] = .init(file: file, size: values.size, date: values.modified, identity: values.identity)
        } catch {
            guard missingFile(error) else { inventory = nil; known = false; return }
            index[file] = nil; touches[file] = nil
        }
        bytes = max(0, bytes - oldSize + (index[file]?.size ?? 0))
        inventory = index; inventoryRevision = contentRevision; known = wasKnown
    }
    func clear(generation next: Int, policy: MediaDiskPolicy) async {
        guard next > generation else { return }; generation = next; upcoming = [:]
        var count = 0
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants]) {
            while let file = files.nextObject() as? URL {
                guard generation == next else { return }
                let name = file.lastPathComponent
                if !protected(name) { try? FileManager.default.removeItem(at: file); changed(files: true) }
                else if let identity = identity(file) { clearDeferred[name] = identity }
                count += 1; if count.isMultiple(of: 32) { maintenanceYields += 1; await Task.yield() }
            }
        }
        await trim(policy)
    }
    func preloadMaximum(video: Bool, requested: Int64, policy: MediaDiskPolicy) async throws -> Int64 {
        latestPolicy = policy
        if !known { await trim(policy) }
        guard known, let free = free(policy) else { throw ImageLoadError.cacheWrite }
        var names = Set(pins.keys).union(repairPins.keys).union(upcoming.values.flatMap { $0 })
        for namesInLease in leases.values { names.formUnion(namesInLease) }
        var held: Int64 = 0
        for name in names {
            let file = directory.appendingPathComponent(name)
            do { held += try metadata(file).size }
            catch {
                guard missingFile(error) else { throw ImageLoadError.cacheWrite }
            }
        }
        let physical = max(0, free - reserve - physicalReserved)
        let headroom = min(128 * 1024 * 1024, policy.capacity / 4)
        let quota = max(0, policy.capacity - headroom - held - repairReserved - downloadReserved)
        let maximum = min(requested, physical, quota)
        guard maximum >= min(requested, video ? 8 * 1024 * 1024 : 1024 * 1024) else { throw ImageLoadError.lowSpace }
        return maximum
    }
    func reserveDownload(video: Bool, requested: Int64, prefetching: Bool, generation expected: Int,
                         policy: MediaDiskPolicy) async throws -> MediaBudgetReservation {
        try check(expected)
        latestPolicy = policy
        let maximum = prefetching ? try await preloadMaximum(video: video, requested: requested, policy: policy) : requested
        var admittedMaximum = maximum
        var amount = prefetching ? maximum : (video ? min(requested, 64 * 1024 * 1024) : MediaCache.imageDownloadMaximum)
        let minimumFree = reserve + physicalReserved + amount
        if let available = free(policy), available < minimumFree {
            await trim(policy)
            if let after = free(policy), after < minimumFree { throw ImageLoadError.lowSpace }
        }
        try check(expected)
        // A maintenance await can admit another reservation. Recompute against
        // the current ledger before installing this token, without suspension.
        if prefetching {
            admittedMaximum = try await preloadMaximum(video: video, requested: requested, policy: policy)
            amount = admittedMaximum
        }
        try check(expected)
        if let available = free(policy), available < reserve + physicalReserved + amount { throw ImageLoadError.lowSpace }
        let token = MediaBudgetReservation(id: UUID(), bytes: amount, maximum: admittedMaximum, generation: generation)
        reservations[token.id] = .init(bytes: amount, repair: false, physical: amount); changed(); return token
    }
    func reserveRepair(generation expected: Int, policy: MediaDiskPolicy) async throws -> MediaBudgetReservation {
        try check(expected)
        let requested = min(536_870_912, max(0, policy.capacity / 2)), id = UUID()
        reservations[id] = .init(bytes: requested, repair: true, physical: requested); await trim(policy)
        do { try check(expected) } catch { reservations[id] = nil; throw error }
        let amount: Int64 = known ? min(requested, max(0, policy.capacity - bytes - (repairReserved - requested) - downloadReserved),
            max(0, (free(policy) ?? reserve) - reserve - (physicalReserved - requested))) : 0
        reservations[id] = .init(bytes: amount, repair: true, physical: amount); changed()
        return .init(id: id, bytes: amount, maximum: amount, generation: generation)
    }
    func releaseBudget(_ token: MediaBudgetReservation, policy: MediaDiskPolicy) async {
        guard reservations.removeValue(forKey: token.id) != nil else { return }; await trim(policy, forceScan: false)
    }
    func install(_ staged: URL, name: String, reservation token: MediaBudgetReservation,
                 generation expected: Int, policy: MediaDiskPolicy) async throws -> MediaFileLease {
        try check(expected)
        guard token.generation == expected, reservations[token.id]?.bytes == token.bytes,
              let stagedIdentity = identity(staged), stagedIdentity.size <= token.maximum else { throw ImageLoadError.cacheWrite }
        let admission = UUID(), target = directory.appendingPathComponent(name)
        // A completed transfer no longer needs its worst-case download budget.
        // Convert that token to the actual file admission before suspending;
        // eviction and commit then observe the same reservation ledger.
        reservations[token.id] = nil
        reservations[admission] = .init(bytes: stagedIdentity.size, repair: true, physical: 0)
        await trim(policy, forceScan: false)
        do {
            try check(expected)
            guard reservations[admission]?.bytes == stagedIdentity.size, identity(staged) == stagedIdentity else { throw CancellationError() }
            guard known, bytes + repairReserved + downloadReserved <= policy.capacity,
                  free(policy).map({ $0 >= reserve + physicalReserved }) ?? false else { throw ImageLoadError.lowSpace }
            guard !exists(target) || !protected(name) else { throw ImageLoadError.cacheWrite }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            recordFile(target)
            guard let lease = lease(target, generation: expected) else { throw ImageLoadError.cacheWrite }
            reservations[admission] = nil; changed(); return lease
        } catch {
            reservations[admission] = nil; recordFile(target); throw error
        }
    }
    func remove(_ file: URL, expected: MediaRepairStore.Identity? = nil) {
        if let expected, identity(file) != expected { return }
        try? FileManager.default.removeItem(at: file); recordFile(file)
    }
    func move(_ from: URL, to: URL) throws { try FileManager.default.moveItem(at: from, to: to); recordFile(from); recordFile(to) }
    func isVideo(_ file: URL) -> Bool { MediaImageDecoder.looksLikeVideo(file) }
    func document(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }; defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        var text = String(decoding: data, as: UTF8.self)
        if text.unicodeScalars.first?.value == 0xfeff { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("<")
    }
    func poster(_ data: Data, target: URL, source: URL, identity expectedIdentity: MediaRepairStore.Identity?,
                producedFrom: MediaFileLease? = nil, generation expected: Int, requireAdmission: Bool,
                policy: MediaDiskPolicy) async throws -> Bool {
        try check(expected)
        let id = UUID(), amount = Int64(data.count)
        if requireAdmission { reservations[id] = .init(bytes: amount, repair: true, physical: amount); await trim(policy) }
        do {
            try check(expected)
            if let producedFrom, identity(producedFrom.file) != producedFrom.identity { throw CancellationError() }
            if source.isFileURL {
                guard let current = identity(source) else { throw ImageLoadError.missingLocal }
                guard expectedIdentity == nil || current == expectedIdentity else { throw CancellationError() }
            }
            if requireAdmission {
                guard reservations[id] != nil, known, bytes + repairReserved + downloadReserved <= policy.capacity,
                      free(policy).map({ $0 >= reserve + physicalReserved }) ?? false else { throw ImageLoadError.lowSpace }
            }
            guard !exists(target) || !protected(target.lastPathComponent) else { throw ImageLoadError.cacheWrite }
            try data.write(to: target, options: .atomic)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            recordFile(target); reservations[id] = nil; await trim(policy, forceScan: false)
            return expected == generation && exists(target)
        } catch { reservations[id] = nil; await trim(policy); throw error }
    }
    func repairMatch(_ source: URL, original: URL?, scope: URL, touch: Bool,
                     generation expected: Int) -> (URL, Bool, MediaFileLease)? {
        guard expected == generation,
              let match = MediaRepairStore.cached(source, original: original, directory: scope, touch: false),
              let lease = lease(match.url, generation: expected) else { return nil }
        return (match.url, match.transcoded, lease)
    }
    func commitRepair(_ source: URL, original: URL, expectedIdentity: MediaRepairStore.Identity,
                      partial: URL, target: URL, content: String, transcoded: Bool,
                      reservation: MediaBudgetReservation, generation expected: Int) throws -> MediaFileLease {
        try check(expected)
        guard reservation.generation == expected, reservations[reservation.id]?.bytes == reservation.bytes,
              identity(original) == expectedIdentity else { throw CancellationError() }
        guard let output = identity(partial), output.size <= max(0, reservation.bytes - 4096) else { throw MediaRepairError.lowSpace }
        recordFile(partial)
        let oldTargetBytes = identity(target)?.size ?? 0
        let stagedBytesInCache: Int64 = cacheName(partial) == nil ? 0 : output.size
        guard let policy = latestPolicy, known,
              bytes - stagedBytesInCache - oldTargetBytes + output.size + 4096 + repairReserved - reservation.bytes + downloadReserved <= policy.capacity else { throw MediaRepairError.lowSpace }
        guard !exists(target) || !leases.values.contains(where: { $0.contains(target.lastPathComponent) }) else { throw MediaRepairError.output }
        if exists(target) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: partial, to: target)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        try MediaRepairStore.commit(source, original: original, content: content, transcoded: transcoded,
            output: target, directory: target.deletingLastPathComponent())
        guard let lease = lease(target, generation: expected) else { throw MediaRepairError.output }
        recordFile(partial); recordFile(target); recordFile(MediaRepairStore.receiptURL(source, directory: target.deletingLastPathComponent()))
        reservations[reservation.id] = nil; changed()
        return lease
    }
}

/// One decode per file revision/pixel tier/policy, shared by actual consumers.
/// Queue bookkeeping is cheap MainActor state; ImageIO runs only in the worker.
@MainActor private final class MediaDecodeScheduler {
    private struct Flight {
        let id: UUID
        let task: Task<UIImage?, Error>
        var consumers: Set<UUID>
        var foregroundConsumers: Set<UUID>
    }
    private struct PreviewSlot: Hashable {
        let generation: Int
        let resource: String
        let tier: Int
    }
    private let queue = MediaLoadQueue(limit: 2, maximumWaiting: 64)
    private let memory = NSCache<NSString, UIImage>()
    private let maximumIndexedPreviews = 512
    private var requestIndex: [PreviewSlot: String] = [:]
    private var slotsByResource: [String: Set<PreviewSlot>] = [:]
    private var insertionOrder: [PreviewSlot] = []
    private var flights: [String: Flight] = [:]
    private(set) var decoded = 0
    init() { memory.totalCostLimit = 64 * 1024 * 1024 }
    static func tier(_ requested: Int) -> Int { [256, 512, 1024, 2048, 4096].first { $0 >= requested } ?? 4096 }
    func clear() {
        memory.removeAllObjects(); requestIndex = [:]; slotsByResource = [:]; insertionOrder = []
        for flight in flights.values { flight.task.cancel() }; flights = [:]
    }
    func memoryPreview(generation: Int, resources: [String], pixels: Int) -> UIImage? {
        let tier = Self.tier(pixels)
        for resource in resources {
            let slot = PreviewSlot(generation: generation, resource: resource, tier: tier)
            if let key = requestIndex[slot], let image = memory.object(forKey: key as NSString) { return image }
        }
        return nil
    }
    func invalidate(resource: String) {
        let slots = slotsByResource.removeValue(forKey: resource) ?? []
        for slot in slots {
            if let key = requestIndex.removeValue(forKey: slot) { memory.removeObject(forKey: key as NSString) }
        }
        if !slots.isEmpty { insertionOrder.removeAll { slots.contains($0) } }
    }
    func cachedImage(_ lease: MediaFileLease, pixels: Int, resource: String) -> UIImage? {
        let tier = Self.tier(pixels), identity = lease.identity
        let key = "\(lease.generation)|\(resource)|\(identity.size)|\(identity.inode)|\(identity.created)|\(tier)|still"
        return memory.object(forKey: key as NSString)
    }
    func image(_ lease: MediaFileLease, pixels: Int, resource: String, priority: MediaLoadQueue.Priority,
               publishPreview: Bool) async throws -> UIImage? {
        try Task.checkCancellation()
        let tier = Self.tier(pixels), identity = lease.identity
        let key = "\(lease.generation)|\(resource)|\(identity.size)|\(identity.inode)|\(identity.created)|\(tier)|still"
        let slot = PreviewSlot(generation: lease.generation, resource: resource, tier: tier)
        if let image = memory.object(forKey: key as NSString) {
            if publishPreview { index(slot, key: key) }
            return image
        }
        let consumer = UUID(), id: UUID, task: Task<UIImage?, Error>
        let foreground = priority == .foreground
        if var flight = flights[key] {
            flight.consumers.insert(consumer)
            if foreground { flight.foregroundConsumers.insert(consumer) }
            flights[key] = flight; id = flight.id; task = flight.task
            if foreground { queue.promote(id) }
        } else {
            id = UUID()
            let jobID = id, file = lease.file
            task = Task {
                let visibleConsumer = flights[key]?.foregroundConsumers.isEmpty == false
                try await queue.acquire(jobID, priority: visibleConsumer ? .foreground : .background)
                defer { queue.release(jobID) }
                try Task.checkCancellation(); decoded += 1
                let worker = Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard !Task.isCancelled, let image = MediaImageDecoder.preview(file, pixels: tier) else { return nil }
                    return UIImage(cgImage: image)
                }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); return result
            }
            flights[key] = .init(id: id, task: task, consumers: [consumer],
                                 foregroundConsumers: foreground ? [consumer] : [])
        }
        defer { leave(key, id: id, consumer: consumer) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: {
            Task { @MainActor in self.leave(key, id: id, consumer: consumer) }
        }
        try Task.checkCancellation()
        if let result {
            memory.setObject(result, forKey: key as NSString,
                cost: Int(result.size.width * result.size.height * result.scale * result.scale * 4))
            if publishPreview { index(slot, key: key) }
        }
        return result
    }

    private func index(_ slot: PreviewSlot, key: String) {
        if requestIndex[slot] == nil {
            insertionOrder.append(slot)
            slotsByResource[slot.resource, default: []].insert(slot)
        }
        requestIndex[slot] = key
        while insertionOrder.count > maximumIndexedPreviews {
            let expired = insertionOrder.removeFirst()
            if let expiredKey = requestIndex.removeValue(forKey: expired) {
                memory.removeObject(forKey: expiredKey as NSString)
                slotsByResource[expired.resource]?.remove(expired)
                if slotsByResource[expired.resource]?.isEmpty == true { slotsByResource[expired.resource] = nil }
            }
        }
    }

    private func leave(_ key: String, id: UUID, consumer: UUID) {
        guard var flight = flights[key], flight.id == id else { return }
        flight.consumers.remove(consumer)
        let wasForeground = flight.foregroundConsumers.remove(consumer) != nil
        if flight.consumers.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else {
            flights[key] = flight
            if wasForeground && flight.foregroundConsumers.isEmpty { queue.setPriority(.background, for: id) }
        }
    }
}
