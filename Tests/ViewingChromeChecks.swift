import Foundation
import Observation

// INSERT_CONTROLLER

private final class Notifications: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func add() { lock.lock(); storage += 1; lock.unlock() }
}

@main struct ViewingChromeChecks {
    @MainActor static func main() {
        let chrome = ViewingChromeController()
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        let inline = UUID(), full = UUID(), other = UUID(), overlayA = UUID(), overlayB = UUID()
        let rootNotifications = Notifications()
        withObservationTracking { _ = chrome.hasInlinePlayer } onChange: { rootNotifications.add() }
        chrome.begin(full, inline: false)
        check(rootNotifications.count == 0, "full-screen registration must not invalidate root theme")
        chrome.end(full)
        check(rootNotifications.count == 0, "full-screen retirement must not invalidate root theme")
        chrome.begin(inline, inline: true)
        check(chrome.hasInlinePlayer && rootNotifications.count == 1, "inline theme must notify")
        chrome.begin(full, inline: false)
        check(!chrome.hasInlinePlayer && chrome.activeScope == full, "full screen takes foreground")
        chrome.begin(other, inline: false)
        chrome.end(full)
        check(!chrome.hasInlinePlayer && chrome.activeScope == other, "removing covered scope preserves foreground")
        chrome.end(other)
        check(chrome.hasInlinePlayer && chrome.activeScope == inline, "inline owner resumes")

        let hiddenNotifications = Notifications()
        withObservationTracking { _ = chrome.isHidden(for: inline) } onChange: { hiddenNotifications.add() }
        chrome.toggle(inline)
        check(chrome.isHidden(for: inline) && hiddenNotifications.count == 1, "hide must notify leaf")
        chrome.reveal()
        check(!chrome.isHidden(for: inline), "reveal restores controls")
        let railNotifications = Notifications()
        withObservationTracking { _ = chrome.showsRail(for: inline) } onChange: { railNotifications.add() }
        chrome.prepareRailDeparture()
        check(!chrome.showsRail(for: inline) && railNotifications.count == 1, "departure must notify rail")
        chrome.cancelRailDeparture()
        check(chrome.showsRail(for: inline), "cancel restores rail")
        let suspensionNotifications = Notifications()
        withObservationTracking { _ = chrome.isSuspended } onChange: { suspensionNotifications.add() }
        chrome.suspend(for: overlayA)
        check(chrome.isSuspended && suspensionNotifications.count == 1, "overlay must notify suspension")
        chrome.suspend(for: overlayB)
        chrome.resume(after: overlayA)
        check(chrome.activeScope == nil && !chrome.showsRail(for: inline), "overlapping overlay retains suspension")
        check(chrome.hasInlinePlayer, "overlays must not change inline theme projection")
        chrome.resume(after: overlayB)
        check(chrome.activeScope == inline && chrome.showsRail(for: inline), "last overlay restores exact owner")
        let scopeNotifications = Notifications()
        withObservationTracking { _ = chrome.showsRail(for: inline) } onChange: { scopeNotifications.add() }
        chrome.endInlinePlayer()
        check(scopeNotifications.count == 1 && !chrome.showsRail(for: inline), "scope removal must notify rail")
        check(!chrome.hasInlinePlayer && chrome.activeScope == nil, "last inline owner retires")
        print("ViewingChromeChecks: \(checks) passed")
    }
}
