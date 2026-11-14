import SwiftUI

struct FilterView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var openedIdentity: SiteSession.AccountSessionID?
    @State private var capturedIdentity = false
    @Binding private var filter: FeedFilter
    @State private var draft: FeedFilter
    private let context: FilterContext
    private let saveAsDefaultForFollowing: Bool?
    private let showsMediaSelector: Bool
    private let isCollection: Bool
    @Environment(\.dismiss) private var dismiss

    init(filter: Binding<FeedFilter>, context: FilterContext = .discovery,
         saveAsDefaultForFollowing: Bool? = nil, showsMediaSelector: Bool = false, isCollection: Bool = false) {
        _filter = filter
        _draft = State(initialValue: filter.wrappedValue)
        self.context = context
        self.saveAsDefaultForFollowing = saveAsDefaultForFollowing
        self.showsMediaSelector = showsMediaSelector
        self.isCollection = isCollection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                if showsMediaSelector {
                    FloatingMediaPicker(title: "默认媒体", selection: Binding(get: { draft.effectiveKind }, set: { draft = draft.selecting(kind: $0) }), identifier: "filter.media-kind")
                }
                if !isCollection {
                    SettingsControlCard("排序与范围") {
                        SettingsChoice(title: "排序", selection: $draft.sort,
                                       options: FeedSort.allCases.map(\.rawValue), name: { FeedSort(rawValue: $0)?.title ?? $0 })
                            .accessibilityIdentifier("filter.sort")
                        Divider()
                        SettingsChoice(title: "时间范围", selection: $draft.period,
                                       options: FeedPeriod.allCases.map(\.rawValue), name: { FeedPeriod(rawValue: $0)?.title ?? $0 })
                            .accessibilityIdentifier("filter.period")
                    }
                }
                SettingsControlCard("内容范围") {
                    if !isCollection {
                        SettingsChoice(title: "基础模型", selection: $draft.baseModel,
                                       options: ["", "SDXL 1.0", "Flux.1 D", "Wan Video"], name: { value in
                            switch value {
                            case "": "全部"
                            case "SDXL 1.0": "SDXL"
                            default: value
                            }
                        })
                        Divider()
                    }
                    Toggle("仅看 PG", isOn: $draft.onlyPG)
                        .frame(minHeight: FloatingPageChrome.controlHeight)
                        .accessibilityIdentifier("filter.only-pg")
                        .accessibilityHint("关闭后遵循账号和站点的内容范围")
                }
                VideoDurationFilterSection(range: $draft.videoDurationRange)
                SettingsControlCard {
                    Button("重置筛选") {
                        if isCollection { draft = .defaults(for: context, kind: filter.effectiveKind) }
                        else { draft = draft.resetting(in: context) }
                    }
                        .frame(minHeight: FloatingPageChrome.controlHeight)
                }
            }
            .pageScrollContentInsets()
        }
        .floatingTitleBar(isCollection ? "收藏筛选" : "浏览条件") {
            Button { dismiss() } label: { FloatingPageIcon(symbol: "checkmark") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("完成")
        }
        .onAppear {
            if !capturedIdentity { openedIdentity = session.accountSessionID; capturedIdentity = true }
        }
        .commitOnPageReturn { [draft, openedIdentity, capturedIdentity] in
            guard capturedIdentity, openedIdentity == session.accountSessionID else { return }
            filter = draft
            if let followed = saveAsDefaultForFollowing { draft.saveDefault(followed: followed) }
        }
        .ordinaryAppearance()
    }
}

struct SettingsControlCard<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            PageContentCard { content }
                .font(.subheadline)
                .toggleStyle(CompactSettingsToggleStyle())
        }
    }
}

struct CompactSettingsToggleStyle: ToggleStyle {
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        let track = Capsule()
            .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.35))
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 14, height: 14).padding(3)
            }
            .frame(width: 36, height: 20)

        return Button { configuration.isOn.toggle() } label: {
            Group {
                if showsLabel {
                    HStack(spacing: FloatingPageChrome.spacing) {
                        configuration.label
                        Spacer(minLength: FloatingPageChrome.spacing)
                        track
                    }
                } else {
                    track.frame(width: FloatingPageChrome.controlHeight)
                }
            }
            .frame(minHeight: FloatingPageChrome.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

struct SettingsChoice<Value: Hashable>: View {
    let title: String
    let symbol: String?
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String

    init(title: String, symbol: String? = nil, selection: Binding<Value>, options: [Value], name: @escaping (Value) -> String) {
        self.title = title
        self.symbol = symbol
        self._selection = selection
        self.options = options
        self.name = name
    }

    var body: some View {
        AppValueSelector(title: title, selection: $selection, options: options, name: name) {
            HStack(spacing: FloatingPageChrome.groupInset) {
                if let symbol { SettingsRowLabel(title, symbol) }
                else { Text(title).font(.subheadline) }
                Spacer(minLength: FloatingPageChrome.spacing)
                ChoiceValueLabel(title: name(selection))
            }
            .foregroundStyle(.primary)
            .frame(minHeight: FloatingPageChrome.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(name(selection))
    }
}

private struct ChoiceValueLabel: View {
    let title: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.valueSelectorExpanded) private var expanded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: FloatingPageChrome.groupInset) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .font(FloatingPageChrome.controlFont)
        .foregroundStyle(expanded ? Color.accentColor : Color.primary)
        .padding(.horizontal, FloatingPageChrome.spacing)
        .padding(.vertical, FloatingPageChrome.groupInset)
        .frame(minHeight: FloatingPageChrome.visibleHeight(nested: true))
        .background(expanded ? AppTheme.selectionFill(for: scheme) : AppTheme.pageBackground(for: scheme),
                    in: FloatingPageChrome.surfaceShape(nested: true))
        .overlay { FloatingPageChrome.surfaceShape(nested: true).strokeBorder(expanded ? Color.accentColor.opacity(0.55) : .clear, lineWidth: ContentMetrics.Optical.hairline) }
        .animation(reduceMotion ? nil : .easeInOut(duration: ContentMetrics.Choice.motionDuration), value: expanded)
    }
}

struct VideoDurationFilterSection: View {
    @Binding var range: VideoDurationRange?
    var body: some View {
        SettingsControlCard {
            Toggle("视频时长", isOn: Binding(get: { range != nil }, set: { enabled in
                range = enabled ? .init() : nil
            }))
            .frame(minHeight: FloatingPageChrome.controlHeight)
            .accessibilityIdentifier("duration.range.enabled")
            .accessibilityHint("开启后只匹配已知时长的视频")
            if range != nil {
                Divider()
                VideoDurationRangeControl(range: $range).padding(.vertical, FloatingPageChrome.spacing)
            }
        }
    }
}

struct SettingsRowLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, _ symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        HStack(spacing: FloatingPageChrome.spacing) {
            Image(systemName: symbol).font(.system(size: ContentMetrics.Icon.primary, weight: .regular)).frame(width: 22, height: 22).accessibilityHidden(true)
            Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 26)
    }
}

private struct BlockedTagsView: View {
    @ObservedObject private var blocklist = TagBlocklist.shared
    @State private var name = ""
    @State private var error: String?
    @State private var errorAttempt = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                SettingsControlCard {
                    TextField("输入站点标签名", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(add)
                        .frame(minHeight: FloatingPageChrome.controlHeight)
                }
                SettingsControlCard(blocklist.names.isEmpty ? nil : "已屏蔽 · \(blocklist.names.count)") {
                    if blocklist.names.isEmpty {
                        Text("尚未屏蔽标签").foregroundStyle(.secondary)
                            .frame(minHeight: FloatingPageChrome.controlHeight)
                    }
                    if !blocklist.names.isEmpty {
                        TagPillLayout() {
                            ForEach(blocklist.names.sorted(), id: \.self) { tag in
                                Button(role: .destructive) { blocklist.remove(tag) } label: {
                                    WorkTagLabel(title: tag, selected: false, blocked: true, removable: true)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除屏蔽标签 " + tag)
                            }
                        }
                        .padding(.vertical, FloatingPageChrome.groupInset)
                    }
                }
                Text("仅在本机按站点标签名屏蔽作品。标签尚未核实的作品会暂时隐藏。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, FloatingPageChrome.cardInset)
            }
            .pageScrollContentInsets()
        }
        .floatingTitleBar("屏蔽标签") {
            Button(action: add) { FloatingPageIcon(symbol: "plus") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("添加屏蔽标签")
                .disabled(TagPolicy.normalize(name).isEmpty)
        }
        .ordinaryAppearance()
        .existingFeedbackToast(error, id: errorAttempt)
    }
    private func add() {
        if blocklist.add(name) { name = ""; error = nil }
        else {
            errorAttempt += 1
            error = "请使用 1—80 个字符，最多保存 100 个标签。"
        }
    }
}

private struct MediaRailOrderView: View {
    @AppStorage(MediaRailAction.defaultsKey) private var railOrder = ""
    @AppStorage(MediaRailAction.hiddenDefaultsKey) private var hiddenRailActions = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var scaledRowHeight: CGFloat = 44
    @GestureState private var drag: RailDrag?

    private struct RailDrag {
        let action: MediaRailAction
        let offset: CGFloat
    }

    private let rowSpacing = FloatingPageChrome.groupInset
    private var rowHeight: CGFloat { max(FloatingPageChrome.controlHeight, scaledRowHeight) }
    private var rowStep: CGFloat { rowHeight + rowSpacing }
    private var actions: [MediaRailAction] { MediaRailAction.ordered(railOrder) }
    private var hidden: Set<MediaRailAction> { MediaRailAction.hidden(hiddenRailActions) }

    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: FloatingPageChrome.groupInset) {
                VStack(spacing: rowSpacing) {
                    ForEach(actions, id: \.self) { action in
                        row(action)
                            .offset(y: rowOffset(action))
                            .zIndex(drag?.action == action ? 1 : 0)
                    }
                }
                .padding(FloatingPageChrome.groupInset)
                .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)

            }
            .pageScrollContentInsets()
        }
        .floatingTitleBar("播放侧栏") {
            Button {
                railOrder = ""
                hiddenRailActions = ""
            } label: { FloatingPageIcon(symbol: "arrow.counterclockwise") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .disabled(actions == MediaRailAction.allCases && hidden.isEmpty)
                .accessibilityLabel("恢复默认")
                .accessibilityIdentifier("settings.media-rail.reset")
        }
        .ordinaryAppearance()
    }

    private func row(_ action: MediaRailAction) -> some View {
        let visible = !hidden.contains(action)
        return HStack(spacing: 2) {
            SettingsRowLabel(action.title, action.symbol)
                .foregroundStyle(visible ? Color.primary : Color.secondary)
            if action == .cleanImage || action == .mute {
                Text(action == .cleanImage ? "仅图片" : "仅视频")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            Toggle(action.title, isOn: Binding(
                get: { !hidden.contains(action) },
                set: { setVisibility($0, for: action) }
            ))
            .toggleStyle(CompactSettingsToggleStyle(showsLabel: false))
            .accessibilityHint(action == .cleanImage ? "仅适用于图片侧栏" : (action == .mute ? "仅适用于视频侧栏" : ""))
            .accessibilityIdentifier("settings.media-rail.\(action.rawValue)")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: ContentMetrics.Icon.primary, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .highPriorityGesture(reorderGesture(action))
                .accessibilityLabel("拖动排序：\(action.title)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: move(action, by: 1)
                    case .decrement: move(action, by: -1)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("settings.media-rail.drag.\(action.rawValue)")
        }
        .padding(.leading, FloatingPageChrome.cardInset)
        .frame(height: rowHeight)
        .background(.primary.opacity(0.065), in: FloatingPageChrome.surfaceShape(nested: true))
    }

    private func reorderGesture(_ action: MediaRailAction) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($drag) { value, state, _ in
                guard let index = actions.firstIndex(of: action) else { return }
                let upper = CGFloat(actions.count - 1 - index) * rowStep
                let lower = -CGFloat(index) * rowStep
                state = RailDrag(action: action, offset: min(upper, max(lower, value.translation.height)))
            }
            .onEnded { value in
                move(action, by: Int((value.translation.height / rowStep).rounded()))
            }
    }

    private func rowOffset(_ action: MediaRailAction) -> CGFloat {
        guard let drag, let source = actions.firstIndex(of: drag.action),
              let index = actions.firstIndex(of: action) else { return 0 }
        if drag.action == action { return drag.offset }
        let destination = source + Int((drag.offset / rowStep).rounded())
        if source < index && index <= destination { return -rowStep }
        if destination <= index && index < source { return rowStep }
        return 0
    }

    private func move(_ action: MediaRailAction, by distance: Int) {
        var ordered = actions
        guard let source = ordered.firstIndex(of: action) else { return }
        let destination = min(max(source + distance, 0), ordered.count - 1)
        guard destination != source else { return }
        ordered.remove(at: source)
        ordered.insert(action, at: destination)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            railOrder = ordered.map(\.rawValue).joined(separator: ",")
        }
    }

    private func setVisibility(_ visible: Bool, for action: MediaRailAction) {
        var hidden = self.hidden
        if visible { hidden.remove(action) }
        else { hidden.insert(action) }
        hiddenRailActions = MediaRailAction.allCases.filter { hidden.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var cache = MediaCache.shared
    @ObservedObject private var orientation = ViewingOrientationController.shared
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("muted") private var muted = true
    @AppStorage("automaticVideoRepair") private var automaticVideoRepair = true
    @AppStorage("wifiVideoPrefetch") private var wifiVideoPrefetch = true
    @AppStorage("mediaPrefetchCount") private var mediaPrefetchCount = 6
    @AppStorage("mediaPrefetchConcurrency") private var mediaPrefetchConcurrency = 4
    @AppStorage("cacheLimitGB") private var cacheLimitGB = 5
    @AppStorage("deduplicateMedia") private var deduplicateMedia = true
    @AppStorage(AppTheme.appearanceKey) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var defaultDiscovery = FeedFilter.saved()
    @State private var defaultFollowing = FeedFilter.saved(followed: true)
    @State private var editDefault: Int?
    private var appearanceSelection: Binding<AppAppearance> {
        Binding(get: { AppAppearance(rawValue: appearanceRaw) ?? .system }, set: { appearanceRaw = $0.rawValue })
    }
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }
    @State private var refreshingAccount = false

    var body: some View {
        List {
            Group {
                Group {
                    sectionHeading("Civitai 账号")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    if let account = session.account {
                        LabeledContent {
                            Text(account.username).lineLimit(1)
                        } label: {
                            SettingsRowLabel("当前账号", "person.crop.circle")
                        }
                        NavigationLink { AccountPreferencesView() } label: { SettingsRowLabel("账号内容偏好", "gearshape") }
                        NavigationLink { FollowingView() } label: { SettingsRowLabel("关注的作者", "person.2") }
                        Button(role: .destructive) { Task { await session.clearLocalLogin() } } label: { SettingsRowLabel("退出此客户端", "rectangle.portrait.and.arrow.right") }
                    } else {
                        Button { session.openLogin() } label: { SettingsRowLabel("登录 Civitai", "person.crop.circle") }
                    }
                    LabeledContent { Text("civitai.red") } label: { SettingsRowLabel("连接站点", "globe") }
                }
                Group {
                    sectionHeading("外观")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    SettingsChoice(title: "显示模式", symbol: "circle.lefthalf.filled",
                                   selection: appearanceSelection, options: AppAppearance.allCases, name: { $0.title })
                        .accessibilityIdentifier("settings-appearance-picker")
                }
                Group {
                    sectionHeading("下载")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    NavigationLink {
                        OfflineDownloadSettingsView()
                    } label: {
                        SettingsRowLabel("下载设置", "arrow.down.circle")
                    }
                    .accessibilityIdentifier("settings.downloads")
                }
                Group {
                    sectionHeading("播放")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    NavigationLink { MediaRailOrderView() } label: { SettingsRowLabel("播放侧栏", "sidebar.right") }
                        .accessibilityIdentifier("settings.media-rail")
                    Toggle(isOn: $autoplay) { SettingsRowLabel("自动播放视频", "play.circle") }
                    Toggle(isOn: $muted) { SettingsRowLabel("视频默认静音", "speaker.slash") }
                    Toggle(isOn: $automaticVideoRepair) { SettingsRowLabel("自动修复不兼容视频", "wand.and.stars") }
                    Toggle(isOn: Binding(get: { orientation.automatic }, set: { orientation.setAutomatic($0) })) { SettingsRowLabel("自动旋转", "rotate.right") }
                    if !orientation.automatic {
                        Button { orientation.toggleOrientation() } label: {
                            SettingsRowLabel("手动切换方向", "rectangle.portrait.rotate")
                        }
                        .accessibilityIdentifier("settings.rotation.toggle")
                    }
                }
                Group {
                    sectionHeading("浏览记录")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    NavigationLink { BrowsingHistoryView() } label: { SettingsRowLabel("最近浏览与接着看", "clock.arrow.circlepath") }
                }
                Group {
                    sectionHeading("诊断")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    NavigationLink { LocalDiagnosticsView() } label: { SettingsRowLabel("本机错误与诊断记录", "stethoscope") }
                }
                Group {
                    sectionHeading("默认浏览设置")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    Button { editDefault = 0 } label: { SettingsRowLabel("推荐时间线默认筛选", "slider.horizontal.3") }
                    Button { editDefault = 1 } label: { SettingsRowLabel("关注时间线默认筛选", "person.2") }
                    NavigationLink { BlockedTagsView() } label: { SettingsRowLabel("屏蔽标签", "tag.slash") }
                    NavigationLink { AuthorBlocklistView() } label: { SettingsRowLabel("屏蔽的作者", "person.crop.circle.badge.xmark") }
                    NavigationLink { LocalTagLibraryView() } label: { SettingsRowLabel("本地标签库与同步", "externaldrive") }
                    Toggle(isOn: $deduplicateMedia) { SettingsRowLabel("合并相同媒体", "rectangle.on.rectangle.slash") }
                }
                Group {
                    sectionHeading("时间线缓存")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    Toggle(isOn: $wifiVideoPrefetch) { SettingsRowLabel("仅在 Wi-Fi 下预取视频", "wifi") }
                    SettingsChoice(title: "预加载作品", symbol: "arrow.down.circle",
                                   selection: $mediaPrefetchCount, options: [3, 6, 10], name: { "后续 \($0) 条" })
                    // Bring the track closer while keeping the slider's full touch height.
                    VStack(alignment: .leading, spacing: -FloatingPageChrome.groupInset) {
                        SettingsRowLabel("预载并发", "arrow.down.forward.and.arrow.up.backward")
                            .accessibilityHidden(true)
                        PrefetchConcurrencySlider(value: $mediaPrefetchConcurrency)
                            .frame(height: FloatingPageChrome.controlHeight)
                    }
                    .padding(.vertical, FloatingPageChrome.spacing)
                    if let status = cache.preloadStatus {
                        LabeledContent("预加载状态", value: status.summary)
                    }
                    LabeledContent { Text(cache.diskUsageKnown ? AppTheme.storageSize(cache.diskBytes) : "暂时无法统计") } label: { SettingsRowLabel("媒体缓存", "internaldrive") }
                        .accessibilityIdentifier("settings.media-cache-size")
                    SettingsChoice(title: "磁盘缓存上限", symbol: "externaldrive",
                                   selection: $cacheLimitGB, options: [1, 5, 10, 20], name: { "\($0) GB" })
                    LabeledContent { Text("\(cache.cacheHits) 次") } label: { SettingsRowLabel("本次缓存复用", "arrow.triangle.2.circlepath") }
                    Button { cache.clear() } label: { SettingsRowLabel("清理媒体缓存", "trash") }
                }

                Group {
                    sectionHeading("关于")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isHeader)

                    LabeledContent { Text(appVersion) } label: { SettingsRowLabel("版本", "info.circle") }
                    NavigationLink { MediaRepairLicenseView() } label: { SettingsRowLabel("开源组件", "curlybraces") }
                }
            }
            .font(.subheadline)
            .toggleStyle(CompactSettingsToggleStyle())
            .floatingCardListRows()
        }
        .listStyle(.plain)
        .listRowSpacing(FloatingPageChrome.groupInset)
        .avoidOverlaidTabBar(constrainViewport: true)
        .clipped()
        .floatingTitleBar("账号与设置", layoutIdentity: session.account != nil) {
            if session.account != nil {
                Button {
                    guard !refreshingAccount else { return }
                    refreshingAccount = true
                    Task { await session.refreshAccount(); refreshingAccount = false }
                } label: {
                    if refreshingAccount { ProgressView().controlSize(.small) }
                    else { FloatingPageIcon(symbol: "arrow.clockwise") }
                }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .disabled(refreshingAccount)
                .accessibilityLabel("刷新账号与关注")
                .accessibilityIdentifier("settings.account.refresh")
            }
        }
            .ordinaryAppearance().environment(\.defaultMinListRowHeight, FloatingPageChrome.controlHeight).onAppear { cache.trim() }
            .onChange(of: cacheLimitGB) { _, _ in cache.trim() }
            .navigationDestination(isPresented: Binding(get: { editDefault != nil }, set: { if !$0 { editDefault = nil } })) {
                if editDefault == 1 { FilterView(filter: $defaultFollowing, context: .following, saveAsDefaultForFollowing: true, showsMediaSelector: true) }
                else { FilterView(filter: $defaultDiscovery, saveAsDefaultForFollowing: false, showsMediaSelector: true) }
            }
    }
    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: .secondaryLabel))
    }

}

struct AccountPreferencesView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var refreshing = false

    var body: some View {
        Group {
            if let identity = session.accountSessionID, let account = session.account, let level = account.browsingLevel {
                AccountPreferencesForm(identity: identity, level: level, blur: account.blurNsfw)
                    .id(identity).id(account.blurNsfw != nil)
            } else {
                ScrollView {
                    PageStatusCard(title: "暂未取得账号浏览偏好", symbol: "person.crop.circle")
                        .pageScrollContentInsets()
                }
                .floatingTitleBar("账号内容偏好") {
                    Button {
                        guard !refreshing else { return }
                        refreshing = true
                        Task { await session.refreshAccount(); refreshing = false }
                    } label: {
                        if refreshing { ProgressView().controlSize(.small) }
                        else { FloatingPageIcon(symbol: "arrow.clockwise") }
                    }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .disabled(refreshing).accessibilityLabel("重新读取账号偏好")
                }
            }
        }.ordinaryAppearance()
    }
}

private struct AccountPreferencesForm: View {
    let identity: SiteSession.AccountSessionID
    @EnvironmentObject private var session: SiteSession
    @State private var level: Int
    @State private var blur: Bool
    @State private var saving = false
    private let levels: [(Int, String)] = [(1, "PG"), (2, "PG-13"), (4, "R"), (8, "X"), (16, "XXX")]

    init(identity: SiteSession.AccountSessionID, level: Int, blur: Bool?) {
        self.identity = identity
        _level = State(initialValue: level)
        _blur = State(initialValue: blur ?? true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                SettingsControlCard("账号浏览范围") {
                    ForEach(levels, id: \.0) { bit, title in
                        if bit != levels.first?.0 { Divider() }
                        Toggle(title, isOn: Binding(get: { level & bit != 0 }, set: { enabled in
                            if enabled { level |= bit } else { level &= ~bit }
                        })).disabled(saving)
                    }
                }
                if session.account?.blurNsfw != nil {
                    SettingsControlCard { Toggle("模糊成熟内容", isOn: $blur).disabled(saving) }
                }
            }
            .font(AppTypography.rowTitle)
            .toggleStyle(CompactSettingsToggleStyle())
            .pageScrollContentInsets()
        }
        .floatingTitleBar("账号内容偏好") {
            Button(action: save) {
                if saving { ProgressView().controlSize(.small) }
                else { FloatingPageIcon(symbol: "checkmark") }
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .disabled(saving || level == 0 || identity != session.accountSessionID)
            .accessibilityLabel(saving ? "正在保存并核对" : "保存到 Civitai")
            .accessibilityIdentifier("account-preferences.save")
        }
    }

    private func save() {
        guard !saving, level != 0, identity == session.accountSessionID else { return }
        let submittedLevel = level
        let submittedBlur = session.account?.blurNsfw == nil ? nil : blur
        saving = true
        Task {
            defer { saving = false }
            await session.saveBrowsingPreferences(level: submittedLevel, blur: submittedBlur, for: identity)
            guard identity == session.accountSessionID, let account = session.account else { return }
            level = account.browsingLevel ?? level
            blur = account.blurNsfw ?? blur
        }
    }
}
