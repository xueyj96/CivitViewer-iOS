#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import AVFoundation
import CryptoKit

/// Local synthetic patterns only. This route bypasses RootView, account refresh,
/// tag synchronization, history recording and offline-library downloads.
@MainActor enum MediaFormatQA {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-media-format") }
    static var variant: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--qa-media-format"), i + 1 < args.count else { return "gif" }
        return args[i + 1]
    }
    static var root: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMediaFormatQA") }
    static var item: MediaItem {
        let file: String
        switch variant {
        case "webp", "autoplay-off": file = "animated.webp"
        case "video-as-image", "poster": file = "short.mp4"
        case "static": file = "static.png"
        default: file = "animated.jpeg" // GIF bytes with deliberately misleading suffix.
        }
        var item = MediaItem(id: 900000028, url: "https://example.invalid/local-controlled-media", width: 192, height: 256,
                             type: variant == "gif-as-video" ? "video" : "image", username: "Controlled_Pattern", browsingLevel: 1,
                             thumbnail: nil, creatorID: 900000028, tags: [])
        item.offlineMediaURL = root.appendingPathComponent(file)
        return item
    }
    static func readback() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) else { return }
        var bitmaps: [[String: Any]] = [], videos: [[String: Any]] = []
        func walk(_ view: UIView) {
            if let image = view as? UIImageView, image.accessibilityIdentifier == "bitmap-media" {
                bitmaps.append(["animating": image.isAnimating, "frames": image.animationImages?.count ?? 0,
                                "duration": image.animationDuration, "width": image.bounds.width, "height": image.bounds.height])
            }
            if let layer = view.layer as? AVPlayerLayer, let player = layer.player {
                videos.append(["readyForDisplay": layer.isReadyForDisplay, "rate": player.rate,
                               "position": player.currentTime().seconds.isFinite ? player.currentTime().seconds : -1,
                               "ready": player.currentItem?.status == .readyToPlay])
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        let data: [String: Any] = ["build": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown", "case": variant,
                                   "bitmaps": bitmaps, "videos": videos, "autoplay": UserDefaults.standard.bool(forKey: "autoplay"),
                                   "source": "local synthetic color patterns; actual production MediaPageView"]
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            try? bytes.write(to: root.appendingPathComponent("readback.json"), options: .atomic)
        }
    }
}

struct MediaFormatQAView: View {
    @State private var focused: Int? = 900000028
    @State private var active = true
    var body: some View {
        ZStack {
            if MediaFormatQA.variant == "poster" {
                CachedPoster(source: MediaFormatQA.item.mediaURL!, declared: MediaFormatQA.item.mediaURL!, active: true, fit: true)
            } else {
                MediaDeck(items: [MediaFormatQA.item], focused: $focused, isVisible: active, showsLoadMore: false, onAuthor: { _ in }, loadMore: {})
            }
        }.background(.black).preferredColorScheme(.dark)
            .task {
                UserDefaults.standard.set(MediaFormatQA.variant != "autoplay-off", forKey: "autoplay")
                for tick in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    if MediaFormatQA.variant == "inactive" && tick == 18 { active = false }
                    MediaFormatQA.readback()
                }
            }
    }
}

@MainActor enum RootTransition180QA {
    static let enabled = CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-root-release180")
    static let reportURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CivitRoot180QA", isDirectory: true).appendingPathComponent("report.json")
    static let requiredArguments = ["--qa-collection-paging", "--qa-visual-controls",
                                    "--qa-header-motion", "--qa-body-motion", "--qa-canvas-cancel179",
                                    "--qa-body-identity164"]
}

@MainActor private final class RootTransition180QARunner: ObservableObject {
    private struct HeaderReading {
        let tab: Int
        let selected: Int
        let rootSelected: Int
        let token: String?
        let live: Bool
        let ownerMatches: Bool
        let topOwner: Bool
        let foreground: Bool
        let lockActive: Bool
        let previewPresent: Bool
        let phase: String
        let header: CGRect?
        let footer: CGRect?
        var dictionary: [String: Any] {
            ["selected": "\(selected)", "rootSelected": "\(rootSelected)", "token": token ?? "missing",
             "liveControls": "\(live)", "ownerMatches": "\(ownerMatches)", "topOwner": "\(topOwner)",
             "foreground": "\(foreground)", "lockActive": "\(lockActive)",
             "previewPresent": "\(previewPresent)", "phase": phase,
             "header": rect(header) as Any? ?? NSNull(), "footer": rect(footer) as Any? ?? NSNull()]
        }
        private func rect(_ value: CGRect?) -> [String: Double]? {
            guard let value else { return nil }
            return ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
        }
    }
    private struct CompletionWaiter {
        let id: UUID
        let kind: String
        let phase: String
        let tab: Int
        let continuation: CheckedContinuation<HeaderReading?, Never>
    }
    private struct RootHostWaitResult {
        let host: RootTabHostController?
        let observed: [String: Any]
    }

    @Published private(set) var status = "idle"
    private let motion: TabPageMotion
    private let selectedTab: () -> Int
    private let selectTab: (Int) -> Void
    private let commitEdge: (Int) -> Void
    private let canvasStarts: () -> (all: Int, black: Int)
    private var observer: NSObjectProtocol?
    private var waiter: CompletionWaiter?
    private var timeoutTask: Task<Void, Never>?
    private var ackReading: HeaderReading?
    private var caseRecords: [[String: Any]] = []
    private var geometryByTab: [Int: (header: CGRect, footer: CGRect)] = [:]
    private var footerReference: CGRect?
    private var initialScope: String?
    private var started = false
    private var invalidated = false
    private var finished = false
    private var startedAt: CFTimeInterval = 0

    init(motion: TabPageMotion, selectedTab: @escaping () -> Int,
         selectTab: @escaping (Int) -> Void, commitEdge: @escaping (Int) -> Void,
         canvasStarts: @escaping () -> (all: Int, black: Int)) {
        self.motion = motion
        self.selectedTab = selectedTab
        self.selectTab = selectTab
        self.commitEdge = commitEdge
        self.canvasStarts = canvasStarts
        observer = NotificationCenter.default.addObserver(forName: PageBodyHandoff.qaStateDidChange,
                                                           object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated { self?.receive(note) }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            timeoutTask?.cancel()
        }
    }

    func runIfNeeded() async {
        guard !started else { return }
        started = true
        startedAt = CACurrentMediaTime()
        let runDeadline = startedAt + 55
        defer { timeoutTask?.cancel(); timeoutTask = nil }
        let missing = RootTransition180QA.requiredArguments.filter { !ProcessInfo.processInfo.arguments.contains($0) }
        guard missing.isEmpty else {
            appendFailure(caseName: "setup", phase: "aborted", token: nil,
                          expected: ["requiredFlags": "present"], observed: ["missingFlags": missing.joined(separator: ",")])
            finish("aborted: required QA flags missing")
            return
        }
        let hostWait = await waitForRootHost(timeout: 8)
        guard let host = hostWait.host, !invalidated else {
            if invalidated { return }
            appendFailure(caseName: "setup", phase: "aborted", token: nil,
                          expected: ["rootHost": "mounted-in-key-window", "scene": "foreground", "selection": "consistent"],
                          observed: hostWait.observed)
            finish(hostWait.observed["taskCancelled"] as? Bool == true
                ? "aborted: setup task cancelled" : "aborted: root host not ready")
            return
        }
        initialScope = host.feedIdentity
        appendRecord(caseName: "setup-root-host", phase: "host-ready",
                     token: host.token(for: selectedTab())?.uuidString, scheme: scheme,
                     expected: ["rootHost": "mounted-in-key-window", "scene": "foreground", "selection": "consistent"],
                     observed: hostWait.observed, passed: true)
        status = "running"
        writeReport(status: status)
        guard let initial = await waitForStable(tab: 0, timeout: 8) else {
            var observed = rootHostSetupReadback(elapsed: CACurrentMediaTime() - startedAt,
                                                 taskCancelled: Task.isCancelled).observed
            observed["phase"] = "root-not-stable"
            observed["liveHeader"] = false
            observed["locksReleased"] = !(motion.rootHost?.viewIfLoaded?.window.map { PageInteractionShield.isActive(in: $0) } ?? false)
            appendFailure(caseName: "setup", phase: "aborted", token: token(for: 0),
                          expected: ["selected": "0", "liveHeader": "true", "locksReleased": "true"],
                          observed: observed)
            finish(Task.isCancelled ? "aborted: setup task cancelled" : "aborted: initial timeline not ready")
            return
        }
        rememberGeometry(initial)
        for round in 1...3 {
            guard CACurrentMediaTime() < runDeadline,
                  await runTap("tap-0-2-round-\(round)", from: 0, to: 2, deadline: runDeadline),
                  await runTap("tap-2-0-round-\(round)", from: 2, to: 0, deadline: runDeadline) else {
                abortIfNeeded("tap route failed at round \(round)")
                finish("aborted: root tap route failed")
                return
            }
            if invalidated { return }
        }
        guard await runTap("tap-0-2-before-edge", from: 0, to: 2, deadline: runDeadline),
              await runEdge("edge-2-4-accepted", from: 2, to: 4, accepted: true, deadline: runDeadline),
              await runTap("tap-4-2-before-cancel", from: 4, to: 2, deadline: runDeadline),
              await runEdge("edge-2-0-cancelled", from: 2, to: 0, accepted: false, deadline: runDeadline),
              await runEdge("edge-2-0-accepted", from: 2, to: 0, accepted: true, deadline: runDeadline) else {
            abortIfNeeded("edge route failed")
            finish("aborted: root edge route failed")
            return
        }
        finish(caseRecords.allSatisfy { $0["passed"] as? Bool == true } ? "passed" : "failed")
    }

    private func waitForRootHost(timeout: TimeInterval) async -> RootHostWaitResult {
        let waitStarted = CACurrentMediaTime()
        let deadline = waitStarted + timeout
        var sample = rootHostSetupReadback(elapsed: 0, taskCancelled: Task.isCancelled)
        while CACurrentMediaTime() < deadline, !Task.isCancelled, !invalidated {
            sample = rootHostSetupReadback(elapsed: CACurrentMediaTime() - waitStarted,
                                           taskCancelled: Task.isCancelled)
            if let host = motion.rootHost, host.viewIfLoaded?.window != nil,
               host.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
               host.selected == selectedTab(), sample.observed["runnerHostInKeyWindow"] as? Bool == true {
                return RootHostWaitResult(host: host, observed: sample.observed)
            }
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { break }
        }
        sample = rootHostSetupReadback(elapsed: CACurrentMediaTime() - waitStarted,
                                       taskCancelled: Task.isCancelled)
        return RootHostWaitResult(host: nil, observed: sample.observed)
    }

    private func rootHosts(in window: UIWindow) -> [RootTabHostController] {
        var result: [RootTabHostController] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ controller: UIViewController) {
            guard visited.insert(ObjectIdentifier(controller)).inserted else { return }
            if let host = controller as? RootTabHostController { result.append(host) }
            controller.children.forEach(visit)
            if let presented = controller.presentedViewController { visit(presented) }
        }
        if let root = window.rootViewController { visit(root) }
        return result
    }

    private func rootHostSetupReadback(elapsed: TimeInterval, taskCancelled: Bool) -> RootHostWaitResult {
        let runnerHost = motion.rootHost
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foregroundScenes = scenes.filter { $0.activationState == .foregroundActive }
        let keyWindow = foregroundScenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let windowHosts = keyWindow.map { rootHosts(in: $0) } ?? []
        let runnerWindow = runnerHost?.viewIfLoaded?.window
        let runnerIdentity = runnerHost.map { ObjectIdentifier($0).hashValue } ?? 0
        let windowHostIdentities = windowHosts.map { ObjectIdentifier($0).hashValue }
        let sceneName: String
        if let state = runnerWindow?.windowScene?.activationState {
            switch state {
            case .foregroundActive: sceneName = "foregroundActive"
            case .foregroundInactive: sceneName = "foregroundInactive"
            case .background: sceneName = "background"
            case .unattached: sceneName = "unattached"
            @unknown default: sceneName = "unknown"
            }
        } else {
            sceneName = "missing"
        }
        let selected = selectedTab()
        let hostInOwnWindowRoot = runnerHost.map { candidate in
            runnerWindow.map { rootHosts(in: $0).contains { $0 === candidate } } ?? false
        } ?? false
        let observed: [String: Any] = [
            "runnerMotionRootHostPresent": runnerHost != nil,
            "runnerHostViewLoaded": runnerHost?.isViewLoaded ?? false,
            "runnerHostWindowPresent": runnerWindow != nil,
            "runnerWindowScene": sceneName,
            "foregroundActiveSceneCount": foregroundScenes.count,
            "keyWindowPresent": keyWindow != nil,
            "keyWindowRootHostCount": windowHosts.count,
            "runnerHostIdentity": runnerIdentity,
            "keyWindowRootHostIdentities": windowHostIdentities,
            "runnerHostInKeyWindow": runnerHost.map { candidate in windowHosts.contains { $0 === candidate } } ?? false,
            "runnerHostInOwnWindowRoot": hostInOwnWindowRoot,
            "runnerHostSelected": runnerHost?.selected ?? -1,
            "selectedBinding": selected,
            "selectionConsistent": runnerHost.map { $0.selected == selected } ?? false,
            "taskCancelled": taskCancelled,
            "elapsedMs": Int((elapsed * 1_000).rounded())
        ]
        return RootHostWaitResult(host: runnerHost, observed: observed)
    }

    private func runTap(_ name: String, from: Int, to: Int, deadline: CFTimeInterval) async -> Bool {
        guard preconditionReady(name, selected: from, deadline: deadline) else { return false }
        let before = canvasStarts()
        ackReading = nil
        let observation = await waitForTransition(caseName: name, kind: "tab", phase: "completed", tab: to, deadline: deadline) {
            self.selectTab(to)
            return true
        }
        guard let observation else {
            appendFailure(caseName: name, phase: "timeout", token: token(for: selectedTab()),
                          expected: ["completion": "tab/completed"], observed: ["selected": "\(selectedTab())"])
            return false
        }
        guard !invalidated else { return false }
        return await verifyAccepted(name, target: to, before: before, completion: observation, deadline: deadline)
    }

    private func runEdge(_ name: String, from: Int, to: Int, accepted: Bool,
                         deadline: CFTimeInterval) async -> Bool {
        guard preconditionReady(name, selected: from, deadline: deadline) else { return false }
        guard let host = motion.rootHost,
              let owner = host.navigationOwner(tab: from), owner.navigationController?.topViewController === owner,
              host.owns(owner, tab: from), let width = owner.viewIfLoaded?.bounds.width, width > 1 else { return false }
        let before = canvasStarts()
        ackReading = nil
        let terminalPhase = accepted ? "completed" : "cancelled"
        let observation = await waitForTransition(caseName: name, kind: "tab-edge", phase: terminalPhase,
                                                   tab: accepted ? to : from, deadline: deadline) {
            let order = [0, 2, 4, 3]
            let sign: CGFloat = (order.firstIndex(of: to) ?? 0) > (order.firstIndex(of: from) ?? 0) ? -1 : 1
            let result = self.motion.beginRootSwitch(from: from, to: to, sign: sign, interactive: true,
                                                      commit: self.commitEdge)
            guard case .started = result else { return false }
            self.motion.updateRootSwitch(translation: sign * width * (accepted ? 0.52 : 0.12))
            self.motion.endRootSwitch(velocity: 0, cancelled: !accepted)
            return true
        }
        guard let observation else {
            appendFailure(caseName: name, phase: "timeout-or-not-started", token: token(for: selectedTab()),
                          expected: ["completion": "tab-edge/\(terminalPhase)"],
                          observed: ["selected": "\(selectedTab())", "rootSelected": "\(motion.rootHost?.selected ?? -1)"])
            return false
        }
        guard !invalidated else { return false }
        if accepted { return await verifyAccepted(name, target: to, before: before, completion: observation, deadline: deadline) }
        guard let final = await waitForStable(tab: from, timeout: min(4, remaining(deadline))) else {
            appendFailure(caseName: name, phase: "cancelled-final-state-timeout", token: token(for: from),
                          expected: ["selected": "\(from)", "liveHeader": "true", "locksReleased": "true"],
                          observed: ["selected": "\(selectedTab())"])
            return false
        }
        let blackDelta = canvasStarts().black - before.black
        let geometryStable = geometryByTab[from].map { close(final.header ?? .zero, $0.header) }
            ?? true
        let footerStable = footerReference.map { expected in final.footer.map { close($0, expected) } ?? false } ?? true
        rememberGeometry(final)
        let expected = ["selected": "\(from)", "cancelledBeforeRemove": "true", "finalLiveHeader": "true",
                        "locksReleased": "true", "previewGone": "true", "blackStartsDelta": "0"]
        let observed = observation.dictionary.merging([
            "finalSelected": "\(final.selected)", "finalLiveHeader": "\(final.live)",
            "finalLocksReleased": "\(!final.lockActive)", "previewGone": "\(!final.previewPresent)",
            "blackStartsDelta": "\(blackDelta)", "geometryStable": "\(geometryStable)",
            "footerStable": "\(footerStable)",
            "header": rect(final.header) as Any? ?? NSNull(), "footer": rect(final.footer) as Any? ?? NSNull()
        ]) { _, new in new }
        let passed = observation.phase == "cancelled" && observation.selected == from
            && final.live && !final.lockActive && !final.previewPresent && blackDelta == 0 && geometryStable && footerStable
        appendRecord(caseName: name, phase: "cancelled-before-remove+final-stable", token: observation.token,
                     scheme: scheme, expected: expected, observed: observed, passed: passed)
        return passed
    }

    private func verifyAccepted(_ name: String, target: Int, before: (all: Int, black: Int),
                                completion: HeaderReading, deadline: CFTimeInterval) async -> Bool {
        guard let final = await waitForStable(tab: target, timeout: min(4, remaining(deadline))) else {
            appendFailure(caseName: name, phase: "final-state-timeout", token: completion.token,
                          expected: ["selected": "\(target)", "liveHeader": "true", "locksReleased": "true"],
                          observed: ["selected": "\(selectedTab())"])
            return false
        }
        let counts = canvasStarts()
        let blackDelta = counts.black - before.black
        let allDelta = counts.all - before.all
        let geometryStable = geometryByTab[target].map { close(final.header ?? .zero, $0.header) } ?? true
        let footerStable = footerReference.map { expected in final.footer.map { close($0, expected) } ?? false } ?? true
        rememberGeometry(final)
        let ack = ackReading
        let expected = ["selected": "\(target)", "ackLiveControls": "true", "preRemoveLiveControls": "true",
                        "preRemoveLockActive": "true", "finalLocksReleased": "true", "previewGone": "true",
                        "blackStartsDelta": "0"]
        var observed = completion.dictionary
        observed["ackLiveControls"] = ack.map { "\($0.live)" } ?? "missing"
        observed["ackToken"] = ack?.token ?? "missing"
        observed["finalLiveControls"] = "\(final.live)"
        observed["finalLocksReleased"] = "\(!final.lockActive)"
        observed["previewGone"] = "\(!final.previewPresent)"
        observed["canvasStartsDelta"] = "\(allDelta)"
        observed["blackStartsDelta"] = "\(blackDelta)"
        observed["geometryStable"] = "\(geometryStable)"
        observed["footerStable"] = "\(footerStable)"
        observed["header"] = rect(final.header); observed["footer"] = rect(final.footer)
        let passed = completion.phase == "completed" && completion.selected == target && completion.live && completion.lockActive
            && ack?.live == true && ack?.token == completion.token
            && final.live && !final.lockActive && !final.previewPresent
            && allDelta == 0 && blackDelta == 0 && geometryStable && footerStable
        appendRecord(caseName: name, phase: "completed-before-remove+final-stable", token: completion.token,
                     scheme: scheme, expected: expected, observed: observed, passed: passed)
        return passed
    }

    private func preconditionReady(_ name: String, selected expected: Int, deadline: CFTimeInterval) -> Bool {
        guard CACurrentMediaTime() < deadline, !Task.isCancelled,
              let host = motion.rootHost, host.selected == expected, selectedTab() == expected,
              host.feedIdentity == initialScope,
              host.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              motion.handoff == nil, motion.preparedTab == nil,
              let owner = host.navigationOwner(tab: expected), host.owns(owner, tab: expected),
              owner.navigationController?.topViewController === owner,
              host.token(for: expected) != nil else {
            appendFailure(caseName: name, phase: "precondition-failed", token: token(for: expected),
                          expected: ["selected": "\(expected)", "hostReady": "true", "scopeStable": "true"],
                          observed: ["selected": "\(selectedTab())", "rootSelected": "\(motion.rootHost?.selected ?? -1)"])
            return false
        }
        return true
    }

    private func waitForTransition(caseName: String, kind: String, phase: String, tab: Int,
                                   deadline: CFTimeInterval, trigger: () -> Bool) async -> HeaderReading? {
        guard remaining(deadline) > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            waiter = CompletionWaiter(id: id, kind: kind, phase: phase,
                                      tab: tab, continuation: continuation)
            guard trigger() else {
                waiter = nil
                continuation.resume(returning: nil)
                return
            }
            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let expires = CACurrentMediaTime() + min(3, self.remaining(deadline))
                while CACurrentMediaTime() < expires {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard self.waiter?.id == id else { return }
                    if Task.isCancelled || self.motion.rootHost?.feedIdentity != self.initialScope
                        || self.motion.rootHost?.viewIfLoaded?.window?.windowScene?.activationState != .foregroundActive {
                        self.stop(reason: Task.isCancelled ? "runner-cancelled" : "scope-or-scene-invalid")
                        return
                    }
                }
                guard self.waiter?.id == id else { return }
                let expired = self.waiter
                self.waiter = nil; self.timeoutTask = nil
                expired?.continuation.resume(returning: nil)
            }
        }
    }

    private func receive(_ note: Notification) {
        guard let waiter,
              let kind = note.userInfo?["kind"] as? String,
              let phase = note.userInfo?["phase"] as? String,
              kind == waiter.kind else { return }
        let reading = readHeader(tab: waiter.tab)
        if phase == "root-live-header" {
            ackReading = reading
            return
        }
        guard phase == waiter.phase || phase == "cancelled" else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        self.waiter = nil
        waiter.continuation.resume(returning: HeaderReading(tab: reading.tab, selected: reading.selected,
            rootSelected: reading.rootSelected, token: reading.token, live: reading.live,
            ownerMatches: reading.ownerMatches, topOwner: reading.topOwner, foreground: reading.foreground,
            lockActive: reading.lockActive, previewPresent: reading.previewPresent, phase: phase,
            header: reading.header, footer: reading.footer))
    }

    private func readHeader(tab: Int) -> HeaderReading {
        let selected = selectedTab()
        let host = motion.rootHost
        let window = host?.viewIfLoaded?.window
        let token = host?.token(for: tab)
        let owner = host?.navigationOwner(tab: tab)
        var pending = owner.map { [$0] } ?? []
        var found: NativeHeaderProbe?
        while let controller = pending.popLast() {
            if let probe = controller as? NativeHeaderProbe,
               probe.rootToken == token,
               let owner, PageViewportGeometry.owner(of: probe) === owner,
               host?.owns(owner, tab: tab) == true,
               owner.navigationController?.topViewController === owner,
               let current = probe.currentHeader ?? probe.settledHeader,
               probe.anchor.visibleFrame != nil,
               current.appearance.contentOwner == probe.anchor.appearance?.contentOwner {
                found = probe
                break
            }
            pending.append(contentsOf: controller.children)
        }
        let footer = window.flatMap { PageBodyViewports.fixedBottomBarFrame(in: $0) }
        return HeaderReading(tab: tab, selected: selected, rootSelected: host?.selected ?? -1,
            token: token?.uuidString, live: found?.rendersLiveControls == true,
            ownerMatches: owner.map { host?.owns($0, tab: tab) == true } ?? false,
            topOwner: owner.map { $0.navigationController?.topViewController === $0 } ?? false,
            foreground: window?.windowScene?.activationState == .foregroundActive,
            lockActive: window.map { PageInteractionShield.isActive(in: $0) } ?? false,
            previewPresent: motion.preparedTab != nil || motion.handoff != nil,
            phase: "observed",
            header: found.flatMap { ($0.currentHeader ?? $0.settledHeader)?.frame }, footer: footer)
    }

    private func waitForStable(tab: Int, timeout: TimeInterval) async -> HeaderReading? {
        let deadline = CACurrentMediaTime() + max(0, timeout)
        while CACurrentMediaTime() < deadline, !Task.isCancelled {
            if let host = motion.rootHost, host.feedIdentity == initialScope,
               host.selected == tab, selectedTab() == tab,
               host.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
               motion.preparedTab == nil, motion.handoff == nil {
                let reading = readHeader(tab: tab)
                if reading.live && !reading.lockActive && !reading.previewPresent
                    && reading.ownerMatches && reading.topOwner
                    && reading.header != nil && reading.footer != nil {
                    return reading
                }
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(35))
        }
        return nil
    }

    private func rememberGeometry(_ reading: HeaderReading) {
        guard let header = reading.header, let footer = reading.footer else { return }
        if geometryByTab[reading.tab] == nil { geometryByTab[reading.tab] = (header, footer) }
        if footerReference == nil { footerReference = footer }
    }

    private func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private var scheme: String { motion.rootHost?.viewIfLoaded?.window?.traitCollection.userInterfaceStyle == .dark ? "dark" : "light" }
    private func token(for tab: Int) -> String? { motion.rootHost?.token(for: tab)?.uuidString }
    private func remaining(_ deadline: CFTimeInterval) -> TimeInterval { max(0, deadline - CACurrentMediaTime()) }
    private func rect(_ value: CGRect?) -> [String: Double]? {
        guard let value else { return nil }
        return ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
    }

    private func appendFailure(caseName: String, phase: String, token: String?,
                               expected: [String: String], observed: [String: Any]) {
        appendRecord(caseName: caseName, phase: phase, token: token, scheme: scheme,
                     expected: expected, observed: observed, passed: false)
    }

    private func appendRecord(caseName: String, phase: String, token: String?, scheme: String,
                              expected: [String: String], observed: [String: Any], passed: Bool) {
        caseRecords.append(["case": caseName, "expected": expected, "observed": observed,
                            "phase": phase, "token": token as Any? ?? NSNull(),
                            "scheme": scheme, "passed": passed])
        writeReport(status: status)
    }

    private func abortIfNeeded(_ reason: String) {
        if Task.isCancelled || motion.rootHost?.viewIfLoaded?.window?.windowScene?.activationState != .foregroundActive
            || motion.rootHost?.feedIdentity != initialScope {
            motion.cancel(reason: "root-release-qa-aborted")
        } else if motion.handoff != nil || motion.preparedTab != nil {
            motion.cancel(reason: "root-release-qa-\(reason)")
        }
    }

    func stop(reason: String) {
        guard started, !finished, !invalidated else { return }
        let wasSettingUp = status == "idle"
        var observed = rootHostSetupReadback(elapsed: startedAt > 0 ? CACurrentMediaTime() - startedAt : 0,
                                             taskCancelled: Task.isCancelled).observed
        observed["reason"] = reason
        observed["leaseActiveBeforeCancel"] = motion.rootHost?.viewIfLoaded?.window.map { PageInteractionShield.isActive(in: $0) } ?? false
        invalidated = true
        motion.cancel(reason: "root-release-qa-\(reason)")
        timeoutTask?.cancel(); timeoutTask = nil
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: nil)
        }
        appendFailure(caseName: wasSettingUp ? "setup" : "run", phase: "aborted", token: token(for: selectedTab()),
                      expected: ["complete": "false", "leaseReleased": "true"], observed: observed)
        finish("aborted: \(reason)")
    }

    private func finish(_ value: String) {
        if !invalidated || value.hasPrefix("aborted:") { status = value }
        finished = true
        writeReport(status: status)
    }

    private func writeReport(status: String) {
        let payload: [String: Any] = ["schema": 180, "status": status,
            "method": "MainTabs root host/controller plus PageBodyHandoff live-controls ACK; not XCTest touch automation",
            "caseCount": caseRecords.count, "cases": caseRecords]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: RootTransition180QA.reportURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: RootTransition180QA.reportURL, options: .atomic)
        } catch {
            NSLog("ROOT_RELEASE180_REPORT writeFailed")
        }
    }
}

@MainActor struct RootTransition180QAView: View {
    @StateObject private var runner: RootTransition180QARunner
    init(motion: TabPageMotion, selectedTab: @escaping () -> Int,
         selectTab: @escaping (Int) -> Void, commitEdge: @escaping (Int) -> Void,
         canvasStarts: @escaping () -> (all: Int, black: Int)) {
        _runner = StateObject(wrappedValue: RootTransition180QARunner(motion: motion, selectedTab: selectedTab,
            selectTab: selectTab, commitEdge: commitEdge, canvasStarts: canvasStarts))
    }
    var body: some View {
        Text(runner.status).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
            .allowsHitTesting(false).accessibilityHidden(true).accessibilityIdentifier("root.release180.qa")
            .task { await runner.runIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { runner.stop(reason: "scene-inactive") }
            }
            .onDisappear { runner.stop(reason: "qa-view-disappeared") }
    }
    @Environment(\.scenePhase) private var scenePhase
}

@MainActor enum VisualControlsQA {
    static var enabled: Bool { CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-visual-controls") }
    static var creatorID: Int { CollectionPagingQA.ownerID + 900 }
    static var state: String {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-control-state=") })?.components(separatedBy: "=").last ?? "normal"
    }
    static var width: CGFloat? {
        guard enabled, let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-control-width=") }),
              let value = Double(argument.components(separatedBy: "=").last ?? ""), [320.0, 375, 440].contains(value) else { return nil }
        return CGFloat(value)
    }
    static var largeType: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--qa-control-large-type") }
    static var author: String { ProcessInfo.processInfo.arguments.contains("--qa-control-long-author") ? "LongCreatorName_ForMediaControls_WithImagesAndVideos" : "LayoutCreator" }
}

/// Opt-in accumulated image feeds with real decoded local bitmaps. Setup is
/// outside the measured interaction window; no network or user data is used.
@MainActor enum ContentPerformance179QA {
    static let enabled = CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-content-performance179")
    static let firstID = 179_000_000
    static let initialCount = 300
    static let total = 420
    static var plainCellBodies = 0
    static var collectionCellBodies = 0
    static var gridBodies = 0
    static var pageReads = 0
    static var progressTicks = 0
    static var setupStage = "initial"
    static let items: [MediaItem] = (0..<total).map { index in
        let count = index % 20 == 0 ? 120 : 16
        let tags = (0..<count).map { MediaTag(id: 179_100 + $0, name: "content fixture tag \($0)") }
        var item = MediaItem(id: firstID + index, url: "https://example.invalid/content179/\(index).png",
                             width: 450, height: 640, type: "image", username: VisualControlsQA.author,
                             browsingLevel: 1, thumbnail: nil, creatorID: VisualControlsQA.creatorID, tags: tags)
        item.offlineMediaURL = CollectionPagingQA.root.appendingPathComponent("pattern-\(index % 6).png")
        return item
    }
    static func page(filter: FeedFilter, cursor: String?) -> MediaPage {
        pageReads += 1
        guard filter.effectiveKind != .video else { return .init(items: [], metadata: .init(nextCursor: nil)) }
        let start = min(total, max(0, Int(cursor ?? "0") ?? 0))
        let end = min(total, start + (cursor == nil ? initialCount : 20))
        return .init(items: Array(items[start..<end]), metadata: .init(nextCursor: end < total ? String(end) : nil))
    }
    static func cell(collection: Bool) {
        guard enabled else { return }
        if collection { collectionCellBodies += 1 } else { plainCellBodies += 1 }
    }
    static var value: String {
        "plain=\(plainCellBodies);collection=\(collectionCellBodies);grids=\(gridBodies);pages=\(pageReads);ticks=\(progressTicks);setup=\(setupStage);readyFiles=\(OfflineLibrary.shared.readyCount)"
    }
}

private struct ContentPerformance179Readback: UIViewRepresentable {
    final class Readback: UILabel {
        override var accessibilityValue: String? { get { ContentPerformance179QA.value } set {} }
    }
    func makeUIView(context: Context) -> Readback {
        let label = Readback(); label.text = "content performance"; label.textColor = .clear
        label.font = .systemFont(ofSize: 1); label.isAccessibilityElement = true
        label.accessibilityIdentifier = "content179.state"; label.isUserInteractionEnabled = false
        return label
    }
    func updateUIView(_ uiView: Readback, context: Context) {}
}

private struct ContentPerformance179Controls: View {
    @State private var publishing = false
    var body: some View {
        HStack {
            ContentPerformance179Readback().frame(width: 1, height: 1).allowsHitTesting(false)
            Button(publishing ? "停止进度" : "后台进度") { publishing.toggle() }
                .font(.caption2).accessibilityIdentifier("content179.progress")
        }
        .padding(.bottom, 72)
        .task(id: publishing) {
            guard publishing else { return }
            for tick in 0..<1_000 {
                guard !Task.isCancelled else { return }
                OfflineLibrary.shared.publishContentProgress179(tick: tick)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

/// Scripted local pages exercise the real Timeline/FeedStore/native pager path.
/// The observer counts fixture page reads, never site RPCs or user-account data.
@MainActor enum AuthorPaging176QA {
    static var enabled: Bool { CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-author-paging176") }
    static let continuous = ProcessInfo.processInfo.arguments.contains("--qa-author-paging-continuous")
    static let holdsCovers = ProcessInfo.processInfo.arguments.contains("--qa-author-paging-hold-covers")
    static let stressesTagIndex = ProcessInfo.processInfo.arguments.contains("--qa-author-paging-loaded-tag-index")
    private static let coverPrefix = "author176-held-cover-"
    final class Observer: ObservableObject {
        @Published var requests = 0
        @Published var cancellations = 0
        @Published var committed = 0
        @Published var released = false
        @Published var waitingCovers = 0
        @Published var tagIndexSeeded = false
        @Published var inputSample = ""
        var value: String { "requests=\(requests);cancelled=\(cancellations);committed=\(committed);waitingCovers=\(waitingCovers);tagIndexSeeded=\(tagIndexSeeded ? 1 : 0)" + inputSample }
    }
    static let shared = Observer()
    private static var releaseOnNextDrag = false
    private static var dragging = false
    private static var gestureStart: TimeInterval?
    private static var appliedAt: TimeInterval?
    private static var movesAfterApply = 0

    static func armReleaseOnDrag() { releaseOnNextDrag = true }

    static func dragChanged() {
        if !dragging {
            dragging = true
            if releaseOnNextDrag {
                releaseOnNextDrag = false
                gestureStart = Date().timeIntervalSince1970
                appliedAt = nil
                movesAfterApply = 0
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    if dragging && gestureStart != nil { shared.released = true }
                }
            }
        }
        if appliedAt != nil { movesAfterApply += 1 }
    }

    static func visiblePageApplied(itemCount: Int) {
        guard dragging, gestureStart != nil, itemCount > 20 else { return }
        appliedAt = Date().timeIntervalSince1970
    }

    static func dragEnded() {
        dragging = false
        guard let gestureStart else { return }
        let end = Date().timeIntervalSince1970
        shared.inputSample = ";gestureStart=\(gestureStart);pageApplied=\(appliedAt ?? 0);gestureEnd=\(end);movesAfterApply=\(movesAfterApply)"
        self.gestureStart = nil
        appliedAt = nil
    }
    static func prepareTagIndex(session: SiteSession) async {
        guard stressesTagIndex else { return }
        let policy = TagAvailabilityPolicy(blockedTags: TagBlocklist.shared.names,
                                           blockedAuthorIDs: AuthorBlocklist.shared.blockedIDs,
                                           blockedAuthorHandles: AuthorBlocklist.shared.blockedHandles,
                                           deduplicateMediaAssets: UserDefaults.standard.object(forKey: "deduplicateMedia") as? Bool ?? true)
        let counts = [5_000, 2_637, 903, 1_444]
        for (index, count) in counts.enumerated() {
            let scope = index == 0 ? session.tagEvidenceIdentity : "qa-tag-index-\(index)"
            let items = stride(from: 1, through: count, by: 100).map { offset in
                let tags = (offset..<min(offset + 100, count + 1)).map { MediaTag(id: $0, name: "fixture-\($0)") }
                return MediaItem(id: 28_044_000 + offset, url: "https://example.invalid/tag-fixture/\(offset).png",
                                 width: 10, height: 10, type: "image", username: nil, browsingLevel: 1,
                                 thumbnail: nil, tags: tags)
            }
            TagObservationStore.shared.observe(items: items, scope: scope, policy: policy)
        }
        await TagObservationStore.shared.flush()
        shared.tagIndexSeeded = TagObservationStore.shared.estimate(tagID: 5_000, scope: session.tagEvidenceIdentity, policy: policy) != nil
    }

    static func coverFixture(at index: Int) -> URL {
        CollectionPagingQA.root.appendingPathComponent("\(coverPrefix)\(index % 6).png")
    }

    static func holdCoverIfNeeded(_ url: URL) async throws {
        guard holdsCovers, url.isFileURL, url.lastPathComponent.hasPrefix(coverPrefix) else { return }
        shared.waitingCovers += 1
        defer { shared.waitingCovers -= 1 }
        try await Task.sleep(for: .seconds(120))
    }

    static func page(creator: Creator, cursor: String?) async throws -> MediaPage {
        shared.requests += 1
        if cursor != nil || ProcessInfo.processInfo.arguments.contains("--qa-hold-author-first-page") {
            let deadline = ContinuousClock.now + .seconds(continuous || holdsCovers ? 120 : 40)
            do {
                while !shared.released {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw ClientError.invalidResponse }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                if Task.isCancelled { shared.cancellations += 1 }
                throw error
            }
        }
        guard let original = CollectionPagingQA.items.first(where: { !$0.isVideo }) else { throw ClientError.invalidResponse }
        let items = (cursor == nil ? 0..<20 : 20..<40).map { index in
            var item = MediaItem(id: 28_037_300 + index, url: "https://example.invalid/author176-\(index).png",
                                 width: original.width, height: original.height, type: "image", username: creator.username,
                                 browsingLevel: 1, thumbnail: nil, creatorID: creator.id, tags: [])
            item.offlineMediaURL = holdsCovers ? coverFixture(at: index) : original.offlineMediaURL
            if stressesTagIndex {
                let first = index < 20 ? index * 12 + 1 : 6_000 + (index - 20) * 12
                item.tags = (first..<(first + 12)).map { MediaTag(id: $0, name: "fixture-\($0)") }
            }
            return item
        }
        shared.committed += items.count
        return MediaPage(items: items, metadata: .init(nextCursor: cursor == nil ? "author176-next" : nil))
    }
}

@MainActor final class CollectionOpenFileQA: ObservableObject {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--qa-collection-open-file-wait")
    static let shared = CollectionOpenFileQA()
    @Published private(set) var entered = 0
    @Published private(set) var completed = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var state: String { "entered=\(entered);completed=\(completed)" }

    func waitForRelease() async {
        entered += 1
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        completed += 1
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private struct CollectionOpenFileReadback: View {
    @ObservedObject private var state = CollectionOpenFileQA.shared
    var body: some View {
        HStack {
            Text(state.state).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("collection.open-file.state").accessibilityValue(state.state)
            Button("释放文件核验") { state.release() }.accessibilityIdentifier("collection.open-file.release")
        }.padding(.bottom, 90)
    }
}

private struct AuthorPaging176Readback: View {
    @ObservedObject private var state = AuthorPaging176QA.shared
    var body: some View {
        HStack {
            Text(state.value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("author176.state").accessibilityValue(state.value)
            Button("释放分页") { state.released = true }.accessibilityIdentifier("author176.release")
            if AuthorPaging176QA.continuous {
                Button("拖动时释放") { AuthorPaging176QA.armReleaseOnDrag() }.accessibilityIdentifier("author176.release-on-drag")
            }
        }.padding(.bottom, 90)
    }
}

@MainActor enum AutoContinuationQA {
    static var scenario: String? {
        guard CollectionPagingQA.enabled,
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-auto-continuation=") }),
              let value = argument.components(separatedBy: "=").last,
              ["filtered-empty", "initial-empty", "rate-limited", "repeated-cursor", "sparse-reserve", "sparse-long64"].contains(value) else { return nil }
        return value
    }
    static var enabled: Bool { scenario != nil }
    static var filter: FeedFilter {
        if scenario == "sparse-long64" {
            return FeedFilter(kind: .video, sort: "Most Reactions", period: "Day", videoDurationRange: .init(minimumSeconds: 120, minimumIsExclusive: true))
        }
        return FeedFilter(kind: .video, sort: "Newest", period: "AllTime")
    }
    /// Long-duration metadata exercises filtering; validated local silent bytes
    /// remain the short fixture, so this is not a long-video playback benchmark.
    static var longSparseItems: [MediaItem] {
        (0..<18).map { index in
            var item = MediaItem(id: 64_000_100 + index, url: "https://example.invalid/long-sparse64-\(index).mp4",
                                 width: 320, height: 180, type: "video", username: "LongSparse_\(index)",
                                 browsingLevel: 1, thumbnail: nil, creatorID: CollectionPagingQA.ownerID, tags: [])
            item.metadata = VideoTechnicalMetadata(duration: 181)
            item.offlinePosterURL = CollectionPagingQA.root.appendingPathComponent("pattern-2.png")
            return item
        }
    }
    @MainActor final class Observer: ObservableObject {
        @Published var requests = 0
        @Published var totalRequests = 0
        @Published var requestGroups: [String: Int] = [:]
        @Published var first = 0
        @Published var continuations = 0
        @Published var lastCursor = "none"
        @Published var returned = "none"
        @Published var errors = 0
        @Published var kind = "none"
        @Published var gate = "armed"
        @Published var gateReleased = false
        @Published var gateScheduled = false
        var prepared = false
        var limited = false
        var value: String { "scenario=\(AutoContinuationQA.scenario ?? "none");totalRequests=\(totalRequests);groups=\(requestGroups.keys.sorted().map { "\($0):\(requestGroups[$0]!)" }.joined(separator: ","));requests=\(requests);first=\(first);continuations=\(continuations);lastCursor=\(lastCursor);returned=\(returned);errors=\(errors);kind=\(kind);gate=\(gate)" }
    }
    static let shared = Observer()
    static func prepare() async throws {
        guard enabled, !shared.prepared else { return }
        let source = CollectionPagingQA.wideVideoEnabled
            ? CollectionPagingQA.root.appendingPathComponent("wide.mp4")
            : ResumePromptQA.videoFixtureURL
        guard source.isFileURL, FileManager.default.fileExists(atPath: source.path) else { throw ClientError.invalidResponse }
        let audio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        guard audio.isEmpty else { throw ClientError.invalidResponse }
        if scenario == "sparse-reserve" {
            for item in CollectionPagingQA.sparseReserveItems {
                try CollectionPagingQA.seedVideoCache(source: source, item: item)
            }
        }
        if scenario == "sparse-long64" {
            for item in longSparseItems { try CollectionPagingQA.seedVideoCache(source: source, item: item) }
        }
        shared.prepared = true
    }
    static func page(filter: FeedFilter, cursor: String?, followed: Bool, isCreator: Bool) async throws -> MediaPage {
        guard let scenario else { throw ClientError.invalidResponse }
        // Each continuation assertion owns the discovery video chain. Neighbor
        // preloads remain real reads in totalRequests/requestGroups; they must
        // not masquerade as retries of the chain whose cursor is under test.
        let primary = !followed && !isCreator && filter == self.filter
        shared.totalRequests += 1
        let group = "\(isCreator ? "creator" : followed ? "following" : "discovery")-\(filter.effectiveKind.rawValue)-\(cursor == nil ? "first" : "next")"
        shared.requestGroups[group, default: 0] += 1
        if primary {
            shared.requests += 1; shared.lastCursor = cursor ?? "none"; shared.kind = filter.effectiveKind.rawValue
            if cursor == nil { shared.first += 1 } else { shared.continuations += 1 }
        }
        // Pause only the local transport response, after the real model has
        // entered loading. The QA button never calls a model or paging action.
        if primary, cursor == "scan-0", ["filtered-empty", "initial-empty", "sparse-reserve", "sparse-long64", "rate-limited"].contains(scenario), !shared.gateReleased {
            shared.gate = "waiting"
            let deadline = ContinuousClock.now + .seconds(60)
            while !shared.gateReleased {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ClientError.invalidResponse }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            shared.gate = "released"
        }
        // Preserve actual asynchronous loading/cooldown after gate release.
        try await Task.sleep(for: .milliseconds(cursor == nil ? 180 : 250))
        let fixture = CollectionPagingQA.items
        let page: MediaPage
        if scenario == "sparse-long64" {
            if cursor == nil {
                page = .init(items: Array(longSparseItems.prefix(3)), metadata: .init(nextCursor: "scan-0"))
            } else {
                guard let cursor, cursor.hasPrefix("scan-"), let index = Int(cursor.dropFirst(5)), (0..<45).contains(index) else { throw ClientError.invalidResponse }
                var short = fixture[2]; short.metadata = VideoTechnicalMetadata(duration: 90)
                let item = index % 3 == 2 ? longSparseItems[index / 3 + 3] : short
                page = .init(items: [item], metadata: .init(nextCursor: index == 44 ? nil : "scan-\(index + 1)"))
            }
        } else if scenario == "sparse-reserve" {
            let sparse = CollectionPagingQA.sparseReserveItems
            if cursor == nil {
                page = .init(items: [sparse[0]], metadata: .init(nextCursor: "scan-0"))
            } else {
                guard let cursor, cursor.hasPrefix("scan-"),
                      let index = Int(cursor.dropFirst(5)), (0...17).contains(index) else { throw ClientError.invalidResponse }
                let item = index % 3 == 2 ? sparse[index / 3 + 1] : fixture[0]
                page = .init(items: [item], metadata: .init(nextCursor: "scan-\(index + 1)"))
            }
        } else if cursor == nil {
            let firstItems = scenario == "initial-empty" ? [fixture[0]] : (scenario == "repeated-cursor" ? [fixture[2], fixture[4]] : [fixture[2]])
            page = .init(items: firstItems, metadata: .init(nextCursor: "scan-0"))
        } else if scenario == "rate-limited" {
            if primary, !shared.limited { shared.limited = true; shared.errors += 1; throw ClientError.http(429) }
            page = .init(items: [fixture[4]], metadata: .init(nextCursor: nil))
        } else if scenario == "repeated-cursor" {
            page = .init(items: [fixture[0]], metadata: .init(nextCursor: cursor))
        } else {
            guard let cursor, cursor.hasPrefix("scan-"), let index = Int(cursor.dropFirst(5)), (0...8).contains(index) else { throw ClientError.invalidResponse }
            page = index < 8 ? .init(items: [fixture[0]], metadata: .init(nextCursor: "scan-\(index + 1)"))
                : .init(items: scenario == "initial-empty" ? [] : [fixture[4]], metadata: .init(nextCursor: nil))
        }
        if primary { shared.returned = page.items.map { String($0.id) }.joined(separator: ",") }
        return page
    }
}

@MainActor final class NativePagerIdentityQA: ObservableObject {
    static let shared = NativePagerIdentityQA()
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-identity-during-drag161") }
    @Published var invalidated = false
    @Published private(set) var instances = Set<String>()
    @Published private(set) var movingDismantles = 0
    @Published private(set) var clearedDismantles = 0
    func received(_ id: String) { if Self.enabled { instances.insert(id) } }
    func dismantled(moving: Bool, hostsBefore: Int, hostsAfter: Int) {
        guard Self.enabled, invalidated else { return }
        if moving { movingDismantles += 1 }
        if hostsBefore > 0 && hostsAfter == 0 { clearedDismantles += 1 }
    }
    var value: String { "instances=\(instances.count);moving=\(movingDismantles);cleared=\(clearedDismantles);invalidated=\(invalidated ? 1 : 0)" }
}

private struct AutoContinuationQAReadback: View {
    @ObservedObject private var state = AutoContinuationQA.shared
    @ObservedObject private var identity = NativePagerIdentityQA.shared
    @EnvironmentObject private var session: SiteSession
    var body: some View {
        HStack(spacing: 8) {
            Text(state.value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                .accessibilityIdentifier("continuation.qa.state").accessibilityValue(state.value)
            if NativePagerIdentityQA.enabled {
                Text(identity.value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                    .accessibilityIdentifier("pager.identity.qa").accessibilityValue(identity.value)
            }
            if ["filtered-empty", "initial-empty", "sparse-reserve", "sparse-long64", "rate-limited"].contains(AutoContinuationQA.scenario ?? "") {
                Button(state.gateReleased ? "本地响应已释放" : "释放本地响应") {
                    if NativePagerIdentityQA.enabled {
                        state.gateScheduled = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            session.invalidateFeedIdentityForPagerQA()
                        }
                    } else if ProcessInfo.processInfo.arguments.contains("--qa-release-during-drag64") {
                        state.gateScheduled = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            state.gateReleased = true
                        }
                    } else { state.gateReleased = true }
                }
                    .accessibilityIdentifier("continuation.qa.release")
                    .disabled(state.gate != "waiting" || state.gateReleased || state.gateScheduled)
                    .frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, minHeight: 44).background(Color(uiColor: .systemBackground))
    }
}

/// Exercises the production Settings -> Collections -> grid -> full-screen route.
/// Simulator-only synthetic files; no network authorization, sync or user-data reset.
@MainActor enum TimelineCoverHandoffQA {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--qa-timeline-cover-handoff")
    static let original = URL(string: "https://example.invalid/paging-0")!
    static let declared = URL(string: "https://example.invalid/timeline-handoff-cover.png")!
    static var released = false

    static func prepare() async throws {
        guard enabled else { return }
        let cache = MediaCache.shared
        let name = SHA256.hash(data: Data(declared.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".img"
        let pixels = try Data(contentsOf: CollectionPagingQA.root.appendingPathComponent("pattern-3.png"))
        try pixels.write(to: cache.repairDirectory.appendingPathComponent(name), options: .atomic)
        let request = MediaPosterPolicy.coverRequest(source: original, declared: declared, isVideo: false)
        _ = try await cache.loadCoverPreview(request, context: "timeline-handoff-fixture")
        guard cache.preparedCoverMemory(request) != nil else { throw ImageLoadError.decode }
    }

    static func holdOriginalIfNeeded(_ url: URL) async throws {
        guard enabled, url == original else { return }
        while !released { try await Task.sleep(for: .milliseconds(50)) }
    }
}

@MainActor enum CollectionPagingQA {
    static var playbackDiagnosticMode: String? {
        let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-playback-diagnostics43=") })?.components(separatedBy: "=").last
        return value.flatMap { ["valid", "invalid-offline", "bad-cache", "invalid-untargeted", "invalid-current-target", "repair-vp9", "repair-vp8", "poster-stream49"].contains($0) ? $0 : nil }
    }
    static let enabled = ProcessInfo.processInfo.arguments.contains("--qa-collection-paging") ||
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--qa-auto-continuation=") }) ||
        ProcessInfo.processInfo.arguments.contains("--qa-details-tags") ||
        ProcessInfo.processInfo.arguments.contains("--qa-wide-video")
    static var wideVideoEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-wide-video") }
    static var detailsTagsEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-details-tags") }
    static let neutralDetailsTags: [MediaTag] = [
        .init(id: 42_001, name: "portrait"), .init(id: 42_002, name: "night"),
        .init(id: 42_003, name: "city"), .init(id: 42_004, name: "street fashion"),
        .init(id: 42_005, name: "soft lighting"), .init(id: 42_006, name: "cinematic"),
        .init(id: 42_007, name: "rain"), .init(id: 42_008, name: "architecture"),
        .init(id: 42_009, name: "neon signs"), .init(id: 42_010, name: "reflection"),
        .init(id: 42_011, name: "evening"), .init(id: 42_012, name: "long coat"),
        .init(id: 42_013, name: "urban landscape"), .init(id: 42_014, name: "depth of field"),
        .init(id: 42_015, name: "warm window light"), .init(id: 42_016, name: "35mm photo"),
        .init(id: 42_017, name: "blue hour"), .init(id: 42_018, name: "city walk")
    ]
    static let ownerID = 28_037_001
    private static let repairRun = UUID().uuidString
    private static let posterRun = UUID().uuidString
    static var posterStreamURL: URL { root.appendingPathComponent("stream49-" + posterRun + ".mp4") }
    static let collection = SavedCollection(id: 28_037_002, name: "分页测试收藏", userId: ownerID, type: "Image", mode: nil, read: "Private")
    static var collections: [SavedCollection] {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--qa-no-collections") { return [] }
        if arguments.contains("--qa-multiple-collections") {
            return [collection, SavedCollection(id: 28_037_003, name: "另一个收藏夹", userId: ownerID, type: "Image", mode: nil, read: "Public")]
        }
        return [collection]
    }
    static var otherCollectionItems: [MediaItem] {
        var item = MediaItem(id: 28_037_106, url: "https://example.invalid/other-folder", width: 192, height: 256,
                             type: "image", username: "PagingFixture", browsingLevel: 1, thumbnail: nil, tags: [])
        item.offlineMediaURL = root.appendingPathComponent("pattern-5.png")
        return [item] + Array(items.prefix(1))
    }
    static var biographyCase: String? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-biography-case=") })?.components(separatedBy: "=").last
    }
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitCollectionPagingQA", isDirectory: true)
    }
    static var initialDurationFilter: FeedFilter {
        guard ProcessInfo.processInfo.arguments.contains("--qa-duration-legacy") else { return FeedFilter() }
        let legacy = Data(#"{"kind":"all","sort":"Most Reactions","period":"Week","baseModel":"","onlyPG":false,"videoDurationRange":{"minimumSeconds":120}}"#.utf8)
        return (try? JSONDecoder().decode(FeedFilter.self, from: legacy)) ?? FeedFilter()
    }
    static var items: [MediaItem] {
        if let option = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-fast-swipe-network=") }),
           let run = UUID(uuidString: String(option.dropFirst("--qa-fast-swipe-network=".count))) {
            return (0..<4).map { index in
                var item = MediaItem(id: 28_193_400 + index, url: "", width: 320, height: 180, type: "video",
                                     username: VisualControlsQA.author, browsingLevel: 1, thumbnail: nil,
                                     creatorID: VisualControlsQA.creatorID, tags: [])
                item.offlineMediaURL = index == 0 ? ResumePromptQA.videoFixtureURL :
                    URL(string: "http://localhost:49371/\(run.uuidString)/\(index).mp4")
                item.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
                return item
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-playback-sessions172") {
            return (0..<6).map { offset in
                var item = MediaItem(id: 28_172_000 + offset, url: "https://example.invalid/double-buffer172-\(offset)",
                                     width: 320, height: 180, type: "video", username: VisualControlsQA.author,
                                     browsingLevel: 1, thumbnail: nil, creatorID: VisualControlsQA.creatorID, tags: [])
                item.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
                return item
            }
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-failure-next66=") }),
           let count = Int(argument.components(separatedBy: "=").last ?? ""), [2, 4].contains(count) {
            return (0..<6).map { index in
                var item = MediaItem(id: 28_037_100 + index, url: "", width: 320, height: 180,
                    type: "video", username: "FailurePattern_\(index)", browsingLevel: 1,
                    thumbnail: nil, creatorID: ownerID, tags: [])
                item.offlineMediaURL = index < count ? root.appendingPathComponent("missing-failure66-\(index).mp4") : ResumePromptQA.videoFixtureURL
                item.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
                return item
            }
        }
        if let mode = playbackDiagnosticMode {
            let workID = mode == "poster-stream49" ? PlaybackFailureDiagnostic.posterTargetWorkID : (mode == "invalid-untargeted" ? 146_853_867 :
                (mode == "invalid-current-target" ? PlaybackFailureDiagnostic.currentTargetWorkID : PlaybackFailureDiagnostic.targetWorkID)
            )
            let repair = mode.hasPrefix("repair-")
            var item = MediaItem(id: workID,
                                 url: repair ? "https://example.invalid/local-repair47/\(repairRun)/\(mode).mp4" : "",
                                 width: repair ? 320 : 480, height: repair ? 240 : 854, type: "video", username: "LocalPlaybackFixture",
                                 browsingLevel: 1, thumbnail: nil, creatorID: ownerID, tags: [])
            item.offlineMediaURL = mode == "invalid-offline" || mode == "invalid-untargeted" || mode == "invalid-current-target"
                ? root.appendingPathComponent("diagnostic-truncated.mp4") : ResumePromptQA.videoFixtureURL
            item.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
            if repair { item.offlineMediaURL = nil }
            if mode == "poster-stream49" {
                item.offlineMediaURL = posterStreamURL
                item.offlinePosterURL = root.appendingPathComponent("unreadable49.jpeg")
            }
            return [item]
        }
        return (0..<6).map { index in
            let video = index == 2 || index == 4
            let wideVideo = video && wideVideoEnabled
            let tall = ViewportAuditQA.enabled && index != 1
            var item = MediaItem(id: 28_037_100 + index, url: "https://example.invalid/paging-\(index)",
                                 width: wideVideo ? 480 : (tall ? 192 : (video ? 320 : 192)),
                                 height: wideVideo ? 320 : (tall ? 416 : (video ? 180 : 256)),
                                 type: video ? "video" : "image", username: VisualControlsQA.enabled ? VisualControlsQA.author : (ViewportAuditQA.enabled ? "PagingFixture" : "PagingPattern_\(index)"), browsingLevel: 1,
                                 thumbnail: index == 0 && TimelineCoverHandoffQA.enabled ? .init(url: TimelineCoverHandoffQA.declared.absoluteString) : nil, creatorID: ownerID,
                                 tags: detailsTagsEnabled ? neutralDetailsTags : [])
            item.offlineMediaURL = wideVideo ? root.appendingPathComponent("wide.mp4") : (video ? ResumePromptQA.videoFixtureURL : root.appendingPathComponent("pattern-\(index).png"))
            if ViewportAuditQA.enabled && video { item.offlineMediaURL = ViewportAuditQA.root.appendingPathComponent("vertical.mp4") }
            // Exercise the real favorite button for a normal cached work, while
            // keeping every byte local and all site requests disabled in QA.
            if index == 0 && ProcessInfo.processInfo.arguments.contains("--qa-theme-ui") { item.offlineMediaURL = nil }
            if VisualControlsQA.enabled {
                item.offlineMediaURL = nil; item.creatorID = VisualControlsQA.creatorID
                if index == 2, ProcessInfo.processInfo.arguments.contains("--qa-playback-follow-fallback") {
                    item.creatorID = nil
                    item.postTitle = "带标题的测试作品"
                }
            }
            if detailsTagsEnabled {
                item.createdAt = "2026-05-04T12:30:00.000Z"
                item.postID = 28_037_500
                if ProcessInfo.processInfo.arguments.contains("--qa-details-preview") {
                    item.postTitle = video ? "街景短片 · 测试样例" : "城市风景 · 测试样例"
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--qa-details-input-tags-unknown175") { item.tags = nil }
            if wideVideo { item.offlineMediaURL = root.appendingPathComponent("wide.mp4") }
            if video { item.offlinePosterURL = root.appendingPathComponent("pattern-\(index).png") }
            if video { item.metadata = VideoTechnicalMetadata(duration: index == 2 ? 119.9 : 120.1) }
            return item
        }
    }
    /// Sparse scenario reuses fixture 2 as its focused first video and adds
    /// distinct URL identities backed by the same validated silent local file.
    static var sparseReserveItems: [MediaItem] {
        let first = items[2]
        let extras = (1...6).map { offset -> MediaItem in
            let id = 28_037_300 + offset
            var item = MediaItem(id: id, url: "https://example.invalid/sparse-reserve-\(offset).mp4",
                                 width: wideVideoEnabled ? 480 : 320, height: wideVideoEnabled ? 320 : 180,
                                 type: "video", username: "PagingPattern_\(id)", browsingLevel: 1,
                                 thumbnail: nil, creatorID: ownerID,
                                 tags: detailsTagsEnabled ? neutralDetailsTags : [])
            item.offlineMediaURL = nil // Resolve through the locally seeded CivitMedia cache.
            item.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
            return item
        }
        var firstVideo = first
        firstVideo.offlineMediaURL = nil
        firstVideo.offlinePosterURL = root.appendingPathComponent("pattern-2.png")
        return [firstVideo] + extras
    }

    /// Seed the same URL-hash cache namespace used by MediaCache; never fetch
    /// fixture bytes from the example.invalid URL.
    static func seedVideoCache(source: URL, item: MediaItem) throws {
        guard source.isFileURL, FileManager.default.fileExists(atPath: source.path),
              let url = URL(string: item.url), url.scheme == "https", url.host == "example.invalid" else {
            throw ClientError.invalidResponse
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CivitMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data(contentsOf: source).write(to: cache.appendingPathComponent(digest + ".mp4"), options: .atomic)
    }

    static func validateWideVideoIfRequested() async throws {
        guard wideVideoEnabled else { return }
        let file = root.appendingPathComponent("wide.mp4")
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else { throw ClientError.invalidResponse }
        let audio = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        guard audio.isEmpty else { throw ClientError.invalidResponse }
    }
    static func preparePlaybackDiagnosticsIfRequested() async throws {
        guard let mode = playbackDiagnosticMode else { return }
        if mode.hasPrefix("repair-") {
            let fixture = root.appendingPathComponent(mode + ".webm")
            guard MediaImageDecoder.looksLikeVideo(fixture), let item = items.first else { throw ClientError.invalidResponse }
            try seedVideoCache(source: fixture, item: item)
            try await LocalDiagnosticsStore.shared.clear()
            return
        }
        let original = ResumePromptQA.videoFixtureURL
        guard original.isFileURL, try await AVURLAsset(url: original).loadTracks(withMediaType: .audio).isEmpty else {
            throw ClientError.invalidResponse
        }
        let bytes = try Data(contentsOf: original)
        guard bytes.count > 1_024 && bytes.count < 64 * 1024 * 1024 else { throw ClientError.invalidResponse }
        if mode == "poster-stream49" {
            let latePoster = ProcessInfo.processInfo.arguments.contains("--qa-poster-late51")
            try (latePoster ? Data(bytes.prefix(1_024)) : bytes).write(to: posterStreamURL, options: .atomic)
            try Data("synthetic invalid poster body".utf8).write(to: root.appendingPathComponent("unreadable49.jpeg"), options: .atomic)
            try await LocalDiagnosticsStore.shared.clear()
            return
        }
        let broken = Data(bytes.prefix(1_024))
        try broken.write(to: root.appendingPathComponent("diagnostic-truncated.mp4"), options: .atomic)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(original.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".mp4"
        let ownFixtureCache = cache.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: ownFixtureCache.path) { try FileManager.default.removeItem(at: ownFixtureCache) }
        if mode == "bad-cache" { try broken.write(to: ownFixtureCache, options: .atomic) }
        try await LocalDiagnosticsStore.shared.clear()
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemCyan, .systemPink]
        for index in 0..<6 {
            let width: CGFloat = ContentPerformance179QA.enabled ? 450 : 192
            let height: CGFloat = ContentPerformance179QA.enabled ? 640 : (ViewportAuditQA.enabled && index != 1 ? 416 : 256)
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
                colors[index].setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                UIColor.white.setFill(); context.fill(CGRect(x: 16, y: 16, width: 160, height: 24))
                if ProcessInfo.processInfo.arguments.contains("--qa-chrome-texture181") {
                    for row in 0..<Int(ceil(height / 24)) {
                        for column in 0..<Int(ceil(width / 24)) where (row + column) % 2 == 0 {
                            UIColor.white.withAlphaComponent(0.4).setFill()
                            context.fill(CGRect(x: CGFloat(column) * 24, y: CGFloat(row) * 24, width: 24, height: 24))
                        }
                    }
                }
            }
            let file = root.appendingPathComponent("pattern-\(index).png")
            let data = image.pngData()!
            try data.write(to: file, options: .atomic)
            if AuthorPaging176QA.holdsCovers { try data.write(to: AuthorPaging176QA.coverFixture(at: index), options: .atomic) }
            if VisualControlsQA.enabled {
                let source = URL(string: "https://example.invalid/paging-\(index)")!
                let video = index == 2 || index == 4
                let name = SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + (video ? ".mp4" : ".img")
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let data = video ? try Data(contentsOf: ResumePromptQA.videoFixtureURL) : image.pngData()!
                try data.write(to: cache.appendingPathComponent(name), options: .atomic)
            }
            if index == 0 && ProcessInfo.processInfo.arguments.contains("--qa-theme-ui") {
                let source = URL(string: "https://example.invalid/paging-0")!
                let name = SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".img"
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitMedia", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try image.pngData()!.write(to: cache.appendingPathComponent(name), options: .atomic)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-playback-sessions172") {
            for item in items { try seedVideoCache(source: ResumePromptQA.videoFixtureURL, item: item) }
        }
        // Audio is absent from the test video; mute is also enforced in the player.
        UserDefaults.standard.set(true, forKey: "muted")
        UserDefaults.standard.set(true, forKey: "autoplay")
    }
}

struct CollectionPagingQAView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var ready = false
    @State private var latePosterWrite51 = "not-written"
    @State private var timelineTopRequest53 = 0
    @State private var timelineRestartRequest53 = 0
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--qa-theme-timeline") || VisualControlsQA.enabled || AutoContinuationQA.enabled || CollectionPagingQA.playbackDiagnosticMode != nil ? 0 : 3
    @State private var filter = CollectionPagingQA.initialDurationFilter
    private var biographyCase: String? {
        CollectionPagingQA.biographyCase
    }
    private var posterDetailsItem50: MediaItem {
        if ProcessInfo.processInfo.arguments.contains("--qa-image-failure55") {
            var value = MediaItem(id: 55_003, url: "", width: 192, height: 256, type: "image",
                                  username: "LocalFixture", browsingLevel: 8, thumbnail: nil, tags: [])
            value.offlineMediaURL = CollectionPagingQA.root.appendingPathComponent("missing-image55.png")
            return value
        }
        var item = CollectionPagingQA.items[0]
        if ProcessInfo.processInfo.arguments.contains("--qa-poster-missing50") { item.offlineMediaURL = nil }
        return item
    }
    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--qa-duration-filter") {
                FilterView(filter: $filter).overlay(alignment: .topTrailing) {
                    Text(filter.videoDurationRange?.summary ?? "none").font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                        .accessibilityIdentifier("duration.qa.state").accessibilityValue(filter.videoDurationRange?.summary ?? "none")
                }
            } else if ready && ProcessInfo.processInfo.arguments.contains("--qa-empty-deck63") {
                EmptyMediaDeckQAView()
            } else if ready && ProcessInfo.processInfo.arguments.contains("--qa-poster-details50") {
                MediaDetailsView(item: posterDetailsItem50)
            } else if let biographyCase, ready {
                NavigationStack {
                    CreatorView(creator: Creator(id: CollectionPagingQA.ownerID, username: "Pattern Creator"))
                        .frame(maxWidth: biographyCase == "narrow" || biographyCase == "dynamic" ? 320 : .infinity)
                }.dynamicTypeSize(biographyCase == "dynamic" ? .accessibility2 : .large)
            } else if ready {
                MainTabs(selectedTab: $selectedTab, onTimelineTap: { timelineTopRequest53 += 1 }, onTimelineDoubleTap: { timelineRestartRequest53 += 1 },
                         timeline: TimelineView(isVisible: selectedTab == 0, restartRequest: timelineRestartRequest53, topRequest: timelineTopRequest53), authors: LeaderboardView(),
                         search: SearchView(), collections: CollectionsView(),
                         pageContentRevisions: [0: AnyHashable([selectedTab == 0 ? 1 : 0, timelineRestartRequest53, timelineTopRequest53])])
            } else { ProgressView() }
        }
        .frame(maxWidth: VisualControlsQA.width ?? (ProcessInfo.processInfo.arguments.contains("--qa-theme-compact") ? 320 : .infinity))
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--qa-theme-compact") || VisualControlsQA.largeType ? .accessibility2 : .large)
        // The QA transport control covers only the existing 104pt timeline
        // header, outside the native media viewport. It never resizes the deck.
        .overlay(alignment: .topTrailing) { if AutoContinuationQA.enabled { AutoContinuationQAReadback() } }
        .overlay(alignment: .bottomLeading) {
            if TimelineCoverHandoffQA.enabled && ready {
                Button("完成测试原图加载") { TimelineCoverHandoffQA.released = true }
                    .font(.caption).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("timeline-cover.qa.release")
            }
        }
        .overlay(alignment: .bottomLeading) { if AuthorPaging176QA.enabled { AuthorPaging176Readback() } }
        .overlay(alignment: .bottomLeading) { if CollectionOpenFileQA.enabled { CollectionOpenFileReadback() } }
        .overlay(alignment: .bottomLeading) { if ContentPerformance179QA.enabled { ContentPerformance179Controls() } }
        .overlay(alignment: .topTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--qa-favorite-save69-delay") {
                let value = "pending=\(session.savingFavoriteID ?? -1);saved=\(!(session.savedMemberships[28_037_100] ?? []).isEmpty);message=\(session.message != nil)"
                Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("favorite69.qa.state").accessibilityValue(value)
            }
        }
        .existingFeedbackToast(ProcessInfo.processInfo.arguments.contains("--qa-favorite-save69-delay") ? session.message : nil,
                               global: true, scope: session.feedIdentity, onShown: { message in
            if session.message == message { session.message = nil }
        })
        .overlay(alignment: .topLeading) { if CollectionPagingQA.playbackDiagnosticMode != nil { PlaybackDiagnostics43Readback() } }
        .overlay(alignment: .bottomTrailing) {
            if ready && (ProcessInfo.processInfo.arguments.contains("--qa-poster-late51") || ProcessInfo.processInfo.arguments.contains("--qa-cover-refresh177")) {
                Button("生成测试封面") {
                    Task {
                        do {
                            guard let source = posterDetailsItem50.mediaURL,
                                  let frame = MediaImageDecoder.preview(CollectionPagingQA.root.appendingPathComponent("pattern-2.png"), pixels: 384),
                                  let data = UIImage(cgImage: frame).jpegData(compressionQuality: 0.85) else {
                                throw ImageLoadError.decode
                            }
                            try await MediaCache.shared.storeGeneratedPoster(data, source: source,
                                expectedGeneration: MediaCache.shared.repairGeneration)
                            latePosterWrite51 = "written"
                        } catch {
                            latePosterWrite51 = ProcessInfo.processInfo.arguments.contains("--qa-cover-refresh177")
                                ? "failed:\(PosterDiagnosticPolicy.failure(error, stage: .cachedPoster).rawValue)" : "failed"
                        }
                    }
                }
                .accessibilityIdentifier("poster.qa.generate51")
                .accessibilityValue(latePosterWrite51)
                .padding(12)
            }
        }
        .task {
            do {
                if ContentPerformance179QA.enabled { ContentPerformance179QA.setupStage = "patterns" }
                try CollectionPagingQA.prepare()
                try await TimelineCoverHandoffQA.prepare()
                try await CollectionPagingQA.validateWideVideoIfRequested()
                try await CollectionPagingQA.preparePlaybackDiagnosticsIfRequested()
                if AutoContinuationQA.enabled { try await AutoContinuationQA.prepare() }
                session.configureForCollectionPagingQA()
                await AuthorPaging176QA.prepareTagIndex(session: session)
                if ContentPerformance179QA.enabled { ContentPerformance179QA.setupStage = "offline" }
                if ViewportAuditQA.enabled { try await ViewportAuditQA.prepare(session: session) }
                if ContentPerformance179QA.enabled { ContentPerformance179QA.setupStage = "ready" }
                ready = true
            }
            catch {
                if ContentPerformance179QA.enabled { ContentPerformance179QA.setupStage = "failed:" + String(error.localizedDescription.prefix(160)) }
                session.message = "Unable to prepare paging fixtures"
            }
        }
    }
    static func biography(_ value: String) -> String {
        switch value {
        case "empty": return ""
        case "short": return "Images and video."
        case "chinese": return "这是一段用于检查作者简介排版的中文测试内容。正文使用页面全宽，默认只显示两行。\n\n第二段保留原来的段落，不会把展开按钮挤到正文右侧。\n\n末段用于确认收起后的高度和阅读顺序。"
        case "url": return "Creator portfolio:\nhttps://example.com/" + String(repeating: "portfolio-segment-", count: 10) + "\n\nLinks use the original safe destination and wrap within the available width."
        default: return "A creator working with images and videos. This paragraph is long enough to verify that the biography uses the available width and truncates after exactly two lines.\n\nThe second paragraph stays separate when expanded.\n\nA final paragraph for a controlled layout check."
        }
    }
}

struct EmptyMediaDeckQAView: View {
    private static let creatorID = 900_000_063
    @State private var seeded = false
    @State private var focused: Int? = 900_000_063
    @State private var phase: FeedContinuationState = .scanning
    @State private var requests = 0
    @State private var invalidSource = false
    @State private var closed = false
    private var item: MediaItem {
        var value = MediaItem(id: Self.creatorID, url: invalidSource ? "" : "https://example.invalid/blank63.mp4",
            width: 480, height: 854, type: "video", username: "Synthetic_Blank_Page", browsingLevel: 1,
            thumbnail: nil, creatorID: Self.creatorID, tags: [])
        if !invalidSource { value.offlineMediaURL = ResumePromptQA.videoFixtureURL }
        return value
    }
    private func request() async { requests += 1; phase = .scanning }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if closed {
                Text("已退出查看器").accessibilityIdentifier("empty.qa.closed")
            } else if seeded {
                FeedMediaViewer(items: [item], focused: $focused, initialID: Self.creatorID, continuationState: phase,
                    refreshFromStart: { await request() }, onClose: { closed = true }, loadMore: { await request() })
            }
            HStack {
                Button("模拟失败") { phase = .failed(.request(message: "Local synthetic failure", retryAfter: nil)) }
                    .accessibilityIdentifier("empty.qa.fail")
                Button("模拟空结果") { phase = .ready }.accessibilityIdentifier("empty.qa.ready")
                Button("显示作品") { AuthorBlocklist.shared.remove(id: Self.creatorID); phase = .ended }
                    .accessibilityIdentifier("empty.qa.recover")
                Button("无效地址") { invalidSource = true; AuthorBlocklist.shared.remove(id: Self.creatorID); phase = .ended }
                    .accessibilityIdentifier("empty.qa.invalid")
                Button("过滤全部") {
                    _ = AuthorBlocklist.shared.add(Creator(id: Self.creatorID, username: "Synthetic_Blank_Page"))
                    phase = .ended
                }.accessibilityIdentifier("empty.qa.block")
            }.font(.caption2).buttonStyle(.bordered).padding(.top, 80)
            Text("raw=1;requests=\(requests)").font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("empty.qa.state").accessibilityValue("raw=1;requests=\(requests)")
        }
        .task {
            AuthorBlocklist.shared.remove(id: Self.creatorID)
            _ = AuthorBlocklist.shared.add(Creator(id: Self.creatorID, username: "Synthetic_Blank_Page"))
            seeded = true
        }
        .onDisappear { AuthorBlocklist.shared.remove(id: Self.creatorID) }
    }
}

struct MediaPreloadQAReadback: View {
    let preloader: MediaPreloader
    var pagingAllowed = true
    @State private var value = "pending"
    var body: some View {
        Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityIdentifier("media.qa.prefetch").accessibilityValue(value)
            .task(id: pagingAllowed) {
                while !Task.isCancelled {
                    let state = preloader.snapshot
                    value = "active=\(state.active);desired=\(state.desired);ready=\(state.ready);failed=\(state.failed);networkPaused=\(state.networkPaused);pagingAllowed=\(pagingAllowed)"
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
    }
}

private struct PlaybackDiagnostics43Readback: View {
    @State private var value = "[]"
    var body: some View {
        Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityIdentifier("qa.playback-diagnostics43")
            .accessibilityLabel("Playback diagnostic fixture readback")
            .accessibilityValue(value)
            .task {
                while !Task.isCancelled {
                    if let entries = try? await LocalDiagnosticsStore.shared.entries() {
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
                        if let data = try? encoder.encode(entries.filter {
                            $0.area == .playback || (CollectionPagingQA.playbackDiagnosticMode == "poster-stream49" && $0.area == .thumbnail)
                        }) { value = String(decoding: data, as: UTF8.self) }
                    }
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
    }
}

struct CollectionPagingQAFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct CollectionPagingQAObserver: ViewModifier {
    let focused: Int?
    @State private var frames: [String: CGRect] = [:]
    private var value: String {
        guard let viewport = frames["viewport"], let focused, let page = frames["page-\(focused)"] else { return "waiting" }
        let others = frames.filter { $0.key.hasPrefix("page-") && $0.key != "page-\(focused)" }
        let overlaps = others.values.filter { $0.intersection(viewport).width > 1 && $0.intersection(viewport).height > 1 }.count
        let base = "focused=\(focused);viewportY=\(viewport.minY);viewportH=\(viewport.height);pageY=\(page.minY);pageH=\(page.height);viewportX=\(viewport.minX);viewportW=\(viewport.width);pageX=\(page.minX);pageW=\(page.width);neighborOverlap=\(overlaps)"
        guard VisualControlsQA.enabled else { return base }
        let extra = ["favorite", "details", "mute", "rotate", "follow", "author", "social", "follow.text", "favorite.icon", "details.icon", "mute.icon", "rotate.icon", "follow.icon"].compactMap { name -> String? in
            guard let frame = frames["control.\(focused).\(name)"] else { return nil }
            let key = name.replacingOccurrences(of: ".", with: "_")
            return "\(key)X=\(frame.minX);\(key)Y=\(frame.minY);\(key)W=\(frame.width);\(key)H=\(frame.height)"
        }.joined(separator: ";")
        return base + ";" + extra
    }
    func body(content: Content) -> some View {
        if CollectionPagingQA.enabled {
            content.onPreferenceChange(CollectionPagingQAFrameKey.self) { frames = $0; record($0) }
                .overlay(alignment: .topTrailing) {
                    Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("collection.qa.geometry").accessibilityValue(value)
                }
        } else { content }
    }
    private func record(_ values: [String: CGRect]) {
        let rectangles = values.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        var scrolls: [[String: Any]] = []
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            func visit(_ view: UIView) {
                if let scroll = view as? UIScrollView {
                    let frame = scroll.convert(scroll.bounds, to: window)
                    scrolls.append(["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                                    "offsetY": scroll.contentOffset.y, "insetTop": scroll.adjustedContentInset.top, "insetBottom": scroll.adjustedContentInset.bottom,
                                    "contentHeight": scroll.contentSize.height])
                }
                view.subviews.forEach(visit)
            }
            visit(window)
        }
        let object: [String: Any] = ["focused": focused as Any? ?? NSNull(), "frames": rectangles, "scrolls": scrolls]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: CollectionPagingQA.root.appendingPathComponent("geometry.json"), options: .atomic)
        }
    }
}
/// Uses the real presenter with synthetic payloads; no network or account writes.
struct PresentationLifecycleQAView: View {
    private struct Request: Identifiable { let id = UUID(); let workID = 7; let number: Int }
    @State private var request: Request?
    @State private var sourceVisible = true
    @State private var begins = 0
    @State private var ends = 0
    @State private var mounts = 0
    @State private var staleRejected = false
    @State private var oldMayClose: (() -> Bool)?
    @State private var route = NativeHeaderRoute()
    private var scenario: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--qa-lifecycle-case=") }?.components(separatedBy: "=").last ?? "replace"
    }
    var body: some View {
        VStack {
            Text("Lifecycle").accessibilityIdentifier("qa.lifecycle.state")
                .accessibilityValue("begins=\(begins);ends=\(ends);mounts=\(mounts);source=\(sourceVisible ? 1 : 0);staleRejected=\(staleRejected ? 1 : 0)")
            if sourceVisible {
                Button("Open") { request = Request(number: 1) }.accessibilityIdentifier("qa.lifecycle.open")
                    .pagePresentation(item: $request, route: route, onBegin: { _, _ in
                        begins += 1
                        if scenario == "begin-remove" { request = nil; sourceVisible = false }
                    }, onEnd: { payload, _ in
                        ends += 1
                        if scenario == "end-remove", payload.number == 1 {
                            request = Request(number: 2)
                            sourceVisible = false
                        }
                    }) { payload, _, mayClose in
                        VStack {
                            Text("Work \(payload.workID) / \(payload.number)")
                                .accessibilityIdentifier("qa.lifecycle.presented.\(payload.number)")
                            Button("Replace same work") { request = Request(number: 2) }
                                .accessibilityIdentifier("qa.lifecycle.replace")
                            Button("Close") { if mayClose() { request = nil } }
                                .accessibilityIdentifier("qa.lifecycle.close")
                        }
                        .onAppear {
                            mounts += 1
                            if payload.number == 1 { oldMayClose = mayClose }
                            else { staleRejected = oldMayClose?() == false }
                        }
                    }
            }
        }
    }
}
/// Exercises the actual raster owner, including a target that changes row
/// geometry after its first snapshot. No network or account is involved.
struct HeaderStagingQAView: View {
    @State private var report = "pending"
    var body: some View {
        Text(report).accessibilityIdentifier("header.staging.qa").accessibilityValue(report)
            .task {
                func header(height: CGFloat, row: CGFloat, light: Bool) -> HeaderContent {
                    .init(frame: CGRect(x: 16, y: 70, width: 370, height: height), appearance: .init(
                        controls: AnyView(Text(light ? "目标" : "来源").frame(width: 370, height: height)),
                        firstRowHeight: row, colorScheme: light ? .light : .dark,
                        surfaceColor: light ? .white : .black, borderColor: .gray, surfaceHeight: height))
                }
                let source = header(height: 36, row: 36, light: false)
                let tone = PageToneTransition(source: .black, sourceScheme: .dark)
                guard let flight = HeaderHandoff(source: source, tone: tone) else { report = "renderFailed"; return }
                flight.stageSurface(header(height: 36, row: 36, light: true))
                let initiallyStaged = flight.stagedControls != nil && flight.stagedTarget != nil
                flight.stageSurface(header(height: 68, row: 34, light: true))
                let heightRevoked = flight.stagedControls == nil && flight.stagedTarget == nil
                flight.stageSurface(header(height: 36, row: 36, light: true))
                let restaged = flight.stagedControls != nil
                flight.stageSurface(header(height: 36, row: 18, light: true))
                let rowRevoked = flight.stagedControls == nil && flight.stagedTarget == nil
                flight.stageSurface(header(height: 36, row: 36, light: true))
                let tall = header(height: 68, row: 34, light: true)
                let replaced = await flight.replace(with: tall, while: { true })
                report = "staged=\(initiallyStaged ? 1 : 0);heightRevoked=\(heightRevoked ? 1 : 0);restaged=\(restaged ? 1 : 0);rowRevoked=\(rowRevoked ? 1 : 0);finalRevoked=\(flight.stagedControls == nil ? 1 : 0);height=\(flight.height);finished=\(replaced && flight.phase == .finished ? 1 : 0)"
                flight.cancel()
            }
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
struct AppToastQAView: View {
    @State private var message: String?
    @State private var pageMessage: String?
    @State private var hiddenMessage: String?
    @State private var event = 0
    @State private var taps = 0
    @State private var scope = 0
    @State private var child = false
    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            VStack(spacing: 16) {
                Button("显示已有错误") { event += 1; message = "已有错误提示" }.accessibilityIdentifier("toast.qa.show")
                Button("重复已有错误") {
                    event += 1; message = "重复错误提示"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        event += 1; message = "重复错误提示"
                    }
                }.accessibilityIdentifier("toast.qa.repeat")
                Button("显示长提示") {
                    event += 1; message = String(repeating: "已有的长错误提示，需要保留可读性。", count: 8)
                }.accessibilityIdentifier("toast.qa.long")
                Button("无反馈操作") { taps += 1 }.accessibilityIdentifier("toast.qa.silent")
                Button("失活来源") { hiddenMessage = "失活来源错误" }.accessibilityIdentifier("toast.qa.inactive")
                Button("切换作用域") { scope += 1 }.accessibilityIdentifier("toast.qa.scope")
                Button("打开子页") { child = true }.accessibilityIdentifier("toast.qa.child")
                Text("\(taps)").accessibilityIdentifier("toast.qa.count")
            }.padding(.top, 90)
            Button("透传点击") { taps += 1 }
                .frame(width: 160, height: 44)
                .position(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY)
                .accessibilityIdentifier("toast.qa.passthrough")
            Color.clear.frame(width: 1, height: 1)
                .existingFeedbackToast(hiddenMessage, active: false)
        }
        .ignoresSafeArea()
        .existingFeedbackToast(message, id: event, global: true, scope: scope, onShown: { value in
            if message == value { message = nil }
        })
        .existingFeedbackToast(pageMessage)
        .fullScreenCover(isPresented: $child) { AppToastChildQAView() }
    }
}
private struct AppToastChildQAView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    var body: some View {
        VStack(spacing: 24) {
            Button("显示子页已有错误") { message = "子页已有错误" }.accessibilityIdentifier("toast.qa.child-error")
            Button("关闭子页") { dismiss() }.accessibilityIdentifier("toast.qa.close-child")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .existingFeedbackToast(message)
    }
}
#endif
