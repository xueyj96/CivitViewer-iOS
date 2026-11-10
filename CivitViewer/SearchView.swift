import SwiftUI

struct SearchView: View {
    private enum Mode: String, CaseIterable {
        case works = "作品"
        case authors = "作者"
    }

    @State private var mode = Mode.works
    @State private var authorText = ""
    @State private var submittedAuthor = ""
    @State private var openedAuthor: Creator?
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
    @State private var filter: FeedFilter
    @State private var showFilter = false
    @State private var presetRequest: FilterPresetRequest?
    @FocusState private var titleFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    private let showsBack: Bool
    init(initialCriteria: MediaSearchCriteria = .init(),
         initialFilter: FeedFilter = .defaults(for: .creator), showsBack: Bool = false) {
        self.showsBack = showsBack
        _text = State(initialValue: initialCriteria.text)
        _author = State(initialValue: initialCriteria.author)
        _tags = State(initialValue: initialCriteria.tags)
        _filter = State(initialValue: initialFilter)
    }
    private var criteria: MediaSearchCriteria { .init(text: text, author: author, tags: tags) }
    var body: some View {
        ZStack {
            if mode == .authors {
                AuthorLookupResults(keyword: submittedAuthor, opensProfiles: true, onSelect: { openedAuthor = $0 }) {
                    EmptyView()
                }
            } else if let submission {
                SearchResultGrid(criteria: submission.criteria, filter: $filter)
                    .id(submission.id)
                    .accessibilityIdentifier("search.results")
            } else {
                ScrollView {
                    if !text.isEmpty && !MediaSearchText.valid(text, mode: .title) {
                        Text(MediaSearchText.validationMessage).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, AppTheme.spacing)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: authorText) { _, text in
            if MediaSearchText.authorKeyword(text) != submittedAuthor { submittedAuthor = "" }
        }
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
        .navigationDestination(item: $openedAuthor) { CreatorView(creator: $0) }
    }

    private var hasConditions: Bool {
        submission != nil || !text.isEmpty || author != nil || !tags.isEmpty || filter != .defaults(for: .creator)
    }

    private var searchHeaderLayout: PageHeaderLayout {
        .search(accessibility: typeSize.isAccessibilitySize, includesFilters: mode == .works)
    }

    private var floatingBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: FloatingPageChrome.groupInset) {
                if showsBack {
                    FloatingPageBackButton()
                } else {
                    modeButton
                }
                queryField
                submitButton
            }
            if mode == .works {
                workFilters
            }
        }
    }

    private var modeButton: some View {
        Button {
            titleFocused = false
            mode = mode == .works ? .authors : .works
        } label: {
            FloatingPageIcon(symbol: mode == .works ? "square.grid.2x2" : "person.crop.circle")
        }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .accessibilityLabel("切换搜索类型")
        .accessibilityValue(mode.rawValue)
        .accessibilityHint("轻点切换作品或作者")
        .accessibilityIdentifier("search.mode")
    }

    private var workFilters: some View {
        let gap = FloatingPageChrome.groupInset
        let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [
            GridItem(.flexible(), spacing: gap),
            GridItem(.flexible(), spacing: gap),
            GridItem(.flexible(), spacing: gap),
            GridItem(.fixed(FloatingPageChrome.controlHeight)),
        ]
        return LazyVGrid(columns: columns, spacing: 0) {
            Button { titleFocused = false; showAuthors = true } label: {
                AppFilterLabel(title: author.map { "@" + $0.username } ?? "限作者", symbol: "person.crop.circle")
                    .minimumScaleFactor(1)
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
                AppFilterLabel(title: filter.effectiveKind.title, symbol: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FloatingPageButtonStyle(selected: filter != .defaults(for: .creator)))
            .accessibilityLabel("范围与排序，" + filter.summary)
            .accessibilityIdentifier("search.range")

            Button {
                titleFocused = false
                presetRequest = .init(session: session, scope: .search, filter: filter, criteria: criteria)
            } label: {
                FloatingPageIcon(symbol: "bookmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .accessibilityLabel("已保存的搜索条件")
            .accessibilityIdentifier("search.presets")
        }
    }

    private var queryField: some View {
        HStack(spacing: 0) {
            FloatingPageIcon(symbol: "magnifyingglass")
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
                .accessibilityHidden(true)
            if mode == .authors {
                SearchTitleField(text: $authorText, prompt: "搜作者", identifier: "search-author-input",
                                 focused: $titleFocused, onSubmit: searchAuthors)
            } else {
                SearchTitleField(text: $text, prompt: "搜标题",
                                 identifier: "search-title-input", focused: $titleFocused, onSubmit: searchWorks)
            }
            if mode == .works && hasConditions {
                Button {
                    text = ""; author = nil; tags = []; filter = .defaults(for: .creator); submission = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: searchHeaderLayout.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空全部条件")
            }
        }
        .font(FloatingPageChrome.controlFont)
        .padding(.horizontal, FloatingPageChrome.groupInset * 2)
        .frame(height: searchHeaderLayout.rowHeight)
        .background { FloatingPageFieldSurface() }
    }

    private var submitButton: some View {
        let searchesAuthors = mode == .authors
        let enabled = searchesAuthors ? MediaSearchText.valid(MediaSearchText.authorKeyword(authorText), mode: .author) : criteria.valid
        return Button {
            if searchesAuthors { searchAuthors() } else { searchWorks() }
        } label: {
            Text("搜索")
                .font(FloatingPageChrome.controlFont)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: FloatingPageChrome.controlHeight, height: searchHeaderLayout.rowHeight)
                .background { FloatingPageFieldSurface() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(searchesAuthors ? "搜索作者" : "搜索作品")
        .accessibilityIdentifier(searchesAuthors ? "search-authors-submit" : "search-submit")
    }

    private func searchAuthors() {
        let keyword = MediaSearchText.authorKeyword(authorText)
        guard MediaSearchText.valid(keyword, mode: .author) else { return }
        titleFocused = false
        submittedAuthor = keyword
    }

    private func pickTags() { titleFocused = false; showTags = true }

    private func searchWorks() {
        let query = criteria
        guard query.valid else { return }
        titleFocused = false
        submission = Submission(criteria: query)
    }
}

/// Native input stays out of the frozen header copy used during navigation.
private struct SearchTitleField: View {
    @Binding var text: String
    let prompt: String
    let identifier: String
    let focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    @Environment(\.headerPreviewCanGoBack) private var headerPreview

    var body: some View {
        if headerPreview != nil {
            Text(text.isEmpty ? prompt : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(prompt, text: $text, prompt: FloatingPageChrome.fieldPrompt(prompt))
                .accessibilityIdentifier(identifier)
                .focused(focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
        }
    }
}

private struct SearchResultGrid: View {
    private struct EmptyTagScope: Equatable {
        let request: FeedStoreRequestKey
        let evidenceIdentity: String
        let policy: TagAvailabilityPolicy
    }
    let criteria: MediaSearchCriteria
    @Binding var filter: FeedFilter
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
    private var authorOnly: Creator? {
        guard criteria.normalizedText.isEmpty, criteria.tags.isEmpty else { return nil }
        return criteria.author
    }
    private var target: MediaSearchTarget {
        if let authorOnly { return .author(authorOnly) }
        return .combined(criteria)
    }
    private var resultsHeader: some View {
        VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
            if let authorOnly {
                CreatorIdentityCard(creator: authorOnly)
                    .accessibilityIdentifier("search.author-result")
            }
            Menu {
                ForEach(FeedSort.allCases) { sort in
                    Button {
                        filter.sort = sort.rawValue
                    } label: {
                        if filter.sort == sort.rawValue { Label(sort.title, systemImage: "checkmark") }
                        else { Text(sort.title) }
                    }
                }
            } label: {
                AppFilterLabel(title: filter.sortTitle, symbol: "arrow.up.arrow.down")
            }
            .buttonStyle(FloatingPageButtonStyle())
            .menuOrder(.fixed)
            .accessibilityLabel("排序")
            .accessibilityValue(filter.sortTitle)
            .accessibilityIdentifier("search.results.sort")
            if criteria.tags.contains(where: { blocklist.names.contains(TagPolicy.normalize($0.name)) }) {
                Text("所选标签已屏蔽，相关作品仍会隐藏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FloatingPageChrome.pageInset)
    }

    var body: some View {
        MediaGrid(feed: feed,
                  isVisible: viewer == nil, refreshFromStart: refreshFeed, header: AnyView(resultsHeader),
                  horizontalInset: AppTheme.spacing, centersInitialProgress: true) { item in
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
