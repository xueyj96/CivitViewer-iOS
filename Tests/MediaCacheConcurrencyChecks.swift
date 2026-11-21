import Foundation
import CryptoKit

/// Boundary checks use actual cache files and workers, with disposable data.
@MainActor enum MediaCacheConcurrencyChecks {
    static func run(root: URL, jpeg: Data, localSource: URL, remoteImage: URL) async throws {
        try await checkStartupCoverReads(root: root, jpeg: jpeg)
        let folder = root.appendingPathComponent("actor-boundaries", isDirectory: true)
        let cache = MediaCache(directoryURL: folder, monitorNetwork: false, diagnostics: nil,
            availableBytesProvider: { 2_000_000_000 })
        await cache.trim()
        // A true empty regular file is a known zero. A directory or failed
        // metadata read cannot be silently accounted as the same zero state.
        let empty = folder.appendingPathComponent("empty-regular.img")
        try Data().write(to: empty, options: .atomic)
        await cache.trim()
        precondition(cache.diskUsageKnown && cache.diskBytes == 0,
                     "A real zero-byte regular cache file remains a known zero")
        let outsideDirectory = root.appendingPathComponent("nonregular-metadata-source", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        let probe = root.appendingPathComponent("metadata-state-probe.jpeg")
        try jpeg.write(to: probe, options: .atomic)
        guard let probeLease = await cache.leaseFile(probe) else { preconditionFailure("Metadata probe lease missing") }
        let nonregular = folder.appendingPathComponent("nonregular-entry", isDirectory: true)
        try await cache.moveTemporary(outsideDirectory, to: nonregular)
        // release refreshes the observable snapshot without running a scan, so
        // this assertion tests recordFile's failed incremental accounting.
        await cache.release(probeLease)
        precondition(!cache.diskUsageKnown,
                     "recordFile rejects nonregular metadata as UNKNOWN before a full reconciliation")
        await cache.trim()
        precondition(!cache.diskUsageKnown,
                     "A full scan also preserves UNKNOWN for a nonregular cache entry")
        try FileManager.default.removeItem(at: nonregular)
        await cache.trim()
        precondition(cache.diskUsageKnown && cache.diskBytes == 0,
                     "Removing the unsupported entry restores the known true zero")
        let local = root.appendingPathComponent("decode-revision.jpeg")
        try jpeg.write(to: local, options: .atomic)
        let before = cache.decodeCount
        let first = Task { try await cache.loadImage(local, pixels: 200) }
        let second = Task { try await cache.loadImage(local, pixels: 240) }
        _ = try await first.value; _ = try await second.value
        precondition(cache.decodeCount == before + 1, "Same resource revision and quantized tier share one actual decode")
        _ = try await cache.loadImage(local, pixels: 500)
        precondition(cache.decodeCount == before + 2, "A different pixel tier has its own decode")
        try jpeg.write(to: local, options: .atomic)
        _ = try await cache.loadImage(local, pixels: 200)
        precondition(cache.decodeCount == before + 3, "Replacing the resource invalidates the old decode revision")

        // A small remote view reuses the 256px validation decode after rename;
        // validation must not first materialize an unrelated 2048px bitmap.
        let remoteBefore = cache.decodeCount
        let gridA = Task { try await cache.loadImage(remoteImage, pixels: 200) }
        let gridB = Task { try await cache.loadImage(remoteImage, pixels: 240) }
        _ = try await gridA.value; _ = try await gridB.value
        precondition(cache.decodeCount == remoteBefore + 1, "A remote small-grid transfer validates and displays with one shared 256px decode")

        try await cache.checkImageInstalledBetweenMissAndFetch(
            remoteImage.deletingLastPathComponent().appendingPathComponent("late-cover-miss"))

        for (pixels, suffix) in [(512, "timeline-poster"), (1024, "collection-cover")] {
            let resource = remoteImage.deletingLastPathComponent().appendingPathComponent(suffix)
            let start = cache.decodeCount
            _ = try await cache.loadPreviewImage(resource, pixels: pixels)
            precondition(cache.decodeCount - start == 1, "A cold \(suffix) validates and displays with one decode at the requested tier")
        }

        let source = root.appendingPathComponent("actor-source.mp4")
        try FileManager.default.copyItem(at: localSource, to: source)
        guard let originalIdentity = await cache.fileIdentity(source) else { preconditionFailure("Fixture identity missing") }
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: localSource, to: source)
        do {
            try await cache.storeGeneratedPoster(jpeg, source: source, expectedGeneration: cache.repairGeneration,
                expectedSourceIdentity: originalIdentity)
            preconditionFailure("A replaced local producer source committed a poster")
        } catch is CancellationError { }

        let posterSource = URL(string: "https://fixture.invalid/concurrent-poster")!
        let generation = cache.repairGeneration
        let pending = Task { try await cache.storeGeneratedPoster(jpeg, source: posterSource, expectedGeneration: generation) }
        await cache.clear()
        do { try await pending.value } catch is CancellationError { }
        let staleRetained = await cache.hasGeneratedPoster(posterSource)
        precondition(!staleRetained, "A clear fence prevents a late old-generation poster from remaining on disk")

        try await cache.storeGeneratedPoster(jpeg, source: posterSource, expectedGeneration: cache.repairGeneration)
        let posterFile = folder.appendingPathComponent(cache.posterCacheKey(for: posterSource))
        guard let held = await cache.leaseFile(posterFile) else { preconditionFailure("Poster lease missing") }
        let identity = held.identity
        do {
            try await cache.storeGeneratedPoster(jpeg, source: posterSource, expectedGeneration: cache.repairGeneration)
            preconditionFailure("A live leased target was replaced")
        } catch ImageLoadError.cacheWrite { }
        let retainedIdentity = await cache.fileIdentity(posterFile)
        precondition(retainedIdentity == identity, "Rejecting replacement preserves the leased file identity")
        await cache.clear()
        let heldDuringClear = await cache.fileExists(posterFile)
        precondition(heldDuringClear, "Clear retains a file while its real consumer holds a lease")
        await cache.release(held); await cache.release(held)
        let removedAfterRelease = await cache.fileExists(posterFile)
        precondition(!removedAfterRelease, "The last release completes deferred clear exactly once")

        // More than one maintenance batch; a live lease must survive all LRU
        // deletion decisions even when physical budget becomes zero.
        var free: Int64 = 2_000_000_000
        let batchFolder = root.appendingPathComponent("actor-batched-maintenance", isDirectory: true)
        let batched = MediaCache(directoryURL: batchFolder, monitorNetwork: false, diagnostics: nil,
            availableBytesProvider: { free })
        await batched.trim()
        for index in 0..<192 {
            let name = SHA256.hash(data: Data("batch-\(index)".utf8)).map { String(format: "%02x", $0) }.joined() + ".img"
            try jpeg.write(to: batchFolder.appendingPathComponent(name), options: .atomic)
        }
        let heldFile = batchFolder.appendingPathComponent("held.img")
        try jpeg.write(to: heldFile, options: .atomic)
        guard let keep = await batched.leaseFile(heldFile) else { preconditionFailure("Maintenance lease missing") }
        free = 0
        let priorYields = await batched.maintenanceYieldCount()
        let maintenance = Task { await batched.trim() }
        guard let secondHold = await batched.leaseFile(heldFile) else { preconditionFailure("Concurrent lease missing") }
        await batched.release(keep)
        await maintenance.value
        let afterYields = await batched.maintenanceYieldCount()
        let surviving = await batched.fileExists(heldFile)
        precondition(afterYields > priorYields && surviving, "Batched maintenance yields and respects the latest live lease")
        await batched.release(secondHold); await batched.trim()
        let reclaimed = await batched.fileExists(heldFile)
        precondition(!reclaimed && batched.diskBytes == 0, "Released protection returns to the unchanged zero-budget LRU policy")
        print("MediaCacheConcurrencyChecks: zero-byte/nonregular UNKNOWN, decode tiers/revision, producer identity, clear fence, live replacement, idempotent lease release and batched maintenance passed")
    }
    private static func checkStartupCoverReads(root: URL, jpeg: Data) async throws {
        let folder = root.appendingPathComponent("startup-cover-reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let covers = (0..<8).map { URL(string: "https://fixture.invalid/startup-\($0)")! }
        for cover in covers {
            let key = SHA256.hash(data: Data(cover.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            try jpeg.write(to: folder.appendingPathComponent(key + ".img"))
        }
        for index in covers.count..<2048 {
            try Data([0]).write(to: folder.appendingPathComponent("cached-\(index).img"))
        }
        let cache = MediaCache(directoryURL: folder, monitorNetwork: false, diagnostics: nil,
                               availableBytesProvider: { 2_000_000_000 })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in covers {
                group.addTask { _ = try await cache.loadPreviewImage(url, pixels: 512) }
            }
            try await group.waitForAll()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !cache.diskUsageKnown, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let yields = await cache.maintenanceYieldCount()
        precondition(cache.cacheHits == covers.count && cache.decodeCount == covers.count,
                     "Every visible startup image uses the local file and a single decode")
        precondition(cache.diskUsageKnown && cache.diskBytes == Int64(covers.count * jpeg.count + 2048 - covers.count),
                     "Startup accounting publishes the complete inventory alongside foreground reads")
        precondition(yields == 2048 / 64, "Releasing a read lease during inventory must not restart the scan")
    }

}
