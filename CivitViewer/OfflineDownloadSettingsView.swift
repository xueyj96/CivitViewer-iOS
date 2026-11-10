import SwiftUI

struct OfflineDownloadSettingsView: View {
    @EnvironmentObject private var session: SiteSession
    @AppStorage("offlineAutoSave") private var autoSave = true
    @AppStorage("offlineWifiOnly") private var wifiOnly = true
    @AppStorage("offlineLimitGB") private var limitGB = 10

    private var offline: OfflineLibrary { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                SettingsControlCard("下载方式") {
                    Toggle(isOn: Binding(get: { autoSave }, set: setAutoSave)) {
                        SettingsRowLabel("自动下载收藏", "arrow.down.circle")
                    }
                    .frame(minHeight: FloatingPageChrome.controlHeight)
                    .accessibilityIdentifier("downloads.auto-save")
                    Divider()
                    Toggle(isOn: Binding(get: { wifiOnly }, set: setWiFiOnly)) {
                        SettingsRowLabel("仅 Wi-Fi 下载", "wifi")
                    }
                    .frame(minHeight: FloatingPageChrome.controlHeight)
                    .accessibilityIdentifier("downloads.wifi-only")
                }
                SettingsControlCard("空间") {
                    SettingsChoice(title: "离线空间上限", symbol: "externaldrive",
                                   selection: Binding(get: { limitGB }, set: setLimit),
                                   options: [1, 5, 10, 20, 50], name: { "\($0) GB" })
                        .accessibilityIdentifier("downloads.capacity")
                }
            }
            .pageScrollContentInsets()
        }
        .floatingTitleBar("下载设置")
        .ordinaryAppearance()
    }

    private func setAutoSave(_ enabled: Bool) {
        guard enabled != autoSave else { return }
        autoSave = enabled
        if enabled {
            offline.resumeAll(session: session)
        } else {
            offline.pause(reason: "自动保存已关闭")
        }
    }

    private func setWiFiOnly(_ enabled: Bool) {
        guard enabled != wifiOnly else { return }
        wifiOnly = enabled
        offline.pause()
        if autoSave { offline.requestSync(session: session) }
    }

    private func setLimit(_ value: Int) {
        guard value != limitGB else { return }
        limitGB = value
        if autoSave { offline.requestSync(session: session) }
    }
}
