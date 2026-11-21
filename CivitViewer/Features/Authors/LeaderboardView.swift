import SwiftUI
import Observation

struct LeaderboardView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var board: Board = .seasonal
    @State private var recent: RecentPublication = .any
    @State private var openedAuthor: CreatorRoute?
    var body: some View {
        SegmentedContentPager(selection: board, options: Board.allCases, identifier: "leaderboard.board", isolatesNativeLists: true) { value, active in
            LeaderboardList(board: value, visible: active, selected: value == board, recent: recent, onOpen: {
                #if DEBUG && targetEnvironment(simulator)
                let started = TransitionCostQA174.start
                defer { TransitionCostQA174.record("leaderboard.authorTap.preparation", started) }
                #endif
                openedAuthor = CreatorRoute(creator: $0, kind: .image).preparing(session: session, blockedTags: TagBlocklist.shared.names)
            })
        }
        .floatingPageBar("leaderboard.top-bar") {
            HStack(spacing: FloatingPageChrome.groupInset) {
                FloatingSegmentedControl(title: "作者榜类型", selection: $board, options: Board.allCases,
                                         optionTitle: { $0.title }, identifier: "leaderboard.board")
                AppValueSelector(title: "作品更新时间", selection: $recent,
                                 options: RecentPublication.allCases, name: { $0.title }) {
                    AppFilterLabel(title: recent.title, symbol: "calendar")
                }
                .accessibilityLabel("作品更新：" + recent.title)
                .accessibilityIdentifier("leaderboard.recent-filter")
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .ordinaryAppearance()
        .navigationDestination(item: $openedAuthor) { CreatorView(creator: $0.creator, initialKind: $0.kind, preparation: $0.preparation) }
        .edgeSwitchingSegments(selection: $board, options: Board.allCases, identifier: "leaderboard.board", reservesPageEdges: false, leftEdge: false, rightEdge: false, centerSwipe: true)
    }
}

// Both boards retain their mounted list and original rank positions.
private struct LeaderboardList: View {
    let board: Board
    let visible: Bool
    let selected: Bool
    let recent: RecentPublication
    let onOpen: (Creator) -> Void
    @Environment(\.rootPageParticipation) private var rootParticipation
    @Environment(\.segmentedPageMotion) private var segmentMotion
    @EnvironmentObject private var session: SiteSession
    @State private var entries: [LeaderboardEntry] = []
    @State private var loading = false
    @State private var loadID: UUID?
    @State private var loaded = false
    @State private var error: String?
    @State private var showUnknown = false
    @StateObject private var activity = CreatorActivityStore()
    private struct ActivityKey: Equatable { let visible: Bool; let active: Bool; let identity: String; let ids: [Int] }
    private var activityKey: ActivityKey { .init(visible: visible && selected && rootParticipation.isActive, active: recent != .any, identity: session.feedIdentity, ids: entries.map(\.id)) }
    private var matching: [LeaderboardEntry] {
        entries.filter { entry in
            if recent == .any { return true }
            if case .published(let date) = activity.result(for: entry.id) { return recent.includes(date) }
            return false
        }
    }
    private var unknown: [LeaderboardEntry] { entries.filter { activity.result(for: $0.id) == nil || activity.result(for: $0.id) == .unverified } }
    private var unchecked: Bool { entries.contains { activity.result(for: $0.id) == nil } }
    private var activitySummary: String {
        let verified = (entries.count - unknown.count).formatted(.number.locale(Locale(identifier: "en_US")))
        let total = entries.count.formatted(.number.locale(Locale(identifier: "en_US")))
        return "符合 \(matching.count) 位 · 已核实 \(verified)/\(total)"
    }
    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        let _ = segmentMotion?.recordProfileBodyEvaluation()
        #endif
        Group {
            if entries.isEmpty {
                if loading || (!loaded && error == nil) {
                    ProgressView().controlSize(.small).accessibilityLabel("正在加载作者榜").frame(maxHeight: .infinity)
                }
                else if let error { FailureView(message: error) { Task { await load() } } }
                else {
                    ScrollView {
                        PageStatusCard(title: "当前榜单暂无结果", symbol: "person.3")
                            .padding(.horizontal, FloatingPageChrome.pageInset)
                    }
                    .refreshable { await load() }
                }
            } else {
                List {
                    Section {
                        let results = matching
                        ForEach(results) { entry in row(entry, startsSection: entry.id == results.first?.id) }
                        if recent != .any && results.isEmpty && activity.busy {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("正在筛选作者")
                        } else if results.isEmpty && !activity.busy && !activity.checks.isEmpty {
                            Text(unknown.isEmpty ? "没有符合条件的作者" : "暂未找到符合条件的作者").foregroundStyle(.secondary)
                        }
                        if recent != .any && !activity.busy && unchecked {
                            Button("继续筛选") {
                                Task { await activity.checkNext(entries.map(\.user), source: session) }
                            }
                            .accessibilityValue(activitySummary)
                            .accessibilityIdentifier("leaderboard.activity.next")
                        }
                    }
                    .listSectionSeparator(.hidden)
                    if recent != .any && !unknown.isEmpty && (!activity.busy || showUnknown) {
                        let failed = unknown.filter { activity.result(for: $0.id) == .unverified }
                        Section {
                            DisclosureGroup("待核实 · \(unknown.count) 位", isExpanded: $showUnknown) {
                                if !failed.isEmpty {
                                    StatusReloadButton(title: "重试待核实作者") {
                                        Task { await activity.checkNext(failed.map(\.user), source: session, retryUnknown: true) }
                                    }
                                        .disabled(activity.busy)
                                }
                                ForEach(unknown) { entry in row(entry) }
                            }
                            .accessibilityIdentifier("leaderboard.activity.unknown")
                        }
                    }
                }
                .listStyle(.plain)
                .pageContentViewport(active: visible && selected && rootParticipation.canPrepare)
                .floatingScrollCanvas()
                .refreshable { await load() }
                    .overlay(alignment: .bottom) {
                        if error != nil {
                            HStack(spacing: 4) {
                                StatusReloadButton { Task { await load() } }
                            }.padding(.leading, 12).background(AppTheme.secondarySurface, in: Capsule()).padding()
                        }
                    }
            }
        }
        .existingFeedbackToast(entries.isEmpty ? nil : error.map { _ in "刷新失败" }, active: visible && selected, scope: session.feedIdentity)
        .task(id: visible && rootParticipation.canPrepare) { if visible && rootParticipation.canPrepare && !loaded { await load(replacing: true) } }
            .task(id: activityKey) {
                guard visible, selected, rootParticipation.isActive, recent != .any else { return }
                await activity.checkNext(entries.map(\.user), source: session)
            }
    }
    private func row(_ entry: LeaderboardEntry, startsSection: Bool = false) -> some View {
        let shape = FloatingPageChrome.controlShape
        return Button {
            guard selected, visible, rootParticipation.isActive, segmentMotion?.isInteracting != true else { return }
            onOpen(entry.user)
        } label: {
            HStack(spacing: FloatingPageChrome.spacing) {
                AuthorRowIdentity(name: entry.user.username, detail: publicationDate(for: entry), position: entry.position)
                Spacer(minLength: 0)
                if session.following.contains(entry.user.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .accessibilityLabel("已关注")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .authorCardRow()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.secondarySurface, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(SegmentedContentButtonStyle())
        .navigationLinkIndicatorVisibility(.hidden)
        .listRowInsets(EdgeInsets(top: startsSection ? 0 : 2, leading: FloatingPageChrome.pageInset, bottom: 2, trailing: FloatingPageChrome.pageInset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("leaderboard.author.\(entry.user.id)")
    }
    private func publicationDate(for entry: LeaderboardEntry) -> String? {
        guard recent != .any, case .published(let date) = activity.result(for: entry.id) else { return nil }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).year().month().day())
    }

    private func load(replacing: Bool = false) async {
        guard replacing || !loading else { return }
        let request = UUID()
        loadID = request
        loading = true
        error = nil
        defer {
            if loadID == request { loading = false }
        }
        do {
            let value = try await session.leaderboard(board)
            guard !Task.isCancelled, loadID == request else { return }
            entries = value.filter { !$0.user.username.isEmpty }
            loaded = true
        } catch {
            if !Task.isCancelled, loadID == request { self.error = error.localizedDescription }
        }
    }
}
