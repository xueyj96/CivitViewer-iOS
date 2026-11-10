import Foundation

@main struct ViewingOrientationChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }

        let suite = "ViewingOrientationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ViewingOrientationSettings(defaults: defaults)
        check(settings.automatic, "An unset orientation preference follows the system")
        settings.automatic = true
        check(ViewingOrientationSettings(defaults: defaults).automatic, "Automatic rotation persists locally")
        settings.automatic = false
        check(!ViewingOrientationSettings(defaults: defaults).automatic, "An explicit rotation lock survives a new settings instance")

        var policy = ViewingOrientationPolicy()
        check(policy.supportedMask == .portrait, "Default locked policy permits portrait")
        let landscape = policy.toggle(actual: .portrait)
        check(landscape == .landscapeRight && policy.supportedMask == .landscapeRight,
              "Manual landscape remains the app mask independent of navigation")
        let portrait = policy.toggle(actual: .landscapeRight)
        check(portrait == .portrait && policy.supportedMask == .portrait && !policy.automatic,
              "Manual portrait does not enable automatic rotation")

        policy.setAutomatic(true, actual: .portrait)
        check(policy.supportedMask == .allButUpsideDown, "System following allows portrait and both landscape sides")
        _ = policy.toggle(actual: .portrait)
        check(policy.automatic && policy.supportedMask == .allButUpsideDown,
              "A manual request under system following does not install an orientation lock")
        policy.setAutomatic(false, actual: .landscapeLeft)
        check(policy.supportedMask == .landscapeLeft, "Turning off system following locks the visible landscape side")
        _ = policy.toggle(actual: .landscapeLeft)
        check(policy.supportedMask == .portrait, "The app can return to portrait from either landscape side")

        var rollbackPolicy = ViewingOrientationPolicy()
        let prior = rollbackPolicy
        var requests = ViewingOrientationRequestTracker()
        let rejectedRequest = requests.begin(rollbackOnFailure: prior)
        _ = rollbackPolicy.toggle(actual: .portrait)
        check(rollbackPolicy.supportedMask == .landscapeRight, "Manual request temporarily applies its requested exact mask")
        check(requests.reject(rejectedRequest, policy: &rollbackPolicy) && rollbackPolicy == prior, "Rejected geometry request restores the previous policy")
        let staleRequest = requests.begin(rollbackOnFailure: prior)
        let newerRequest = requests.begin()
        _ = rollbackPolicy.toggle(actual: .portrait)
        check(!requests.reject(staleRequest, policy: &rollbackPolicy) && rollbackPolicy.supportedMask == .landscapeRight, "Late rejection cannot roll back a newer user orientation request")
        check(requests.reject(newerRequest, policy: &rollbackPolicy), "Current request rejection is accepted by revision tracker")
        var visibleFallback = rollbackPolicy
        visibleFallback.setAutomatic(false, actual: .portrait)
        let retry = requests.begin(rollbackOnFailure: visibleFallback)
        _ = rollbackPolicy.toggle(actual: .portrait)
        check(requests.reject(retry, policy: &rollbackPolicy) && rollbackPolicy.supportedMask == .portrait,
              "A retry rejected before the screen rotates locks the visible orientation")

        print("ViewingOrientationChecks: \(checks) local policy assertions passed")
    }
}
