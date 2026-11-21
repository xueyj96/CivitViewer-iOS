import Foundation

enum ViewingOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight

    var toggled: ViewingOrientation { self == .portrait ? .landscapeRight : .portrait }
}

enum ViewingOrientationMask: Equatable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
    case allButUpsideDown
}

struct ViewingOrientationPolicy: Equatable, Sendable {
    private(set) var automatic: Bool
    private(set) var lockedOrientation: ViewingOrientation = .portrait

    init(automatic: Bool = false) { self.automatic = automatic }

    var supportedMask: ViewingOrientationMask {
        if automatic { return .allButUpsideDown }
        switch lockedOrientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }

    mutating func setAutomatic(_ enabled: Bool, actual: ViewingOrientation) {
        automatic = enabled
        if !enabled { lockedOrientation = actual }
    }

    mutating func toggle(actual: ViewingOrientation) -> ViewingOrientation {
        let target = actual.toggled
        if !automatic { lockedOrientation = target }
        return target
    }
}

struct ViewingOrientationRequestTracker {
    private(set) var revision = 0
    private var rollbackPolicy: ViewingOrientationPolicy?

    mutating func begin(rollbackOnFailure: ViewingOrientationPolicy? = nil) -> Int {
        revision += 1
        rollbackPolicy = rollbackOnFailure
        return revision
    }

    mutating func reject(_ request: Int, policy: inout ViewingOrientationPolicy) -> Bool {
        guard request == revision else { return false }
        if let rollbackPolicy { policy = rollbackPolicy }
        self.rollbackPolicy = nil
        return true
    }
}

final class ViewingOrientationSettings {
    static let storageKey = "civitviewer.automaticRotation"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var automatic: Bool {
        get { defaults.object(forKey: Self.storageKey) == nil || defaults.bool(forKey: Self.storageKey) }
        set { defaults.set(newValue, forKey: Self.storageKey) }
    }
}

#if canImport(UIKit)
import UIKit
import Combine

struct PlaybackOrientationSession {
    private var opening: ViewingOrientation?
    private weak var openingScene: UIWindowScene?

    @MainActor mutating func rotate() {
        let controller = ViewingOrientationController.shared
        let scene = controller.playbackScene
        let previous = controller.toggleOrientation()
        if opening == nil, previous != nil { opening = previous; openingScene = scene }
    }

    @MainActor mutating func restore() {
        takeRestoreAction()?()
    }

    @MainActor mutating func takeRestoreAction() -> (() -> Void)? {
        guard let opening else { return nil }
        self.opening = nil
        let scene = openingScene
        openingScene = nil
        return { [weak scene] in
            guard let scene else { return }
            ViewingOrientationController.shared.restorePlaybackOrientation(opening, in: scene)
        }
    }
}

@MainActor final class ViewingOrientationController: ObservableObject {
    static let shared = ViewingOrientationController()

    @Published private(set) var automatic: Bool
    @Published private(set) var message: String?
    private let settings: ViewingOrientationSettings
    private var policy: ViewingOrientationPolicy
    private var geometryRequests = ViewingOrientationRequestTracker()
    private struct DeferredRestore {
        weak var scene: UIWindowScene?
        let orientation: ViewingOrientation
    }
    private var deferredRestores: [ObjectIdentifier: DeferredRestore] = [:]
    private var sceneActivationObserver: NSObjectProtocol?

    var playbackScene: UIWindowScene? { activeScene() }

    var supportedOrientations: UIInterfaceOrientationMask {
        switch policy.supportedMask {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .allButUpsideDown: .allButUpsideDown
        }
    }

    init(settings: ViewingOrientationSettings = ViewingOrientationSettings()) {
        self.settings = settings
        let value = settings.automatic
        self.automatic = value
        self.policy = ViewingOrientationPolicy(automatic: value)
        sceneActivationObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let scene = notification.object as? UIWindowScene else { return }
            Task { @MainActor [weak self, weak scene] in
                guard let self, let scene else { return }
                self.resumeDeferredRestore(in: scene)
            }
        }
    }

    func setAutomatic(_ enabled: Bool) {
        guard automatic != enabled else { return }
        automatic = enabled
        settings.automatic = enabled
        deferredRestores.removeAll()
        policy.setAutomatic(enabled, actual: currentOrientation() ?? policy.lockedOrientation)
        message = nil
        applyPolicy(requestGeometry: !enabled)
    }

    @discardableResult
    func toggleOrientation() -> ViewingOrientation? {
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("orientation.toggle", ["automatic": automatic, "actual": activeScene()?.interfaceOrientation.rawValue ?? -1,
            "windowW": Double(activeScene()?.windows.first(where: \.isKeyWindow)?.bounds.width ?? 0)])
        #endif
        guard let scene = activeScene(), let actual = orientation(scene.interfaceOrientation) else {
            message = "当前无法更改画面方向。"
            return nil
        }
        deferredRestores[ObjectIdentifier(scene)] = nil
        requestOrientation(actual.toggled, from: actual, scene: scene)
        return actual
    }

    func restorePlaybackOrientation(_ entry: ViewingOrientation) {
        guard let scene = activeScene() else { return }
        restorePlaybackOrientation(entry, in: scene)
    }

    func restorePlaybackOrientation(_ entry: ViewingOrientation, in scene: UIWindowScene) {
        deferredRestores = deferredRestores.filter { $0.value.scene != nil }
        guard UIApplication.shared.connectedScenes.contains(scene) else { return }
        guard scene.activationState == .foregroundActive, let actual = orientation(scene.interfaceOrientation) else {
            deferredRestores[ObjectIdentifier(scene)] = DeferredRestore(scene: scene, orientation: entry)
            return
        }
        deferredRestores[ObjectIdentifier(scene)] = nil
        requestOrientation(entry, from: actual, scene: scene)
    }

    private func resumeDeferredRestore(in scene: UIWindowScene) {
        deferredRestores = deferredRestores.filter { $0.value.scene != nil }
        guard let pending = deferredRestores[ObjectIdentifier(scene)], pending.scene === scene else { return }
        restorePlaybackOrientation(pending.orientation, in: scene)
    }

    private func requestOrientation(_ target: ViewingOrientation, from actual: ViewingOrientation, scene: UIWindowScene) {
        var fallback = policy
        fallback.setAutomatic(automatic, actual: actual)
        policy.setAutomatic(automatic, actual: target)
        message = nil
        applyPolicy(requestGeometry: true, sceneOverride: scene, target: target, rollbackOnFailure: fallback)
    }

    func refreshSupportedOrientations() {
        updateControllers()
    }

    private func applyPolicy(requestGeometry: Bool, sceneOverride: UIWindowScene? = nil, target: ViewingOrientation? = nil,
                             rollbackOnFailure: ViewingOrientationPolicy? = nil) {
        let revision = geometryRequests.begin(rollbackOnFailure: requestGeometry ? rollbackOnFailure : nil)
        updateControllers(in: sceneOverride)
        guard requestGeometry else { return }
        guard let scene = sceneOverride ?? activeScene() else {
            finishGeometryRequest(revision: revision, message: "当前无法更改画面方向。")
            return
        }
        guard #available(iOS 16.0, *) else {
            finishGeometryRequest(revision: revision, message: "当前系统暂不支持更改画面方向。")
            return
        }
        let mask: UIInterfaceOrientationMask
        if let target {
            switch target {
            case .portrait: mask = .portrait
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            }
        } else {
            mask = supportedOrientations
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
            Task { @MainActor in
                self?.finishGeometryRequest(revision: revision, message: "系统未接受画面方向请求；设备旋转锁定设置保持不变。")
            }
        }
    }

    private func finishGeometryRequest(revision: Int, message: String) {
        #if DEBUG && targetEnvironment(simulator)
        PagerGestureTraceQA.lifecycle("orientation.rejected", ["revision": revision, "automatic": automatic])
        #endif
        guard geometryRequests.reject(revision, policy: &policy) else { return }
        updateControllers()
        self.message = message
    }

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }
    }

    private func currentOrientation() -> ViewingOrientation? {
        guard let scene = activeScene() else { return nil }
        return orientation(scene.interfaceOrientation)
    }

    private func orientation(_ value: UIInterfaceOrientation) -> ViewingOrientation? {
        switch value {
        case .portrait, .portraitUpsideDown: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }

    private func updateControllers(in scene: UIWindowScene? = nil) {
        guard let window = (scene ?? activeScene())?.windows.first(where: \.isKeyWindow) else { return }
        func update(_ controller: UIViewController?) {
            guard let controller else { return }
            if #available(iOS 16.0, *) { controller.setNeedsUpdateOfSupportedInterfaceOrientations() }
            update(controller.presentedViewController)
        }
        update(window.rootViewController)
    }
}
#endif
