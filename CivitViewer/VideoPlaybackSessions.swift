import Foundation
import AVFoundation

struct VideoPlaybackSessionKey: Hashable {
    let owner: UUID
    let scope: String
    let workID: Int
    let requestedURL: URL
    let sourceURL: URL
    let sourceRevision: String?
    let rootSlot: UUID?

    init(owner: UUID, scope: String, workID: Int, requestedURL: URL, sourceURL: URL, sourceRevision: String? = nil, rootSlot: UUID? = nil) {
        self.owner = owner
        self.scope = scope
        self.workID = workID
        self.requestedURL = requestedURL
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.rootSlot = rootSlot
    }
}

@MainActor
final class VideoPlaybackSessions {
    static let shared = VideoPlaybackSessions()
    static let capacity = 2

    enum State {
        case preparing
        case readyPaused
        case active
        case coveredPaused
        case rootPaused
        case candidate
        case retired
    }

    @MainActor
    final class Entry {
        let token: UUID
        let key: VideoPlaybackSessionKey
        let player: AVPlayer
        let item: AVPlayerItem
        fileprivate weak var pool: VideoPlaybackSessions?
        fileprivate(set) var generation: UInt64 = 0
        fileprivate(set) var state: State
        fileprivate(set) var valid = true
        fileprivate var pinRelease: (@MainActor () -> Void)?
        fileprivate var foregroundBusy = false
        fileprivate var prerollPending = false
        fileprivate(set) var prerollFinished = false

        var statusObserver: NSKeyValueObservation?
        var playbackObserver: NSKeyValueObservation?
        var bufferObserver: NSKeyValueObservation?
        var durationObserver: NSKeyValueObservation?
        var seekableObserver: NSKeyValueObservation?
        fileprivate var candidateObserver: NSKeyValueObservation?
        var timeObserver: Any?

        fileprivate init(key: VideoPlaybackSessionKey, player: AVPlayer, item: AVPlayerItem,
                         pool: VideoPlaybackSessions, state: State, unpin: (@MainActor () -> Void)?) {
            token = UUID()
            self.key = key
            self.player = player
            self.item = item
            self.pool = pool
            self.state = state
            pinRelease = unpin
        }

        var canPlay: Bool {
            valid && item.status == .readyToPlay && pool?.isActive(self) == true
        }

        var readiness: Float {
            guard valid, item.status == .readyToPlay else { return 0 }
            return player.status == .readyToPlay ? 1 : 0
        }

        func stopObservers() {
            statusObserver = nil
            playbackObserver = nil
            bufferObserver = nil
            durationObserver = nil
            seekableObserver = nil
            candidateObserver = nil
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }

        fileprivate func retire() {
            guard valid else { return }
            valid = false
            state = .retired
            generation &+= 1
            player.cancelPendingPrerolls()
            item.cancelPendingSeeks()
            prerollPending = false
            stopObservers()
            player.pause()
            player.replaceCurrentItem(with: nil)
            let release = pinRelease
            pinRelease = nil
            release?()
        }
    }

    private(set) var entries: [Entry] = []
    private var activeToken: UUID?
    private var lastActiveKey: VideoPlaybackSessionKey?
    private var candidateSuppressed = false

    private init() {}

    func lookup(key: VideoPlaybackSessionKey) -> Entry? {
        entries.first { $0.key == key && $0.valid }
    }

    func isActive(_ entry: Entry) -> Bool {
        entry.valid && activeToken == entry.token
    }

    @discardableResult
    func acquireCurrent(key: VideoPlaybackSessionKey, pin: @escaping @MainActor () -> Void = {},
                        unpin: @escaping @MainActor () -> Void = {}) -> Entry? {
        if lastActiveKey != key { candidateSuppressed = false }
        lastActiveKey = key
        retireChangedScope(for: key)
        let entry: Entry
        if let existing = lookup(key: key) {
            entry = existing
            entry.player.cancelPendingPrerolls()
            entry.prerollPending = false
            entry.stopObservers()
        } else {
            guard makeRoom(allowCovered: true) else { return nil }
            pin()
            entry = makeEntry(key: key, state: .preparing, muted: false, unpin: unpin)
        }

        for other in entries where other !== entry {
            other.player.pause()
            if other.state == .active { other.state = .readyPaused }
        }
        activeToken = entry.token
        // Active is an exclusive business lease; item readiness remains separate.
        entry.state = .active
        return entry
    }

    @discardableResult
    func prepareCandidate(key: VideoPlaybackSessionKey, expectedCurrentWorkID: Int,
                          pin: @escaping @MainActor () -> Void = {},
                          unpin: @escaping @MainActor () -> Void = {}) -> Entry? {
        guard let active = entries.first(where: { $0.token == activeToken }),
              active.valid, active.key.owner == key.owner, active.key.scope == key.scope,
              active.key.workID == expectedCurrentWorkID else { return nil }
        guard !candidateSuppressed, key.sourceURL.isFileURL,
              active.key.workID != key.workID, active.player.currentItem === active.item,
              !active.foregroundBusy, active.item.status == .readyToPlay,
              active.player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { return nil }
        removeCandidates(owner: key.owner, keeping: key)
        retireChangedScope(for: key)
        if let existing = lookup(key: key) { return existing }
        guard makeRoom(allowCovered: false) else { return nil }
        pin()
        let entry = makeEntry(key: key, state: .candidate, muted: true, unpin: unpin)
        installObservers(on: entry, candidate: true)
        return entry
    }

    @discardableResult
    func promoteCandidate(_ entry: Entry) -> Entry? {
        guard entry.valid, entries.contains(where: { $0 === entry }), entry.state == .candidate else { return nil }
        entry.player.cancelPendingPrerolls()
        entry.prerollPending = false
        return acquireCurrent(key: entry.key)
    }

    func retainCovered(_ entry: Entry) {
        guard entry.valid, entries.contains(where: { $0 === entry }) else { return }
        entry.player.pause()
        entry.stopObservers()
        entry.state = .coveredPaused
        if activeToken == entry.token { activeToken = nil }
    }

    /// Called by the root host only after a real selected-tab commit, before
    /// hiding the source. Preparation and cancelled drags never enter this role.
    func pauseForRootDeparture(rootSlot: UUID, feedIdentity: String) {
        for entry in entries.filter({ $0.key.rootSlot == rootSlot && $0.key.scope.hasPrefix(feedIdentity + ":") }) {
            if entry.state == .candidate { release(entry); continue }
            guard isActive(entry), entry.state != .coveredPaused else { continue }
            entry.player.pause(); entry.stopObservers(); entry.state = .rootPaused
            activeToken = nil
        }
    }

    func hasRootPaused(owner: UUID, rootSlot: UUID) -> Bool {
        entries.contains { $0.valid && $0.key.owner == owner && $0.key.rootSlot == rootSlot && $0.state == .rootPaused }
    }

    func retainRootPaused(_ entry: Entry) {
        guard entry.valid, entry.state == .rootPaused else { return }
        entry.player.pause(); entry.stopObservers()
        if activeToken == entry.token { activeToken = nil }
    }

    func retireRootSlots(_ tokens: Set<UUID>) {
        for entry in entries.filter({ $0.key.rootSlot.map(tokens.contains) == true }) { release(entry) }
    }

    func release(_ entry: Entry) {
        guard entries.contains(where: { $0 === entry }) else { return }
        if activeToken == entry.token { activeToken = nil }
        entry.retire()
        entries.removeAll { $0 === entry }
    }

    func setForegroundBusy(_ entry: Entry, _ busy: Bool) {
        guard isActive(entry) else { return }
        entry.foregroundBusy = busy
        if busy { removeCandidates(owner: entry.key.owner) }
    }

    func removeCandidates(owner: UUID, keeping key: VideoPlaybackSessionKey? = nil) {
        for entry in entries.filter({ $0.key.owner == owner && $0.state == .candidate && $0.key != key }) { release(entry) }
    }

    func retireOwner(_ owner: UUID) {
        for entry in entries.filter({ $0.key.owner == owner }) { release(entry) }
    }

    func reset() {
        for entry in entries { entry.retire() }
        entries.removeAll()
        activeToken = nil; lastActiveKey = nil; candidateSuppressed = false
    }

    func suspendForBackground() {
        candidateSuppressed = true
        for entry in entries {
            entry.player.pause()
            if entry.state == .candidate { release(entry) }
            else if entry.state == .active { entry.state = .readyPaused }
        }
        activeToken = nil
    }

    func handleMemoryPressure() {
        candidateSuppressed = true
        for entry in entries where entry.token != activeToken { release(entry) }
    }

    private func makeEntry(key: VideoPlaybackSessionKey, state: State, muted: Bool,
                           unpin: @escaping @MainActor () -> Void) -> Entry {
        let item = AVPlayerItem(url: key.sourceURL)
        item.preferredForwardBufferDuration = 4
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = muted
        let entry = Entry(key: key, player: player, item: item, pool: self, state: state, unpin: unpin)
        entries.append(entry)
        return entry
    }

    private func makeRoom(allowCovered: Bool) -> Bool {
        guard entries.count >= Self.capacity else { return true }
        let victim = entries.first { entry in
            entry.token != activeToken && entry.state != .active && entry.state != .coveredPaused
        } ?? (allowCovered ? entries.first { entry in
            entry.token != activeToken && entry.state != .active
        } : nil)
        guard let victim else { return false }
        release(victim)
        return entries.count < Self.capacity
    }

    private func retireChangedScope(for key: VideoPlaybackSessionKey) {
        let changed = entries.filter {
            $0.key.owner == key.owner && ($0.key.scope != key.scope || ($0.key.workID == key.workID && $0.key != key))
        }
        for entry in changed { release(entry) }
    }

    private func installObservers(on entry: Entry, candidate: Bool = false) {
        entry.stopObservers()
        guard candidate else { return }
        let token = entry.token, generation = entry.generation
        let player = entry.player
        entry.candidateObserver = player.observe(\.status, options: [.initial, .new]) { [weak self, weak entry] observed, _ in
            Task { @MainActor in
                guard let self, let entry, entry.valid, entry.token == token,
                      entry.generation == generation, observed === entry.player,
                      entry.player.currentItem === entry.item, entry.state == .candidate,
                      !self.isActive(entry) else { return }
                self.startCandidatePreroll(entry)
            }
        }
    }

    private func startCandidatePreroll(_ entry: Entry) {
        guard entry.valid, entry.state == .candidate, !entry.prerollPending,
              entry.player.status == .readyToPlay, !isActive(entry) else { return }
        let token = entry.token
        let observedItem = entry.item
        let generation = entry.generation
        entry.prerollPending = true
        entry.player.preroll(atRate: 1) { [weak self, weak entry, weak observedItem] finished in
            Task { @MainActor in
                guard let self, let entry, let observedItem,
                      entry.valid, entry.token == token, entry.item === observedItem,
                      entry.generation == generation, entry.state == .candidate, !self.isActive(entry) else { return }
                entry.prerollPending = false
                entry.prerollFinished = finished
            }
        }
    }
}
