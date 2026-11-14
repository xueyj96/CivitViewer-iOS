import SwiftUI

enum TimelinePresentation: String { case stream, grid }

struct TimelineView: View {
    var isVisible = true
    var restartRequest = 0
    var topRequest = 0
    @State private var playbackOrientation = PlaybackOrientationSession()
    @State private var following = false
    @State private var pageMotion = TimelinePageMotion()
    @Environment(\.rootPageParticipation) private var rootParticipation
    @Environment(\.tabPageMotion) private var rootMotion
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: SiteSession
    @State private var recommendationRestart = 0
    @State private var followingRestart = 0
    @State private var recommendationTop = 0
    @State private var followingTop = 0
    @AppStorage("timeline.presentation") private var presentation = TimelinePresentation.stream.rawValue
    private var layout: TimelinePresentation { TimelinePresentation(rawValue: presentation) ?? .stream }
    #if DEBUG && targetEnvironment(simulator)
    private var qaController: ResumePromptQAController?
    init(isVisible: Bool = true, restartRequest: Int = 0, topRequest: Int = 0, qaController: ResumePromptQAController? = nil) {
        self.isVisible = isVisible; self.restartRequest = restartRequest; self.topRequest = topRequest; self.qaController = qaController
    }
    #else
    init(isVisible: Bool = true, restartRequest: Int = 0, topRequest: Int = 0) { self.isVisible = isVisible; self.restartRequest = restartRequest; self.topRequest = topRequest }
    #endif
    var body: some View {
        ZStack(alignment: .top) {
            lane(followed: false, request: recommendationRestart)
                .opacity(following ? 0 : 1).allowsHitTesting(!following).accessibilityHidden(following)
            lane(followed: true, request: followingRestart)
                .opacity(following ? 1 : 0).allowsHitTesting(following).accessibilityHidden(!following)
        }.background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.timelinePageMotion, pageMotion)
            .onAppear { registerRootCanvas() }
            .onChange(of: following) { _, _ in registerRootCanvas() }
            .onChange(of: rootParticipation) { _, _ in registerRootCanvas() }
            .onChange(of: session.feedIdentity) { _, _ in pageMotion.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { pageMotion.stop() } }
            .onDisappear { pageMotion.stop() }
            .environment(\.rotatePlayback, { playbackOrientation.rotate() })
            .onChange(of: isVisible) { _, visible in
                if !visible { pageMotion.stop(); playbackOrientation.restore() }
            }
            .onChange(of: restartRequest) { _, _ in
                if following { followingRestart += 1 } else { recommendationRestart += 1 }
            }
            .onChange(of: topRequest) { _, _ in
                if following { followingTop += 1 } else { recommendationTop += 1 }
            }
    }
    private func registerRootCanvas() {
        let selectedSource = following
        rootMotion?.registerTimelineCanvas(token: rootParticipation.token) { [weak pageMotion] owner in
            pageMotion?.rootTabCanvas(followed: selectedSource, owner: owner)
        }
    }

    @ViewBuilder private func lane(followed: Bool, request: Int) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        TimelineLane(isVisible: isVisible && following == followed, followed: followed, sourceSelection: $following,
                     presentation: layout, togglePresentation: togglePresentation, restoreInlineOrientation: restoreInlinePlaybackOrientation, restartRequest: request,
                     topRequest: followed ? followingTop : recommendationTop, qaController: qaController?.controller(for: followed))
        #else
        TimelineLane(isVisible: isVisible && following == followed, followed: followed, sourceSelection: $following,
                     presentation: layout, togglePresentation: togglePresentation, restoreInlineOrientation: restoreInlinePlaybackOrientation, restartRequest: request,
                     topRequest: followed ? followingTop : recommendationTop)
        #endif
    }
    private func restoreInlinePlaybackOrientation() {
        playbackOrientation.restore()
    }

    private func togglePresentation() {
        if layout == .stream {
            ViewingChromeController.shared.endInlinePlayer()
            restoreInlinePlaybackOrientation()
        }
        presentation = (layout == .stream ? TimelinePresentation.grid : .stream).rawValue
    }
}

