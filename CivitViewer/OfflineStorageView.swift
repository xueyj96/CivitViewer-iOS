import SwiftUI

/// Capacity and cleanup only. Collection cards own download/playback state.
struct OfflineStorageView: View {
    var embedded = false
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var library = OfflineLibrary.shared
    @State private var confirmClean = false
    @State private var confirmAll = false
    @State private var confirmationBinding: UUID?
    @State private var cleanupRequested = false
    @State private var spaceNotice: String?
    private var storageFraction: Double {
        min(1, max(0, Double(library.diskBytes) / Double(max(1, library.capacity))))
    }
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                SettingsControlCard {
                    VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("已用 " + (library.diskUsageKnown ? AppTheme.storageSize(library.diskBytes) : "暂不可统计"))
                                .font(.headline.monospacedDigit())
                            Spacer(minLength: FloatingPageChrome.spacing)
                            Text("上限 " + AppTheme.storageSize(library.capacity))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if library.diskUsageKnown {
                            ProgressView(value: storageFraction).tint(.blue)
                                .accessibilityLabel("离线文件空间占用")
                        }
                    }.padding(.vertical, FloatingPageChrome.spacing)
                }
                SettingsControlCard("清理空间") {
                    Button {
                        confirmationBinding = library.bindingID; confirmClean = true
                    } label: { SettingsRowLabel("清理已取消收藏的文件", "trash") }
                        .disabled(library.busy || !session.hasCollectionAccess)
                        .accessibilityIdentifier("offline.storage.clean-unfavorited")
                    Divider()
                    Button(role: .destructive) {
                        confirmationBinding = library.bindingID; confirmAll = true
                    } label: { SettingsRowLabel("删除全部本地文件", "trash") }
                        .disabled(library.busy || library.readyCount == 0)
                        .accessibilityIdentifier("offline.storage.clear-all")
                }
                if library.busy {
                    Text(cleanupRequested ? "正在清理空间" : "当前任务完成或暂停后可清理")
                        .font(AppTypography.supportingText).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.pageScrollContentInsets()
        }
    }
    @ViewBuilder private var presentation: some View {
        if embedded {
            content
        } else {
            content.floatingTitleBar("空间管理") {
                NavigationLink { OfflineDownloadSettingsView() } label: { FloatingPageIcon(symbol: "gearshape") }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .accessibilityLabel("下载设置")
            }
            .ordinaryAppearance()
        }
    }
    var body: some View {
        presentation
        .existingFeedbackToast(spaceNotice, id: spaceNotice, scope: library.bindingID)
        .onChange(of: library.bindingID) { _, _ in
            confirmClean = false; confirmAll = false; confirmationBinding = nil
            cleanupRequested = false; spaceNotice = nil
        }
        .onChange(of: library.busy) { _, busy in
            if cleanupRequested && !busy { spaceNotice = library.queueNotice; cleanupRequested = false }
        }
        .appConfirmationDialog("清理已取消收藏的文件？", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("核对并清理", role: .destructive) {
                guard confirmationBinding == library.bindingID else { return }
                runCleanup { library.cleanUnfavorited(session: session) }
            }
        } message: { Text("只删除已确认不在云端收藏中的本地文件。") }
        .appConfirmationDialog("删除全部本地文件？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("删除本地文件", role: .destructive) {
                guard confirmationBinding == library.bindingID else { return }
                runCleanup { library.clearAll() }
            }
        } message: { Text("云端收藏保留。再次打开作品时会重新下载。") }
    }
    private func runCleanup(_ operation: () -> Void) {
        cleanupRequested = true; spaceNotice = nil
        operation()
        if !library.busy { cleanupRequested = false; spaceNotice = library.queueNotice }
    }
}
