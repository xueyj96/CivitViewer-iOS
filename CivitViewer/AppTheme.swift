import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum AppTheme {
    static let appearanceKey = "app.appearance"
    static let spacing: CGFloat = 16
    static let secondarySurface = Color(uiColor: .secondarySystemBackground)

    static func selectionFill(for scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.20 : 0.10)
    }

    static func storageSize(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func pageBackground(for scheme: ColorScheme) -> Color {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        return Color(uiColor: UIColor.systemBackground.resolvedColor(with: traits))
    }
}

/// Content roles; navigation geometry remains owned by FloatingPageChrome.
enum ContentMetrics {
    enum Tag {
        static let minimumFaceHeight: CGFloat = 26
        static let targetHeight: CGFloat = 32
        static let horizontalInset: CGFloat = 8
        static let verticalInset: CGFloat = 4
        static let gap = FloatingPageChrome.groupInset
    }
    enum Card {
        static let rowVerticalInset = FloatingPageChrome.groupInset
        static let summaryInset = FloatingPageChrome.cardInset
    }
    enum Choice {
        static let width: CGFloat = 240
        static let visibleRows = 6
        static let motionDuration: TimeInterval = 0.2
    }
    enum Preview {
        static let width: CGFloat = 60
        static let height: CGFloat = 80
    }
    enum Icon {
        static let primary: CGFloat = 16
    }
    enum Action {
        static let faceHeight: CGFloat = 32
    }
    enum Media {
        static let trackHeight: CGFloat = 3
        static let statusHeight: CGFloat = 26
    }
    enum Optical {
        static let iconTextGap: CGFloat = 2
        static let hairline: CGFloat = 0.5
    }
}

enum AppTypography {
    static let controlLabel = Font.footnote.weight(.medium)
    static let rowTitle = Font.subheadline
    static let supportingText = Font.caption
    static let tag = Font.caption
    static let tabLabel = Font.caption2
    static let statistics = Font.system(size: 29, weight: .semibold, design: .rounded)
}

/// Small, flat controls share a 44-point hit area across sheets and lists.
/// The fill stays quieter than the selected state or primary content.
struct AppActionButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, destructive }
    var tone: Tone = .neutral
    var circular = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ink: Color {
        switch tone { case .neutral: .primary; case .accent: .blue; case .destructive: .red }
    }
    private var fill: Color {
        switch tone {
        case .neutral: scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.05)
        case .accent: AppTheme.selectionFill(for: scheme)
        case .destructive: .red.opacity(scheme == .dark ? 0.18 : 0.09)
        }
    }
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ink)
        return Group {
            if circular {
                label.frame(width: ContentMetrics.Action.faceHeight, height: ContentMetrics.Action.faceHeight).background(fill, in: Circle())
            } else {
                label.padding(.horizontal, FloatingPageChrome.spacing).frame(minHeight: ContentMetrics.Action.faceHeight)
                    .background(fill, in: FloatingPageChrome.controlShape)
            }
        }
        .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StatusReloadButton: View {
    var title: LocalizedStringKey = "重试"
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: "arrow.clockwise", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(AppActionButtonStyle(circular: true))
            .accessibilityLabel(Text(title))
    }
}

/// A filter can be scanned before opening the menu; the chevron is deliberate.
struct AppFilterLabel: View {
    let title: String
    let symbol: String
    @Environment(\.valueSelectorExpanded) private var expanded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: FloatingPageChrome.spacing) {
            Image(systemName: symbol).font(.system(size: ContentMetrics.Icon.primary, weight: .medium))
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .foregroundStyle(expanded ? Color.accentColor : Color.primary)
        .animation(reduceMotion ? nil : .easeInOut(duration: ContentMetrics.Choice.motionDuration), value: expanded)
    }
}

enum PlaybackChrome {
    static let horizontalInset = FloatingPageChrome.pageInset
    static let panelFill = Color.black.opacity(0.48)
    static let panelStroke = Color.white.opacity(0.12)
    // Keep the rail centered below the trailing button inside the top panel.
    static let railHitInset = horizontalInset + FloatingPageChrome.groupInset
}

/// Shared visible surface for the main tab bar and its standalone batch fallback.
struct FloatingBottomBarSurface: View {
    var overMedia = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if overMedia { PlaybackChromeSurface() }
            else {
                let shape = FloatingPageChrome.controlShape
                shape.fill(Color(uiColor: .systemBackground).opacity(reduceTransparency ? 1 : FloatingPageChrome.ordinaryPanelOpacity))
                    .overlay { shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: ContentMetrics.Optical.hairline) }
            }
        }
        .frame(height: FloatingPageChrome.surfaceHeight)
        .allowsHitTesting(false)
    }
}

struct PlaybackChromeSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = FloatingPageChrome.controlShape
        shape.fill(reduceTransparency ? Color.black : PlaybackChrome.panelFill)
            .overlay { shape.strokeBorder(PlaybackChrome.panelStroke, lineWidth: 0.5) }
            .allowsHitTesting(false)
    }
}

enum FloatingPageChrome {
    private static let unit: CGFloat = 4
    static let pageInset = AppTheme.spacing
    static let ordinaryPanelOpacity: Double = 0.86
    static let cardInset: CGFloat = 12
    static let spacing = 2 * unit
    static let controlHeight = 11 * unit
    static let surfaceInset = unit
    static let surfaceHeight = controlHeight - 2 * surfaceInset
    static let iconSurfaceWidth = surfaceHeight
    static let iconGlyphSize = ContentMetrics.Icon.primary
    static let topInset = unit
    static let bottomInset: CGFloat = 6
    static let segmentInset = unit
    static let groupInset = unit
    static let compactRowHeight = surfaceHeight - groupInset
    static let controlRadius = 2 * unit
    static let controlShape = RoundedRectangle(cornerRadius: controlRadius, style: .circular)
    static let controlFont = AppTypography.controlLabel
    static let filterSymbol = "line.3.horizontal.decrease"

    static func surfaceShape(nested: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: controlRadius - (nested ? groupInset : 0), style: .circular)
    }

    static func visibleHeight(nested: Bool) -> CGFloat {
        surfaceHeight - (nested ? 2 * groupInset : 0)
    }

    static func fieldPrompt(_ title: String) -> Text {
        Text(title).foregroundStyle(Color(uiColor: .secondaryLabel))
    }

    static func equalColumns(_ count: Int, gap: CGFloat = spacing) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: gap), count: count)
    }

    static func columnWidth(in width: CGFloat, count: Int, gap: CGFloat = spacing) -> CGFloat {
        max(0, (width - CGFloat(count - 1) * gap) / CGFloat(count))
    }
}

private struct FloatingPageRowHeightKey: EnvironmentKey {
    static let defaultValue = FloatingPageChrome.controlHeight
}

private struct InsideFloatingPagePanelKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InsidePlaybackPanelKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var insidePlaybackPanel: Bool {
        get { self[InsidePlaybackPanelKey.self] }
        set { self[InsidePlaybackPanelKey.self] = newValue }
    }

    var floatingPageRowHeight: CGFloat {
        get { self[FloatingPageRowHeightKey.self] }
        set { self[FloatingPageRowHeightKey.self] = newValue }
    }

    var insideFloatingPagePanel: Bool {
        get { self[InsideFloatingPagePanelKey.self] }
        set { self[InsideFloatingPagePanelKey.self] = newValue }
    }
}

struct FloatingPageFieldSurface: View {
    @Environment(\.insideFloatingPagePanel) private var nested
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = FloatingPageChrome.surfaceShape(nested: nested)
        shape.fill(nested ? Color.primary.opacity(0.035) : Color(uiColor: .systemBackground).opacity(reduceTransparency ? 1 : 0.90))
            .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
            .frame(height: FloatingPageChrome.visibleHeight(nested: nested))
    }
}

struct FloatingPageIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol).font(.system(size: FloatingPageChrome.iconGlyphSize, weight: .medium))
    }
}

struct FloatingPageButtonStyle: ButtonStyle {
    var selected = false
    var iconOnly = false
    var overMedia = false
    var usesPlaybackWidth = false
    @Environment(\.insidePlaybackPanel) private var insidePlaybackPanel
    @Environment(\.floatingPageRowHeight) private var rowHeight
    @Environment(\.insideFloatingPagePanel) private var nested
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let shape = FloatingPageChrome.surfaceShape(nested: nested)
        let iconWidth = usesPlaybackWidth ? FloatingPageChrome.iconSurfaceWidth : FloatingPageChrome.controlHeight
        let media = overMedia || insidePlaybackPanel
        let surface = insidePlaybackPanel ? Color.white.opacity(0.06)
            : media ? (reduceTransparency ? Color.black : PlaybackChrome.panelFill)
            : nested ? Color.primary.opacity(0.035)
            : Color(uiColor: .systemBackground).opacity(reduceTransparency ? 1 : 0.90)
        configuration.label
            .font(FloatingPageChrome.controlFont)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(selected ? Color.accentColor : (media ? .white : .primary))
            .padding(.horizontal, iconOnly ? 0 : 8)
            .frame(minWidth: FloatingPageChrome.controlHeight)
            .frame(width: iconOnly ? FloatingPageChrome.controlHeight : nil, height: rowHeight)
            .background {
                shape.fill(surface)
                    .overlay { if selected { shape.fill(Color.accentColor.opacity(0.08)) } }
                    .overlay {
                        shape.strokeBorder(selected ? Color.accentColor.opacity(0.28) : (media ? PlaybackChrome.panelStroke : Color.primary.opacity(0.12)), lineWidth: 0.5)
                    }
                    .frame(width: iconOnly ? iconWidth : nil,
                           height: FloatingPageChrome.visibleHeight(nested: nested))
            }
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .contentShape(Rectangle())
    }
}

struct FloatingCardListNote: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, FloatingPageChrome.groupInset)
            .listRowBackground(Color.clear)
    }
}

struct PageContentCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FloatingPageChrome.cardInset)
            .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
    }
}

/// Ordinary page message with a real action, kept at content size rather than a
/// system full-screen empty-state size. Callers provide the action's semantics.
struct PageMessageCard<Actions: View>: View {
    let title: String
    let symbol: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        PageContentCard {
            VStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                HStack(alignment: .top, spacing: FloatingPageChrome.spacing) {
                    FloatingPageIcon(symbol: symbol).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                        Text(title).font(AppTypography.rowTitle)
                        Text(detail).font(AppTypography.supportingText).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                actions()
            }
            .padding(.vertical, FloatingPageChrome.groupInset)
            .frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Media messages share the card geometry while retaining readable dark material.
/// Read-only short media status, distinct from a 44-point action target.
struct MediaHUDSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, FloatingPageChrome.spacing)
            .padding(.vertical, FloatingPageChrome.groupInset)
            .frame(minHeight: ContentMetrics.Media.statusHeight)
            .background(Color.black.opacity(0.72), in: FloatingPageChrome.surfaceShape(nested: true))
    }
}

struct MediaFeedbackSurface: ViewModifier {
    var verticalInset: CGFloat = 0
    func body(content: Content) -> some View {
        content.foregroundStyle(.white)
            .background {
                FloatingPageChrome.controlShape.fill(Color.black.opacity(0.76))
                    .padding(.vertical, verticalInset)
            }
            .environment(\.colorScheme, .dark)
    }
}

struct PageStatusCard: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var retryTitle: LocalizedStringKey = "重试"
    var retry: (() -> Void)? = nil

    var body: some View {
        PageContentCard {
            HStack(spacing: FloatingPageChrome.spacing) {
                FloatingPageIcon(symbol: symbol).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                    Text(title).font(AppTypography.rowTitle)
                    if let detail { Text(detail).font(AppTypography.supportingText) }
                }
                .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Spacer(minLength: 0)
                    StatusReloadButton(title: retryTitle, action: retry)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, FloatingPageChrome.groupInset)
            .frame(minHeight: FloatingPageChrome.controlHeight)
        }
    }
}

struct WorkTagLabel: View {
    let title: String
    let selected: Bool
    var blocked = false
    var fillsHitColumn = false
    var removable = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let hitHeight = typeSize.isAccessibilitySize ? FloatingPageChrome.controlHeight : ContentMetrics.Tag.targetHeight
        return
        HStack(spacing: FloatingPageChrome.groupInset) {
            Text(title).lineLimit(removable ? 1 : 2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
            if removable { Image(systemName: "xmark").font(.caption2).accessibilityHidden(true) }
            else if blocked { Image(systemName: "tag.slash").font(.caption2).accessibilityHidden(true) }
        }
        .font(AppTypography.tag)
        .foregroundStyle(blocked && !selected ? Color.secondary : Color.primary)
        .padding(.horizontal, ContentMetrics.Tag.horizontalInset)
        .padding(.vertical, ContentMetrics.Tag.verticalInset)
        .frame(minHeight: ContentMetrics.Tag.minimumFaceHeight)
        .background {
            let shape = FloatingPageChrome.surfaceShape(nested: true)
            shape.fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.075))
                .overlay {
                    if selected { shape.strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1) }
                }
        }
        .frame(minWidth: hitHeight, maxWidth: fillsHitColumn ? .infinity : nil,
               minHeight: hitHeight,
               alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct FloatingSegmentedTrack: View {
    let nested: Bool
    let overMedia: Bool
    @Environment(\.insidePlaybackPanel) private var insidePlaybackPanel
    @Environment(\.insideFloatingPagePanel) private var insidePanel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = FloatingPageChrome.surfaceShape(nested: nested)
        let foreground = overMedia ? Color.white : Color.primary
        let fill = insidePlaybackPanel ? Color.white.opacity(0.06)
            : overMedia ? (reduceTransparency ? Color.black : PlaybackChrome.panelFill)
            : insidePanel ? Color.primary.opacity(0.035) : Color(uiColor: .systemBackground)
        shape.fill(fill)
            .overlay { shape.strokeBorder(foreground.opacity(0.12), lineWidth: 0.5) }
            .frame(height: FloatingPageChrome.visibleHeight(nested: nested))
            .allowsHitTesting(false)
    }
}

/// A single clipped drawing keeps wrap copies out of layout and accessibility
/// bounds, while animatable position supports both taps and live edge drags.
private struct SegmentedSelectionShape: Shape {
    var position: Double
    let count: Int
    let inset: CGFloat
    let height: CGFloat
    let radius: CGFloat
    var animatableData: Double {
        get { position }
        set { position = newValue }
    }
    func path(in rect: CGRect) -> Path {
        guard count > 0 else { return Path() }
        let slot = rect.width / CGFloat(count)
        let width = max(0, slot - 2 * inset)
        var path = Path()
        for copy in [-1, 0, 1] {
            let x = (CGFloat(position) + CGFloat(copy * count) + 0.5) * slot - width / 2
            let box = CGRect(x: x, y: rect.midY - height / 2, width: width, height: height)
            path.addPath(RoundedRectangle(cornerRadius: radius, style: .circular).path(in: box))
        }
        return path.intersection(Path(rect))
    }
}

struct FloatingSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let optionTitle: (Value) -> String
    let identifier: String
    var overMedia = false
    var nested = false
    var showsTrack = true
    @Environment(\.insideFloatingPagePanel) private var insideFloatingPagePanel
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.segmentedPageMotion) private var pageMotion

    var body: some View {
        let isNested = nested || insideFloatingPagePanel
        let outerInset = isNested ? FloatingPageChrome.groupInset : 0
        let selectionInset = isNested ? FloatingPageChrome.segmentInset / 2 : FloatingPageChrome.segmentInset
        let trackHeight = FloatingPageChrome.visibleHeight(nested: isNested)
        let foreground = overMedia ? Color.white : Color.primary
        let selectedIndex = Double(options.firstIndex(of: selection) ?? 0)
        let position = pageMotion?.identifier == identifier ? (pageMotion?.position ?? selectedIndex) : selectedIndex
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    guard option != selection else { return }
                    if let pageMotion, pageMotion.identifier == identifier,
                       let from = options.firstIndex(of: selection), let to = options.firstIndex(of: option) {
                        pageMotion.select(from: from, to: to, reduceMotion: reduceMotion) { selection = option }
                    } else { selection = option }
                } label: {
                    Text(optionTitle(option))
                        .font(FloatingPageChrome.controlFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(foreground.opacity(selected ? 1 : 0.78))
                        .shadow(color: .black.opacity(overMedia ? 0.55 : 0), radius: 1, y: 1)
                        .padding(.horizontal, FloatingPageChrome.segmentInset)
                        .frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pageMotion?.identifier == identifier && pageMotion?.isInteracting == true)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .background {
            if !options.isEmpty {
                SegmentedSelectionShape(position: position, count: options.count,
                                        inset: showsTrack ? 0 : selectionInset,
                                        height: trackHeight - 2 * selectionInset,
                                        radius: FloatingPageChrome.controlRadius - outerInset - selectionInset)
                    .fill(foreground.opacity(overMedia ? 0.26 : 0.14))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection)
        .padding(.horizontal, showsTrack ? selectionInset : 0)
        .background {
            if showsTrack { FloatingSegmentedTrack(nested: isNested, overMedia: overMedia) }
        }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

struct FloatingMediaPicker: View {
    let title: String
    @Binding var selection: MediaKind
    let identifier: String
    var overMedia = false
    var nested = false
    var showsTrack = true

    var body: some View {
        FloatingSegmentedControl(title: title, selection: $selection, options: MediaKind.browsingCases,
                                 optionTitle: { $0.title }, identifier: identifier, overMedia: overMedia, nested: nested, showsTrack: showsTrack)
    }
}

struct FloatingTitleRow: Layout {
    private let height = FloatingPageChrome.controlHeight
    private let gap = FloatingPageChrome.groupInset

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sideWidth = max(actionWidth(subviews[1]), actionWidth(subviews[3]))
        let idealWidth = subviews[2].sizeThatFits(.unspecified).width + 2 * sideWidth
        return CGSize(width: proposal.width ?? idealWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let leadingWidth = min(bounds.width / 3, actionWidth(subviews[1]))
        let trailingWidth = min(bounds.width / 3, actionWidth(subviews[3]))
        let trackStart = bounds.minX + leadingWidth
        let trackEnd = bounds.maxX - trailingWidth
        let centeredTextWidth = max(0, bounds.width - 2 * max(leadingWidth, trailingWidth))
        subviews[0].place(at: CGPoint(x: trackStart, y: bounds.midY), anchor: .leading,
                         proposal: ProposedViewSize(width: max(0, trackEnd - trackStart), height: height))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                         proposal: ProposedViewSize(width: max(0, leadingWidth - gap), height: height))
        subviews[2].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                         proposal: ProposedViewSize(width: centeredTextWidth, height: height))
        subviews[3].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                         proposal: ProposedViewSize(width: max(0, trailingWidth - gap), height: height))
    }

    private func actionWidth(_ action: LayoutSubview) -> CGFloat {
        let width = action.sizeThatFits(.unspecified).width
        return width > 0 ? width + gap : 0
    }
}

struct FloatingPageBackButton: View {
    var action: (() -> Void)? = nil
    var identifier = "navigation.back"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isHeaderRasterPreview) private var rasterPreview

    var body: some View {
        ZStack {
            if action == nil && !rasterPreview {
                FlatBackNavigationSupport()
                    .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            // The page explicitly owns this action; UIKit only arbitrates gestures.
            Button { if let action { action() } else { dismiss() } } label: { FloatingPageIcon(symbol: "chevron.left") }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .accessibilityLabel("返回")
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct OrdinaryColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme = .light
}

extension EnvironmentValues {
    /// Kept separately from the local media canvas, which is always dark.
    var ordinaryColorScheme: ColorScheme {
        get { self[OrdinaryColorSchemeKey.self] }
        set { self[OrdinaryColorSchemeKey.self] = newValue }
    }
}

private struct AppRootAppearance: ViewModifier {
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(AppTheme.appearanceKey) private var preference = AppAppearance.system.rawValue
    @ObservedObject private var chrome = ViewingChromeController.shared
    @State private var sceneScheme: ColorScheme?
    private var selection: AppAppearance { AppAppearance(rawValue: preference) ?? .system }
    func body(content: Content) -> some View {
        let scheme = selection.colorScheme ?? sceneScheme ?? systemScheme
        content
            .environment(\.ordinaryColorScheme, scheme)
            .background(AppTheme.pageBackground(for: scheme).ignoresSafeArea())
            .background(alignment: .topLeading) {
                SystemAppearanceReader(scheme: $sceneScheme)
                    .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
            .preferredColorScheme(chrome.hasInlinePlayer ? .dark : selection.colorScheme)
            .tint(.blue)
            #if DEBUG && targetEnvironment(simulator)
            .overlay(alignment: .topTrailing) {
                if CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-style49") { NativeBack49Readback() }
            }
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--qa-theme-ui") && CollectionPagingQA.enabled {
                    let value = "theme=\(scheme == .dark ? "dark" : "light");preference=\(preference);scene=\(sceneScheme.map { $0 == .dark ? "dark" : "light" } ?? "pending")"
                    Text(value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityElement(children: .ignore).accessibilityIdentifier("qa.theme.state").accessibilityValue(value)
                }
            }
            #endif
    }
}

/// Read the screen trait so the scene's presentation preference cannot feed
/// the player's dark scheme back into the ordinary pages.
private struct SystemAppearanceReader: UIViewRepresentable {
    @Binding var scheme: ColorScheme?

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.onChange = { scheme = $0 }
        return view
    }

    func updateUIView(_ view: Reader, context: Context) {
        view.onChange = { scheme = $0 }
    }

    static func dismantleUIView(_ view: Reader, coordinator: ()) {
        view.stopObserving()
    }

    final class Reader: UIView {
        var onChange: ((ColorScheme) -> Void)?
        private weak var scene: UIWindowScene?
        private var observation: (any UITraitChangeRegistration)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let newScene = window?.windowScene
            guard newScene !== scene else { return }
            stopObserving()
            guard let newScene else { return }
            scene = newScene
            observation = newScene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                [weak self] (source: UIWindowScene, _: UITraitCollection) in
                self?.publishAppearance(from: source)
            }
            publishAppearance(from: newScene)
        }

        func stopObserving() {
            if let observation { scene?.unregisterForTraitChanges(observation) }
            observation = nil
            scene = nil
        }

        private func publishAppearance(from source: UIWindowScene) {
            DispatchQueue.main.async { [weak self, weak source] in
                guard let self, let source, self.scene === source else { return }
                let systemStyle = source.screen.traitCollection.userInterfaceStyle
                let style = systemStyle == .unspecified ? source.traitCollection.userInterfaceStyle : systemStyle
                self.onChange?(style == .dark ? .dark : .light)
            }
        }
    }
}

private struct OrdinaryAppearance: ViewModifier {
    @Environment(\.ordinaryColorScheme) private var scheme
    func body(content: Content) -> some View {
        let background = AppTheme.pageBackground(for: scheme)
        content
            .tint(.blue)
            .scrollContentBackground(.hidden)
            .background(background.ignoresSafeArea())
            .environment(\.colorScheme, scheme)
            .toolbarBackground(background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(scheme, for: .navigationBar)
    }
}

private struct OrdinaryPresentationAppearance: ViewModifier {
    @Environment(\.ordinaryColorScheme) private var scheme
    func body(content: Content) -> some View {
        content.ordinaryAppearance().preferredColorScheme(scheme)
    }
}

private struct FlatBackNavigationSupport: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Probe {
        let controller = Probe()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        controller.onAttach = { [weak controller, weak coordinator] in
            guard let controller else { return }; coordinator?.apply(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: Probe, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            coordinator.apply(from: controller)
        }
    }

    static func dismantleUIViewController(_ controller: Probe, coordinator: Coordinator) {
        controller.onAttach = nil
        coordinator.recordLifecycle("dismantle")
        coordinator.restoreGesture()
    }

    final class Probe: UIViewController {
        var onAttach: (() -> Void)?
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in self?.onAttach?() }
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            DispatchQueue.main.async { [weak self] in self?.onAttach?() }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAttach?()
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigationController: UINavigationController?
        private weak var owner: UIViewController?
        private final class PopBinding {
            weak var gesture: UIGestureRecognizer?
            var delegate: UIGestureRecognizerDelegate?
            let enabled: Bool
            init(_ gesture: UIGestureRecognizer, delegate: UIGestureRecognizerDelegate?, enabled: Bool) {
                self.gesture = gesture; self.delegate = delegate; self.enabled = enabled
            }
        }
        private var bindings: [PopBinding] = []

        func apply(from controller: UIViewController) {
            var ancestor: UIViewController? = controller
            var host: UIViewController?
            var navigation: UINavigationController?
            while let current = ancestor {
                if let found = current.navigationController,
                   found.viewControllers.contains(where: { $0 === current }) {
                    host = current
                    navigation = found
                    break
                }
                ancestor = current.parent
            }
            guard let host, let navigation, navigation.topViewController === host else {
                return
            }
            let hasPrevious = navigation.viewControllers.count > 1
            if let transition = navigation.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { [weak self, weak controller] _ in
                    guard let controller else { return }; self?.apply(from: controller)
                }
                return
            }
            if hasPrevious {
                if navigationController !== navigation { restoreGesture() }
                self.navigationController = navigation
                owner = host
                // Preserve UIKit's two native return actions and their mutual
                // failure precedence; only our page/edge eligibility is custom.
                var gestures = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
                if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
                    gestures.append(content)
                }
                for gesture in gestures {
                    if gesture.delegate !== self {
                        bindings.removeAll { $0.gesture === gesture }
                        let prior = (gesture.delegate as? Coordinator)?.bindings.first { $0.gesture === gesture }
                        let original = prior != nil ? prior?.delegate : gesture.delegate
                        bindings.append(PopBinding(gesture, delegate: original, enabled: prior?.enabled ?? gesture.isEnabled))
                        gesture.delegate = self
                        #if DEBUG && targetEnvironment(simulator)
                        gesture.addTarget(self, action: #selector(traceNativeReturn(_:)))
                        #endif
                    }
                    gesture.isEnabled = true
                }
            } else { restoreGesture() }
            recordQA(navigation)
        }

        func recordLifecycle(_ event: String) {
            #if DEBUG && targetEnvironment(simulator)
            guard ProcessInfo.processInfo.arguments.contains("--qa-style49") else { return }
            let detail = bindings.map { binding in
                "state=\(binding.gesture?.state.rawValue ?? -1),restoreEnabled=\(binding.enabled),own=\(binding.gesture?.delegate === self)"
            }.joined(separator: "|")
            let entry = event + "[transition=\(navigationController?.transitionCoordinator != nil);\(detail)]"
            NativeBack49State.shared.events.append(entry)
            NativeBack49State.shared.events = Array(NativeBack49State.shared.events.suffix(8))
            #endif
        }

        func restoreGesture() {
            if !bindings.isEmpty { recordLifecycle("restore") }
            for binding in bindings {
                if let gesture = binding.gesture, gesture.delegate === self {
                    #if DEBUG && targetEnvironment(simulator)
                    gesture.removeTarget(self, action: #selector(traceNativeReturn(_:)))
                    #endif
                    gesture.delegate = binding.delegate
                    gesture.isEnabled = binding.enabled
                }
            }
            bindings.removeAll()
            navigationController = nil
            owner = nil
        }

        private func nativeKind(_ gesture: UIGestureRecognizer) -> String {
            if gesture === navigationController?.interactivePopGestureRecognizer { return "edge-property" }
            if #available(iOS 26.0, *), gesture === navigationController?.interactiveContentPopGestureRecognizer { return "content-property" }
            return "other"
        }

        #if DEBUG && targetEnvironment(simulator)
        @objc private func traceNativeReturn(_ gesture: UIPanGestureRecognizer) {
            guard ProcessInfo.processInfo.arguments.contains("--qa-segment-edge"),
                  gesture.state != .changed else { return }
            let point = gesture.translation(in: gesture.view)
            let velocity = gesture.velocity(in: gesture.view)
            NSLog("NATIVE_RETURN kind=%@ state=%ld dx=%.1f vx=%.1f", nativeKind(gesture), gesture.state.rawValue, point.x, velocity.x)
            if gesture.state == .began {
                DispatchQueue.main.async { [weak self] in
                    self?.navigationController?.transitionCoordinator?.notifyWhenInteractionChanges { context in
                        NSLog("NATIVE_RETURN interaction cancelled=%@ percent=%.3f", context.isCancelled ? "true" : "false", context.percentComplete)
                    }
                }
            }
        }
        #endif

        private func eligible(_ gesture: UIGestureRecognizer) -> Bool {
            guard bindings.contains(where: { $0.gesture === gesture }),
                  let owner,
                  let navigation = navigationController, navigation.topViewController === owner,
                  navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil,
                  navigation.presentedViewController == nil else { return false }
            return !PageEdgeReturnPolicy.isSegmentedBrowsing(owner: owner)
                && !PageEdgeReturnPolicy.ownsReturnGesture(owner: owner)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            #if DEBUG && targetEnvironment(simulator)
            NativeBack49State.shared.beginCalls += 1
            #endif
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-segment-edge") {
                NSLog("NATIVE_GATE begin kind=%@ driver=%@ eligible=%@ transition=%@", String(describing: type(of: gestureRecognizer)), nativeKind(gestureRecognizer), eligible(gestureRecognizer) ? "true" : "false", navigationController?.transitionCoordinator != nil ? "true" : "false")
            }
            #endif
            guard eligible(gestureRecognizer) else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view {
                let velocity = pan.velocity(in: view)
                let returning = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -velocity.x : velocity.x
                guard returning > abs(velocity.y) else { return false }
            }
            // The default delegate rejects hidden native back buttons. The
            // gesture still drives UIKit's original interactive pop action.
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            #if DEBUG && targetEnvironment(simulator)
            NativeBack49State.shared.lastGate = "nav=\(navigationController.map { String(describing: ObjectIdentifier($0)) } ?? "nil"),top=\(navigationController?.topViewController === owner),transition=\(navigationController?.transitionCoordinator != nil),eligible=\(eligible(gestureRecognizer))"
            #endif
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-segment-edge") {
                NSLog("NATIVE_GATE receive kind=%@ driver=%@ eligible=%@ transition=%@", String(describing: type(of: gestureRecognizer)), nativeKind(gestureRecognizer), eligible(gestureRecognizer) ? "true" : "false", navigationController?.transitionCoordinator != nil ? "true" : "false")
            }
            #endif
            guard eligible(gestureRecognizer), let view = gestureRecognizer.view,
                  touch.type == .direct, touch.view?.isDescendant(of: view) == true else { return false }
            let point = touch.location(in: view)
            let distance = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? view.bounds.maxX - point.x : point.x - view.bounds.minX
            let allowed = ScreenEdgeGesture.contains(distance: distance)
            #if DEBUG && targetEnvironment(simulator)
            NativeBack49State.shared.receiveCalls += 1
            NativeBack49State.shared.lastReceiveAllowed = allowed
            #endif
            return allowed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            let allowed = eligible(gestureRecognizer) && event.type == .touches
            #if DEBUG && targetEnvironment(simulator)
            NativeBack49State.shared.eventCalls += 1
            NativeBack49State.shared.lastEventAllowed = allowed
            #endif
            return allowed
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            guard let binding = bindings.first(where: { $0.gesture === gesture }),
                  bindings.contains(where: { $0.gesture === other }) else { return false }
            return binding.delegate?.gestureRecognizer?(gesture, shouldRequireFailureOf: other) ?? false
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            if let binding = bindings.first(where: { $0.gesture === gesture }),
               bindings.contains(where: { $0.gesture === other }) {
                return binding.delegate?.gestureRecognizer?(gesture, shouldBeRequiredToFailBy: other) ?? false
            }
            // Once the leading-edge touch is accepted, grid taps/scrolling
            // wait for the return pan. Center touches never enter this path.
            guard eligible(gesture), !bindings.contains(where: { $0.gesture === other }),
                  let view = navigationController?.view, let otherView = other.view else { return false }
            return otherView === view || otherView.isDescendant(of: view)
        }

        private func recordQA(_ controller: UINavigationController) {
            #if DEBUG && targetEnvironment(simulator)
            guard CollectionPagingQA.enabled, ProcessInfo.processInfo.arguments.contains("--qa-style49") else { return }
            NativeBack49State.shared.snapshot = { [weak controller, weak self] in
                guard let controller, #available(iOS 26.0, *) else { return }
                let state = NativeBack49State.shared
                let edge = controller.interactivePopGestureRecognizer
                let value = "navID=\(ObjectIdentifier(controller));lastGate=\(state.lastGate);depth=\(controller.viewControllers.count);nativeBackHidden=\(controller.topViewController?.navigationItem.hidesBackButton == true);edgeSwipe=\(edge?.isEnabled == true);ownDelegate=\(edge?.delegate === self);gestureState=\(edge?.state.rawValue ?? -1);beginCalls=\(state.beginCalls);receiveCalls=\(state.receiveCalls);receiveAllowed=\(state.lastReceiveAllowed);eventCalls=\(state.eventCalls);eventAllowed=\(state.lastEventAllowed);transition=\(controller.transitionCoordinator != nil);gestureView=\(edge?.view != nil);gestureInWindow=\(edge?.view?.window != nil);gestureWidth=\(Int(edge?.view?.bounds.width ?? -1));gestureViewEnabled=\(edge?.view?.isUserInteractionEnabled == true);navInWindow=\(controller.view.window != nil);edgeKind=\(edge is UIScreenEdgePanGestureRecognizer);edges=\((edge as? UIScreenEdgePanGestureRecognizer)?.edges.rawValue ?? 0);contentEnabled=\(controller.interactiveContentPopGestureRecognizer?.isEnabled == true);contentState=\(controller.interactiveContentPopGestureRecognizer?.state.rawValue ?? -1);gestureViewHidden=\(edge?.view?.isHidden == true);navHidden=\(controller.view.isHidden)"
                if NativeBack49State.shared.value != value { NativeBack49State.shared.value = value }
            }
            #endif
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor private final class NativeBack49State: ObservableObject {
    static let shared = NativeBack49State()
    @Published var value = "notObserved"
    @Published var events: [String] = []
    var snapshot: (() -> Void)?
    var lastGate = "none"
    var beginCalls = 0
    var receiveCalls = 0
    var lastReceiveAllowed = false
    var eventCalls = 0
    var lastEventAllowed = false
}
private struct NativeBack49Readback: View {
    @ObservedObject private var state = NativeBack49State.shared
    var body: some View {
        Text(state.value).font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityIdentifier("navigation.qa49").accessibilityValue(state.value + ";lifecycle=" + state.events.joined(separator: ">"))
            .task {
                while !Task.isCancelled {
                    state.snapshot?()
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            }
    }
}
#endif

private struct OverlaidTabBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Only the height drawn over ordinary content. Tabs already reserved in the safe area contribute zero.
    var overlaidTabBarHeight: CGFloat {
        get { self[OverlaidTabBarHeightKey.self] }
        set { self[OverlaidTabBarHeightKey.self] = newValue }
    }
}

private struct FloatingPageSafeInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}
private struct FloatingPageContentInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}
extension EnvironmentValues {
    var floatingPageSafeInsets: EdgeInsets {
        get { self[FloatingPageSafeInsetsKey.self] }
        set { self[FloatingPageSafeInsetsKey.self] = newValue }
    }
    var floatingPageContentInsets: EdgeInsets {
        get { self[FloatingPageContentInsetsKey.self] }
        set { self[FloatingPageContentInsetsKey.self] = newValue }
    }
}

/// The scrolling viewport fills its canvas. Only the scrollable content owns
/// clearance for fixed chrome, including when hosted by a native list pane.
private struct FloatingScrollCanvas: ViewModifier {
    var additionalBottom: CGFloat = 0
    @Environment(\.floatingPageContentInsets) private var insets
    func body(content: Content) -> some View {
        content
            .contentMargins(.top, insets.top, for: .scrollContent)
            .contentMargins(.bottom, insets.bottom + additionalBottom, for: .scrollContent)
            .contentMargins(.top, insets.top, for: .scrollIndicators)
            .contentMargins(.bottom, insets.bottom + additionalBottom, for: .scrollIndicators)
            .ignoresSafeArea(.container, edges: .vertical)
    }
}

private struct PageScrollContentInsets: ViewModifier {
    @Environment(\.overlaidTabBarHeight) private var overlap

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, FloatingPageChrome.pageInset)
            .padding(.bottom, FloatingPageChrome.pageInset)
    }
}

private struct AvoidOverlaidTabBar: ViewModifier {
    let constrainViewport: Bool
    @Environment(\.overlaidTabBarHeight) private var overlap

    func body(content: Content) -> some View {
        content.floatingScrollCanvas()
    }
}

extension View {
    func floatingScrollCanvas(additionalBottom: CGFloat = 0) -> some View {
        modifier(FloatingScrollCanvas(additionalBottom: additionalBottom))
    }
    func pageScrollContentInsets() -> some View { modifier(PageScrollContentInsets()) }
    func avoidOverlaidTabBar(constrainViewport: Bool = false) -> some View {
        modifier(AvoidOverlaidTabBar(constrainViewport: constrainViewport))
    }

    /// Apply once outside the root navigation and all presentations.
    func appRootAppearance() -> some View { modifier(AppRootAppearance()) }
    func floatingCardListRows() -> some View {
        let outer = FloatingPageChrome.pageInset
        let inner = outer + FloatingPageChrome.cardInset
        return self
            .font(AppTypography.rowTitle)
            .listRowInsets(EdgeInsets(top: 0, leading: inner, bottom: 0, trailing: inner))
            .listRowBackground(FloatingPageChrome.controlShape.fill(AppTheme.secondarySurface).padding(.horizontal, outer))
            .listRowSeparator(.hidden)
    }

    /// Ordinary navigation and sheets retain this theme even when opened over media.
    func ordinaryAppearance() -> some View { modifier(OrdinaryAppearance()) }
    /// Apply at a sheet's root so UIKit has its style before the transition.
    func ordinaryPresentationAppearance() -> some View { modifier(OrdinaryPresentationAppearance()) }
    func floatingPagePanelControls(rowHeight: CGFloat = FloatingPageChrome.controlHeight, overMedia: Bool = false) -> some View {
        buttonStyle(FloatingPageButtonStyle())
            .environment(\.insideFloatingPagePanel, true)
            .environment(\.floatingPageRowHeight, rowHeight)
            .environment(\.insidePlaybackPanel, overMedia)
    }

    func floatingTitleBar<Leading: View, Actions: View>(
        _ title: String,
        count: Int? = nil,
        overMedia: Bool = false,
        hidden: Bool = false,
        layoutIdentity: AnyHashable? = nil,
        observesContentViewport: Bool = true,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        self.navigationTitle(title)
            .pageContentViewport(observes: observesContentViewport && !overMedia)
            .floatingPageBar("page-title." + title, overMedia: overMedia, hidden: hidden, layoutIdentity: layoutIdentity) {
                FloatingTitleRow {
                    FloatingSegmentedTrack(nested: true, overMedia: overMedia).accessibilityHidden(true)
                    ZStack {
                        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
                        leading()
                    }
                    HStack(spacing: FloatingPageChrome.groupInset) {
                        Text(title)
                        if let count { Text("· \(count)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                        .font(FloatingPageChrome.controlFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("page-header.title")
                        .accessibilityAddTraits(.isHeader)
                    ZStack {
                        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
                        HStack(spacing: FloatingPageChrome.groupInset, content: actions)
                    }
                }
            }
    }

    func floatingTitleBar<Actions: View>(
        _ title: String, count: Int? = nil, layoutIdentity: AnyHashable? = nil,
        observesContentViewport: Bool = true, @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        floatingTitleBar(title, count: count, layoutIdentity: layoutIdentity, observesContentViewport: observesContentViewport,
                         leading: { FloatingPageBackButton() }, actions: actions)
    }

    func floatingTitleBar(_ title: String) -> some View {
        floatingTitleBar(title) { EmptyView() }
    }
}

private struct ValueSelectorExpandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var valueSelectorExpanded: Bool {
        get { self[ValueSelectorExpandedKey.self] }
        set { self[ValueSelectorExpandedKey.self] = newValue }
    }
}


/// Fixed bar palettes interpolate actual fill, border and ink endpoints. No
/// full-bar opacity and no partially transparent color curtain on first mount.
@MainActor enum PageBarPalette {
    static func traits(_ scheme: ColorScheme) -> UITraitCollection {
        UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
    }
    static func fill(_ media: Bool, _ scheme: ColorScheme, _ opaque: Bool) -> UIColor {
        media ? UIColor.black.withAlphaComponent(opaque ? 1 : 0.48)
            : UIColor.systemBackground.resolvedColor(with: traits(scheme)).withAlphaComponent(opaque ? 1 : CGFloat(FloatingPageChrome.ordinaryPanelOpacity))
    }
    static func border(_ media: Bool, _ scheme: ColorScheme) -> UIColor {
        media ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.label.resolvedColor(with: traits(scheme)).withAlphaComponent(0.06)
    }
    static func ink(_ media: Bool, _ scheme: ColorScheme) -> UIColor {
        media ? UIColor.white.withAlphaComponent(0.88) : UIColor.secondaryLabel.resolvedColor(with: traits(scheme))
    }
    static func mix(_ source: UIColor, _ target: UIColor, _ progress: Double) -> Color {
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        source.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
        target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let p = CGFloat(progress)
        return Color(uiColor: UIColor(red: sr + (tr - sr) * p, green: sg + (tg - sg) * p,
                                      blue: sb + (tb - sb) * p, alpha: sa + (ta - sa) * p))
    }
    static func progress(_ tone: PageToneTransition?, reduced: Bool) -> Double {
        guard !reduced, let tone else { return 1 }
        return 1 - tone.initialOpacity * (1 - tone.clock.progress)
    }
}

struct PageToneBarSurface: View {
    let overMedia: Bool
    let fallback: PageToneTransition?
    var opaqueOverride: Bool? = nil
    @Environment(\.pageSurfaceTone) private var managed
    @Environment(\.pageWindowToneContext) private var windowTone
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        let tone = windowTone?.returnTone ?? managed ?? windowTone?.tone ?? fallback
        SwiftUI.TimelineView(.animation(paused: tone == nil || reduced)) { _ in
            let p = PageBarPalette.progress(tone, reduced: reduced)
            let fromMedia = tone?.sourceIsMedia ?? overMedia
            let toMedia = tone?.destinationIsMedia ?? overMedia
            let toScheme = tone?.destinationScheme ?? scheme
            let fromScheme = tone?.sourceScheme ?? scheme
            let shape = FloatingPageChrome.controlShape
            shape.fill(PageBarPalette.mix(PageBarPalette.fill(fromMedia, fromScheme, opaqueOverride ?? opaque),
                                          PageBarPalette.fill(toMedia, toScheme, opaqueOverride ?? opaque), p))
                .overlay {
                    shape.strokeBorder(PageBarPalette.mix(PageBarPalette.border(fromMedia, fromScheme),
                                                           PageBarPalette.border(toMedia, toScheme), p),
                                       lineWidth: ContentMetrics.Optical.hairline)
                }
        }
        .frame(height: FloatingPageChrome.surfaceHeight).allowsHitTesting(false)
    }
}

struct PageToneBarInk: ViewModifier {
    let selected: Bool
    let overMedia: Bool
    let fallback: PageToneTransition?
    @Environment(\.pageSurfaceTone) private var managed
    @Environment(\.pageWindowToneContext) private var windowTone
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        let tone = windowTone?.returnTone ?? managed ?? windowTone?.tone ?? fallback
        SwiftUI.TimelineView(.animation(paused: tone == nil || reduced)) { _ in
            let p = PageBarPalette.progress(tone, reduced: reduced)
            let fromMedia = tone?.sourceIsMedia ?? overMedia
            let toMedia = tone?.destinationIsMedia ?? overMedia
            let toScheme = tone?.destinationScheme ?? scheme
            let ink = PageBarPalette.mix(PageBarPalette.ink(fromMedia, tone?.sourceScheme ?? scheme),
                                         PageBarPalette.ink(toMedia, toScheme), p)
            content.foregroundStyle(selected ? Color.accentColor : ink)
                .shadow(color: .black.opacity(((fromMedia ? 0.7 : 0) * (1 - p)) + ((toMedia ? 0.7 : 0) * p)), radius: 2, y: 1)
        }
    }
}


extension EnvironmentValues {
    @Entry var pageWindowToneContext: PageSurfaceToneContext? = nil
}

struct PageWindowToneReader: ViewModifier {
    @State private var context: PageSurfaceToneContext?
    func body(content: Content) -> some View {
        content.environment(\.pageWindowToneContext, context)
            .background { WindowMarker(context: $context).allowsHitTesting(false).accessibilityHidden(true) }
    }
    private struct WindowMarker: UIViewRepresentable {
        @Binding var context: PageSurfaceToneContext?
        func makeUIView(context: Context) -> Marker { Marker() }
        func updateUIView(_ view: Marker, context: Context) {
            view.attach = { [weak view] value in
                let expectedWindow = view?.window
                // Resolve the window reference once outside the current SwiftUI
                // update; per-frame tone progress remains a direct clock read.
                DispatchQueue.main.async { [weak view, weak expectedWindow] in
                    guard view?.window === expectedWindow else { return }
                    self.context = value
                }
            }
            view.resolve()
        }
        final class Marker: UIView {
            var attach: ((PageSurfaceToneContext?) -> Void)?
            private weak var attachedWindow: UIWindow?
            override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
            func resolve() {
                guard window !== attachedWindow else { return }
                attachedWindow = window
                attach?(window.map { PageBodyHandoff.toneContext(in: $0) })
            }
        }
    }
}


/// Only a cover needs this canvas strip. Tab transitions already blend their
/// entire root canvas and must not receive a second color layer here.
struct PageToneBarCanvas: View {
    @Environment(\.pageSurfaceTone) private var managed
    @Environment(\.pageWindowToneContext) private var windowTone
    var body: some View {
        if let tone = windowTone?.returnTone ?? managed ?? windowTone?.tone {
            ZStack {
                // A navigation drag still has the source page mounted behind
                // this fixed bar. Explicit return endpoints supply its canvas;
                // fading the source alone would keep revealing source white.
                if let media = tone.destinationIsMedia, let scheme = tone.destinationScheme {
                    media ? Color.black : AppTheme.pageBackground(for: scheme)
                }
                PageToneBlend(tone: tone, coversSafeArea: false)
            }.id(tone.id)
        }
    }
}
