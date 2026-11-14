import SwiftUI
import UIKit

@MainActor private protocol AppFloatingOwner: AnyObject {
    func dismissPresentation()
    func close(animated: Bool)
    var sourceWindow: UIWindow? { get }
    var sourceRect: CGRect { get }
}

@MainActor private enum AppFloatingOwnership {
    static weak var current: (any AppFloatingOwner)?
}

/// App-owned single-value selector. Dismissing outside leaves the value unchanged.
struct AppValueSelector<Value: Hashable, Label: View>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String
    @ViewBuilder let label: () -> Label
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = FloatingPageChrome.controlHeight

    var body: some View {
        Button { expanded = true } label: { label().environment(\.valueSelectorExpanded, expanded) }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityValue(name(selection))
            .background {
                AnchoredChoicePresentation(isPresented: $expanded,
                                           preferredHeight: CGFloat(min(options.count, ContentMetrics.Choice.visibleRows)) * rowHeight + 2 * FloatingPageChrome.groupInset,
                                           reduceMotion: reduceMotion) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(options, id: \.self) { option in
                                    Button {
                                        expanded = false
                                        selection = option
                                    } label: {
                                        Text(name(option))
                                            .font(AppTypography.rowTitle)
                                            .lineLimit(1).truncationMode(.tail)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .frame(height: rowHeight)
                                            .padding(.horizontal, FloatingPageChrome.cardInset)
                                            .foregroundStyle(selection == option ? Color.accentColor : Color.primary)
                                            .background(selection == option ? AppTheme.selectionFill(for: scheme) : .clear,
                                                        in: FloatingPageChrome.surfaceShape(nested: true))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel(name(option))
                                    .accessibilityIdentifier("value-selector.option.\(String(describing: option))")
                                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                                    .accessibilityValue(selection == option ? "已选" : "")
                                    .id(option)
                                }
                            }.padding(FloatingPageChrome.groupInset)
                        }
                        .onAppear { proxy.scrollTo(selection, anchor: .center) }
                    }
                    .background(AppTheme.pageBackground(for: scheme), in: FloatingPageChrome.controlShape)
                    .overlay { FloatingPageChrome.controlShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: ContentMetrics.Optical.hairline) }
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize)
                    .disabled(!enabled)
                    .accessibilityIdentifier("value-selector.options")
                }
            }
            .onChange(of: enabled) { _, value in if !value { expanded = false } }
    }
}

/// Attach to the source window so list clipping and the fixed header cannot crop
/// the menu. The coordinator owns one overlay and removes it with its source.
/// Snapshot renderers must not traverse even an empty UIKit anchor: it draws
/// an unsupported-view placeholder over the real button label.
struct AnchoredChoicePresentation<Content: View>: View {
    @Binding var isPresented: Bool
    let preferredHeight: CGFloat
    let reduceMotion: Bool
    var centered = false
    @ViewBuilder let content: () -> Content
    @Environment(\.isHeaderRasterPreview) private var rasterPreview
    @Environment(\.rootPageParticipation) private var participation

    var body: some View {
        if !rasterPreview && participation.isActive {
            AnchoredChoiceBridge(isPresented: $isPresented, preferredHeight: preferredHeight,
                                 reduceMotion: reduceMotion, centered: centered, content: content)
        }
    }
}

private struct AnchoredChoiceBridge<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let preferredHeight: CGFloat
    let reduceMotion: Bool
    var centered = false
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ChoiceAnchorView {
        let view = ChoiceAnchorView()
        view.isUserInteractionEnabled = false
        view.layoutChanged = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.reposition(from: view) }
        }
        return view
    }
    func updateUIView(_ view: ChoiceAnchorView, context: Context) {
        context.coordinator.update(from: view, presented: isPresented, height: preferredHeight,
                                   reduceMotion: reduceMotion, centered: centered, content: AnyView(content()), dismiss: { isPresented = false })
    }
    static func dismantleUIView(_ view: ChoiceAnchorView, coordinator: Coordinator) { coordinator.close() }

    final class Coordinator: AppFloatingOwner {
        private var host: UIHostingController<AnyView>?
        private var content = AnyView(EmptyView())
        private var height: CGFloat = 0
        private var dismiss: () -> Void = {}
        private weak var anchor: UIView?
        private var reduceMotion = false
        private var closing = false
        private var centered = false
        var sourceWindow: UIWindow? { anchor?.window }
        var sourceRect: CGRect { guard let anchor, let window = anchor.window else { return .zero }; return anchor.convert(anchor.bounds, to: window) }
        private var transitionID = UUID()
        private var interaction: PageInteractionShield.Lease?
        private var keyboardObservers: [NSObjectProtocol] = []

        func update(from anchor: UIView, presented: Bool, height: CGFloat, reduceMotion: Bool, centered: Bool, content: AnyView, dismiss: @escaping () -> Void) {
            self.anchor = anchor; self.reduceMotion = reduceMotion; self.centered = centered
            self.content = content; self.height = height; self.dismiss = dismiss
            guard presented else { close(animated: !reduceMotion); return }
            guard let window = anchor.window else { return }
            if let other = AppFloatingOwnership.current, other !== self {
                other.dismissPresentation()
                other.close(animated: false)
            }
            AppFloatingOwnership.current = self
            let animateOpening = host == nil || closing
            transitionID = UUID(); closing = false
            if host == nil {
                let controller = UIHostingController(rootView: AnyView(EmptyView()))
                controller.view.backgroundColor = .clear
                controller.view.alpha = reduceMotion ? 1 : 0
                controller.view.accessibilityViewIsModal = true
                controller.view.frame = window.bounds
                controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                window.addSubview(controller.view)
                host = controller
                for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
                    keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self, let anchor = self.anchor else { return }
                            self.reposition(from: anchor)
                        }
                    })
                }
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
            host?.view.isUserInteractionEnabled = true
            reposition(from: anchor)
            if animateOpening, let host {
                interaction?.release()
                let lease = PageInteractionShield.acquire(in: window)
                interaction = lease
                UIView.animate(withDuration: reduceMotion ? 0 : ContentMetrics.Choice.motionDuration,
                               delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { host.view.alpha = 1 }
                completion: { _ in lease.release() }
            }
        }
        func reposition(from anchor: UIView) {
            guard let host else { return }
            guard let window = anchor.window, host.view.superview === window else {
                close()
                let dismiss = dismiss, revision = transitionID
                DispatchQueue.main.async { [weak self] in
                    guard self?.transitionID == revision else { return }
                    dismiss()
                }
                return
            }
            let rect = anchor.convert(anchor.bounds, to: window)
            let keyboardTop = window.keyboardLayoutGuide.layoutFrame.minY
            host.rootView = AnyView(ChoiceOverlay(anchor: rect, safeArea: window.safeAreaInsets,
                                                 keyboardTop: keyboardTop > 0 ? keyboardTop : window.bounds.height,
                                                 preferredHeight: height, centered: centered, isPresented: !closing,
                                                 reduceMotion: reduceMotion, dismiss: dismiss, content: content))
        }
        func dismissPresentation() { dismiss(); close() }

        func close(animated: Bool = false) {
            guard let host else { return }
            if animated {
                guard !closing else { return }
                closing = true
                let revision = UUID(); transitionID = revision
                if let anchor { reposition(from: anchor) }
                host.view.isUserInteractionEnabled = false
                interaction?.release()
                let lease = host.view.window.map(PageInteractionShield.acquire)
                interaction = lease
                UIView.animate(withDuration: ContentMetrics.Choice.motionDuration, delay: 0,
                               options: [.beginFromCurrentState, .allowUserInteraction]) {
                    host.view.alpha = 0
                } completion: { [weak self, weak host] _ in
                    lease?.release()
                    guard let self, let host, self.transitionID == revision, self.host === host else { return }
                    self.close()
                }
                return
            }
            transitionID = UUID(); closing = false
            interaction?.release(); interaction = nil
            keyboardObservers.forEach(NotificationCenter.default.removeObserver)
            keyboardObservers = []
            host.view.layer.removeAllAnimations()
            host.view.removeFromSuperview()
            self.host = nil
            if AppFloatingOwnership.current === self { AppFloatingOwnership.current = nil }
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }
}

final class ChoiceAnchorView: UIView {
    var layoutChanged: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); layoutChanged?() }
    override func didMoveToWindow() { super.didMoveToWindow(); layoutChanged?() }
}

private struct ChoiceOverlay: View {
    let anchor: CGRect
    let safeArea: UIEdgeInsets
    let keyboardTop: CGFloat
    let preferredHeight: CGFloat
    let centered: Bool
    let isPresented: Bool
    let reduceMotion: Bool
    let dismiss: () -> Void
    let content: AnyView
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            let gap = FloatingPageChrome.groupInset
            let left = safeArea.left + FloatingPageChrome.pageInset, right = geometry.size.width - safeArea.right - FloatingPageChrome.pageInset
            let top = safeArea.top + gap, bottom = min(geometry.size.height - safeArea.bottom, keyboardTop) - gap
            let anchorTop = max(top, min(anchor.minY, bottom))
            let anchorBottom = max(top, min(anchor.maxY, bottom))
            let below = max(0, bottom - anchorBottom - gap), above = max(0, anchorTop - gap - top)
            let height = min(preferredHeight, centered ? max(0, bottom - top) : max(above, below))
            let width = min(ContentMetrics.Choice.width, max(0, right - left))
            let x = centered ? (left + right - width) / 2 : max(left, min(anchor.maxX - width, right - width))
            let proposedY = centered ? (top + bottom - height) / 2 : (below >= height ? anchorBottom + gap : anchorTop - gap - height)
            let y = max(top, min(proposedY, bottom - height))
            ZStack(alignment: .topLeading) {
                Button(action: dismiss) { Color.black.opacity(centered ? 0.18 : 0.001).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(centered ? "关闭确认" : "关闭菜单")
                content.frame(width: width, height: height)
                    .clipShape(FloatingPageChrome.controlShape)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                    .offset(y: appeared && isPresented ? 0 : -FloatingPageChrome.groupInset)
                    .animation(reduceMotion ? nil : .easeOut(duration: ContentMetrics.Choice.motionDuration), value: appeared && isPresented)
                    .position(x: x + width / 2, y: y + height / 2)
            }
        }
        .ignoresSafeArea()
        .onAppear { appeared = true }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
    }
}

private struct AppMenuDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
private extension EnvironmentValues {
    var appMenuDismiss: () -> Void {
        get { self[AppMenuDismissKey.self] }
        set { self[AppMenuDismissKey.self] = newValue }
    }
}

/// Commands retain their original actions, disabled state and destructive role.
/// The common primitive style owns only the row and trigger-then-dismiss rule.
private struct AppMenuItemStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.appMenuDismiss) private var dismiss
        @Environment(\.isEnabled) private var enabled
        @ScaledMetric(relativeTo: .subheadline) private var height = FloatingPageChrome.controlHeight
        var body: some View {
            configuration.label
                .font(AppTypography.rowTitle)
                .labelStyle(AppMenuLabelStyle())
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: height)
                .padding(.horizontal, FloatingPageChrome.cardInset)
                .contentShape(Rectangle())
                .foregroundStyle(!enabled ? Color.secondary : configuration.role == .destructive ? Color.red : Color.primary)
                .onTapGesture { activate() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate() }
        }
        private func activate() {
            guard enabled else { return }
            configuration.trigger()
            dismiss()
        }
    }
}
private struct AppMenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FloatingPageChrome.spacing) {
            configuration.icon.font(.system(size: ContentMetrics.Icon.primary)).frame(width: ContentMetrics.Icon.primary)
            configuration.title.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AppMenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(AppTypography.supportingText).foregroundStyle(.secondary)
                .padding(.horizontal, FloatingPageChrome.cardInset).padding(.vertical, FloatingPageChrome.groupInset)
            content()
        }
    }
}

private struct AppMenuSurface<Content: View>: View {
    @Binding var height: CGFloat
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(FloatingPageChrome.groupInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .buttonStyle(AppMenuItemStyle())
        .environment(\.appMenuDismiss, dismiss)
        .background(AppTheme.pageBackground(for: scheme), in: FloatingPageChrome.controlShape)
        .overlay { FloatingPageChrome.controlShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: ContentMetrics.Optical.hairline) }
        .accessibilityIdentifier("app-menu.options")
    }
}

struct AppMenu<Content: View, Label: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var expanded = false
    @State private var measuredHeight: CGFloat = 272
    @Environment(\.self) private var environment
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = FloatingPageChrome.controlHeight
    var body: some View {
        Button { expanded = true } label: { label().environment(\.valueSelectorExpanded, expanded) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .background {
                AnchoredChoicePresentation(isPresented: $expanded,
                                           preferredHeight: min(measuredHeight, rowHeight * CGFloat(ContentMetrics.Choice.visibleRows) + 8),
                                           reduceMotion: reduceMotion) {
                    AppMenuSurface(height: $measuredHeight, dismiss: { expanded = false }, content: content)
                        .environment(\.self, environment)
                }
            }
            .onChange(of: enabled) { _, value in if !value { expanded = false } }
    }
}

private final class ContextMenuInteraction {
    var blocksPrimaryAction = false
}

struct AppContextButton<Label: View, Actions: View>: View {
    let contextEnabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewBuilder let menu: () -> Actions
    @State private var interaction = ContextMenuInteraction()
    init(contextEnabled: Bool = true, action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label, @ViewBuilder menu: @escaping () -> Actions) {
        self.contextEnabled = contextEnabled; self.action = action; self.label = label; self.menu = menu
    }
    var body: some View {
        Button {
            if !interaction.blocksPrimaryAction { action() }
        } label: { label() }
            .modifier(AppContextMenu(permitted: contextEnabled, interaction: interaction, actions: menu))
    }
}

private struct AppContextMenu<Actions: View>: ViewModifier {
    let permitted: Bool
    let interaction: ContextMenuInteraction
    @ViewBuilder let actions: () -> Actions
    @State private var expanded = false
    @State private var measuredHeight: CGFloat = 272
    @Environment(\.self) private var environment
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = FloatingPageChrome.controlHeight
    @Environment(\.isHeaderRasterPreview) private var rasterPreview
    func body(content: Content) -> some View {
        content
            .background {
                if !rasterPreview {
                    ContextMenuAnchor(enabled: enabled && permitted) {
                        interaction.blocksPrimaryAction = true
                        expanded = true
                    }
                        .background {
                            AnchoredChoicePresentation(isPresented: $expanded,
                                                       preferredHeight: min(measuredHeight, rowHeight * CGFloat(ContentMetrics.Choice.visibleRows) + 8),
                                                       reduceMotion: reduceMotion) {
                                AppMenuSurface(height: $measuredHeight, dismiss: { expanded = false }, content: actions)
                                    .environment(\.self, environment)
                            }
                        }
                }
            }
            .accessibilityAction(named: Text("更多操作")) {
                if enabled && permitted { interaction.blocksPrimaryAction = true; expanded = true }
            }
            .onChange(of: expanded) { _, value in
                if !value {
                    interaction.blocksPrimaryAction = false
                }
            }
            .onDisappear { interaction.blocksPrimaryAction = false }
            .onChange(of: permitted) { _, value in if !value { expanded = false } }
            .onChange(of: enabled) { _, value in if !value { expanded = false } }
    }
}

/// A recognizer on the source host can cancel the underlying SwiftUI tap when
/// long press wins. Each row admits only touches inside its own anchor bounds.
private struct ContextMenuAnchor: UIViewRepresentable {
    let enabled: Bool
    let open: () -> Void
    @Environment(\.rootPageParticipation) private var participation
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ChoiceAnchorView {
        let view = ChoiceAnchorView(); view.isUserInteractionEnabled = false
        context.coordinator.anchor = view
        view.layoutChanged = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        return view
    }
    func updateUIView(_ view: ChoiceAnchorView, context: Context) {
        context.coordinator.open = open; context.coordinator.enabled = enabled && participation.isActive; context.coordinator.attach()
    }
    static func dismantleUIView(_ view: ChoiceAnchorView, coordinator: Coordinator) { coordinator.detach() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var anchor: UIView?
        private weak var host: UIView?
        var open: () -> Void = {}
        var enabled = true
        private lazy var press: UILongPressGestureRecognizer = {
            let value = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
            value.minimumPressDuration = 0.45; value.allowableMovement = 12; value.delegate = self
            value.cancelsTouchesInView = true
            return value
        }()
        private lazy var secondary: UITapGestureRecognizer = {
            let value = UITapGestureRecognizer(target: self, action: #selector(clicked))
            value.buttonMaskRequired = .secondary; value.delegate = self
            return value
        }()
        func attach() {
            guard enabled, let anchor, anchor.window != nil else { detach(); return }
            var responder: UIResponder? = anchor
            var parent: UIView?
            while let current = responder {
                if let controller = current as? UIViewController { parent = controller.view; break }
                responder = current.next
            }
            guard let parent else { return }
            if host !== parent {
                detach(); host = parent
                parent.addGestureRecognizer(press); parent.addGestureRecognizer(secondary)
            }
            press.isEnabled = enabled; secondary.isEnabled = enabled
        }
        func detach() { host?.removeGestureRecognizer(press); host?.removeGestureRecognizer(secondary); host = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, let anchor, let window = anchor.window, let host, host.window === window else { return false }
            let rect = anchor.convert(anchor.bounds, to: window)
            guard rect.intersects(window.bounds), rect.contains(touch.location(in: window)) else { return false }
            var current: UIView? = anchor
            while let view = current {
                if view.isHidden || view.alpha < 0.01 { return false }
                current = view.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === press
        }
        @objc private func pressed() { if press.state == .began { open() } }
        @objc private func clicked() { if secondary.state == .ended { open() } }
    }
}

private struct AppConfirmation<Actions: View, Message: View>: ViewModifier {
    let title: String
    let titleVisibility: Visibility
    let showsCancel: Bool
    @Binding var isPresented: Bool
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let message: () -> Message
    @State private var height: CGFloat = 272
    @Environment(\.self) private var environment
    @Environment(\.ordinaryColorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var presentationEnvironment: EnvironmentValues {
        var result = environment
        result.colorScheme = scheme
        return result
    }
    func body(content: Content) -> some View {
        content.background {
            AnchoredChoicePresentation(isPresented: $isPresented, preferredHeight: height, reduceMotion: reduceMotion, centered: true) {
                AppMenuSurface(height: $height, dismiss: { isPresented = false }) {
                    VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                        if titleVisibility != .hidden {
                            Text(title).font(AppTypography.rowTitle.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                        message().font(AppTypography.supportingText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(FloatingPageChrome.cardInset)
                    Divider().padding(.horizontal, FloatingPageChrome.groupInset)
                    actions()
                    if showsCancel { Button("取消", role: .cancel) { isPresented = false } }
                }.environment(\.self, presentationEnvironment)
            }
        }
    }
}

extension View {
    func appConfirmationDialog<Actions: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, showsCancel: Bool = true,
                                              @ViewBuilder actions: @escaping () -> Actions) -> some View {
        modifier(AppConfirmation(title: title, titleVisibility: titleVisibility, showsCancel: showsCancel, isPresented: isPresented, actions: actions, message: { EmptyView() }))
    }
    func appConfirmationDialog<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, showsCancel: Bool = true,
                                                           @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder message: @escaping () -> Message) -> some View {
        modifier(AppConfirmation(title: title, titleVisibility: titleVisibility, showsCancel: showsCancel, isPresented: isPresented, actions: actions, message: message))
    }
}

/// Multi-selection uses the same shell/rows while keeping edits local until Apply.
struct AppMultiValueSelector<Value: Hashable, Label: View>: View {
    let title: String
    @Binding var selection: Set<Value>
    let options: [Value]
    let name: (Value) -> String
    @ViewBuilder let label: () -> Label
    @State private var expanded = false
    @State private var draft: Set<Value> = []
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = FloatingPageChrome.controlHeight
    var body: some View {
        Button { draft = selection; expanded = true } label: { label().environment(\.valueSelectorExpanded, expanded) }
            .accessibilityLabel(title)
            .background {
                AnchoredChoicePresentation(isPresented: $expanded,
                                           preferredHeight: rowHeight * CGFloat(min(options.count, ContentMetrics.Choice.visibleRows) + 1) + 8,
                                           reduceMotion: reduceMotion) {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(options, id: \.self) { option in
                                    Button {
                                        if !draft.insert(option).inserted { draft.remove(option) }
                                    } label: {
                                        HStack(spacing: FloatingPageChrome.spacing) {
                                            Text(name(option)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: draft.contains(option) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: ContentMetrics.Icon.primary))
                                        }
                                        .font(AppTypography.rowTitle).padding(.horizontal, FloatingPageChrome.cardInset)
                                        .frame(height: rowHeight).contentShape(Rectangle())
                                        .foregroundStyle(draft.contains(option) ? Color.accentColor : .primary)
                                        .background(draft.contains(option) ? AppTheme.selectionFill(for: scheme) : .clear, in: FloatingPageChrome.surfaceShape(nested: true))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(name(option)).accessibilityAddTraits(draft.contains(option) ? .isSelected : [])
                                    .accessibilityValue(draft.contains(option) ? "已选" : "未选")
                                    .accessibilityIdentifier("collections.folder.\(String(describing: option))")
                                }
                            }
                        }
                        Divider()
                        Button("应用") { selection = draft; expanded = false }
                            .font(AppTypography.rowTitle).frame(maxWidth: .infinity).frame(height: rowHeight)
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(draft.isEmpty)
                            .accessibilityIdentifier("collections.apply-folders")
                    }
                    .padding(FloatingPageChrome.groupInset)
                    .background(AppTheme.pageBackground(for: scheme), in: FloatingPageChrome.controlShape)
                    .overlay { FloatingPageChrome.controlShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: ContentMetrics.Optical.hairline) }
                    .environment(\.self, environment)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("app-multi-selector.options")
                }
            }
            .onChange(of: enabled) { _, value in if !value { expanded = false } }
            .onChange(of: options) { _, _ in expanded = false }
    }
}

/// Share presentation belongs to the source window, not the transient menu host.
struct AppMenuShareLink<Label: View>: View {
    private let prepare: @MainActor () async -> URL?
    private let onFinish: @MainActor (URL) -> Void
    private let label: () -> Label
    init(item: URL, @ViewBuilder label: @escaping () -> Label) {
        self.prepare = { item }
        self.onFinish = { _ in }
        self.label = label
    }
    init(prepare: @escaping @MainActor () async -> URL?, onFinish: @escaping @MainActor (URL) -> Void = { _ in }, @ViewBuilder label: @escaping () -> Label) {
        self.prepare = prepare
        self.onFinish = onFinish
        self.label = label
    }
    var body: some View {
        Button {
            // Capture the stable window before the menu dismisses or async
            // preparation yields. The transient menu host never owns sharing.
            guard let owner = AppFloatingOwnership.current, let window = owner.sourceWindow else { return }
            let sourceRect = owner.sourceRect
            Task { @MainActor in
                guard let item = await prepare() else { return }
                guard !window.isHidden, window.windowScene?.activationState == .foregroundActive else { onFinish(item); return }
                let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
                activity.completionWithItemsHandler = { _, _, _, _ in
                    Task { @MainActor in onFinish(item) }
                }
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = window
                    popover.sourceRect = sourceRect
                }
                var presenter = window.rootViewController
                while let next = presenter?.presentedViewController, !next.isBeingDismissed { presenter = next }
                guard presenter?.viewIfLoaded?.window === window, presenter?.presentedViewController == nil else { onFinish(item); return }
                presenter?.present(activity, animated: true)
            }
        } label: { label() }
    }
}

/// A URL command uses the same actionable row as other menu commands.
struct AppMenuLink<Label: View>: View {
    let destination: URL
    @ViewBuilder let label: () -> Label
    @Environment(\.openURL) private var openURL
    var body: some View { Button { openURL(destination) } label: { label() } }
}
