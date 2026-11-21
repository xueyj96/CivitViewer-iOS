import SwiftUI

struct FollowButton: View {
    let creator: Creator
    var onSignIn: (() -> Void)? = nil
    var mediaItemID: Int? = nil
    @Environment(\.requestSignIn) private var requestSignIn
    @EnvironmentObject private var session: SiteSession
    private var following: Bool { session.following.contains(creator.id) }

    var body: some View {
        Button {
            if session.account == nil {
                if let onSignIn { onSignIn() }
                else if let requestSignIn { requestSignIn(false) }
                else { session.openLogin() }
            } else { Task { await session.setFollowing(!following, creator: creator) } }
        } label: {
            ZStack {
                Label("待确认", systemImage: "arrow.clockwise").hidden().accessibilityHidden(true)
                Label("已关注", systemImage: "checkmark").hidden().accessibilityHidden(true)
                followLabel
            }
        }
        .buttonStyle(FollowButtonStyle(following: following, overMedia: mediaItemID != nil))
        .disabled(!session.pendingUsers.isEmpty || session.account?.id == creator.id)
        .accessibilityLabel(session.unknownUsers.contains(creator.id) ? "关注结果待确认" : (following ? "已关注" : "关注"))
        .accessibilityIdentifier(mediaItemID.map { "media.follow.\($0)" } ?? "follow-\(creator.id)")
    }

    @ViewBuilder private var followLabel: some View {
        if session.pendingUsers.contains(creator.id) { ProgressView().controlSize(.small) }
        else if session.unknownUsers.contains(creator.id) { Label("待确认", systemImage: "arrow.clockwise") }
        else { Label(following ? "已关注" : "关注", systemImage: following ? "checkmark" : "plus") }
    }
}

private struct FollowButtonStyle: ButtonStyle {
    let following: Bool
    let overMedia: Bool
    @Environment(\.isEnabled) private var enabled

    private var ink: Color { overMedia ? .white : (following ? .secondary : .accentColor) }
    private var fill: Color { overMedia ? .black.opacity(0.55) : Color.primary.opacity(0.065) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold)).lineLimit(1)
            .foregroundStyle(ink).tint(ink)
            .padding(.horizontal, FloatingPageChrome.spacing)
            .padding(.vertical, FloatingPageChrome.groupInset)
            .background(fill, in: FloatingPageChrome.surfaceShape(nested: true))
            .frame(minWidth: FloatingPageChrome.controlHeight, minHeight: FloatingPageChrome.controlHeight)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.55)
    }
}
