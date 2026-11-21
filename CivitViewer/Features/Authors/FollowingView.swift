import SwiftUI
import Observation

struct FollowingView: View {
    private enum PresentationOrder: String, CaseIterable, Identifiable {
        case newest, oldest, nameAscending, nameDescending
        var id: Self { self }
        var title: String {
            switch self {
            case .newest: "最近关注"
            case .oldest: "最早关注"
            case .nameAscending: "名称 A–Z"
            case .nameDescending: "名称 Z–A"
            }
        }
        var sort: FollowingSort { self == .nameAscending || self == .nameDescending ? .name : .followed }
        var reverse: Bool { self == .oldest || self == .nameDescending }
        init(sort: FollowingSort, reverse: Bool) {
            switch (sort, reverse) {
            case (.followed, false): self = .newest
            case (.followed, true): self = .oldest
            case (.name, false): self = .nameAscending
            case (.name, true): self = .nameDescending
            }
        }
    }
    @EnvironmentObject private var session: SiteSession
    @StateObject private var store = FollowingListStore(cache: .shared)
    @State private var openedAuthor: CreatorRoute?
    @AppStorage("following.sort") private var sortRaw = FollowingSort.followed.rawValue
    @AppStorage("following.reverseTime") private var reverseTime = false
    @AppStorage("following.reverseName") private var reverseName = false
    private var sort: FollowingSort { FollowingSort(rawValue: sortRaw) ?? .followed }
    private var reverse: Bool { sort == .followed ? reverseTime : reverseName }
    private var presentationOrder: PresentationOrder {
        get { PresentationOrder(sort: sort, reverse: reverse) }
        nonmutating set {
            sortRaw = newValue.sort.rawValue
            if newValue.sort == .followed { reverseTime = newValue.reverse }
            else { reverseName = newValue.reverse }
        }
    }
    private var key: FollowingListKey { .init(identity: session.followingIdentity, memberIDs: session.following, revision: session.followingRevision) }
    private var current: Bool { store.requestKey == key }
    private var orderIdentity: String { "\(session.followingIdentity):\(sort.rawValue):\(reverse)" }
    var body: some View {
        Group {
            if session.account == nil {
                ScrollView {
                    PageMessageCard(title: "登录后查看关注", symbol: "star", detail: "与 Civitai 账号同步关注关系。") {
                        Button("登录 Civitai") { session.openLogin() }
                            .buttonStyle(AppActionButtonStyle(tone: .accent))
                    }
                }
                .pageScrollContentInsets()
            } else if current, store.complete {
                List {
                    Section {
                        ForEach(store.ordered(sort, reverse: reverse)) { creator in
                            Button {
                                openedAuthor = CreatorRoute(creator: creator, kind: .image)
                                    .preparing(session: session, blockedTags: TagBlocklist.shared.names)
                            } label: {
                                AuthorRowIdentity(name: creator.username).authorCardRow(horizontalInset: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .floatingCardListRows()
                    if store.creators.isEmpty {
                        Section { Text("你还没有关注作者").foregroundStyle(.secondary) }
                            .floatingCardListRows()
                    }
                    if store.error != nil {
                        Section {
                            HStack(spacing: FloatingPageChrome.spacing) {
                                Spacer(minLength: 0)
                                StatusReloadButton(title: "重新加载关注列表") { Task { await load(force: true) } }
                            }
                        }
                        .floatingCardListRows()
                    }
                    Section {
                        Text("共 \(store.creators.count) 位")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .floatingCardListRows()
                }
                .accessibilityIdentifier("following.card-list")
                .listStyle(.plain)
                .listRowSpacing(FloatingPageChrome.groupInset)
                .id(orderIdentity)
                .refreshable { await load(force: true) }
            } else if !current || store.loading {
                VStack {
                    Spacer(minLength: 0)
                    ProgressView()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("following.loading")
            } else {
                List {
                    Section {
                        if store.error != nil {
                            HStack(spacing: FloatingPageChrome.spacing) {
                                Spacer(minLength: 0)
                                StatusReloadButton(title: "重新加载关注列表") { Task { await load(force: true) } }
                            }
                        }
                    }
                    .floatingCardListRows()
                }
                .listStyle(.plain)
                .refreshable { await load(force: true) }
            }
        }
        .avoidOverlaidTabBar(constrainViewport: true)
        .existingFeedbackToast(store.error, active: current, scope: session.feedIdentity)
        .navigationDestination(item: $openedAuthor) { CreatorView(creator: $0.creator, initialKind: $0.kind, preparation: $0.preparation) }
        .floatingTitleBar("我的关注") {
                AppValueSelector(title: "关注排序", selection: Binding(get: { presentationOrder }, set: { presentationOrder = $0 }),
                                 options: PresentationOrder.allCases, name: { $0.title }) {
                    FloatingPageIcon(symbol: "arrow.up.arrow.down")
                }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("关注排序")
                .accessibilityValue(presentationOrder.title)
                .accessibilityIdentifier("following.order")
        }
        .task(id: key) { await load(force: false) }.ordinaryAppearance()
    }
    private func load(force: Bool) async {
        guard !Task.isCancelled else { return }
        guard session.account != nil else { store.clear(); return }
        let requestedKey = key
        if !force, store.requestKey == requestedKey, store.complete,
           !store.isStaleSnapshot, store.error == nil { return }
        await store.reload(key: requestedKey, source: session)
    }
}
