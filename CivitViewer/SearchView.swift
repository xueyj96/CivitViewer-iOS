import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var session: SiteSession
    @StateObject private var directory = TagDirectoryStore(diagnostics: .shared)
    @State private var text = ""
    @State private var author: Creator?
    @State private var tags: [SearchTag] = []
    @State private var showTags = false
    @State private var showAuthors = false
    private struct Submission: Identifiable {
        let id = UUID()
        let criteria: MediaSearchCriteria
    }
    @State private var submission: Submission?
    @State private var filter = FeedFilter(kind: .image, sort: "Newest", period: "AllTime")
    @State private var showFilter = false
    @State private var presetRequest: FilterPresetRequest?
    @FocusState private var titleFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    private let showsBack: Bool
    init(initialCriteria: MediaSearchCriteria = .init(), showsBack: Bool = false) {
        self.showsBack = showsBack
        _text = State(initialValue: initialCriteria.text)
        _author = State(initialValue: initialCriteria.author)
        _tags = State(initialValue: initialCriteria.tags)
    }
    private var criteria: MediaSearchCriteria { .init(text: text, author: author, tags: tags) }
    var body: some View {
        Group {
            if let submission {
                SearchResultGrid(criteria: submission.criteria, filter: filter, queryHeader: AnyView(querySummary))
                    .id(submission.id)
                    .accessibilityIdentifier("search.results")
            } else {
                ScrollView { querySummary }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: criteria.id) { _, id in
            if let submission, submission.criteria.id != id { self.submission = nil }
        }
        .floatingPageBar("search.top-bar", layout: searchHeaderLayout) { floatingBar }
        .ordinaryAppearance()
        .navigationDestination(isPresented: $showFilter) { FilterView(filter: $filter, context: .creator, showsMediaSelector: true) }
        .navigationDestination(item: $presetRequest) { request in
            FilterPresetPage(request: request) { snapshot in
                guard let query = snapshot.criteria else { return }
                text = query.text; author = query.author; tags = query.tags; filter = snapshot.filter; submission = nil
            }
        }
        .navigationDestination(isPresented: $showTags) { TagDirectoryView(selected: $tags, store: directory) }
        .navigationDestination(isPresented: $showAuthors) { AuthorSearchPicker(selected: $author) }
    }

    private var querySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if author != nil || !tags.isEmpty { selectedConditions }
            if !text.isEmpty && !MediaSearchText.valid(text, mode: .title) {
                Text(MediaSearchText.validationMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.spacing)
    }

    private var hasConditions: Bool {
        submission != nil || !text.isEmpty || author != nil || !tags.isEmpty || filter != .defaults(for: .creator)
    }

    private var searchHeaderLayout: PageHeaderLayout { .search(accessibility: typeSize.isAccessibilitySize) }

    private var floatingBar: some View {
        VStack(spacing: 0) {
            let queryLayout = typeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: FloatingPageChrome.groupInset))
                : AnyLayout(SearchQueryRowLayout())
            queryLayout {
                queryField
                queryActions
            }
            LazyVGrid(columns: FloatingPageChrome.equalColumns(typeSize.isAccessibilitySize ? 1 : 3, gap: FloatingPageChrome.groupInset), spacing: 0) {
                Button { titleFocused = false; showAuthors = true } label: {
                    AppFilterLabel(title: "作者", symbol: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FloatingPageButtonStyle(selected: author != nil))
                .accessibilityLabel("选择作者")
                .accessibilityValue(author.map { "@" + $0.username } ?? "未选择")
                .accessibilityIdentifier("search-author-picker")

                Button(action: pickTags) {
                    AppFilterLabel(title: tags.isEmpty ? "标签" : "标签 \(tags.count)", symbol: "tag")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FloatingPageButtonStyle(selected: !tags.isEmpty))
                .accessibilityLabel("选择标签")
                .accessibilityValue(tags.isEmpty ? "未选择" : "已选择 \(tags.count) 个标签")
                .accessibilityHint("作品须包含全部所选标签")
                .accessibilityIdentifier("search-tag-picker")

                Button { titleFocused = false; showFilter = true } label: {
                    ViewThatFits(in: .horizontal) {
                        AppFilterLabel(title: filter.effectiveKind.title + " · " + filter.sortTitle, symbol: "slider.horizontal.3")
                        AppFilterLabel(title: "筛选", symbol: "slider.horizontal.3")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(FloatingPageButtonStyle(selected: filter != .defaults(for: .creator)))
                .accessibilityLabel("范围与排序，" + filter.summary)
                .accessibilityIdentifier("search.range")
            }
        }
    }

    private var queryField: some View {
        HStack(spacing: FloatingPageChrome.groupInset) {
            if showsBack { FloatingPageBackButton() }
            HStack(spacing: 0) {
                FloatingPageIcon(symbol: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                    .accessibilityHidden(true)
                SearchTitleField(text: $text, focused: $titleFocused, onSubmit: search)
                if hasConditions {
                    Button {
                        text = ""; author = nil; tags = []; filter = .defaults(for: .creator); submission = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.secondary)
                            .frame(width: FloatingPageChrome.controlHeight, height: searchHeaderLayout.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空全部条件")
                }
            }
            .font(FloatingPageChrome.controlFont)
            .padding(.leading, 8)
            .padding(.trailing, hasConditions ? 0 : 8)
            .frame(height: searchHeaderLayout.rowHeight)
            .background { FloatingPageFieldSurface() }
        }
    }

    private var queryActions: some View {
        HStack(spacing: FloatingPageChrome.groupInset) {
            Button(action: search) {
                FloatingPageIcon(symbol: "arrow.right")
                    .foregroundStyle(criteria.valid ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: searchHeaderLayout.rowHeight)
                    .background { FloatingPageFieldSurface() }
                    .contentShape(Rectangle())
            }
            .disabled(!criteria.valid)
            .accessibilityLabel("搜索作品")
            .accessibilityIdentifier("search-submit")
            Button {
                titleFocused = false
                presetRequest = .init(session: session, scope: .search, filter: filter, criteria: criteria)
            } label: {
                FloatingPageIcon(symbol: "bookmark")
                    .frame(maxWidth: .infinity, minHeight: searchHeaderLayout.rowHeight)
                    .background { FloatingPageFieldSurface() }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("已保存的搜索条件")
            .accessibilityIdentifier("search.presets")
        }
        .font(FloatingPageChrome.controlFont)
        .buttonStyle(.plain)
    }

    private var selectedConditions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                if let author {
                    Button { self.author = nil } label: { selectedConditionLabel("@" + author.username) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("不限作者")
                }
                ForEach(tags) { tag in
                    Button { tags.removeAll { $0.id == tag.id } } label: { selectedConditionLabel(tag.name) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除搜索标签 " + tag.name)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func selectedConditionLabel(_ text: String) -> some View {
        WorkTagLabel(title: text, selected: true, removable: true)
            .frame(maxWidth: 150)
    }

    private func pickTags() { titleFocused = false; showTags = true }
    private func search() { if criteria.valid { titleFocused = false; submission = Submission(criteria: criteria) } }
}

/// The query spans the first two filter columns. Both actions share the third.
private struct SearchTitleField: View {
    @Binding var text: String
    let focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    @Environment(\.headerPreviewCanGoBack) private var headerPreview

    var body: some View {
        if headerPreview != nil {
            Text(text.isEmpty ? "标题开头" : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("标题开头", text: $text, prompt: FloatingPageChrome.fieldPrompt("标题开头"))
                .accessibilityIdentifier("search-title-input")
                .focused(focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
        }
    }
}

private struct SearchQueryRowLayout: Layout {
    private let spacing = FloatingPageChrome.groupInset

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(spacing) { $0 + $1.sizeThatFits(.unspecified).width }
        let proposals = columnProposals(width: width)
        let height = zip(subviews, proposals).map { $0.sizeThatFits($1).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let proposals = columnProposals(width: bounds.width)
        var x = bounds.minX
        for (view, column) in zip(subviews, proposals) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: column)
            x += (column.width ?? 0) + spacing
        }
    }

    private func columnProposals(width: CGFloat) -> [ProposedViewSize] {
        let column = FloatingPageChrome.columnWidth(in: width, count: 3, gap: spacing)
        return [.init(width: 2 * column + spacing, height: nil), .init(width: column, height: nil)]
    }
}

private struct SearchResultGrid: View {
    private struct EmptyTagScope: Equatable {
        let request: FeedStoreRequestKey
        let evidenceIdentity: String
        let policy: TagAvailabilityPolicy
    }
    let criteria: MediaSearchCriteria
    let filter: FeedFilter
    let queryHeader: AnyView
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocks = AuthorBlocklist.shared
    @AppStorage("deduplicateMedia") private var deduplicateMedia = true
    @StateObject private var feed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: .shared)
    @State private var focused: Int?
    @State private var viewer: MediaItem?
    @State private var emptyTagScope: EmptyTagScope?
    @State private var emptyTagKinds: Set<MediaKind> = []

    private var requestKey: FeedStoreRequestKey { .init(identity: session.feedIdentity, filter: filter, source: .search(target)) }
    private var target: MediaSearchTarget { .combined(criteria) }
    private var resultsContext: AnyView {
        let hasBlockedTag = criteria.tags.contains { blocklist.names.contains(TagPolicy.normalize($0.name)) }
        return AnyView(
            VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                queryHeader
                VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                    if hasBlockedTag {
                        Text("所选标签已屏蔽，相关作品仍会隐藏。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let author = criteria.author {
                        NavigationLink { CreatorView(creator: author, initialKind: filter.effectiveKind) } label: {
                            Label("作者主页", systemImage: "person.crop.circle")
                        }
                        .buttonStyle(FloatingPageButtonStyle())
                    }
                }
                .padding(.horizontal, FloatingPageChrome.pageInset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    var body: some View {
        MediaGrid(feed: feed,
                  isVisible: viewer == nil, refreshFromStart: refreshFeed, header: resultsContext,
                  horizontalInset: AppTheme.spacing) { item in
            focused = item.id
            viewer = item
        } loadMore: { await feed.next(session: session) }
        .avoidOverlaidTabBar()
            .task(id: requestKey) {
                let retainedKey = feed.requestKey == requestKey
                let commit = await feed.activate(session: session, filter: filter, source: .search(target), blockedTags: blocklist.names)
                if !retainedKey && feed.accepts(commit, identity: session.feedIdentity) { focused = nil }
            }
            .onChange(of: blocklist.names) { _, tags in feed.applyBlockedTags(tags) }
            .onChange(of: feed.reachedEnd) { _, _ in recordEmptyTagSearch() }
            .onChange(of: feed.items.isEmpty) { _, _ in recordEmptyTagSearch() }
            .onChange(of: feed.loading) { _, _ in recordEmptyTagSearch() }
            .mediaCover(item: $viewer) { opening in
                FeedMediaViewer(items: feed.items, focused: $focused, initialID: opening.id,
                                continuationState: feed.continuationState, loadMoreAutomatically: { await feed.nextAutomatically(session: session) },
                                refreshFromStart: refreshFeed, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                                onDetailsVisibility: { feed.setTagPolicyDeferred($0) }, onClose: { viewer = nil }) {
                    await feed.next(session: session)
                }
            }
    }
    private func recordEmptyTagSearch() {
        let kind = filter.effectiveKind
        guard feed.requestKey == requestKey, MediaKind.browsingCases.contains(kind),
              filter.sort == "Newest", filter.period == "AllTime", filter.baseModel.isEmpty,
              filter.videoDurationRange == nil, !filter.onlyPG, criteria.tags.count == 1,
              criteria.author == nil, criteria.normalizedText.isEmpty else { return }
        let policy = TagAvailabilityPolicy(blockedTags: blocklist.names, blockedAuthorIDs: authorBlocks.blockedIDs,
            blockedAuthorHandles: authorBlocks.blockedHandles, deduplicateMediaAssets: deduplicateMedia)
        let scope = EmptyTagScope(request: .init(identity: session.feedIdentity, filter: filter.selecting(kind: .image), source: .search(target)),
                                  evidenceIdentity: session.tagEvidenceIdentity, policy: policy)
        if emptyTagScope != scope {
            emptyTagScope = scope
            emptyTagKinds = []
        }
        guard !feed.loading, feed.error == nil, feed.reachedEnd, feed.items.isEmpty else {
            emptyTagKinds.remove(kind)
            return
        }
        // Both user-selected media searches must finish before writing a catalog-wide negative observation.
        guard emptyTagKinds.insert(kind).inserted, emptyTagKinds.count == MediaKind.browsingCases.count else { return }
        TagObservationStore.shared.recordEmpty(tagID: criteria.tags[0].id, scope: scope.evidenceIdentity, policy: policy)
    }
    private func refreshFeed() async {
        if await feed.restartCurrentFeed(session: session)?.status == .committed { focused = feed.items.first?.id }
    }
}
