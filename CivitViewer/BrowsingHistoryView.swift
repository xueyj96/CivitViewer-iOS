import SwiftUI

struct BrowsingHistoryView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @State private var kind: MediaKind = .image
    @State private var query = ""
    @State private var limit = 30
    @State private var verified: [Int: MediaItem] = [:]
    @State private var checked = Set<Int>()
    @State private var loading = false
    @State private var loadError = false
    @State private var validatedIdentity: String?
    @State private var clearConfirmation = false
    @State private var favoriteBatch = FavoriteBatchSelection()
    @State private var request: HistoryPlaybackRequest?
    private var context: HistoryContext? { history.context(ownerID: session.tagLibraryOwnerID) }
    private var matching: [HistoryRecord] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.records.filter { record in
            !authorBlocklist.blocks(record) &&
            record.kind == kind &&
            (keyword.isEmpty || (record.authorName ?? "").localizedCaseInsensitiveContains(keyword) || String(record.id).contains(keyword))
        }
    }
    private var page: [HistoryRecord] { Array(matching.prefix(limit)) }
    private var visible: [HistoryRecord] {
        page.filter { record in
            guard !authorBlocklist.blocks(record) else { return false }
            guard let item = verified[record.id] else { return blocklist.names.isEmpty }
            return permitted(item) && !authorBlocklist.blocks(item)
        }
    }
    private var dayGroups: [(Date, [HistoryRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.viewedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }
    private var loadKey: String { "\(session.tagLibraryIdentity):\(session.feedIdentity):\(context?.generation ?? -1):" + page.map { String($0.id) }.joined(separator: ",") }

    var body: some View {
        ScrollView {
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

                SettingsControlCard {
                    Toggle(isOn: Binding(get: { history.recordingEnabled }, set: { value in
                        if let context { history.setRecordingEnabled(value, context: context) }
                    })) {
                        SettingsRowLabel("记录浏览历史", "clock.arrow.circlepath")
                    }
                    .disabled(context == nil)
                    .accessibilityHint("保留最近 30 天的记录，最多 5,000 条")
                }

                if !history.checkpoints.isEmpty {
                    Text("接着看").font(.caption).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(history.checkpoints, id: \.lane) { checkpoint in
                        SettingsControlCard {
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
                            }.buttonStyle(.plain).disabled(context == nil)
                        }
                    }
                }

                FloatingMediaPicker(title: "历史媒体类型", selection: $kind, identifier: "history.media-kind")
                if let error = history.error {
                    HStack(spacing: 8) {
                        Text(error).font(.subheadline)
                        StatusReloadButton(title: "重新读取浏览记录") {
                            Task { await history.retry(ownerID: session.tagLibraryOwnerID, identity: session.tagLibraryIdentity) }
                        }
                    }
                }
                if history.ready && matching.isEmpty {
                    PageStatusCard(title: history.records.isEmpty ? "还没有浏览记录" : "没有匹配的浏览记录", symbol: "clock")
                }
                ForEach(dayGroups, id: \.0) { day, rows in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(rows) { record in
                                Button {
                                    if favoriteBatch.works != nil { favoriteBatch.toggle(record.id) }
                                    else { open(record) }
                                } label: { historyRow(record) }
                                    .buttonStyle(.plain)
                                    .disabled(favoriteBatch.works != nil && verified[record.id] == nil)
                                    .accessibilityAddTraits(favoriteBatch.works?.contains(record.id) == true ? .isSelected : [])
                                    .accessibilityIdentifier("history.item.\(record.id)")
                                    .contextMenu {
                                        if favoriteBatch.works == nil {
                                            Button("从历史中删除", systemImage: "trash", role: .destructive) {
                                                if let context { history.remove(ids: [record.id], context: context) }
                                            }
                                        }
                                    }
                                if record.id != rows.last?.id { Divider().padding(.leading, 86) }
                            }
                        }.background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
                    }
                }
                if loading { ProgressView("正在核对作品…").frame(maxWidth: .infinity) }
                if page.count > visible.count {
                    Text("\(page.count - visible.count) 项因屏蔽标签或标签待核实暂不展示。").font(.caption).foregroundStyle(.secondary)
                }
                if loadError {
                    HStack(spacing: 8) {
                        Text("作品信息暂未取得").font(.subheadline).foregroundStyle(.secondary)
                        StatusReloadButton { Task { await hydrate(retry: true) } }
                    }
                }
                if limit < matching.count { Button("加载更多记录") { limit += 30 }.frame(maxWidth: .infinity).padding(12) }
            }
            .pageScrollContentInsets()
        }
            .scrollDismissesKeyboard(.interactively)
            .ordinaryAppearance()
            .floatingTitleBar("最近浏览") {
                FavoriteBatchToolbar(selection: $favoriteBatch, canSelect: context != nil && visible.contains { verified[$0.id] != nil })
                if favoriteBatch.works == nil {
                    Button("清空", role: .destructive) { clearConfirmation = true }.disabled(history.records.isEmpty || context == nil)
                }
            }
            .favoriteBatchEditor($favoriteBatch)
            .confirmationDialog("清空本机浏览记录与接着看位置？", isPresented: $clearConfirmation, titleVisibility: .visible) {
                Button("清空浏览历史", role: .destructive) { if let context { history.clear(context: context) } }
            } message: { Text("仅清理当前账号的浏览历史。收藏、离线文件和时间线缓存会保留。") }
            .task(id: loadKey) { await hydrate() }
            .onChange(of: session.tagLibraryIdentity) { _, _ in verified = [:]; checked = []; request = nil }
            .onChange(of: session.feedIdentity) { _, _ in verified = [:]; checked = []; favoriteBatch.reset() }
            .onChange(of: context) { _, _ in favoriteBatch.reset() }
            .onChange(of: blocklist.names) { _, _ in favoriteBatch.reset() }
            .onChange(of: authorBlocklist.entries) { _, _ in favoriteBatch.reset() }
            .onChange(of: kind) { _, _ in limit = 30 }
            .onChange(of: query) { _, _ in limit = 30 }
            .mediaCover(item: $request) { HistoryPlaybackView(request: $0) }
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                if let item = verified[record.id], let url = item.isVideo ? item.posterURL : item.mediaURL,
                   permitted(item) {
                    CachedImage(url: url).blur(radius: ((session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0)) ? 20 : 0)
                } else { Image(systemName: record.kind == .video ? "play.rectangle" : "photo").foregroundStyle(.secondary) }
                if record.kind == .video { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(7).background(.black.opacity(0.4), in: Circle()) }
            }.frame(width: 58, height: 74).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
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
        }.padding(14).contentShape(Rectangle())
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
                    ContentUnavailableView { Label("这段内容暂不可用", systemImage: "photo.badge.exclamationmark") } description: {
                        Text(message ?? "作品可能已不在当前可见范围，或被当前标签设置屏蔽。浏览记录会保留。")
                    } actions: {
                        StatusReloadButton { Task { await load() } }
                            .environment(\.colorScheme, .dark)
                    }.foregroundStyle(.white)
                }
                if !currentItems.isEmpty && !currentItems.contains(where: { $0.id == request.focusedID }) {
                    Text("原作品当前不可见，已定位到相邻可见作品")
                        .font(.caption).padding(10).foregroundStyle(.white)
                        .background(.black.opacity(0.7), in: FloatingPageChrome.controlShape)
                        .padding(.horizontal, FloatingPageChrome.pageInset)
                        .padding(.top, PageHeaderLayout.singleRow.reservedHeight)
                        .viewingChromeHidden(chrome.hidden)
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
