import SwiftUI
import Observation

// A tap toggles the bookmark. Folder management is a separate long-press action.
struct FavoriteButton: View {
    let item: MediaItem
    let active: Bool
    @EnvironmentObject private var session: SiteSession
    let onManage: (MediaItem) -> Void
    private struct MembershipRequest: Equatable {
        let session: SiteSession.AccountSessionID
        let workID: Int
    }
    private var membershipRequest: MembershipRequest? {
        guard active, let identity = session.collectionSessionID else { return nil }
        return .init(session: identity, workID: item.id)
    }
    private var saved: Bool { session.isBookmarked(item.id) }
    private var saving: Bool { session.savingFavoriteID == item.id }
    var body: some View {
        AppContextButton { toggleFavorite() } label: {
            MediaIconActionLabel(title: saved ? "已收藏" : "收藏", symbol: saved ? "bookmark.fill" : "bookmark", qaKey: "control.\(item.id).favorite")
        } menu: {
            Button("选择收藏夹", systemImage: "folder") { onManage(item) }
                .accessibilityIdentifier("favorite.manage")
        }
        .buttonStyle(.plain).disabled(saving)
        .accessibilityAction(named: Text("选择收藏夹")) { onManage(item) }
        .accessibilityLabel(saved ? "已收藏" : "收藏")
        .accessibilityIdentifier("favorite-\(item.id)")
        .task(id: membershipRequest) { [membershipRequest] in
            if let membershipRequest, membershipRequest.session == session.collectionSessionID {
                _ = try? await session.refreshSavedMembership(membershipRequest.workID)
            }
        }
    }

    private func toggleFavorite() {
        guard let identity = session.collectionSessionID else {
            onManage(item)
            return
        }
        do {
            try session.toggleFavorite(imageID: item.id, wasSaved: saved, for: identity)
        } catch {
            session.message = error.localizedDescription
        }
    }
}

private extension EnvironmentValues {
    @Entry var authorizeCollections: (() -> Void)? = nil
}

struct CollectionAccessView: View {
    @EnvironmentObject private var session: SiteSession
    @Environment(\.authorizeCollections) private var authorize
    var body: some View {
        ScrollView {
            PageContentCard {
                VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                    Label(session.account == nil ? "登录后查看收藏" : "启用账号收藏", systemImage: "bookmark")
                        .font(AppTypography.rowTitle.weight(.medium))
                    Text("授权后可查看、保存和移除账号收藏。")
                        .font(AppTypography.supportingText).foregroundStyle(.secondary)
                    Button { authorize?() } label: {
                        Text(session.account == nil ? "登录并启用收藏" : "补充收藏授权")
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .accent))
                }
                .padding(.vertical, FloatingPageChrome.cardInset)
            }
            .padding(.horizontal, FloatingPageChrome.pageInset)
        }
        .ordinaryAppearance()
    }
}

/// The page root survives the access/loaded content switch after authorization.
private struct CollectionAuthorization: ViewModifier {
    @EnvironmentObject private var session: SiteSession
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .environment(\.authorizeCollections, { shown = true })
            .businessPage(isPresented: $shown, onDismiss: { session.oauth.cancel() }) { close in
                LoginView(forCollections: true, onClose: close)
            }
            .onChange(of: session.hasCollectionAccess) { _, allowed in if allowed { shown = false } }
    }
}

private extension View {
    func collectionAuthorization() -> some View { modifier(CollectionAuthorization()) }
}

struct CollectionsView: View {
    var showsBack = false

    @EnvironmentObject private var session: SiteSession
    @State private var error: String?
    @State private var selectedCollectionIDs = Set<Int>()
    @State private var filter = FeedFilter(kind: .image)
    @State private var cachedFolders: (scope: String, folders: [SavedCollection])?
    private var refreshScope: String { "\(session.feedIdentity):\(session.hasCollectionAccess)" }
    private var presentedFolders: [SavedCollection] {
        if session.collectionsKnown { return session.collections }
        return cachedFolders?.scope == refreshScope ? (cachedFolders?.folders ?? []) : []
    }
    private var availableCollectionIDs: Set<Int> { Set(presentedFolders.map(\.id)) }
    private var selection: Set<Int> {
        let available = selectedCollectionIDs.intersection(availableCollectionIDs)
        return available.isEmpty ? Set(presentedFolders.prefix(1).map(\.id)) : available
    }

    var body: some View {
        let ids = selection
        Group {
            if session.hasCollectionAccess, let first = ids.first {
                let source: FeedSource = ids.count == 1 ? .collection(first) : .collections(ids)
                CollectionWorksView(source: source, filter: $filter, showsBack: showsBack, onRefreshCollections: refresh, showsFolders: presentedFolders.count > 1) {
                    if presentedFolders.count > 1 { collectionPicker(ids: ids) }
                }
                .id(source)
            } else {
                Group {
                    if !session.hasCollectionAccess {
                        CollectionAccessView()
                    } else if let error {
                        FailureView(message: error) { Task { await refresh() } }
                    } else if !session.collectionsKnown {
                        ProgressView().controlSize(.small).accessibilityLabel("正在读取收藏")
                    } else {
                        ScrollView {
                            PageStatusCard(title: "暂无收藏作品", symbol: "bookmark")
                                .padding(.horizontal, FloatingPageChrome.pageInset)
                        }
                        .refreshable { await refresh() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .avoidOverlaidTabBar()
                .floatingPageBar("collections.top-bar", layoutIdentity: presentedFolders.count > 1) {
                    HStack(spacing: FloatingPageChrome.groupInset) {
                        if showsBack { FloatingPageBackButton() }
                        CollectionDownloadsLink()
                        Spacer()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("collections.access-actions")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .collectionAuthorization()
        .ordinaryAppearance().environment(\.defaultMinListRowHeight, 52)
        .task(id: refreshScope) {
            let scope = refreshScope
            if collectionListCachingEnabled, session.hasCollectionAccess, !session.collectionsKnown,
               let owner = session.account?.id,
               let folders = await CollectionListCache.shared.folders(owner: owner),
               !Task.isCancelled, scope == refreshScope {
                cachedFolders = (scope, folders)
            }
            await refresh()
        }
    }

    private func collectionPicker(ids: Set<Int>) -> some View {
        let title: String = if ids.count == 1, let folder = presentedFolders.first(where: { ids.contains($0.id) }) {
            folder.name
        } else {
            "已选 \(ids.count) 个收藏夹"
        }
        return AppMultiValueSelector(title: "选择收藏夹", selection: Binding(get: { ids }, set: {
            selectedCollectionIDs = $0.intersection(availableCollectionIDs)
        }), options: presentedFolders.map(\.id), name: { id in
            presentedFolders.first(where: { $0.id == id })?.name ?? "收藏夹"
        }) {
            FloatingPageIcon(symbol: ids.count > 1 ? "folder.fill" : "folder")
        }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .id(session.collectionSessionID)
        .accessibilityLabel("选择收藏夹").accessibilityValue(title)
        .accessibilityIdentifier("collections.folder-picker")
    }

    private func refresh() async {
        guard session.hasCollectionAccess, !Task.isCancelled else { return }
        let scope = refreshScope
        error = nil
        do {
            try await session.refreshCollections()
            guard !Task.isCancelled, scope == refreshScope else { return }
            cachedFolders = nil
            if collectionListCachingEnabled, session.collectionsKnown, let owner = session.account?.id {
                await CollectionListCache.shared.storeFolders(session.collections, owner: owner)
            }
        }
        catch {
            if !Task.isCancelled, refreshScope == scope { self.error = error.localizedDescription }
        }
    }
}

@MainActor private var collectionListCachingEnabled: Bool {
    #if DEBUG && targetEnvironment(simulator)
    if CollectionPagingQA.enabled { return CollectionListCacheQA.fixture != nil }
    #endif
    return true
}

struct FavoriteEditor: View {
    let item: MediaItem
    let onClose: () -> Void
    @EnvironmentObject private var session: SiteSession
    @Environment(\.colorScheme) private var scheme
    @State private var original = Set<Int>()
    @State private var selected = Set<Int>()
    @State private var loadingRequest: (id: UUID, session: SiteSession.AccountSessionID)?
    @State private var loadedSession: SiteSession.AccountSessionID?
    @State private var error: String?
    private var loading: Bool {
        loadingRequest.map { $0.session == session.collectionSessionID } ?? false
    }
    private var loaded: Bool {
        loadedSession.map { $0 == session.collectionSessionID } ?? false
    }
    private var saving: Bool { session.savingFavoriteID != nil }
    var body: some View {
        NavigationStack {
            Group {
                if !session.hasCollectionAccess { CollectionAccessView() }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                            if loaded {
                                ForEach(session.collections) { collection in
                                    FavoriteFolderRow(collection: collection, selected: selected.contains(collection.id)) {
                                        if selected.remove(collection.id) == nil { selected.insert(collection.id) }
                                    }
                                    .favoriteFolderCard()
                                    .disabled(saving)
                                }
                                if session.collections.contains(where: { $0.read == "Public" }) {
                                    Text("公开收藏夹中的作品可被他人看到。")
                                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                                }
                                if session.collections.isEmpty {
                                    PageStatusCard(title: "暂无可用收藏夹", symbol: "folder")
                                }
                            }
                            if (!loaded && error == nil) || saving {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(saving ? "正在同步收藏…" : "正在读取收藏状态")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .accessibilityIdentifier("favorite-editor-status")
                            }
                            if let error {
                                PageStatusCard(title: "", symbol: "exclamationmark.circle", retryTitle: "重新读取收藏状态") {
                                    Task { await load() }
                                }
                                .disabled(saving || loading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FloatingPageChrome.pageInset)
                        .padding(.bottom, FloatingPageChrome.pageInset)
                    }
                    .background(AppTheme.pageBackground(for: scheme).ignoresSafeArea())
                }
            }
            .floatingTitleBar(item.isVideo ? "收藏视频" : "收藏图片", leading: {
                Button { onClose() } label: { FloatingPageIcon(symbol: "xmark") }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .accessibilityLabel("取消")
            }) {
                Button { save() } label: { FloatingPageIcon(symbol: "checkmark") }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .accessibilityLabel("保存")
                    .disabled(!loaded || loading || saving || selected == original)
            }
            .pageReturnAction(enabled: !saving) {
                guard !saving else { return false }
                onClose()
                return true
            }
            .task(id: session.collectionSessionID) { await load() }
        }
        .collectionAuthorization().ordinaryPresentationAppearance()
        .existingFeedbackToast(error, id: error, active: error != nil, scope: session.feedIdentity)
    }
    private func load() async {
        guard !loading, let identity = session.collectionSessionID, !Task.isCancelled else { return }
        let requestID = UUID()
        loadingRequest = (requestID, identity)
        loadedSession = nil
        error = nil
        defer { if loadingRequest?.id == requestID { loadingRequest = nil } }
        do {
            try await session.refreshCollections()
            let ids = try await session.refreshSavedMembership(item.id, force: true)
            guard !Task.isCancelled, identity == session.collectionSessionID, loadingRequest?.id == requestID else { return }
            original = ids
            selected = ids.isEmpty ? session.defaultCollectionIDs : ids
            loadedSession = identity
        } catch {
            if !Task.isCancelled, identity == session.collectionSessionID, loadingRequest?.id == requestID { self.error = error.localizedDescription }
        }
    }
    private func save() {
        guard let loadedSession, loaded, !saving, selected != original else { return }
        error = nil
        do {
            try session.submitCollectionSelection(imageID: item.id, original: original, selected: selected, for: loadedSession)
            onClose()
        } catch {
            self.error = error.localizedDescription
            self.loadedSession = nil
        }
    }
}

private struct FavoriteFolderRow: View {
    let collection: SavedCollection
    let selected: Bool
    var showsPrivacy = true
    var identifierPrefix = "favorite.folder"
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                FloatingPageIcon(symbol: "folder")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name).font(.subheadline).foregroundStyle(.primary)
                        .lineLimit(showsPrivacy ? nil : 1)
                    if showsPrivacy { Text(collection.privacyTitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: FloatingPageChrome.groupInset)
                FavoriteSelectionMark(selected: selected)
            }
            .padding(.vertical, FloatingPageChrome.groupInset)
            .frame(minHeight: FloatingPageChrome.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collection.name)
        .accessibilityValue(selected ? "已选" : "未选")
        .accessibilityHint(showsPrivacy ? collection.privacyTitle : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix).\(collection.id)")
    }
}

private extension View {
    func favoriteFolderCard() -> some View { PageContentCard { self } }
}

struct FavoriteSelectionMark: View {
    let selected: Bool
    var onMedia = false

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(selected ? Color.accentColor : onMedia ? .white : .secondary)
            .background {
                if onMedia { Circle().fill(selected ? .white : .black.opacity(0.45)) }
            }
            .accessibilityHidden(true)
    }
}

struct FavoriteBatchSelection {
    enum Operation {
        case add
        case remove(from: Set<Int>)

        var isRemoval: Bool { if case .remove = self { true } else { false } }
        var verb: String { isRemoval ? "移除" : "收藏" }
    }
    @Observable @MainActor
    final class EditorState {
        var remaining: Set<Int>
        var selected = Set<Int>()
        var loadedSession: SiteSession.AccountSessionID?
        var loading = false
        var saving = false
        var attempted = false
        var error: String?
        let operationID = UUID()
        @ObservationIgnored var loadTask: Task<Void, Never>?
        @ObservationIgnored var loadToken: UUID?
        @ObservationIgnored var loadSession: SiteSession.AccountSessionID?

        init(works: Set<Int>) { remaining = works }
    }
    struct Request: Identifiable {
        let id: UUID
        let works: Set<Int>
        let operation: Operation
        let accountSession: SiteSession.AccountSessionID?
        let editorState: EditorState

        @MainActor init(works: Set<Int>, operation: Operation, accountSession: SiteSession.AccountSessionID?) {
            id = UUID()
            self.works = works
            self.operation = operation
            self.accountSession = accountSession
            editorState = EditorState(works: works)
        }
    }

    private(set) var works: Set<Int>?
    var request: Request?

    mutating func begin(selecting id: Int? = nil) {
        guard works == nil else { return }
        works = id.map { [$0] } ?? []
    }
    mutating func toggle(_ id: Int) {
        guard var selected = works else { return }
        if selected.remove(id) == nil { selected.insert(id) }
        works = selected
    }
    @MainActor mutating func openEditor(_ operation: Operation = .add, for accountSession: SiteSession.AccountSessionID?) {
        if let works, !works.isEmpty {
            request = Request(works: works, operation: operation, accountSession: accountSession)
        }
    }
    mutating func confirm(_ saved: Set<Int>) {
        guard let works else { return }
        let remaining = works.subtracting(saved)
        self.works = remaining.isEmpty ? nil : remaining
    }
    mutating func reset() { works = nil; request = nil }
}

@MainActor
final class FavoriteSelectionBar: ObservableObject {
    struct Entry {
        let owner: UUID
        let count: Int
        let canManage: Bool
        let folders: Set<Int>?
        let selection: Binding<FavoriteBatchSelection>
        let onDelete: (() -> Void)?
        init(owner: UUID, count: Int, canManage: Bool, folders: Set<Int>?, selection: Binding<FavoriteBatchSelection>, onDelete: (() -> Void)? = nil) {
            self.owner = owner; self.count = count; self.canManage = canManage
            self.folders = folders; self.selection = selection; self.onDelete = onDelete
        }
    }

    @Published private(set) var entry: Entry?

    func show(_ entry: Entry) { self.entry = entry }
    func clear(owner: UUID? = nil) {
        if let entry, owner == nil || entry.owner == owner { self.entry = nil }
    }
}

extension EnvironmentValues {
    @Entry var favoriteSelectionBar: FavoriteSelectionBar? = nil
}

struct FavoriteBatchBarButtons: View {
    let entry: FavoriteSelectionBar.Entry
    @EnvironmentObject private var session: SiteSession

    var body: some View {
        HStack(spacing: 8) {
            if let folders = entry.folders {
                Button("返回") { entry.selection.wrappedValue.reset() }
                    .buttonStyle(AppActionButtonStyle())
                    .accessibilityIdentifier("collection-batch.back")
                Spacer(minLength: 0)
                Button("添加") { entry.selection.wrappedValue.openEditor(for: session.accountSessionID) }
                    .buttonStyle(AppActionButtonStyle(tone: .accent))
                    .disabled(entry.count == 0 || !entry.canManage)
                    .accessibilityLabel("添加到收藏夹")
                Button("移除") { entry.selection.wrappedValue.openEditor(.remove(from: folders), for: session.accountSessionID) }
                    .buttonStyle(AppActionButtonStyle(tone: .destructive))
                    .disabled(entry.count == 0 || !entry.canManage)
                    .accessibilityLabel("从当前收藏夹移除")
                    .accessibilityIdentifier("collection-batch.remove")
            } else {
                Button("取消") { entry.selection.wrappedValue.reset() }
                    .buttonStyle(AppActionButtonStyle()).accessibilityIdentifier("favorite-batch.cancel")
                Spacer(minLength: 0)
                Text("已选 \(entry.count)").font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                    if let onDelete = entry.onDelete {
                        Button("删除", role: .destructive) { onDelete() }
                            .buttonStyle(AppActionButtonStyle(tone: .destructive))
                            .disabled(entry.count == 0)
                            .accessibilityLabel("删除 \(entry.count) 条记录")
                            .accessibilityIdentifier("history-batch.delete")
                    }
                    Button("收藏") { entry.selection.wrappedValue.openEditor(for: session.accountSessionID) }
                        .buttonStyle(AppActionButtonStyle(tone: .accent))
                        .disabled(entry.count == 0 || !entry.canManage)
                        .accessibilityLabel("收藏 \(entry.count)")
                        .accessibilityIdentifier("favorite-batch.open")
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct FavoriteBatchBottomBar: ViewModifier {
    @Binding var selection: FavoriteBatchSelection
    let canManage: Bool
    let folders: Set<Int>?
    let onDelete: (() -> Void)?
    @Environment(\.favoriteSelectionBar) private var bar
    @State private var owner = UUID()
    @State private var visible = false

    private struct StateKey: Equatable {
        let count: Int?
        let canManage: Bool
        let folders: Set<Int>?
        let hasDelete: Bool
    }
    private var state: StateKey { .init(count: selection.works?.count, canManage: canManage, folders: folders, hasDelete: onDelete != nil) }
    private var entry: FavoriteSelectionBar.Entry? {
        selection.works.map { .init(owner: owner, count: $0.count, canManage: canManage, folders: folders, selection: $selection, onDelete: onDelete) }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onChange(of: state) { _, _ in if visible { update() } }
            .onDisappear { visible = false; bar?.clear(owner: owner) }
            .overlay(alignment: .bottom) {
                if bar == nil, let entry {
                    FavoriteBatchBarButtons(entry: entry)
                        .frame(minHeight: FloatingPageChrome.controlHeight)
                        .padding(.horizontal, FloatingPageChrome.groupInset)
                        .padding(.vertical, ContentMetrics.Optical.iconTextGap)
                        .background { FloatingBottomBarSurface() }
                        .padding(.horizontal, FloatingPageChrome.pageInset)
                }
            }
    }

    private func update() {
        if let entry { bar?.show(entry) }
        else { bar?.clear(owner: owner) }
    }
}

struct FavoriteBatchToolbar: View {
    @Binding var selection: FavoriteBatchSelection
    let canSelect: Bool
    @EnvironmentObject private var session: SiteSession

    var body: some View {
        if let works = selection.works {
            Button("取消") { selection.reset() }.accessibilityIdentifier("favorite-batch.cancel")
            Button("收藏 \(works.count)") { selection.openEditor(for: session.accountSessionID) }
                .disabled(works.isEmpty)
                .accessibilityIdentifier("favorite-batch.open")
        } else if canSelect {
            Button { selection.begin() } label: { FloatingPageIcon(symbol: "checklist") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("多选收藏").accessibilityIdentifier("favorite-batch.select")
        }
    }
}

extension View {
    func favoriteBatchBottomBar(_ selection: Binding<FavoriteBatchSelection>, canManage: Bool, folders: Set<Int>? = nil,
                                onDelete: (() -> Void)? = nil) -> some View {
        modifier(FavoriteBatchBottomBar(selection: selection, canManage: canManage, folders: folders, onDelete: onDelete))
    }

    func favoriteBatchEditor(_ selection: Binding<FavoriteBatchSelection>) -> some View {
        businessPage(item: selection.request) { request, close in
            BatchFavoriteEditor(request: request, onClose: close) { confirmed in
                guard selection.wrappedValue.request?.id == request.id else { return }
                selection.wrappedValue.confirm(confirmed)
            }
        }
    }
}

private struct BatchFavoriteEditor: View {
    let editorState: FavoriteBatchSelection.EditorState
    let works: Set<Int>
    let operation: FavoriteBatchSelection.Operation
    let onConfirmed: (Set<Int>) -> Void
    let onClose: () -> Void
    @EnvironmentObject private var session: SiteSession
    private var remaining: Set<Int> {
        get { editorState.remaining }
        nonmutating set { editorState.remaining = newValue }
    }
    private var selected: Set<Int> {
        get { editorState.selected }
        nonmutating set { editorState.selected = newValue }
    }
    private let openedSession: SiteSession.AccountSessionID?
    private var loadedSession: SiteSession.AccountSessionID? {
        get { editorState.loadedSession }
        nonmutating set { editorState.loadedSession = newValue }
    }
    private var loaded: Bool { loadedSession.map { $0 == session.collectionSessionID } ?? false }
    private var saving: Bool {
        get { editorState.saving }
        nonmutating set { editorState.saving = newValue }
    }
    private var attempted: Bool {
        get { editorState.attempted }
        nonmutating set { editorState.attempted = newValue }
    }
    private var error: String? {
        get { editorState.error }
        nonmutating set { editorState.error = newValue }
    }
    #if DEBUG && targetEnvironment(simulator)
    @State private var traceIdentity = UUID()
    private func traceEditor(_ event: String, saveInputCount: Int = -1) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") else { return }
        NSLog("BATCH169 event=%@ instance=%@ operation=%@ request=%@ verb=%@ total=%d remaining=%d saveInputCount=%d attempted=%d saving=%d error=%d",
              event, traceIdentity.uuidString, editorState.operationID.uuidString, requestID.uuidString,
              operation.verb, works.count, remaining.count, saveInputCount,
              attempted ? 1 : 0, saving ? 1 : 0, error == nil ? 0 : 1)
    }
    #endif

    init(request: FavoriteBatchSelection.Request, onClose: @escaping () -> Void, onConfirmed: @escaping (Set<Int>) -> Void) {
        works = request.works
        operation = request.operation
        openedSession = request.accountSession
        editorState = request.editorState
        requestID = request.id
        self.onConfirmed = onConfirmed
        self.onClose = onClose
    }

    private let requestID: UUID

    private var confirmedCount: Int { works.count - remaining.count }
    private var canSave: Bool {
        loaded && !saving && session.savingFavoriteID == nil && !selected.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if !session.hasCollectionAccess {
                    CollectionAccessView()
                } else if remaining.isEmpty {
                    ScrollView {
                        PageStatusCard(title: "已\(operation.verb) \(confirmedCount) 项作品", symbol: "checkmark.circle")
                            .padding(.horizontal, FloatingPageChrome.pageInset)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                            Text("待\(operation.verb) \(remaining.count) 项作品")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, FloatingPageChrome.cardInset)
                            if case let .remove(folders) = operation {
                                ForEach(session.collections.filter { folders.contains($0.id) }) { collection in
                                    Label(collection.name, systemImage: "folder")
                                        .font(.subheadline)
                                        .frame(minHeight: FloatingPageChrome.controlHeight)
                                        .favoriteFolderCard()
                                }
                            } else {
                                ForEach(session.collections) { collection in
                                    FavoriteFolderRow(collection: collection, selected: selected.contains(collection.id)) {
                                        if selected.remove(collection.id) == nil { selected.insert(collection.id) }
                                    }
                                    .favoriteFolderCard()
                                    .disabled(!loaded || attempted)
                                }
                            }
                            if loaded && session.collections.isEmpty {
                                PageStatusCard(title: "暂无可用收藏夹", symbol: "folder")
                            }
                            if operation.isRemoval || session.collections.contains(where: { $0.read == "Public" }) {
                                Text(operation.isRemoval ? "仅从上面列出的收藏夹移除。" : "公开收藏夹中的作品可被他人看到。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, FloatingPageChrome.cardInset)
                            }
                            if saving || editorState.loading || (!loaded && error == nil) {
                                ProgressView(saving ? "正在\(operation.verb)…" : "正在读取收藏夹…")
                                    .font(.footnote)
                                    .frame(maxWidth: .infinity)
                            }
                            if confirmedCount > 0 {
                                PageStatusCard(title: "已\(operation.verb) \(confirmedCount) 项，\(remaining.count) 项待确认。", symbol: "checkmark.circle")
                            }
                            if error != nil {
                                PageStatusCard(title: "", symbol: "exclamationmark.circle", retryTitle: "重新读取收藏夹",
                                               retry: loaded ? nil : { Task { await load() } })
                            }
                        }
                        .padding(.horizontal, FloatingPageChrome.pageInset)
                        .padding(.bottom, FloatingPageChrome.pageInset)
                    }
                }
            }
            .floatingTitleBar("批量\(operation.verb)", layoutIdentity: remaining.isEmpty, leading: {
                if !remaining.isEmpty { Button("关闭") { close() }.disabled(saving) }
            }) {
                if remaining.isEmpty {
                    Button("完成") { onClose() }
                } else {
                    Button(attempted ? "重试" : operation.verb, role: operation.isRemoval ? .destructive : nil) {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("favorite-batch.save")
                }
            }
            .pageReturnAction(enabled: !saving) {
                guard !saving else { return false }
                close()
                return true
            }
            .task(id: session.collectionSessionID) { await load() }
            .onChange(of: session.accountSessionID) { _, _ in close() }
        }
        .interactiveDismissDisabled(saving)
        .collectionAuthorization()
        .ordinaryPresentationAppearance()
        .existingFeedbackToast(error, id: error, active: error != nil, scope: session.feedIdentity)
        #if DEBUG && targetEnvironment(simulator)
        .onAppear { traceEditor("appear") }
        .onDisappear { traceEditor("disappear") }
        .onChange(of: remaining) { _, _ in traceEditor("remaining") }
        #endif
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        guard session.accountSessionID == openedSession else { close(); return }
        guard let identity = session.collectionSessionID, !saving else { return }
        if loadedSession == identity { return }
        if editorState.loadSession == identity, let task = editorState.loadTask {
            await task.value
            return
        }
        editorState.loadTask?.cancel()
        let token = UUID()
        let state = editorState
        let session = session
        let openedSession = openedSession
        let operation = operation
        #if DEBUG && targetEnvironment(simulator)
        let traceInstance = traceIdentity
        let traceOperation = state.operationID
        let traceRequest = requestID
        let traceVerb = operation.verb
        let traceTotalCount = works.count
        #endif
        state.loadToken = token
        state.loadSession = identity
        state.loading = true
        #if DEBUG && targetEnvironment(simulator)
        traceEditor("load-begin")
        #endif
        let task = Task { @MainActor in
            defer {
                if state.loadToken == token {
                    state.loadTask = nil
                    state.loadToken = nil
                    state.loadSession = nil
                    state.loading = false
                    #if DEBUG && targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("--qa-collection-batch-manage") {
                        NSLog("BATCH169 event=load-end instance=%@ operation=%@ request=%@ verb=%@ total=%d remaining=%d saveInputCount=-1 attempted=%d saving=%d error=%d",
                              traceInstance.uuidString, traceOperation.uuidString, traceRequest.uuidString,
                              traceVerb, traceTotalCount, state.remaining.count,
                              state.attempted ? 1 : 0, state.saving ? 1 : 0, state.error == nil ? 0 : 1)
                    }
                    #endif
                }
            }
            guard state.loadToken == token,
                  session.accountSessionID == openedSession,
                  session.collectionSessionID == identity,
                  !state.saving else { return }
            state.error = nil
            do {
                try await session.refreshCollections()
                try Task.checkCancellation()
                guard state.loadToken == token,
                      session.accountSessionID == openedSession,
                      identity == session.collectionSessionID,
                      !state.saving else { return }
                if case let .remove(folders) = operation {
                    guard folders.isSubset(of: Set(session.collections.map(\.id))) else { throw ClientError.invalidResponse }
                    state.selected = folders
                } else {
                    state.selected = session.defaultCollectionIDs
                }
                state.loadedSession = identity
            } catch {
                if !Task.isCancelled,
                   state.loadToken == token,
                   session.accountSessionID == openedSession,
                   identity == session.collectionSessionID,
                   !state.saving {
                    state.error = error.localizedDescription
                }
            }
        }
        editorState.loadTask = task
        await task.value
    }

    private func close() {
        let task = editorState.loadTask
        editorState.loadToken = nil
        editorState.loadSession = nil
        editorState.loadTask = nil
        editorState.loading = false
        task?.cancel()
        onClose()
    }

    private func save() async {
        guard canSave, let identity = loadedSession else { return }
        #if DEBUG && targetEnvironment(simulator)
        traceEditor("save-begin", saveInputCount: remaining.count)
        #endif
        saving = true; attempted = true; error = nil
        editorState.loadToken = nil
        editorState.loadSession = nil
        editorState.loadTask?.cancel()
        editorState.loadTask = nil
        editorState.loading = false
        defer {
            saving = false
            #if DEBUG && targetEnvironment(simulator)
            traceEditor("save-end")
            #endif
        }
        do {
            let result = try await session.updateFavorites(remaining, folders: selected,
                                                           removing: operation.isRemoval, for: identity)
            guard identity == session.collectionSessionID else { return }
            remaining.subtract(result.confirmed)
            onConfirmed(result.confirmed)
            if !remaining.isEmpty {
                error = result.error ?? "请稍后重试。"
            }
        } catch {
            if identity == session.collectionSessionID { self.error = error.localizedDescription }
        }
    }
}

struct CollectionDownloadsLink: View {
    var body: some View {
        NavigationLink { OfflineDownloadTasksView() } label: {
            FloatingPageIcon(symbol: "arrow.down.to.line").accessibilityHidden(true)
        }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .frame(width: FloatingPageChrome.controlHeight)
        .accessibilityLabel("下载管理")
        .accessibilityIdentifier("collections.downloads")
    }
}

private struct CollectionWorksView<FolderControl: View>: View {
    let source: FeedSource
    @Binding var filter: FeedFilter
    let showsBack: Bool
    let onRefreshCollections: () async -> Void
    var showsFolders = false
    @ViewBuilder let folderControl: () -> FolderControl
    @EnvironmentObject private var session: SiteSession
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocks = AuthorBlocklist.shared
    @StateObject private var imageFeed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: .shared)
    @StateObject private var videoFeed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: .shared)
    @State private var showFilter = false
    @State private var viewerItem: MediaItem?
    @State private var focusedByKind: [MediaKind: Int] = [:]
    @State private var gridAnchors: [MediaKind: Int] = [:]
    private struct PreviewCache { let key: FeedStoreRequestKey; let items: [MediaItem] }
    private struct PaneTaskKey: Equatable {
        let key: FeedStoreRequestKey
        let active: Bool
        let revision: Int
        let viewerVisible: Bool
        let access: Bool
    }
    @State private var cachedPreviews: [MediaKind: PreviewCache] = [:]
    @State private var preparedByKind: [MediaKind: (key: FeedStoreRequestKey, revision: Int, at: Date)] = [:]
    @State private var pendingPreviewOpens: [MediaKind: Int] = [:]
    @State private var favoriteBatch = FavoriteBatchSelection()
    @ObservedObject private var offline = OfflineLibrary.shared
    private struct LocalOpen {
        let item: MediaItem
        let kind: MediaKind
        let key: FeedStoreRequestKey
        let binding: UUID
        let collectionRevision: Int
    }
    @State private var sourceVisible = false
    @State private var localPlaybackItems: [MediaItem] = []
    @State private var pendingLocalOpen: LocalOpen?
    #if DEBUG && targetEnvironment(simulator)
    @State private var cacheWriteVerified = false
    #endif
    private var requestKey: FeedStoreRequestKey { requestKey(for: filter.effectiveKind) }
    private var activeKind: MediaKind { filter.effectiveKind }
    private func requestKey(for kind: MediaKind) -> FeedStoreRequestKey {
        .init(identity: session.feedIdentity, filter: filter.selecting(kind: kind), source: source)
    }
    private func feed(for kind: MediaKind) -> FeedStore { kind == .video ? videoFeed : imageFeed }
    private var feed: FeedStore { feed(for: activeKind) }
    private func anchorBinding(for kind: MediaKind) -> Binding<Int?> {
        Binding(get: { gridAnchors[kind] }, set: { gridAnchors[kind] = $0 })
    }
    private func focusBinding(for kind: MediaKind) -> Binding<Int?> {
        Binding(get: { focusedByKind[kind] }, set: { focusedByKind[kind] = $0 })
    }
    private struct CacheContext: Equatable {
        let key: FeedStoreRequestKey
        let owner: Int
        let scope: CollectionListCache.Scope
        let revision: Int
    }
    private func cacheContext(for kind: MediaKind) -> CacheContext? {
        let paneFilter = filter.selecting(kind: kind)
        guard collectionListCachingEnabled, session.hasCollectionAccess, let account = session.account,
              let scope = CollectionListCache.Scope(source: source, filter: paneFilter, browsingLevel: account.browsingLevel ?? 1) else { return nil }
        return .init(key: requestKey(for: kind), owner: account.id, scope: scope, revision: session.collectionRevision)
    }
    private func previewItems(for kind: MediaKind) -> [MediaItem]? {
        let paneFeed = feed(for: kind)
        let paneKey = requestKey(for: kind)
        guard cachedPreviews[kind]?.key == paneKey, let context = cacheContext(for: kind),
              let cached = cachedPreviews[kind]?.items,
              paneFeed.requestKey != paneKey || (paneFeed.items.isEmpty && !paneFeed.reachedEnd) else { return nil }
        var visible = FeedAccumulator(keeping: cached.filter { item in
            guard let level = item.browsingLevel, level > 0 else { return false }
            return level & ~context.scope.browsingLevel == 0
        }, blockedTags: blocklist.names, videoDurationRange: filter.selecting(kind: kind).videoDurationRange)
        visible.applyBlockedAuthors(ids: authorBlocks.blockedIDs, handles: authorBlocks.blockedHandles)
        return visible.items.isEmpty ? nil : visible.items
    }
    private func gridPreview(for kind: MediaKind) -> [MediaItem]? {
        previewItems(for: kind) ?? (feed(for: kind).requestKey == requestKey(for: kind) ? nil : [])
    }
    private var mediaKindSelection: Binding<MediaKind> {
        Binding(get: { filter.effectiveKind }, set: { filter = filter.selecting(kind: $0) })
    }
    private var currentFolders: Set<Int> {
        switch source {
        case .collection(let id): [id]
        case .collections(let ids): ids
        default: []
        }
    }
    private var canSelectWorks: Bool {
        session.hasCollectionAccess && feed.requestKey == requestKey && previewItems(for: activeKind) == nil && !feed.items.isEmpty
    }
    var body: some View {
        SegmentedContentPager(selection: activeKind, options: MediaKind.browsingCases,
                              identifier: "collection.media-kind", onInteractionBegan: { pendingPreviewOpens = [:] }) { kind, active in
            mediaPane(kind: kind, active: active)
        }
        .avoidOverlaidTabBar()
        .floatingPageBar("collections.top-bar", layoutIdentity: showsFolders) {
            HStack(spacing: FloatingPageChrome.groupInset) {
                if showsBack { FloatingPageBackButton() }
                CollectionDownloadsLink()
                folderControl()
                FloatingMediaPicker(title: "收藏作品类型", selection: mediaKindSelection, identifier: "collection.media-kind")
                AppMenu {
                    Button("筛选条件", systemImage: "slider.horizontal.3") { showFilter = true }
                        .accessibilityIdentifier("collection-show-filter")
                    Button {
                        filter.onlyPG.toggle()
                    } label: {
                        Label("仅看 PG", systemImage: filter.onlyPG ? "checkmark.shield" : "shield")
                    }
                    .accessibilityAddTraits(filter.onlyPG ? .isSelected : [])
                    .accessibilityValue(filter.onlyPG ? "开" : "关")
                    .accessibilityIdentifier("collection-only-pg")
                    Button("刷新作品", systemImage: "arrow.clockwise") { Task { await refreshWorks(kind: activeKind) } }
                    if favoriteBatch.works == nil && canSelectWorks {
                        Button("多选作品", systemImage: "checklist") { favoriteBatch.begin() }
                            .accessibilityIdentifier("collection-batch.select")
                    }
                } label: { FloatingPageIcon(symbol: FloatingPageChrome.filterSymbol) }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("收藏筛选与刷新").accessibilityIdentifier("collection-filter-menu")
            }
            .disabled(favoriteBatch.works != nil)
        }
        .edgeSwitchingSegments(selection: mediaKindSelection, options: MediaKind.browsingCases,
                               identifier: "collection.media-kind", enabled: viewerItem == nil && !showFilter && favoriteBatch.works == nil,
                               reservesPageEdges: false, leftEdge: false, rightEdge: false, centerSwipe: true)
        .favoriteBatchBottomBar($favoriteBatch, canManage: canSelectWorks, folders: currentFolders)
        .favoriteBatchEditor($favoriteBatch)
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if CollectionListCacheQA.fixture != nil {
                Text(cacheWriteVerified ? "stored" : "pending").font(.system(size: 1))
                    .frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("collection-cache.qa")
            }
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--qa-segment-edge") {
                Text("collection preparation").font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01)
                    .allowsHitTesting(false).accessibilityIdentifier("collection.preparation.qa")
                    .accessibilityValue("revision=\(session.collectionRevision);imageRevision=\(preparedByKind[.image]?.revision ?? -1);videoRevision=\(preparedByKind[.video]?.revision ?? -1);imageCount=\(imageFeed.items.count);videoCount=\(videoFeed.items.count)")
            }
        }
        #endif
        .onChange(of: requestKey) { _, _ in favoriteBatch.reset() }
        .onChange(of: activeKind) { _, kind in
            pendingPreviewOpens = [:]
            let key = requestKey(for: kind)
            if preparedByKind[kind]?.key == key, preparedByKind[kind]?.revision == session.collectionRevision {
                Task { await finishAlignment(kind: kind, key: key, context: cacheContext(for: kind)) }
            }
        }
        .onChange(of: blocklist.names) { _, tags in
            imageFeed.applyBlockedTags(tags); videoFeed.applyBlockedTags(tags); favoriteBatch.reset()
        }
        .onChange(of: authorBlocks.entries) { _, _ in favoriteBatch.reset() }
        .onChange(of: session.feedIdentity) { _, _ in
            cachedPreviews = [:]
            pendingPreviewOpens = [:]
            viewerItem = nil
            focusedByKind = [:]
            gridAnchors = [:]
            preparedByKind = [:]
        }
        .onChange(of: session.collectionRevision) { _, _ in
            cachedPreviews = [:]
            pendingPreviewOpens = [:]
        }
        .navigationDestination(isPresented: $showFilter) {
            FilterView(filter: $filter, isCollection: true)
        }
        .onAppear { sourceVisible = true }
        .onDisappear { sourceVisible = false; pendingLocalOpen = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pendingLocalOpen = nil } }
        .onChange(of: showFilter) { _, showing in if showing { pendingLocalOpen = nil } }
        .onChange(of: favoriteBatch.works != nil) { _, selecting in if selecting { pendingLocalOpen = nil } }
        .onChange(of: session.collectionRevision) { _, _ in pendingLocalOpen = nil }
        .mediaCover(item: $viewerItem, onDismiss: { localPlaybackItems = [] }) { opening in
            FeedMediaViewer(items: localPlaybackItems, focused: focusBinding(for: activeKind), initialID: opening.id,
                            continuationState: .ended,
                            onDetailsVisibility: { feed.setTagPolicyDeferred($0) },
                            onClose: { viewerItem = nil }) {}
        }
    }

    private func mediaPane(kind: MediaKind, active: Bool) -> some View {
        let paneFeed = feed(for: kind)
        let paneKey = requestKey(for: kind)
        let current = activeKind == kind
        return MediaGrid(feed: paneFeed, previewItems: gridPreview(for: kind),
                         waitingForPreviewOpen: nil, anchor: anchorBinding(for: kind),
                         isVisible: active && current && viewerItem == nil,
                         automaticLoadingAllowed: active && current && preparedByKind[kind]?.key == paneKey
                             && preparedByKind[kind]?.revision == session.collectionRevision,
                         loadMoreAutomatically: { await next(kind: kind, automatically: true) },
                         refreshFromStart: { await refreshFeed(kind: kind) }, horizontalInset: AppTheme.spacing,
                         favoriteSelection: favoriteBatch.works,
                         beginSelection: canSelectWorks && current ? { favoriteBatch.begin(selecting: $0.id) } : nil,
                         open: { item in
            if favoriteBatch.works != nil { favoriteBatch.toggle(item.id) }
            else { openWork(item, kind: kind) }
        }, loadMore: { await next(kind: kind) })
            .environment(\.showsCollectionDownloads, true)
            .onChange(of: pendingLocalOpen.flatMap { offline.localCollectionItem($0.item, owner: session.account?.id) }?.id) { _, _ in finishLocalOpen() }
            .onChange(of: offline.bindingID) { _, _ in pendingLocalOpen = nil; viewerItem = nil }
            .onChange(of: activeKind) { _, _ in pendingLocalOpen = nil }
            .onChange(of: requestKey) { _, _ in pendingLocalOpen = nil }
            .refreshable { await refreshWorks(kind: kind) }
            .task(id: PaneTaskKey(key: paneKey, active: active, revision: session.collectionRevision,
                                  viewerVisible: viewerItem == nil, access: session.hasCollectionAccess)) {
                guard active, viewerItem == nil else { return }
                await load(kind: kind, active: true)
            }
    }

    private func load(kind: MediaKind, active: Bool) async {
        guard active, !Task.isCancelled else { return }
        let paneFeed = feed(for: kind)
        guard session.hasCollectionAccess else { paneFeed.clear(); return }
        let key = requestKey(for: kind), context = cacheContext(for: kind)
        let revision = session.collectionRevision
        if let prepared = preparedByKind[kind], prepared.key == key, prepared.revision == revision, paneFeed.requestKey == key {
            if Date.now.timeIntervalSince(prepared.at) > 30 { await refreshFeed(kind: kind) }
            else { await finishAlignment(kind: kind, key: key, context: context) }
            return
        }
        if paneFeed.requestKey == key, !paneFeed.items.isEmpty || paneFeed.reachedEnd {
            // A newer collection revision refreshes this pane without discarding
            // its last confirmed list on a transient network failure.
            await refreshFeed(kind: kind)
            return
        }
        cachedPreviews[kind] = nil
        pendingPreviewOpens[kind] = nil
        if paneFeed.requestKey != key {
            gridAnchors[kind] = nil
            focusedByKind[kind] = nil
        }
        if let context, session.savingFavoriteID == nil,
           let rows = await CollectionListCache.shared.rows(owner: context.owner, scope: context.scope),
           !Task.isCancelled, cacheContext(for: kind) == context, session.savingFavoriteID == nil {
            cachedPreviews[kind] = PreviewCache(key: key, items: rows.map { row in
                row.preview(with: MediaCache.shared.cachedCollectionPreview(keys: row.previewKeys))
            })
        }
        guard !Task.isCancelled, key == requestKey(for: kind) else { return }
        let commit = await paneFeed.activate(session: session, filter: key.filter, source: key.source, blockedTags: blocklist.names)
        if revision == session.collectionRevision, paneFeed.accepts(commit, identity: session.feedIdentity), commit.state == .loaded || commit.state == .ended {
            preparedByKind[kind] = (key, revision, .now)
            await finishAlignment(kind: kind, key: key, context: context)
        } else if key == requestKey(for: kind), paneFeed.continuationState.failure != nil {
            pendingPreviewOpens[kind] = nil
        }
    }

    private func openWork(_ item: MediaItem, kind: MediaKind) {
        guard sourceVisible, scenePhase == .active, viewerItem == nil, !showFilter, favoriteBatch.works == nil,
              activeKind == kind,
              let current = (gridPreview(for: kind) ?? feed(for: kind).items).first(where: { $0.id == item.id }) else { return }
        if let local = offline.localCollectionItem(current, owner: session.account?.id, verifyFile: true) {
            openLocal(local, kind: kind)
        } else {
            pendingLocalOpen = LocalOpen(item: current, kind: kind, key: requestKey,
                                        binding: offline.bindingID, collectionRevision: session.collectionRevision)
            offline.requestCollectionItem(current.id, session: session)
        }
    }

    private func openLocal(_ local: MediaItem, kind: MediaKind) {
        let displayed = gridPreview(for: kind) ?? feed(for: kind).items
        localPlaybackItems = displayed.compactMap { offline.localCollectionItem($0, owner: session.account?.id) }
        guard localPlaybackItems.contains(where: { $0.id == local.id }) else { return }
        pendingLocalOpen = nil
        focusedByKind[kind] = local.id
        viewerItem = local
    }

    private func finishLocalOpen() {
        guard sourceVisible, scenePhase == .active, viewerItem == nil, !showFilter, favoriteBatch.works == nil,
              let pending = pendingLocalOpen, pending.kind == activeKind,
              pending.key == requestKey, pending.binding == offline.bindingID,
              pending.collectionRevision == session.collectionRevision,
              let current = (gridPreview(for: pending.kind) ?? feed.items).first(where: { $0.id == pending.item.id }),
              let local = offline.localCollectionItem(current, owner: session.account?.id, verifyFile: true) else { return }
        openLocal(local, kind: pending.kind)
    }

    private func next(kind: MediaKind, automatically: Bool = false) async {
        let paneFeed = feed(for: kind)
        let key = requestKey(for: kind), context = cacheContext(for: kind)
        let revision = session.collectionRevision
        guard activeKind == kind, paneFeed.requestKey == key else { return }
        let commit = if automatically { await paneFeed.nextAutomatically(session: session) } else { await paneFeed.next(session: session) }
        if revision == session.collectionRevision, commit.didCommit, paneFeed.accepts(commit, identity: session.feedIdentity), commit.state == .loaded || commit.state == .ended {
            await finishAlignment(kind: kind, key: key, context: context)
        } else if key == requestKey(for: kind), paneFeed.continuationState.failure != nil {
            pendingPreviewOpens[kind] = nil
        }
    }

    private func finishAlignment(kind: MediaKind, key: FeedStoreRequestKey, context: CacheContext?) async {
        let paneFeed = feed(for: kind)
        guard !Task.isCancelled, activeKind == kind, requestKey(for: kind) == key,
              paneFeed.requestKey == key, session.hasCollectionAccess,
              preparedByKind[kind]?.key == key, preparedByKind[kind]?.revision == session.collectionRevision else { return }
        cachedPreviews[kind] = nil
        if let pending = pendingPreviewOpens[kind] {
            pendingPreviewOpens[kind] = nil
            if let item = paneFeed.items.first(where: { $0.id == pending }) { openWork(item, kind: kind) }
        }
        guard let context, cacheContext(for: kind) == context, session.collectionsKnown, session.savingFavoriteID == nil else { return }
        let rows = paneFeed.items.prefix(CollectionListCache.previewLimit).map {
            CollectionListCache.Row($0, previewKeys: MediaCache.shared.collectionPreviewKeys(for: $0))
        }
        let written = await CollectionListCache.shared.storeRows(rows, owner: context.owner, scope: context.scope,
                                                               verifiedFolders: session.collections)
        #if DEBUG && targetEnvironment(simulator)
        if CollectionListCacheQA.fixture != nil, !Task.isCancelled, activeKind == kind, cacheContext(for: kind) == context { cacheWriteVerified = written }
        #endif
    }

    private func refreshFeed(kind: MediaKind) async {
        let paneFeed = feed(for: kind)
        let key = requestKey(for: kind), context = cacheContext(for: kind)
        let revision = session.collectionRevision
        let result = await paneFeed.restartFromStart(session: session, filter: key.filter, source: key.source, blockedTags: blocklist.names)
        if result.status == .committed, revision == session.collectionRevision, key == requestKey(for: kind) {
            preparedByKind[kind] = (key, revision, .now)
            await finishAlignment(kind: kind, key: key, context: context)
        }
        else if result.status == .failedRetainingPrevious, key == requestKey(for: kind) { pendingPreviewOpens[kind] = nil }
    }
    private func refreshWorks(kind: MediaKind) async {
        await refreshFeed(kind: kind)
        if !Task.isCancelled { await onRefreshCollections() }
    }
}


extension EnvironmentValues {
    @Entry var showsCollectionDownloads = false
}

/// A status-only corner badge. Completed copies intentionally have no label.
struct CollectionDownloadBadge: View {
    let workID: Int
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var offline = OfflineLibrary.shared
    var body: some View {
        if let state = offline.collectionDownloadState(workID, owner: session.account?.id) {
            HStack(spacing: FloatingPageChrome.groupInset) {
                switch state {
                case .waiting: Image(systemName: "clock")
                case .paused: Image(systemName: "pause.fill")
                case .failed: Image(systemName: "exclamationmark")
                case .downloading(let progress):
                    Image(systemName: "arrow.down")
                    if let progress { Text(min(1, max(0, progress)), format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                }
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
            .background(.black.opacity(0.72), in: FloatingPageChrome.surfaceShape(nested: true))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle(state))
            .accessibilityIdentifier("collection.download.\(workID)")
        }
    }
    private func accessibilityTitle(_ state: OfflineLibrary.CollectionDownloadState) -> String {
        switch state {
        case .waiting: "等待下载"
        case .paused: "下载已暂停"
        case .failed: "下载失败，轻点作品重试"
        case .downloading(let progress): progress.map { "下载中，\(Int(min(1, max(0, $0)) * 100))%" } ?? "下载中"
        }
    }
}
