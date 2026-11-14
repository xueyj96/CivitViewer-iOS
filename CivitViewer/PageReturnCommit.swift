import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var pageReturnNavigationReceipt: PageReturnNavigationReceipt? = nil
}

/// Shared, read-only native-pop adapter. A disappearance is only an observation
/// point: a noncancelled transition AND removal from this exact stack confirm it.
@MainActor
final class PageNativePopReceiptObserver {
    private let ownerID: ObjectIdentifier
    private weak var navigation: UINavigationController?
    private weak var transition: UIViewControllerTransitionCoordinator?
    private var completion: ((PageNavigationOutcome) -> Void)?
    private var waitsForTransition = false

    init?(owner: UIViewController, navigation: UINavigationController,
          completion: @escaping (PageNavigationOutcome) -> Void) {
        guard owner.isMovingFromParent || !navigation.viewControllers.contains(where: { $0 === owner }) else { return nil }
        ownerID = ObjectIdentifier(owner)
        self.navigation = navigation
        self.completion = completion
    }

    func observeTransition(from owner: UIViewController) {
        guard let transition = owner.transitionCoordinator else { return }
        self.transition = transition
        waitsForTransition = transition.animate(alongsideTransition: nil) { [self] context in
            complete(cancelled: context.isCancelled)
        }
    }

    func sourceDisappeared() {
        if !waitsForTransition { complete(cancelled: transition?.isCancelled == true) }
    }

    private func complete(cancelled: Bool) {
        guard let completion else { return }
        self.completion = nil
        let outcome: PageNavigationOutcome
        if cancelled { outcome = .cancelled }
        else if let navigation {
            outcome = navigation.viewControllers.contains(where: { ObjectIdentifier($0) == ownerID })
                ? .aborted("owner-still-in-navigation-stack") : .committed
        } else { outcome = .aborted("navigation-stack-unavailable") }
        completion(outcome)
    }
}

/// Commits local selection drafts only after this navigation owner was popped.
/// Pushing another page, covering it, and cancelling an interactive pop do not commit.
private struct PageReturnCommit: UIViewControllerRepresentable {
    let commit: () -> Void

    func makeUIViewController(context: Context) -> Probe {
        let probe = Probe()
        probe.commit = commit
        probe.view.isUserInteractionEnabled = false
        return probe
    }

    func updateUIViewController(_ probe: Probe, context: Context) { probe.commit = commit }

    final class Probe: UIViewController {
        var commit: () -> Void = {}
        private weak var owner: UIViewController?
        private weak var navigation: UINavigationController?
        private var flight: PageNativePopReceiptObserver?

        override func loadView() { view = UIView(); view.backgroundColor = .clear }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            flight = nil
            resolveOwner()
        }

        private func resolveOwner() {
            guard let navigationController,
                  let owner = navigationController.viewControllers.first(where: {
                      $0.viewIfLoaded.map { view.isDescendant(of: $0) } ?? false
                  }) else { return }
            self.owner = owner
            navigation = navigationController
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if owner == nil { resolveOwner() }
            guard flight == nil, let owner, let navigation,
                  owner.isMovingFromParent || !navigation.viewControllers.contains(where: { $0 === owner }) else { return }
            let ownerID = ObjectIdentifier(owner)
            let commit = commit
            let observer = PageNativePopReceiptObserver(owner: owner, navigation: navigation) { [weak navigation] outcome in
                guard outcome == .committed else { return }
                // Receipt is final; defer only the parent-state write until
                // SwiftUI finishes its own destination-binding bookkeeping.
                DispatchQueue.main.async {
                    guard let navigation,
                          !navigation.viewControllers.contains(where: { ObjectIdentifier($0) == ownerID }) else { return }
                    commit()
                }
            }
            flight = observer
            observer?.observeTransition(from: owner)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            flight?.sourceDisappeared()
        }
    }
}

extension View {
    func commitOnPageReturn(_ commit: @escaping () -> Void) -> some View {
        background { PageReturnCommit(commit: commit).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true) }
    }
}
