import SwiftUI
import os
import UIKit

/// Opt-in for a signed diagnostic build. The simulator can enable the same reader in UI tests.
@MainActor enum NavigationDiagnostics {
    #if CIVIT_NAVIGATION_DIAGNOSTICS
    static let enabled = true
    #elseif DEBUG && targetEnvironment(simulator)
    static let enabled = ProcessInfo.processInfo.arguments.contains("--qa-navigation-diagnostics")
    #else
    static let enabled = false
    #endif

    private static let recorder = Recorder()
    private static var timer: DispatchSourceTimer?
    private static var activeProbes = Set<ObjectIdentifier>()
    #if DEBUG && targetEnvironment(simulator)
    private static var injectedDelay = false
    #endif

    static func mark(_ event: NavigationTrace.Event, tab: Int? = nil, owner: NavigationTrace.Owner? = nil, locks: Int? = nil) {
        guard enabled else { return }
        recorder.add(event, tab: tab, owner: owner, locks: locks)
    }

    static func clearHistory() -> Int? { enabled ? recorder.clearHistory() : nil }

    static func exportSnapshot() -> (trace: NavigationTrace, generation: Int)? {
        enabled ? recorder.exportSnapshot() : nil
    }

    static func probeActive(_ probe: UIView, _ active: Bool) {
        let key = ObjectIdentifier(probe)
        if active { activeProbes.insert(key) }
        else { activeProbes.remove(key) }
        let isActive = !activeProbes.isEmpty
        guard recorder.setActive(isActive) else { return }
        if isActive {
            let recorder = recorder
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(175), leeway: .milliseconds(30))
            timer.setEventHandler { recorder.poll() }
            timer.resume()
            self.timer = timer
            #if DEBUG && targetEnvironment(simulator)
            if !injectedDelay, ProcessInfo.processInfo.arguments.contains("--qa-navigation-main-delay") {
                injectedDelay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Thread.sleep(forTimeInterval: 0.85) }
            }
            #endif
        } else {
            timer?.cancel()
            timer = nil
            recorder.flush()
        }
    }

    struct Monitor: View {
        @Environment(\.scenePhase) private var phase

        var body: some View {
            if NavigationDiagnostics.enabled {
                Attachment(active: phase == .active)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private struct Attachment: UIViewRepresentable {
        let active: Bool

        func makeUIView(context: Context) -> WindowProbe { WindowProbe() }
        func updateUIView(_ view: WindowProbe, context: Context) { view.isActive = active }
        static func dismantleUIView(_ view: WindowProbe, coordinator: ()) { view.isActive = false }
    }

    private final class WindowProbe: UIView {
        var isActive = false {
            didSet { if oldValue != isActive { updateAttachment() } }
        }
        private weak var observedWindow: UIWindow?
        private let observer: PassiveTouches = {
            let observer = PassiveTouches()
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            return observer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateAttachment()
        }

        private func updateAttachment() {
            let target = isActive ? window : nil
            if observedWindow !== target {
                observedWindow?.removeGestureRecognizer(observer)
                target?.addGestureRecognizer(observer)
                observedWindow = target
            }
            NavigationDiagnostics.probeActive(self, target != nil)
        }
    }

    private final class PassiveTouches: UIGestureRecognizer {
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let window = view as? UIWindow, let touch = touches.first else { return }
            let point = touch.location(in: window)
            let zone: NavigationTrace.Zone
            if point.y <= window.safeAreaInsets.top + 90 { zone = .top }
            else if point.y >= window.bounds.height - window.safeAreaInsets.bottom - 64 { zone = .bottom }
            else if ScreenEdgeGesture.contains(distance: point.x - window.bounds.minX) { zone = .leftEdge }
            else if ScreenEdgeGesture.contains(distance: window.bounds.maxX - point.x) { zone = .rightEdge }
            else { zone = .body }
            let shield = PageInteractionShield.diagnosticTarget(for: touch.view, in: window)
            NavigationDiagnostics.recorder.add(shield.hit ? .shieldTouch : .touch, owner: shield.owner, locks: shield.locks, zone: zone)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    }

    private final class Recorder: Sendable {
        private struct State {
            var active = false
            var pendingProbe: Int?
            var reportedDelay = false
            var samples: [NavigationTrace.Sample] = []
            var serial = 0
            var writtenSerial = 0
            var lastWrite = -3_000
            var newest = 0
            var generation = 0
            var reportedShield = false
        }

        private struct Write {
            let trace: NavigationTrace
            let generation: Int
        }

        private struct Tick {
            var ping: Int?
            var delayed: Write?
            var activity: Write?
        }

        private let epoch = DispatchTime.now().uptimeNanoseconds
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let delayThreshold = 350

        private func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds - epoch) / 1_000_000) }

        func setActive(_ active: Bool) -> Bool {
            state.withLock { state in
                guard state.active != active else { return false }
                state.active = active
                state.pendingProbe = nil
                state.reportedDelay = false
                append(active ? .monitorStarted : .monitorStopped, elapsed(), to: &state)
                return true
            }
        }

        func add(_ event: NavigationTrace.Event, tab: Int? = nil, owner: NavigationTrace.Owner? = nil,
                 locks: Int? = nil, zone: NavigationTrace.Zone? = nil) {
            let blocked = state.withLock { state -> Write? in
                append(event, elapsed(), to: &state, tab: tab, owner: owner, locks: locks, zone: zone)
                if event == .leaseReleased, locks == 0 { state.reportedShield = false }
                guard event == .shieldTouch, !state.reportedShield else { return nil }
                state.reportedShield = true
                return snapshot(state)
            }
            if let blocked { persist(.navigationShieldBlocked, blocked) }
        }

        func clearHistory() -> Int {
            state.withLock { state in
                state.generation += 1
                state.samples.removeAll(keepingCapacity: true)
                state.writtenSerial = state.serial
                state.pendingProbe = nil
                state.reportedDelay = false
                state.reportedShield = false
                return state.generation
            }
        }

        func exportSnapshot() -> (trace: NavigationTrace, generation: Int)? {
            state.withLock { state in
                guard !state.samples.isEmpty else { return nil }
                return (NavigationTrace(samples: state.samples), state.generation)
            }
        }

        private func append(_ event: NavigationTrace.Event, _ now: Int, to state: inout State, tab: Int? = nil,
                            owner: NavigationTrace.Owner? = nil, locks: Int? = nil, zone: NavigationTrace.Zone? = nil) {
            if state.samples.count == NavigationTrace.capacity { state.samples.removeFirst() }
            state.samples.append(.init(ms: now, event: event, tab: tab, owner: owner, locks: locks, zone: zone))
            state.serial += 1
            state.newest = now
        }

        func poll() {
            let tick = state.withLock { state -> Tick in
                guard state.active else { return Tick() }
                let now = elapsed()
                var due = Tick()
                if let pending = state.pendingProbe {
                    let age = now - pending
                    if !state.reportedDelay, age >= delayThreshold {
                        state.reportedDelay = true
                        due.delayed = snapshot(state, delay: age, probe: pending)
                    }
                } else {
                    state.pendingProbe = now
                    due.ping = now
                }
                if now - state.newest >= 600 || now - state.lastWrite >= 3_500 {
                    due.activity = snapshotIfDue(&state, at: now)
                }
                return due
            }
            if let trace = tick.delayed { persist(.navigationMainDelayed, trace) }
            if let trace = tick.activity { persist(.navigationTrace, trace) }
            if let sent = tick.ping { DispatchQueue.main.async { self.answered(sent) } }
        }

        private func answered(_ sent: Int) {
            let recovery = state.withLock { state -> Write? in
                guard state.pendingProbe == sent else { return nil }
                state.pendingProbe = nil
                let delay = elapsed() - sent
                state.reportedDelay = false
                return delay >= delayThreshold ? snapshot(state, delay: delay, probe: sent) : nil
            }
            if let recovery { persist(.navigationMainResumed, recovery) }
        }

        func flush() {
            if let trace = state.withLock({ snapshotIfDue(&$0, at: elapsed(), immediately: true) }) {
                persist(.navigationTrace, trace)
            }
        }

        private func snapshotIfDue(_ state: inout State, at now: Int, immediately: Bool = false) -> Write? {
            guard state.serial != state.writtenSerial, immediately || now - state.lastWrite >= 3_000 else { return nil }
            state.writtenSerial = state.serial
            state.lastWrite = now
            return snapshot(state)
        }

        private func snapshot(_ state: State, delay: Int? = nil, probe: Int? = nil) -> Write {
            Write(trace: NavigationTrace(samples: state.samples, delayMS: delay, probeMS: probe),
                  generation: state.generation)
        }

        private func persist(_ code: DiagnosticCode, _ write: Write) {
            Task {
                await LocalDiagnosticsStore.shared.record(area: .navigation, code: code, navigation: write.trace,
                                                          navigationGeneration: write.generation)
            }
        }
    }
}
