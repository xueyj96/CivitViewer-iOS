import SwiftUI

struct TagDirectoryView: View {
    @Binding var selected: [SearchTag]
    @ObservedObject var store: TagDirectoryStore
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
    @State private var actionTask: Task<Void, Never>?
    @State private var footerVisible = false
    @State private var requestedAtResultCount: Int?
    init(selected: Binding<[SearchTag]>, store: TagDirectoryStore) {
        _selected = selected; self.store = store
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
    private var key: TagDirectoryStore.Key { .init(mode: activeMode, keyword: keyword, identity: session.tagLookupIdentity) }
    private var canRetry: Bool { store.key == key && valid && (store.error != nil || store.onlineError != nil) }
    private var valid: Bool { keyword.isEmpty || MediaSearchText.valid(keyword, mode: .tag) }
    private var visibilityPolicy: TagAvailabilityPolicy {
        .init(blockedTags: blocklist.names, blockedAuthorIDs: authorBlocks.blockedIDs,
              blockedAuthorHandles: authorBlocks.blockedHandles, deduplicateMediaAssets: deduplicateMedia)
    }
    private var evidenceScope: String { session.tagEvidenceIdentity }
    private var matchedTags: [SearchTag] {
        guard activeMode == .common else { return store.tags }
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
    #if DEBUG && targetEnvironment(simulator)
    private var sampledTagCount: Int { store.tags.filter { estimate($0) != nil }.count }
    #endif
    private func estimate(_ tag: SearchTag) -> TagObservationEstimate? {
        observations.estimate(tagID: tag.id, scope: evidenceScope, policy: visibilityPolicy)
    }
    private func status(_ tag: SearchTag) -> String {
        guard let sample = estimate(tag) else { return "暂无浏览样本" }
        if sample.emptyUntil != nil { return "近期搜索未显示作品" }
        guard sample.countLowerBound > 0 else { return "浏览样本已过期" }
        return "近 30 天见过 ≥\(sample.countLowerBound) 条"
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: FloatingPageChrome.groupInset) {
                    HStack(spacing: FloatingPageChrome.spacing) {
                        FloatingPageIcon(symbol: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("搜索标签名称", text: $query, prompt: FloatingPageChrome.fieldPrompt("搜索标签名称"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("tag-search-input")
                        Button { query = "" } label: {
                            FloatingPageIcon(symbol: "xmark")
                                .foregroundStyle(.secondary)
                                .frame(width: FloatingPageChrome.controlHeight, height: FloatingPageChrome.controlHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(query.isEmpty ? 0 : 1)
                        .allowsHitTesting(!query.isEmpty)
                        .accessibilityHidden(query.isEmpty)
                        .accessibilityLabel("清空标签名称")
                    }
                    .font(FloatingPageChrome.controlFont)
                    .frame(minHeight: FloatingPageChrome.controlHeight)
                    .padding(.horizontal, 12)
                    .background { FloatingPageFieldSurface() }
                    if canRetry { retryButton }
                    else { prefixMenu }
                }
                FloatingSegmentedControl(title: "浏览标签", selection: browsingMode,
                                         options: TagDirectoryMode.allCases, optionTitle: { $0.title },
                                         identifier: "tag-directory.mode")
            }
            .padding(.horizontal, FloatingPageChrome.pageInset)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.secondary) }
                    if store.key == key { tagResults }
                    else if valid { loadingIndicator }
                    else { Text(MediaSearchText.validationMessage).font(.caption).foregroundStyle(.secondary) }
                }
                .pageScrollContentInsets()
                .padding(.top, FloatingPageChrome.groupInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("tag-directory.scroll")
        }
        .floatingTitleBar("选择标签") {
            Button {
                if selectionIdentity == session.tagLookupIdentity { selected = draft }
                dismiss()
            } label: {
                Text("完成").frame(minWidth: FloatingPageChrome.surfaceHeight)
            }
            .accessibilityValue("已选 \(draft.count) / 8")
        }
            .task(id: key) {
                guard valid else { store.cancel(); return }
                await store.reload(key: key, source: session)
            }
            .task(id: evidenceScope) { await observations.activate(scope: evidenceScope) }
            .onAppear { if selectionIdentity == nil { selectionIdentity = session.tagLookupIdentity } }
            .onChange(of: session.tagLookupIdentity) { _, identity in
                if let selectionIdentity, selectionIdentity != identity { dismiss() }
            }
            .refreshable {
                guard valid else { return }
                actionTask?.cancel(); actionTask = nil; requestedAtResultCount = nil
                await store.reload(key: key, source: session, forceRemote: true)
            }
            .onChange(of: key) { _, _ in
                actionTask?.cancel(); actionTask = nil
                requestedAtResultCount = nil
            }
            .onChange(of: store.loading) { _, loading in
                if !loading { loadMoreIfVisible() }
            }
            .onDisappear { actionTask?.cancel(); actionTask = nil; store.cancel() }
            #if DEBUG && targetEnvironment(simulator)
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") {
                    let value = "mode=\(activeMode.rawValue);selected=\(draft.map(\.id));loaded=\(store.tags.count);visible=\(displayedTags.count);sampled=\(sampledTagCount);probeReads=\(session.tagCandidateReads);revision=\(observations.revision)"
                    Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("qa.tag-availability55").accessibilityValue(value)
                }
            }
            #endif
        .ordinaryAppearance()
    }
    private var prefixMenu: some View {
        Menu {
            Section("字母") {
                ForEach(Array("abcdefghijklmnopqrstuvwxyz"), id: \.self) { letter in
                    Button(String(letter).uppercased()) { showCatalog = true; query = String(letter) }
                }
            }
            Section("数字") {
                ForEach(0...9, id: \.self) { digit in
                    Button(String(digit)) { showCatalog = true; query = String(digit) }
                }
            }
        } label: { FloatingPageIcon(symbol: "textformat.abc") }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .accessibilityLabel("首字母")
            .accessibilityIdentifier("tag-directory.prefix")
    }
    private var retryButton: some View {
        Button {
            requestedAtResultCount = nil
            perform {
                if store.onlineError != nil { await store.retryOnline(source: session) }
                else if !store.reachedEnd { await store.next(source: session) }
                else { await store.reload(key: key, source: session) }
            }
        } label: {
            FloatingPageIcon(symbol: "arrow.clockwise")
        }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .disabled(store.loading)
        .accessibilityLabel("重试标签")
        .accessibilityHint(matchedTags.isEmpty ? "重新请求标签" : "重新请求后续标签")
        .accessibilityIdentifier("tag-directory.retry")
    }
    private var loadingIndicator: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            .accessibilityLabel("正在加载标签")
    }
    @ScaledMetric(relativeTo: .caption) private var tagColumnWidth: CGFloat = 112

    @ViewBuilder private var tagResults: some View {
        let tags = displayedTags
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tagColumnWidth), spacing: FloatingPageChrome.groupInset)], alignment: .leading, spacing: 0) {
            ForEach(tags) { tag in
                let chosen = draft.contains(where: { $0.id == tag.id })
                let blocked = blocklist.names.contains(TagPolicy.normalize(tag.name))
                Button { toggle(tag) } label: {
                    WorkTagLabel(title: tag.name, selected: chosen, blocked: blocked, fillsHitColumn: true)
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("tag-directory.tag.\(tag.id)")
                    .accessibilityLabel(tag.name)
                    .accessibilityValue((chosen ? "已选择" : "未选择") + "，" + status(tag) + (blocked ? "，已在本机屏蔽" : ""))
            }
        }
        tagFooter(hasResults: !matchedTags.isEmpty)
    }

    @ViewBuilder private func tagFooter(hasResults: Bool) -> some View {
        let canPage = !store.reachedEnd && (hasResults || activeMode == .catalog)
        if canRetry && !store.loading {
            if !hasResults { Text("标签读取失败").font(.footnote).foregroundStyle(.secondary) }
        } else if store.loading || canPage {
            let footer = ZStack {
                Color.clear

                if store.loading {
                    loadingIndicator
                } else if canPage && actionTask == nil && requestedAtResultCount == matchedTags.count {
                    Button {
                        requestedAtResultCount = nil
                        loadMoreIfVisible()
                    } label: {
                        Label("继续查找", systemImage: "chevron.down")
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .frame(minHeight: FloatingPageChrome.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight)
            .id(key)
            if #available(iOS 18, *) {
                footer
                    .onScrollVisibilityChange(threshold: 0.25, footerVisibilityChanged)
                    .onDisappear { footerVisible = false }
            } else {
                footer
                    .onAppear { footerVisibilityChanged(true) }
                    .onDisappear { footerVisibilityChanged(false) }
            }
        } else if !hasResults {
            Text(store.tags.isEmpty ? "没有匹配标签" : "暂无常用标签")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func footerVisibilityChanged(_ visible: Bool) {
        footerVisible = visible
        if visible { loadMoreIfVisible() }
        else if !store.loading { requestedAtResultCount = nil }
    }

    private func loadMoreIfVisible() {
        guard footerVisible, (activeMode == .catalog || !matchedTags.isEmpty),
              actionTask == nil, store.key == key, !store.loading, !store.reachedEnd,
              store.error == nil, store.onlineError == nil else { return }
        let count = matchedTags.count
        guard requestedAtResultCount != count else { return }
        requestedAtResultCount = count
        let requestKey = key
        perform {
            await store.next(source: session)
            // Skip at most one extra batch if quality filtering or deduplication left this viewport unchanged.
            if !Task.isCancelled, key == requestKey, footerVisible, matchedTags.count == count,
               !store.reachedEnd, store.error == nil, store.onlineError == nil {
                await store.next(source: session)
            }
        }
    }


    private func toggle(_ tag: SearchTag) {
        if draft.contains(where: { $0.id == tag.id }) { draft.removeAll { $0.id == tag.id }; selectionError = nil }
        else if draft.count < 8 { draft.append(tag); selectionError = nil }
        else { selectionError = "最多选择 8 个标签" }
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard actionTask == nil else { return }
        let requestedKey = key
        actionTask = Task {
            guard !Task.isCancelled, requestedKey == key else { return }
            await action()
            guard !Task.isCancelled, requestedKey == key else { return }
            actionTask = nil
            loadMoreIfVisible()
        }
    }
}

struct AuthorSearchPicker: View {
    @Binding var selected: Creator?
    let title: String
    @State private var draft: Creator?

    init(selected: Binding<Creator?>, title: String = "选择作者") {
        _selected = selected
        _draft = State(initialValue: selected.wrappedValue)
        self.title = title
    }
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private var keyword: String { MediaSearchText.authorKeyword(text) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                HStack(spacing: FloatingPageChrome.spacing) {
                    FloatingPageIcon(symbol: "magnifyingglass")
                        .foregroundStyle(.secondary).frame(width: 28).accessibilityHidden(true)
                    TextField("输入作者昵称", text: $text, prompt: FloatingPageChrome.fieldPrompt("用户名或开头"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("author-picker.input")
                    if selected != nil || draft != nil {
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

                AuthorLookupResults(keyword: keyword, selectedID: draft?.id, onSelect: { draft = $0 })
            }
            .font(FloatingPageChrome.controlFont)
            .pageScrollContentInsets()
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingTitleBar(title) {
            Button {
                selected = draft
                dismiss()
            } label: {
                FloatingPageIcon(symbol: "checkmark")
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .disabled(draft == nil && selected == nil)
            .accessibilityLabel("完成")
            .accessibilityIdentifier("author-picker.done")
        }
        .ordinaryAppearance()
    }
}

struct AuthorLookupResults: View {
    let keyword: String
    var selectedID: Int? = nil
    var opensProfiles = false
    let onSelect: (Creator) -> Void
    @EnvironmentObject private var session: SiteSession
    @StateObject private var lookup = SearchLookupStore()

    private var key: SearchLookupStore.Key { .init(mode: .author, text: keyword, identity: session.feedIdentity, blockedTags: []) }

    var body: some View {
        VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
            if lookup.key == key {
                ForEach(lookup.authors) { author in
                    Button { onSelect(author) } label: {
                        HStack(spacing: FloatingPageChrome.spacing) {
                            AuthorRowIdentity(name: author.username, showsHandle: true)
                            Spacer(minLength: 0)
                            if opensProfiles {
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            } else if selectedID == author.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight, alignment: .leading)
                        .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedID == author.id ? .isSelected : [])
                    .accessibilityLabel("@" + author.username)
                    .accessibilityIdentifier(opensProfiles ? "search.author.\(author.id)" : "author-picker.author.\(author.id)")
                }
                if lookup.loading { loadingIndicator }
                else if let error = lookup.error {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        StatusReloadButton { Task { await lookup.reload(key: key, source: session) } }
                    }
                } else if lookup.authors.isEmpty && !keyword.isEmpty {
                    Text("没有返回匹配作者").font(.footnote).foregroundStyle(.secondary)
                }
            } else if !keyword.isEmpty {
                if MediaSearchText.valid(keyword, mode: .author) { loadingIndicator }
                else { Text(MediaSearchText.validationMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: key) {
            guard lookup.key != key else { return }
            lookup.clear()
            guard MediaSearchText.valid(keyword, mode: .author) else { return }
            do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation() } catch { return }
            await lookup.reload(key: key, source: session)
        }
    }

    private var loadingIndicator: some View {
        ProgressView().controlSize(.small).accessibilityLabel("正在搜索作者")
    }
}
