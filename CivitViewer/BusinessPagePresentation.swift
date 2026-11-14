import SwiftUI
import UIKit

/// Owns the platform lifecycle. Business intent and visual settlement are
/// separate; a callback can close only the session that created it.
private struct PinnedPageCover<Item: Identifiable, Presented: View>: ViewModifier {
    @Binding var item: Item?
    let route: NativeHeaderRoute
    let requestIdentity: AnyHashable?
    let destinationRole: PageCanvasRole
    let sourceRole: PageCanvasRole?
    let animateDismissal: Bool
    let onBegin: (Item, UUID) -> Void
    let onEnd: (Item, UUID) -> Void
    let presented: (Item, UUID, @escaping () -> Bool) -> Presented
    @State private var lifecycle = PresentationLifecycle<Item>(ownerInitiallyActive: false)
    @State private var cleanup = PagePresentationCleanup()
    @State private var bodyHandoff = PageBodyHandoff()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageSurfaceTone) private var inheritedTone
    @Environment(\.pageCanvasRole) private var inheritedRole
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: SiteSession

    func body(content: Content) -> some View {
        let callbackReceipt = cleanup.callbackReceipt
        content
            .nativeHeaderRouteBoundary(route, isPresented: false,
                                       onLayout: {
                                           if lifecycle.requiresMountRecovery {
                                               DispatchQueue.main.async { reconcile() }
                                           }
                                       },
                                       onAttach: {
                                           lifecycle.attachOwner($0)
                                           tracePresentation("source-attach")
                                           reconcile()
                                       }, onDetach: sourceRemoved)
            .background {
                Color.clear.fullScreenCover(item: platformPresentation, onDismiss: { [cleanup, callbackReceipt] in
                    // This is the platform receipt. The mounted slot survives
                    // probe teardown and cannot be replaced by a newer request.
                    if let callbackReceipt {
                        // A late actual receipt can update its own history even
                        // after recovery, but cannot consume a newer session.
                        callbackReceipt.recordNavigation(.committed)
                    }
                    if let callbackReceipt, let receipt = cleanup.platformDismissed(callbackReceipt.id) {
                        finish(receipt.id, platformWasMounted: true)
                        reconcile()
                    }
                }) { session in
                    presented(item?.id == session.item.id ? (item ?? session.item) : session.item,
                              session.id, { mayClose(session.id) })
                        .environment(\.pageCanvasRole, destinationRole)
                        .environment(\.pageReturnNavigationReceipt, cleanup.receipt(for: session.id))
                        .nativeHeaderRouteBoundary(route, isPresented: true,
                                                   onAppear: { appeared(session.id) },
                                                   onLayout: { if lifecycle.session?.id == session.id { bodyHandoff.keepVisible() } })
                }
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
            .environment(\.pageSurfaceTone, bodyHandoff.tone ?? inheritedTone)
            .onChange(of: item.map { requestIdentity ?? AnyHashable($0.id) }, initial: true) { _, _ in
                lifecycle.requestChanged()
                reconcile()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                lifecycle.setSceneActive(phase == .active)
                if phase == .active { reconcile() } else { bodyHandoff.cancel() }
            }
            .onChange(of: session.accountSessionID) { _, _ in bodyHandoff.cancel() }
    }

    private var platformPresentation: Binding<PresentationLifecycle<Item>.Session?> {
        let expectedToken = lifecycle.session?.id
        return Binding(get: {
            guard lifecycle.session?.id == expectedToken else { return nil }
            return lifecycle.platformSession
        }, set: { value in
            if value == nil, let expectedToken { close(expectedToken) }
        })
    }

    private func reconcile() {
        guard lifecycle.ownerActive, lifecycle.sceneActive else { return }
        if let active = lifecycle.session, lifecycle.requiresMountRecovery,
           lifecycle.canRecoverUnmountedMount(active.id, platformIsAbsent: platformPresentationIsAbsent) {
            finish(active.id, platformWasMounted: false)
            return
        }
        if lifecycle.phase == .idle, !cleanup.awaitingPlatformReceipt, let item, let session = lifecycle.prepare(item) {
            tracePresentation("prepare")
            cleanup.begin(session.id)
            onBegin(item, session.id)
            // Cancellation before this platform commit finishes locally; it
            // must not wait for a UIKit onDismiss that can never arrive.
            DispatchQueue.main.async {
                guard lifecycle.session?.id == session.id else { return }
                guard lifecycle.ownerActive, lifecycle.sceneActive, itemStillRequested(session) else { finish(session.id, platformWasMounted: false); return }
                bodyHandoff.prepare(session.id, source: route.sourcePageController, kind: "entry",
                                    enabled: !reduceMotion, fallback: canvasFallback,
                                    sourceScheme: (sourceRole ?? inheritedRole) == .playback ? .dark : ordinaryScheme,
                                    sourceIsMedia: (sourceRole ?? inheritedRole) == .playback)
                route.preparePresentation(tone: bodyHandoff.tone)
                withoutPageAnimation {
                    if lifecycle.commitMount(session.id) { cleanup.requested(session.id) }
                }
            }
        } else if let session = lifecycle.session, !itemStillRequested(session) {
            close(session.id)
        }
    }

    private func sourceRemoved(_ token: UUID) {
        tracePresentation("source-detach")
        guard lifecycle.detachOwner(token) else { return }
        bodyHandoff.cancel()
        guard let active = lifecycle.session else { return }
        cleanup.receipt(for: active.id)?.abortVisual(reason: "presentation-owner-removed")
        // Keep the request terminable until actual appearance, dismissal, or a
        // reattached live presenter proves that UIKit has no such presentation.
        if lifecycle.phase == .mounting { return }
        finish(active.id, platformWasMounted: lifecycle.phase != .preparing)
    }

    private var platformPresentationIsAbsent: Bool {
        guard let source = route.sourcePageController, let view = source.viewIfLoaded,
              let window = view.window, window.windowScene?.activationState == .foregroundActive,
              view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var destination = route.destinationPageController
        while let current = destination {
            if current.viewIfLoaded?.window != nil || current.presentingViewController != nil
                || current.isBeingPresented || current.isBeingDismissed || current.transitionCoordinator != nil { return false }
            destination = current.parent
        }
        var presenter: UIViewController? = source
        while let current = presenter {
            if current.presentedViewController != nil || current.isBeingPresented
                || current.isBeingDismissed || current.transitionCoordinator != nil { return false }
            if current.parent == nil { return current.viewIfLoaded?.window === window }
            presenter = current.parent
        }
        return false
    }

    private func itemStillRequested(_ session: PresentationLifecycle<Item>.Session) -> Bool {
        item?.id == session.item.id && lifecycle.requestRevision == session.requestRevision
    }

    private func mayClose(_ token: UUID) -> Bool {
        guard let session = lifecycle.session, session.id == token else { return false }
        return itemStillRequested(session) && (lifecycle.phase == .visible || lifecycle.phase == .mounting)
    }

    private func appeared(_ token: UUID) {
        guard lifecycle.session?.id == token, lifecycle.phase == .mounting else { return }
        cleanup.mounted(token)
        let closeAfterMount = lifecycle.appeared(token)
        route.appeared()
        if closeAfterMount { close(token, preserveEntryBody: true) }
        else { bodyHandoff.reveal(token, destination: route.destinationPageController) }
    }

    private var canvasFallback: UIColor {
        if destinationRole == .playback { return .black }
        return UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: ordinaryScheme == .dark ? .dark : .light))
    }

    private func close(_ token: UUID, preserveEntryBody: Bool = false) {
        guard lifecycle.session?.id == token else { return }
        if lifecycle.phase == .preparing { finish(token, platformWasMounted: false); return }
        let receipt = cleanup.receipt(for: token)
        let policy = cleanup.dismissalPolicy(token, requested: animateDismissal)
        if lifecycle.requestClose(token) {
            if policy, !reduceMotion, receipt?.hasBodyOwner != true {
                if !preserveEntryBody {
                    bodyHandoff.prepare(token, source: route.destinationPageController, kind: "return",
                                        enabled: true, fallback: UIColor.systemBackground.resolvedColor(with: route.sourcePageController?.traitCollection ?? UITraitCollection(userInterfaceStyle: ordinaryScheme == .dark ? .dark : .light)),
                                        sourceScheme: destinationRole == .playback ? .dark : ordinaryScheme,
                                        sourceIsMedia: destinationRole == .playback)
                }
            } else { bodyHandoff.cancel() }
            route.prepareDismissal(animate: policy, tone: bodyHandoff.tone)
        }
    }

    private func finish(_ token: UUID, platformWasMounted: Bool) {
        tracePresentation("finish")
        let edgeOwnsBody = cleanup.receipt(for: token)?.hasBodyOwner == true
        guard let ended = lifecycle.finish(token) else { return }
        if platformWasMounted { route.dismissed(animate: cleanup.dismissalPolicy(token, requested: animateDismissal)) }
        cleanup.finish(token)
        if item?.id == ended.item.id, lifecycle.requestRevision == ended.requestRevision { item = nil }
        onEnd(ended.item, ended.id)
        let finishVisual: () -> Void = {
            DispatchQueue.main.async {
                lifecycle.callbacksFinished(token)
                reconcile() // Re-read pending after all callbacks and visual cleanup.
            }
        }
        if platformWasMounted, !edgeOwnsBody {
            bodyHandoff.reveal(token, destination: route.sourcePageController, completion: { _ in finishVisual() })
        } else {
            bodyHandoff.cancel()
            finishVisual()
        }
    }

    private func tracePresentation(_ event: String) {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") else { return }
        NSLog("PRESENT169 event=%@ session=%@ phase=%@", event,
              lifecycle.session?.id.uuidString ?? "none", String(describing: lifecycle.phase))
        #endif
    }
}

struct BusinessPageSurface<Content: View>: View {
    var fromMedia = false
    let onTab: (MediaTabExit) -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.ordinaryColorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                content()
                    .environment(\.overlaidTabBarHeight, tabs?.height ?? 0)
                    .environment(\.floatingPageSafeInsets, geometry.safeAreaInsets)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
            .ordinaryPresentationAppearance()
            .overlay(alignment: .bottom) {
                if let tabs { tabs.render(false, "business.tabs", nil, nil, { onTab(.init(id: $0, fromMedia: false)) }) }
            }
            .environment(\.exitMediaCoverToTab, onTab)
        }
    }
}

/// A removed authorization/access page must not leave playback suspended.
private final class BusinessPageLease: ObservableObject {
    let id = UUID()
    deinit {
        let id = id
        Task { @MainActor in ViewingChromeController.shared.resume(after: id) }
    }
}

private struct BusinessPageToken: Identifiable { let id = 0 }

private struct BusinessPagePresentation<Item: Identifiable, Presented: View>: ViewModifier {
    @Binding var requested: Item?
    let onDismiss: () -> Void
    let presented: (Item, @escaping () -> Void) -> Presented
    private struct Context { let token: UUID; let wasOverMedia: Bool }
    @State private var context: Context?
    @State private var route = NativeHeaderRoute()
    @StateObject private var lease = BusinessPageLease()
    @State private var exitingToTab = false
    @ObservedObject private var chrome = ViewingChromeController.shared
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var parentExit
    @Environment(\.colorScheme) private var sourceScheme
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .pagePresentation(item: $requested, route: route, animateDismissal: !exitingToTab,
                              onBegin: begin, onEnd: end) { payload, token, mayClose in
                BusinessPageSurface(fromMedia: context?.wasOverMedia == true, onTab: { selectTab($0, token: token, mayClose: mayClose) }) {
                    presented(payload, { close(token, mayClose: mayClose) })
                }
            }
            .onDisappear { if context == nil { chrome.resume(after: lease.id) } }
    }

    private func begin(_ payload: Item, token: UUID) {
        context = Context(token: token, wasOverMedia: sourceScheme == .dark && ordinaryScheme == .light)
        exitingToTab = false
        chrome.suspend(for: lease.id)
    }

    private func close(_ token: UUID, mayClose: () -> Bool) {
        guard context?.token == token, mayClose() else { return }
        withoutPageAnimation {
            requested = nil
        }
    }

    private func selectTab(_ exit: MediaTabExit, token: UUID, mayClose: () -> Bool) {
        guard context?.token == token, mayClose() else { return }
        let select = parentExit ?? tabs?.select
        withoutPageAnimation {
            exitingToTab = true
            chrome.resume(after: lease.id)
            requested = nil
            select?(.init(id: exit.id, fromMedia: false))
        }
    }

    private func end(_ payload: Item, token: UUID) {
        guard context?.token == token else { return }
        context = nil
        chrome.resume(after: lease.id)
        onDismiss()
    }
}

extension View {
    /// Stable item identity permits live payload updates. A new intent for the
    /// same item must supply a fresh requestIdentity (or a UUID request envelope).
    func pagePresentation<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, route: NativeHeaderRoute, requestIdentity: AnyHashable? = nil,
        destinationRole: PageCanvasRole = .ordinary, sourceRole: PageCanvasRole? = nil, animateDismissal: Bool = true,
        onBegin: @escaping (Item, UUID) -> Void = { _, _ in },
        onEnd: @escaping (Item, UUID) -> Void = { _, _ in },
        @ViewBuilder content: @escaping (Item, UUID, @escaping () -> Bool) -> Presented
    ) -> some View {
        modifier(PinnedPageCover(item: item, route: route, requestIdentity: requestIdentity, destinationRole: destinationRole, sourceRole: sourceRole, animateDismissal: animateDismissal,
                                 onBegin: onBegin, onEnd: onEnd, presented: content))
    }

    func pinnedPageCover<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, route: NativeHeaderRoute, destinationRole: PageCanvasRole = .ordinary, sourceRole: PageCanvasRole? = nil,
        animateDismissal: Bool = true, onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping (Item) -> Presented
    ) -> some View {
        pagePresentation(item: item, route: route, destinationRole: destinationRole, sourceRole: sourceRole, animateDismissal: animateDismissal,
                         onEnd: { _, _ in onDismiss() }) { payload, _, _ in content(payload) }
    }

    func businessPage<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item, @escaping () -> Void) -> Presented
    ) -> some View {
        modifier(BusinessPagePresentation(requested: item, onDismiss: onDismiss, presented: content))
    }

    func businessPage<Presented: View>(
        isPresented: Binding<Bool>, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (@escaping () -> Void) -> Presented
    ) -> some View {
        businessPage(item: Binding(
            get: { isPresented.wrappedValue ? BusinessPageToken() : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        ), onDismiss: onDismiss) { _, close in content(close) }
    }
}


extension EnvironmentValues {
    @Entry var requestSignIn: ((Bool) -> Void)? = nil
}

/// A covered player presents login from its own stable navigation owner.
/// Ordinary pages retain the MainTabs login presenter.
private struct PlaybackLoginPresentation: ViewModifier {
    @EnvironmentObject private var session: SiteSession
    @State private var shown = false
    @State private var includesCollections = false

    func body(content: Content) -> some View {
        content
            .businessPage(isPresented: $shown, onDismiss: { session.oauth.cancel() }) { close in
                LoginView(forCollections: includesCollections, onClose: close)
            }
            .environment(\.requestSignIn, { collections in
                includesCollections = collections || session.oauth.hasCollectionAccess
                shown = true
            })
    }
}

extension View {
    func playbackLoginPage() -> some View { modifier(PlaybackLoginPresentation()) }
}
