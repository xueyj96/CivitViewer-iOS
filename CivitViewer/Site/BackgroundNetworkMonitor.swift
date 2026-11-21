import Combine
import Network

struct BackgroundNetworkState: Equatable, Sendable {
    let connected: Bool
    let unmetered: Bool

    static let offline = Self(connected: false, unmetered: false)

    func allowsSync(wifiOnly: Bool) -> Bool {
        connected && (!wifiOnly || unmetered)
    }
}

@MainActor final class BackgroundNetworkMonitor {
    static let shared = BackgroundNetworkMonitor()
    private let monitor = NWPathMonitor()
    private let updates = CurrentValueSubject<BackgroundNetworkState, Never>(.offline)

    var state: BackgroundNetworkState { updates.value }

    private init() {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let localNetwork = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let unmetered = connected && localNetwork && !path.isExpensive && !path.isConstrained
            let state = BackgroundNetworkState(connected: connected, unmetered: unmetered)
            Task { @MainActor in
                self?.updates.send(state)
            }
        }
        monitor.start(queue: DispatchQueue(label: "CivitViewer.background-network"))
    }

    func observe(_ receive: @escaping (BackgroundNetworkState) -> Void) -> AnyCancellable {
        updates.removeDuplicates().sink(receiveValue: receive)
    }
}
