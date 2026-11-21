import SwiftUI
import UIKit

struct MediaTabExit {
    let id: Int
    let fromMedia: Bool
}

struct MediaTabs {
    let height: CGFloat
    let render: (_ overMedia: Bool, _ identifier: String, _ selection: FavoriteSelectionBar.Entry?, _ onSelect: @escaping (Int) -> Void) -> AnyView
    let select: (MediaTabExit) -> Void
}

extension EnvironmentValues {
    @Entry var mediaTabs: MediaTabs? = nil
    @Entry var exitMediaCoverToTab: ((MediaTabExit) -> Void)? = nil
    @Entry var rotatePlayback: (() -> Void)? = nil
}

enum MediaPresentationSource { case ordinary, playback }

/// Read the presentation resource binding inside a concrete SwiftUI body.
/// The escaping platform factory does not own observation of the source State.
private struct MediaCoverSessionContent<Content: View>: View {
    @Binding var navigation: PlaybackNavigationOwner
    let token: UUID
    let mayClose: () -> Bool
    let rotate: () -> Void
    let exit: ((MediaTabExit) -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let owner = navigation
        if owner.session == token, !owner.finished {
            content()
                .environment(\.playbackNavigationOwner, owner)
                .environment(\.rotatePlayback, {
                    guard !owner.finished, owner.session == token, mayClose() else { return }
                    rotate()
                })
                .environment(\.exitMediaCoverToTab, exit.map { action in { destination in
                    guard !owner.finished, owner.session == token, mayClose() else { return }
                    action(destination)
                } })
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

private struct MediaCover<Item: Identifiable, Presented: View>: ViewModifier {
    @Binding var item: Item?
    var onDismiss: () -> Void
    let source: MediaPresentationSource
    @ViewBuilder var presented: (Item) -> Presented
    @Environment(\.mediaTabs) private var tabs
    @Environment(\.exitMediaCoverToTab) private var parentExit
    @Environment(\.ordinaryColorScheme) private var ordinaryScheme
    @State private var route = NativeHeaderRoute()
    @State private var playbackOrientation = PlaybackOrientationSession()
    @State private var exitsToTab = false
    @State private var navigation = PlaybackNavigationOwner()

    func body(content: Content) -> some View {
        content.pagePresentation(item: $item, route: route, destinationRole: .playback, sourceRole: source == .playback ? .playback : .ordinary, animateDismissal: !exitsToTab, onBegin: { _, token in
            navigation = PlaybackNavigationOwner(session: token)
        }, onEnd: { _, token in
            navigation.finish(token)
            if let restore = playbackOrientation.takeRestoreAction() {
                if !PageCoverExitEffects.deferUntilFinished(scope: token, action: restore) { restore() }
            }
            exitsToTab = false
            onDismiss()
        }) { opening, token, mayClose in
            MediaCoverSessionContent(navigation: $navigation, token: token, mayClose: mayClose,
                rotate: { playbackOrientation.rotate() }, exit: tabs.map { _ in { destination in
                    guard item != nil else { return }
                    withoutPageAnimation {
                        exitsToTab = true
                        item = nil
                        (parentExit ?? tabs?.select)?(destination)
                    }
                } }) { presented(opening) }
        }
        .transaction {
            // A native pager hosts its media page in a separate SwiftUI root.
            // Keep the exit policy attached until that cover has dismissed.
            if exitsToTab, item == nil {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }
}

extension View {
    func mediaCover<Item: Identifiable, Presented: View>(
        item: Binding<Item?>, source: MediaPresentationSource = .ordinary, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> Presented
    ) -> some View {
        modifier(MediaCover(item: item, onDismiss: onDismiss, source: source, presented: content))
    }
}
