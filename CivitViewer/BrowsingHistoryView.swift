import SwiftUI

private struct PendingHistoryDeletion {
    let ids: Set<Int>
    let context: HistoryContext
    let accountIdentity: String
}

struct BrowsingHistoryView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @State private var kind: MediaKind = .image
    @State private var query = ""
    @State private var limits: [MediaKind: Int] = [:]
    private var limit: Int { limits[kind] ?? 30 }
    @State private var verified: [Int: MediaItem] = [:]
    @State private var checked = Set<Int>()
    @State private var loading = false
    @State private var loadError = false
    @State private var validatedIdentity: String?
    @State private var clearConfirmation = false
    @State private var deleteConfirmation = false
    @State private var pendingHistoryDeletion: PendingHistoryDeletion?
    @State private var favoriteBatch = FavoriteBatchSelection()
    @State private var request: HistoryPlaybackRequest?
    private var context: HistoryContext? { history.context(ownerID: session.tagLibraryOwnerID) }
    private var matching: [HistoryRecord] { matching(kind: kind) }
    private func matching(kind: MediaKind) -> [HistoryRecord] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.records.filter { record in
            !authorBlocklist.blocks(record) &&
            record.kind == kind &&
            (keyword.isEmpty || (record.authorName ?? "").localizedCaseInsensitiveContains(keyword) || String(record.id).contains(keyword))
        }
    }
    private var page: [HistoryRecord] { Array(matching.prefix(limit)) }
    private var visible: [HistoryRecord] { visibleRecords(page) }
    private func visibleRecords(_ records: [HistoryRecord]) -> [HistoryRecord] {
        records.filter { record in
            guard !authorBlocklist.blocks(record) else { return false }
            guard let item = verified[record.id] else { return blocklist.names.isEmpty }
            return permitted(item) && !authorBlocklist.blocks(item)
        }
    }
    private func dayGroups(_ records: [HistoryRecord]) -> [(Date, [HistoryRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: records) { calendar.startOfDay(for: $0.viewedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }
    private var loadKey: String { "\(session.tagLibraryIdentity):\(session.feedIdentity):\(context?.generation ?? -1):" + page.map { String($0.id) }.joined(separator: ",") }

    private func historyPane(kind paneKind: MediaKind) -> some View {
        let matching = matching(kind: paneKind)
        let limit = limits[paneKind] ?? 30
        let page = Array(matching.prefix(limit))
        let visible = visibleRecords(page)
        let groups = dayGroups(visible)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                HStack(spacing: FloatingPageChrome.spacing) {
                    FloatingPageIcon(symbol: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("作者名或作品编号", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .font(FloatingPageChrome.controlFont)
                .padding(.horizontal, FloatingPageChrome.cardInset)
                .frame(height: FloatingPageChrome.controlHeight)
                .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)

                if !history.checkpoints.isEmpty {
                    PageContentCard {
                        VStack(spacing: 0) {
                            ForEach(Array(history.checkpoints.enumerated()), id: \.element.lane) { index, checkpoint in
                                Button {
                                    if let context { request = .init(checkpoint: checkpoint, context: context, resumePosition: history.resumePosition(for: checkpoint.focusedID)) }
                                } label: {
                                    HStack(spacing: FloatingPageChrome.spacing) {
                                        Image(systemName: checkpoint.lane == .following ? "person.2" : "play.rectangle")
                                            .frame(width: 22).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(checkpoint.lane.title + "时间线").font(.subheadline.weight(.medium))
                                            Text(checkpoint.filter.effectiveKind.chineseTitle + " · " + checkpoint.updatedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_Hans_CN"))))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        FloatingPageIcon(symbol: "play.fill").foregroundStyle(.tint)
                                    }
                                    .padding(.vertical, FloatingPageChrome.groupInset)
                                    .frame(minHeight: FloatingPageChrome.controlHeight)
                                    .contentShape(Rectangle())
                                }.buttonStyle(SegmentedContentButtonStyle()).disabled(context == nil)
                                if index < history.checkpoints.count - 1 { Divider() }
                            }
                        }
                    }
                }
                if history.error != nil {
                    HStack(spacing: 8) {
                        StatusReloadButton(title: "重新读取浏览记录") {
                            Task { await history.retry(ownerID: session.tagLibraryOwnerID, identity: session.tagLibraryIdentity) }
                        }
                    }
                }
                if history.ready && matching.isEmpty {
                    PageStatusCard(title: history.records.isEmpty ? "还没有浏览记录" : "没有匹配的浏览记录", symbol: "clock")
                }
                ForEach(groups, id: \.0) { day, rows in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(rows) { record in
                                Button {
                                    if favoriteBatch.works != nil { favoriteBatch.toggle(record.id) }
                                    else { open(record) }
                                } label: { historyRow(record) }
                                .buttonStyle(SegmentedContentButtonStyle())
                                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    guard favoriteBatch.works == nil, context != nil else { return }
                                    favoriteBatch.begin(selecting: record.id)
                                })
                                .accessibilityAddTraits(favoriteBatch.works?.contains(record.id) == true ? .isSelected : [])
                                .accessibilityIdentifier("history.item.\(record.id)")
                                if record.id != rows.last?.id {
                                    Divider().padding(.leading, FloatingPageChrome.cardInset + ContentMetrics.Preview.width + FloatingPageChrome.cardInset)
                                }
                            }
                        }.background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
                    }
                }
                if loading { ProgressView("正在核对作品…").frame(maxWidth: .infinity) }
                if page.count > visible.count {
                    Text("\(page.count - visible.count) 项因屏蔽标签或标签待核实暂不展示。").font(.caption).foregroundStyle(.secondary)
                }
                if loadError {
                    StatusReloadButton { Task { await hydrate(retry: true) } }
                }
                if limit < matching.count { Button("加载更多记录") { limits[paneKind, default: 30] += 30 }.frame(maxWidth: .infinity).padding(12) }
            }
            .pageScrollContentInsets()
        }
            .scrollDismissesKeyboard(.interactively)
            .pageContentViewport(active: paneKind == kind)
            .existingFeedbackToast(history.error, id: history.error, active: paneKind == kind, scope: session.feedIdentity)
            .existingFeedbackToast(loadError ? "作品信息暂未取得" : nil, id: "history-hydrate-\(loadKey)", active: paneKind == kind, scope: session.feedIdentity)
    }

    var body: some View {
        SegmentedContentPager(selection: kind, options: MediaKind.browsingCases, identifier: "history.media-kind") { paneKind, _ in
            historyPane(kind: paneKind)
        }
            .ordinaryAppearance()
            .floatingPageBar("page-title.最近浏览", layoutIdentity: favoriteBatch.works != nil) {
                HStack(spacing: FloatingPageChrome.groupInset) {
                    FloatingPageBackButton()
                    FloatingMediaPicker(title: "历史媒体类型", selection: $kind, identifier: "history.media-kind")
                        .disabled(favoriteBatch.works != nil)
                    if favoriteBatch.works != nil {
                        Button { favoriteBatch.reset() } label: { FloatingPageIcon(symbol: "checkmark") }
                            .buttonStyle(FloatingPageButtonStyle(iconOnly: true)).accessibilityLabel("完成多选")
                    } else {
                        AppMenu {
                            Toggle(isOn: Binding(get: { history.recordingEnabled }, set: { value in
                                if let context { history.setRecordingEnabled(value, context: context) }
                            })) { Label("记录浏览历史", systemImage: "clock.arrow.circlepath") }
                                .font(AppTypography.rowTitle)
                                .toggleStyle(CompactSettingsToggleStyle())
                                .frame(minHeight: FloatingPageChrome.controlHeight)
                                .padding(.horizontal, FloatingPageChrome.cardInset)
                                .disabled(context == nil)
                            Button("清空浏览历史", systemImage: "trash", role: .destructive) { clearConfirmation = true }
                                .disabled(history.records.isEmpty || context == nil)
                        } label: { FloatingPageIcon(symbol: "ellipsis") }
                            .buttonStyle(FloatingPageButtonStyle(iconOnly: true)).accessibilityLabel("历史记录选项")
                            .accessibilityIdentifier("history.actions")
                    }
                }
            }
            .favoriteBatchBottomBar($favoriteBatch,
                                   canManage: context != nil && !(favoriteBatch.works ?? []).isEmpty && (favoriteBatch.works ?? []).allSatisfy { verified[$0] != nil },
                                   onDelete: { beginDeletingSelectedHistory() })
            .favoriteBatchEditor($favoriteBatch)
            .appConfirmationDialog("清空浏览历史？", isPresented: $clearConfirmation, titleVisibility: .visible) {
                Button("清空", role: .destructive) { if let context { history.clear(context: context) } }
            } message: { Text("同时清除接着看位置。") }
            .appConfirmationDialog("删除 \(pendingHistoryDeletion?.ids.count ?? 0) 条记录？", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) { confirmDeletingSelectedHistory() }
            }
            .task(id: loadKey) { await hydrate() }
            .onChange(of: session.tagLibraryIdentity) { _, _ in
                verified = [:]; checked = []; request = nil; favoriteBatch.reset()
                pendingHistoryDeletion = nil; deleteConfirmation = false
            }
            .onChange(of: session.feedIdentity) { _, _ in verified = [:]; checked = []; favoriteBatch.reset(); pendingHistoryDeletion = nil; deleteConfirmation = false }
            .onChange(of: context) { _, _ in favoriteBatch.reset(); pendingHistoryDeletion = nil; deleteConfirmation = false }
            .onChange(of: blocklist.names) { _, _ in favoriteBatch.reset() }
            .onChange(of: authorBlocklist.entries) { _, _ in favoriteBatch.reset() }
            .onChange(of: query) { _, _ in limits = [:]; favoriteBatch.reset() }
            .onChange(of: kind) { _, _ in favoriteBatch.reset() }
            .onChange(of: deleteConfirmation) { _, shown in if !shown { pendingHistoryDeletion = nil } }
            .onDisappear { pendingHistoryDeletion = nil; deleteConfirmation = false }
            .mediaCover(item: $request) { HistoryPlaybackView(request: $0) }
            .edgeSwitchingSegments(selection: $kind, options: MediaKind.browsingCases, identifier: "history.media-kind",
                                   enabled: request == nil && favoriteBatch.works == nil && !clearConfirmation)
    }

    private func beginDeletingSelectedHistory() {
        guard let ids = favoriteBatch.works, !ids.isEmpty, let current = context else { return }
        pendingHistoryDeletion = PendingHistoryDeletion(ids: ids, context: current, accountIdentity: session.tagLibraryIdentity)
        deleteConfirmation = true
    }

    private func confirmDeletingSelectedHistory() {
        guard let pendingHistoryDeletion,
              session.tagLibraryIdentity == pendingHistoryDeletion.accountIdentity,
              context == pendingHistoryDeletion.context,
              history.accepts(pendingHistoryDeletion.context) else { return }
        history.remove(ids: pendingHistoryDeletion.ids, context: pendingHistoryDeletion.context)
        favoriteBatch.reset()
        self.pendingHistoryDeletion = nil
        deleteConfirmation = false
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        HStack(spacing: FloatingPageChrome.cardInset) {
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                if let item = verified[record.id], let url = item.isVideo ? item.posterURL : item.mediaURL,
                   permitted(item) {
                    CachedImage(url: url).blur(radius: ((session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0)) ? 20 : 0)
                } else { Image(systemName: record.kind == .video ? "play.rectangle" : "photo").foregroundStyle(.secondary) }
                if record.kind == .video { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(FloatingPageChrome.spacing).background(.black.opacity(0.4), in: Circle()) }
            }.frame(width: ContentMetrics.Preview.width, height: ContentMetrics.Preview.height).clipShape(FloatingPageChrome.controlShape)
            VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                Text(record.authorName.map { "@" + $0 } ?? "作品 #\(record.id)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(record.kind.chineseTitle + " · " + record.viewedAt.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).hour().minute())).font(.caption).foregroundStyle(.secondary)
                if let position = PlaybackResumePolicy.position(position: record.positionSeconds, duration: record.durationSeconds), position >= 1 {
                    Text("看到 " + clock(position) + " / " + clock(record.durationSeconds ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.blue)
                } else if checked.contains(record.id) && verified[record.id] == nil {
                    Text("当前不可见或暂不可用").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 2)
            if let works = favoriteBatch.works {
                FavoriteSelectionMark(selected: works.contains(record.id))
            } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.padding(FloatingPageChrome.cardInset).contentShape(Rectangle())
    }
    private func open(_ record: HistoryRecord) {
        guard let context else { return }
        let ids = page.map(\.id)
        request = .init(ids: ids, focusedID: record.id, context: context, resumePosition: history.resumePosition(for: record.id))
    }
    private func permitted(_ item: MediaItem) -> Bool {
        !authorBlocklist.blocks(item) &&
        !HistoryMediaPolicy.ordered([item], ids: [item.id], blockedTags: blocklist.names, allowedMask: session.account?.browsingLevel ?? 1).isEmpty
    }
    private func hydrate(retry: Bool = false) async {
        guard let context else { return }
        let identity = session.tagLibraryIdentity, visibility = session.feedIdentity
        let validation = identity + ":" + visibility
        if validatedIdentity != validation { verified = [:]; checked = []; validatedIdentity = validation }
        let ids = page.map(\.id).filter { retry || !checked.contains($0) }
        guard !ids.isEmpty else { return }
        loading = true; loadError = false
        defer { if identity == session.tagLibraryIdentity, visibility == session.feedIdentity { loading = false } }
        do {
            for start in stride(from: 0, to: ids.count, by: 30) {
                try Task.checkCancellation()
                let batch = Array(ids[start..<min(ids.count, start + 30)])
                let media = try await session.mediaItems(ids: batch, includeTags: true)
                guard history.accepts(context), identity == session.tagLibraryIdentity, visibility == session.feedIdentity, !Task.isCancelled else { return }
                let allowed = HistoryMediaPolicy.ordered(media, ids: batch, blockedTags: [], allowedMask: session.account?.browsingLevel ?? 1)
                for id in batch { verified[id] = nil }
                for item in allowed { verified[item.id] = item }
                checked.formUnion(batch)
            }
        } catch is CancellationError {} catch {
            if history.accepts(context), identity == session.tagLibraryIdentity, visibility == session.feedIdentity {
                loadError = true; LocalDiagnosticsStore.shared.note(area: .restore, code: .loadFailed)
            }
        }
    }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).month().day())
    }
    private func clock(_ value: Double) -> String { let n = Int(max(0, value)); return String(format: "%d:%02d", n / 60, n % 60) }
}

struct HistoryPlaybackView: View {
    let request: HistoryPlaybackRequest
    var onLatest: (() -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @ObservedObject private var chrome = ViewingChromeController.shared
    @State private var items: [MediaItem] = []
    @State private var focused: Int?
    @State private var creator: CreatorRoute?
    @State private var loading = false
    @State private var message: String?
    @State private var navigationVisible = true
    private var currentItems: [MediaItem] {
        HistoryMediaPolicy.ordered(items, ids: request.ids, blockedTags: blocklist.names, filter: request.filter,
                                   followingIDs: request.lane == .following ? session.following : nil, allowedMask: session.account?.browsingLevel ?? 1)
            .filter { !authorBlocklist.blocks($0) }
    }
    private var resumePositions: [Int: Double] {
        if let record = history.records.first(where: { $0.id == request.focusedID }), record.durationSeconds != nil {
            return PlaybackResumePolicy.position(position: record.positionSeconds, duration: record.durationSeconds).map { [request.focusedID: $0] } ?? [:]
        }
        return request.resumePosition.map { [request.focusedID: $0] } ?? [:]
    }
    var body: some View {
        PlaybackNavigation(creator: $creator) { openAuthor in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if !currentItems.isEmpty {
                    MediaDeck(items: currentItems, focused: $focused, initialID: request.focusedID,
                              isVisible: navigationVisible, showsLoadMore: false, onAuthor: openAuthor,
                              historyCheckpoint: { item in
                        guard let lane = request.lane, let filter = request.filter else { return nil }
                        return TimelineCheckpoint.window(lane: lane, filter: filter, items: currentItems, focusedID: item.id)
                    }, resumePositions: resumePositions,
                              endAction: onLatest == nil ? nil : latest) {}
                } else if loading {
                    ProgressView().tint(.white).frame(maxHeight: .infinity).accessibilityLabel("正在核对作品")
                }
                else {
                    ScrollView {
                        PageMessageCard(title: "这段内容暂不可用", symbol: "photo.badge.exclamationmark",
                                        detail: "作品可能已不在当前可见范围，或被当前标签设置屏蔽。浏览记录会保留。") {
                            StatusReloadButton { Task { await load() } }
                                .accessibilityIdentifier("history.playback.retry")
                        }
                        .accessibilityIdentifier("history.playback.unavailable")
                        .padding(.horizontal, FloatingPageChrome.pageInset)
                        .padding(.top, PageHeaderLayout.singleRow.reservedHeight + FloatingPageChrome.groupInset)
                    }
                    .avoidOverlaidTabBar()
                    .environment(\.colorScheme, .dark)
                }
            }
            .playbackTitleBar(request.lane.map { $0.title + " · 接着看" } ?? "最近浏览",
                              workID: currentItems.first(where: { $0.id == focused })?.id,
                              hidden: chrome.hidden && !currentItems.isEmpty,
                              closeLabel: "关闭浏览记录", onClose: { dismiss() }) {
                if onLatest != nil { Button("最新", action: latest).accessibilityLabel("加载当前最新时间线") }
            }
                .onAppear { navigationVisible = true }.onDisappear { navigationVisible = false }
        }.tint(.white)
            .task { await load() }
            .existingFeedbackToast(message, id: request.id, active: navigationVisible && !loading && currentItems.isEmpty && !chrome.hidden, scope: session.feedIdentity)
            .existingFeedbackToast(
                !currentItems.isEmpty && !currentItems.contains(where: { $0.id == request.focusedID })
                    ? "原作品当前不可见，已定位到相邻可见作品" : nil,
                id: request.id,
                active: navigationVisible && !chrome.hidden,
                scope: session.feedIdentity
            )
            .onChange(of: session.tagLibraryIdentity) { _, _ in items = []; dismiss() }
            .onChange(of: history.generation) { _, _ in if !history.accepts(request.context) { items = []; dismiss() } }
    }
    private func latest() { onLatest?(); dismiss() }
    private func load() async {
        guard !loading, history.accepts(request.context) else { return }
        loading = true; message = nil
        let identity = session.tagLibraryIdentity
        defer { loading = false }
        do {
            let followingIDs = request.lane == .following ? try await session.refreshFollowingIDs() : nil
            let media = try await session.resumeMediaItems(ids: request.ids, followingIDs: followingIDs) {
                !Task.isCancelled && identity == session.tagLibraryIdentity && history.accepts(request.context)
            }
            guard !Task.isCancelled, identity == session.tagLibraryIdentity, history.accepts(request.context) else { return }
            if let filter = request.filter {
                items = try await session.enrichRestoredVideoDurations(media, filter: filter) {
                    !Task.isCancelled && identity == session.tagLibraryIdentity && history.accepts(request.context)
                }
            } else { items = media }
            focused = currentItems.contains(where: { $0.id == request.focusedID }) ? request.focusedID : currentItems.first?.id
        } catch is CancellationError {} catch {
            guard identity == session.tagLibraryIdentity, history.accepts(request.context) else { return }
            message = "连接或账号暂不可用，请联网后重试。历史位置仍保留。"
            LocalDiagnosticsStore.shared.note(area: .restore, code: .loadFailed)
        }
    }
}
