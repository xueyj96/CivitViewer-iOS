import UIKit

/// Owns only new touches during an app transition. Existing drags retain their
/// original touch target, so they can still complete or cancel normally.
@MainActor final class PageInteractionShield {
    private final class BlockerView: UIView {
        var hitTarget: ((CGPoint, UIEvent?) -> UIView?)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if let target = hitTarget?(point, event) { return target }
            return super.hitTest(point, with: event)
        }
    }

    @MainActor final class Lease {
        private weak var owner: PageInteractionShield?
        private let id: UUID
        fileprivate init(owner: PageInteractionShield, id: UUID) { self.owner = owner; self.id = id }
        func release() {
            let owner = self.owner
            self.owner = nil
            owner?.release(id)
        }
        isolated deinit { owner?.release(id) }
    }
    private static var windowKey: UInt8 = 0
    private weak var window: UIWindow?
    private let blocker = BlockerView()
    private var owners = Set<UUID>()
    private var hitTargets: [UUID: (CGPoint, UIEvent?) -> UIView?] = [:]
    private var diagnosticOwners: [UUID: NavigationTrace.Owner] = [:]
    #if DEBUG && targetEnvironment(simulator)
    private var readback: UILabel?
    private var acquired = 0
    private var blockedSamples = 0
    #endif
    private init(window: UIWindow) {
        self.window = window
        blocker.backgroundColor = .clear
        blocker.isAccessibilityElement = true
        blocker.accessibilityLabel = "正在切换"
        blocker.accessibilityViewIsModal = true
        blocker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    static func acquire(in window: UIWindow, source: NavigationTrace.Owner,
                        hitTarget: ((CGPoint, UIEvent?) -> UIView?)? = nil) -> Lease {
        let shield: PageInteractionShield
        if let current = objc_getAssociatedObject(window, &windowKey) as? PageInteractionShield { shield = current }
        else {
            shield = PageInteractionShield(window: window)
            objc_setAssociatedObject(window, &windowKey, shield, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let id = UUID(); shield.owners.insert(id)
        if let hitTarget { shield.hitTargets[id] = hitTarget }
        if NavigationDiagnostics.enabled {
            shield.diagnosticOwners[id] = source
            NavigationDiagnostics.mark(.leaseAcquired, owner: source, locks: shield.owners.count)
        }
        shield.updateHitTarget()
        shield.blocker.frame = window.bounds
        window.addSubview(shield.blocker)
        #if DEBUG && targetEnvironment(simulator)
        shield.acquired += 1
        if blocksNewTouches(in: window) { shield.blockedSamples += 1 }
        shield.updateReadback()
        #endif
        return Lease(owner: shield, id: id)
    }
    static func isActive(in window: UIWindow) -> Bool {
        guard let shield = objc_getAssociatedObject(window, &windowKey) as? PageInteractionShield else { return false }
        return !shield.owners.isEmpty
    }

    static func blocksNewTouches(in window: UIWindow) -> Bool {
        guard let shield = objc_getAssociatedObject(window, &windowKey) as? PageInteractionShield,
              !shield.owners.isEmpty else { return false }
        return window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: nil) === shield.blocker
    }
    private func release(_ id: UUID) {
        owners.remove(id)
        hitTargets.removeValue(forKey: id)
        if NavigationDiagnostics.enabled, let source = diagnosticOwners.removeValue(forKey: id) {
            NavigationDiagnostics.mark(.leaseReleased, owner: source, locks: owners.count)
        }
        if owners.isEmpty {
            blocker.hitTarget = nil
            blocker.removeFromSuperview()
        } else {
            updateHitTarget()
        }
        #if DEBUG && targetEnvironment(simulator)
        updateReadback()
        #endif
    }

    private func updateHitTarget() {
        guard owners.count == 1, let id = owners.first else {
            blocker.hitTarget = nil
            return
        }
        blocker.hitTarget = hitTargets[id]
    }
    static func diagnosticTarget(for view: UIView?, in window: UIWindow) -> (hit: Bool, locks: Int, owner: NavigationTrace.Owner?) {
        guard let shield = objc_getAssociatedObject(window, &windowKey) as? PageInteractionShield else {
            return (false, 0, nil)
        }
        let sources = Set(shield.diagnosticOwners.values)
        return (view === shield.blocker, shield.owners.count, sources.count == 1 ? sources.first : nil)
    }
    #if DEBUG && targetEnvironment(simulator)
    private func updateReadback() {
        guard let window, ProcessInfo.processInfo.arguments.contains("--qa-segment-edge") || ProcessInfo.processInfo.arguments.contains("--qa-header-motion") else { return }
        if readback == nil {
            let label = UILabel(frame: CGRect(x: 0, y: window.bounds.height - 2, width: 1, height: 1))
            label.alpha = 0.01; label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true; label.accessibilityIdentifier = "page.interaction-lock"
            label.autoresizingMask = [.flexibleTopMargin]
            window.addSubview(label); readback = label
        }
        readback?.accessibilityValue = "locks=\(owners.count);acquired=\(acquired);blocked=\(blockedSamples)"
    }
    #endif
}

/// During an edge return the fixed chrome can be represented by a visual copy.
/// Keep its original control host as the touch target. Querying a target is
/// side-effect free; only a delivered contact may interrupt the visual handoff.
@MainActor final class PageReturnTouchObserver: UIView, UIGestureRecognizerDelegate {
    private struct Control {
        weak var drawable: PageControlDrawable?
        let frame: CGRect
        let originalTransform: CGAffineTransform
        var appliedTransform: CGAffineTransform
    }

    private let inputToken = UUID()
    private let observer = UITapGestureRecognizer()
    private var controls: [Control] = []
    var onNewTouch: (() -> Void)?
    var controlsAreCurrent: (() -> Bool)?

    func install(in window: UIWindow) {
        frame = window.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityElementsHidden = true
        observer.delegate = self
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        window.addSubview(self)
        window.addGestureRecognizer(observer)
    }

    func trackControls(of owner: UIViewController, includingSuppressed: Bool = false) {
        guard let window, let source = owner.viewIfLoaded, source.window === window else { return }
        let views = PageBodyViewports.floatingControlViews(in: owner, includePresentationFooter: true,
                                                          includingSuppressed: includingSuppressed)
        var drawables = PageBodyViewports.controlDrawables(for: views)
        if !drawables.contains(where: { $0.kind == .footer }),
           PageBodyViewports.rootFooterEndpoint(in: window, includingSuppressed: includingSuppressed) != nil,
           let footer = PageBodyViewports.rootFooterControl(in: window),
           let view = footer.view, !view.isDescendant(of: source),
           includingSuppressed || PageBodyViewports.fixedBottomBarIsOutside(source) {
            drawables.append(footer)
        }
        let next = drawables.compactMap { drawable -> Control? in
            guard let view = drawable.view else { return nil }
            return Control(drawable: drawable, frame: view.convert(view.bounds, to: window),
                           originalTransform: view.transform, appliedTransform: view.transform)
        }
        guard next.count != controls.count || !zip(next, controls).allSatisfy({
            $0.drawable === $1.drawable && $0.frame == $1.frame
        }) else { return }
        releaseControls()
        controls = next
        for control in controls { control.drawable?.keepInput(inputToken) }
    }

    // The page body moves under fixed chrome. Keep the actual controls at
    // their screen positions so UIKit delivers the same coordinates it tested.
    func pinControls(in source: UIView, bodyOffset: CGFloat) {
        for index in controls.indices {
            let control = controls[index]
            guard let host = control.drawable?.view, host.isDescendant(of: source),
                  host.transform == control.appliedTransform else { continue }
            let pinned = control.originalTransform.concatenating(CGAffineTransform(translationX: -bodyOffset, y: 0))
            host.transform = pinned
            controls[index].appliedTransform = pinned
        }
    }

    func remove() {
        onNewTouch = nil
        controlsAreCurrent = nil
        releaseControls()
        observer.view?.removeGestureRecognizer(observer)
        removeFromSuperview()
    }

    private func releaseControls() {
        for control in controls {
            if let view = control.drawable?.view, view.transform == control.appliedTransform {
                view.transform = control.originalTransform
            }
            control.drawable?.releaseInput(inputToken)
        }
        controls.removeAll()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.phase == .began {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-stale-edge-pan-touch"), let window {
                let point = touch.location(in: window)
                let control = controls.first(where: { $0.frame.contains(point) })?.drawable
                let host = control?.view
                NSLog("RETURN_INPUT point=%@ actual=%@ host=%@ local=%@ visible=%d eligible=%d", NSCoder.string(for: point),
                      touch.view.map { String(describing: type(of: $0)) } ?? "-", host.map { String(describing: type(of: $0)) } ?? "-",
                      NSCoder.string(for: touch.location(in: host)), control?.baseVisible == true ? 1 : 0,
                      controlsAreCurrent?() == true ? 1 : 0)
            }
            #endif
            onNewTouch?()
        }
        return false
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let event, event.type == .touches, let window else { return nil }
        for control in controls where control.frame.contains(point) {
            guard let drawable = control.drawable, drawable.baseVisible, let host = drawable.view,
                  host.window === window, host.bounds.size == control.frame.size else { continue }
            let liveFrame = host.convert(host.bounds, to: window)
            if drawable.isDrawable && liveFrame == control.frame { return nil }
            guard controlsAreCurrent?() == true else { return nil }
            let local = CGPoint(x: point.x - control.frame.minX + host.bounds.minX,
                                y: point.y - control.frame.minY + host.bounds.minY)
            return host.hitTest(local, with: event)
        }
        return nil
    }
}

/// Track the physical touch independently of the pan's target-action and reset callbacks.
class PageMotionPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var resetGeneration = 0
    var onReset: (() -> Void)?
    var onTouchSequenceFinished: (() -> Void)?
    private weak var trackedTouch: UITouch?
    private var touchGeneration = 0
    private var trackingTouch = false
    private var touchWatch: Task<Void, Never>?
    #if DEBUG && targetEnvironment(simulator)
    var dropTouchTerminalForQA = false
    var keepTouchAliveForQA = false
    private(set) var touchWatchRecoveredForQA = false
    #endif

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackingTouch, !hasLiveTouch { finishTouchSequence() }
        if !trackingTouch, let touch = touches.first {
            touchGeneration &+= 1
            trackedTouch = touch
            trackingTouch = true
            #if DEBUG && targetEnvironment(simulator)
            dropTouchTerminalForQA = false
            keepTouchAliveForQA = false
            touchWatchRecoveredForQA = false
            #endif
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let generation = terminalGeneration(for: touches)
        super.touchesEnded(touches, with: event)
        if generation == touchGeneration { finishTouchSequence() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let generation = terminalGeneration(for: touches)
        super.touchesCancelled(touches, with: event)
        if generation == touchGeneration { finishTouchSequence() }
    }

    /// Only a drag that owns a transition needs a liveness check. A stationary
    /// finger is still live, and no display frame is required to end the watch.
    func watchTouchSequence() {
        guard trackingTouch, touchWatch == nil else { return }
        let generation = touchGeneration
        touchWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard let self, self.touchGeneration == generation, self.trackingTouch else { return }
                if !self.hasLiveTouch {
                    #if DEBUG && targetEnvironment(simulator)
                    self.touchWatchRecoveredForQA = true
                    #endif
                    self.finishTouchSequence()
                    return
                }
            }
        }
    }

    func stopWatchingTouchSequence() {
        touchWatch?.cancel()
        touchWatch = nil
    }

    func discardTrackedTouchSequence() {
        trackingTouch = false
        trackedTouch = nil
        stopWatchingTouchSequence()
        #if DEBUG && targetEnvironment(simulator)
        dropTouchTerminalForQA = false
        keepTouchAliveForQA = false
        #endif
    }

    private var hasLiveTouch: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if keepTouchAliveForQA { return true }
        #endif
        guard let trackedTouch else { return false }
        return trackedTouch.phase != .ended && trackedTouch.phase != .cancelled
    }

    private func terminalGeneration(for touches: Set<UITouch>) -> Int? {
        guard trackingTouch, let trackedTouch, touches.contains(trackedTouch) else { return nil }
        #if DEBUG && targetEnvironment(simulator)
        guard !dropTouchTerminalForQA else { return nil }
        #endif
        return touchGeneration
    }

    private func finishTouchSequence() {
        guard trackingTouch else { return }
        discardTrackedTouchSequence()
        onTouchSequenceFinished?()
    }

    override func reset() {
        super.reset()
        recordReset()
    }

    private func recordReset() {
        resetGeneration &+= 1
        onReset?()
    }

    #if DEBUG && targetEnvironment(simulator)
    func simulateResetNotificationForQA() { recordReset() }
    #endif
}

extension PageTransitionInput {
    @discardableResult
    func acquire(in window: UIWindow, source: NavigationTrace.Owner,
                 hitTarget: ((CGPoint, UIEvent?) -> UIView?)? = nil) -> Bool {
        acquire {
            let lease = PageInteractionShield.acquire(in: window, source: source, hitTarget: hitTarget)
            return { lease.release() }
        }
    }
}
