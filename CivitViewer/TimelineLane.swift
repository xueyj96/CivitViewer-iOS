import SwiftUI
import UIKit

private struct TimelineGestureFrameKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

private extension View {
    func timelineGestureFrame(in space: Namespace.ID) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: TimelineGestureFrameKey.self, value: [geometry.frame(in: .named(space))])
        })
    }
}

// Keep gesture feedback updates out of the media pager's view hierarchy.
@MainActor private final class TimelineEdgePreview: ObservableObject {
    struct Value {
        let title: String
        let translation: Double
        var ready: Bool { abs(translation) >= ScreenEdgeGesture.commitDistance }
        var offset: CGFloat {
            let distance = abs(translation)
            let threshold = ScreenEdgeGesture.commitDistance
            let resisted = distance <= threshold ? distance : threshold + (distance - threshold) * 0.28
            return CGFloat(translation < 0 ? -resisted : resisted)
        }
    }
    @Published private(set) var value: Value?

    func update(title: String?, translation: Double) {
        let next = title.map { Value(title: $0, translation: translation) }
        if next?.ready == true, value?.ready != true { UISelectionFeedbackGenerator().selectionChanged() }
        value = next
    }

    func clear(animated: Bool = false) {
        guard value != nil else { return }
        withAnimation(animated ? .easeOut(duration: 0.18) : nil) { value = nil }
    }
}

private struct TimelineEdgeMotion: ViewModifier {
    @ObservedObject var preview: TimelineEdgePreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.offset(x: reduceMotion ? 0 : (preview.value?.offset ?? 0))
    }
}

private struct TimelineEdgePreviewView: View {
    @ObservedObject var preview: TimelineEdgePreview
    var body: some View {
        if let value = preview.value {
            HStack(spacing: 8) {
                if value.translation > 0 { Image(systemName: "chevron.left") }
                VStack(spacing: 4) {
                    Text(value.title).font(.headline)
                    Text(value.ready ? "松开切换" : "继续拖动").font(.caption2)
                }
                if value.translation < 0 { Image(systemName: "chevron.right") }
            }.foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 13)
                .background(.black.opacity(0.78), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(value.ready ? 0.65 : 0.2)))
                .scaleEffect(value.ready ? 1.05 : 0.92)
                .opacity(min(1, abs(value.translation) / 30))
                .animation(.easeOut(duration: 0.12), value: value.ready)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: value.translation < 0 ? .trailing : .leading)
                .padding(.horizontal, 18).transition(.opacity)
        }
    }
}

struct TimelineLane: View {
    private enum ToolDestination: Hashable { case account, history, followingAuthors }
    private enum EdgeDestination {
        case source(Bool), media(MediaKind)
        var title: String {
            switch self {
            case .source(let following): following ? "关注" : "推荐"
            case .media(let kind): kind.title
            }
        }
    }
    var isVisible: Bool
    let followed: Bool
    var sourceSelection: Binding<Bool>?
    var presentation: TimelinePresentation = .stream
    var togglePresentation: (() -> Void)?
    var restoreInlineOrientation: (() -> Void)?
    var restartRequest = 0
    var topRequest = 0
    @EnvironmentObject private var session: SiteSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.ordinaryColorScheme) private var ordinaryColorScheme
    @Environment(\.overlaidTabBarHeight) private var tabBarOverlap
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var chrome = ViewingChromeController.shared
    @AppStorage("mediaPrefetchCount") private var mediaPrefetchCount = 6
    @StateObject private var model: TimelineModel
    @State private var showFilter = false
    @State private var presetRequest: FilterPresetRequest?
    @State private var pendingPreset: (request: FilterPresetRequest, filter: FeedFilter)?
    @State private var toolDestination: ToolDestination?
    @State private var creator: CreatorRoute?
    @State private var authorHeaderRoute = NativeHeaderRoute()
    @State private var navigationVisible = true
    @State private var edgePreview = TimelineEdgePreview()
    @State private var handledRestartRequest = 0
    @State private var handledTopRequest = 0
    @State private var gridAnchor: Int?
    @State private var gridViewer: MediaItem?
    @Namespace private var gestureSpace
    @State private var overlayFrames: [CGRect] = []
    @State private var continuationAction: Task<Void, Never>?
    @State private var continuationActionID: UUID?
    private var leavingInlinePlayback: Bool {
        creator != nil || toolDestination != nil || showFilter || presetRequest != nil
    }
    private var laneVisible: Bool { isVisible && (navigationVisible || gridViewer != nil) }
    private var preloadReserve: Int { max(6, [3, 6, 10].contains(mediaPrefetchCount) ? mediaPrefetchCount : 6) }
    private var continuationState: FeedContinuationState {
        if model.restoreState.continuationUnavailable {
            return .failed(.stalled(message: "保存的续页位置当前不可用；原作品仍保留，请重新获取当前结果。"))
        }
        return feed.continuationState
    }
    #if DEBUG && targetEnvironment(simulator)
    @State private var qaMediaActive = false
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private let qaController: ResumePromptQAController?
    #endif
    private struct LoadKey: Equatable {
        let visible: Bool
        let request: FeedStoreRequestKey
        let restoring: Bool
    }
    private var feed: FeedStore { model.feed }
    private var chromeBottomSpacing: CGFloat { verticalSizeClass == .compact ? 0 : FloatingPageChrome.bottomInset }
    private var chromeHeight: CGFloat { FloatingPageChrome.controlHeight + FloatingPageChrome.topInset + chromeBottomSpacing }
    private var floatingHeader: Bool {
        presentation == .stream && isVisible && !feed.items.isEmpty &&
        feed.requestKey?.identity == session.feedIdentity && !(followed && session.account == nil)
    }
    private var filter: FeedFilter { model.filter }
    private var hasActiveFilter: Bool {
        filter != filter.resetting(in: followed ? .following : .discovery)
    }
    private var lane: HistoryLane { model.lane }
    private var historyContext: HistoryContext? { history.context(ownerID: session.tagLibraryOwnerID) }
    private var loadKey: LoadKey {
        .init(visible: laneVisible && scenePhase == .active,
              request: .init(identity: session.feedIdentity, filter: filter, source: model.source),
              restoring: model.restoreState.isBusy)
    }
    private var filterBinding: Binding<FeedFilter> { .init(get: { model.filter }, set: model.selectFilter) }
    private var kindBinding: Binding<MediaKind> {
        .init(get: { filter.effectiveKind }, set: { model.selectFilter(filter.selecting(kind: $0)) })
    }
    private var tagSummary: String {
        let tags = blocklist.names.isEmpty ? "" : "标签屏蔽隐藏 \(feed.hiddenByTags) 项，另有 \(feed.unverifiedTags) 项标签待核实、暂不展示。"
        let duration = filter.videoDurationRange == nil ? "" : "时长范围隐藏 \(feed.hiddenByDuration) 项；\(feed.unverifiedDuration) 项时长未知，暂不展示。仅覆盖已查结果，可继续加载。"
        return tags + duration
    }
    init(isVisible: Bool, followed: Bool, sourceSelection: Binding<Bool>? = nil,
         presentation: TimelinePresentation = .stream, togglePresentation: (() -> Void)? = nil, restoreInlineOrientation: (() -> Void)? = nil,
         restartRequest: Int = 0, topRequest: Int = 0) {
        self.isVisible = isVisible; self.followed = followed; self.sourceSelection = sourceSelection
        self.presentation = presentation; self.togglePresentation = togglePresentation; self.restoreInlineOrientation = restoreInlineOrientation
        self.restartRequest = restartRequest; self.topRequest = topRequest
        #if DEBUG && targetEnvironment(simulator)
        self.qaController = nil
        #endif
        #if DEBUG && targetEnvironment(simulator)
        _model = StateObject(wrappedValue: TimelineModel(followed: followed,
            filter: AutoContinuationQA.enabled ? AutoContinuationQA.filter : nil,
            dismissals: ViewportAuditQA.enabled ? ViewportAuditQA.dismissals() : TimelineCheckpointDismissals()))
        #else
        _model = StateObject(wrappedValue: TimelineModel(followed: followed))
        #endif
    }
    #if DEBUG && targetEnvironment(simulator)
    init(isVisible: Bool, followed: Bool, sourceSelection: Binding<Bool>? = nil,
         presentation: TimelinePresentation = .stream, togglePresentation: (() -> Void)? = nil, restoreInlineOrientation: (() -> Void)? = nil,
         restartRequest: Int = 0, topRequest: Int = 0, qaController: ResumePromptQAController?) {
        self.isVisible = isVisible; self.followed = followed; self.sourceSelection = sourceSelection
        self.presentation = presentation; self.togglePresentation = togglePresentation; self.restoreInlineOrientation = restoreInlineOrientation
        self.restartRequest = restartRequest; self.topRequest = topRequest; self.qaController = qaController
        _model = StateObject(wrappedValue: TimelineModel(followed: followed,
            filter: AutoContinuationQA.enabled ? AutoContinuationQA.filter : nil,
            dismissals: qaController == nil ? (ViewportAuditQA.enabled ? ViewportAuditQA.dismissals() : TimelineCheckpointDismissals()) : ResumePromptQA.dismissals()))
    }
    #endif

    private var timelineTools: some View {
        Menu {
            Button { openTool(.history) } label: {
                Label("最近浏览", systemImage: "clock.arrow.circlepath")
            }
            if let togglePresentation {
                Button(action: togglePresentation) {
                    Label(presentation == .stream ? "双列网格" : "逐条浏览",
                          systemImage: presentation == .stream ? "square.grid.2x2" : "rectangle.portrait.on.rectangle.portrait")
                }
            }
            Button { chrome.endInlinePlayer(); showFilter = true } label: {
                Label("浏览条件", systemImage: "line.3.horizontal.decrease")
            }
            Button {
                chrome.endInlinePlayer()
                presetRequest = .init(session: session, scope: followed ? .following : .recommendation, filter: filter)
            } label: {
                Label("已存条件", systemImage: "list.bullet.rectangle")
            }
            if followed {
                Divider()
                Button { openTool(.followingAuthors) } label: {
                    Label("我的关注", systemImage: "person.2")
                }
            }
        } label: {
            Group {
                if model.restoreState.isRefreshing {
                    ProgressView().controlSize(.small).tint(floatingHeader ? .white : .primary)
                } else {
                    FloatingPageIcon(symbol: "ellipsis")
                }
            }
        }
        .menuOrder(.fixed)
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true, overMedia: floatingHeader))
        .accessibilityLabel("时间线工具")
        .accessibilityValue((presentation == .stream ? "信息流" : "双列网格") + (hasActiveFilter ? "，筛选已启用" : "，默认筛选"))
        .accessibilityIdentifier("timeline.tools")
    }

    private var timelineHeaderControls: some View {
        let segmentCount = sourceSelection == nil ? 1 : 2
        return HStack(spacing: FloatingPageChrome.groupInset) {
            Button { openTool(.account) } label: {
                FloatingPageIcon(symbol: session.account == nil ? "person.crop.circle" : "person.crop.circle.fill")
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true, overMedia: floatingHeader))
            .accessibilityLabel("账号与设置")
            .accessibilityIdentifier("timeline.account")
            LazyVGrid(columns: FloatingPageChrome.equalColumns(segmentCount, gap: 0), spacing: 0) {
                if let sourceSelection {
                    FloatingSegmentedControl(title: "时间线来源", selection: sourceSelection, options: [true, false],
                                             optionTitle: { $0 ? "关注" : "推荐" }, identifier: "timeline.source",
                                             overMedia: floatingHeader, nested: true, showsTrack: false)
                }
                FloatingMediaPicker(title: "媒体类型", selection: kindBinding, identifier: "timeline.media-kind",
                                    overMedia: floatingHeader, nested: true, showsTrack: false)
            }
            .environment(\.colorScheme, floatingHeader ? .dark : ordinaryColorScheme)
            .frame(maxWidth: .infinity)
            .background { FloatingSegmentedTrack(nested: true, overMedia: floatingHeader) }
            timelineTools
        }
        .floatingPagePanelControls(overMedia: floatingHeader)
        .foregroundStyle(floatingHeader ? Color.white : Color.primary)
        .padding(.horizontal, FloatingPageChrome.groupInset)
    }

    private var timelineHeader: some View {
        let inset = FloatingPageChrome.surfaceInset
        let appearance = HeaderAppearance(
            controls: AnyView(timelineHeaderControls.offset(y: -inset)
                .environment(\.colorScheme, floatingHeader ? .dark : ordinaryColorScheme)),
            firstRowHeight: FloatingPageChrome.surfaceHeight,
            colorScheme: floatingHeader ? .dark : ordinaryColorScheme,
            surfaceColor: floatingHeader ? .black : AppTheme.pageBackground(for: ordinaryColorScheme),
            borderColor: floatingHeader ? PlaybackChrome.panelStroke : Color.primary.opacity(0.10)
        )
        return timelineHeaderControls
            .background {
                FloatingPagePanelSurface(overMedia: floatingHeader)
                    .padding(.vertical, inset)
            }
            .tabHeaderSurface(appearance, verticalInset: inset, enabled: !chrome.hidden)
        .frame(maxWidth: .infinity)
        #if DEBUG && targetEnvironment(simulator)
        .background(GeometryReader { geometry in
            if VisualControlsQA.enabled {
                let frame = geometry.frame(in: .global)
                let rowValue = "x=\(frame.minX);y=\(frame.minY);w=\(frame.width);h=\(frame.height)"
                let filterValue = "kind=\(filter.effectiveKind.rawValue);sort=\(filter.sort);period=\(filter.period);model=\(filter.baseModel);pg=\(filter.onlyPG)"
                VStack {
                    Text(rowValue)
                        .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("qa.controls.row").accessibilityValue(rowValue)
                    Text(filterValue)
                        .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("qa.controls.filter").accessibilityValue(filterValue)
                }
            }
        }.allowsHitTesting(false))
        #endif
        .padding(.horizontal, FloatingPageChrome.pageInset)
        .frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight)
        .padding(.top, FloatingPageChrome.topInset)
        .padding(.bottom, chromeBottomSpacing)
        .foregroundStyle(floatingHeader ? Color.white : Color.primary)
        .background(floatingHeader ? Color.clear : Color(uiColor: .systemBackground))
        .viewingChromeHidden(chrome.hidden)
    }

    private var laneCanvas: some View {
        ZStack(alignment: .top) {
            if presentation == .stream && !feed.items.isEmpty { Color.black }
            else { Color(uiColor: .systemBackground) }
            if followed && session.account == nil {
                ContentUnavailableView { Label("登录后刷关注作品", systemImage: "person.2") } description: {
                    Text("查看你在 Civitai 关注的作者发布的图片和视频。")
                } actions: { Button("使用 Google 登录") { session.openLogin() }.buttonStyle(AppActionButtonStyle(tone: .accent)) }
            } else if feed.requestKey?.identity == session.feedIdentity && !feed.items.isEmpty {
                if presentation == .grid {
                    MediaGrid(feed: feed, continuationState: continuationState, emptyDescription: filter.summary,
                              anchor: $gridAnchor,
                              scrollRequest: model.focusRequest + model.queueRevision, loadsOnAppearance: false,
                              isVisible: deckIsVisible && gridViewer == nil,
                              automaticLoadingAllowed: model.automaticLoadingAllowed,
                              loadMoreAutomatically: { await model.nextAutomatically(session: session) },
                              refreshFromStart: { await model.restartFromStart(session: session) }) { item in
                        model.focused = item.id; gridViewer = item
                    } loadMore: { await model.next(session: session) }
                        .padding(.top, chromeHeight + 4)
                        .avoidOverlaidTabBar()
                } else {
                MediaDeck(items: feed.items, focused: $model.focused, focusRequest: model.focusRequest,
                          queueRevision: model.queueRevision,
                          playbackSuspended: model.restoreState.isRefreshing || showFilter || presetRequest != nil,
                          automaticLoadingAllowed: model.automaticLoadingAllowed, loadsPageOnAppearance: false,
                          isVisible: deckIsVisible, coveredByNavigation: isVisible && (showFilter || presetRequest != nil),
                          continuationState: continuationState,
                          loadMoreAutomatically: { await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve) },
                          refreshFromStart: { await model.restartFromStart(session: session) },
                          restartRetryAvailableAt: feed.restartRetryAvailableAt,
                          bottomBarInset: tabBarOverlap, inlinePlayback: true,
                          continuationTopInset: chromeHeight,
                          gestureTopExclusion: chrome.hidden ? 0 : chromeHeight,
                          gestureExcludedFrames: chrome.hidden ? [] : overlayFrames,
                          onEdgeSwipe: switchByEdge, onEdgeDrag: showEdgeDrag, onAuthor: openCreator, onDetailsVisibility: { feed.setTagPolicyDeferred($0) },
                          historyCheckpoint: model.checkpoint, resumePositions: model.resumePositions) {
                    await model.nextAndFillUpcoming(session: session, minimumUpcoming: preloadReserve)
                }
                .modifier(TimelineEdgeMotion(preview: edgePreview))
                }
            } else if deckIsVisible {
                VStack(spacing: 14) {
                    FeedContinuationStatusView(state: continuationState, empty: true,
                        performing: continuationAction != nil,
                        restartRetryAvailableAt: feed.restartRetryAvailableAt,
                        retry: { startContinuationAction { await model.next(session: session) } },
                        restart: { startContinuationAction { await model.restartFromStart(session: session) } })
                    if continuationState == .ended || continuationState.failure != nil {
                        Text(filter.summary + "。" + tagSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if floatingHeader && !chrome.hidden {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.54), location: 0),
                    .init(color: .black.opacity(0.25), location: 0.56),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: chromeHeight + 34)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            TimelineEdgePreviewView(preview: edgePreview)
                .viewingChromeHidden(chrome.hidden).allowsHitTesting(false).accessibilityHidden(true)
            // Keep both feeds alive, but put only the active lane's controls in the view hierarchy.
            if isVisible { timelineHeader }
            if let savedCheckpoint = model.resumeCandidate {
                HStack(spacing: 8) {
                    Button { Task { await model.restore(savedCheckpoint, session: session) } } label: {
                        Label("接着看 · 上次" + lane.title, systemImage: "play.circle")
                            .font(.caption.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 9)
                    }.disabled(model.restoreState.isBusy).accessibilityIdentifier("timeline.resume")
                    Button { model.dismissPrompt() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 44, height: 44)
                    }.accessibilityLabel("关闭接着看提示").accessibilityIdentifier("timeline.resume.close")
                }.foregroundStyle(.white).background(.black.opacity(0.68), in: Capsule())
                    .timelineGestureFrame(in: gestureSpace).padding(.top, chromeHeight - 2).viewingChromeHidden(chrome.hidden)
            }
            if let notice = model.notice, notice.isError {
                HStack(spacing: 10) {
                    Text(notice.text).font(.caption).lineLimit(notice.isError ? 5 : 3)
                        .accessibilityIdentifier("timeline.notice.text")
                    if notice.recovery == .restartFromStart {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            StatusReloadButton { model.requestRestartFromStart(session: session) }
                                .environment(\.colorScheme, .dark)
                                .disabled(model.restoreState.isRefreshing || (feed.restartRetryAvailableAt.map { $0 > context.date } ?? false))
                                .accessibilityIdentifier("timeline.notice.retry")
                        }.fixedSize()
                    }
                    Button { model.clearMessage(id: notice.id) } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 44, height: 44)
                    }.accessibilityLabel("关闭提示").accessibilityIdentifier("timeline.notice.close")
                }.padding(.leading, 12).padding(.trailing, 2).padding(.vertical, 4)
                    .foregroundStyle(.white).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { if !notice.isError { model.clearMessage(id: notice.id) } })
                    .accessibilityElement(children: .contain).accessibilityIdentifier("timeline.notice")
                    .accessibilityValue(notice.isError ? "错误，等待处理" : "约两秒半后收起，可点按关闭")
                    .timelineGestureFrame(in: gestureSpace)
                    .padding(.horizontal, 16).padding(.top, chromeHeight).viewingChromeHidden(chrome.hidden)
            }
        }
    }

    private var presentedLane: some View {
        laneCanvas.coordinateSpace(name: gestureSpace)
        .onPreferenceChange(TimelineGestureFrameKey.self) { overlayFrames = $0 }
        .background((floatingHeader ? Color.black : Color(uiColor: .systemBackground)).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showFilter) {
            FilterView(filter: filterBinding, context: followed ? .following : .discovery)
        }
        .navigationDestination(item: $presetRequest) { request in
            FilterPresetPage(request: request) { snapshot in pendingPreset = (request, snapshot.filter) }
        }
        .onChange(of: presetRequest?.id) { _, value in
            if value == nil { finishPresetPage() }
        }
        .mediaCover(item: $gridViewer) { opening in
            FeedMediaViewer(items: feed.items, focused: $model.focused, initialID: opening.id,
                            focusRequest: model.focusRequest, queueRevision: model.queueRevision,
                            playbackSuspended: model.restoreState.isRefreshing, automaticLoadingAllowed: model.automaticLoadingAllowed,
                            continuationState: continuationState,
                          loadMoreAutomatically: { await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve) },
                            refreshFromStart: { await model.restartFromStart(session: session) },
                            restartRetryAvailableAt: feed.restartRetryAvailableAt,
                            historyCheckpoint: model.checkpoint, resumePositions: model.resumePositions,
                            onDetailsVisibility: { feed.setTagPolicyDeferred($0) }, onClose: { gridViewer = nil }) {
                await model.nextAndFillUpcoming(session: session, minimumUpcoming: preloadReserve)
            }
        }
        .nativeHeaderRouteBoundary(authorHeaderRoute, isPresented: false)
        .navigationDestination(item: $creator) { route in
            CreatorView(creator: route.creator, initialKind: route.kind)
                .nativeHeaderRouteBoundary(authorHeaderRoute, isPresented: true)
        }
        .onChange(of: creator != nil) { _, showsAuthor in
            if !showsAuthor { authorHeaderRoute.dismissed(animate: false) }
        }
        .navigationDestination(item: $toolDestination) { destination in
            Group {
                switch destination {
                case .account: SettingsView()
                case .history: BrowsingHistoryView()
                case .followingAuthors: FollowingView()
                }
            }
        }
    }

    var body: some View {
        presentedLane.onChange(of: presentation) { _, layout in
            if layout == .grid { gridAnchor = model.focused }
        }
        .onChange(of: gridAnchor) { _, id in
            if presentation == .grid && gridViewer == nil && isVisible, let id { model.focused = id }
        }
        .onChange(of: model.focusRequest) { _, _ in if presentation == .grid { gridAnchor = model.focused } }
        .onChange(of: model.queueRevision) { _, _ in
            if presentation == .grid { gridAnchor = model.focused }
            requestAppearanceFill()
        }
        .onChange(of: presentation) { _, _ in requestAppearanceFill() }
        .onChange(of: mediaPrefetchCount) { _, _ in requestAppearanceFill() }
        .onChange(of: feed.items.map(\.id)) { _, _ in requestAppearanceFill() }
        .onChange(of: gridViewer) { _, value in
            model.setVisible(isVisible && scenePhase == .active && (navigationVisible || value != nil))
        }
        .task(id: historyContext) { model.bindHistory(ownerID: session.tagLibraryOwnerID) }
        .task(id: loadKey) {
            #if DEBUG && targetEnvironment(simulator)
            if qaController != nil && !ResumePromptQA.scenario.hasPrefix("restart-") {
                model.setVisible(laneVisible && scenePhase == .active)
                return
            }
            #endif
            await model.activate(session: session, visible: laneVisible && scenePhase == .active, blockedTags: blocklist.names)
            if presentation == .stream, model.shouldFillOnAppearance {
                await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve)
            }
        }
        .onChange(of: restartRequest) { _, _ in
            handlePendingRestart()
        }
        .onChange(of: topRequest) { _, _ in handlePendingTop() }
        .onChange(of: blocklist.names) { _, names in model.applyBlockedTags(names); requestAppearanceFill() }
        .onChange(of: session.following) { _, ids in Task { await model.followingChanged(ids, session: session) } }
        .onChange(of: leavingInlinePlayback) { _, leaving in
            if leaving && isVisible { restoreInlineOrientation?() }
        }
        .onChange(of: isVisible) { _, visible in
            model.setVisible(laneVisible && scenePhase == .active)
            if !visible { cancelContinuationAction(); edgePreview.clear() }
            if visible { handlePendingTop(); handlePendingRestart() }
            else { handledTopRequest = topRequest; handledRestartRequest = restartRequest }
        }
        .onAppear {
            navigationVisible = true; model.setVisible(isVisible && scenePhase == .active)
            #if DEBUG && targetEnvironment(simulator)
            if let qaController {
                qaController.setMediaActive = { qaMediaActive = $0 }
                qaController.attach(model: model, session: session, history: history)
            }
            #endif
            handlePendingTop(); handlePendingRestart()
        }
        .onDisappear {
            cancelContinuationAction()
            edgePreview.clear()
            navigationVisible = false; model.setVisible(isVisible && gridViewer != nil)
            #if DEBUG && targetEnvironment(simulator)
            qaController?.visibilityChanged(isVisible && gridViewer != nil)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelContinuationAction(); edgePreview.clear() }
            model.setVisible(laneVisible && phase == .active)
        }
    }

    private func requestAppearanceFill() {
        guard presentation == .stream, model.shouldFillOnAppearance else { return }
        Task { await model.fillUpcoming(session: session, minimumUpcoming: preloadReserve) }
    }
    private func handlePendingTop() {
        guard isVisible && navigationVisible, topRequest > handledTopRequest else { return }
        handledTopRequest = topRequest
        model.scrollToStart()
    }

    private func handlePendingRestart() {
        guard isVisible && navigationVisible, restartRequest > handledRestartRequest else { return }
        handledRestartRequest = restartRequest
        model.setVisible(true)
        model.requestRestartFromStart(session: session)
    }

    private func startContinuationAction(_ action: @escaping () async -> Void) {
        guard continuationAction == nil, laneVisible, scenePhase == .active else { return }
        let owner = UUID(); continuationActionID = owner
        continuationAction = Task {
            await action()
            guard continuationActionID == owner else { return }
            continuationAction = nil; continuationActionID = nil
        }
    }
    private func cancelContinuationAction() {
        continuationAction?.cancel(); continuationAction = nil; continuationActionID = nil
    }

    private var deckIsVisible: Bool {
        let currentPageIsTimeline = isVisible && navigationVisible && creator == nil && toolDestination == nil && !showFilter && presetRequest == nil
        #if DEBUG && targetEnvironment(simulator)
        if qaController != nil { return currentPageIsTimeline && qaMediaActive }
        #endif
        return currentPageIsTimeline
    }

    private func openTool(_ destination: ToolDestination) {
        chrome.endInlinePlayer()
        toolDestination = destination
    }

    private func finishPresetPage() {
        guard let pending = pendingPreset else { return }
        pendingPreset = nil
        guard pending.request.identity == session.feedIdentity,
              pending.request.ownerID == session.tagLibraryOwnerID else { return }
        model.selectFilter(pending.filter)
    }

    private func openCreator(_ route: CreatorRoute) {
        authorHeaderRoute.preparePresentation()
        chrome.endInlinePlayer()
        creator = route
    }

    private func edgeDestination(in region: MediaEdgeRegion) -> EdgeDestination? {
        switch region {
        case .upper:
            guard sourceSelection != nil else { return nil }
            return .source(!followed)
        case .lower:
            return .media(filter.effectiveKind == .video ? .image : .video)
        }
    }

    private func switchByEdge(_: Int, _ region: MediaEdgeRegion) {
        guard deckIsVisible, scenePhase == .active, let destination = edgeDestination(in: region) else { return }
        switch destination {
        case .source(let following): sourceSelection?.wrappedValue = following
        case .media(let kind): model.selectFilter(filter.selecting(kind: kind))
        }
    }

    private func showEdgeDrag(_ delta: Double, _ phase: MediaPanPhase, _ region: MediaEdgeRegion) {
        switch phase {
        case .began, .changed:
            let destination = abs(delta) > 5 ? edgeDestination(in: region) : nil
            edgePreview.update(title: destination?.title, translation: delta)
        case .ended: edgePreview.clear(animated: abs(delta) < ScreenEdgeGesture.commitDistance)
        case .cancelled: edgePreview.clear(animated: true)
        }
    }
}

