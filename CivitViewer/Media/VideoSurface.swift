import SwiftUI
import AVFoundation
import UIKit

#if DEBUG && targetEnvironment(simulator)
/// A plain trace must not introduce another SwiftUI render while observing seek.
private final class VideoSeekQAEvents {
    var callbacks = 0
    var commits = 0
    var lastFinished: Bool?
}
#endif

private enum VideoStartupPreview: Equatable { case poster, transition }
private enum VideoStartupDisplay: Equatable { case native, nativeBuffering, transition, poster, waiting, neutral }

private enum VideoStartupPolicy {
    static func nativeVisible(layerReady: Bool, itemReady: Bool, resumePending: Bool,
                              wantsPlayback: Bool, nativePlaying: Bool, committed: Bool) -> Bool {
        layerReady && itemReady && !resumePending && (committed || !wantsPlayback || nativePlaying)
    }
    static func pauseVisible(active: Bool, wantsPlayback: Bool, failed: Bool, overlaid: Bool,
                             seeking: Bool, restoring: Bool, hasVisual: Bool) -> Bool {
        active && !wantsPlayback && !failed && !overlaid && !seeking && !restoring && hasVisual
    }
    static func preview(held: VideoStartupPreview?, posterReady: Bool, transitionReady: Bool) -> VideoStartupPreview? {
        if held == .poster, posterReady { return .poster }
        if held == .transition, transitionReady { return .transition }
        if transitionReady { return .transition }
        return posterReady ? .poster : nil
    }
    static func display(nativeVisible: Bool, nativeBuffering: Bool, waiting: Bool,
                        active: Bool, sceneActive: Bool, paused: Bool,
                        selected: VideoStartupPreview?, posterAllowed: Bool, transitionAllowed: Bool,
                        waitRequested: Bool) -> VideoStartupDisplay {
        if nativeVisible { return nativeBuffering && active && sceneActive && !paused ? .nativeBuffering : .native }
        guard waiting else { return .neutral }
        if selected == .transition && transitionAllowed { return .transition }
        if selected == .poster && posterAllowed { return .poster }
        if active && sceneActive && !paused && waitRequested { return .waiting }
        return .neutral
    }
}

private struct VideoLayerReadinessIdentity: Equatable {
    let player: ObjectIdentifier
    let item: ObjectIdentifier
    let attachment: UUID
    let generation: Int
    let source: URL
}

/// A queued layer event belongs to one mount and attachment. Updating the
/// representable may keep its layer while replacing that qualification.
private final class VideoLayerReadinessGate {
    struct Ticket: Equatable {
        let mount: UUID
        let identity: VideoLayerReadinessIdentity
    }
    private(set) var current: Ticket?
    func bind(_ identity: VideoLayerReadinessIdentity) -> Ticket {
        if let current, current.identity == identity { return current }
        let ticket = Ticket(mount: UUID(), identity: identity)
        current = ticket
        return ticket
    }
    func accepts(_ ticket: Ticket) -> Bool { current == ticket }
    func invalidate() { current = nil }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let identity: VideoLayerReadinessIdentity
    let onReadiness: (VideoLayerReadinessIdentity, Bool) -> Void
    final class Coordinator {
        var observation: NSKeyValueObservation?
        let gate = VideoLayerReadinessGate()
        var onReadiness: ((VideoLayerReadinessIdentity, Bool) -> Void)?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        #if DEBUG && targetEnvironment(simulator)
        private let geometryID = UUID()
        private final class GeometryProbe: UIView {
            weak var surface: Surface?
            override var accessibilityValue: String? {
                get { surface?.accessibilityValue }
                set { }
            }
        }
        func enableGeometryReadback() {
            let probe = GeometryProbe(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            probe.surface = self; probe.isUserInteractionEnabled = false
            probe.isAccessibilityElement = true; probe.accessibilityTraits = .staticText
            probe.accessibilityIdentifier = "media.qa.video-geometry"
            probe.accessibilityLabel = "Video layer geometry"
            addSubview(probe)
        }
        override var accessibilityValue: String? {
            get {
                guard ProcessInfo.processInfo.arguments.contains("--qa-chrome-geometry") else { return super.accessibilityValue }
                func rect(_ value: CGRect) -> [String: Double] {
                    ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
                }
                let video = playerLayer.videoRect
                let sourceSize = playerLayer.player?.currentItem?.presentationSize ?? .zero
                let insets = window?.safeAreaInsets ?? .zero
                let transform = self.transform
                let object: [String: Any] = [
                    "surface": geometryID.uuidString,
                    "window": window.map { rect($0.bounds) } ?? [:],
                    "windowSafeArea": ["top": Double(insets.top), "bottom": Double(insets.bottom), "left": Double(insets.left), "right": Double(insets.right)],
                    "surfaceBounds": rect(bounds),
                    "surfaceWindow": window.map { rect(convert(bounds, to: $0)) } ?? [:],
                    "layerBounds": rect(playerLayer.bounds), "layerFrame": rect(playerLayer.frame),
                    "videoRect": rect(video),
                    "presentationSize": ["width": Double(sourceSize.width), "height": Double(sourceSize.height)],
                    "sourceScale": ["x": sourceSize.width > 0 ? Double(video.width / sourceSize.width) : 0,
                                    "y": sourceSize.height > 0 ? Double(video.height / sourceSize.height) : 0],
                    "videoWindow": window.map { rect(convert(video, to: $0)) } ?? [:],
                    "gravity": playerLayer.videoGravity.rawValue,
                    "ready": playerLayer.isReadyForDisplay,
                    "transform": ["a": Double(transform.a), "b": Double(transform.b), "c": Double(transform.c), "d": Double(transform.d), "tx": Double(transform.tx), "ty": Double(transform.ty)]
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            set { super.accessibilityValue = newValue }
        }
        #endif
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.playerLayer.videoGravity = .resizeAspect; view.playerLayer.player = player
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-chrome-geometry") {
            view.enableGeometryReadback()
        }
        #endif
        connect(view, coordinator: context.coordinator)
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        connect(view, coordinator: context.coordinator)
    }
    private func connect(_ view: Surface, coordinator: Coordinator) {
        coordinator.onReadiness = onReadiness
        let previous = coordinator.gate.current
        let ticket = coordinator.gate.bind(identity)
        guard previous != ticket || coordinator.observation == nil else { return }
        coordinator.observation = nil
        coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak coordinator, weak view] _, _ in
            DispatchQueue.main.async {
                guard let coordinator, let view, coordinator.gate.accepts(ticket),
                      let currentPlayer = view.playerLayer.player, ObjectIdentifier(currentPlayer) == ticket.identity.player,
                      let currentItem = currentPlayer.currentItem, ObjectIdentifier(currentItem) == ticket.identity.item else { return }
                coordinator.onReadiness?(ticket.identity, view.playerLayer.isReadyForDisplay)
            }
        }
    }
    static func dismantleUIView(_ view: Surface, coordinator: Coordinator) {
        coordinator.gate.invalidate(); coordinator.onReadiness = nil
        coordinator.observation = nil; view.playerLayer.player = nil
    }
}


struct VideoProgressChrome: View {
    let position: Double
    let duration: Double
    let bufferedRanges: [SeekTimeRange]
    let enabled: Bool
    let showTime: Bool
    let onSeek: (Double, MediaPanPhase) -> Void
    let onInteractionChange: (Bool) -> Void
    var preparationVisible = false
    var preparationProgress: Double? = nil
    var preparationCanCancel = false
    var onPreparationCancel: () -> Void = {}
    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoSeekControl(position: position, duration: duration, bufferedRanges: bufferedRanges, enabled: enabled && !preparationCanCancel,
                             onSeek: onSeek, onInteractionChange: onInteractionChange)
                .frame(height: 44)
                .allowsHitTesting(!preparationCanCancel).zIndex(0)
            if preparationVisible {
                VideoPreparationOverlay(visible: true,
                    progress: preparationProgress, canCancel: preparationCanCancel,
                    onCancel: onPreparationCancel)
                    .zIndex(1)
            }
        }
        .frame(height: 44)
        .overlay(alignment: .top) {
            if showTime && !preparationVisible {
                Text(Self.clock(position))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .modifier(MediaHUDSurface())
                    .offset(y: -10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("media.progress-band")
        #if DEBUG && targetEnvironment(simulator)
        .playbackQAFrame("progress")
        #endif
    }
    static func clock(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--:--" }
        let seconds = Int(min(value, Double(Int.max - 1)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VideoSwipeSeekFeedback: View {
    let target: Double
    let duration: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * 0.62
            let fraction = duration > 0 ? min(1, max(0, target / duration)) : 0
            ZStack {
                Color.black.opacity(0.25)
                VStack(spacing: 4) {
                    Text(VideoProgressChrome.clock(target))
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                    Text("/ " + VideoProgressChrome.clock(duration))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.72))
                    Capsule().fill(.white.opacity(0.28))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: width * fraction)
                        }
                        .frame(width: width, height: 3).padding(.top, 10)
                }.foregroundStyle(.white).shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct VideoSurface<Caption: View, ActionRail: View>: View {
    let url: URL
    let poster: URL?
    let active: Bool
    var diagnosticWorkID: Int? = nil
    var diagnosticOffline = false
    var gesturesActive: Bool? = nil
    var gestureTopExclusion: CGFloat = 110
    var gestureExcludedFrames: [CGRect] = []
    var chromeHidden = false
    var onChromeHold: (() -> Void)? = nil
    var pausedForOverlay = false
    var retainDuringInterruption = false
    var presentationLease: MediaDeckPresentationLease? = nil
    var playbackOwner: UUID? = nil
    var playbackScope: String? = nil
    var playbackRootSlot: UUID? = nil
    var timelineWindow: VideoPlaybackNeighborWindow? = nil
    var preserveForPageCover = false
    var mediaBlurred = false
    var onEdgeSwipe: MediaEdgeSwipeAction? = nil
    var onEdgeDrag: MediaEdgeDragAction? = nil
    var onDoubleTap: (() -> Void)? = nil
    var refreshURL: (() async throws -> URL?)? = nil
    var onConfirmedUnavailable: (() -> Void)? = nil
    var resumePosition: Double? = nil
    var onProgress: ((Double, Double, Bool) -> Void)? = nil
    var onDisplayReady: ((Bool) -> Void)? = nil
    var onImageContent: (() -> Void)? = nil
    var transitionFrame: UIImage? = nil
    var usesTransitionPreview = false
    let caption: () -> Caption
    let actionRail: (Binding<Bool>) -> ActionRail
    private let chrome = ViewingChromeController.shared
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("muted") private var muted = true
    @AppStorage("automaticVideoRepair") private var automaticVideoRepair = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.playbackControlsBottomInset) private var bottomBarHeight
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var preparationTask: Task<Void, Never>?
    @State private var sourceIdentity: MediaRepairStore.Identity?
    @State private var localSourceMissing = false
    @State private var compatibilityLease: MediaFileLease?
    @State private var posterLookupTask: Task<Void, Never>?
    @State private var posterLookupID: UUID?
    @State private var playbackEntry: VideoPlaybackSessions.Entry?
    @State private var playbackAttachment: UUID?
    @State private var observersAttached = false
    @State private var boundInputURL: URL?
    @State private var standalonePlaybackOwner = UUID()
    private var ownedPlaybackEntry: VideoPlaybackSessions.Entry? {
        guard let entry = playbackEntry, entry.valid, entry.attachment == playbackAttachment else { return nil }
        return entry
    }
    private var player: AVPlayer? {
        guard let entry = ownedPlaybackEntry, entry.player.currentItem === entry.item else { return nil }
        return entry.player
    }
    @State private var actualSourceURL: URL?
    @State private var preloadDemandOwner = UUID()
    #if DEBUG
    @State private var measuredStartupAt: TimeInterval?
    @State private var measuredFirstFrame = false
    #endif
    @State private var actualSourceKind: PlaybackDiagnosticSource = .network
    @State private var compatibilityAvailable = false
    @State private var nativeRetrySuspended = false
    @State private var compatibilityPosition: Double?
    @State private var compatibilityRequest: CompatibilityRequest?
    @State private var repairedSource: MediaRepair.Result?
    @State private var posterRetry = 0
    @State private var posterLoadResult = CachedPosterLoadResult()
    @State private var delayedPoster: FirstFrameWait?
    @State private var preservesPreparedCover = false
    @State private var posterNeedsFrame = false
    @State private var posterCaptureTried = false
    @State private var posterVideoOutput: AVPlayerItemVideoOutput?
    @State private var posterOutputItem: AVPlayerItem?
    @State private var posterSampleAttempts = 0
    @State private var posterCaptureTask: Task<Void, Never>?
    @State private var posterExpiryTask: Task<Void, Never>?
    @State private var posterCaptureID: UUID?
    @State private var bypassRepaired = false
    @State private var repairAttempted = false
    @State private var repairStage: MediaRepairStage?
    @State private var repairProgress: Double?
    @State private var preparationGestureFrame: CGRect = .zero
    #if DEBUG && targetEnvironment(simulator)
    @State private var qaPreparationCancelled = false
    @State private var qaBuffering = true
    private var qaPreparationActive: Bool {
        VisualControlsQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-preparation58") &&
            !qaPreparationCancelled && active
    }
    #endif
    @State private var repairPlayingRecorded = false
    @State private var repairFirstPosition: Double?
    private struct CompatibilityRequest: Identifiable {
        let id = UUID()
        let requestedURL: URL
        let sourceURL: URL
        let sourceKind: PlaybackDiagnosticSource
        let workID: Int?
        let initialPosition: Double?
    }
    #if DEBUG && targetEnvironment(simulator)
    @State private var qaPlayerID: UUID?
    @State private var qaPrepareCount = 0
    @State private var qaCreationCount = 0
    @State private var qaFirstFrameMS: Int?
    @State private var qaStartupHeld177 = false
    @State private var qaStartupReleased177 = false
    @State private var qaNativeStartReleased177 = false
    @State private var qaLateTransitionReady177 = false

    @State private var qaTapCount = 0
    @State private var qaRateHoldCount = 0
    @State private var qaSeekStartCount = 0
    @State private var qaSeekEvents = VideoSeekQAEvents()
    #endif
    @State private var playing = false
    @State private var playbackFailed = false
    @State private var itemReady = false
    @State private var readyForDisplay = false
    @State private var nativeTimeControlStatus = AVPlayer.TimeControlStatus.paused
    @State private var nativePresentationCommitted = false
    @State private var startupPreview: VideoStartupPreview?
    @State private var startupPreviewSource: URL?
    @State private var waitingForData = true
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var bufferedRanges: [SeekTimeRange] = []
    private var statusObserver: NSKeyValueObservation? {
        get { ownedPlaybackEntry?.statusObserver }
        nonmutating set { ownedPlaybackEntry?.statusObserver = newValue }
    }
    private var playbackObserver: NSKeyValueObservation? {
        get { ownedPlaybackEntry?.playbackObserver }
        nonmutating set { ownedPlaybackEntry?.playbackObserver = newValue }
    }
    private var bufferObserver: NSKeyValueObservation? {
        get { ownedPlaybackEntry?.bufferObserver }
        nonmutating set { ownedPlaybackEntry?.bufferObserver = newValue }
    }
    private var durationObserver: NSKeyValueObservation? {
        get { ownedPlaybackEntry?.durationObserver }
        nonmutating set { ownedPlaybackEntry?.durationObserver = newValue }
    }
    private var seekableObserver: NSKeyValueObservation? {
        get { ownedPlaybackEntry?.seekableObserver }
        nonmutating set { ownedPlaybackEntry?.seekableObserver = newValue }
    }
    @State private var seekRanges: [SeekTimeRange] = []
    private var timeObserver: Any? {
        get { ownedPlaybackEntry?.timeObserver }
        nonmutating set { ownedPlaybackEntry?.timeObserver = newValue }
    }
    private struct PlayerEventToken: Equatable {
        let id = UUID()
        let item: ObjectIdentifier
        let generation: Int
    }
    @State private var playerStatusEvent: PlayerEventToken?
    @State private var playerReprepareEvent: PlayerEventToken?
    @State private var playerSyncEvent: PlayerEventToken?
    @State private var seekingBase: Double?
    @State private var seekTarget: Double?
    @State private var holdingRate = false
    @State private var wasPlayingBeforeHold = false
    @State private var resolvedURL: URL?
    @State private var recoveryAttempted = false
    @State private var recovering = false
    @State private var recoveryMessage = "视频暂时无法播放"
    @State private var recoveryTask: Task<Void, Never>?
    @State private var playbackGeneration = 0
    @State private var failureHandled = false
    @State private var resumeApplied = false
    @State private var resumeInFlight = false
    @State private var interactiveSeekID: UUID?
    @State private var recoveryPosition: Double?
    @State private var resumeCursor = PlaybackResumeCursor()
    @State private var userIntent = PlaybackUserIntent()
    @State private var barInteractionActive = false
    private var chromePosition: Double {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return PlaybackLayoutQA.variant == "zero" ? 0 : 9 }
        #endif
        return seekTarget ?? currentTime
    }
    private var chromeDuration: Double {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return PlaybackLayoutQA.variant == "unknown" ? 0 : 30 }
        #endif
        return duration
    }
    private var chromeBufferedRanges: [SeekTimeRange] {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-buffering62") {
            return [.init(start: 0, end: 6), .init(start: 12, end: 18)]
        }
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return [.init(start: 0, end: 18)] }
        #endif
        return bufferedRanges
    }
    private var showsTrackTime: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return PlaybackLayoutQA.variant == "seeking" }
        #endif
        return barInteractionActive
    }
    private var swipeSeekTarget: Double? {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant == "swipe" { return chromePosition }
        #endif
        return barInteractionActive ? nil : seekTarget
    }
    private var compactHeight: Bool { verticalSizeClass == .compact }
    private var requestedResume: Double? { resumeCursor.requested(initial: resumePosition, recovery: recoveryPosition) }
    private var awaitingResume: Bool { resumeInFlight || (requestedResume != nil && !resumeApplied) }
    private struct FirstFrameWait: Equatable {
        let source: URL
        let generation: Int
    }
    private var simulatedFirstFrameWait: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        return VisualControlsQA.enabled && qaBuffering &&
            (args.contains("--qa-first-frame-poster") ||
             (args.contains("--qa-neighbor-first-frame") && diagnosticWorkID == 28_037_104))
        #else
        false
        #endif
    }
    private var waitingForFirstFrame: Bool {
        !VideoStartupPolicy.nativeVisible(layerReady: readyForDisplay, itemReady: itemReady,
            resumePending: awaitingResume, wantsPlayback: wantsPlayback,
            nativePlaying: nativeTimeControlStatus == .playing, committed: nativePresentationCommitted) || simulatedFirstFrameWait
    }
    private var currentPosterImage: UIImage? { posterLoadResult.image(for: url, declared: poster) }
    private var selectedStartupPreview: VideoStartupPreview? {
        VideoStartupPolicy.preview(held: startupPreviewSource == url ? startupPreview : nil,
                                   posterReady: currentPosterImage != nil,
                                   transitionReady: startupTransitionFrame != nil && !awaitingResume)
    }
    private var startupTransitionFrame: UIImage? {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-late-transition177"), diagnosticWorkID == 28_037_104,
           !qaLateTransitionReady177 { return nil }
        #endif
        return transitionFrame
    }
    private var showsTransitionFrame: Bool { selectedStartupPreview == .transition && waitingForFirstFrame && !awaitingResume }
    private var needsTransitionFallback: Bool {
        active && scenePhase == .active && !pausedForOverlay && !chromeHidden && usesTransitionPreview && wantsPlayback && waitingForFirstFrame && !showsTransitionFrame &&
            (!playbackFailed || recovering || repreparePending)
    }
    private var wantsPlayback: Bool { userIntent.shouldPlay(autoplay: autoplay) || holdingRate }
    private var firstFrameWait: FirstFrameWait? {
        guard active, scenePhase == .active, !pausedForOverlay, wantsPlayback, waitingForFirstFrame,
              !playbackFailed || recovering || repreparePending else { return nil }
        return .init(source: url, generation: playbackGeneration)
    }
    private var posterPresentation: CachedPoster.Presentation {
        guard waitingForFirstFrame, !showsTransitionFrame else { return .hidden }
        // A prepared page has no active player. Keep its cached cover or
        // placeholder visible while it participates in a page transition.
        if !active || preservesPreparedCover { return .preview }
        if !wantsPlayback { return .preview }
        if needsTransitionFallback { return .imageOnly }
        guard let firstFrameWait, delayedPoster == firstFrameWait else { return .hidden }
        return .imageOnly
    }
    private var visibleStartupPreview: VideoStartupPreview? {
        switch startupDisplay {
        case .poster: return .poster
        case .transition: return .transition
        default: return nil
        }
    }
    private var startupDisplay: VideoStartupDisplay {
        VideoStartupPolicy.display(nativeVisible: !waitingForFirstFrame,
            nativeBuffering: currentVideoWaiting, waiting: waitingForFirstFrame,
            active: active, sceneActive: scenePhase == .active, paused: pausedForOverlay || chromeHidden,
            selected: selectedStartupPreview, posterAllowed: posterPresentation != .hidden && currentPosterImage != nil,
            transitionAllowed: showsTransitionFrame,
            waitRequested: currentVideoWaiting || needsTransitionFallback)
    }
    private var showsNativeLayer: Bool {
        startupDisplay == .native || startupDisplay == .nativeBuffering
    }
    private func commitVisibleStartupPreview() {
        guard let visibleStartupPreview else { return }
        if startupPreviewSource != url { startupPreview = nil; startupPreviewSource = url }
        if startupPreview != visibleStartupPreview { startupPreview = visibleStartupPreview }
    }
    private var ownsPlaybackLease: Bool { playbackEntry.map { $0.attachment == playbackAttachment && VideoPlaybackSessions.shared.isActive($0) } == true }
    private var layerReadinessIdentity: VideoLayerReadinessIdentity? {
        guard let entry = ownedPlaybackEntry, entry.player.currentItem === entry.item, boundInputURL == url else { return nil }
        return .init(player: ObjectIdentifier(entry.player), item: ObjectIdentifier(entry.item),
                     attachment: entry.attachment, generation: playbackGeneration, source: url)
    }
    private func acceptLayerReadiness(_ identity: VideoLayerReadinessIdentity, ready: Bool) {
        guard layerReadinessIdentity == identity else { return }
        if readyForDisplay != ready { readyForDisplay = ready }
    }
    private var canScrub: Bool { active && ownsPlaybackLease && itemReady && duration > 0 && !resumeInFlight && !playbackFailed && !seekRanges.isEmpty }
    private var loading: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if PlaybackLayoutQA.enabled && PlaybackLayoutQA.variant != "live" { return PlaybackLayoutQA.variant == "buffering" }
        if VisualControlsQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-buffering62") && qaBuffering { return active }
        #endif
        return active && !playbackFailed && seekTarget == nil && (awaitingResume || !itemReady || (wantsPlayback && (waitingForData || waitingForFirstFrame)))
    }
    private var preparingVideo: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return true }
        #endif
        return active && (loading || (playbackFailed && (recovering || repreparePending)))
    }
    private var repreparePending: Bool { currentItem(matching: playerReprepareEvent) != nil }
    private var currentVideoWaiting: Bool {
        active && scenePhase == .active && !chromeHidden && !pausedForOverlay &&
            (gesturesActive ?? active) && seekTarget == nil && preparingVideo &&
            wantsPlayback
    }
    private var showsPausedOverlay: Bool {
        VideoStartupPolicy.pauseVisible(active: active, wantsPlayback: wantsPlayback, failed: playbackFailed,
            overlaid: pausedForOverlay, seeking: seekTarget != nil, restoring: awaitingResume,
            hasVisual: !waitingForFirstFrame || visibleStartupPreview != nil)
    }
    private var repairingVideo: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return true }
        #endif
        return recovering && repairStage != nil
    }
    private var preparationCanCancel: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return (gesturesActive ?? active) && !chromeHidden && !pausedForOverlay }
        #endif
        return preparingVideo && recovering && repairStage != nil && (gesturesActive ?? active) && !chromeHidden && !pausedForOverlay
    }
    private var effectiveGestureExcludedFrames: [CGRect] {
        guard !chromeHidden else { return [] }
        var frames = gestureExcludedFrames
        if preparationCanCancel && !preparationGestureFrame.isEmpty {
            frames.append(preparationGestureFrame)
        }
        return frames
    }
    private var preparationFraction: Double? {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { return 0.65 }
        #endif
        if repairStage == .transcoding || repairStage == .downloading { return repairProgress }
        return nil
    }
    var body: some View {
        ZStack {
            Group {
                CachedPoster(source: url, declared: poster, active: active, fit: true, presentation: .hidden,
                    sharedResult: posterLoadResult, restoresDecodedCoverPreview: true,
                    retryToken: posterRetry, diagnosticWorkID: diagnosticWorkID,
                    onFailure: { failed in
                        if failed { posterNeedsFrame = true; installPosterOutput() }
                    })
                if startupDisplay == .poster, let posterImage = currentPosterImage {
                    Image(uiImage: posterImage).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true).allowsHitTesting(false)
                } else if startupDisplay == .transition, let transitionFrame = startupTransitionFrame {
                    Image(uiImage: transitionFrame).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true).allowsHitTesting(false)
                } else if startupDisplay == .neutral || startupDisplay == .waiting {
                    CoverPlaceholder(symbol: "", title: "视频预览")
                }
                if let player, let identity = layerReadinessIdentity {
                    // A replacement player owns a new layer observation. Reusing
                    // the old representable retains its captured player identity.
                    PlayerLayerView(player: player, identity: identity, onReadiness: acceptLayerReadiness)
                        .id(ObjectIdentifier(player)).opacity(showsNativeLayer ? 1 : 0)
                }
            }.blur(radius: mediaBlurred ? 24 : 0)
            VideoWaitingIndicator(visible: startupDisplay == .waiting || startupDisplay == .nativeBuffering)
                .accessibilityHidden(!active)
            if playbackFailed && !recovering && !repreparePending {
                VStack(spacing: 12) {
                    Button("重试") { nativeRetrySuspended = false; repairAttempted = false; release(); prepare() }
                        .buttonStyle(AppActionButtonStyle(tone: .neutral))
                    if compatibilityAvailable {
                        Button("兼容播放", action: openCompatibility)
                            .buttonStyle(AppActionButtonStyle(tone: .accent))
                            .accessibilityIdentifier("media.compatibility.open")
                    }
                }
                .font(.caption)
                .padding(FloatingPageChrome.cardInset)
                .frame(maxWidth: 260)
                .modifier(MediaFeedbackSurface())
                .viewingChromeHidden(chromeHidden)
                .existingFeedbackToast(recoveryMessage, active: active && !chromeHidden)
            } else if showsPausedOverlay {
                Image(systemName: "play.fill").font(.title).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(.black.opacity(0.35), in: Circle())
                    .allowsHitTesting(false).accessibilityHidden(true).viewingChromeHidden(chromeHidden)
            }
            if holdingRate && seekTarget == nil {
                VStack { Text("2× 播放").modifier(MediaHUDSurface()).padding(.top, 120); Spacer() }.allowsHitTesting(false).viewingChromeHidden(chromeHidden)
            }
            VStack(spacing: 0) {
                caption().padding(.leading, PlaybackChrome.horizontalInset).padding(.trailing, 72)
                Group {
                    if active && (!playbackFailed || recovering || repreparePending) {
                        VideoProgressChrome(position: chromePosition, duration: chromeDuration, bufferedRanges: chromeBufferedRanges,
                                            enabled: canScrub && chromeDuration > 0,
                                            showTime: showsTrackTime, onSeek: scrub,
                                            onInteractionChange: { barInteractionActive = $0 },
                                            preparationVisible: repairingVideo,
                                            preparationProgress: preparationFraction, preparationCanCancel: preparationCanCancel,
                                            onPreparationCancel: cancelRepair)
                    } else { Color.clear.frame(height: 44).accessibilityHidden(true) }
                }
                .padding(.leading, PlaybackChrome.horizontalInset)
                .padding(.trailing, compactHeight ? 72 : PlaybackChrome.horizontalInset)
            }
            .padding(.bottom, bottomBarHeight)
            .background(alignment: .bottom) {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.82), location: 0),
                    .init(color: .black.opacity(0.42), location: 0.45),
                    .init(color: .clear, location: 1)
                ], startPoint: .bottom, endPoint: .top)
                .frame(height: 190 + bottomBarHeight).allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .viewingChromeHidden(chromeHidden)
        }
        .overlay(alignment: compactHeight ? .trailing : .bottomTrailing) {
            actionRail($muted)
                .playbackRailInsets(bottomBarHeight: bottomBarHeight, compactHeight: compactHeight)
                .viewingChromeHidden(chromeHidden)
        }
        .overlay {
            if let target = swipeSeekTarget {
                VideoSwipeSeekFeedback(target: target, duration: chromeDuration)
                    .viewingChromeHidden(chromeHidden)
            }
        }
        .overlayPreferenceValue(VideoPreparationGestureAnchorKey.self) { anchor in
            GeometryReader { proxy in
                Color.clear.preference(
                    key: VideoPreparationGestureFrameKey.self,
                    value: resolvedVideoPreparationFrame(anchor, in: proxy)
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .coordinateSpace(name: VideoPreparationGestureSpace.name)
        .onPreferenceChange(VideoPreparationGestureFrameKey.self) { frame in
            let next = preparationCanCancel ? frame : .zero
            if preparationGestureFrame != next { preparationGestureFrame = next }
        }
        .background {
            MediaGestureLayer(active: (gesturesActive ?? active) && !pausedForOverlay, isVideo: true, topExclusion: chromeHidden ? 0 : gestureTopExclusion, bottomExclusion: chromeHidden ? 0 : bottomBarHeight + 44, excludedFrames: effectiveGestureExcludedFrames, onEdgeSwipe: onEdgeSwipe, onEdgeDrag: onEdgeDrag, onSeek: seek, onRateHold: holdRate, onTap: togglePlayback, onDoubleTap: onDoubleTap, onChromeHold: onChromeHold)
        }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topTrailing) {
            if CollectionPagingQA.enabled && active && qaStartupHeld177 {
                Button("完成本地准备") { qaStartupReleased177 = true }
                    .accessibilityIdentifier("media.qa.finish-prepare177").buttonStyle(.bordered).padding(.top, 180)
            }
            if CollectionPagingQA.enabled && active && ProcessInfo.processInfo.arguments.contains("--qa-native-start-held177") {
                Button("开始本地播放") { qaNativeStartReleased177 = true; syncPlayback() }
                    .accessibilityIdentifier("media.qa.native-start177").buttonStyle(.bordered).padding(.top, 180)
            }
            if CollectionPagingQA.enabled && active && diagnosticWorkID == 28_037_104 &&
                ProcessInfo.processInfo.arguments.contains("--qa-late-transition177") {
                Button("提供预解码画面") { qaLateTransitionReady177 = true }
                    .accessibilityIdentifier("media.qa.release-warm177").buttonStyle(.bordered).padding(.top, 230)
            }
            if VisualControlsQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-buffering62") && active {
                Button(qaBuffering ? "模拟恢复" : "模拟缓冲") { qaBuffering.toggle() }
                    .accessibilityIdentifier("media.qa.buffering-toggle")
                    .buttonStyle(.bordered).padding(.top, 180)
            }
            if CollectionPagingQA.enabled, active,
               ProcessInfo.processInfo.arguments.contains("--qa-compatibility-template") {
                Button("打开兼容播放测试", action: presentCompatibility)
                    .accessibilityIdentifier("media.qa.compatibility-open")
                    .buttonStyle(.bordered)
                    .padding(.top, 200)
            }
            if (CollectionPagingQA.enabled || PlaybackLayoutQA.enabled) && active {
                let pool = VideoPlaybackSessions.shared
                let entries = pool.entries
                let activeEntry = entries.first(where: { pool.isActive($0) })
                let candidate = entries.first {
                    guard $0.state == .candidate else { return false }
                    if let window = activeEntry?.timelineWindow { return window.next?.matches($0.key) == true }
                    return true
                }.map { "\($0.key.workID):\($0.token.uuidString):\($0.prerollFinished)" } ?? "none"
                let retained = entries.first { $0.state == .adjacentPaused }
                    .map { "\($0.key.workID):\($0.token.uuidString)" } ?? "none"
                let state = "player=\(qaPlayerID?.uuidString ?? "none");prepare=\(qaPrepareCount);created=\(qaCreationCount);position=\(String(format: "%.3f", currentTime));muted=\(player?.isMuted ?? muted);rate=\(player?.rate ?? 0);chrome=\(chromeHidden);toggles=\(chrome.qaToggleCount);taps=\(qaTapCount);rateHolds=\(qaRateHoldCount);seekStarts=\(qaSeekStartCount);poolCount=\(entries.count);poolPlaying=\(entries.filter { $0.player.rate != 0 }.count);firstFrameMS=\(qaFirstFrameMS.map(String.init) ?? "pending")"
                let bufferState = ";candidate=\(candidate);retainedNeighbor=\(retained)"
                let seekState = ";intent=\(playing);inFlight=\(resumeInFlight);interactivePending=\(interactiveSeekID != nil);seekBase=\(seekingBase != nil);resumeApplied=\(resumeApplied);hasResume=\(requestedResume != nil);active=\(active);overlay=\(pausedForOverlay);ready=\(itemReady);failed=\(playbackFailed);gen=\(playbackGeneration);seekCallbacks=\(qaSeekEvents.callbacks);seekCommits=\(qaSeekEvents.commits);seekFinished=\(qaSeekEvents.lastFinished.map { String($0) } ?? "none");nativePosition=\(String(format: "%.3f", player?.currentTime().seconds ?? -1));timeStatus=\(player?.timeControlStatus.rawValue ?? -1)"
                let nativeState = ";itemStatus=\(player?.currentItem?.status.rawValue ?? -1);itemErrorCode=\((player?.currentItem?.error as NSError?)?.code ?? 0);source=\(actualSourceKind.rawValue);posterMode=\(posterPresentation);coverReady=\(currentPosterImage != nil);transitionFrame=\(showsTransitionFrame);display=\(startupDisplay);startupHeld177=\(qaStartupHeld177);pausedHUD=\(showsPausedOverlay);wantsPlayback=\(wantsPlayback);layerReady=\(readyForDisplay);nativeVisible=\(!waitingForFirstFrame);nativeCommitted=\(nativePresentationCommitted);entryNative177=\(ownedPlaybackEntry?.hasPresentedNative ?? false);preview177=\(visibleStartupPreview.map { String(describing: $0) } ?? "none");lateTransition177=\(qaLateTransitionReady177)"
                Text(state + bufferState + seekState + nativeState).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("media.qa.player").accessibilityValue(state + bufferState + seekState + nativeState)
            }
        }
        #endif
        .task(id: firstFrameWait) {
            delayedPoster = nil
            guard let wait = firstFrameWait else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, firstFrameWait == wait else { return }
            delayedPoster = wait
        }
        .accessibilityAction(named: Text(wantsPlayback ? "暂停视频" : "播放视频"), togglePlayback)
        .onChange(of: visibleStartupPreview) { _, _ in commitVisibleStartupPreview() }
        #if DEBUG && targetEnvironment(simulator)
        .onChange(of: active, initial: true) { _, _ in
            guard ProcessInfo.processInfo.arguments.contains("--qa-late-transition177"), diagnosticWorkID == 28_037_104 else { return }
            qaLateTransitionReady177 = false
        }
        #endif
        .onChange(of: waitingForFirstFrame) { _, waiting in
            if !waiting, active, ownsPlaybackLease {
                ownedPlaybackEntry?.markNativePresented()
                nativePresentationCommitted = true
            }
            publishDisplayReadiness(); recordMeasuredFirstFrame()
        }
        .onChange(of: nativeTimeControlStatus) { _, _ in publishDisplayReadiness() }
        .onChange(of: wantsPlayback) { _, _ in publishDisplayReadiness() }
        .onAppear {
            preservesPreparedCover = !active
            commitVisibleStartupPreview()
            if active { prepare() }
        }
        .onChange(of: active) { _, value in
            if value { commitVisibleStartupPreview(); prepare() }
            else {
                startupPreview = nil; startupPreviewSource = nil
                // Activating a prepared page must not withdraw its existing
                // cover before AVPlayerLayer has a drawable native frame.
                preservesPreparedCover = true
                if !retainDuringInterruption && resumePosition == nil { resumeCursor.reset(); userIntent.reset() }
                release(interrupted: retainDuringInterruption, keepTimelineNeighbor: true)
            }
        }
        .onChange(of: url) { _, _ in
            startupPreview = nil; startupPreviewSource = nil
            preservesPreparedCover = !active
            posterNeedsFrame = false
            nativeRetrySuspended = false; compatibilityPosition = nil; compatibilityAvailable = false
            release()
            repairedSource = nil; bypassRepaired = false; repairAttempted = false
            if active { prepare() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && repairStage != nil { cancelRepair() }
            if phase != .active { stopPosterCapture() }
            else { posterCaptureTried = false; installPosterOutput() }
            updatePreloadDemand()
        }
        .onChange(of: preparingVideo) { _, _ in updatePreloadDemand() }
        .onChange(of: waitingForData) { _, waiting in
            guard active else { return }
            updatePreloadDemand()
            if waiting { VideoPlaybackSessions.shared.removeCandidates(owner: playbackOwner ?? standalonePlaybackOwner) }
            else if readyForDisplay && itemReady { publishDisplayReadiness() }
        }
        .onChange(of: seekingBase) { _, base in
            updatePreloadDemand()
            if base != nil { VideoPlaybackSessions.shared.removeCandidates(owner: playbackOwner ?? standalonePlaybackOwner) }
        }
        .onChange(of: interactiveSeekID) { _, _ in updatePreloadDemand() }
        .onChange(of: repairingVideo) { _, busy in
            updatePreloadDemand()
            if busy { VideoPlaybackSessions.shared.removeCandidates(owner: playbackOwner ?? standalonePlaybackOwner) }
        }
        .onChange(of: muted) { _, value in player?.isMuted = value }
        .onChange(of: readyForDisplay) { _, value in
            publishDisplayReadiness()
            recordMeasuredFirstFrame()
            if value, let player, let item = player.currentItem { capturePosterFrame(player, item: item) }
        }
        .onChange(of: itemReady) { _, _ in publishDisplayReadiness(); recordMeasuredFirstFrame() }
        .onChange(of: playerStatusEvent) { _, event in
            guard let item = currentItem(matching: event) else { return }
            itemReady = item.status == .readyToPlay
            if item.status == .failed { handleFailure(item) }
            updateBuffer(item)
            if itemReady && !pausedForOverlay { applyResume(item) }
            // Reattaching an already-ready paused layer may not emit another
            // readiness edge. Publish its current identity-bound state now.
            publishDisplayReadiness()
        }
        .onChange(of: playerReprepareEvent) { _, event in
            guard active, ownsPlaybackLease, currentItem(matching: event) != nil else { return }
            playerReprepareEvent = nil
            retirePlayer(); prepare()
        }
        .onChange(of: playerSyncEvent) { _, event in
            guard currentItem(matching: event) != nil else { return }
            syncPlayback(); publishDisplayReadiness()
        }
        .onChange(of: duration) { _, _ in
            if itemReady, !pausedForOverlay, let item = player?.currentItem { applyResume(item) }
        }
        .onChange(of: currentTime) { _, _ in observePlaybackProgress() }
        .onChange(of: resumeInFlight) { _, value in
            if value { syncPlayback() }
        }
        .onChange(of: autoplay) { _, value in
            userIntent.reset(); ownedPlaybackEntry?.userIntent = nil
            if active { playing = value; syncPlayback() }
        }
        .onChange(of: pausedForOverlay) { _, value in
            if !value && localSourceMissing { confirmUnavailable() }
            syncPlayback()
            updatePreloadDemand()
            if value { stopPosterCapture() }
            else { posterCaptureTried = false; installPosterOutput() }
            if !value, let item = player?.currentItem {
                if item.status == .failed { handleFailure(item) }
                else if item.status == .readyToPlay { applyResume(item) }
            }
        }
        .onDisappear {
            release(interrupted: retainDuringInterruption, presentationDetached: true, keepTimelineNeighbor: true)
        }
        .mediaCover(item: $compatibilityRequest, source: .playback, onDismiss: {
            if let lease = compatibilityLease {
                compatibilityLease = nil
                Task { await MediaCache.shared.release(lease) }
            }
            onDisplayReady?(false)
        }) { request in
            CompatibilityVideoView(url: request.sourceURL, workID: request.workID, initialPosition: request.initialPosition,
                onProgress: { position, length, flush in
                    compatibilityPosition = PlaybackResumePolicy.position(position: position, duration: length)
                    onProgress?(position, length, flush)
                }, onPlaying: {
                    onDisplayReady?(true)
                    let context = compatibilityDiagnostic(request, code: nil)
                    LocalDiagnosticsStore.shared.note(area: .playback, code: .compatibilityPlaying, playback: context)
                }, onFailure: { code in
                    let context = compatibilityDiagnostic(request, code: code)
                    LocalDiagnosticsStore.shared.note(area: .playback, code: .playbackFailed, count: 2, playback: context)
                }, onClose: {
                    guard compatibilityRequest?.id == request.id else { return }
                    compatibilityRequest = nil
                })
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let current = player?.currentItem, let ended = note.object as? AVPlayerItem, current === ended, active, ownsPlaybackLease else { return }
            onProgress?(0, duration, true)
            player?.seek(to: .zero); syncPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let current = player?.currentItem, let failed = note.object as? AVPlayerItem, current === failed, active, ownsPlaybackLease else { return }
            handleFailure(failed, notificationError: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
        }
    }
    private func currentItem(matching event: PlayerEventToken?) -> AVPlayerItem? {
        guard let event, event.generation == playbackGeneration,
              let item = player?.currentItem, ObjectIdentifier(item) == event.item else { return nil }
        return item
    }
    private func prepare() {
        guard presentationLease?.finished != true, active, !nativeRetrySuspended else { return }
        if player != nil && observersAttached { syncPlayback(); return }
        guard preparationTask == nil else { return }
        let generation = playbackGeneration, input = url, address = resolvedURL ?? url
        let owner = playbackOwner ?? standalonePlaybackOwner, scope = playbackScope ?? "standalone"
        preparationTask = Task { @MainActor in
            defer { if generation == playbackGeneration { preparationTask = nil } }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-startup-held177") {
                qaStartupHeld177 = true
                do {
                    while !qaStartupReleased177 { try await Task.sleep(for: .milliseconds(50)) }
                } catch { qaStartupHeld177 = false; return }
                qaStartupHeld177 = false
            }
            #endif
            let retained = playbackEntry.flatMap { entry -> VideoPlaybackSessions.Entry? in
                guard entry.valid, entry.key.owner == owner, entry.key.scope == scope,
                      entry.key.workID == (diagnosticWorkID ?? 0), entry.key.requestedURL == address,
                      entry.key.rootSlot == playbackRootSlot else { return nil }
                return entry
            }
            var lease: MediaFileLease?
            var repair = repairedSource
            if retained == nil {
                if repair == nil && !bypassRepaired { repair = await MediaRepair.shared.cached(address, offline: diagnosticOffline) }
                if let repair {
                    if let protected = repair.lease { lease = protected }
                    else { lease = await MediaCache.shared.leaseFile(repair.url, protecting: address) }
                }
                if lease == nil {
                    lease = address.isFileURL ? await MediaCache.shared.leaseFile(address) :
                        (recoveryAttempted ? nil : await MediaCache.shared.leaseCached(address, video: true))
                }
            }
            guard presentationLease?.finished != true, !Task.isCancelled, active, !nativeRetrySuspended, input == url,
                  generation == playbackGeneration else {
                if let lease { await MediaCache.shared.release(lease) }; return
            }
            if let repair, lease?.file == repair.url {
                repairedSource = .init(url: repair.url, transcoded: repair.transcoded, reused: repair.reused)
            }
            let source = retained?.key.sourceURL ?? lease?.file ?? address
            if source.isFileURL && retained == nil && lease == nil {
                playbackFailed = true; waitingForData = false; playing = false
                localSourceMissing = true
                recoveryMessage = "本地视频不可用"
                // Preserve the existing terminal-local-missing policy without
                // handing an unvalidated file to AVPlayer first.
                confirmUnavailable()
                return
            }
            let key = retained?.key ?? videoPlaybackKey(owner: owner, scope: scope, workID: diagnosticWorkID ?? 0,
                address: address, source: source, rootSlot: playbackRootSlot, lease: lease)
            let existing = VideoPlaybackSessions.shared.lookup(key: key)
            let reuseTimelinePosition = timelineWindow != nil && existing?.state == .adjacentPaused &&
                existing?.timelineResumeSeed == resumePosition
            var consumed = false
            let entry = VideoPlaybackSessions.shared.acquireCurrent(key: key, timelineWindow: timelineWindow,
                                                                    pin: { consumed = true }, unpin: {
                if let lease { Task { await MediaCache.shared.release(lease) } }
            })
            if !consumed, let lease { Task { await MediaCache.shared.release(lease) } }
            guard let entry else { return }
            sourceIdentity = retained == nil ? lease?.identity : sourceIdentity
            completePreparation(entry, existing: existing, retained: retained, reuseTimelinePosition: reuseTimelinePosition,
                                source: source, address: address)
        }
    }

    private func completePreparation(_ entry: VideoPlaybackSessions.Entry, existing: VideoPlaybackSessions.Entry?,
                                     retained: VideoPlaybackSessions.Entry?, reuseTimelinePosition: Bool,
                                     source: URL, address: URL) {
        #if DEBUG && targetEnvironment(simulator)
        qaPrepareCount += 1; qaFirstFrameMS = nil
        #endif
        #if DEBUG
        measuredStartupAt = ProcessInfo.processInfo.systemUptime; measuredFirstFrame = false
        #endif
        let previousLayerReady = readyForDisplay && playbackEntry === entry && boundInputURL == url &&
            entry.valid && entry.player.currentItem === entry.item && entry.item.status == .readyToPlay
        nativePresentationCommitted = entry.valid && entry.player.currentItem === entry.item && entry.hasPresentedNative
        nativeTimeControlStatus = entry.player.timeControlStatus
        if userIntent.explicitPlaying == nil, let saved = entry.userIntent, saved.autoplay == autoplay {
            userIntent.setPlaying(saved.playing)
        }
        entry.userIntent = userIntent.explicitPlaying.map { .init(playing: $0, autoplay: autoplay) }
        localSourceMissing = false
        playbackFailed = false; compatibilityAvailable = false; failureHandled = false
        itemReady = entry.item.status == .readyToPlay
        readyForDisplay = previousLayerReady; waitingForData = nativeTimeControlStatus == .waitingToPlayAtSpecifiedRate
        repairPlayingRecorded = false; repairFirstPosition = nil
        resumeApplied = false; resumeInFlight = false; onDisplayReady?(false)
        currentTime = 0; duration = 0; bufferedRanges = []; playing = userIntent.shouldPlay(autoplay: autoplay)
        actualSourceURL = source
        actualSourceKind = diagnosticOffline && address.isFileURL && source.isFileURL &&
            source.deletingLastPathComponent() == address.deletingLastPathComponent() ? .offline :
            (source != address && source.isFileURL ? .cache : (source.isFileURL ? (diagnosticOffline ? .offline : .local) : .network))
        updatePreloadDemand(waiting: true)
            playbackEntry = entry; playbackAttachment = entry.attachment; observersAttached = true; boundInputURL = url
            let item = entry.item, value = entry.player
            value.isMuted = muted
            let nativeTime = value.currentTime().seconds
            if existing != nil, nativeTime.isFinite { currentTime = max(0, nativeTime) }
            if reuseTimelinePosition && nativeTime.isFinite {
                resumeApplied = true
            } else if retained != nil, let target = requestedResume,
                      nativeTime.isFinite, abs(target - nativeTime) < 0.1 {
                resumeApplied = true
            }
            entry.timelineResumeSeed = timelineWindow == nil ? nil : resumePosition
            posterCaptureTried = false; installPosterOutput()
            #if DEBUG && targetEnvironment(simulator)
            qaPlayerID = entry.token
            if existing == nil { qaCreationCount += 1 }
            #endif
            let observedGeneration = playbackGeneration
            statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                Task { @MainActor in
                    guard player?.currentItem === item, observedGeneration == playbackGeneration else { return }
                    // Only publish identity-bound native state here. Playback
                    // decisions belong to the current View, after overlay/focus
                    // changes, rather than the View that installed this KVO.
                    playerStatusEvent = .init(item: ObjectIdentifier(item), generation: observedGeneration)
                }
            }
            playbackObserver = value.observe(\.timeControlStatus, options: [.initial, .new]) { value, _ in
                Task { @MainActor in
                    guard player === value, observedGeneration == playbackGeneration else { return }
                    nativeTimeControlStatus = value.timeControlStatus
                    waitingForData = nativeTimeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
            bufferObserver = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { item, _ in
                Task { @MainActor in
                    guard player?.currentItem === item, observedGeneration == playbackGeneration else { return }
                    updateBuffer(item)
                }
            }
            durationObserver = item.observe(\.duration, options: [.initial, .new]) { item, _ in
                Task { @MainActor in guard player?.currentItem === item, observedGeneration == playbackGeneration else { return }; updateBuffer(item) }
            }
            seekableObserver = item.observe(\.seekableTimeRanges, options: [.initial, .new]) { item, _ in
                Task { @MainActor in guard player?.currentItem === item, observedGeneration == playbackGeneration else { return }; updateBuffer(item) }
            }
            timeObserver = value.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                guard player === value, observedGeneration == playbackGeneration else { return }
                currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
                updateBuffer(item)
            }
        syncPlayback()
    }
    private func togglePlayback() {
        guard active, !pausedForOverlay, !playbackFailed, seekingBase == nil, !holdingRate else { return }
        #if DEBUG && targetEnvironment(simulator)
        qaTapCount += 1
        #endif
        if player == nil { prepare() }
        playing = !userIntent.shouldPlay(autoplay: autoplay); userIntent.setPlaying(playing)
        ownedPlaybackEntry?.userIntent = .init(playing: playing, autoplay: autoplay)
        syncPlayback()
        if playing { posterCaptureTried = false; installPosterOutput() }
    }
    private func installPosterOutput() {
        guard posterNeedsFrame else { return }
        guard posterVideoOutput == nil, posterCaptureTask == nil else { return }
        let deferred: PosterDiagnosticStage?
        if !active || scenePhase != .active { deferred = .waitingForActivity }
        else if pausedForOverlay { deferred = .waitingForOverlay }
        else if nativeRetrySuspended || playbackFailed { deferred = .waitingForPlayback }
        else if player?.currentItem == nil { deferred = .waitingForPlayer }
        else if posterCaptureTried { deferred = .waitingForPriorAttempt }
        else { deferred = nil }
        if let deferred { noteFramePoster(.posterDeferred, error: nil, failure: nil, stage: deferred); return }
        guard let item = player?.currentItem else { return }
        guard posterLookupTask == nil else { return }
        let generation = playbackGeneration, source = url, lookup = UUID()
        posterLookupID = lookup
        posterLookupTask = Task { @MainActor in
            defer { if posterLookupID == lookup { posterLookupTask = nil; posterLookupID = nil } }
            let exists = await MediaCache.shared.hasGeneratedPoster(source)
            guard !Task.isCancelled, posterLookupID == lookup, generation == playbackGeneration, source == url,
                  player?.currentItem === item, active, !pausedForOverlay else { return }
            if exists { posterNeedsFrame = false; posterRetry += 1; return }
            attachPosterOutput(item)
        }
    }
    private func attachPosterOutput(_ item: AVPlayerItem) {
        guard posterVideoOutput == nil, !posterCaptureTried else { return }
        posterCaptureTried = true; posterSampleAttempts = 0
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = false
        item.add(output); posterVideoOutput = output; posterOutputItem = item
        noteFramePoster(.posterCaptureStarted, error: nil, failure: nil)
        let operation = UUID(); posterCaptureID = operation
        posterExpiryTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)); try Task.checkCancellation() } catch { return }
            guard posterCaptureID == operation, player?.currentItem === item else { return }
            noteFramePoster(.posterFailed, error: nil, failure: .frameUnavailable)
            stopPosterCapture()
        }
    }
    private func capturePosterFrame(_ value: AVPlayer, item: AVPlayerItem) {
        guard player === value, value.currentItem === item, active, scenePhase == .active,
              !pausedForOverlay, itemReady, readyForDisplay, !awaitingResume, !playbackFailed,
              posterOutputItem === item, let output = posterVideoOutput else { return }
        posterSampleAttempts += 1
        let time = value.currentTime()
        guard time.isValid, time.seconds.isFinite, time.seconds >= 0,
              output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            if posterSampleAttempts >= 8 {
                noteFramePoster(.posterFailed, error: nil, failure: .frameUnavailable)
                stopPosterCapture()
            }
            return
        }
        item.remove(output); posterVideoOutput = nil; posterOutputItem = nil
        guard let operation = posterCaptureID else { return }
        let frame = VideoPosterPixelBuffer(pixelBuffer)
        let generation = playbackGeneration, source = url
        let cacheGeneration = MediaCache.shared.repairGeneration
        posterCaptureTask = Task { @MainActor in
            defer {
                if posterCaptureID == operation {
                    posterExpiryTask?.cancel(); posterExpiryTask = nil
                    posterCaptureTask = nil; posterCaptureID = nil
                }
            }
            var stage = PosterDiagnosticStage.decodedFrame
            do {
                let sourceIdentity = source.isFileURL ? await MediaCache.shared.fileIdentity(source) : nil
                let rendered = try await VideoPosterProcessor.shared.process(frame, item: item)
                try Task.checkCancellation()
                guard posterCaptureID == operation, active, scenePhase == .active, !pausedForOverlay,
                      generation == playbackGeneration, player === value, value.currentItem === item,
                      url == source, !playbackFailed else { return }
                if source.isFileURL && sourceIdentity == nil { return }
                stage = .cacheWrite
                try await MediaCache.shared.storeGeneratedPoster(rendered.data, source: source,
                    expectedGeneration: cacheGeneration, expectedSourceIdentity: sourceIdentity)
                guard !Task.isCancelled, posterCaptureID == operation, active, scenePhase == .active,
                      !pausedForOverlay, generation == playbackGeneration, player === value,
                      value.currentItem === item, url == source, !playbackFailed else { return }
                posterNeedsFrame = false; posterRetry += 1
                noteFramePoster(.posterCaptured, error: nil, failure: nil)
            } catch is CancellationError {} catch {
                guard posterCaptureID == operation, generation == playbackGeneration,
                      player === value, value.currentItem === item, active else { return }
                let kind: PosterFailureKind = (error as? VideoPosterFrameError) == .unsupported ? .unsupported :
                    PosterDiagnosticPolicy.failure(error, stage: stage)
                noteFramePoster(.posterFailed, error: error, failure: kind, stage: stage)
            }
        }
    }
    private func noteFramePoster(_ code: DiagnosticCode, error: Error?, failure: PosterFailureKind?, stage: PosterDiagnosticStage = .decodedFrame) {
        let context = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: actualSourceKind,
            requestedURL: url, sourceURL: actualSourceURL ?? url, recoveryAttempted: posterCaptureTried,
            error: error.map { $0 as NSError }, eventStatusCodes: [], posterStage: stage, posterFailure: failure)
        guard let context else { return }
        LocalDiagnosticsStore.shared.note(area: .thumbnail, code: code, playback: context)
    }
    private func stopPosterCapture() {
        posterLookupTask?.cancel(); posterLookupTask = nil; posterLookupID = nil
        posterExpiryTask?.cancel(); posterExpiryTask = nil
        posterCaptureTask?.cancel(); posterCaptureTask = nil; posterCaptureID = nil
        if let output = posterVideoOutput { posterOutputItem?.remove(output) }
        posterVideoOutput = nil; posterOutputItem = nil
    }
    private func publishDisplayReadiness() {
        updatePreloadDemand()
        let ready = active && ownsPlaybackLease && !waitingForFirstFrame
        #if DEBUG && targetEnvironment(simulator)
        if ready, qaFirstFrameMS == nil, let measuredStartupAt {
            qaFirstFrameMS = Int(max(0, ProcessInfo.processInfo.systemUptime - measuredStartupAt) * 1000)
        }
        #endif
        onDisplayReady?(ready)
    }

    private func syncPlayback() {
        if let entry = playbackEntry, entry.attachment != playbackAttachment { return }
        updatePreloadDemand()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-native-start-held177"), !qaNativeStartReleased177 {
            player?.pause(); return
        }
        #endif
        let awaitingResume = requestedResume != nil && !resumeApplied
        if active && scenePhase == .active && ownsPlaybackLease && !pausedForOverlay && !resumeInFlight && !awaitingResume && seekingBase == nil && (playing || holdingRate) {
            if autoplay, userIntent.explicitPlaying != false, !holdingRate, !playbackFailed,
               seekTarget == nil, interactiveSeekID == nil,
               ownedPlaybackEntry?.startRemoteAutoplayIfReady(attachment: playbackAttachment) == true {
                return
            }
            player?.rate = holdingRate ? 2 : 1
        } else { captureProgress(flush: true); player?.pause() }
    }
    private func applyResume(_ item: AVPlayerItem) {
        guard active, ownsPlaybackLease, !resumeApplied, let value = player, value.currentItem === item else { return }
        // A ready item can publish its finite duration later. Keep the seed
        // pending until that value is known instead of silently dropping it.
        if PlaybackResumePolicy.waitsForDuration(position: requestedResume, duration: duration) { return }
        resumeApplied = true
        guard let target = resumeCursor.target(initial: resumePosition, recovery: recoveryPosition, duration: duration), target > 0 else {
            recoveryPosition = nil; syncPlayback(); publishDisplayReadiness(); return
        }
        resumeInFlight = true
        let generation = playbackGeneration
        value.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard player === value, value.currentItem === item, generation == playbackGeneration, ownsPlaybackLease else { return }
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--qa-history-screen") {
                    HistoryQA.seekReadback(requested: target, actual: value.currentTime().seconds, finished: finished)
                }
                #endif
                resumeInFlight = false; recoveryPosition = nil
                if finished { currentTime = target }
                else { LocalDiagnosticsStore.shared.note(area: .restore, code: .seekFailed) }
                playerSyncEvent = .init(item: ObjectIdentifier(item), generation: generation)
            }
        }
    }
    private func captureProgress(flush: Bool) {
        guard itemReady, !resumeInFlight, duration.isFinite, duration > 0 else { return }
        let position = player?.currentTime().seconds ?? currentTime
        guard position.isFinite, position >= 0 else { return }
        onProgress?(min(position, duration), duration, flush)
    }
    private func updateBuffer(_ item: AVPlayerItem) {
        let seconds = item.duration.seconds
        let nextDuration = seconds.isFinite && seconds > 0 ? seconds : 0
        if duration != nextDuration { duration = nextDuration }
        let nextBuffered: [SeekTimeRange] = item.loadedTimeRanges.map(\.timeRangeValue).compactMap { range in
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, end > start else { return nil }
            return SeekTimeRange(start: start, end: end)
        }
        if bufferedRanges != nextBuffered { bufferedRanges = nextBuffered }
        let nextSeekable: [SeekTimeRange] = item.seekableTimeRanges.map(\.timeRangeValue).compactMap { value in
            let start = value.start.seconds, end = CMTimeRangeGetEnd(value).seconds
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return SeekTimeRange(start: start, end: end)
        }
        if seekRanges != nextSeekable { seekRanges = nextSeekable }
    }
    private func observePlaybackProgress() {
        guard active, ownsPlaybackLease, let value = player, let item = value.currentItem else { return }
        capturePosterFrame(value, item: item)
        guard itemReady, !resumeInFlight, !pausedForOverlay, !playbackFailed else { return }
        onProgress?(min(currentTime, duration), duration, false)
        if let repairedSource, active, readyForDisplay, !repairPlayingRecorded, value.timeControlStatus == .playing,
           let baseline = repairFirstPosition, currentTime > baseline + 0.05 {
            repairPlayingRecorded = true
            let context = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: diagnosticOffline ? .offline : .cache,
                requestedURL: resolvedURL ?? url, sourceURL: repairedSource.url, recoveryAttempted: true,
                error: nil, eventStatusCodes: [], repairMode: repairedSource.transcoded ? .transcode : .remux)
            LocalDiagnosticsStore.shared.note(area: .playback, code: .repairedVideoPlaying, playback: context)
        }
        if readyForDisplay && (repairFirstPosition == nil || currentTime < (repairFirstPosition ?? 0)) { repairFirstPosition = currentTime }
    }
    private func release(interrupted: Bool = false, presentationDetached: Bool = false,
                         keepTimelineNeighbor: Bool = false) {
        let expectedOwner = playbackOwner ?? standalonePlaybackOwner
        let expectedScope = playbackScope ?? "standalone"
        let matchingEntry = playbackEntry.map { entry in
            entry.key.owner == expectedOwner && entry.key.scope == expectedScope &&
            entry.key.workID == (diagnosticWorkID ?? 0) && boundInputURL == url &&
            entry.key.requestedURL == (resolvedURL ?? url) && entry.key.rootSlot == playbackRootSlot && entry.valid
        } == true
        let sessionDetach = presentationDetached && retainDuringInterruption && presentationLease?.externallyOwned == true && presentationLease?.finished == false && ownsPlaybackLease
        let reusable = matchingEntry && scenePhase == .active && !playbackFailed && !recovering &&
            repairStage == nil && !resumeInFlight && interactiveSeekID == nil &&
            player?.currentItem?.status == .readyToPlay
        let preserve = reusable && (preserveForPageCover || playbackEntry?.state == .rootPaused || sessionDetach)
        recoveryTask?.cancel(); recoveryTask = nil; playbackGeneration += 1
        if let lease = repairedSource?.lease {
            repairedSource = nil
            Task { await MediaCache.shared.release(lease) }
        }
        recoveryAttempted = false; recovering = false; localSourceMissing = false
        if !preserve { resolvedURL = nil }
        repairStage = nil; repairProgress = nil
        repairAttempted = false
        retirePlayer(interrupted: interrupted, preserveSession: preserve, parkTimelineNeighbor: reusable && keepTimelineNeighbor)
        recoveryPosition = nil
    }
    private func retirePlayer(interrupted: Bool = false, preserveSession: Bool = false,
                              parkTimelineNeighbor: Bool = false) {
        preparationTask?.cancel(); preparationTask = nil
        MediaCache.shared.removeForegroundVideoDemand(owner: preloadDemandOwner)
        stopPosterCapture()
        interactiveSeekID = nil
        if !resumeInFlight, itemReady, duration > 0 {
            resumeCursor.capture(position: player?.currentTime().seconds ?? currentTime, duration: duration, enabled: resumePosition != nil || retainDuringInterruption, interrupted: interrupted)
        }
        captureProgress(flush: true); onDisplayReady?(false)
        statusObserver = nil; playbackObserver = nil; bufferObserver = nil; durationObserver = nil; seekableObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }; timeObserver = nil
        if let entry = playbackEntry {
            if preserveSession {
                if entry.state == .rootPaused { VideoPlaybackSessions.shared.retainRootPaused(entry, attachment: playbackAttachment) }
                else { VideoPlaybackSessions.shared.retainCovered(entry, attachment: playbackAttachment) }
            }
            else {
                let pool = VideoPlaybackSessions.shared
                let parked = parkTimelineNeighbor && pool.retainTimelineNeighbor(entry, attachment: playbackAttachment)
                if !parked { pool.release(entry, attachment: playbackAttachment) }
                // An offscreen page never keeps a player layer or owns live callbacks.
                playbackEntry = nil; playbackAttachment = nil; boundInputURL = nil; sourceIdentity = nil
            }
        }
        observersAttached = false
        playerStatusEvent = nil; playerSyncEvent = nil; playerReprepareEvent = nil
        if preserveSession {
            holdingRate = false; seekingBase = nil; seekTarget = nil
            return
        }
        actualSourceURL = nil
        nativePresentationCommitted = false; nativeTimeControlStatus = .paused
        playing = false; itemReady = false; readyForDisplay = false; waitingForData = true
        resumeApplied = false; resumeInFlight = false
        currentTime = 0; duration = 0; bufferedRanges = []
        seekRanges = []
        holdingRate = false; seekingBase = nil; seekTarget = nil
    }
    private func updatePreloadDemand(waiting: Bool? = nil) {
        if let entry = playbackEntry, entry.attachment == playbackAttachment {
            VideoPlaybackSessions.shared.setForegroundBusy(entry,
                preparingVideo || resumeInFlight || seekingBase != nil || interactiveSeekID != nil || repairingVideo || holdingRate)
        }
        guard active, scenePhase == .active, let source = actualSourceURL, !source.isFileURL else {
            MediaCache.shared.removeForegroundVideoDemand(owner: preloadDemandOwner); return
        }
        MediaCache.shared.setForegroundVideoDemand(url: source, owner: preloadDemandOwner,
            waiting: !pausedForOverlay && (waiting ?? preparingVideo))
    }
    private func recordMeasuredFirstFrame() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--qa-continuous59"), active,
              !waitingForFirstFrame, !measuredFirstFrame,
              let started = measuredStartupAt else { return }
        measuredFirstFrame = true
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
        let code: DiagnosticCode = actualSourceKind == .network ? .frameReadyNetwork :
            (actualSourceKind == .cache ? .frameReadyCache : .frameReadyLocal)
        LocalDiagnosticsStore.shared.note(area: .playback, code: code, count: Int(min(elapsed * 1_000, 1_000_000_000)))
        #endif
    }
    private func handleFailure(_ item: AVPlayerItem, notificationError: NSError? = nil) {
        guard active, ownsPlaybackLease, !pausedForOverlay, player?.currentItem === item, !failureHandled else { return }
        failureHandled = true; playbackFailed = true; playing = false
        let generation = playbackGeneration
        let address = resolvedURL ?? url
        let initial = Self.failure(item, address: address)
        let failedCacheIdentity = actualSourceKind == .cache ? sourceIdentity : nil
        compatibilityAvailable = (initial == .unknown || initial == .decoderMissing) &&
            (Self.isFormatFailure(notificationError) || Self.isFormatFailure(item.error as NSError?))
        let failedRepaired = repairedSource != nil
        let failedTranscoded = repairedSource?.transcoded == true
        if failedRepaired { bypassRepaired = true; repairedSource = nil }
        let eventCodes = item.errorLog().map { Array($0.events.reversed().lazy.map(\.errorStatusCode).filter { $0 != 0 }.prefix(4)) } ?? []
        let diagnostic = PlaybackFailureDiagnostic(workID: diagnosticWorkID, source: actualSourceKind,
            requestedURL: address, sourceURL: actualSourceURL ?? address, recoveryAttempted: recoveryAttempted,
            error: notificationError ?? (item.error as NSError?), eventStatusCodes: eventCodes)
        if case .http(let status) = initial { LocalDiagnosticsStore.shared.note(area: .playback, code: .http, httpStatus: status, playback: diagnostic) }
        else { LocalDiagnosticsStore.shared.note(area: .playback, code: .playbackFailed, count: recoveryAttempted ? 1 : 0, playback: diagnostic) }
        let decision = VideoRecoveryPolicy.decide(failed: true, failure: initial, recoveryAttempted: recoveryAttempted)
        if decision == .manualRetry {
            recovering = false; repairStage = nil; repairProgress = nil
            recoveryMessage = initial == .http(429) ? "请求较多，请稍后重试" : "登录状态需要确认，请重新登录后重试"
            return
        }
        if decision == .skip { confirmUnavailable(); return }
        recovering = true; recoveryMessage = recoveryAttempted ? "正在确认播放状态…" : "正在更新播放地址并重试…"
        recoveryTask = Task {
            guard !Task.isCancelled, active, ownsPlaybackLease, generation == playbackGeneration else { return }
            defer { if generation == playbackGeneration { recovering = false; repairStage = nil; repairProgress = nil; recoveryTask = nil } }
            if onImageContent != nil && (initial == .unknown || initial == .decoderMissing) {
                // Some site "video" records actually deliver animated GIF/WebP.
                // Probe only this failed, focused item with the image size bound.
                do {
                    let resource = try await MediaCache.shared.imageResource(address)
                    if let lease = resource.lease { await MediaCache.shared.release(lease) }
                    guard !Task.isCancelled, active, generation == playbackGeneration, ownsPlaybackLease else { return }
                    onImageContent?(); return
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, active, generation == playbackGeneration, ownsPlaybackLease else { return }
                    if Self.blocksFailureAdvance(error) {
                        recoveryMessage = error.localizedDescription
                        return
                    }
                }
            }
            if compatibilityAvailable && automaticVideoRepair && !repairAttempted && !failedTranscoded {
                repairAttempted = true
                do {
                    let result = try await MediaRepair.shared.repair(address, offline: diagnosticOffline, forceTranscode: bypassRepaired, diagnosticWorkID: diagnosticWorkID) { stage, fraction in
                        guard !Task.isCancelled, active, generation == playbackGeneration, ownsPlaybackLease else { return }
                        repairStage = stage; repairProgress = fraction
                    }
                    guard !Task.isCancelled, active, generation == playbackGeneration, ownsPlaybackLease else {
                        if let lease = result.lease { await MediaCache.shared.release(lease) }; return
                    }
                    posterRetry += 1
                    recoveryPosition = requestedResume ?? PlaybackResumePolicy.position(position: currentTime, duration: duration)
                    repairedSource = result
                    repairStage = nil; repairProgress = nil; recovering = false
                    playerReprepareEvent = .init(item: ObjectIdentifier(item), generation: generation)
                    return
                } catch is CancellationError { return }
                catch {
                    guard active, generation == playbackGeneration, ownsPlaybackLease else { return }
                    if actualSourceKind == .cache && decision == .recover {
                        // A failed conversion must not swallow the existing
                        // one-time bypass of a broken disposable browser cache.
                        if case MediaRepairError.damaged = error, let failedCacheIdentity {
                            await MediaCache.shared.discardBrokenVideo(address, expected: failedCacheIdentity)
                            repairAttempted = false
                        }
                        repairStage = nil; repairProgress = nil
                    } else {
                        recoveryMessage = (error as? MediaRepairError)?.errorDescription ?? "修复所需文件暂不可用，可重试或尝试兼容播放"
                        if !Self.blocksFailureAdvance(error) { confirmUnavailable() }
                        return
                    }
                }
            }
            if decision == .recover {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, active, ownsPlaybackLease, generation == playbackGeneration else { return }
                    let fresh: URL?
                    if let refreshURL { fresh = try await refreshURL() }
                    else { fresh = address }
                    guard !Task.isCancelled, active, generation == playbackGeneration, ownsPlaybackLease else { return }
                    // A failed retry can move to another work without treating
                    // missing metadata as proof that this work was deleted.
                    guard let fresh else { confirmUnavailable(); return }
                    recoveryPosition = PlaybackResumePolicy.position(position: currentTime, duration: duration)
                    recoveryAttempted = true; resolvedURL = fresh
                    playerReprepareEvent = .init(item: ObjectIdentifier(item), generation: generation)
                } catch {
                    guard !Task.isCancelled, active, generation == playbackGeneration, ownsPlaybackLease else { return }
                    if Self.blocksFailureAdvance(error) { recoveryMessage = "连接或授权暂不可用，请稍后重试" }
                    else { confirmUnavailable() }
                }
            } else {
                var failure = initial
                if initial == .unknown, !address.isFileURL, let status = await Self.probeStatus(address) { failure = .http(status) }
                guard !Task.isCancelled, active, generation == playbackGeneration, ownsPlaybackLease else { return }
                if VideoRecoveryPolicy.decide(failed: true, failure: failure, recoveryAttempted: true) == .skip { confirmUnavailable() }
                else { recoveryMessage = "视频暂时无法播放，可稍后重试或手动划到下一条" }
            }
        }
    }
    private func cancelRepair() {
        #if DEBUG && targetEnvironment(simulator)
        if qaPreparationActive { qaPreparationCancelled = true; return }
        #endif
        recoveryTask?.cancel(); recoveryTask = nil; playbackGeneration += 1
        recovering = false; repairStage = nil; repairProgress = nil
        recoveryMessage = "已停止本次修复，原视频已保留"
    }
    private static func isFormatFailure(_ error: NSError?) -> Bool {
        var value = error
        for _ in 0..<5 {
            guard let error = value else { break }
            if error.domain == AVFoundationErrorDomain,
               [AVError.Code.fileFormatNotRecognized.rawValue, AVError.Code.fileFailedToParse.rawValue,
                AVError.Code.decoderNotFound.rawValue].contains(error.code) { return true }
            value = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    private func openCompatibility() {
        guard active, playbackFailed, compatibilityAvailable else { return }
        presentCompatibility()
    }

    private func presentCompatibility() {
        guard presentationLease?.finished != true else { return }
        stopPosterCapture()
        recoveryTask?.cancel(); recoveryTask = nil; playbackGeneration += 1; recovering = false
        nativeRetrySuspended = true; player?.pause()
        let address = resolvedURL ?? url
        let generation = playbackGeneration
        preparationTask?.cancel()
        preparationTask = Task { @MainActor in
            let lease = address.isFileURL ? await MediaCache.shared.leaseFile(address) : await MediaCache.shared.leaseCached(address, video: true)
            guard presentationLease?.finished != true, !Task.isCancelled, active, generation == playbackGeneration else {
                if let lease { await MediaCache.shared.release(lease) }; return
            }
            if let old = compatibilityLease { Task { await MediaCache.shared.release(old) } }
            compatibilityLease = lease
            let source = lease?.file ?? address
            let kind: PlaybackDiagnosticSource = lease != nil && !address.isFileURL ? .cache :
                (source.isFileURL ? (diagnosticOffline ? .offline : .local) : .network)
            compatibilityRequest = .init(requestedURL: address, sourceURL: source, sourceKind: kind,
                workID: diagnosticWorkID, initialPosition: compatibilityPosition ?? resumePosition)
            preparationTask = nil
        }
    }
    private func compatibilityDiagnostic(_ request: CompatibilityRequest, code: Int?) -> PlaybackFailureDiagnostic? {
        PlaybackFailureDiagnostic(workID: request.workID, source: request.sourceKind,
            requestedURL: request.requestedURL, sourceURL: request.sourceURL, recoveryAttempted: true,
            error: code.map { NSError(domain: "WebKitMediaErrorDomain", code: $0) }, eventStatusCodes: [], engine: .webKit)
    }
    private func confirmUnavailable() {
        guard active, !pausedForOverlay else { return }
        recovering = false; recoveryMessage = "视频暂时无法播放"
        onConfirmedUnavailable?()
    }
    private static func blocksFailureAdvance(_ error: Error) -> Bool {
        switch error {
        case ClientError.signedOut, ClientError.accountChanged, ClientError.loadingSite: return true
        case ClientError.http(let status), MediaDownloadError.http(let status): return status == 401 || status == 429
        default: return false
        }
    }
    private static func failure(_ item: AVPlayerItem, address: URL) -> VideoFailure {
        if address.isFileURL, let error = item.error as NSError?,
           (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
           (error.domain == NSPOSIXErrorDomain && error.code == 2) { return .localMissing }
        if let status = item.errorLog()?.events.reversed().map(\.errorStatusCode).first(where: { (400...599).contains($0) }) { return .http(status) }
        var error = item.error as NSError?
        for _ in 0..<5 {
            guard let current = error else { break }
            if current.domain == NSURLErrorDomain { return .network }
            if current.domain == AVFoundationErrorDomain, current.code == AVError.Code.decoderNotFound.rawValue { return .decoderMissing }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unknown
    }
    private static func probeStatus(_ address: URL) async -> Int? {
        guard address.scheme == "https" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: address); request.httpMethod = "HEAD"
        do { let (_, response) = try await session.data(for: request); return (response as? HTTPURLResponse)?.statusCode }
        catch { return nil }
    }
    private func seek(_ delta: Double, _ phase: MediaPanPhase) {
        if phase == .cancelled { cancelSeek(); return }
        guard canScrub, let player else { return }
        #if DEBUG && targetEnvironment(simulator)
        if phase == .began { qaSeekStartCount += 1 }
        #endif
        if phase == .began { interactiveSeekID = nil; seekingBase = max(0, player.currentTime().seconds); player.pause() }
        guard let base = seekingBase else { return }
        previewSeek(base + delta / 10, phase: phase)
    }
    private func scrub(_ fraction: Double, _ phase: MediaPanPhase) {
        if phase == .cancelled { cancelSeek(); return }
        guard canScrub, let player, let target = VideoSeekMath.time(fraction: fraction, duration: duration) else { return }
        #if DEBUG && targetEnvironment(simulator)
        if phase == .began { qaSeekStartCount += 1 }
        #endif
        if phase == .began { interactiveSeekID = nil; seekingBase = max(0, player.currentTime().seconds); player.pause() }
        guard seekingBase != nil else { return }
        previewSeek(target, phase: phase)
    }
    private func previewSeek(_ requested: Double, phase: MediaPanPhase) {
        guard let target = VideoSeekMath.target(seconds: requested, duration: duration, ranges: seekRanges) else { cancelSeek(); return }
        seekTarget = target
        guard phase == .ended else { return }
        guard let value = player, let item = value.currentItem,
              let plan = VideoSeekMath.interactiveTickPlan(seconds: target, duration: duration, ranges: seekRanges) else { cancelSeek(); return }
        let generation = playbackGeneration
        let operation = UUID()
        seekingBase = nil; seekTarget = nil; interactiveSeekID = operation
        // Browsing seeks allow at most 50ms within one continuous seekable
        // interval. Exact restore remains in applyResume; it has a different contract.
        value.seek(to: CMTime(value: plan.targetTicks, timescale: plan.timescale),
                   toleranceBefore: CMTime(value: plan.toleranceBeforeTicks, timescale: plan.timescale),
                   toleranceAfter: CMTime(value: plan.toleranceAfterTicks, timescale: plan.timescale)) { finished in
            Task { @MainActor in
                #if DEBUG && targetEnvironment(simulator)
                qaSeekEvents.callbacks += 1; qaSeekEvents.lastFinished = finished
                #endif
                guard interactiveSeekID == operation, player === value, value.currentItem === item,
                      generation == playbackGeneration, ownsPlaybackLease else { return }
                #if DEBUG && targetEnvironment(simulator)
                qaSeekEvents.commits += 1
                #endif
                interactiveSeekID = nil
                if finished {
                    let actual = value.currentTime().seconds
                    if actual.isFinite && actual >= 0 { currentTime = actual; captureProgress(flush: true) }
                    else { LocalDiagnosticsStore.shared.note(area: .playback, code: .seekFailed) }
                }
                else { LocalDiagnosticsStore.shared.note(area: .playback, code: .seekFailed) }
                playerSyncEvent = .init(item: ObjectIdentifier(item), generation: generation)
            }
        }
        // An interactive jump must not wait for a seek completion before accepting
        // play/pause intent. Only exact history restoration owns resumeInFlight.
        syncPlayback()
    }
    private func cancelSeek() {
        seekingBase = nil; seekTarget = nil; syncPlayback()
    }
    private func holdRate(_ held: Bool) {
        #if DEBUG && targetEnvironment(simulator)
        if held { qaRateHoldCount += 1 }
        #endif
        if held { wasPlayingBeforeHold = playing; holdingRate = true }
        else { holdingRate = false; playing = wasPlayingBeforeHold }
        syncPlayback()
    }
}

@MainActor func videoPlaybackKey(owner: UUID, scope: String, workID: Int, address: URL, source: URL,
                                 rootSlot: UUID? = nil, lease: MediaFileLease? = nil) -> VideoPlaybackSessionKey {
    let revision = lease.map { lease in
        let identity = lease.identity
        return "\(identity.size):\(identity.inode):\(identity.created)"
    }
    return .init(owner: owner, scope: scope, workID: workID, requestedURL: address,
                 sourceURL: source, sourceRevision: revision, rootSlot: rootSlot,
                 cacheGeneration: lease?.generation ?? MediaCache.shared.repairGeneration)
}
