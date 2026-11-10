import SwiftUI
import UIKit

@MainActor
@Observable
final class TabPageMotion {
    @ObservationIgnored private var anchors: [Int: [WeakHeaderProbe]] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var railEntry: Task<Void, Never>?
    private(set) var handoff: HeaderHandoff?
    private(set) var holdsInlineRail = false
    @ObservationIgnored private var preparingInlineExit = false

    func register(_ probe: NativeHeaderProbe, tab: Int) {
        var entries = (anchors[tab] ?? []).filter { $0.probe != nil }
        if !entries.contains(where: { $0.probe === probe }) {
            entries.append(WeakHeaderProbe(probe: probe))
        }
        anchors[tab] = entries
    }

    func switchPage(from source: Int, to destination: Int,
                    leavesInlinePlayback: Bool, select: @escaping () -> Void) {
        cancel()
        pending = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if leavesInlinePlayback {
                // The native tab removes its player in one update. Fade the
                // actual controls while that player is still on screen.
                preparingInlineExit = true
                ViewingChromeController.shared.prepareRailDeparture()
                try? await Task.sleep(for: .seconds(playbackRailFadeDuration))
                guard !Task.isCancelled else { return }
                preparingInlineExit = false
            }
            takeHeaderOwnership(from: source)
            if let outgoing = header(for: source) {
                handoff = HeaderHandoff(source: outgoing)
            }
            holdsInlineRail = destination == 0
            withoutPageAnimation(select)
            if holdsInlineRail {
                railEntry = Task { [weak self] in
                    // Start after the incoming player is visible, so the
                    // first part of the fade isn't lost behind its canvas.
                    try? await Task.sleep(for: .milliseconds(24))
                    guard !Task.isCancelled else { return }
                    self?.holdsInlineRail = false
                }
            }

            // Give the native tab a frame to attach its incoming header.
            try? await Task.sleep(for: .milliseconds(24))
            guard !Task.isCancelled else { return }
            guard let activeHandoff = handoff else { return }
            for _ in 0..<8 {
                if let incoming = header(for: destination) {
                    await activeHandoff.replace(with: incoming) { !Task.isCancelled && self.handoff === activeHandoff }
                    guard !Task.isCancelled else { return }
                    break
                }
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
            }
            withoutPageAnimation { handoff = nil }
        }
    }

    func takeHeaderOwnership(from tab: Int) {
        guard let window = anchors[tab]?.compactMap({ $0.probe?.viewIfLoaded?.window }).first else { return }
        NativeHeaderMotion.forWindow(window).yieldToTabSwitch()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        railEntry?.cancel()
        railEntry = nil
        if preparingInlineExit {
            ViewingChromeController.shared.cancelRailDeparture()
            preparingInlineExit = false
        }
        withoutPageAnimation {
            handoff = nil
            holdsInlineRail = false
        }
    }

    private func header(for tab: Int) -> HeaderContent? {
        anchors[tab]?.reversed().compactMap {
            guard let probe = $0.probe, probe.showsChrome else { return nil }
            return probe.currentHeader
        }.first
    }
}

@MainActor
final class HeaderAnchor: UIView {
    var appearance: HeaderAppearance?

    var visibleFrame: CGRect? {
        guard let window, !bounds.isEmpty else { return nil }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return nil }
            view = current.superview
        }
        let frame = convert(bounds, to: window)
        return window.bounds.insetBy(dx: -24, dy: 0).contains(frame) ? frame : nil
    }
}

private struct WeakHeaderProbe {
    weak var probe: NativeHeaderProbe?
}

private struct HeaderProbe: UIViewControllerRepresentable {
    let motion: TabPageMotion?
    let tab: Int?
    let appearance: HeaderAppearance
    let nativeMotionEnabled: Bool
    let showsChrome: Bool
    @Environment(\.nativeHeaderRouteID) private var routeID
    let onHandoffChange: (HeaderHandoff?) -> Void

    func makeUIViewController(context: Context) -> NativeHeaderProbe { NativeHeaderProbe() }

    func updateUIViewController(_ controller: NativeHeaderProbe, context: Context) {
        controller.anchor.appearance = appearance
        controller.nativeMotionEnabled = nativeMotionEnabled
        controller.showsChrome = showsChrome
        controller.routeID = routeID
        controller.onHandoffChange = onHandoffChange
        if let motion, let tab { motion.register(controller, tab: tab) }
    }
}

extension EnvironmentValues {
    @Entry var tabPageMotion: TabPageMotion? = nil
    @Entry var motionTab: Int? = nil
}

private struct TabHeaderSurfaceRegistration: ViewModifier {
    let appearance: HeaderAppearance
    let verticalInset: CGFloat
    let enabled: Bool
    let participatesInTabs: Bool
    var onNativeHandoff: (HeaderHandoff?) -> Void
    @State private var nativeHandoff: HeaderHandoff?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabPageMotion) private var motion
    @Environment(\.motionTab) private var tab

    func body(content: Content) -> some View {
        let hidden = nativeHandoff != nil || (enabled && participatesInTabs && motion?.handoff != nil)
        content
            .opacity(hidden ? 0 : 1)
            .animation(nil, value: hidden)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .background {
                HeaderProbe(motion: enabled && participatesInTabs ? motion : nil, tab: tab, appearance: appearance,
                            nativeMotionEnabled: !reduceMotion && motion?.handoff == nil, showsChrome: enabled,
                            onHandoffChange: {
                                nativeHandoff = $0
                                onNativeHandoff($0)
                            })
                    .padding(.vertical, verticalInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func tabHeaderSurface(_ appearance: HeaderAppearance, verticalInset: CGFloat,
                          enabled: Bool = true, participatesInTabs: Bool = true,
                          onNativeHandoff: @escaping (HeaderHandoff?) -> Void = { _ in }) -> some View {
        modifier(TabHeaderSurfaceRegistration(appearance: appearance, verticalInset: verticalInset,
                                              enabled: enabled, participatesInTabs: participatesInTabs,
                                              onNativeHandoff: onNativeHandoff))
    }
}
