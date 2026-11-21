import SwiftUI

struct LoginView: View {
    var forCollections: Bool? = nil
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var oauth: OAuthLogin
    private var collectionLogin: Bool { forCollections ?? session.loginForCollections }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                    PageContentCard {
                        VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                            Text("在系统浏览器选择 Google，完成 Civitai 授权后会自动返回。")
                            if collectionLogin {
                                Text("收藏授权用于查看、保存和移除收藏作品。")
                            }
                        }
                        .font(.subheadline)
                        .padding(.vertical, FloatingPageChrome.cardInset)
                    }
                    Button {
                        Task { await oauth.start(includeCollections: collectionLogin) }
                    } label: {
                        HStack(spacing: FloatingPageChrome.groupInset) {
                            if oauth.busy { ProgressView().controlSize(.small) }
                            Text(oauth.busy ? "等待授权…" : (collectionLogin ? "前往 Civitai 授权" : "使用 Google 登录"))
                        }
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .accent))
                    .disabled(oauth.busy)
                    Text("Google 密码和验证码只在官方页面输入。登录凭据保存在本机 Keychain。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, FloatingPageChrome.cardInset)
                }
                .padding(.horizontal, FloatingPageChrome.pageInset)
                .padding(.bottom, FloatingPageChrome.pageInset)
            }
            .floatingTitleBar(collectionLogin ? "启用账号收藏" : "账号登录", leading: {
                Button {
                    if let onClose { onClose() } else { session.showLogin = false }
                } label: { FloatingPageIcon(symbol: "xmark") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("关闭")
            }, actions: { EmptyView() })
            .pageReturnAction(enabled: !oauth.busy) {
                guard !oauth.busy else { return false }
                if let onClose { onClose() } else { session.showLogin = false }
                return true
            }
                .fullScreenCover(item: $oauth.browserPage) { page in
                    SystemAuthBrowser(url: page.url) { oauth.cancel() }.ignoresSafeArea()
                }
        }
        .onChange(of: session.accountSessionID) { _, _ in
            if session.account != nil, !collectionLogin || session.hasCollectionAccess { onClose?() }
        }
        .ordinaryPresentationAppearance()
        .existingFeedbackToast(oauth.error, scope: session.feedIdentity)
    }
}
