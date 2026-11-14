import SwiftUI
import UIKit

/// The declared rows provide the first layout estimate. The view reports its
/// measured size once its content and safe area are laid out.
struct PageHeaderLayout {
    private let rowCount: Int
    let compactRows: Bool

    static let singleRow = Self(rowCount: 1, compactRows: false)
    static let doubleRow = Self(rowCount: 2, compactRows: false)
    static let tripleRow = Self(rowCount: 3, compactRows: false)

    static func search(accessibility: Bool, includesFilters: Bool) -> Self {
        let rows = includesFilters ? (accessibility ? 6 : 2) : 1
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

/// The live top bar and its pinned copy use exactly the same role palette.
enum HeaderPanelPalette {
    static func fill(overMedia: Bool, scheme: ColorScheme, opaque: Bool) -> Color {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        return overMedia ? .black.opacity(opaque ? 1 : 0.48)
            : Color(uiColor: UIColor.systemBackground.resolvedColor(with: traits))
                .opacity(opaque ? 1 : FloatingPageChrome.ordinaryPanelOpacity)
    }
    static func border(overMedia: Bool, scheme: ColorScheme) -> Color {
        (overMedia || scheme == .dark ? Color.white : .black).opacity(overMedia ? 0.12 : 0.10)
    }
}

struct FloatingPagePanelSurface: View {
    let overMedia: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var body: some View {
        FloatingPageChrome.controlShape
            .fill(HeaderPanelPalette.fill(overMedia: overMedia, scheme: scheme, opaque: opaque))
            .overlay {
                FloatingPageChrome.controlShape.strokeBorder(
                    HeaderPanelPalette.border(overMedia: overMedia, scheme: scheme), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
    }
}

private struct FloatingPageBar<Bar: View>: ViewModifier {
    let identifier: String
    let layout: PageHeaderLayout
    let overMedia: Bool
    let hidden: Bool
    let layoutIdentity: AnyHashable?
    @ViewBuilder let bar: () -> Bar
    @Environment(\.self) private var pageEnvironment
    @EnvironmentObject private var session: SiteSession
    private struct MeasuredInset {
        let surfaceHeight: CGFloat
        let clearance: CGFloat
    }
    @State private var measuredInset: MeasuredInset?
    @State private var nativeHandoff: HeaderHandoff?
    @State private var contentOwner = UUID()
    @State private var contentAtTop = true
    @Environment(\.tabPageMotion) private var tabMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.overlaidTabBarHeight) private var overlap
    @Environment(\.floatingPageSafeInsets) private var safeInsets
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rootPageParticipation) private var participation
    @Environment(\.motionTab) private var tab

    private var ownContentInset: CGFloat {
        guard let measuredInset, abs(measuredInset.surfaceHeight - layout.surfaceHeight) <= 1 else {
            return layout.reservedHeight
        }
        return measuredInset.clearance
    }

    private var controls: some View {
        bar()
            .floatingPagePanelControls(rowHeight: layout.rowHeight, overMedia: overMedia)
            .foregroundStyle(overMedia ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, FloatingPageChrome.groupInset)
            .padding(.vertical, layout.compactRows ? FloatingPageChrome.groupInset / 2 : 0)
    }

    private var motionAppearance: HeaderAppearance {
        return HeaderAppearance(
            controls: AnyView(controls
                .offset(y: layout.compactRows ? 0 : -FloatingPageChrome.surfaceInset)
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(typeSize)),
            firstRowHeight: layout.firstRowHeight,
            colorScheme: overMedia ? .dark : scheme,
            surfaceColor: HeaderPanelPalette.fill(overMedia: overMedia, scheme: scheme, opaque: opaque),
            borderColor: HeaderPanelPalette.border(overMedia: overMedia, scheme: scheme),
            surfaceHeight: layout.surfaceHeight, environment: pageEnvironment, layoutIdentity: layoutIdentity,
            canvasRole: overMedia ? .playback : .ordinary,
            contentClearance: ownContentInset,
            retainsViewport: !contentAtTop,
            contentOwner: contentOwner
        )
    }

    private var contentInset: CGFloat {
        guard !overMedia else { return 0 }
        let ownInset = ownContentInset
        if let tab, let clearance = tabMotion?.contentClearance(for: tab, owner: contentOwner) { return clearance }
        if let clearance = nativeHandoff?.contentClearance(for: contentOwner) { return clearance }
        if participation.role == .prepared || (tab != nil && tabMotion?.preparedTab == tab) { return ownInset }
        guard let handoff = nativeHandoff ?? tabMotion?.handoff else { return ownInset }
        // Covered routes keep their own layout. Only a same-page, top-of-list
        // change lets the live content follow the fixed surface's resize.
        guard handoff.isLayoutChange,
              !(handoff.destination?.appearance.retainsViewport ?? !contentAtTop) else { return ownInset }
        let source = handoff.source.appearance.contentClearance
            ?? handoff.source.frame.height + layout.reservedHeight - layout.surfaceHeight
        guard let destination = handoff.destination else { return source }
        let target = destination.appearance.contentClearance ?? ownInset
        let delta = destination.frame.height - handoff.source.frame.height
        let progress = abs(delta) > 1 ? min(1, max(0, (handoff.height - handoff.source.frame.height) / delta)) : 1
        return source + (target - source) * progress
    }

    func body(content: Content) -> some View {
        let viewportTop = hidden ? 0 : (overMedia ? layout.reservedHeight : contentInset)
        content
            .floatingScrollCanvas()
            .environment(\.floatingPageContentInsets, EdgeInsets(top: safeInsets.top + (hidden ? 0 : contentInset),
                                                               leading: 0, bottom: safeInsets.bottom + overlap, trailing: 0))
            .onPreferenceChange(PageContentAtTopPreference.self) { value in
                if let value, value != contentAtTop { contentAtTop = value }
            }
            .pageBodyViewport(top: viewportTop, bottom: overlap)
            .pageReturnViewport(topInset: viewportTop,
                                bottomInset: overlap, identity: session.accountSessionID,
                                onReturn: { dismiss() })
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        measuredInset = MeasuredInset(surfaceHeight: layout.surfaceHeight, clearance: $0)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(identifier)
                    .viewingChromeHidden(hidden)
                    .padding(.top, safeInsets.top)
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(.container, edges: .vertical)
    }
}

/// Pages report only a threshold crossing, never every scroll offset. A pane
/// that is not participating cannot overwrite the visible pane's declaration.
struct PageContentAtTopPreference: PreferenceKey {
    static var defaultValue: Bool? { nil }
    static func reduce(value: inout Bool?, nextValue: () -> Bool?) {
        if let next = nextValue() { value = next }
    }
}

private struct PageContentViewport: ViewModifier {
    let active: Bool
    let initiallyAtTop: Bool?
    let observes: Bool
    @State private var isAtTop: Bool

    init(active: Bool, initiallyAtTop: Bool?, observes: Bool) {
        self.active = active
        self.initiallyAtTop = initiallyAtTop
        self.observes = observes
        _isAtTop = State(initialValue: initiallyAtTop ?? true)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if !observes {
            content
        } else if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top <= 1
                } action: { _, value in
                    if isAtTop != value { isAtTop = value }
                }
                .preference(key: PageContentAtTopPreference.self, value: active ? isAtTop : nil)
        } else {
            // The iOS 17 fallback retains the existing page layout; callers
            // with an ID-based position may publish the preference themselves.
            content.preference(key: PageContentAtTopPreference.self, value: active ? initiallyAtTop ?? false : nil)
        }
    }
}

extension View {
    func pageContentViewport(active: Bool = true, initiallyAtTop: Bool? = nil, observes: Bool = true) -> some View {
        floatingScrollCanvas().modifier(PageContentViewport(active: active, initiallyAtTop: initiallyAtTop, observes: observes))
    }

    func floatingPageBar<Bar: View>(
        _ identifier: String, layout: PageHeaderLayout = .singleRow, overMedia: Bool = false, hidden: Bool = false,
        layoutIdentity: AnyHashable? = nil,
        @ViewBuilder bar: @escaping () -> Bar
    ) -> some View {
        modifier(FloatingPageBar(identifier: identifier, layout: layout, overMedia: overMedia, hidden: hidden, layoutIdentity: layoutIdentity, bar: bar))
    }
}
