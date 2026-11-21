import Foundation
import UIKit
import AVFoundation
import CivitMediaEngine

private final class MediaEngineJob: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = cvm_job_create() else { throw MediaRepairError.output }
        self.pointer = pointer
    }
    deinit { cvm_job_destroy(pointer) }
    func cancel() { cvm_job_cancel(pointer) }
}

private final class MediaRepairValidation: @unchecked Sendable {
    let asset: AVURLAsset
    let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var cancelled = false
    init(_ file: URL) {
        asset = AVURLAsset(url: file)
        generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 160, height: 160)
    }
    func register(_ value: AVAssetReader) {
        lock.lock(); reader = value; let stopped = cancelled; lock.unlock()
        if stopped { value.cancelReading() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = reader; lock.unlock()
        value?.cancelReading(); generator.cancelAllCGImageGeneration(); asset.cancelLoading()
    }
}

/// All viewing entries use the same serial, on-demand repair pipeline. Merely
/// prefetching a video never starts a conversion. Cancellation retains originals.
@MainActor final class MediaRepair {
    static let shared = MediaRepair()
    private let queue = MediaLoadQueue(limit: 1, maximumWaiting: 2)
    private let cache: MediaCache
    private let offline: OfflineLibrary
    private let reserve: Int64 = 1_000_000_000
    init(cache: MediaCache? = nil, offline: OfflineLibrary? = nil) { self.cache = cache ?? .shared; self.offline = offline ?? .shared }

    struct Result {
        let url: URL; let transcoded: Bool; let reused: Bool; let lease: MediaFileLease?
        init(url: URL, transcoded: Bool, reused: Bool, lease: MediaFileLease? = nil) {
            self.url = url; self.transcoded = transcoded; self.reused = reused; self.lease = lease
        }
    }
    func cached(_ address: URL, offline isOffline: Bool) async -> Result? {
        let offlineScope = isOffline && address.isFileURL
        guard !offlineScope || offline.ownsRepairSource(address) else { return nil }
        let originalLease = address.isFileURL ? await cache.leaseFile(address) : await cache.leaseCached(address, video: true)
        let scope = offlineScope ? address.deletingLastPathComponent() : cache.repairDirectory
        let match = await cache.cachedRepair(address, original: originalLease?.file, scope: scope, touch: !offlineScope)
        if let originalLease { await cache.release(originalLease) }
        guard let match else { return nil }
        return .init(url: match.0, transcoded: match.1, reused: true, lease: match.2)
    }
    func repair(_ address: URL, offline isOffline: Bool, forceTranscode: Bool = false, diagnosticWorkID: Int? = nil,
                progress: @escaping (MediaRepairStage, Double?) -> Void) async throws -> Result {
        let offlineScope = isOffline && address.isFileURL
        let binding = offlineScope ? offline.bindingID : nil
        let id = UUID(); progress(.waiting, nil)
        try await queue.acquire(id); defer { queue.release(id) }
        try Task.checkCancellation()
        if let binding, binding != offline.bindingID { throw CancellationError() }
        if !forceTranscode, let existing = await cached(address, offline: isOffline) { return existing }
        if ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { throw MediaRepairError.paused }
        let cacheGeneration = cache.repairGeneration
        let scope = offlineScope ? address.deletingLastPathComponent() : cache.repairDirectory
        let access = offlineScope ? offline.beginRepair(address) : nil
        guard !offlineScope || access != nil else { throw MediaRepairError.unavailable }
        defer { if let access { offline.finishRepair(access) } }
        if !address.isFileURL { await cache.pin(address) }
        do {
            let original: URL
            if address.isFileURL { original = address }
            else {
                progress(.downloading, nil)
                original = try await cache.repairOriginal(address) { written, total in
                    Task { @MainActor in progress(.downloading, total > 0 ? min(1, Double(written) / Double(total)) : nil) }
                }
            }
            let sourceIdentity: MediaRepairStore.Identity
            if let access { sourceIdentity = try await offline.repairIdentity(access) }
            else if let identity = await cache.fileIdentity(original) { sourceIdentity = identity }
            else { throw MediaRepairError.unavailable }
            func check() async throws {
                try Task.checkCancellation()
                if let access { guard offline.acceptsRepair(access) else { throw CancellationError() } }
                else {
                    guard cache.repairGeneration == cacheGeneration,
                          await cache.fileIdentity(original) == sourceIdentity else { throw CancellationError() }
                }
            }
            try await check(); progress(.inspecting, nil)
            let fingerprint = Task.detached(priority: .userInitiated) { try MediaRepairStore.contentHash(original) }
            let content = try await withTaskCancellationHandler { try await fingerprint.value } onCancel: { fingerprint.cancel() }
            try await check()
            let info = try await runProbe(original); try await check()
            let sourceKind: PlaybackDiagnosticSource = offlineScope ? .offline : (address.isFileURL ? .local : .cache)
            LocalDiagnosticsStore.shared.note(area: .playback, code: .repairStarted,
                playback: PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: sourceKind, requestedURL: address,
                    sourceURL: original, recoveryAttempted: false, error: nil, eventStatusCodes: [],
                    videoCodec: PlaybackVideoCodec(rawValue: Int(info.video_codec)) ?? .unknown))
            for transcode in forceTranscode ? [true] : [false, true] {
                try await check()
                if transcode && info.hdr != 0 { throw MediaRepairError.hdr }
                let reservation: MediaBudgetReservation?
                let budget: Int64
                if let access { reservation = nil; budget = try await offline.reserveRepairBudget(access) }
                else { let token = try await cache.repairReservation(); reservation = token; budget = token.bytes }
                let limit = max(0, budget - 4096)
                let target = scope.appendingPathComponent(MediaRepairStore.outputName(address, content: content, transcoded: transcode))
                var stage: URL?
                var partial: URL?
                func finishAttempt() async {
                    if let stage { offline.discardRepairStaging(stage) }
                    else if let partial { await cache.removeTemporary(partial) }
                    if !offlineScope, let partial {
                        await cache.unprotectRepairFile(partial); await cache.unprotectRepairFile(target)
                    }
                    if let access { offline.releaseRepairBudget(access) }
                    else if let reservation { await cache.releaseReservation(reservation) }
                }
                do {
                    guard offlineScope ? offline.diskUsageKnown : cache.diskUsageKnown else { throw MediaRepairError.storageUnknown }
                    guard limit >= 8 * 1024 * 1024 else { throw MediaRepairError.lowSpace }
                    if let access { stage = try await offline.makeRepairStaging(access) }
                    let output = (stage ?? scope).appendingPathComponent(MediaRepairStore.stem(address) + "-" + UUID().uuidString + ".partial.mp4")
                    partial = output
                    if !offlineScope { await cache.protectRepairFile(output); await cache.protectRepairFile(target) }
                    progress(transcode ? .transcoding : .remuxing, nil)
                    try await convert(original: original, output: output, transcode: transcode, limit: limit, check: check) { fraction in
                        progress(transcode ? .transcoding : .remuxing, fraction)
                    }
                    try await check(); progress(.validating, nil)
                    guard try await validate(output, expected: info) else {
                        if transcode { throw MediaRepairError.validation }
                        await finishAttempt(); continue
                    }
                    try await check()
                    let final: URL, lease: MediaFileLease?
                    if let access {
                        final = try await offline.commitRepair(access, staged: output, identity: sourceIdentity, content: content, transcoded: transcode)
                        lease = await cache.leaseFile(final)
                    } else {
                        guard let reservation else { throw MediaRepairError.output }
                        let committed = try await cache.commitRepair(address, original: original, identity: sourceIdentity,
                            partial: output, target: target, content: content, transcoded: transcode,
                            reservation: reservation, expectedGeneration: cacheGeneration)
                        final = committed.file; lease = committed
                    }
                    await finishAttempt()
                    LocalDiagnosticsStore.shared.note(area: .playback, code: .repairCompleted,
                        playback: PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: sourceKind,
                            requestedURL: address, sourceURL: final, recoveryAttempted: true, error: nil,
                            eventStatusCodes: [], repairMode: transcode ? .transcode : .remux,
                            videoCodec: transcode ? .h264 : (PlaybackVideoCodec(rawValue: Int(info.video_codec)) ?? .unknown)))
                    if !address.isFileURL { await cache.unpin(address) }; await cache.trim()
                    return .init(url: final, transcoded: transcode, reused: false, lease: lease)
                } catch {
                    await finishAttempt()
                    switch error {
                    case is CancellationError, MediaRepairError.lowSpace, MediaRepairError.paused, MediaRepairError.expired: throw error
                    default: if transcode { throw error }
                    }
                }
            }
            throw MediaRepairError.validation
        } catch {
            if !address.isFileURL { await cache.unpin(address) }; await cache.trim(); throw error
        }
    }

    private func runProbe(_ file: URL) async throws -> CVMInfo {
        let job = try MediaEngineJob()
        var expired = false
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)); expired = true; job.cancel() } catch { }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            let pair = await Task.detached(priority: .userInitiated) {
                var info = CVMInfo()
                let code = cvm_probe(job.pointer, file.path, &info)
                return (code, info)
            }.value
            try Task.checkCancellation()
            if expired { throw MediaRepairError.expired }
            try Self.checkCode(pair.0)
            return pair.1
        } onCancel: { job.cancel() }
    }
    private func convert(original: URL, output: URL, transcode: Bool, limit: Int64,
                         check: @escaping () async throws -> Void, progress: @escaping (Double?) -> Void) async throws {
        let job = try MediaEngineJob(), started = ContinuousClock.now
        var stopped: MediaRepairError?
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await check()
                    if ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { stopped = .paused; job.cancel(); return }
                    let free = await cache.volumeAvailableSpace(at: output.deletingLastPathComponent())
                    if let free, free < reserve { stopped = .lowSpace; job.cancel(); return }
                    if ContinuousClock.now - started > .seconds(1200) { stopped = .expired; job.cancel(); return }
                    let fraction = cvm_job_progress(job.pointer)
                    progress(fraction >= 0 ? min(fraction, 0.99) : nil)
                    try await Task.sleep(for: .milliseconds(200))
                } catch { job.cancel(); return }
            }
        }
        defer { monitor.cancel() }
        let code = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                cvm_convert(job.pointer, original.path, output.path, Int32(transcode ? CVM_TRANSCODE : CVM_REMUX), limit)
            }.value
        } onCancel: { job.cancel() }
        if let stopped { throw stopped }
        try Task.checkCancellation(); try await check(); try Self.checkCode(code)
    }
    private static func checkCode(_ code: Int32) throws {
        switch Int(code) {
        case CVM_OK: return
        case CVM_CANCELLED: throw CancellationError()
        case CVM_INPUT, CVM_DAMAGED, CVM_DECODE: throw MediaRepairError.damaged
        case CVM_UNSUPPORTED, CVM_TIMING: throw MediaRepairError.unsupported
        case CVM_HDR: throw MediaRepairError.hdr
        case CVM_LIMIT: throw MediaRepairError.lowSpace
        default: throw MediaRepairError.output
        }
    }
    private func validate(_ file: URL, expected: CVMInfo) async throws -> Bool {
        let state = MediaRepairValidation(file)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { try await Self.validate(state, expected: expected) }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    state.cancel(); throw MediaRepairError.validation
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
        } onCancel: { state.cancel() }
    }
    nonisolated private static func validate(_ state: MediaRepairValidation, expected: CVMInfo) async throws -> Bool {
            let asset = state.asset
            guard try await asset.load(.isPlayable) else { return false }
            let video = try await asset.loadTracks(withMediaType: .video)
            guard !video.isEmpty else { return false }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                  expected.duration <= 0 || abs(duration - expected.duration) <= max(1, expected.duration * 0.02) else { return false }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard (expected.has_audio != 0) == !audio.isEmpty else { return false }
            if let track = audio.first {
                let decodable = try await Task.detached(priority: .userInitiated) {
                    let reader = try AVAssetReader(asset: asset)
                    state.register(reader)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    output.alwaysCopiesSampleData = false
                    guard reader.canAdd(output) else { return false }
                    reader.add(output)
                    guard reader.startReading() else { return false }
                    defer { reader.cancelReading() }
                    return output.copyNextSampleBuffer() != nil
                }.value
                guard decodable else { return false }
            }
            // Decode first frame; isPlayable alone is insufficient evidence.
            _ = try await state.generator.image(at: .zero)
            try Task.checkCancellation()
            return true
    }
}
