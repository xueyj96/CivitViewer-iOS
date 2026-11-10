import SwiftUI

// A tap toggles the bookmark. Folder management is a separate long-press action.
struct FavoriteButton: View {
    let item: MediaItem
    let active: Bool
    @EnvironmentObject private var session: SiteSession
    @State private var showPicker = false
    @State private var chromeOverlay = UUID()
    @ObservedObject private var chrome = ViewingChromeController.shared
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
        Button { toggleFavorite() } label: {
            MediaIconActionLabel(title: saved ? "已收藏" : "收藏", symbol: saved ? "bookmark.fill" : "bookmark", qaKey: "control.\(item.id).favorite")
        }
        .buttonStyle(.plain).disabled(saving)
        .contextMenu {
            Button("选择收藏夹", systemImage: "folder") { showPicker = true }
                .accessibilityIdentifier("favorite.manage")
        }
        .accessibilityAction(named: Text("选择收藏夹")) { showPicker = true }
        .accessibilityLabel(saved ? "已收藏" : "收藏")
        .accessibilityIdentifier("favorite-\(item.id)")
        .sheet(isPresented: $showPicker, onDismiss: { chrome.resume(after: chromeOverlay) }) {
            FavoriteEditor(item: item)
                .id(item.id)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: showPicker) { _, shown in
            if shown { chrome.suspend(for: chromeOverlay) }
            else { chrome.resume(after: chromeOverlay) }
        }
        .onDisappear { chrome.resume(after: chromeOverlay) }
        .task(id: membershipRequest) { [membershipRequest] in
            if let membershipRequest, membershipRequest.session == session.collectionSessionID {
                _ = try? await session.refreshSavedMembership(membershipRequest.workID)
            }
        }
    }

    private func toggleFavorite() {
        guard let identity = session.collectionSessionID else {
            showPicker = true
            return
        }
        do {
            try session.toggleFavorite(imageID: item.id, wasSaved: saved, for: identity)
        } catch {
            session.message = error.localizedDescription
        }
    }
}

struct CollectionAccessView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var showAuthorization = false
    var body: some View {
        ContentUnavailableView {
            Label(session.account == nil ? "登录后查看收藏" : "启用账号收藏", systemImage: "bookmark")
        } description: {
            Text("读取 Civitai 收藏夹，保存图片和视频，并在这里继续浏览。需要收藏读取与管理权限。")
        } actions: {
            Button { showAuthorization = true } label: {
                Text(session.account == nil ? "登录并启用收藏" : "补充收藏授权").frame(minHeight: 44)
            }.buttonStyle(AppActionButtonStyle(tone: .accent))
        }
        .ordinaryAppearance()
        .sheet(isPresented: $showAuthorization, onDismiss: { session.oauth.cancel() }) {
            CollectionAuthorizationView()
        }
        .onChange(of: session.hasCollectionAccess) { _, allowed in if allowed { showAuthorization = false } }
    }
}

private struct CollectionAuthorizationView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        LoginView(forCollections: true, onClose: { dismiss() }).ordinaryAppearance()
    }
}

struct CollectionsView: View {
    var showsBack = false

    private struct FolderPickerRequest: Identifiable {
        let id = UUID()
        let selection: Set<Int>
    }

    @EnvironmentObject private var session: SiteSession
    @State private var error: String?
    @State private var selectedCollectionIDs = Set<Int>()
    @State private var folderPickerRequest: FolderPickerRequest?
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
                CollectionWorksView(source: source, filter: $filter, showsBack: showsBack, onRefreshCollections: refresh) {
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
                .floatingPageBar("collections.top-bar") {
                    HStack(spacing: FloatingPageChrome.groupInset) {
                        if showsBack { FloatingPageBackButton() }
                        CollectionDownloadsLink()
                        Spacer()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        return Button {
            folderPickerRequest = FolderPickerRequest(selection: ids)
        } label: {
            FloatingPageIcon(symbol: ids.count > 1 ? "folder.fill" : "folder")
        }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .accessibilityLabel("选择收藏夹").accessibilityValue(title)
        .accessibilityIdentifier("collections.folder-picker")
        .popover(item: $folderPickerRequest, arrowEdge: .top) { request in
            CollectionFolderPicker(collections: presentedFolders, selection: request.selection) { ids in
                selectedCollectionIDs = ids.intersection(availableCollectionIDs)
                folderPickerRequest = nil
            }
            .presentationCompactAdaptation(.popover)
        }
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

private struct CollectionFolderPicker: View {
    let collections: [SavedCollection]
    @State var selection: Set<Int>
    let apply: (Set<Int>) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(collections) { collection in
                        let isSelected = selection.contains(collection.id)
                        FavoriteFolderRow(collection: collection, selected: isSelected, showsPrivacy: false,
                                          identifierPrefix: "collections.folder") {
                            if isSelected { selection.remove(collection.id) }
                            else { selection.insert(collection.id) }
                        }
                        .padding(.horizontal, FloatingPageChrome.cardInset)
                    }
                }
            }
            .frame(height: CGFloat(min(collections.count, 6) * 44))
        }
        .floatingTitleBar("收藏夹", leading: { EmptyView() }) {
            Button("应用") { apply(selection) }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("collections.apply-folders")
        }
        .frame(width: 264)
        .ordinaryPresentationAppearance()
    }

}

private struct FavoriteEditor: View {
    let item: MediaItem
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
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
                                PageStatusCard(title: error, symbol: "exclamationmark.circle", retryTitle: "重新读取收藏状态") {
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
                Button { dismiss() } label: { FloatingPageIcon(symbol: "xmark") }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .accessibilityLabel("取消")
            }) {
                Button { save() } label: { FloatingPageIcon(symbol: "checkmark") }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .accessibilityLabel("保存")
                    .disabled(!loaded || loading || saving || selected == original)
            }
            .task(id: session.collectionSessionID) { await load() }
        }.ordinaryPresentationAppearance()
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
            dismiss()
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
    struct Request: Identifiable {
        let id = UUID()
        let works: Set<Int>
        let operation: Operation
        let accountSession: SiteSession.AccountSessionID?
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
    mutating func openEditor(_ operation: Operation = .add, for accountSession: SiteSession.AccountSessionID?) {
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
    @State private var managing = false

    var body: some View {
        HStack(spacing: 8) {
            if managing, let folders = entry.folders {
                Button("返回") { managing = false }
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
                if entry.folders != nil {
                    Button("管理") { managing = true }
                        .buttonStyle(AppActionButtonStyle(tone: .accent))
                        .disabled(entry.count == 0 || !entry.canManage)
                        .accessibilityLabel("管理 \(entry.count)")
                        .accessibilityIdentifier("collection-batch.manage")
                } else {
                    Button("收藏") { entry.selection.wrappedValue.openEditor(for: session.accountSessionID) }
                        .buttonStyle(AppActionButtonStyle(tone: .accent))
                        .disabled(entry.count == 0 || !entry.canManage)
                        .accessibilityLabel("收藏 \(entry.count)")
                        .accessibilityIdentifier("favorite-batch.open")
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct FavoriteBatchBottomBar: ViewModifier {
    @Binding var selection: FavoriteBatchSelection
    let canManage: Bool
    let folders: Set<Int>?
    @Environment(\.favoriteSelectionBar) private var bar
    @State private var owner = UUID()
    @State private var visible = false

    private struct StateKey: Equatable {
        let count: Int?
        let canManage: Bool
        let folders: Set<Int>?
    }
    private var state: StateKey { .init(count: selection.works?.count, canManage: canManage, folders: folders) }
    private var entry: FavoriteSelectionBar.Entry? {
        selection.works.map { .init(owner: owner, count: $0.count, canManage: canManage, folders: folders, selection: $selection) }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onChange(of: state) { _, _ in if visible { update() } }
            .onDisappear { visible = false; bar?.clear(owner: owner) }
            .overlay(alignment: .bottom) {
                if bar == nil, let entry {
                    FavoriteBatchBarButtons(entry: entry)
                        .frame(height: 48)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 12)
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
    func favoriteBatchBottomBar(_ selection: Binding<FavoriteBatchSelection>, canManage: Bool, folders: Set<Int>? = nil) -> some View {
        modifier(FavoriteBatchBottomBar(selection: selection, canManage: canManage, folders: folders))
    }

    func favoriteBatchEditor(_ selection: Binding<FavoriteBatchSelection>) -> some View {
        sheet(item: selection.request) { request in
            BatchFavoriteEditor(request: request) {
                confirmed in
                guard selection.wrappedValue.request?.id == request.id else { return }
                selection.wrappedValue.confirm(confirmed)
            }
        }
    }
}

private struct BatchFavoriteEditor: View {
    let works: Set<Int>
    let operation: FavoriteBatchSelection.Operation
    let onConfirmed: (Set<Int>) -> Void
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @State private var remaining: Set<Int>
    @State private var selected = Set<Int>()
    private let openedSession: SiteSession.AccountSessionID?
    @State private var loadedSession: SiteSession.AccountSessionID?
    private var loaded: Bool { loadedSession.map { $0 == session.collectionSessionID } ?? false }
    @State private var saving = false
    @State private var attempted = false
    @State private var error: String?

    init(request: FavoriteBatchSelection.Request, onConfirmed: @escaping (Set<Int>) -> Void) {
        works = request.works
        operation = request.operation
        openedSession = request.accountSession
        self.onConfirmed = onConfirmed
        _remaining = State(initialValue: request.works)
    }

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
                    ContentUnavailableView("已\(operation.verb) \(confirmedCount) 项作品", systemImage: "checkmark.circle")
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
                            if saving || (!loaded && error == nil) {
                                ProgressView(saving ? "正在\(operation.verb)…" : "正在读取收藏夹…")
                                    .font(.footnote)
                                    .frame(maxWidth: .infinity)
                            }
                            if let error {
                                PageStatusCard(title: error, symbol: "exclamationmark.circle", retryTitle: "重新读取收藏夹",
                                               retry: loaded ? nil : { Task { await load() } })
                            }
                        }
                        .padding(.horizontal, FloatingPageChrome.pageInset)
                        .padding(.bottom, FloatingPageChrome.pageInset)
                    }
                }
            }
            .floatingTitleBar("批量\(operation.verb)", leading: {
                if !remaining.isEmpty { Button("关闭") { dismiss() }.disabled(saving) }
            }) {
                if remaining.isEmpty {
                    Button("完成") { dismiss() }
                } else {
                    Button(attempted ? "重试" : operation.verb, role: operation.isRemoval ? .destructive : nil) {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("favorite-batch.save")
                }
            }
            .task(id: session.collectionSessionID) { await load() }
            .onChange(of: session.accountSessionID) { _, _ in dismiss() }
        }
        .interactiveDismissDisabled(saving)
        .ordinaryPresentationAppearance()
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        guard session.accountSessionID == openedSession else { dismiss(); return }
        guard let identity = session.collectionSessionID, !saving else { return }
        loadedSession = nil; error = nil
        do {
            try await session.refreshCollections()
            try Task.checkCancellation()
            guard identity == session.collectionSessionID else { return }
            if case let .remove(folders) = operation {
                guard folders.isSubset(of: Set(session.collections.map(\.id))) else { throw ClientError.invalidResponse }
                selected = folders
            } else {
                selected = session.defaultCollectionIDs
            }
            loadedSession = identity
        } catch {
            if !Task.isCancelled, identity == session.collectionSessionID { self.error = error.localizedDescription }
        }
    }

    private func save() async {
        guard canSave, let identity = loadedSession else { return }
        saving = true; attempted = true; error = nil
        defer { saving = false }
        do {
            let result = try await session.updateFavorites(remaining, folders: selected,
                                                           removing: operation.isRemoval, for: identity)
            guard identity == session.collectionSessionID else { return }
            remaining.subtract(result.confirmed)
            onConfirmed(result.confirmed)
            if !remaining.isEmpty {
                let detail = result.error ?? "请稍后重试。"
                error = "已\(operation.verb) \(confirmedCount) 项，\(remaining.count) 项待确认。\(detail)"
            }
        } catch {
            if identity == session.collectionSessionID { self.error = error.localizedDescription }
        }
    }
}

private struct CollectionDownloadsLink: View {
    var body: some View {
        NavigationLink { OfflineDownloadTasksView() } label: {
            FloatingPageIcon(symbol: "arrow.down.to.line")
        }
        .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
        .accessibilityLabel("下载管理")
        .accessibilityIdentifier("collections.downloads")
    }
}

private struct CollectionWorksView<FolderControl: View>: View {
    let source: FeedSource
    @Binding var filter: FeedFilter
    let showsBack: Bool
    let onRefreshCollections: () async -> Void
    @ViewBuilder let folderControl: () -> FolderControl
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var blocklist = TagBlocklist.shared
    @ObservedObject private var authorBlocks = AuthorBlocklist.shared
    @StateObject private var feed = FeedStore(diagnostics: .shared, observations: .shared, authorBlocks: .shared)
    @State private var showFilter = false
    @State private var viewerItem: MediaItem?
    @State private var focused: Int?
    @State private var gridAnchor: Int?
    @State private var needsRefresh = false
    @State private var cachedPreview: (key: FeedStoreRequestKey, items: [MediaItem])?
    @State private var lastAligned: (key: FeedStoreRequestKey, at: Date)?
    @State private var pendingPreviewOpen: Int?
    @State private var favoriteBatch = FavoriteBatchSelection()
    #if DEBUG && targetEnvironment(simulator)
    @State private var cacheWriteVerified = false
    #endif
    private var requestKey: FeedStoreRequestKey { .init(identity: session.feedIdentity, filter: filter, source: source) }
    private struct CacheContext: Equatable {
        let key: FeedStoreRequestKey
        let owner: Int
        let scope: CollectionListCache.Scope
        let revision: Int
    }
    private var cacheContext: CacheContext? {
        guard collectionListCachingEnabled, session.hasCollectionAccess, let account = session.account,
              let scope = CollectionListCache.Scope(source: source, filter: filter, browsingLevel: account.browsingLevel ?? 1) else { return nil }
        return .init(key: requestKey, owner: account.id, scope: scope, revision: session.collectionRevision)
    }
    private var previewItems: [MediaItem]? {
        guard cachedPreview?.key == requestKey, let context = cacheContext,
              let cached = cachedPreview?.items,
              feed.requestKey != requestKey || (feed.items.isEmpty && !feed.reachedEnd) else { return nil }
        var visible = FeedAccumulator(keeping: cached.filter { item in
            guard let level = item.browsingLevel, level > 0 else { return false }
            return level & ~context.scope.browsingLevel == 0
        }, blockedTags: blocklist.names, videoDurationRange: filter.videoDurationRange)
        visible.applyBlockedAuthors(ids: authorBlocks.blockedIDs, handles: authorBlocks.blockedHandles)
        return visible.items.isEmpty ? nil : visible.items
    }
    private var gridPreview: [MediaItem]? {
        previewItems ?? (feed.requestKey == requestKey ? nil : [])
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
        session.hasCollectionAccess && feed.requestKey == requestKey && previewItems == nil && !feed.items.isEmpty
    }
    var body: some View {
        MediaGrid(feed: feed, previewItems: gridPreview, waitingForPreviewOpen: pendingPreviewOpen,
                  anchor: $gridAnchor, isVisible: viewerItem == nil,
                  loadMoreAutomatically: { await next(automatically: true) }, refreshFromStart: refreshFeed,
                  horizontalInset: AppTheme.spacing, favoriteSelection: favoriteBatch.works,
                  beginSelection: canSelectWorks ? { favoriteBatch.begin(selecting: $0.id) } : nil,
                  open: { item in
            if favoriteBatch.works != nil { favoriteBatch.toggle(item.id) }
            else { openWork(item) }
        }, loadMore: { await next() })
            .refreshable { await refreshWorks() }
            .avoidOverlaidTabBar()
            .floatingPageBar("collections.top-bar") {
                HStack(spacing: FloatingPageChrome.groupInset) {
                    if showsBack { FloatingPageBackButton() }
                    CollectionDownloadsLink()
                    folderControl()
                    FloatingMediaPicker(title: "收藏作品类型", selection: mediaKindSelection, identifier: "collection.media-kind")
                    Menu {
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
                        Button("刷新作品", systemImage: "arrow.clockwise") { Task { await refreshWorks() } }
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
        .favoriteBatchBottomBar($favoriteBatch, canManage: canSelectWorks, folders: currentFolders)
        .favoriteBatchEditor($favoriteBatch)
        .task(id: requestKey) { await load() }
        #if DEBUG && targetEnvironment(simulator)
        .overlay(alignment: .topLeading) {
            if CollectionListCacheQA.fixture != nil {
                Text(cacheWriteVerified ? "stored" : "pending").font(.system(size: 1))
                    .frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("collection-cache.qa")
            }
        }
        #endif
        .onChange(of: requestKey) { _, _ in favoriteBatch.reset() }
        .onChange(of: blocklist.names) { _, tags in feed.applyBlockedTags(tags); favoriteBatch.reset() }
        .onChange(of: authorBlocks.entries) { _, _ in favoriteBatch.reset() }
        .onChange(of: session.feedIdentity) { _, _ in
            cachedPreview = nil
            pendingPreviewOpen = nil
            viewerItem = nil
            focused = nil
        }
        .onChange(of: session.collectionRevision) { _, _ in
            cachedPreview = nil
            pendingPreviewOpen = nil
            if viewerItem == nil { Task { await reload() } } else { needsRefresh = true }
        }
        .navigationDestination(isPresented: $showFilter) {
            FilterView(filter: $filter, isCollection: true)
        }
        .mediaCover(item: $viewerItem, onDismiss: {
            if needsRefresh { needsRefresh = false; Task { await reload() } }
        }) { opening in
            FeedMediaViewer(items: feed.items, focused: $focused, initialID: opening.id,
                            continuationState: feed.continuationState, loadMoreAutomatically: { await next(automatically: true) },
                            refreshFromStart: refreshFeed, restartRetryAvailableAt: feed.restartRetryAvailableAt,
                            onDetailsVisibility: { feed.setTagPolicyDeferred($0) },
                            onClose: { viewerItem = nil }) {
                await next()
            }
        }
    }

    private func load() async {
        guard session.hasCollectionAccess else { feed.clear(); return }
        let key = requestKey, context = cacheContext
        if lastAligned?.key == key, let at = lastAligned?.at, feed.requestKey == key {
            if Date.now.timeIntervalSince(at) > 30 { await refreshFeed() }
            return
        }
        cachedPreview = nil
        pendingPreviewOpen = nil
        if feed.requestKey != key { gridAnchor = nil; focused = nil }
        if let context, session.savingFavoriteID == nil,
           let rows = await CollectionListCache.shared.rows(owner: context.owner, scope: context.scope),
           !Task.isCancelled, cacheContext == context, session.savingFavoriteID == nil {
            cachedPreview = (key, rows.map { row in
                row.preview(with: MediaCache.shared.cachedCollectionPreview(keys: row.previewKeys))
            })
        }
        guard !Task.isCancelled, key == requestKey else { return }
        let commit = await feed.activate(session: session, filter: key.filter, source: key.source, blockedTags: blocklist.names)
        if feed.accepts(commit, identity: session.feedIdentity), commit.state == .loaded || commit.state == .ended {
            await finishAlignment(key: key, context: context, firstPage: true)
        } else if key == requestKey, feed.continuationState.failure != nil {
            pendingPreviewOpen = nil
        }
    }

    private func openWork(_ item: MediaItem) {
        if feed.requestKey == requestKey, let current = feed.items.first(where: { $0.id == item.id }) {
            focused = current.id
            viewerItem = current
        } else if previewItems != nil, feed.continuationState.failure == nil {
            pendingPreviewOpen = item.id
        }
    }

    private func next(automatically: Bool = false) async {
        let key = requestKey, context = cacheContext
        guard feed.requestKey == key else { return }
        let commit = if automatically { await feed.nextAutomatically(session: session) } else { await feed.next(session: session) }
        if commit.didCommit, feed.accepts(commit, identity: session.feedIdentity), commit.state == .loaded || commit.state == .ended {
            await finishAlignment(key: key, context: context, firstPage: lastAligned?.key != key)
        } else if key == requestKey, feed.continuationState.failure != nil {
            pendingPreviewOpen = nil
        }
    }

    private func finishAlignment(key: FeedStoreRequestKey, context: CacheContext?, firstPage: Bool) async {
        guard !Task.isCancelled, requestKey == key, feed.requestKey == key, session.hasCollectionAccess else { return }
        cachedPreview = nil
        if firstPage { lastAligned = (key, .now) }
        if let pending = pendingPreviewOpen {
            pendingPreviewOpen = nil
            if let item = feed.items.first(where: { $0.id == pending }) { openWork(item) }
        }
        guard let context, cacheContext == context, session.collectionsKnown, session.savingFavoriteID == nil else { return }
        let rows = feed.items.prefix(CollectionListCache.previewLimit).map {
            CollectionListCache.Row($0, previewKeys: MediaCache.shared.collectionPreviewKeys(for: $0))
        }
        let written = await CollectionListCache.shared.storeRows(rows, owner: context.owner, scope: context.scope,
                                                               verifiedFolders: session.collections)
        #if DEBUG && targetEnvironment(simulator)
        if CollectionListCacheQA.fixture != nil, !Task.isCancelled, cacheContext == context { cacheWriteVerified = written }
        #endif
    }

    private func reload() async {
        guard session.hasCollectionAccess else { feed.clear(); return }
        await refreshFeed()
    }
    private func refreshFeed() async {
        let key = requestKey, context = cacheContext
        let result = await feed.restartFromStart(session: session, filter: key.filter, source: key.source, blockedTags: blocklist.names)
        if result.status == .committed { await finishAlignment(key: key, context: context, firstPage: true) }
        else if result.status == .failedRetainingPrevious, key == requestKey { pendingPreviewOpen = nil }
    }
    private func refreshWorks() async {
        await refreshFeed()
        if !Task.isCancelled { await onRefreshCollections() }
    }
}
