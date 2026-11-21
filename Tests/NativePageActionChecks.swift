import Foundation

struct HistoryContext: Equatable { let ownerKey: String; let generation: Int }
enum MediaEdgeRegion { case upper, lower }
enum MediaPanPhase { case began, changed, ended, cancelled, interrupted }
struct MediaTabExit { let id: Int; let fromMedia: Bool }
// INSERT_ACTION
// INSERT_SOURCE
// INSERT_EDGE_OWNER

@MainActor final class ActionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async { if opened { return }; await withCheckedContinuation { continuation = $0 } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
@MainActor final class ActionHarness {
    // INSERT_KEY
    struct Host { let sourceToken: UUID }
    struct Configuration {
        var queueRevision = 7
        var actionContext = "owner42:7"
        var actionHistoryContext: HistoryContext? = HistoryContext(ownerKey: "42", generation: 3)
        var ids = [1, 2, 3]
        var isVisible = true
        var boundaryWaiting = false
        var focused: Int? = 1
        var onPageAction: (NativeMediaPageAction) -> Void = { _ in }
    }
    var configuration = Configuration()
    var latestConfiguration: Configuration? = Configuration()
    var ids = [1, 2, 3]
    var hosts: [PageKey: Host] = [:]
    var isVisible = true
    var currentID: Int? = 1
    var transition: Int?
    var edgeDrag: NativeMediaEdgeDrag?
    // INSERT_FACTORY
    // INSERT_DISPATCH
    // INSERT_ACCEPT_SOURCE
    // INSERT_CANCEL_EDGE
}

@main struct NativePageActionChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let history = HistoryContext(ownerKey: "42", generation: 3)
        let source = NativeMediaPageSource(id: 1, revision: 7, context: "owner42:7", hostToken: UUID(), historyContext: history)
        let item = MediaItem(id: 1, url: "https://example.invalid/a", width: nil, height: nil, type: "image", username: "a", browsingLevel: 1, thumbnail: nil)
        let other = MediaItem(id: 2, url: "https://example.invalid/b", width: nil, height: nil, type: "image", username: "b", browsingLevel: 1, thumbnail: nil)
        let creator = CreatorRoute(creator: Creator(id: 10, username: "a"), item: item)
        let actions: [NativeMediaPageAction] = [.toggleChrome, .rotate, .edgeSwipe(1, .upper), .edgeDrag(0.3, .changed, .lower), .author(creator), .details(item), .favorite(item), .unavailable(1), .prepared, .exposure(item, history), .end, .recover, .revealControls, .exitTab(MediaTabExit(id: 2, fromMedia: true)), .signIn(false)]
        var delivered = 0
        func harness() -> ActionHarness {
            let value = ActionHarness()
            value.hosts[.init(id: 1, revision: 7)] = .init(sourceToken: source.hostToken)
            value.latestConfiguration?.onPageAction = { _ in delivered += 1 }
            return value
        }
        let live = harness(), callback = live.pageAction(from: source)
        actions.forEach(callback)
        check(delivered == actions.count, "The valid visible current page can dispatch every supported action")
        var newest = 0
        live.latestConfiguration?.onPageAction = { _ in newest += 1 }
        callback(.toggleChrome)
        check(newest == 1 && delivered == actions.count, "A retained source invokes the latest handler without rebuilding its root")

        let invalidations: [(ActionHarness) -> Void] = [
            { $0.latestConfiguration?.queueRevision = 8 }, { $0.configuration.queueRevision = 8 },
            { $0.latestConfiguration?.actionContext = "owner43:7" }, { $0.configuration.actionContext = "owner43:7" },
            { $0.latestConfiguration?.ids = [2, 3] }, { $0.ids = [2, 3] },
            { $0.hosts.removeAll() }, { $0.hosts[.init(id: 1, revision: 7)] = .init(sourceToken: UUID()) },
            { $0.latestConfiguration?.isVisible = false }, { $0.isVisible = false },
            { $0.latestConfiguration?.focused = 2 },
            { $0.currentID = 2 }, { $0.latestConfiguration = nil }
        ]
        for invalidate in invalidations {
            let target = harness(), stale = target.pageAction(from: source), before = delivered
            invalidate(target); actions.forEach(stale)
            check(delivered == before, "A stale revision, context, host, focus, hidden or dismantled source cannot act")
        }
        let waiting = harness(), waitingReceipt = waiting.pageAction(from: source), beforeWaiting = delivered
        waiting.latestConfiguration?.boundaryWaiting = true
        actions.forEach(waitingReceipt)
        check(delivered == beforeWaiting + 2, "Only current-host navigation edges can pass while the next work is pending")
        waiting.latestConfiguration?.focused = 2
        waitingReceipt(.edgeDrag(80, .ended, .upper))
        check(delivered == beforeWaiting + 3, "An arriving work may change logical focus before the displayed host completes its edge drag")
        waiting.transition = 1
        waitingReceipt(.edgeSwipe(1, .upper))
        check(delivered == beforeWaiting + 3, "A vertical settlement still owns the input viewport")
        waiting.transition = nil
        waiting.currentID = 2
        waitingReceipt(.edgeSwipe(1, .upper))
        check(delivered == beforeWaiting + 3, "A parked host cannot navigate even while a result is waiting")

        let departing = harness(), departedReceipt = departing.pageAction(from: source)
        var cancelledEdges = 0, completedEdges = 0, staleCommits = 0
        departing.latestConfiguration?.onPageAction = { action in
            switch action {
            case .edgeDrag(_, .cancelled, _): cancelledEdges += 1
            case .edgeDrag(_, .ended, _): completedEdges += 1
            default: break
            }
        }
        departing.latestConfiguration?.boundaryWaiting = true
        departedReceipt(.edgeDrag(30, .changed, .lower))
        departing.latestConfiguration?.ids = [2, 3]
        departing.latestConfiguration?.onPageAction = { _ in staleCommits += 1 }
        departedReceipt(.edgeDrag(120, .ended, .lower))
        departedReceipt(.edgeDrag(0, .cancelled, .lower))
        departedReceipt(.edgeSwipe(1, .lower))
        check(cancelledEdges == 1 && completedEdges == 0 && staleCommits == 0,
              "Removing a waiting page cancels its accepted edge exactly once with the original owner and cannot complete stale navigation")

        let recovering = harness(), recoveringReceipt = recovering.pageAction(from: source)
        var interruptedEdges = 0
        recovering.latestConfiguration?.onPageAction = { action in
            if case .edgeDrag(_, .interrupted, _) = action { interruptedEdges += 1 }
        }
        recoveringReceipt(.edgeDrag(0, .interrupted, .upper))
        check(interruptedEdges == 0, "An interruption without an accepted edge cannot cancel another owner")
        recoveringReceipt(.edgeDrag(30, .changed, .upper))
        recoveringReceipt(.edgeDrag(0, .interrupted, .upper))
        recoveringReceipt(.edgeDrag(0, .interrupted, .upper))
        check(interruptedEdges == 1, "The accepted edge receives a single interrupted terminal phase")

        let wrongPayload = harness(), wrong = wrongPayload.pageAction(from: source), beforeWrong = delivered
        wrong(.details(other)); wrong(.favorite(other)); wrong(.unavailable(2)); wrong(.exposure(other, history))
        wrong(.exposure(item, HistoryContext(ownerKey: "42", generation: 4)))
        wrongPayload.latestConfiguration?.actionHistoryContext = HistoryContext(ownerKey: "42", generation: 4)
        wrong(.exposure(item, history))
        check(delivered == beforeWrong, "Payload identity and exposure owner/generation must match both source and current context")

        let dragging = harness(), dragReceipt = dragging.pageAction(from: source), dragGate = ActionGate(), dragStarted = ActionGate(), beforeDrag = delivered
        let exposureTimer = Task {
            dragStarted.open(); await dragGate.wait()
            dragReceipt(.exposure(item, history)); dragReceipt(.author(creator)); dragReceipt(.prepared)
        }
        await dragStarted.wait()
        dragging.transition = 1
        dragGate.open(); await exposureTimer.value
        check(delivered == beforeDrag + 1, "A qualified current-page exposure survives a pending vertical drag while author/preparation stay blocked")
        dragging.latestConfiguration?.actionContext = "owner43:7"
        dragReceipt(.exposure(item, history))
        check(delivered == beforeDrag + 1, "A pending drag does not relax source/context validation for exposure")

        for cancelTask in [false, true] {
            let target = harness(), late = target.pageAction(from: source), gate = ActionGate(), started = ActionGate(), before = delivered
            let receipt = Task { started.open(); await gate.wait(); late(.prepared); late(.details(item)); late(.exposure(item, history)) }
            await started.wait()
            if cancelTask { receipt.cancel() } else { target.latestConfiguration = nil }
            gate.open(); await receipt.value
            check(delivered == before, "A genuinely delayed source receipt after cancellation or dismantling is rejected")
        }
        var owner: ActionHarness? = harness()
        weak var weakOwner = owner
        let released = owner!.pageAction(from: source); owner = nil
        released(.toggleChrome)
        check(weakOwner == nil, "Retained source callbacks do not retain their coordinator")
        weakOwner = nil
        print("NativePageActionChecks: \(checks) regression checks passed")
    }
}
