import SwiftUI
import UIKit

// Visual thesis: full-bleed media, quiet native controls, one blue accent.
// Content: mixed timeline, two mature creator boards, creator media, follows, settings.
// Interaction: vertical paging, small filter sheet, native navigation into creators.
@main
struct CivitViewerApp: App {
    @UIApplicationDelegateAdaptor(ViewingAppDelegate.self) private var appDelegate
    @StateObject private var session = SiteSession()
    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            if AppReadback.tagMediaRequested { TagMetadataReadbackView().environmentObject(session) }
            else {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-toast169") { AppToastQAView() }
            else if ProcessInfo.processInfo.arguments.contains("--qa-header-staging161") { HeaderStagingQAView() }
            else if ProcessInfo.processInfo.arguments.contains("--qa-presentation-lifecycle") { PresentationLifecycleQAView().environmentObject(session) }
            else if ProcessInfo.processInfo.arguments.contains("--qa-gesture-scope68") { MediaGestureScopeQAView() }
            else if ProcessInfo.processInfo.arguments.contains("--qa-grid-retry55") { GridRetryQAView() }
            else if ProcessInfo.processInfo.arguments.contains("--qa-preparation48") { VideoPreparationOverlayQAView() }
            else if CollectionPagingQA.enabled { CollectionPagingQAView().environmentObject(session).environmentObject(session.oauth) }
            else if ResumePromptQA.enabled { ResumePromptQAView().environmentObject(session).environmentObject(session.oauth) }
            else if MediaFormatQA.enabled { MediaFormatQAView().environmentObject(session).environmentObject(session.oauth) }
            else if PlaybackLayoutQA.enabled { PlaybackLayoutQAView().environmentObject(session).environmentObject(session.oauth) }
            else { RootView().environmentObject(session).environmentObject(session.oauth) }
            #else
            RootView().environmentObject(session).environmentObject(session.oauth)
            #endif
            }
            #else
            RootView().environmentObject(session).environmentObject(session.oauth)
            #endif
            }.appRootAppearance()
            #if CIVIT_NAVIGATION_DIAGNOSTICS || (DEBUG && targetEnvironment(simulator))
            .background(NavigationDiagnostics.Monitor())
            #endif
        }
    }
}

final class ViewingAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ViewingOrientationController.shared.supportedOrientations
    }
}

struct RootView: View {
    private struct AuthorRefreshKey: Equatable { let identity: String; let ids: [Int] }
    @EnvironmentObject private var session: SiteSession
    @Environment(\.scenePhase) private var scenePhase
    private let offline = OfflineLibrary.shared
    @ObservedObject private var tagLibrary = LocalTagLibrary.shared
    private let history = BrowsingHistory.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @ObservedObject private var orientation = ViewingOrientationController.shared
    @State private var timelineRestartRequest = 0
    @State private var timelineTopRequest = 0
    #if DEBUG
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--qa-history-screen") ? 3 : (ProcessInfo.processInfo.arguments.contains { $0 == "--qa-search-screen" || $0.hasPrefix("--probe-") || $0.hasPrefix("--readback-") } ? 4 : 0)
    #if targetEnvironment(simulator)
    @State private var qaOfflineScreen = ProcessInfo.processInfo.arguments.contains("--qa-offline-screen")
    @State private var qaHistoryScreen = ProcessInfo.processInfo.arguments.contains("--qa-history-screen")
    #endif
    #else
    @State private var selectedTab = RootTab.timeline.rawValue
    #endif
    private var authorRefreshKey: AuthorRefreshKey {
        .init(identity: session.feedIdentity, ids: authorBlocklist.blockedIDs.sorted())
    }
    private var offlineAccount: Int? { session.account?.id ?? session.oauth.storedAccountID }
    private var diagnostics: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--probe-") || $0.hasPrefix("--readback-") || $0 == "--qa-history-screen" }
        #else
        return false
        #endif
    }
    private var tagSyncContext: String { "\(session.tagLibraryIdentity):\(scenePhase == .active)" }
    private func refreshBlockedAuthorNames() async {
        guard session.account != nil else { return }
        let identity = session.feedIdentity
        let ids = authorBlocklist.blockedIDs.sorted()
        guard !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: 30) {
            do {
                try Task.checkCancellation()
                let batch = Array(ids[start..<min(start + 30, ids.count)])
                let creators = try await session.creators(ids: batch)
                guard !Task.isCancelled, identity == session.feedIdentity, session.account != nil else { return }
                let requested = Set(batch)
                authorBlocklist.refreshKnownCreators(creators.filter { requested.contains($0.id) })
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
    var body: some View {
        let timelineTab = RootTab.timeline.rawValue
        MainTabs(selectedTab: $selectedTab,
                 onTimelineTap: { selectedTab = timelineTab; timelineTopRequest &+= 1 },
                 onTimelineDoubleTap: { selectedTab = timelineTab; timelineRestartRequest &+= 1 },
                 timeline: TimelineView(isVisible: selectedTab == timelineTab, restartRequest: timelineRestartRequest, topRequest: timelineTopRequest),
                 authors: LeaderboardView(), search: SearchView(), collections: CollectionsView(),
                 pageContentRevisions: [timelineTab: AnyHashable([selectedTab == timelineTab ? 1 : 0, timelineRestartRequest, timelineTopRequest])])
        #if DEBUG && targetEnvironment(simulator)
        .fullScreenCover(isPresented: $qaOfflineScreen) {
            NavigationStack { OfflineStorageView() }.ordinaryAppearance()
        }
        .fullScreenCover(isPresented: $qaHistoryScreen) {
            NavigationStack { BrowsingHistoryView() }.ordinaryAppearance()
        }
        #endif
        .task {
            await LocalDiagnosticsStore.shared.record(area: .lifecycle, code: .appStarted)
            await session.refreshAccount()
            #if DEBUG
            await AppReadback.runIfRequested(session: session)
            #endif
        }
        .task(id: session.tagLibraryIdentity) {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-history-screen") { await HistoryQA.seed(session: session) }
            #endif
            await history.bind(ownerID: session.tagLibraryOwnerID, identity: session.tagLibraryIdentity)
        }
        .task(id: authorRefreshKey) { await refreshBlockedAuthorNames() }
        .task(id: tagSyncContext) {
            await tagLibrary.bind(ownerID: session.tagLibraryOwnerID)
            tagLibrary.setActive(scenePhase == .active)
            guard scenePhase == .active else { return }
            #if DEBUG
            let diagnostics = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--probe-") || $0.hasPrefix("--readback-") }
            if diagnostics || self.diagnostics { return }
            #endif
            while !Task.isCancelled {
                tagLibrary.requestSync(source: session)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .task(id: session.tagLibraryIdentity) {
            offline.setActive(scenePhase == .active && !diagnostics)
            await offline.bind(accountID: offlineAccount, session: session)
            guard !Task.isCancelled else { return }
            if !diagnostics { offline.requestSync(session: session) }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                if scenePhase == .active && !diagnostics { offline.requestSync(session: session) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            offline.setActive(phase == .active && !diagnostics); tagLibrary.setActive(phase == .active)
            if phase == .active { orientation.refreshSupportedOrientations() }
            if phase == .active || phase == .background {
                Task { await LocalDiagnosticsStore.shared.record(area: .lifecycle, code: phase == .active ? .foreground : .background) }
            }
        }
        .onChange(of: orientation.message) { _, message in
            if let message { session.message = message; Task { await LocalDiagnosticsStore.shared.record(area: .restore, code: .contextChanged) } }
        }
        .onChange(of: session.collectionRevision) { _, _ in offline.requestSync(session: session) }
        .onChange(of: session.savedMembershipUpdate) { _, update in
            if let update { offline.accept(update); offline.requestSync(session: session) }
        }
        .existingFeedbackToast(session.message, global: true, scope: session.feedIdentity, onShown: { message in
            if session.message == message { session.message = nil }
        })
    }
}
