// Appended to the actual cache source by verify-image-cache.py, so the tests
// can exercise the file-private disk actor without changing its visibility.
private extension MediaDiskStore {
    func holdCompletedMaintenanceForQuotaChecks() async {
        let covered = maintenanceDemand
        let task = Task { covered }
        _ = await task.value
        maintenance = (UUID(), task)
    }
    func outstandingQuotaChecks() -> Int { reservations.count }
}

// Model the suspension after the first disk miss without depending on a timer.
extension MediaCache {
    func checkImageInstalledBetweenMissAndFetch(_ url: URL) async throws {
        let initial = await leaseCached(url, video: false)
        precondition(initial == nil)
        let before = decodeCount
        _ = try await loadImage(url, pixels: 200)
        guard let first = await leaseCached(url, video: false) else { preconditionFailure("Missing completed image") }
        let identity = first.identity
        await release(first)
        let late = try await fetchFile(url, video: false, reuseInstalledImage: true)
        let sameFile = late.identity == identity
        let pixels = try await decode(late, pixels: 240, resource: url)
        await release(late)
        precondition(sameFile && pixels != nil && decodeCount == before + 1,
                     "A resumed image miss must reuse the completed transfer and decoded tier")
    }
}

enum PreviewQuotaChecks {
    static func run(root: URL) async throws {
        let fm = FileManager.default, capacity: Int64 = 1_000_000_000
        let policy = MediaDiskPolicy(capacity: capacity, injectedSpace: 8_000_000_000, usesInjectedSpace: true)
        func resident(_ folder: URL, size: Int64) throws -> URL {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("old-resident.img")
            fm.createFile(atPath: file.path, contents: Data())
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(size)); try handle.close()
            return file
        }
        for round in 0..<5 {
            let folder = root.appendingPathComponent("quota176-\(round)")
            _ = try resident(folder, size: capacity - 128*1024*1024)
            // A real maintenance pass must yield while inspecting this inventory.
            for i in 0..<80 { try Data([1]).write(to: folder.appendingPathComponent("old-\(i).img")) }
            let disk = MediaDiskStore(directory: folder)
            await disk.initialize(policy)
            if round == 1 { await disk.holdCompletedMaintenanceForQuotaChecks() }
            var tokens: [MediaBudgetReservation] = [], stages: [URL] = []
            for i in 0..<4 {
                tokens.append(try await disk.reserveDownload(video: false, requested: 64*1024*1024,
                    prefetching: false, generation: 0, policy: policy))
                let staged = root.appendingPathComponent("staged176-\(round)-\(i)")
                try Data(repeating: 1,count: 32*1024).write(to: staged); stages.append(staged)
            }
            let before = await disk.snapshot(); precondition(before.pending == 256*1024*1024)
            if round < 2 {
                for i in 0..<4 {
                    let lease = try await disk.install(stages[i], name:"preview-\(i).img", reservation:tokens[i], generation:0,policy:policy)
                    await disk.release(lease); await disk.releaseBudget(tokens[i],policy:policy)
                }
            } else {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for i in 0..<4 { let token=tokens[i],stage=stages[i]
                        group.addTask {
                            let lease = try await disk.install(stage,name:"preview-\(i).img",reservation:token,generation:0,policy:policy)
                            await disk.release(lease); await disk.releaseBudget(token,policy:policy)
                        }
                    }
                    for try await _ in group {}
                }
            }
            let after = await disk.snapshot(), outstanding = await disk.outstandingQuotaChecks()
            precondition(after.known && after.pending == 0 && outstanding == 0 && after.bytes <= capacity)
            for i in 0..<4 { precondition(fm.fileExists(atPath: folder.appendingPathComponent("preview-\(i).img").path)) }
        }
        for mode in ["lease", "pin", "upcoming"] {
            let folder = root.appendingPathComponent("quota176-release-\(mode)")
            let old = try resident(folder,size:capacity-128*1024*1024)
            let disk = MediaDiskStore(directory:folder);await disk.initialize(policy)
            var held: MediaFileLease?
            let owner = UUID()
            if mode == "lease" { held = await disk.lease(old,generation:0) }
            if mode == "pin" { await disk.pin(old.lastPathComponent,repair:false,adding:true) }
            if mode == "upcoming" { await disk.targets([old.lastPathComponent],owner:owner,generation:0) }
            var tokens: [MediaBudgetReservation] = []
            for _ in 0..<4 { tokens.append(try await disk.reserveDownload(video:false,requested:64*1024*1024,prefetching:false,generation:0,policy:policy)) }
            await disk.trim(policy,forceScan:false)
            precondition(fm.fileExists(atPath:old.path),"Maintenance may not delete a protected resident")
            await disk.holdCompletedMaintenanceForQuotaChecks()
            if let held { await disk.release(held) }
            if mode == "pin" { await disk.pin(old.lastPathComponent,repair:false,adding:false) }
            if mode == "upcoming" { await disk.targets(nil,owner:owner,generation:0) }
            await disk.trim(policy,forceScan:false)
            let reclaimed = await disk.snapshot()
            precondition(reclaimed.known && reclaimed.bytes + reclaimed.pending <= capacity,
                         "A completed old job cannot hide newly reclaimable space after \(mode) release")
            for token in tokens { await disk.releaseBudget(token,policy:policy) }
            let outstanding = await disk.outstandingQuotaChecks();precondition(outstanding == 0)
        }
        let protectedFolder = root.appendingPathComponent("quota176-protected")
        let protected = try resident(protectedFolder,size:capacity-10*1024*1024)
        let disk = MediaDiskStore(directory:protectedFolder); await disk.initialize(policy)
        guard let held = await disk.lease(protected,generation:0) else { preconditionFailure("Protected fixture missing") }
        let token = try await disk.reserveDownload(video:false,requested:64*1024*1024,prefetching:false,generation:0,policy:policy)
        let stage = root.appendingPathComponent("quota176-too-large");try Data(repeating:1,count:20*1024*1024).write(to:stage)
        do { _ = try await disk.install(stage,name:"rejected.img",reservation:token,generation:0,policy:policy);preconditionFailure("Protected quota was bypassed") }
        catch ImageLoadError.lowSpace {}
        let identity = await disk.identity(protected), pending = await disk.outstandingQuotaChecks()
        precondition(identity == held.identity && pending == 0); await disk.release(held)

        let physicalFolder = root.appendingPathComponent("quota176-staged")
        let physical = MediaDiskStore(directory:physicalFolder); await physical.initialize(policy)
        let budget = try await physical.reserveDownload(video:false,requested:64*1024*1024,prefetching:false,generation:0,policy:policy)
        let ready = root.appendingPathComponent("quota176-already-on-disk");try Data(repeating:1,count:32*1024).write(to:ready)
        let lowPhysical = MediaDiskPolicy(capacity:capacity,injectedSpace:1_000_000_001,usesInjectedSpace:true)
        let lease = try await physical.install(ready,name:"staged.img",reservation:budget,generation:0,policy:lowPhysical)
        await physical.release(lease)
        do {
            _ = try await physical.poster(Data(repeating:1,count:32*1024),target:physicalFolder.appendingPathComponent("unwritten.jpg"),
                source:URL(string:"https://fixture.invalid/source176")!,identity:nil,generation:0,requireAdmission:true,policy:lowPhysical)
            preconditionFailure("In-memory poster write ignored its physical obligation")
        } catch ImageLoadError.lowSpace {}
        let final = await physical.outstandingQuotaChecks();precondition(final == 0)
        print("PreviewQuotaChecks: five four-image rounds; completed-job lease/pin/upcoming release recovery; protected real quota rejection; staged physical bytes counted once; in-memory poster physical reserve; empty ledgers passed")
    }
}
