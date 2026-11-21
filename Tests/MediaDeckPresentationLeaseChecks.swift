import Foundation
import Observation
import Combine

@MainActor final class VideoPlaybackSessions {
    static let shared = VideoPlaybackSessions()
    var retirements: [UUID: Int] = [:]
    func retireOwner(_ owner: UUID) { retirements[owner, default: 0] += 1 }
}

// INSERT_CHROME
// INSERT_LEASE

@main struct PresentationLeaseChecks {
    @MainActor static func main() {
        let chrome = ViewingChromeController.shared
        let pool = VideoPlaybackSessions.shared
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); count += 1
        }
        let session = MediaDeckPresentationLease(externallyOwned: true)
        session.syncChrome(visible: true, inline: false)
        chrome.toggle(session.chrome)
        check(chrome.hidden, "Session chrome can hide")
        session.viewDetached(covered: false, retainedRoot: false)
        check(chrome.hidden && chrome.activeScope == session.chrome, "Render detachment must preserve session chrome")
        check(pool.retirements[session.chrome] == nil, "Leaf cannot retire session resources")
        session.syncChrome(visible: false, inline: false)
        check(chrome.activeScope == session.chrome, "History disappearance is not session completion")
        session.syncChrome(visible: true, inline: false)
        check(chrome.hidden, "Reattachment must not reset hidden state")
        chrome.suspend(for: session.details)
        session.finish()
        check(session.finished && !chrome.isSuspended, "Finish is terminal and releases its overlay")
        check(chrome.activeScope == nil && !chrome.showsRail(for: session.chrome), "Finish unregisters the session")
        check(pool.retirements[session.chrome] == 1, "Finish retires its player owner")
        session.syncChrome(visible: true, inline: false)
        check(chrome.activeScope == nil, "Late attachment cannot revive a finished scope")
        session.finish()
        check(pool.retirements[session.chrome] == 1, "Explicit finish is idempotent")

        let standalone = MediaDeckPresentationLease()
        standalone.syncChrome(visible: true, inline: true)
        check(chrome.hasInlinePlayer, "Standalone inline keeps its theme")
        standalone.viewDetached(covered: false, retainedRoot: false)
        check(!chrome.hasInlinePlayer && pool.retirements[standalone.chrome] == 1, "Standalone disappearance retains prior cleanup")
        standalone.syncChrome(visible: true, inline: true)
        check(chrome.activeScope == standalone.chrome, "Retained standalone root may reappear")
        standalone.viewDetached(covered: true, retainedRoot: false)
        check(pool.retirements[standalone.chrome] == 1, "A covered standalone player is not retired")
        let root = MediaDeckPresentationLease()
        root.syncChrome(visible: true, inline: true)
        root.viewDetached(covered: false, retainedRoot: true)
        check(pool.retirements[root.chrome] == nil, "Root-paused entries keep their existing ownership")
        print("MediaDeckPresentationLeaseChecks: \(count) passed")
    }
}
