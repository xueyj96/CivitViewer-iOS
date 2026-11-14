import SwiftUI

struct MediaDetailsView: View {
    enum ExitAction { case author(CreatorRoute), signIn, tab(MediaTabExit) }
    let item: MediaItem
    private let onClose: ((ExitAction?) -> Void)?
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @Environment(\.floatingPageSafeInsets) private var floatingPageSafeInsets
    @Environment(\.mediaTabs) private var tabs
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @State private var resolvedTags: (request: TagRequest, names: [String], ids: [String: Int])?
    @State private var selected = Set<String>()
    @State private var preparingSearch = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDraft: MediaSearchCriteria?
    @State private var error: String?
    @State private var errorEvent = 0
    @State private var authorBlockError: String?
    @State private var authorBlockWorking = false
    @State private var authorBlockTask: Task<Void, Never>?
    @State private var authorBlockRequestID: UUID?
    @State private var displayedItemID: Int
    @State private var imageFailure: String?
    @State private var posterRetry = 0
    @State private var searchBarHeight: CGFloat = 0
    @State private var authorRetry = 0
    @State private var resolvedDuration: (workID: Int, identity: String, seconds: Double)?
    @State private var resolvedAuthor: (request: AuthorRequest, creator: Creator)?
    @State private var failedAuthorRequest: AuthorRequest?
    private struct TagRequest: Equatable {
        let workID: Int
        let identity: String
    }
    private var tagRequest: TagRequest {
        .init(workID: item.id, identity: session.feedIdentity)
    }
    private struct AuthorRequest: Equatable {
        let workID: Int
        let identity: String
        let retry: Int
    }
    private var authorRequest: AuthorRequest {
        .init(workID: item.id, identity: session.feedIdentity, retry: authorRetry)
    }
    private var author: Creator? {
        item.attributedCreator ?? (resolvedAuthor?.request == authorRequest ? resolvedAuthor?.creator : nil)
    }
    private var blurPreview: Bool { (session.account?.blurNsfw ?? true) && ((item.browsingLevel ?? 1) & 28 != 0) }
    init(item: MediaItem, onClose: ((ExitAction?) -> Void)? = nil) {
        self.item = item
        self.onClose = onClose
        _displayedItemID = State(initialValue: item.id)
    }
    private static func ids(_ tags: [MediaTag]?) -> [String: Int] {
        Dictionary((tags ?? []).compactMap { value in
            guard let name = value.name, let id = value.id, id > 0 else { return nil }
            return (TagPolicy.normalize(name), id)
        }, uniquingKeysWith: { first, _ in first })
    }
    private var eligibleTags: [String] {
        guard let resolvedTags, resolvedTags.request == tagRequest else { return [] }
        return resolvedTags.names
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                    VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                        let headerLayout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: FloatingPageChrome.spacing))
                            : AnyLayout(HStackLayout(alignment: .center, spacing: FloatingPageChrome.cardInset))
                        headerLayout {
                            preview
                            identity
                        }
                        Divider()
                        metadataGroup
                        if let imageFailure {
                            MediaLoadFailureContent(message: imageFailure, retryIdentifier: "details.image.retry",
                                                    retry: { posterRetry += 1 })
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(FloatingPageChrome.cardInset)
                    .background(cardSurface)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("details.work-card")

                    if !eligibleTags.isEmpty {
                        tagsCard.transition(.modifier(active: DetailsTagsReveal(progress: 0),
                                                       identity: DetailsTagsReveal(progress: 1)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FloatingPageChrome.pageInset)
                .padding(.bottom, 16)
            }
                .floatingScrollCanvas(additionalBottom: selected.isEmpty ? 0 : searchBarHeight)
                .disabled(preparingSearch)
                .existingFeedbackToast(error, id: errorEvent, scope: session.feedIdentity)
                .existingFeedbackToast(authorBlockError, scope: session.feedIdentity)
                .overlay(alignment: .bottom) {
                    if !selected.isEmpty {
                        searchBar
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                                        searchBarHeight = height
                                    }
                                }
                            }
                            .padding(.bottom, floatingPageSafeInsets.bottom + tabBarHeight)
                    }
                }
                .floatingTitleBar("作品详情", leading: {
                    Button { closeDetails() } label: { FloatingPageIcon(symbol: "chevron.left") }
                        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                        .accessibilityLabel("返回作品")
                        .accessibilityIdentifier("details.back")
                }) {
                    authorActions.disabled(preparingSearch)
                }
                .pageReturnAction(enabled: onClose != nil && !preparingSearch) {
                    guard !preparingSearch, onClose != nil else { return false }
                    closeDetails()
                    return true
                }
                .navigationDestination(item: $searchDraft) { SearchView(initialCriteria: $0, showsBack: true) }
                .task(id: tagRequest) { [tagRequest] in await refreshTags(for: tagRequest) }
                .task(id: authorRequest) { await loadAuthor(authorRequest) }
                .task(id: "\(session.feedIdentity):\(item.id)") { await loadDuration() }
        }
        .environment(\.overlaidTabBarHeight, tabBarHeight)
        .environment(\.exitMediaCoverToTab, onClose.map { _ in { exit in closeDetails(.tab(exit)) } })
        .ordinaryPresentationAppearance()
        .overlay(alignment: .bottom) {
            if let tabs, onClose != nil {
                tabs.render(false, "details.tabs", nil, nil, requestTab)
            }
        }
            .onAppear { notePosterRoute() }
            .onChange(of: session.feedIdentity) { _, _ in
                searchTask?.cancel(); authorBlockTask?.cancel(); authorBlockRequestID = nil; authorBlockWorking = false
                selected = []; error = nil
            }
            .onChange(of: item.id) { _, newID in
                displayedItemID = newID; authorBlockTask?.cancel(); authorBlockRequestID = nil; authorBlockWorking = false
                searchTask?.cancel(); selected = []; error = nil
                notePosterRoute()
            }
            .onDisappear { searchTask?.cancel(); authorBlockTask?.cancel() }
    }

    private var tabBarHeight: CGFloat { onClose == nil ? 0 : (tabs?.height ?? 0) }

    private func closeDetails(_ action: ExitAction? = nil) {
        if let onClose { onClose(action) }
        else { dismiss() }
    }

    private func requestTab(_ id: Int) {
        closeDetails(.tab(MediaTabExit(id: id, fromMedia: false)))
    }

    private var cardSurface: some View {
        FloatingPageChrome.controlShape.fill(AppTheme.secondarySurface)
    }

    private var mediaKind: String { item.isVideo ? "视频" : "图片" }

    private var workTitle: String? {
        guard let title = item.postTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    private var identity: some View {
        let authorLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: FloatingPageChrome.spacing))

        return VStack(alignment: .leading, spacing: 0) {
            Text(workTitle ?? "\(mediaKind)作品")
                .font(.title3.weight(.semibold))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("details.summary")

            authorLayout {
                if item.username != nil { authorLink }
                else { Text("作者未知").font(.subheadline).foregroundStyle(.secondary) }
                authorFollowAction
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataGroup: some View {
        VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
            if !workMetadata.isEmpty {
                Text(workMetadata)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("details.metadata")
            }
            Text(publicationMetadata)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("details.publication")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var publicationMetadata: String {
        var parts: [String] = []
        if let rawDate = item.createdAt,
           let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(rawDate))
               ?? (try? Date.ISO8601FormatStyle().parse(rawDate)) {
            parts.append(date.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).year().month().day()))
        }
        parts.append("作品 #\(item.id)")
        if let postID = item.postID, postID > 0 { parts.append("帖子 #\(postID)") }
        return parts.joined(separator: " · ")
    }

    private func loadDuration() async {
        guard item.isVideo, item.durationSeconds == nil, item.offlineMediaURL == nil,
              let postID = item.postID, postID > 0 else { return }
        let identity = session.feedIdentity
        let workID = item.id
        guard let records = try? await session.videoDurationMetadata(ids: [workID], postIDs: [postID], onlyPG: false),
              let seconds = records.first(where: { $0.id == workID })?.metadata?.duration,
              !Task.isCancelled, identity == session.feedIdentity else { return }
        resolvedDuration = (workID, identity, seconds)
    }

    private var workMetadata: String {
        var parts: [String] = workTitle == nil ? [] : [mediaKind]
        let fetched = resolvedDuration.flatMap { $0.workID == item.id && $0.identity == session.feedIdentity ? $0.seconds : nil }
        if item.isVideo, let duration = item.durationSeconds ?? fetched, duration.isFinite, duration > 0 {
            parts.append(VideoProgressChrome.clock(duration))
        }
        if let width = item.width, let height = item.height, width > 0, height > 0 {
            parts.append("\(width) × \(height)")
        }
        if item.offlineMediaURL != nil { parts.append("本地副本") }
        if blockedAuthorForItem != nil { parts.append("作者已屏蔽") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var authorFollowAction: some View {
        if !item.isStandaloneOfflineCopy {
            if let author {
                FollowButton(creator: author, onSignIn: onClose.map { _ in
                    { closeDetails(.signIn) }
                })
                .fixedSize(horizontal: true, vertical: false)
            } else if failedAuthorRequest == authorRequest {
                Button { authorRetry += 1 } label: { FloatingPageIcon(symbol: "arrow.clockwise") }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .accessibilityLabel("重试读取作者")
            } else if item.username != nil {
                ProgressView().controlSize(.small).accessibilityLabel("读取作者")
            }
        }
    }

    private var authorActions: some View {
        AppMenu {
            if blockedAuthorForItem != nil {
                Button("已屏蔽此作者", systemImage: "person.crop.circle.badge.xmark") {}
                    .disabled(true)
            } else if item.username != nil {
                Button(authorBlockWorking ? "正在核验…" : "屏蔽此作者", systemImage: "person.crop.circle.badge.xmark") {
                    guard !authorBlockWorking else { return }
                    let expectedID = displayedItemID, identity = session.feedIdentity
                    let requestID = UUID()
                    authorBlockTask?.cancel()
                    authorBlockRequestID = requestID
                    authorBlockTask = Task { await blockCurrentAuthor(itemID: expectedID, identity: identity, requestID: requestID) }
                }.disabled(authorBlockWorking)
            } else {
                Button("无法屏蔽：作者身份不可核验") {}.disabled(true)
            }
        } label: {
            FloatingPageIcon(symbol: "ellipsis")
        }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .accessibilityLabel(blockedAuthorForItem == nil ? "更多作者操作" : "更多作者操作，作者已屏蔽")
        .accessibilityIdentifier("details.more")
    }

    private var tagsCard: some View {
        TagPillLayout() {
            ForEach(eligibleTags, id: \.self) { tag in tagButton(tag) }
        }
        .padding(FloatingPageChrome.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("details.tags")
        .accessibilityValue("已选 \(selected.count) / 8")
    }

    @ViewBuilder private var authorLink: some View {
        if let username = item.username {
            if let author, onClose != nil {
                Button {
                    closeDetails(.author(CreatorRoute(creator: author, item: item)))
                } label: {
                    HStack(spacing: 4) {
                        Text("@" + username).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain)
                .accessibilityIdentifier("details.author")
            } else {
                Text("@" + username).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private func loadAuthor(_ request: AuthorRequest) async {
        guard !item.isStandaloneOfflineCopy, item.attributedCreator == nil,
              let username = item.username else { return }
        do {
            let creator = try await session.creator(username: username)
            guard !Task.isCancelled, request == authorRequest else { return }
            guard creator.id > 0 else { throw ClientError.invalidResponse }
            resolvedAuthor = (request, creator)
        } catch {
            if !Task.isCancelled, request == authorRequest { failedAuthorRequest = request }
        }
    }

    private var preview: some View {
        ZStack {
            Color(uiColor: .tertiarySystemBackground)
            if item.isVideo, let source = item.mediaURL {
                CachedPoster(source: source, declared: item.posterURL, active: false, fit: false,
                    retryToken: posterRetry, allowLocalExtraction: true, diagnosticWorkID: item.id,
                    showsFailure: false, emptyPlaceholder: "暂无可用封面",
                    placeholderTitle: nil,
                    imageBlur: blurPreview ? 24 : 0)
            } else if !item.isVideo, let imageURL = item.mediaURL {
                CachedImage(url: imageURL, fit: false, allowsRetry: false, retryToken: posterRetry,
                            showsFailure: false, onFailureMessage: { imageFailure = $0 },
                            imageBlur: blurPreview ? 24 : 0)
                    .opacity(imageFailure == nil ? 1 : 0)
            } else {
                if item.isVideo {
                    Text("暂无可用封面").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    CoverPlaceholder(symbol: "photo",
                        title: "图片 · #\(item.id)\(item.username.map { " · \($0)" } ?? "")")
                }
            }
            if imageFailure != nil { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: ContentMetrics.Preview.width, height: ContentMetrics.Preview.height)
        .clipShape(FloatingPageChrome.controlShape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.isVideo ? "视频封面" : "作品预览")
        .accessibilityIdentifier("details.preview")
    }
    private func notePosterRoute() {
        let route: PosterDiagnosticStage = item.mediaURL == nil ? .detailsUnavailable :
            (item.isVideo ? .detailsVideo : .detailsBitmap)
        guard let context = PlaybackFailureDiagnostic(workID: item.id, posterRoute: route,
            sourceURL: item.mediaURL, declaredURL: item.posterURL) else { return }
        LocalDiagnosticsStore.shared.note(area: .thumbnail, code: .posterOpened, playback: context)
    }
    private var blockedAuthorForItem: BlockedAuthor? {
        if let id = item.creatorID { return authorBlocklist.entries.first(where: { $0.id == id }) }
        guard let username = item.username else { return nil }
        let handle = AuthorHandlePolicy.normalize(username)
        guard authorBlocklist.blockedHandles.contains(handle) else { return nil }
        return authorBlocklist.entries.first(where: { AuthorHandlePolicy.normalize($0.username) == handle })
    }
    @MainActor private func blockCurrentAuthor(itemID: Int, identity: String, requestID: UUID) async {
        guard !Task.isCancelled, !authorBlockWorking, authorBlockRequestID == requestID,
              displayedItemID == itemID, item.id == itemID else { return }
        authorBlockWorking = true; authorBlockError = nil
        defer {
            if authorBlockRequestID == requestID { authorBlockWorking = false; authorBlockRequestID = nil }
        }
        guard let username = item.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            authorBlockError = "作品没有可核验的作者用户名，不能屏蔽匿名作者。"; return
        }
        do {
            let creator: Creator
            if let creatorID = item.creatorID, creatorID > 0 {
                creator = Creator(id: creatorID, username: username, image: nil)
            } else {
                let resolved = try await session.creator(username: username)
                guard identity == session.feedIdentity, !Task.isCancelled,
                      authorBlockRequestID == requestID, displayedItemID == itemID, item.id == itemID else { return }
                guard resolved.username == username else {
                    authorBlockError = "站点返回的作者用户名与作品不完全匹配，未添加屏蔽。"; return
                }
                creator = resolved
            }
            guard identity == session.feedIdentity, !Task.isCancelled,
                  authorBlockRequestID == requestID, displayedItemID == itemID, item.id == itemID else { return }
            guard authorBlocklist.add(creator) else {
                authorBlockError = authorBlocklist.error ?? "无法将此作者加入本机屏蔽名单。"; return
            }
            closeDetails()
        } catch is CancellationError {
            return
        } catch {
            guard identity == session.feedIdentity, !Task.isCancelled,
                  authorBlockRequestID == requestID, displayedItemID == itemID, item.id == itemID else { return }
            authorBlockError = "无法核验作者资料：" + error.localizedDescription
        }
    }
    private var searchBar: some View {
        HStack(spacing: FloatingPageChrome.groupInset) {
            Button("清空") { if !preparingSearch { selected = [] } }
                .disabled(preparingSearch)
            Button {
                guard !preparingSearch else { return }
                searchTask?.cancel()
                searchTask = Task { await prepareSearch() }
            } label: {
                HStack(spacing: FloatingPageChrome.groupInset) {
                    if preparingSearch { ProgressView() }
                    Label("组合搜索 · \(selected.count)", systemImage: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(FloatingPageButtonStyle(selected: true))
            .disabled(selected.isEmpty || preparingSearch)
                .accessibilityIdentifier("details.search")
        }
        .floatingPagePanelControls()
        .padding(.horizontal, FloatingPageChrome.groupInset)
        .background {
            FloatingPageChrome.controlShape.fill(AppTheme.secondarySurface.opacity(0.9))
                .frame(height: FloatingPageChrome.surfaceHeight)
        }
        .padding(.horizontal, FloatingPageChrome.pageInset)
    }
    private func tagButton(_ tag: String) -> some View {
        let chosen = selected.contains(tag)
        let blocked = blocklist.names.contains(tag)
        return AppContextButton {
            guard !preparingSearch else { return }
            if selected.contains(tag) { selected.remove(tag); error = nil }
            else if selected.count < 8 { selected.insert(tag); error = nil }
            else { errorEvent += 1; error = "最多组合 8 个标签，可先取消已有选择。" }
        } label: {
            WorkTagLabel(title: tag, selected: chosen, blocked: blocked)
        } menu: {
            Button(blocked ? "撤销屏蔽" : "屏蔽此标签", systemImage: blocked ? "tag" : "tag.slash") {
                guard !preparingSearch else { return }
                if blocked { blocklist.remove(tag); error = nil }
                else if !blocklist.add(tag) { errorEvent += 1; error = "无法加入屏蔽列表：最多 100 个标签，每个最多 80 字。" }
            }.disabled(preparingSearch)
            Button("仅用此标签组合搜索", systemImage: "magnifyingglass") {
                guard !preparingSearch else { return }
                selected = [tag]; searchTask?.cancel(); searchTask = Task { await prepareSearch() }
            }.disabled(preparingSearch)
        }
        .buttonStyle(.plain).accessibilityIdentifier("details.tag.\(tag)")
        .accessibilityLabel(tag).accessibilityValue(chosen ? "已选入组合搜索" : "未选择")
    }
    private func prepareSearch() async {
        guard !Task.isCancelled, !preparingSearch, !selected.isEmpty else { return }
        preparingSearch = true; error = nil
        defer { preparingSearch = false }
        let request = tagRequest, names = selected.sorted()
        let tagIDs = resolvedTags?.request == request ? resolvedTags?.ids ?? [:] : [:]
        do {
            var resolved: [SearchTag] = []
            for name in names {
                try Task.checkCancellation()
                if let id = tagIDs[name] { resolved.append(.init(id: id, name: name)) }
                else if let tag = try await session.exactTag(name: name) { resolved.append(tag) }
                else { throw ClientError.format("站点暂未确认标签编号。") }
            }
            guard request == tagRequest, !Task.isCancelled, selected == Set(names) else { return }
            searchDraft = .init(tags: resolved)
        } catch {
            guard !Task.isCancelled, request == tagRequest else { return }
            self.error = error.localizedDescription
        }
    }

    private func refreshTags(for request: TagRequest) async {
        let value: MediaItem?
        if item.offlineMediaURL != nil { value = item }
        else { value = try? await session.mediaItem(id: request.workID) }
        guard !Task.isCancelled, request == tagRequest else { return }

        let names = (value?.tagNames ?? []).filter { TagDirectoryQuality.includes($0) }.sorted()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.26)) {
            resolvedTags = (request, names, Self.ids(value?.tags))
            selected.formIntersection(names)
        }
    }
}

struct TagPillLayout: Layout {
    var spacing: CGFloat = ContentMetrics.Tag.gap
    var rowSpacing: CGFloat = ContentMetrics.Tag.gap
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (view, placement) in zip(subviews, result.frames) {
            view.place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y), proposal: ProposedViewSize(placement.size))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let width = max(1, width)
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (frames, frames.isEmpty ? 0 : y + rowHeight)
    }
}

struct CreatorBiographyView: View {
    let creator: Creator
    var collapsedLines = 2
    var onCollapse: (() -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @State private var value: CreatorBiography?
    @State private var error: String?
    @State private var loading = false
    @State private var loadedIdentity: String?
    @State private var expanded = false
    @State private var revision = 0
    @State private var requestedIdentity: String?
    private var text: String { BiographyText.plain(value?.profile?.bio ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading { ProgressView("读取简介…").font(.caption) }
            else if error != nil || value == nil {
                HStack(spacing: 8) {
                    if error == nil { Text("简介尚未取得").font(.caption).foregroundStyle(.secondary) }
                    StatusReloadButton(title: error == nil ? "读取简介" : "重试简介") { Task { await load() } }
                }
            }
            else if value?.blockedByThem == true { Text("作者简介当前不可见").font(.caption).foregroundStyle(.secondary) }
            else { CreatorBiographyContent(text: text, collapsedLines: collapsedLines, onCollapse: onCollapse) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .existingFeedbackToast(error, scope: session.feedIdentity)
            .task(id: session.feedIdentity) { if loadedIdentity != session.feedIdentity { await load() } }
    }
    private func load() async {
        let identity = session.feedIdentity
        guard !loading || requestedIdentity != identity else { return }
        revision += 1; let request = revision; requestedIdentity = identity
        loading = true; error = nil
        if loadedIdentity != identity { value = nil; expanded = false }
        defer { if request == revision { loading = false } }
        do {
            let result = try await session.creatorBiography(creator)
            guard request == revision, identity == session.feedIdentity, !Task.isCancelled else { return }
            value = result; loadedIdentity = identity
        } catch { if request == revision && identity == session.feedIdentity && !Task.isCancelled { self.error = "简介暂时无法读取：" + error.localizedDescription } }
    }
}

/// Full-width, native biography text shared by the loaded creator view and
/// controlled layout previews. Overflow beyond the collapsed preview is detected from the
/// text's laid-out height at the currently proposed width, so font and width
/// changes remeasure.
struct CreatorBiographyContent: View {
    let text: String
    var collapsedLines = 2
    var onCollapse: (() -> Void)? = nil
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    private var hasOverflow: Bool { fullHeight > collapsedHeight + 1 }
    private var attributedText: AttributedString { Self.linkedText(text) }

    private var textFont: Font { collapsedLines == 1 ? .footnote : .subheadline }

    var body: some View {
        let layout = collapsedLines == 1
            ? AnyLayout(HStackLayout(alignment: expanded ? .top : .center, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        layout {
            if !text.isEmpty {
                Text(attributedText)
                    .font(textFont)
                    .foregroundStyle(collapsedLines == 1 ? Color.secondary : Color.primary)
                    .lineLimit(expanded ? nil : collapsedLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: collapsedLines == 1 ? nil : .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("creator.biography.body")
                    .overlay {
                        ZStack(alignment: .topLeading) {
                            Text(attributedText)
                                .font(textFont)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .hidden().accessibilityHidden(true)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: BiographyHeightKey.self, value: ["full": proxy.size.height])
                                    }
                                }
                            Text(attributedText)
                                .font(textFont).lineLimit(collapsedLines)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .hidden().accessibilityHidden(true)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: BiographyHeightKey.self, value: ["collapsed": proxy.size.height])
                                    }
                                }
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }

                if hasOverflow {
                    Button {
                        let wasExpanded = expanded
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                        if wasExpanded { onCollapse?() }
                    } label: {
                        if collapsedLines == 1 {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                                .frame(width: 44, alignment: .leading)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        } else {
                            Text(expanded ? "收起" : "展开")
                        }
                    }
                    .accessibilityLabel(expanded ? "收起简介" : "展开简介")
                    .font(.caption.weight(.medium))
                    .tint(.blue)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .frame(width: collapsedLines == 1 ? 44 : nil)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("creator.biography.toggle")
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text) { _, _ in expanded = false; fullHeight = 0; collapsedHeight = 0 }
        .onPreferenceChange(BiographyHeightKey.self) { values in
            if let full = values["full"], abs(fullHeight - full) > 0.5 { fullHeight = full }
            if let collapsed = values["collapsed"], abs(collapsedHeight - collapsed) > 0.5 { collapsedHeight = collapsed }
        }
    }

    /// Add native Text links only for URLs accepted by the existing policy.
    /// Zero-width break opportunities keep a long URL inside narrow screens;
    /// the explicit link attribute still targets the original safe URL.
    private static func linkedText(_ source: String) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(source)
        }
        let matches = detector.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var result = AttributedString()
        var cursor = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source),
                  let raw = match.url?.absoluteString,
                  let safe = BiographyText.safeURL(raw), range.lowerBound >= cursor else { continue }
            result.append(AttributedString(String(source[cursor..<range.lowerBound])))
            let originalURL = String(source[range])
            var display = ""
            for (index, character) in originalURL.enumerated() {
                if index > 0 && index % 12 == 0 { display.append("\u{200B}") }
                display.append(character)
            }
            var linked = AttributedString(display)
            linked.link = safe
            result.append(linked)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(source[cursor...])))
        return result
    }
}

private struct BiographyHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Reveal the full tag card from its fixed top edge, including its padding.
/// The content keeps its natural layout; only the allocated height expands.
private struct DetailsTagsReveal: AnimatableModifier {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        DetailsTagsRevealLayout(progress: progress) { content }.clipped()
            .allowsHitTesting(progress >= 0.999).accessibilityHidden(progress < 0.999)
    }
}
private struct DetailsTagsRevealLayout: Layout {
    var progress: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(.init(width: proposal.width, height: nil))
        return .init(width: size.width, height: size.height * min(1, max(0, progress)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: .init(width: bounds.width, height: nil))
    }
}
