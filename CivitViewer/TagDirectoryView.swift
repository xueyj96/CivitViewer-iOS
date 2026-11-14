import SwiftUI

struct TagDirectoryView: View {
    @Binding var selected: [SearchTag]
    @ObservedObject private var seedStore: TagDirectoryStore
    @State private var seedMode: TagDirectoryMode
    @StateObject private var catalogStore = TagDirectoryStore(diagnostics: .shared)
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocks = AuthorBlocklist.shared
    @ObservedObject private var observations = TagObservationStore.shared
    @AppStorage("tagDirectory.showCatalog57") private var showCatalog = false
    @AppStorage("deduplicateMedia") private var deduplicateMedia = true
    @State private var query: String
    @State private var draft: [SearchTag]
    @State private var selectionIdentity: String?
    @State private var selectionError: String?
    @State private var retryIdentity: UUID?

    init(selected: Binding<[SearchTag]>, store: TagDirectoryStore) {
        _selected = selected
        _seedStore = ObservedObject(wrappedValue: store)
        let initialMode = store.key?.mode ?? .common
        _seedMode = State(initialValue: initialMode)
        _draft = State(initialValue: selected.wrappedValue)
        _query = State(initialValue: store.key?.keyword ?? "")
    }

    private var keyword: String { TagPolicy.normalize(query) }
    private var activeMode: TagDirectoryMode { showCatalog || !keyword.isEmpty ? .catalog : .common }
    private var browsingMode: Binding<TagDirectoryMode> {
        Binding(get: { activeMode }, set: { mode in
            showCatalog = mode == .catalog
            if mode == .common { query = "" }
        })
    }
    private func store(for mode: TagDirectoryMode) -> TagDirectoryStore { mode == seedMode ? seedStore : catalogStore }
    private var selectedStore: TagDirectoryStore { store(for: activeMode) }
    private var selectedKey: TagDirectoryStore.Key {
        .init(mode: activeMode, keyword: activeMode == .common ? "" : keyword, identity: session.tagLookupIdentity)
    }
    private var valid: Bool { selectedKey.keyword.isEmpty || MediaSearchText.valid(selectedKey.keyword, mode: .tag) }
    private var canRetry: Bool {
        selectedStore.key == selectedKey && valid && (selectedStore.error != nil || selectedStore.onlineError != nil)
    }

    var body: some View {
        SegmentedContentPager(selection: browsingMode.wrappedValue, options: TagDirectoryMode.allCases, identifier: "tag-directory.mode") { mode, active in
            TagDirectoryResultsPane(
                mode: mode,
                query: mode == .common ? "" : keyword,
                active: active,
                selected: activeMode == mode,
                store: store(for: mode),
                draft: $draft,
                selectionError: $selectionError,
                session: session,
                blocklist: blocklist,
                authorBlocks: authorBlocks,
                observations: observations,
                deduplicateMedia: deduplicateMedia
            )
        }
        .floatingPageBar("page-title.选择标签", layout: .tripleRow) {
            VStack(spacing: 0) {
                FloatingTitleRow {
                    FloatingSegmentedTrack(nested: true, overMedia: false).accessibilityHidden(true)
                    FloatingPageBackButton()
                    HStack(spacing: FloatingPageChrome.groupInset) {
                        Text("选择标签")
                    }
                    .font(FloatingPageChrome.controlFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("page-header.title")
                    .accessibilityAddTraits(.isHeader)
                    Button { dismiss() } label: { FloatingPageIcon(symbol: "checkmark") }
                        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                        .accessibilityLabel("完成")
                        .accessibilityValue("已选 \(draft.count) / 8")
                }
                HStack(spacing: FloatingPageChrome.groupInset) {
                    HStack(spacing: FloatingPageChrome.spacing) {
                        FloatingPageIcon(symbol: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("搜索标签名称", text: $query, prompt: FloatingPageChrome.fieldPrompt("搜索标签名称"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("tag-search-input")
                        Button { query = "" } label: {
                            FloatingPageIcon(symbol: "xmark").foregroundStyle(.secondary)
                                .frame(width: FloatingPageChrome.controlHeight, height: FloatingPageChrome.controlHeight).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).opacity(query.isEmpty ? 0 : 1).allowsHitTesting(!query.isEmpty)
                        .accessibilityHidden(query.isEmpty).accessibilityLabel("清空标签名称")
                        .accessibilityIdentifier("tag-search.clear")
                    }
                    .font(FloatingPageChrome.controlFont).frame(minHeight: FloatingPageChrome.controlHeight)
                    .padding(.horizontal, 12).background { FloatingPageFieldSurface() }
                    if canRetry { retryButton } else { prefixMenu }
                }
                FloatingSegmentedControl(title: "浏览标签", selection: browsingMode,
                                         options: TagDirectoryMode.allCases, optionTitle: { $0.title },
                                         identifier: "tag-directory.mode")
            }
        }
        .commitOnPageReturn { [draft, selectionIdentity] in
            if selectionIdentity == session.tagLookupIdentity { selected = draft }
        }
        .task(id: session.tagEvidenceIdentity) { await observations.activate(scope: session.tagEvidenceIdentity) }
        .onAppear { if selectionIdentity == nil { selectionIdentity = session.tagLookupIdentity } }
        .onChange(of: session.tagLookupIdentity) { _, identity in
            if let selectionIdentity, selectionIdentity != identity { dismiss() }
        }
        .ordinaryAppearance()
        .edgeSwitchingSegments(selection: browsingMode, options: TagDirectoryMode.allCases,
                               identifier: "tag-directory.mode", enabled: false, reservesPageEdges: false)
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") {
                let current = selectedStore
                let sampled = current.tags.filter { observations.estimate(tagID: $0.id, scope: session.tagEvidenceIdentity,
                    policy: .init(blockedTags: blocklist.names, blockedAuthorIDs: authorBlocks.blockedIDs,
                                  blockedAuthorHandles: authorBlocks.blockedHandles, deduplicateMediaAssets: deduplicateMedia)) != nil }.count
                let visible: Int = {
                    guard activeMode == .common else { return current.tags.count }
                    let selectedIDs = Set(draft.map(\.id))
                    let resultIDs = Set(current.tags.filter { tag in
                        selectedIDs.contains(tag.id) || observations.estimate(tagID: tag.id, scope: session.tagEvidenceIdentity,
                            policy: .init(blockedTags: blocklist.names, blockedAuthorIDs: authorBlocks.blockedIDs,
                                          blockedAuthorHandles: authorBlocks.blockedHandles, deduplicateMediaAssets: deduplicateMedia))?.isRecommended == true
                    }.map(\.id))
                    return draft.filter { !resultIDs.contains($0.id) }.count + resultIDs.count
                }()
                let value = "mode=\(activeMode.rawValue);selected=\(draft.map(\.id));loaded=\(current.tags.count);visible=\(visible);sampled=\(sampled);probeReads=\(session.tagCandidateReads);revision=\(observations.revision)"
                Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("qa.tag-availability55").accessibilityValue(value)
            }
        }
        #endif
    }

    private var prefixMenu: some View {
        AppMenu {
            AppMenuSection("字母") { ForEach(Array("abcdefghijklmnopqrstuvwxyz"), id: \.self) { letter in Button(String(letter).uppercased()) { showCatalog = true; query = String(letter) } } }
            AppMenuSection("数字") { ForEach(0...9, id: \.self) { digit in Button(String(digit)) { showCatalog = true; query = String(digit) } } }
        } label: { FloatingPageIcon(symbol: "textformat.abc") }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true)).accessibilityLabel("首字母").accessibilityIdentifier("tag-directory.prefix")
    }
    private var retryButton: some View {
        Button {
            let store = selectedStore
            let key = selectedKey
            guard retryIdentity == nil, store.key == key, !store.loading else { return }
            let identity = UUID()
            retryIdentity = identity
            Task {
                defer { if retryIdentity == identity { retryIdentity = nil } }
                guard selectedKey == key, store.key == key, !store.loading else { return }
                if store.onlineError != nil { await store.retryOnline(source: session) }
                else if !store.reachedEnd { await store.next(source: session) }
                else { await store.reload(key: key, source: session) }
            }
        } label: { FloatingPageIcon(symbol: "arrow.clockwise") }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true)).disabled(selectedStore.loading || retryIdentity != nil)
            .accessibilityLabel("重试标签").accessibilityIdentifier("tag-directory.retry")
    }
}

private struct TagDirectoryResultsPane: View {
    let mode: TagDirectoryMode
    let query: String
    let active: Bool
    let selected: Bool
    @ObservedObject var store: TagDirectoryStore
    @Binding var draft: [SearchTag]
    @Binding var selectionError: String?
    @ObservedObject var session: SiteSession
    @ObservedObject var blocklist: TagBlocklist
    @ObservedObject var authorBlocks: AuthorBlocklist
    @ObservedObject var observations: TagObservationStore
    @Environment(\.segmentedPageMotion) private var segmentMotion
    @State private var lastStableQuery: String
    @State private var actionGeneration = 0
    @State private var selectionErrorEvent = 0
    private var modeIndex: Int? { TagDirectoryMode.allCases.firstIndex(of: mode) }
    private var sourceQueryIsFrozen: Bool {
        segmentMotion?.isInteracting == true && segmentMotion?.sourceIndex == modeIndex && mode == .catalog
    }
    private var effectiveQuery: String { mode == .common ? "" : (sourceQueryIsFrozen ? lastStableQuery : query) }
    private var stableSelected: Bool { selected && !(segmentMotion?.isInteracting ?? false) }

    init(mode: TagDirectoryMode, query: String, active: Bool, selected: Bool, store: TagDirectoryStore,
         draft: Binding<[SearchTag]>, selectionError: Binding<String?>, session: SiteSession,
         blocklist: TagBlocklist, authorBlocks: AuthorBlocklist, observations: TagObservationStore, deduplicateMedia: Bool) {
        self.mode = mode; self.query = query; self.active = active; self.selected = selected
        _store = ObservedObject(wrappedValue: store); _draft = draft; _selectionError = selectionError
        _session = ObservedObject(wrappedValue: session); _blocklist = ObservedObject(wrappedValue: blocklist)
        _authorBlocks = ObservedObject(wrappedValue: authorBlocks); _observations = ObservedObject(wrappedValue: observations)
        self.deduplicateMedia = deduplicateMedia
        _lastStableQuery = State(initialValue: query)
    }
    let deduplicateMedia: Bool
    @State private var actionTask: Task<Void, Never>?
    @State private var footerVisible = false
    @State private var requestedAtResultCount: Int?
    @ScaledMetric(relativeTo: .caption) private var tagColumnWidth: CGFloat = 112
    private var key: TagDirectoryStore.Key { .init(mode: mode, keyword: effectiveQuery, identity: session.tagLookupIdentity) }
    private var valid: Bool { effectiveQuery.isEmpty || MediaSearchText.valid(effectiveQuery, mode: .tag) }
    private var visibilityPolicy: TagAvailabilityPolicy {
        .init(blockedTags: blocklist.names, blockedAuthorIDs: authorBlocks.blockedIDs,
              blockedAuthorHandles: authorBlocks.blockedHandles, deduplicateMediaAssets: deduplicateMedia)
    }
    private func estimate(_ tag: SearchTag) -> TagObservationEstimate? {
        return observations.estimate(tagID: tag.id, scope: session.tagEvidenceIdentity, policy: visibilityPolicy)
    }
    private var matchedTags: [SearchTag] {
        guard mode == .common else { return store.tags }
        let selectedIDs = Set(draft.map(\.id))
        let candidates = store.tags.enumerated().compactMap { offset, tag -> (offset: Int, tag: SearchTag, rank: Int)? in
            let sample = estimate(tag)
            guard selectedIDs.contains(tag.id) || sample?.isRecommended == true else { return nil }
            return (offset, tag, sample?.emptyUntil == nil ? (sample?.countLowerBound ?? 0) : -1)
        }
        return candidates.sorted { $0.rank == $1.rank ? $0.offset < $1.offset : $0.rank > $1.rank }.map(\.tag)
    }
    private var displayedTags: [SearchTag] {
        let results = matchedTags
        let resultIDs = Set(results.map(\.id))
        return draft.filter { !resultIDs.contains($0.id) } + results
    }
    private var canRetry: Bool { store.key == key && valid && (store.error != nil || store.onlineError != nil) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if store.key == key { tagResults }
                else if valid { loadingIndicator }
                else { EmptyView() }
            }
            .pageScrollContentInsets().padding(.top, FloatingPageChrome.groupInset)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("tag-directory.scroll")
        .existingFeedbackToast(selectionError, id: selectionErrorEvent, active: active && selected, scope: session.feedIdentity)
        .existingFeedbackToast(!valid ? MediaSearchText.validationMessage : nil, active: active && selected, scope: session.feedIdentity, dismissOnClear: true)
        .existingFeedbackToast(canRetry && !store.loading && matchedTags.isEmpty ? "标签读取失败" : nil,
                               active: active && selected, scope: session.feedIdentity)
        .pageContentViewport(active: active && selected)
        .task(id: active ? key : nil) {
            guard active else { return }
            guard valid else { store.cancel(); return }
            await store.reload(key: key, source: session)
        }
        .refreshable {
            guard active, stableSelected, valid else { return }
            actionTask?.cancel(); actionTask = nil; requestedAtResultCount = nil
            await store.reload(key: key, source: session, forceRemote: true)
        }
        .onChange(of: store.loading) { _, loading in if !loading { loadMoreIfVisible() } }
        .onChange(of: key) { _, _ in cancelPaginationAction() }
        .onChange(of: query) { _, value in
            if segmentMotion?.isInteracting != true { lastStableQuery = value }
        }
        .onChange(of: segmentMotion?.isInteracting ?? false) { _, interacting in
            if interacting { return }
            lastStableQuery = query
            if stableSelected { loadMoreIfVisible() }
        }
        .onChange(of: stableSelected) { _, stable in
            if stable { loadMoreIfVisible() } else { cancelPaginationAction() }
        }
        .onDisappear { actionTask?.cancel(); actionTask = nil; store.cancel() }
    }

    private var loadingIndicator: some View { ProgressView().controlSize(.small).frame(maxWidth: .infinity).accessibilityLabel("正在加载标签") }
    @ViewBuilder private var tagResults: some View {
        let tags = displayedTags
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tagColumnWidth), spacing: FloatingPageChrome.groupInset)], alignment: .leading, spacing: ContentMetrics.Tag.gap) {
            ForEach(tags) { tag in
                let chosen = draft.contains(where: { $0.id == tag.id })
                let blocked = blocklist.names.contains(TagPolicy.normalize(tag.name))
                Button { toggle(tag) } label: { WorkTagLabel(title: tag.name, selected: chosen, blocked: blocked, fillsHitColumn: true) }
                    .buttonStyle(SegmentedContentButtonStyle()).accessibilityIdentifier("tag-directory.tag.\(tag.id)")
                    .accessibilityLabel(tag.name).accessibilityValue((chosen ? "已选择" : "未选择") + "，" + status(tag) + (blocked ? "，已在本机屏蔽" : ""))
            }
        }
        tagFooter(hasResults: !matchedTags.isEmpty)
    }
    @ViewBuilder private func tagFooter(hasResults: Bool) -> some View {
        let canPage = !store.reachedEnd && (hasResults || mode == .catalog)
        if canRetry && !store.loading {
            EmptyView()
        } else if store.loading || canPage {
            let footer = ZStack {
                Color.clear
                if store.loading { loadingIndicator }
                else if canPage && actionTask == nil && requestedAtResultCount == matchedTags.count {
                    Button { requestedAtResultCount = nil; loadMoreIfVisible() } label: {
                        Label("继续查找", systemImage: "chevron.down").font(.footnote).padding(.horizontal, 12)
                            .frame(minHeight: FloatingPageChrome.controlHeight).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.tint)
                }
            }.frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight).id(key)
            if #available(iOS 18, *) { footer.onScrollVisibilityChange(threshold: 0.25, footerVisibilityChanged).onDisappear { footerVisible = false } }
            else { footer.onAppear { footerVisibilityChanged(true) }.onDisappear { footerVisibilityChanged(false) } }
        } else if !hasResults {
            Text(store.tags.isEmpty ? "没有匹配标签" : "暂无常用标签").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func cancelPaginationAction() {
        actionGeneration += 1
        actionTask?.cancel()
        actionTask = nil
        requestedAtResultCount = nil
    }
    private func footerVisibilityChanged(_ visible: Bool) {
        footerVisible = visible
        if visible { loadMoreIfVisible() } else if !store.loading { requestedAtResultCount = nil }
    }
    private func loadMoreIfVisible() {
        guard active, stableSelected, footerVisible, (mode == .catalog || !matchedTags.isEmpty),
              actionTask == nil, store.key == key, !store.loading, !store.reachedEnd,
              store.error == nil, store.onlineError == nil else { return }
        let count = matchedTags.count
        guard requestedAtResultCount != count else { return }
        requestedAtResultCount = count
        let requestKey = key
        perform {
            await store.next(source: session)
            if !Task.isCancelled, key == requestKey, footerVisible, matchedTags.count == count,
               !store.reachedEnd, store.error == nil, store.onlineError == nil { await store.next(source: session) }
        }
    }
    private func status(_ tag: SearchTag) -> String {
        guard let sample = estimate(tag) else { return "暂无浏览样本" }
        if sample.emptyUntil != nil { return "近期搜索未显示作品" }
        guard sample.countLowerBound > 0 else { return "浏览样本已过期" }
        return "近 30 天见过 ≥\(sample.countLowerBound) 条"
    }
    private func toggle(_ tag: SearchTag) {
        if draft.contains(where: { $0.id == tag.id }) { draft.removeAll { $0.id == tag.id }; selectionError = nil }
        else if draft.count < 8 { draft.append(tag); selectionError = nil }
        else { selectionErrorEvent += 1; selectionError = "最多选择 8 个标签" }
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard actionTask == nil else { return }
        let requestedKey = key
        actionGeneration += 1
        let generation = actionGeneration
        actionTask = Task {
            defer { if actionGeneration == generation { actionTask = nil } }
            guard !Task.isCancelled, requestedKey == key, active, stableSelected else { return }
            await action()
            guard !Task.isCancelled, requestedKey == key, active, stableSelected, actionGeneration == generation else { return }
            actionTask = nil
            loadMoreIfVisible()
        }
    }
}

struct AuthorSearchPicker: View {
    @Binding var selected: Creator?
    let title: String
    let allowsClear: Bool
    @State private var draft: Creator?
    @StateObject private var lookup = SearchLookupStore()
    @State private var selectionIdentity: String?
    @EnvironmentObject private var session: SiteSession

    init(selected: Binding<Creator?>, title: String = "选择作者", allowsClear: Bool = true) {
        _selected = selected
        _draft = State(initialValue: selected.wrappedValue)
        self.title = title
        self.allowsClear = allowsClear
    }
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private var keyword: String { MediaSearchText.authorKeyword(text) }
    var body: some View {
        AuthorLookupResults(keyword: keyword, selectedID: draft?.id, lookup: lookup, onSelect: { draft = $0 }) {
            HStack(spacing: FloatingPageChrome.spacing) {
                FloatingPageIcon(symbol: "magnifyingglass")
                    .foregroundStyle(.secondary).frame(width: 28).accessibilityHidden(true)
                TextField("输入作者昵称", text: $text, prompt: FloatingPageChrome.fieldPrompt("用户名或开头"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("author-picker.input")
                if allowsClear && (selected != nil || draft != nil) {
                    Button { draft = nil } label: {
                        Text("不限作者")
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minHeight: FloatingPageChrome.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft == nil ? Color.secondary : Color.accentColor)
                    .disabled(draft == nil)
                    .accessibilityIdentifier("author-picker.clear")
                }
            }
            .frame(minHeight: FloatingPageChrome.controlHeight)
            .padding(.horizontal, 12)
            .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("author-picker.field")
            .font(FloatingPageChrome.controlFont)
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingTitleBar(title, observesContentViewport: false) {
            Button {
                dismiss()
            } label: {
                FloatingPageIcon(symbol: "checkmark")
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .disabled(draft == nil && selected == nil)
            .accessibilityLabel("完成")
            .accessibilityIdentifier("author-picker.done")
        }
        .onAppear { if selectionIdentity == nil { selectionIdentity = session.tagLookupIdentity } }
        .commitOnPageReturn { [draft, selectionIdentity] in
            if selectionIdentity == session.tagLookupIdentity { selected = draft }
        }
        .ordinaryAppearance()
    }
}

struct AuthorLookupResults<Header: View>: View {
    private struct Activation: Equatable {
        let key: SearchLookupStore.Key
        let active: Bool
    }
    let keyword: String
    var selectedID: Int?
    var opensProfiles: Bool
    let isActive: Bool
    let onSelect: (Creator) -> Void
    @ViewBuilder let header: () -> Header
    @EnvironmentObject private var session: SiteSession
    @Environment(\.rootPageParticipation) private var rootParticipation
    @ObservedObject private var lookup: SearchLookupStore
    @Binding private var anchor: Int?
    private let tracksAnchor: Bool

    init(keyword: String, selectedID: Int? = nil, opensProfiles: Bool = false, isActive: Bool = true,
         lookup: SearchLookupStore, anchor: Binding<Int?>? = nil,
         onSelect: @escaping (Creator) -> Void, @ViewBuilder header: @escaping () -> Header) {
        self.keyword = keyword
        self.selectedID = selectedID
        self.opensProfiles = opensProfiles
        self.isActive = isActive
        self.onSelect = onSelect
        self.header = header
        _lookup = ObservedObject(wrappedValue: lookup)
        _anchor = anchor ?? .constant(nil)
        tracksAnchor = anchor != nil
    }

    private var key: SearchLookupStore.Key { .init(mode: .author, text: keyword, identity: session.feedIdentity, blockedTags: []) }
    private var valid: Bool { MediaSearchText.valid(keyword, mode: .author) }
    private var loadingFirstPage: Bool {
        valid && (lookup.key != key || (lookup.authors.isEmpty && lookup.loading))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                header()
                results
            }
            .pageScrollContentInsets()
            .scrollTargetLayout()
        }
        .scrollPosition(id: $anchor, anchor: .top)
        .pageContentViewport(active: isActive && rootParticipation.canPrepare,
                             initiallyAtTop: tracksAnchor ? (anchor == nil || anchor == lookup.authors.first?.id) : nil)
        .accessibilityIdentifier("author-lookup.results")
        .existingFeedbackToast(lookup.key == key ? lookup.error : nil, active: isActive, scope: session.feedIdentity)
        .existingFeedbackToast(!keyword.isEmpty && !valid ? MediaSearchText.validationMessage : nil,
                               active: isActive, scope: session.feedIdentity, dismissOnClear: true)
        .overlay {
            if loadingFirstPage {
                Color.clear
                    .overlay { loadingIndicator.accessibilityIdentifier("author-lookup.initial-progress") }
                    .ignoresSafeArea(.container, edges: .vertical)
                    .allowsHitTesting(false)
            }
        }
        .task(id: Activation(key: key, active: isActive && rootParticipation.isActive)) {
            guard isActive, rootParticipation.isActive else { return }
            guard lookup.key != key else { return }
            lookup.clear()
            guard valid else { return }
            do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation() } catch { return }
            await lookup.reload(key: key, source: session)
        }
    }

    @ViewBuilder private var results: some View {
        if lookup.key == key {
            ForEach(Array(lookup.authors.enumerated()), id: \.element.id) { index, author in
                Button { onSelect(author) } label: {
                    HStack(spacing: FloatingPageChrome.spacing) {
                        AuthorRowIdentity(name: author.username, showsHandle: true, position: opensProfiles ? index + 1 : nil)
                        Spacer(minLength: 0)
                        if opensProfiles {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        } else if selectedID == author.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .authorCardRow()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
                    .contentShape(Rectangle())
                }
                .id(author.id)
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedID == author.id ? .isSelected : [])
                .accessibilityLabel("@" + author.username)
                .accessibilityIdentifier(opensProfiles ? "search.author.\(author.id)" : "author-picker.author.\(author.id)")
            }
            if lookup.error != nil {
                HStack {
                    Spacer(minLength: 0)
                    StatusReloadButton { Task { await lookup.next(source: session) } }
                }
            } else if isActive && rootParticipation.isActive && !lookup.authors.isEmpty && !lookup.reachedEnd {
                loadingIndicator
                    .frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight)
                    .task(id: lookup.authors.last?.id) {
                        guard lookup.key == key else { return }
                        await lookup.next(source: session)
                    }
            } else if lookup.authors.count >= SearchLookupStore.authorResultLimit {
                Text("已显示 \(lookup.authors.count) 位作者，可缩小搜索范围")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if lookup.authors.isEmpty && lookup.reachedEnd {
                Text("没有返回匹配作者").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var loadingIndicator: some View {
        ProgressView().controlSize(.small).accessibilityLabel("正在搜索作者")
    }
}
