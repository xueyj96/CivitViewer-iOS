import SwiftUI

struct LocalTagLibraryView: View {
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var library = LocalTagLibrary.shared
    @AppStorage("tagLibraryAuto") private var automatic = true
    @AppStorage("tagLibraryWiFi") private var wifiOnly = true
    @State private var confirmReset = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                SettingsControlCard("当前账号") {
                    statusRow("可浏览标签", "\(library.stats.visible) 个")
                    Divider()
                    statusRow("已存元数据", "\(library.stats.stored) 项")
                    Divider()
                    statusRow("字母／数字进度", "\(library.stats.completedPrefixes) / 36")
                    Divider()
                    statusRow("独立占用", AppTheme.storageSize(library.stats.bytes) + " / 128 MiB")
                }

                SettingsControlCard("同步") {
                    Toggle("自动分批同步", isOn: $automatic).frame(minHeight: FloatingPageChrome.controlHeight)
                    Divider()
                    Toggle("仅在 Wi-Fi 下同步", isOn: $wifiOnly).frame(minHeight: FloatingPageChrome.controlHeight)
                    Divider()
                    HStack {
                        if library.busy { ProgressView().controlSize(.small) }
                        Text(library.status).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: FloatingPageChrome.controlHeight, alignment: .leading)
                    if let date = library.stats.lastSuccessfulSync {
                        LabeledContent("上次写入") { Text(date, style: .relative) }
                            .frame(minHeight: FloatingPageChrome.controlHeight)
                    }
                    if let error = library.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    Button(library.busy ? "暂停同步" : "同步下一批") {
                        if library.busy { library.pause(userInitiated: true) }
                        else { library.requestSync(source: session, manual: true) }
                    }
                    .frame(minHeight: FloatingPageChrome.controlHeight)
                }

                SettingsControlCard {
                    Button("清空当前标签库", role: .destructive) { confirmReset = true }
                        .frame(minHeight: FloatingPageChrome.controlHeight)
                }
            }
            .pageScrollContentInsets()
        }.floatingTitleBar("本地标签库").ordinaryAppearance()
            .onChange(of: automatic) { _, value in if !value { library.pause(reason: "自动同步已关闭") } }
            .onChange(of: wifiOnly) { _, _ in library.pause(reason: "同步网络设置已更新") }
            .confirmationDialog("清空当前账号的标签库？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空标签索引", role: .destructive) { Task { await library.reset(ownerID: session.tagLibraryOwnerID) } }
            } message: { Text("之后可以重新同步。收藏、屏蔽规则和媒体文件保持原样。") }
    }
    private func statusRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).frame(minHeight: FloatingPageChrome.controlHeight)
    }

}
