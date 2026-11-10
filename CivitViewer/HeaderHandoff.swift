import SwiftUI

/// Keep page replacement separate from the shared chrome animation.
@MainActor
func withoutPageAnimation(_ changes: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction, changes)
}

struct PageToneTransition: Identifiable {
    let id = UUID()
    let source: Color
    let initialOpacity: Double
    private let startedAt = ContinuousClock.now

    static let duration = 0.26
    static let defaultOpacity = 0.88
    static let animation = Animation.easeInOut(duration: duration)

    init(source: Color, initialOpacity: Double = Self.defaultOpacity) {
        self.source = source
        self.initialOpacity = initialOpacity
    }

    func reversed(from source: Color) -> Self {
        let elapsed = startedAt.duration(to: .now) / .seconds(Self.duration)
        let progress = UnitCurve.easeInOut.value(at: min(elapsed, 1))
        return Self(source: source, initialOpacity: 1 - initialOpacity * (1 - progress))
    }
}

/// Briefly blends the old surface tone into the destination in place.
struct PageToneBlend: View {
    let source: Color
    var coversSafeArea = true
    var initialOpacity = PageToneTransition.defaultOpacity
    var onComplete: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = 0.0

    var body: some View {
        source
            .opacity(reduceMotion ? 0 : initialOpacity * (1 - reveal))
            .ignoresSafeArea(edges: coversSafeArea ? .all : [])
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                if reduceMotion {
                    reveal = 1
                    onComplete?()
                } else {
                    withAnimation(PageToneTransition.animation, completionCriteria: .logicallyComplete) {
                        reveal = 1
                    } completion: {
                        onComplete?()
                    }
                }
            }
    }
}

/// A live, noninteractive copy of the controls for a header transition.
struct HeaderAppearance {
    let controls: AnyView
    let firstRowHeight: CGFloat
    let colorScheme: ColorScheme
    let surfaceColor: Color
    let borderColor: Color
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
    let source: HeaderContent
    private(set) var destination: HeaderContent?
    private(set) var height: CGFloat
    private(set) var showsDestinationRow = false
    private(set) var showsDestinationSurface = false

    init(source: HeaderContent) {
        self.source = source
        height = source.frame.height
    }

    func replace(with incoming: HeaderContent, while isCurrent: () -> Bool) async {
        guard isCurrent() else { return }
        destination = incoming
        let changesTheme = source.appearance.colorScheme != incoming.appearance.colorScheme
        let changesHeight = abs(height - incoming.frame.height) > 1
        let surfaceDeadline = ContinuousClock.now + .seconds(PageToneTransition.duration)
            + .milliseconds(16)
        if changesTheme {
            withAnimation(PageToneTransition.animation) { showsDestinationSurface = true }
        }
        if changesHeight {
            let resizeDuration = changesTheme ? 100 : 160
            withAnimation(.easeInOut(duration: Double(resizeDuration) / 1_000)) {
                height = incoming.frame.height
            }
            // Layout can register its animation on the next display update.
            try? await Task.sleep(for: .milliseconds(resizeDuration + 16))
            guard isCurrent() else { return }
        }

        let rowDuration = changesHeight && !changesTheme ? 0.14 : 0.08
        await withCheckedContinuation { continuation in
            withAnimation(.easeInOut(duration: rowDuration), completionCriteria: .logicallyComplete) {
                showsDestinationRow = true
                if !changesTheme { showsDestinationSurface = true }
            } completion: {
                continuation.resume()
            }
        }
        if changesTheme && isCurrent() {
            try? await Task.sleep(until: surfaceDeadline, clock: .continuous)
        }
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
            Rectangle().fill(source.appearance.surfaceColor)
            Rectangle().fill(destination?.appearance.surfaceColor ?? source.appearance.surfaceColor)
                .opacity(handoff.showsDestinationSurface ? 1 : 0)
            if let destination {
                rows(destination)
                    .mask(alignment: .top) {
                        Rectangle().padding(.top, destinationRow)
                    }
                rows(destination)
                    .mask(alignment: .top) { Rectangle().frame(height: destinationRow) }
                    .opacity(handoff.showsDestinationRow ? 1 : 0)
            }
            rows(source)
                .mask(alignment: .top) {
                    Rectangle().frame(height: destination == nil ? source.frame.height : firstRow)
                }
                .opacity(handoff.showsDestinationRow ? 0 : 1)
            if let destination, destination.frame.height < source.frame.height, !handoff.showsDestinationRow {
                rows(source)
                    .mask(alignment: .top) { Rectangle().padding(.top, firstRow) }
            }
        }
        .frame(width: source.frame.width, height: handoff.height, alignment: .top)
        .clipShape(FloatingPageChrome.controlShape)
        .overlay {
            FloatingPageChrome.controlShape.strokeBorder(source.appearance.borderColor, lineWidth: 0.5)
                .opacity(handoff.showsDestinationSurface ? 0 : 1)
            FloatingPageChrome.controlShape.strokeBorder(destination?.appearance.borderColor ?? .clear, lineWidth: 0.5)
                .opacity(handoff.showsDestinationSurface ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rows(_ header: HeaderContent) -> some View {
        header.appearance.controls
            .frame(width: header.frame.width,
                   height: header.frame.height, alignment: .top)
    }
}
