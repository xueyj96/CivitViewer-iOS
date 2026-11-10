import SwiftUI

struct FilterPresetRequest: Identifiable, Hashable {
    let id = UUID()
    let ownerID: Int?
    let identity: String
    let scope: FilterPresetScope
    let snapshot: FilterPresetSnapshot
    @MainActor init(session: SiteSession, scope: FilterPresetScope, filter: FeedFilter, criteria: MediaSearchCriteria? = nil) {
        ownerID = session.tagLibraryOwnerID; identity = session.feedIdentity
        self.scope = scope; snapshot = .init(filter: filter, criteria: criteria)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Every entry shares the same account/session guard, storage and presentation.
struct FilterPresetPage: View {
    let request: FilterPresetRequest
    let onApply: (FilterPresetSnapshot) -> Void
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    private var current: Bool { session.feedIdentity == request.identity && session.tagLibraryOwnerID == request.ownerID }
    var body: some View {
        FilterPresetLibraryView(ownerID: request.ownerID, scope: request.scope, current: request.snapshot,
            onApply: { snapshot in
                guard current else { return }
                onApply(snapshot)
            }, isCurrent: { current })
            .disabled(!current)
            .onChange(of: session.feedIdentity) { _, _ in dismiss() }
    }
}

struct FilterPresetLibraryView: View {
    let ownerID: Int?
    let scope: FilterPresetScope
    let current: FilterPresetSnapshot
    let onApply: (FilterPresetSnapshot) -> Void
    var isCurrent: () -> Bool = { true }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FilterPresetStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presets: [FilterPreset] = []
    @State private var loadError: String?
    @State private var showNameEditor = false
    @State private var editorPreset: FilterPreset?
    @State private var editorName = ""
    @State private var deleteTarget: FilterPreset?
    @State private var operationError: String?
    private var canSave: Bool { (try? current.validated(for: scope)) != nil }

    var body: some View {
        List {
            Group {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前条件").font(.caption).foregroundStyle(.secondary)
                    Text(current.filter.summary).font(.subheadline.weight(.medium))
                    if let criteria = current.criteria, !criteria.summary.isEmpty {
                        Text(criteria.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let loadError {
                    Text(loadError).foregroundStyle(.red).accessibilityIdentifier("preset.library.error")
                } else if presets.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("还没有保存的条件").font(.subheadline.weight(.semibold))
                        Text(canSave ? "用右上角的加号保存当前条件。" : "填写搜索条件后即可保存。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("preset.library.empty")
                } else {
                    ForEach(presets) { preset in
                        Button {
                            guard isCurrent() else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { onApply(preset.snapshot) }
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(preset.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if preset.snapshot.matches(current) { Image(systemName: "checkmark").foregroundStyle(.blue).accessibilityLabel("当前筛选") }
                            }.contentShape(Rectangle()).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain).frame(minHeight: 44)
                        .accessibilityValue(preset.snapshot.matches(current) ? "当前筛选" : "应用方案")
                        .accessibilityIdentifier("preset.library.apply.\(preset.id.uuidString.lowercased())")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { guard isCurrent() else { return }; deleteTarget = preset }.accessibilityIdentifier("preset.library.delete.\(preset.id.uuidString.lowercased())")
                            Button("重命名") { beginRename(preset) }.tint(.blue).accessibilityIdentifier("preset.library.rename.\(preset.id.uuidString.lowercased())")
                        }
                        .contextMenu {
                            Button("重命名") { beginRename(preset) }
                            Button("删除", role: .destructive) { guard isCurrent() else { return }; deleteTarget = preset }
                        }
                    }
                }
                if let operationError { Text(operationError).font(.footnote).foregroundStyle(.red) }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: FloatingPageChrome.pageInset + 12,
                                     bottom: 10, trailing: FloatingPageChrome.pageInset + 12))
            .listRowBackground(
                FloatingPageChrome.controlShape.fill(AppTheme.secondarySurface)
                    .padding(.horizontal, FloatingPageChrome.pageInset)
            )
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .accessibilityIdentifier("preset.library")
        .listRowSpacing(FloatingPageChrome.groupInset)
        .avoidOverlaidTabBar()
        .floatingTitleBar("已存条件 · \(scope.title)", leading: {
            FloatingPageBackButton(identifier: "preset.library.done")
        }) {
            Button { beginSave() } label: { FloatingPageIcon(symbol: "plus") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .disabled(!canSave || !isCurrent())
                .accessibilityLabel("保存当前条件").accessibilityIdentifier("preset.library.save")
        }
        .navigationDestination(isPresented: $showNameEditor) {
            FilterPresetNameView(ownerID: ownerID, scope: scope,
                snapshot: editorPreset?.snapshot ?? current,
                mode: editorPreset.map { .rename($0.id) } ?? .save,
                initialName: editorName, isCurrent: isCurrent) { refresh() }
        }
        .task { refresh() }
        .onChange(of: store.revision) { _, _ in refresh() }
        .alert("删除“\(deleteTarget?.name ?? "")”？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除方案", role: .destructive) { guard isCurrent() else { deleteTarget = nil; return }; if let target = deleteTarget { remove(target) }; deleteTarget = nil }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { Text("只删除这组已存条件。") }
        .ordinaryAppearance()
    }

    private func refresh() {
        do { presets = try store.list(ownerID: ownerID, scope: scope).sorted { $0.updatedAt > $1.updatedAt }; loadError = nil }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? "无法读取已存条件。" }
    }
    private func beginSave() {
        guard isCurrent() else { return }
        editorPreset = nil
        let criteria = current.criteria
        let titlePrefix = criteria?.normalizedText ?? ""
        let subject = titlePrefix.isEmpty
            ? (criteria?.author.map { "@" + $0.username } ?? criteria?.tags.first?.name)
            : titlePrefix
        let fallback = "\(scope.title) · \(current.filter.effectiveKind.title)"
        let base = String((subject ?? fallback).prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        let used = Set(presets.map { $0.name.lowercased() })
        var proposed = base
        for suffix in 2...51 where used.contains(proposed.lowercased()) {
            let ending = " (\(suffix))"
            proposed = String(base.prefix(40 - ending.count)) + ending
        }
        editorName = proposed
        showNameEditor = true
    }
    private func beginRename(_ preset: FilterPreset) {
        guard isCurrent() else { return }
        editorPreset = preset
        editorName = preset.name
        showNameEditor = true
    }
    private func remove(_ preset: FilterPreset) {
        guard isCurrent() else { return }
        do { try store.delete(ownerID: ownerID, scope: scope, id: preset.id); operationError = nil; refresh() }
        catch { operationError = (error as? LocalizedError)?.errorDescription }
    }
}

private struct FilterPresetNameView: View {
    enum Mode { case save, rename(UUID) }
    let ownerID: Int?
    let scope: FilterPresetScope
    let snapshot: FilterPresetSnapshot
    let mode: Mode
    let initialName: String
    let onSaved: () -> Void
    let isCurrent: () -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?

    init(ownerID: Int?, scope: FilterPresetScope, snapshot: FilterPresetSnapshot, mode: Mode, initialName: String = "", isCurrent: @escaping () -> Bool = { true }, onSaved: @escaping () -> Void) {
        self.ownerID = ownerID; self.scope = scope; self.snapshot = snapshot; self.mode = mode; self.initialName = initialName; self.isCurrent = isCurrent; self.onSaved = onSaved
        _name = State(initialValue: initialName)
    }

    private var isRename: Bool { if case .rename = mode { true } else { false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                    HStack {
                        Text("名称").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(name.trimmingCharacters(in: .whitespacesAndNewlines).count) / 40")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    TextField("输入名称", text: $name, prompt: FloatingPageChrome.fieldPrompt("输入名称"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.subheadline).padding(.horizontal, 12)
                        .frame(minHeight: FloatingPageChrome.controlHeight)
                        .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
                        .accessibilityLabel("名称")
                        .accessibilityIdentifier("preset.name.input")
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("preset.name.error")
                    }
                }

                VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                    if let criteria = snapshot.criteria {
                        if !criteria.normalizedText.isEmpty { conditionRow("标题开头", criteria.normalizedText) }
                        if let author = criteria.author { conditionRow("作者", "@\(author.username)") }
                        if !criteria.tags.isEmpty {
                            TagPillLayout(spacing: FloatingPageChrome.groupInset, rowSpacing: 2) {
                                ForEach(criteria.tags) { tag in
                                    WorkTagLabel(title: tag.name, selected: false, compact: true)
                                }
                            }
                            .accessibilityLabel("标签")
                        }
                        Divider()
                    }
                    Text([snapshot.filter.effectiveKind.title, snapshot.filter.sortTitle, snapshot.filter.periodTitle].joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("preset.name.range")
                    if !snapshot.filter.baseModel.isEmpty { conditionRow("模型", snapshot.filter.baseModel) }
                    if snapshot.filter.onlyPG { conditionRow("内容范围", "仅看 PG") }
                    if let duration = snapshot.filter.videoDurationRange { conditionRow("视频时长", duration.summary) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
            }
            .pageScrollContentInsets()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("preset.name")
        .floatingTitleBar(isRename ? "重命名" : "保存条件") {
            Button("保存") { save() }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isCurrent())
                .accessibilityIdentifier("preset.name.save")
        }
        .ordinaryAppearance()
    }

    private func conditionRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save() {
        guard isCurrent() else { error = "账号已切换，请关闭此面板后重试。"; return }
        do {
            switch mode {
            case .save: _ = try FilterPresetStore.shared.save(ownerID: ownerID, scope: scope, name: name, snapshot: snapshot)
            case .rename(let id): _ = try FilterPresetStore.shared.updateName(ownerID: ownerID, scope: scope, id: id, name: name)
            }
            error = nil; onSaved(); dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "无法保存条件。" }
    }
}
