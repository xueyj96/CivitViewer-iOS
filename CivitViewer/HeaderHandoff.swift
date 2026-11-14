import SwiftUI
import UIKit

/// Keep page replacement separate from the shared chrome animation.
@MainActor
func withoutPageAnimation(_ changes: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction, changes)
}

/// One monotonic color clock per visual flight. Suspended clocks keep every
/// consumer at the source color until the destination's frame barrier is ready.
@MainActor @Observable
final class PageToneClock {
    private(set) var startedAt: CFTimeInterval?
    private(set) var finished = false
    private var starts: [UUID: () -> Void] = [:]
    private var interactiveProgress: Double?
    private var resumedProgress = 0.0

    init(suspended: Bool = false) { if !suspended { startedAt = CACurrentMediaTime() } }
    var progress: Double {
        if finished { return 1 }
        if let interactiveProgress { return interactiveProgress }
        guard let startedAt else { return resumedProgress }
        let duration = max(0.001, (1 - resumedProgress) * PageToneTransition.duration)
        return resumedProgress + (1 - resumedProgress) * UnitCurve.easeInOut.value(at: min(1, max(0, (CACurrentMediaTime() - startedAt) / duration)))
    }
    var remaining: Double {
        guard !finished else { return 0 }
        if let interactiveProgress { return (1 - interactiveProgress) * PageToneTransition.duration }
        guard let startedAt else { return (1 - resumedProgress) * PageToneTransition.duration }
        return max(0, (1 - resumedProgress) * PageToneTransition.duration - (CACurrentMediaTime() - startedAt))
    }
    func start() {
        guard startedAt == nil, !finished else { return }
        resumedProgress = interactiveProgress ?? resumedProgress
        interactiveProgress = nil
        startedAt = CACurrentMediaTime()
        notifyStart()
    }
    func setInteractiveProgress(_ value: Double) {
        guard !finished else { return }
        interactiveProgress = min(1, max(0, value))
        startedAt = nil
    }
    func finish() { finished = true; notifyStart() }
    func whenStarted(_ action: @escaping () -> Void) -> (() -> Void)? {
        guard startedAt == nil, !finished else { action(); return nil }
        let id = UUID(); starts[id] = action
        return { [weak self] in self?.starts.removeValue(forKey: id) }
    }
    private func notifyStart() {
        let actions = Array(starts.values); starts.removeAll()
        actions.forEach { $0() }
    }
}

@MainActor
struct PageToneTransition: Identifiable {
    let id = UUID()
    let source: Color
    let sourceScheme: ColorScheme?
    let sourceIsMedia: Bool
    let destinationScheme: ColorScheme?
    let destinationIsMedia: Bool?
    let headerCanvasBand: CGRect?
    let initialOpacity: Double
    let clock: PageToneClock

    static let duration = 0.30
    static let defaultOpacity = 1.0

    init(source: Color, initialOpacity: Double = Self.defaultOpacity,
         sourceScheme: ColorScheme? = nil, sourceIsMedia: Bool = false, suspended: Bool = false, headerCanvasBand: CGRect? = nil,
         destinationScheme: ColorScheme? = nil, destinationIsMedia: Bool? = nil) {
        self.source = source
        self.sourceScheme = sourceScheme
        self.sourceIsMedia = sourceIsMedia
        self.destinationScheme = destinationScheme
        self.destinationIsMedia = destinationIsMedia
        self.headerCanvasBand = headerCanvasBand
        self.initialOpacity = initialOpacity
        clock = PageToneClock(suspended: suspended)
    }
    func reversed(from source: Color, sourceScheme: ColorScheme? = nil, sourceIsMedia: Bool = false) -> Self {
        Self(source: source, initialOpacity: 1 - initialOpacity * (1 - clock.progress), sourceScheme: sourceScheme, sourceIsMedia: sourceIsMedia)
    }
}

extension EnvironmentValues {
    @Entry var pageSurfaceTone: PageToneTransition? = nil
    @Entry var pageCanvasRole: PageCanvasRole = .ordinary
}

/// Readers use the flight's elapsed time, never a fresh animation on mount.
struct PageToneBlend: View {
    let tone: PageToneTransition
    var coversSafeArea = true
    var onComplete: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completed = false

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: reduceMotion)) { _ in
            let progress = reduceMotion ? 1 : tone.clock.progress
            tone.source.opacity(tone.initialOpacity * (1 - progress))
                .ignoresSafeArea(edges: coversSafeArea ? .all : [])
                .onChange(of: progress >= 1, initial: true) { _, done in
                    if done && !completed { completed = true; onComplete?() }
                }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A description rendered into noninteractive pixels for a header transition.
struct HeaderAppearance {
    let controls: AnyView
    var snapshotControls: UIView? = nil
    var hasCompositedHeaderSnapshot = false
    let firstRowHeight: CGFloat
    let colorScheme: ColorScheme
    let surfaceColor: Color
    let borderColor: Color
    var surfaceHeight: CGFloat? = nil
    var environment: EnvironmentValues? = nil
    var layoutIdentity: AnyHashable? = nil
    var canvasRole: PageCanvasRole = .ordinary
    /// The page owns this space independently of the fixed header's frame.
    var contentClearance: CGFloat? = nil
    var retainsViewport = false
    var contentOwner: UUID? = nil
}

struct HeaderContent {
    let frame: CGRect
    let appearance: HeaderAppearance
}

/// Owns the visual sequence for both tab switches and UIKit navigation.
/// Callers own the lifetime and decide when the incoming page is ready.
@MainActor
@Observable
final class HeaderHandoff {
    enum Phase: String { case holding, retiringLowerRow, resizing, replacingControls, finished }
    private(set) var phase: Phase = .holding
    private(set) var source: HeaderContent
    let isLayoutChange: Bool
    private(set) var sourceControls: UIImage?
    private(set) var destinationControls: UIImage?
    private(set) var destination: HeaderContent?
    private(set) var surfaceDestination: HeaderContent?
    private(set) var stagedControls: UIImage?
    private(set) var stagedTarget: HeaderContent?
    private(set) var height: CGFloat
    private(set) var destinationRowOpacity = 0.0
    private(set) var destinationSurfaceOpacity = 0.0
    private(set) var destinationLowerRowsOpacity = 0.0
    private(set) var sourceLowerRowsOpacity = 1.0
    private struct ContentLayoutTarget: Equatable {
        let owner: UUID
        let clearance: CGFloat
        let height: CGFloat
        let retainsViewport: Bool
        let ordinary: Bool
    }
    private var contentLayoutTarget: ContentLayoutTarget?
    private var preservesDestinationViewport = false

    func stageContentLayout(_ incoming: HeaderContent, preservesViewport: Bool) {
        guard !isLayoutChange, let owner = incoming.appearance.contentOwner,
              owner != source.appearance.contentOwner, let clearance = incoming.appearance.contentClearance else { return }
        let target = ContentLayoutTarget(owner: owner, clearance: clearance, height: incoming.frame.height,
                                         retainsViewport: incoming.appearance.retainsViewport,
                                         ordinary: incoming.appearance.canvasRole == .ordinary)
        if (phase == .holding || contentLayoutTarget?.owner != owner), contentLayoutTarget != target {
            contentLayoutTarget = target
        }
        preservesDestinationViewport = preservesViewport
    }

    func contentClearance(for owner: UUID) -> CGFloat? {
        guard !preservesDestinationViewport, let target = contentLayoutTarget,
              target.owner == owner, target.ordinary, !target.retainsViewport,
              let from = source.appearance.contentClearance else { return nil }
        let delta = target.height - source.frame.height
        guard abs(delta) > 1 else { return nil }
        let progress = min(1, max(0, (height - source.frame.height) / delta))
        return from + (target.clearance - from) * progress
    }
    private var frameBoundary: RenderFrameBoundary?
    private var tone: PageToneTransition?
    private var cancelToneWait: (() -> Void)?
    private var animator: RenderProgressAnimation?
    private var cancelled = false
    private var compositedReturnTarget: HeaderContent?
    private(set) var hasPreparedCanvas = false
    func usePreparedCanvas() { hasPreparedCanvas = true }
    private var waits: [UUID: CheckedContinuation<Void, Never>] = [:]

    init?(source: HeaderContent, isLayoutChange: Bool = false, tone: PageToneTransition? = nil) {
        guard let rendered = Self.renderControls(source) else { return nil }
        self.source = source
        self.tone = tone
        sourceControls = rendered
        self.isLayoutChange = isLayoutChange
        height = source.frame.height
    }

    var surfaceTone: PageToneTransition? { tone }
    private func canStageControls(_ incoming: HeaderContent) -> Bool {
        tone != nil && !isLayoutChange
            && (source.appearance.colorScheme != incoming.appearance.colorScheme || source.appearance.canvasRole != incoming.appearance.canvasRole)
            && abs(source.frame.width - incoming.frame.width) <= 2
            && abs(source.frame.height - incoming.frame.height) <= 1
            && abs(source.appearance.firstRowHeight - incoming.appearance.firstRowHeight) <= 1
    }
    private func clearStagedControls() { stagedControls = nil; stagedTarget = nil }
    private func visualTarget(_ candidate: HeaderContent) -> HeaderContent {
        guard let trusted = compositedReturnTarget,
              trusted.appearance.canvasRole == candidate.appearance.canvasRole,
              trusted.appearance.colorScheme == candidate.appearance.colorScheme,
              trusted.appearance.layoutIdentity == candidate.appearance.layoutIdentity,
              abs(trusted.frame.width - candidate.frame.width) <= 2,
              abs(trusted.frame.height - candidate.frame.height) <= 1 else { return candidate }
        return HeaderContent(frame: candidate.frame, appearance: trusted.appearance)
    }
    func stageSurface(_ candidate: HeaderContent) {
        let incoming = visualTarget(candidate)
        surfaceDestination = incoming
        guard canStageControls(incoming) else { clearStagedControls(); return }
        if let stagedTarget,
           stagedTarget.appearance.colorScheme != incoming.appearance.colorScheme
            || stagedTarget.appearance.canvasRole != incoming.appearance.canvasRole
            || stagedTarget.appearance.layoutIdentity != incoming.appearance.layoutIdentity {
            clearStagedControls()
        }
        guard stagedControls == nil else { return }
        stagedControls = Self.renderControls(incoming)
        if stagedControls != nil { stagedTarget = incoming }
    }
    /// Root flights stage both endpoints before motion and consume the body's
    /// progress directly. No second header animation starts after navigation.
    @discardableResult
    func stageRoot(_ incoming: HeaderContent) -> Bool {
        guard !cancelled, let rendered = Self.renderControls(incoming),
              abs(source.frame.width - incoming.frame.width) <= 2 else { return false }
        compositedReturnTarget = incoming.appearance.hasCompositedHeaderSnapshot ? incoming : nil
        clearStagedControls()
        surfaceDestination = incoming
        destination = incoming
        destinationControls = rendered
        updateRootProgress(0)
        return true
    }

    func updateRootProgress(_ value: Double) {
        guard let destination, !cancelled else { return }
        let p = min(1, max(0, value))
        withoutPageAnimation {
            height = source.frame.height + (destination.frame.height - source.frame.height) * p
            destinationRowOpacity = p
            destinationLowerRowsOpacity = p
            sourceLowerRowsOpacity = 1 - p
            destinationSurfaceOpacity = p
            phase = p >= 1 ? .finished : .replacingControls
        }
    }

    func discardTone() { tone?.clock.finish(); tone = nil; clearStagedControls() }

    func joinTone(_ tone: PageToneTransition?) {
        guard phase == .holding, destination == nil, !cancelled else { return }
        self.tone = tone
    }

    func continueFromDestination() {
        guard let destination else { return }
        phase = .holding
        source = destination
        sourceControls = destinationControls
        destinationControls = nil
        self.destination = nil
        surfaceDestination = nil
        clearStagedControls()
        destinationRowOpacity = 0
        destinationSurfaceOpacity = 0
        destinationLowerRowsOpacity = 0
        sourceLowerRowsOpacity = 1
    }

    @discardableResult
    func replace(with candidate: HeaderContent, while isCurrent: () -> Bool,
                 prepareBody: (() -> Bool)? = nil) async -> Bool {
        let incoming = visualTarget(candidate)
        guard isCurrent(), !cancelled, let rendered = Self.renderControls(incoming) else { return false }
        destinationControls = rendered
        if stagedControls != nil {
            if canStageControls(incoming) { stagedControls = rendered; stagedTarget = incoming }
            else { clearStagedControls() }
        }
        destination = incoming
        // Mount both row layers at their outgoing values before changing opacity.
        // A fresh SwiftUI layer has no previous value to animate from.
        await withCheckedContinuation { continuation in
            let id = UUID()
            waits[id] = continuation
            frameBoundary = RenderFrameBoundary { [weak self] in
                guard let self else { return }
                frameBoundary = nil
                waits.removeValue(forKey: id)?.resume()
            }
        }
        guard isCurrent(), !cancelled else { return false }
        guard prepareBody?() ?? true else { return false }
        if let tone, tone.clock.startedAt == nil, !tone.clock.finished {
            await withCheckedContinuation { continuation in
                let id = UUID(); waits[id] = continuation
                cancelToneWait = tone.clock.whenStarted { [weak self] in
                    self?.waits.removeValue(forKey: id)?.resume()
                }
            }
            cancelToneWait = nil
        }
        guard isCurrent(), !cancelled else { return false }
        let startHeight = height
        let endHeight = incoming.frame.height
        let changesTheme = source.appearance.colorScheme != incoming.appearance.colorScheme
        let changesHeight = abs(startHeight - endHeight) > 1
        let retireDuration = changesHeight && endHeight < startHeight ? 0.08 : 0
        let resizeDuration = changesHeight ? 0.18 : 0
        let controlsStart = retireDuration + resizeDuration
        let total = max(controlsStart + 0.14, tone?.clock.remaining ?? (changesTheme ? PageToneTransition.duration : 0))
        let resizeCurve = UnitCurve.bezier(startControlPoint: .init(x: 0.22, y: 0.8),
                                           endControlPoint: .init(x: 0.32, y: 1))
        await withCheckedContinuation { continuation in
            let id = UUID()
            waits[id] = continuation
            // This frame clock owns settlement. SwiftUI animation completion
            // can be withheld by an unrelated transaction in a TabView.
            self.animator = RenderProgressAnimation(duration: total) { [weak self] elapsed in
                guard let self, !self.cancelled else { return }
                withoutPageAnimation {
                    let controls = UnitCurve.easeInOut.value(at: min(1, max(0, (elapsed - controlsStart) / 0.14)))
                    if elapsed < retireDuration { self.phase = .retiringLowerRow }
                    else if elapsed < controlsStart { self.phase = .resizing }
                    else { self.phase = .replacingControls }
                    if changesHeight {
                        let fraction = resizeCurve.value(at: min(1, max(0, (elapsed - retireDuration) / resizeDuration)))
                        self.height = startHeight + (endHeight - startHeight) * fraction
                    }
                    self.destinationRowOpacity = controls
                    self.destinationLowerRowsOpacity = controls
                    self.sourceLowerRowsOpacity = retireDuration > 0
                        ? 1 - UnitCurve.easeOut.value(at: min(1, elapsed / retireDuration))
                        : 1 - controls
                    self.destinationSurfaceOpacity = self.tone?.clock.progress ?? (changesTheme
                        ? UnitCurve.easeInOut.value(at: min(1, elapsed / PageToneTransition.duration))
                        : controls)
                }
            } completion: { [weak self] in
                guard let self else { return }
                self.animator = nil
                if !self.cancelled { self.phase = .finished }
                self.waits.removeValue(forKey: id)?.resume()
            }
        }
        return isCurrent() && !cancelled
    }

    static func renderControls(_ header: HeaderContent) -> UIImage? {
        #if DEBUG && targetEnvironment(simulator)
        let performanceStart = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.arguments.contains("--qa-transition-performance") {
                NSLog("TRANSITION_PERF headerRaster_ms=\((CACurrentMediaTime() - performanceStart) * 1000)")
            }
        }
        #endif
        var environment = header.appearance.environment ?? EnvironmentValues()
        environment.isHeaderRasterPreview = true
        let controls = header.appearance.controls.environment(\.self, environment)
        let renderer = ImageRenderer(content: controls
            .frame(width: header.frame.width, height: header.frame.height, alignment: .top)
            .environment(\.colorScheme, header.appearance.colorScheme))
        renderer.proposedSize = ProposedViewSize(width: header.frame.width, height: header.frame.height)
        renderer.scale = max(1, header.appearance.environment?.displayScale ?? 1)
        return renderer.uiImage
    }

    #if DEBUG && targetEnvironment(simulator)
    static func qaPixelSignature(_ image: UIImage?) -> String {
        guard let cg = image?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return "unavailable" }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return [(0.37, 0.25), (0.62, 0.25), (0.05, 0.25)].map { x, y in
            let i = min(cg.height - 1, Int(Double(cg.height) * y)) * cg.width * 4
                + min(cg.width - 1, Int(Double(cg.width) * x)) * 4
            return (0..<4).map { String(bytes[i + $0]) }.joined(separator: ",")
        }.joined(separator: "|")
    }
    #endif

    /// Call after invalidating ownership so resumed tasks cannot restart a flight.
    func cancel() {
        if phase != .finished { cancelled = true }
        animator?.cancel(); animator = nil
        cancelToneWait?(); cancelToneWait = nil
        frameBoundary?.cancel(); frameBoundary = nil
        let pending = Array(waits.values)
        waits.removeAll()
        pending.forEach { $0.resume() }
    }

}

struct HeaderHandoffView: View {
    let handoff: HeaderHandoff

    var body: some View {
        let source = handoff.source
        let destination = handoff.destination
        let firstRow = source.appearance.firstRowHeight
        let destinationRow = destination?.appearance.firstRowHeight ?? firstRow

        ZStack(alignment: .top) {
            // The surface changes size as one shape. The row opacity below
            // never applies to the surface or to the incoming lower rows.
            SwiftUI.TimelineView(.animation(paused: handoff.surfaceTone == nil)) { _ in
                let target = handoff.surfaceDestination ?? destination
                let progress = handoff.surfaceTone?.clock.progress ?? handoff.destinationSurfaceOpacity
                let returnCanvas = handoff.surfaceTone.flatMap { tone -> Color? in
                    guard let media = tone.destinationIsMedia, let scheme = tone.destinationScheme else { return nil }
                    if handoff.hasPreparedCanvas || target?.appearance.hasCompositedHeaderSnapshot == true { return nil }
                    return media ? .black : AppTheme.pageBackground(for: scheme)
                }
                ZStack {
                    if let returnCanvas, let tone = handoff.surfaceTone {
                        returnCanvas
                        tone.source.opacity(1 - progress)
                    }
                    Rectangle().fill(PageBarPalette.mix(
                        UIColor(source.appearance.surfaceColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: source.appearance.colorScheme == .dark ? .dark : .light)),
                        UIColor(target?.appearance.surfaceColor ?? source.appearance.surfaceColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: (target?.appearance.colorScheme ?? source.appearance.colorScheme) == .dark ? .dark : .light)), progress))
                }
            }
            if let tone = handoff.surfaceTone, let staged = handoff.stagedControls,
               let target = handoff.stagedTarget {
                // Same geometry: crossfade noninteractive pixels now, but keep
                // the flight and real controls pinned until UIKit has finished.
                SwiftUI.TimelineView(.animation) { _ in
                    let progress = tone.clock.progress
                    ZStack(alignment: .top) {
                        rows(target, image: staged).opacity(progress)
                        rows(source, image: handoff.sourceControls).opacity(1 - progress)
                    }
                }
            } else {
                if let destination {
                    rows(destination, image: handoff.destinationControls)
                        .mask(alignment: .top) {
                            Rectangle().padding(.top, destinationRow)
                        }
                        .opacity(handoff.destinationLowerRowsOpacity)
                    rows(destination, image: handoff.destinationControls)
                        .mask(alignment: .top) { Rectangle().frame(height: destinationRow) }
                        .opacity(handoff.destinationRowOpacity)
                }
                rows(source, image: handoff.sourceControls)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: destination == nil ? source.frame.height : firstRow)
                    }
                    .opacity(1 - handoff.destinationRowOpacity)
                if destination != nil {
                    rows(source, image: handoff.sourceControls)
                        .mask(alignment: .top) { Rectangle().padding(.top, firstRow) }
                        .opacity(handoff.sourceLowerRowsOpacity)
                }
            }
        }
        .frame(width: source.frame.width, height: handoff.height, alignment: .top)
        #if DEBUG && targetEnvironment(simulator)
        .background {
            if ProcessInfo.processInfo.arguments.contains("--qa-header-motion") {
                HeaderMotionGeometrySampler(handoff: handoff)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        #endif
        .clipShape(FloatingPageChrome.controlShape)
        .overlay {
            SwiftUI.TimelineView(.animation(paused: handoff.surfaceTone == nil)) { _ in
                let target = handoff.surfaceDestination ?? destination
                let progress = handoff.surfaceTone?.clock.progress ?? handoff.destinationSurfaceOpacity
                ZStack {
                    FloatingPageChrome.controlShape.strokeBorder(source.appearance.borderColor, lineWidth: 0.5)
                        .environment(\.colorScheme, source.appearance.colorScheme).opacity(1 - progress)
                    FloatingPageChrome.controlShape.strokeBorder(target?.appearance.borderColor ?? .clear, lineWidth: 0.5)
                        .environment(\.colorScheme, target?.appearance.colorScheme ?? source.appearance.colorScheme).opacity(progress)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
        .onDisappear { handoff.cancel() }
    }

    private func rows(_ header: HeaderContent, image: UIImage?) -> some View {
        Group {
            if let snapshot = header.appearance.snapshotControls {
                HeaderSnapshotControls(snapshot: snapshot, fallback: image)
            } else if let image {
                Image(uiImage: image).resizable()
            }
        }
        .frame(width: header.frame.width, height: header.frame.height, alignment: .top)
    }
}

/// Mounts a detached UIKit snapshot as inert pixels. If another flight already
/// owns the cached view, leave it where it is and use the canonical image.
private struct HeaderSnapshotControls: UIViewRepresentable {
    let snapshot: UIView
    let fallback: UIImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        updateUIView(container, context: context)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let coordinator = context.coordinator
        if let previous = coordinator.attachedSnapshot, previous !== snapshot, previous.superview === container {
            previous.removeFromSuperview()
        }
        coordinator.attachedSnapshot = nil
        if let fallbackView = coordinator.fallbackView, fallbackView.superview === container {
            fallbackView.removeFromSuperview()
        }
        coordinator.fallbackView = nil

        if snapshot.superview == nil || snapshot.superview === container {
            if snapshot.superview == nil { container.addSubview(snapshot) }
            snapshot.frame = container.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            coordinator.attachedSnapshot = snapshot
        } else if let fallback {
            let fallbackView = UIImageView(image: fallback)
            fallbackView.frame = container.bounds
            fallbackView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            fallbackView.contentMode = .scaleToFill
            fallbackView.isUserInteractionEnabled = false
            fallbackView.accessibilityElementsHidden = true
            container.addSubview(fallbackView)
            coordinator.fallbackView = fallbackView
        }
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        if let snapshot = coordinator.attachedSnapshot, snapshot.superview === container {
            snapshot.removeFromSuperview()
        }
        if let fallback = coordinator.fallbackView, fallback.superview === container {
            fallback.removeFromSuperview()
        }
        coordinator.attachedSnapshot = nil
        coordinator.fallbackView = nil
    }

    @MainActor
    final class Coordinator {
        weak var attachedSnapshot: UIView?
        weak var fallbackView: UIImageView?
    }
}


#if DEBUG && targetEnvironment(simulator)
/// Samples a native view occupying the rendered handoff surface. The readback
/// is a separate UILabel in the window, so sampling never publishes SwiftUI
/// state into the navigation hierarchy under inspection.
private struct HeaderMotionGeometrySampler: UIViewRepresentable {
    let handoff: HeaderHandoff

    func makeCoordinator() -> Coordinator { Coordinator(handoff: handoff) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.handoff = handoff
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        var handoff: HeaderHandoff
        private weak var view: UIView?
        private var displayLink: CADisplayLink?
        private var readback: UILabel?
        private var sampledPhases: [String] = []
        private var samples = 0
        private var intermediate = 0
        private var blockedIntermediate = 0
        private var source: CGFloat
        private var target: CGFloat
        private var minimum: CGFloat = .infinity
        private var maximum: CGFloat = -.infinity
        private var topMinimum: CGFloat = .infinity
        private var topMaximum: CGFloat = -.infinity
        private var current: CGFloat = 0

        init(handoff: HeaderHandoff) {
            self.handoff = handoff
            source = handoff.source.frame.height
            target = source
        }
        func attach(_ view: UIView) {
            self.view = view
            let link = CADisplayLink(target: self, selector: #selector(sample))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        @objc private func sample() {
            guard let view, let window = view.window, view.bounds.height > 0 else { return }
            if readback?.superview !== window {
                readback?.removeFromSuperview()
                // Keep the last completed sample readable after the visual
                // handoff disappears, replacing it only on the next flight.
                window.subviews.filter { $0.accessibilityIdentifier == "header.layout-motion.qa" }.forEach { $0.removeFromSuperview() }
                let label = UILabel(frame: CGRect(x: window.safeAreaInsets.left + 1, y: window.safeAreaInsets.top + 1, width: 1, height: 1))
                label.text = "Header layout motion"
                label.textColor = .clear
                label.font = .systemFont(ofSize: 1)
                label.isUserInteractionEnabled = false
                label.isAccessibilityElement = true
                label.accessibilityIdentifier = "header.layout-motion.qa"
                label.accessibilityLabel = "Header layout motion"
                window.addSubview(label)
                readback = label
            }
            target = handoff.destination?.frame.height ?? source
            let layer = view.layer.presentation() ?? view.layer
            let frame = layer.convert(layer.bounds, to: window.layer)
            guard frame.height.isFinite, frame.height > 0 else { return }
            current = frame.height
            minimum = min(minimum, current)
            maximum = max(maximum, current)
            topMinimum = min(topMinimum, frame.minY)
            topMaximum = max(topMaximum, frame.minY)
            if sampledPhases.last != handoff.phase.rawValue { sampledPhases.append(handoff.phase.rawValue) }
            samples += 1
            if current > min(source, target) + 0.5, current < max(source, target) - 0.5 {
                intermediate += 1
                if PageInteractionShield.blocksNewTouches(in: window) { blockedIntermediate += 1 }
            }
            publish(phase: handoff.phase.rawValue)
        }
        private func publish(phase: String) {
            readback?.accessibilityValue = String(format: "source=%.3f;target=%.3f;current=%.3f;min=%.3f;max=%.3f;topMin=%.3f;topMax=%.3f;intermediate=%ld;blockedMid=%ld;samples=%ld;phase=%@;sequence=%@;sourceRaster=%ld;destinationRaster=%ld", source, target, current, minimum, maximum, topMinimum, topMaximum, intermediate, blockedIntermediate, samples, phase, sampledPhases.joined(separator: ">"), handoff.sourceControls == nil ? 0 : 1, handoff.destinationControls == nil ? 0 : 1)
        }
        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            publish(phase: handoff.phase.rawValue)
        }
    }
}
#endif

/// Wait for one rendered frame without assuming a particular refresh rate.
/// The display link retains this short-lived callback until it fires or cancels.
@MainActor
final class RenderFrameBoundary: NSObject {
    private var link: CADisplayLink?
    private var hasTicked = false
    private var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        guard hasTicked else { hasTicked = true; return }
        let action = action
        cancel()
        action?()
    }

    func cancel() {
        link?.invalidate(); link = nil
        action = nil
    }
}

/// A finite render timeline, not an input-unlock watchdog. Each frame renders
/// its own interpolated values; completion applies the exact terminal frame.
@MainActor
final class RenderProgressAnimation: NSObject {
    private var link: CADisplayLink?
    private let startedAt = CACurrentMediaTime()
    private let duration: Double
    private var update: ((Double) -> Void)?
    private var completion: (() -> Void)?

    init(duration: Double, update: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        self.duration = max(0, duration)
        self.update = update
        self.completion = completion
        super.init()
        update(0)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        let elapsed = min(duration, max(0, CACurrentMediaTime() - startedAt))
        update?(elapsed)
        if elapsed >= duration {
            let completed = completion
            cancel()
            completed?()
        }
    }

    func cancel() {
        link?.invalidate(); link = nil
        update = nil; completion = nil
    }
}
