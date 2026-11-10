import SwiftUI
import UIKit

/// The declared rows provide the first layout estimate. The view reports its
/// measured size once its content and safe area are laid out.
struct PageHeaderLayout {
    private let rowCount: Int
    let compactRows: Bool

    static let singleRow = Self(rowCount: 1, compactRows: false)

    static func search(accessibility: Bool, includesFilters: Bool) -> Self {
        let rows = includesFilters ? (accessibility ? 5 : 2) : 1
        return Self(rowCount: rows, compactRows: !accessibility)
    }

    var rowHeight: CGFloat {
        compactRows ? FloatingPageChrome.compactRowHeight : FloatingPageChrome.controlHeight
    }

    var firstRowHeight: CGFloat {
        if rowCount == 1 { return surfaceHeight }
        return compactRows ? rowHeight + FloatingPageChrome.groupInset / 2 : rowHeight - FloatingPageChrome.surfaceInset
    }

    var surfaceHeight: CGFloat {
        CGFloat(rowCount) * rowHeight
            + (compactRows ? FloatingPageChrome.groupInset : -2 * FloatingPageChrome.surfaceInset)
    }

    var reservedHeight: CGFloat {
        surfaceHeight + 2 * FloatingPageChrome.surfaceInset
            + FloatingPageChrome.topInset + FloatingPageChrome.bottomInset
    }
}

struct FloatingPagePanelSurface: View {
    let overMedia: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if overMedia { PlaybackChromeSurface() }
        else {
            let shape = FloatingPageChrome.controlShape
            shape.fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(reduceTransparency ? 1 : 0.90))
                .overlay { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5) }
                .allowsHitTesting(false)
        }
    }
}

private struct FloatingPageBar<Bar: View>: ViewModifier {
    let identifier: String
    let layout: PageHeaderLayout
    let overMedia: Bool
    let hidden: Bool
    @ViewBuilder let bar: () -> Bar
    @State private var measuredInset: CGFloat?
    @State private var nativeHandoff: HeaderHandoff?
    @Environment(\.tabPageMotion) private var tabMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var controls: some View {
        bar()
            .floatingPagePanelControls(rowHeight: layout.rowHeight, overMedia: overMedia)
            .foregroundStyle(overMedia ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, FloatingPageChrome.groupInset)
            .padding(.vertical, layout.compactRows ? FloatingPageChrome.groupInset / 2 : 0)
    }

    private var motionAppearance: HeaderAppearance {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        return HeaderAppearance(
            controls: AnyView(controls
                .offset(y: layout.compactRows ? 0 : -FloatingPageChrome.surfaceInset)
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(typeSize)),
            firstRowHeight: layout.firstRowHeight,
            colorScheme: overMedia ? .dark : scheme,
            surfaceColor: overMedia ? .black : Color(uiColor: UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits)),
            borderColor: overMedia ? PlaybackChrome.panelStroke : (scheme == .dark ? Color.white : Color.black).opacity(0.10)
        )
    }

    private var contentInset: CGFloat {
        guard !overMedia else { return 0 }
        let ownInset = measuredInset ?? layout.reservedHeight
        guard let handoff = nativeHandoff ?? tabMotion?.handoff else { return ownInset }
        let outerInsets = layout.reservedHeight - layout.surfaceHeight
        return max(ownInset, handoff.height + outerInsets)
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: contentInset).allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                controls
                    .background {
                        FloatingPagePanelSurface(overMedia: overMedia)
                            .padding(.vertical, layout.compactRows ? 0 : FloatingPageChrome.surfaceInset)
                            .allowsHitTesting(false)
                    }
                    .tabHeaderSurface(motionAppearance, verticalInset: layout.compactRows ? 0 : FloatingPageChrome.surfaceInset,
                                      enabled: !hidden, participatesInTabs: !overMedia,
                                      onNativeHandoff: { nativeHandoff = $0 })
                    .padding(.horizontal, FloatingPageChrome.pageInset)
                    .padding(.top, FloatingPageChrome.topInset + (layout.compactRows ? FloatingPageChrome.surfaceInset : 0))
                    .padding(.bottom, FloatingPageChrome.bottomInset + (layout.compactRows ? FloatingPageChrome.surfaceInset : 0))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredInset = $0 }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(identifier)
                    .viewingChromeHidden(hidden)
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
    }
}

extension View {
    func floatingPageBar<Bar: View>(
        _ identifier: String, layout: PageHeaderLayout = .singleRow, overMedia: Bool = false, hidden: Bool = false,
        @ViewBuilder bar: @escaping () -> Bar
    ) -> some View {
        modifier(FloatingPageBar(identifier: identifier, layout: layout, overMedia: overMedia, hidden: hidden, bar: bar))
    }
}
