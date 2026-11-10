import Foundation
import Combine

struct OfflineRepairAccess: Sendable {
    let id = UUID()
    let binding: UUID
    let source: URL
    let permit = OfflineWritePermit()
}

/// Durable, account-scoped files. Browsing-cache eviction never touches this directory.
@MainActor final class OfflineLibrary: ObservableObject {
    private enum Activity {
        case normal(String)
        case attention(String)
        case waitingForNetwork(String)

        var message: String {
            switch self {
            case .normal(let message), .attention(let message), .waitingForNetwork(let message): message
            }
        }
    }

    static let shared = OfflineLibrary()
    @Published private(set) var accountID: Int?
    @Published private(set) var bindingID = UUID()
    @Published private(set) var records: [OfflineRecord] = []
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var diskUsageKnown = false
    @Published private(set) var busy = false
    @Published private var activity = Activity.normal("等待账号")
    @Published private(set) var currentID: Int?
    @Published private(set) var pausedTaskID: Int?
    @Published private(set) var progress: Double?
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var pausedByUser = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var posterIDs = Set<Int>()
    private var omittedIDs = Set<Int>()
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var bindingIdentity: String?
    private var bindingPermit = OfflineWritePermit()
    private var downloadPermit = OfflineWritePermit()
    private(set) var loading = false
    private var cleaning = false
    private var needsStageRecovery = true
    private var membershipVersions: [Int: Int] = [:]
    private var conditionalRemoval: (ids: Set<Int>, permit: OfflineWritePermit)?
    private var active = true
    private var network = BackgroundNetworkState.offline
    private var networkObservation: AnyCancellable?
    private var rescanRequested = false
    private var healthy = true
    private var lastPersisted = Date.distantPast
    private var indexBytes: Int64 = 0
    private var repairs: [UUID: OfflineRepairAccess] = [:]
    private var repairReservations: [UUID: Int64] = [:]
    private var repairFamilyBytes: [String: Int64] = [:]
    private weak var session: SiteSession?
    private let files = OfflineFileStore()
    private let root: URL
    private(set) var directory: URL?
    var autoEnabled: Bool { UserDefaults.standard.object(forKey: "offlineAutoSave") as? Bool ?? true }
    var wifiOnly: Bool { UserDefaults.standard.object(forKey: "offlineWifiOnly") as? Bool ?? true }
    var capacity: Int64 {
        let value = UserDefaults.standard.object(forKey: "offlineLimitGB") as? Int ?? 10
        return Int64([1,5,10,20,50].contains(value) ? value : 10) * 1_000_000_000
    }
    var readyCount: Int { records.filter { $0.fileState == .ready }.count }
    private(set) var status: String {
        get { activity.message }
        set { activity = .normal(newValue) }
    }
    var queueNotice: String? {
        switch activity {
        case .normal: nil
        case .attention(let message), .waitingForNetwork(let message): message
        }
    }
    var networkWaitNotice: String? {
        guard case .waitingForNetwork = activity else { return nil }
        return network.connected ? "连接非计费 Wi-Fi 后可下载" : "联网后可下载"
    }
    var canNetwork: Bool { network.allowsSync(wifiOnly: wifiOnly) }
    var canPauseWork: Bool { worker != nil && !cleaning }
    var downloadRecords: [OfflineRecord] {
        records.filter { $0.fileState != .ready && $0.cloudState == .saved && !omittedIDs.contains($0.id) }
    }
    var mediaItems: [MediaItem] {
        guard let directory else { return [] }
        return records.filter { $0.fileState == .ready }.map { $0.media(in: directory, hasPoster: posterIDs.contains($0.id)) }
    }

    private init() {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled {
            root = ViewportAuditQA.offlineRoot
            active = false; status = "本地高度检查夹具；同步已停用"
            return // Do not start the production network monitor for this isolated run.
        }
        #endif
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitOffline", isDirectory: true)
        networkObservation = BackgroundNetworkMonitor.shared.observe { [weak self] in
            self?.networkChanged(to: $0)
        }
    }

    private func networkChanged(to state: BackgroundNetworkState) {
        let wasAllowed = canNetwork
        network = state
        if wasAllowed && !canNetwork && busy {
            pause(with: .waitingForNetwork(networkWaitMessage))
        } else if case .waitingForNetwork = activity {
            activity = canNetwork ? .normal("网络已恢复") : .waitingForNetwork(networkWaitMessage)
        }
        if !wasAllowed && canNetwork && active && autoEnabled, let session {
            requestSync(session: session)
        }
    }

    private var networkWaitMessage: String { network.connected ? "等待 Wi-Fi" : "离线，可浏览已保存作品" }

    func bind(accountID: Int?, session: SiteSession) async {
        guard !Task.isCancelled else { return }
        self.session = session
        let identity = session.tagLibraryIdentity
        guard self.accountID != accountID || bindingIdentity != identity else { return }
        bindingPermit.invalidate()
        bindingPermit = OfflineWritePermit()
        repairs.values.forEach { $0.permit.invalidate() }
        bindingID = UUID()
        bindingIdentity = identity
        let scope = bindingID
        let permit = bindingPermit
        loading = accountID != nil
        cleaning = false
        membershipVersions = [:]
        conditionalRemoval = nil
        pausedByUser = false
        rescanRequested = false
        pause(reason: "切换账号")
        pausedTaskID = nil
        self.accountID = accountID; records = []; omittedIDs = []; lastScan = nil; diskBytes = 0; indexBytes = 0; directory = nil; healthy = true; lastPersisted = .distantPast
        diskUsageKnown = false; repairFamilyBytes = [:]; posterIDs = []
        guard let accountID else { status = "登录后可管理当前账号的离线收藏"; return }
        status = "正在读取离线收藏…"
        let folder = OfflineFileStore.directory(root: root, owner: accountID)
        let recoveryRoot = needsStageRecovery ? root : nil
        needsStageRecovery = false
        let load = files.enqueue({
            if let recoveryRoot { OfflineFileStore.recoverStaging(in: recoveryRoot) }
            try permit.check()
            return try OfflineFileStore.load(directory: folder, owner: accountID)
        }, completed: { [weak self] result in
            guard let self, self.acceptsBinding(scope) else { return }
            self.loading = false
            self.directory = folder
            switch result {
            case .success(let value):
                self.records = value.manifest.records.filter { $0.id > 0 }
                self.omittedIDs = value.manifest.omittedIDs
                self.lastScan = value.manifest.lastScan
                if let snapshot = value.snapshot { self.apply(snapshot, directory: folder) }
                self.activity = self.diskUsageKnown ? .normal("已读取本地收藏") : .attention("离线空间暂时无法统计，已暂停写入")
            case .failure:
                self.healthy = false
                self.activity = .attention("本地收藏目录读取失败，已停止自动写入")
            }
        })
        _ = await load.result
    }

    func setActive(_ value: Bool) {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled {
            active = false
            if busy { pause(reason: "本地高度检查夹具；同步已停用") }
            return
        }
        #endif
        active = value
        if !value { pause(reason: "后台已暂停，回到 App 后继续") }
        else if autoEnabled, let session { requestSync(session: session) }
    }
    func pause(reason: String = "已暂停") {
        pause(with: .normal(reason))
    }
    private func pause(with activity: Activity) {
        if let currentID { pausedTaskID = currentID }
        generation += 1
        downloadPermit.invalidate()
        downloadPermit = OfflineWritePermit()
        worker?.cancel(); worker = nil; currentID = nil; progress = nil; downloadedBytes = 0
        if !cleaning { busy = false; self.activity = activity }
    }
    func pauseDownloads() {
        pausedByUser = true
        pause()
    }
    func resumeAll(session: SiteSession, includeRemovedCopies: Bool = false) {
        guard !loading, !cleaning else { return }
        pausedByUser = false
        if includeRemovedCopies { omittedIDs = []; schedulePersist(force: true) }
        requestSync(session: session, manual: true)
    }

    func download(_ id: Int, session: SiteSession) {
        guard !busy, downloadRecords.contains(where: { $0.id == id }) else { return }
        requestSync(session: session, manual: true, only: id)
    }

    func requestSync(session: SiteSession, manual: Bool = false, only targetID: Int? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled {
            if ViewportAuditQA.downloadTasksEnabled, manual, !busy, targetID == nil, let pausedTaskID {
                seedDownloadProgressForQA(pausedTaskID)
            }
            return
        }
        #endif
        self.session = session
        guard !loading, !cleaning, repairs.isEmpty else { return }
        guard manual || (autoEnabled && !pausedByUser) else { return }
        guard active, healthy, acceptsBinding(bindingID), let owner = accountID,
              session.account?.id == owner, session.hasCollectionAccess else { return }
        guard canNetwork else { activity = .waitingForNetwork(networkWaitMessage); return }
        if busy { rescanRequested = true; return }
        let revision = generation
        let permit = downloadPermit
        let resumedID = targetID == nil ? pausedTaskID : nil
        if targetID == nil { pausedTaskID = nil }
        busy = true; status = "正在核对本地空间…"
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == self.generation {
                    self.busy = false; self.currentID = nil; self.progress = nil; self.downloadedBytes = 0; self.worker = nil
                    if self.rescanRequested { self.rescanRequested = false; self.requestSync(session: session) }
                }
            }
            do {
                let known = await self.reconcileFiles()
                try self.check(owner, revision)
                guard known else { self.activity = .attention("离线空间暂时无法统计，已暂停下载和转换"); return }
                self.status = "正在扫描全部收藏…"
                try await self.sync(session: session, owner: owner, revision: revision, permit: permit, targetID: targetID, resumedID: resumedID)
            } catch is CancellationError {
                if revision == self.generation { self.status = "已暂停" }
            } catch {
                guard (try? self.check(owner, revision)) != nil else { return }
                self.activity = .attention("同步未完成，已保存文件保留，可稍后重试")
                try? await self.persist(force: true)
            }
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Drive the real card controls with a cancellable local fixture, without fetching media.
    func seedDownloadProgressForQA(_ id: Int) {
        guard ViewportAuditQA.downloadTasksEnabled, worker == nil, downloadRecords.contains(where: { $0.id == id }) else { return }
        pausedTaskID = nil; currentID = id; progress = 0.42; busy = true
        worker = Task { _ = try? await Task.sleep(for: .seconds(600)) }
    }
    #endif

    private func acceptsBinding(_ scope: UUID) -> Bool {
        bindingID == scope && bindingIdentity == session?.tagLibraryIdentity
    }

    private func check(_ owner: Int, _ revision: Int) throws {
        try Task.checkCancellation()
        guard accountID == owner, session?.account?.id == owner, generation == revision, acceptsBinding(bindingID), active else {
            throw CancellationError()
        }
        guard canNetwork else { throw CancellationError() }
    }

    func refreshTags(session: SiteSession) async {
        guard !busy, !loading, acceptsBinding(bindingID), active, canNetwork, let owner = accountID, session.account?.id == owner else { return }
        let ids = records.filter { $0.tagNames == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        busy = true; let revision = generation
        defer {
            if revision == generation {
                busy = false
                if rescanRequested { rescanRequested = false; requestSync(session: session) }
            }
        }
        for offset in stride(from: 0, to: ids.count, by: 30) {
            do {
                try check(owner, revision)
                let batch = Array(ids[offset..<min(offset + 30, ids.count)])
                let items = try await session.mediaItems(ids: batch)
                try check(owner, revision)
                for item in items {
                    if let names = item.tagNames, let index = records.firstIndex(where: { $0.id == item.id }) { records[index].tagNames = names }
                }
                try await persist(force: true)
            } catch { break }
        }
        if revision == generation { status = "收藏标签已更新；仍有 \(records.filter { $0.tagNames == nil }.count) 项待核实" }
    }

    private func sync(session: SiteSession, owner: Int, revision: Int, permit: OfflineWritePermit, targetID: Int?, resumedID: Int?) async throws {
        try await session.refreshCollections(); try check(owner, revision)
        var sources: [Int: MediaItem] = [:], membership: [Int: Set<Int>] = [:]
        for collection in session.collections {
            var cursor: String?, cursors = Set<String>()
            repeat {
                try check(owner, revision)
                let page = try await session.collectionPage(id: collection.id, filter: FeedFilter(), cursor: cursor, allAccessibleLevels: true, includeTags: true)
                try check(owner, revision)
                for id in page.metadata.sourceIDs ?? page.items.map(\.id) { membership[id, default: []].insert(collection.id) }
                for item in page.items where item.id > 0 && item.isSupported {
                    sources[item.id] = item
                    if let index = records.firstIndex(where: { $0.id == item.id }) {
                        records[index].username = item.username; records[index].creatorID = item.creatorID
                        if let names = item.tagNames { records[index].tagNames = names }
                    } else if !omittedIDs.contains(item.id) {
                        records.append(.init(id: item.id, video: item.isVideo, username: item.username, creatorID: item.creatorID, browsingLevel: item.browsingLevel, collectionIDs: [collection.id], cloudState: .saved))
                        records[records.count - 1].tagNames = item.tagNames
                    }
                }
                status = "已扫描 \(sources.count) 项可访问收藏"
                try await persist()
                cursor = page.metadata.nextCursor
                if let cursor, !cursors.insert(cursor).inserted { throw ClientError.invalidResponse }
            } while cursor != nil
        }
        // Only a complete scan may establish missing candidates. Check membership
        // separately because a hidden/unavailable image can be omitted from a grid.
        for id in records.map(\.id) {
            try check(owner, revision)
            guard let index = records.firstIndex(where: { $0.id == id }) else { continue }
            if let folders = membership[id] {
                records[index].collectionIDs = folders; records[index].cloudState = .saved; records[index].checkedAt = Date()
            } else if records[index].cloudState != .localOnly {
                do {
                    let folders = try await session.allSavedMembership(id)
                    try check(owner, revision)
                    if let index = records.firstIndex(where: { $0.id == id }) {
                        records[index].collectionIDs = folders; records[index].cloudState = folders.isEmpty ? .localOnly : .saved; records[index].checkedAt = Date()
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try check(owner, revision)
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].cloudState = .unknown }
                }
            }
        }
        lastScan = Date(); try await persist(force: true)
        var downloadIDs = targetID.map { [$0] } ?? sources.keys.sorted(by: >)
        if let resumedID, let index = downloadIDs.firstIndex(of: resumedID) {
            downloadIDs.remove(at: index)
            downloadIDs.insert(resumedID, at: 0)
        }
        for id in downloadIDs {
            try check(owner, revision)
            guard !omittedIDs.contains(id), let item = sources[id], let index = records.firstIndex(where: { $0.id == id }), records[index].fileState != .ready else { continue }
            let budget = await downloadBudget()
            try check(owner, revision)
            guard budget > 1024 else {
                activity = .attention("离线空间已满或可用空间不足，整理后继续")
                try await persist(force: true)
                return
            }
            currentID = id; progress = nil; downloadedBytes = 0; status = "正在保存 \(item.isVideo ? "视频" : "图片") #\(id)…"
            do { try await save(item, owner: owner, revision: revision, budget: budget, permit: permit) }
            catch is CancellationError { throw CancellationError() }
            catch MediaDownloadError.limitExceeded, OfflineFileStoreError.limitExceeded {
                try check(owner, revision)
                activity = .attention("当前作品超过剩余离线空间，扩大上限或整理后继续")
                try await persist(force: true)
                return
            }
            catch {
                try check(owner, revision)
                if let index = records.firstIndex(where: { $0.id == id }), records[index].fileState != .ready {
                    records[index].fileState = .failed
                }
                try await persist()
            }
        }
        let known = await reconcileFiles()
        try check(owner, revision)
        guard known else { activity = .attention("离线空间暂时无法统计，已暂停写入"); return }
        try await persist(force: true)
        try check(owner, revision)
        if let targetID {
            if records.first(where: { $0.id == targetID })?.fileState == .ready { status = "已下载作品 #\(targetID)" }
            else { status = "作品 #\(targetID) 暂未下载，可稍后重试" }
            return
        }
        let failed = records.filter { $0.fileState == .failed }.count
        let skipped = Set(sources.keys).intersection(omittedIDs).count
        status = failed == 0 ? (skipped == 0 ? "已保存全部可访问收藏" : "已保存 \(readyCount) 项，按你的设置跳过 \(skipped) 项") : "已保存 \(readyCount) 项，\(failed) 项失败，可重试"
    }

    private func save(_ item: MediaItem, owner: Int, revision: Int, budget: Int64, permit: OfflineWritePermit) async throws {
        guard diskUsageKnown else { throw MediaRepairError.storageUnknown }
        guard let directory, let source = item.mediaURL, source.scheme == "https", source.pathExtension.lowercased() != "m3u8",
              let record = records.first(where: { $0.id == item.id }) else { throw ClientError.invalidResponse }
        let target = directory.appendingPathComponent(record.fileName)
        var copied = false
        if let cached = MediaCache.shared.cached(source, video: item.isVideo) {
            if item.isVideo { MediaCache.shared.pin(source) }
            defer { if item.isVideo { MediaCache.shared.unpin(source) } }
            do {
                _ = try await files.enqueue {
                    try OfflineFileStore.install(cached, at: target, copying: true, limit: budget, permit: permit)
                }.value
                copied = true
            } catch is CancellationError { throw CancellationError() }
            catch OfflineFileStoreError.limitExceeded { throw OfflineFileStoreError.limitExceeded }
            catch {
                // The browsing cache may evict the file between lookup and
                // copy. Retry from the source without touching the destination.
                try check(owner, revision)
            }
        }
        if !copied {
            let temporary = try await BoundedDownload.fetch(source, maxBytes: budget, reserveBytes: 1_000_000_000) { [weak self] bytes, total in
                Task { @MainActor in
                    guard let self, self.generation == revision, self.currentID == item.id else { return }
                    self.downloadedBytes = max(0, bytes)
                    self.progress = total > 0 ? min(1, Double(bytes) / Double(total)) : nil
                }
            }
            defer { discardTemporary(temporary) }
            try check(owner, revision)
            let limit = min(budget, max(0, capacity - diskBytes))
            _ = try await files.enqueue {
                try OfflineFileStore.install(temporary, at: target, copying: false, limit: limit, permit: permit)
            }.value
        }
        try check(owner, revision)
        if let index = records.firstIndex(where: { $0.id == item.id }) {
            records[index].fileState = .ready; records[index].savedAt = Date()
        }
        await refreshFileSize(item.id)
        try check(owner, revision)
        try await persist()
        try check(owner, revision)
        if item.isVideo, let poster = item.posterURL, !posterIDs.contains(item.id) {
            let posterTarget = directory.appendingPathComponent(record.posterName)
            let limit = min(await downloadBudget(), 16 * 1024 * 1024)
            try check(owner, revision)
            if limit > 1024, let file = try? await BoundedDownload.fetch(poster, maxBytes: limit, reserveBytes: 1_000_000_000) {
                defer { discardTemporary(file) }
                try check(owner, revision)
                let remaining = min(limit, max(0, capacity - diskBytes))
                _ = try? await files.enqueue {
                    try OfflineFileStore.install(file, at: posterTarget, copying: false, limit: remaining, permit: permit)
                }.value
            }
        }
        try check(owner, revision)
        await refreshFileSize(item.id)
        try check(owner, revision)
        try await persist()
    }

    func accept(_ update: SavedMembershipUpdate) {
        guard acceptsBinding(bindingID), update.accountID == accountID,
              let index = records.firstIndex(where: { $0.id == update.imageID }) else { return }
        records[index].collectionIDs = update.collectionIDs
        records[index].cloudState = update.collectionIDs.isEmpty ? .unknown : .saved
        records[index].checkedAt = Date()
        membershipVersions[update.imageID, default: 0] += 1
        if let conditionalRemoval, conditionalRemoval.ids.contains(update.imageID) {
            conditionalRemoval.permit.invalidate()
        }
        schedulePersist(force: true)
    }

    func opened(_ id: Int, binding scope: UUID) {
        guard acceptsBinding(scope), let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].lastOpenedAt = Date()
        schedulePersist()
    }

    func removeLocal(_ ids: Set<Int>, ifUnfavorited: Bool = false) {
        guard acceptsBinding(bindingID), !loading, !cleaning, healthy, let directory, let accountID else { return }
        pause(reason: "正在清理本地副本…")
        if let pausedTaskID, ids.contains(pausedTaskID) { self.pausedTaskID = nil }
        cleaning = true
        busy = true
        invalidateRepairs(for: ids)
        let scope = bindingID
        let permit = bindingPermit
        let exclusions = omittedIDs.union(ids)
        let intent = OfflineManifest(accountID: accountID, records: records, omittedIDs: exclusions, lastScan: lastScan)
        let targets = records.filter { ids.contains($0.id) }
        let membership = ifUnfavorited ? OfflineWritePermit() : nil
        if let membership { conditionalRemoval = (ids, membership) }
        files.enqueue({
            try OfflineFileStore.removeAfterExcluding(targets, manifest: intent, in: directory,
                                                      binding: permit, membership: membership)
        }, completed: { [weak self] result in
            guard let self, self.acceptsBinding(scope) else { return }
            self.cleaning = false
            self.busy = false
            self.conditionalRemoval = nil
            switch result {
            case .success(let value):
                self.omittedIDs = exclusions
                self.applyIndexSize(value.indexSize)
                if let removed = value.removed { self.records.removeAll { removed.contains($0.id) } }
                if let snapshot = value.snapshot { self.apply(snapshot, directory: directory) }
                else { self.diskUsageKnown = false }
                self.status = value.removed?.count == ids.count
                    ? "已清理 \(ids.count) 项本地副本，云端收藏保留"
                    : "部分文件暂时无法清理，请稍后重试"
            case .failure(let error):
                self.status = error is CancellationError ? "收藏状态已更新，请重新核对" : "本地目录未能保存，清理已停止"
            }
            self.schedulePersist(force: true)
        })
    }

    func cleanUnfavorited(session: SiteSession, ids: Set<Int>? = nil) {
        guard !busy, !loading, !cleaning, acceptsBinding(bindingID), canNetwork,
              let owner = accountID, session.account?.id == owner, session.hasCollectionAccess else {
            status = "请联网后核对并清理"
            return
        }
        let candidates = records.filter { ids?.contains($0.id) ?? true }.map(\.id)
        let revision = generation
        busy = true
        worker = Task {
            var confirmed = Set<Int>()
            defer { if generation == revision { busy = false; worker = nil } }
            for (offset, id) in candidates.enumerated() {
                let membershipVersion = membershipVersions[id, default: 0]
                do {
                    try check(owner, revision)
                    status = "正在核对 \(offset + 1) / \(candidates.count)…"
                    let folders = try await session.allSavedMembership(id)
                    try check(owner, revision)
                    guard membershipVersions[id, default: 0] == membershipVersion else { continue }
                    if folders.isEmpty { confirmed.insert(id) }
                    if let index = records.firstIndex(where: { $0.id == id }) {
                        records[index].collectionIDs = folders
                        records[index].cloudState = folders.isEmpty ? .localOnly : .saved
                        records[index].checkedAt = Date()
                    }
                } catch {
                    guard (try? check(owner, revision)) != nil else { return }
                    if error is CancellationError { return }
                    guard membershipVersions[id, default: 0] == membershipVersion else { continue }
                    if let index = records.firstIndex(where: { $0.id == id }) { records[index].cloudState = .unknown }
                }
            }
            guard (try? check(owner, revision)) != nil else { return }
            if confirmed.isEmpty {
                schedulePersist(force: true)
                status = "没有确认可清理的已取消收藏；待核对文件保留"
            } else {
                // A membership event can supersede a prior successful check.
                let stillConfirmed = Set(records.filter { $0.cloudState == .localOnly }.map(\.id))
                let removable = confirmed.intersection(stillConfirmed)
                if removable.isEmpty {
                    schedulePersist(force: true)
                    status = "没有确认可清理的已取消收藏；待核对文件保留"
                } else { removeLocal(removable, ifUnfavorited: true) }
            }
        }
    }

    func clearAll() {
        guard acceptsBinding(bindingID), !loading, !cleaning, let directory, let accountID else { return }
        UserDefaults.standard.set(false, forKey: "offlineAutoSave")
        if healthy {
            removeLocal(Set(records.map(\.id)))
            return
        }
        pause(reason: "正在清理离线目录…")
        pausedTaskID = nil
        cleaning = true
        busy = true
        invalidateRepairs()
        let scope = bindingID
        let permit = bindingPermit
        files.enqueue({
            try permit.check()
            try OfflineFileStore.empty(directory: directory)
            return try OfflineFileStore.load(directory: directory, owner: accountID)
        }, completed: { [weak self] result in
            guard let self, self.acceptsBinding(scope) else { return }
            self.cleaning = false
            self.busy = false
            switch result {
            case .success(let value):
                self.records = []
                self.omittedIDs = []
                self.lastScan = nil
                self.diskBytes = 0
                self.indexBytes = 0
                self.posterIDs = []
                self.repairFamilyBytes = [:]
                self.healthy = true
                self.diskUsageKnown = false
                if let snapshot = value.snapshot { self.apply(snapshot, directory: directory) }
                self.schedulePersist(force: true)
                self.status = "离线目录已清理，自动保存已关闭"
            case .failure:
                self.diskUsageKnown = false
                self.status = "部分本地文件无法清理，请稍后重试"
            }
        })
    }

    private func downloadBudget() async -> Int64 {
        guard diskUsageKnown, let directory else { return 0 }
        let scope = bindingID
        let free = try? await files.enqueue { OfflineFileStore.freeBytes(in: directory) }.value
        guard acceptsBinding(scope), diskUsageKnown else { return 0 }
        let reserved = repairReservations.values.reduce(0, +)
        return OfflineQuota.downloadBudget(used: diskBytes + reserved, limit: capacity, free: free)
    }

    func ownsRepairSource(_ source: URL) -> Bool {
        guard acceptsBinding(bindingID), healthy, !loading, !cleaning, let directory, source.isFileURL,
              source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return false }
        return records.contains { $0.fileName == source.lastPathComponent && $0.fileState == .ready }
    }

    func beginRepair(_ source: URL) -> OfflineRepairAccess? {
        guard ownsRepairSource(source) else { return nil }
        let access = OfflineRepairAccess(binding: bindingID, source: source)
        repairs[access.id] = access
        return access
    }

    func acceptsRepair(_ access: OfflineRepairAccess) -> Bool {
        acceptsBinding(access.binding) && repairs[access.id] != nil
            && (try? access.permit.check()) != nil && ownsRepairSource(access.source)
    }

    func repairIdentity(_ access: OfflineRepairAccess) async throws -> MediaRepairStore.Identity {
        guard acceptsRepair(access) else { throw CancellationError() }
        let identity = try await files.enqueue {
            try access.permit.check()
            guard let identity = MediaRepairStore.identity(access.source) else { throw MediaRepairError.unavailable }
            return identity
        }.value
        guard acceptsRepair(access) else { throw CancellationError() }
        return identity
    }

    func reserveRepairBudget(_ access: OfflineRepairAccess) async throws -> Int64 {
        guard acceptsRepair(access) else { throw CancellationError() }
        if busy { pause(reason: "正在修复离线视频，收藏下载稍后继续") }
        let known = await reconcileFiles()
        guard acceptsRepair(access) else { throw CancellationError() }
        guard known else { throw MediaRepairError.storageUnknown }
        let budget = min(536_870_912, await downloadBudget())
        guard acceptsRepair(access) else { throw CancellationError() }
        repairReservations[access.id] = budget
        return budget
    }

    func releaseRepairBudget(_ access: OfflineRepairAccess) {
        repairReservations[access.id] = nil
    }

    func makeRepairStaging(_ access: OfflineRepairAccess) async throws -> URL {
        guard acceptsRepair(access) else { throw CancellationError() }
        let root = self.root
        return try await files.enqueue {
            try access.permit.check()
            let temporary = root.appendingPathComponent(".repair-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            return temporary
        }.value
    }

    func discardRepairStaging(_ directory: URL) {
        discardTemporary(directory)
    }

    func commitRepair(_ access: OfflineRepairAccess, staged: URL, identity: MediaRepairStore.Identity,
                      content: String, transcoded: Bool) async throws -> URL {
        guard acceptsRepair(access), let directory, let reservation = repairReservations[access.id] else {
            throw CancellationError()
        }
        let final = directory.appendingPathComponent(MediaRepairStore.outputName(access.source, content: content, transcoded: transcoded))
        let stageDirectory = staged.deletingLastPathComponent()
        let receipt = MediaRepairStore.receiptURL(access.source, directory: directory)
        let stageReceipt = MediaRepairStore.receiptURL(access.source, directory: stageDirectory)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let job = files.enqueue {
                try access.permit.check()
                guard MediaRepairStore.identity(access.source) == identity else { throw CancellationError() }
                let outputSize = try OfflineFileStore.sizeOrAbsent(staged)
                guard outputSize > 0, outputSize <= max(0, reservation - 4096) else { throw MediaRepairError.output }
                try MediaRepairStore.commit(access.source, original: access.source, content: content, transcoded: transcoded,
                                            output: staged, directory: stageDirectory)
                for url in [staged, stageReceipt] {
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                }
                try access.permit.check()
                try OfflineFileStore.replace(staged, at: final)
                try OfflineFileStore.replace(stageReceipt, at: receipt)
            }
            try await job.value
            try Task.checkCancellation()
        } onCancel: { access.permit.invalidate() }
        guard acceptsRepair(access) else { throw CancellationError() }
        return final
    }

    func finishRepair(_ access: OfflineRepairAccess) {
        access.permit.invalidate()
        repairs[access.id] = nil
        repairReservations[access.id] = nil
        if acceptsBinding(access.binding) {
            Task { [weak self] in
                guard let self, self.acceptsBinding(access.binding), !self.cleaning else { return }
                if await self.reconcileFiles(), self.acceptsBinding(access.binding) {
                    self.schedulePersist(force: true)
                    if self.active, self.autoEnabled, let session = self.session { self.requestSync(session: session) }
                }
            }
        } else if active, autoEnabled, let session { requestSync(session: session) }
    }

    private func invalidateRepairs(for ids: Set<Int>? = nil) {
        let targetNames = ids.map { ids in Set(records.filter { ids.contains($0.id) }.map(\.fileName)) }
        for access in repairs.values where targetNames?.contains(access.source.lastPathComponent) ?? true {
            access.permit.invalidate()
        }
    }

    private func reconcileFiles() async -> Bool {
        guard acceptsBinding(bindingID), let directory else { return false }
        let scope = bindingID
        let job = files.enqueue({
            try OfflineFileStore.scan(directory: directory)
        }, completed: { [weak self] result in
            guard let self, self.acceptsBinding(scope) else { return }
            if case .success(let snapshot) = result { self.apply(snapshot, directory: directory) }
            else { self.diskUsageKnown = false }
        })
        _ = await job.result
        return acceptsBinding(scope) && diskUsageKnown
    }

    private func apply(_ snapshot: OfflineFileStore.Snapshot, directory: URL) {
        let disk = snapshot.disk
        let repairBytes = snapshot.repairBytes
        var updated = records
        var known = Set(updated.map(\.id))
        // Recover the durable media left by an interrupted index write.
        for file in disk.files where ["img", "mp4"].contains(file.pathExtension) && !file.lastPathComponent.contains(".poster.") {
            guard let id = Int(file.deletingPathExtension().lastPathComponent), id > 0, known.insert(id).inserted else { continue }
            var record = OfflineRecord(id: id, video: file.pathExtension == "mp4", username: nil, creatorID: nil,
                                       browsingLevel: nil, collectionIDs: [], cloudState: .unknown)
            record.savedAt = disk.created[file.standardizedFileURL.path]
            updated.append(record)
        }
        var posters = Set<Int>()
        for index in updated.indices {
            let file = directory.appendingPathComponent(updated[index].fileName)
            let size = disk.sizes[file.standardizedFileURL.path] ?? 0
            let poster = disk.sizes[directory.appendingPathComponent(updated[index].posterName).standardizedFileURL.path] ?? 0
            if poster > 0 { posters.insert(updated[index].id) }
            updated[index].bytes = size + poster + (repairBytes[MediaRepairStore.stem(file)] ?? 0)
            if size > 0 { updated[index].fileState = .ready }
            else if updated[index].fileState == .ready { updated[index].fileState = .pending }
        }
        records = updated.filter { !omittedIDs.contains($0.id) || $0.bytes > 0 }
        posterIDs = posters
        diskBytes = disk.totalBytes
        indexBytes = disk.sizes[directory.appendingPathComponent("index.json").standardizedFileURL.path] ?? 0
        repairFamilyBytes = repairBytes
        diskUsageKnown = true
    }

    private func refreshFileSize(_ id: Int) async {
        guard acceptsBinding(bindingID), let directory, let record = records.first(where: { $0.id == id }) else { return }
        let scope = bindingID
        let file = directory.appendingPathComponent(record.fileName)
        let poster = directory.appendingPathComponent(record.posterName)
        let job = files.enqueue({
            try (OfflineFileStore.sizeOrAbsent(file), OfflineFileStore.sizeOrAbsent(poster))
        }, completed: { [weak self] result in
            guard let self, self.acceptsBinding(scope), let index = self.records.firstIndex(where: { $0.id == id }) else { return }
            guard case .success(let sizes) = result else { self.diskUsageKnown = false; return }
            let prior = self.records[index].bytes
            let size = sizes.0 + sizes.1 + (self.repairFamilyBytes[MediaRepairStore.stem(file)] ?? 0)
            self.records[index].bytes = size
            if sizes.1 > 0 { self.posterIDs.insert(id) } else { self.posterIDs.remove(id) }
            self.diskBytes += size - prior
        })
        _ = await job.result
    }

    private func discardTemporary(_ url: URL) {
        files.enqueue { try? FileManager.default.removeItem(at: url) }
    }

    @discardableResult private func schedulePersist(force: Bool = false) -> Task<Int64, Error>? {
        guard acceptsBinding(bindingID), healthy, !loading, !cleaning, let directory, let accountID else { return nil }
        let stamp = Date()
        guard force || stamp.timeIntervalSince(lastPersisted) > 2 else { return nil }
        lastPersisted = stamp
        let scope = bindingID
        let manifest = OfflineManifest(accountID: accountID, records: records, omittedIDs: omittedIDs, lastScan: lastScan)
        // Capture before returning to the caller. Even a synchronous UI
        // update followed by a rebind is ordered before reopening its index.
        return files.enqueue({
            try OfflineFileStore.persist(manifest, in: directory)
        }, completed: { [weak self] result in
            guard let self, self.acceptsBinding(scope) else { return }
            if case .success(let size) = result { self.applyIndexSize(size) }
            else if self.lastPersisted == stamp { self.lastPersisted = .distantPast }
        })
    }

    private func persist(force: Bool = false) async throws {
        if let job = schedulePersist(force: force) { _ = try await job.value }
    }

    private func applyIndexSize(_ size: Int64) {
        diskBytes += size - indexBytes
        indexBytes = size
    }
}
