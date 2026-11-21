import SwiftUI

struct OfflineDownloadSettingsView: View {
    @EnvironmentObject private var session: SiteSession
    @AppStorage("offlineWifiOnly") private var wifiOnly = true
    @AppStorage("offlineLimitGB") private var limitGB = 10

    private var offline: OfflineLibrary { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                SettingsControlCard("下载方式") {
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
        .floatingTitleBar("下载设置") {
            Button(action: restoreDefaults) { FloatingPageIcon(symbol: "arrow.counterclockwise") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .disabled(wifiOnly && limitGB == 10)
                .accessibilityLabel("恢复默认")
                .accessibilityIdentifier("downloads.reset")
        }
        .ordinaryAppearance()
    }

    private func restoreDefaults() {
        guard !wifiOnly || limitGB != 10 else { return }
        let networkChanged = !wifiOnly
        wifiOnly = true
        limitGB = 10
        if networkChanged { offline.pause() }
        offline.requestSync(session: session)
    }

    private func setWiFiOnly(_ enabled: Bool) {
        guard enabled != wifiOnly else { return }
        wifiOnly = enabled
        offline.pause()
        offline.requestSync(session: session)
    }

    private func setLimit(_ value: Int) {
        guard value != limitGB else { return }
        limitGB = value
        offline.requestSync(session: session)
    }
}
