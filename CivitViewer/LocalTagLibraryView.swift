import SwiftUI

struct LocalTagLibraryView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var library = LocalTagLibrary.shared
    @AppStorage("tagLibraryAuto") private var automatic = true
    @AppStorage("tagLibraryWiFi") private var wifiOnly = true
    @State private var confirmReset = false
    private var isErrorStatus: Bool {
        ["同步暂时中断", "标签库无法打开", "标签库无法读取"].contains(library.status)
    }
    private var errorFeedback: String? {
        guard library.error != nil else { return nil }
        let retryHint = "稍后自动重试，已下载的标签可继续搜索。"
        return isErrorStatus ? "\(library.status) · \(retryHint)" : retryHint
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                SettingsControlCard("当前账号") {
                    statusRow("已下载标签", library.stats.visible.formatted())
                    Divider()
                    statusRow("占用空间", AppTheme.storageSize(library.stats.bytes))
                }

                SettingsControlCard("同步设置") {
                    Toggle("自动更新", isOn: $automatic).frame(minHeight: FloatingPageChrome.controlHeight)
                    Divider()
                    Toggle("仅限 Wi-Fi", isOn: $wifiOnly).frame(minHeight: FloatingPageChrome.controlHeight)
                    Divider()
                    HStack {
                        if library.busy { ProgressView().controlSize(.small) }
                        if !(library.error != nil && isErrorStatus) {
                            Text(library.status).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: FloatingPageChrome.controlHeight, alignment: .leading)
                }
            }
            .pageScrollContentInsets()
        }.floatingTitleBar("本地标签库") {
            AppMenu {
                if library.busy {
                    Button("暂停同步", systemImage: "pause") { library.pause(userInitiated: true) }
                        .accessibilityIdentifier("tag-library.pause")
                } else {
                    Button(library.error == nil ? "同步下一批" : "重试同步", systemImage: "arrow.clockwise") {
                        library.requestSync(source: session, manual: true)
                    }
                    .accessibilityIdentifier("tag-library.sync")
                }
                Button("清空当前标签库", systemImage: "trash", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("tag-library.clear")
            } label: {
                FloatingPageIcon(symbol: "ellipsis")
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .accessibilityLabel("本地标签库操作")
            .accessibilityIdentifier("tag-library.actions")
        }.ordinaryAppearance()
            .onChange(of: automatic) { _, value in if !value { library.pause(reason: "自动同步已关闭") } }
            .onChange(of: wifiOnly) { _, _ in library.pause(reason: "同步网络设置已更新") }
            .appConfirmationDialog("清空当前账号的标签库？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空标签索引", role: .destructive) { Task { await library.reset(ownerID: session.tagLibraryOwnerID) } }
            } message: { Text("之后可以重新同步。收藏、屏蔽规则和媒体文件保持原样。") }
            .existingFeedbackToast(errorFeedback, id: "local-tag-library-error", scope: session.feedIdentity)
    }
    private func statusRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).frame(minHeight: FloatingPageChrome.controlHeight)
    }

}
