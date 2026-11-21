import Foundation
import Observation

struct CreatorRoute: Equatable { let id: Int }
@MainActor final class MediaDeckPresentationLease {
    let externallyOwned: Bool
    init(externallyOwned: Bool = false) { self.externallyOwned = externallyOwned }
    var finished = false
    func finish() { finished = true }
}
@MainActor final class NativeHeaderRoute { func dismissed(animate: Bool) {} }
// INSERT_OWNER

@main struct Checks {
    @MainActor static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); count += 1
        }
        let a = UUID(), b = UUID(), mount = UUID(), nextMount = UUID(), author = CreatorRoute(id: 1)
        let owner = PlaybackNavigationOwner(session: a)
        check(owner.playback.externallyOwned, "A platform session owns final resource retirement")
        check(!PlaybackNavigationOwner().playback.externallyOwned, "Standalone fallback keeps its leaf cleanup rules")
        let playerOwner = owner.playback
        owner.attach(mount, for: a)
        owner.setCreator(author, for: a, consumer: mount)
        owner.authorDeparture = true
        check(owner.creator(for: a) == author, "The session owns its author route")
        check(owner.playback === playerOwner, "A session's player ownership is immutable")
        check(owner.authorDeparture, "Covered state belongs to the session")
        let next = PlaybackNavigationOwner(session: b)
        check(next.creator == nil && next.consumer == nil, "New flight starts without an author or consumer")
        check(next.playback !== playerOwner, "New flight receives separate playback ownership")
        check(next.headerRoute !== owner.headerRoute, "Header routes are isolated between flights")
        next.attach(nextMount, for: b)
        next.setCreator(author, for: b, consumer: nextMount)
        next.setCreator(nil, for: a, consumer: mount)
        check(next.creator(for: b) == author, "Late old stack setter cannot clear a new route")
        next.setCreator(CreatorRoute(id: 2), for: a, consumer: mount)
        check(next.creator(for: b) == author, "Old action cannot open a new flight's author")
        next.finish(a)
        check(!next.finished && next.creator == author, "Late old completion cannot end a new flight")
        next.attach(mount, for: b)
        next.setCreator(nil, for: b, consumer: nextMount)
        check(next.creator == author, "Old mount in the same flight cannot pop the replacement stack")
        owner.finish(a)
        check(playerOwner.finished && !next.playback.finished, "Old cleanup cannot retire the new session's player ownership")
        next.finish(b)
        check(next.playback.finished && next.finished && next.creator == nil, "Matching completion retires covered playback and route")
        next.setCreator(author, for: b, consumer: mount)
        next.attach(mount, for: b)
        check(next.creator == nil && !next.accepts(b, consumer: mount), "Finished flight cannot revive its route")
        let standalone = PlaybackNavigationOwner()
        standalone.attach(mount, for: nil)
        standalone.setCreator(author, for: nil, consumer: mount)
        check(standalone.creator(for: nil) == author, "Standalone owner supports a local stack")
        print("PlaybackNavigationOwner: \(count) checks passed")
    }
}
