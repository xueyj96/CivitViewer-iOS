import SwiftUI
import UIKit

// Matches the numbered thumb used by ExHViewer's loading settings.
struct PrefetchConcurrencySlider: UIViewRepresentable {
    private static let steps = MediaPrefetchConcurrency.steps

    @Binding var value: Int
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var scaledNumberSize: CGFloat = 13

    init(value: Binding<Int>) { _value = value }

    func makeUIView(context: Context) -> UISlider {
        let slider = NumberedSlider()
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.accessibilityIdentifier = "settings.prefetch-concurrency"
        slider.accessibilityLabel = "预载并发"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.finished(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.view = self
        if !slider.isTracking {
            slider.maximumValue = Float(Self.steps.count - 1)
            slider.value = position(for: value)
        }
        context.coordinator.updateThumb(slider, count: MediaPrefetchConcurrency.validated(value))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: FloatingPageChrome.controlHeight)
    }

    private func position(for count: Int) -> Float {
        let validated = MediaPrefetchConcurrency.validated(count)
        return Float(Self.steps.firstIndex(of: validated) ?? 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    private final class NumberedSlider: UISlider {
        override var intrinsicContentSize: CGSize {
            CGSize(width: super.intrinsicContentSize.width, height: FloatingPageChrome.controlHeight)
        }
        override func accessibilityIncrement() { moveOneStep(1) }
        override func accessibilityDecrement() { moveOneStep(-1) }

        private func moveOneStep(_ step: Float) {
            value = min(max(value.rounded() + step, minimumValue), maximumValue)
            sendActions(for: .valueChanged)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var view: PrefetchConcurrencySlider

        private struct Thumb: Equatable {
            let count: Int
            let numberSize: CGFloat
            let dark: Bool
        }

        private var thumb: Thumb?

        init(view: PrefetchConcurrencySlider) { self.view = view }

        @objc func changed(_ slider: UISlider) {
            let index = min(max(Int(slider.value.rounded()), 0), PrefetchConcurrencySlider.steps.count - 1)
            let count = PrefetchConcurrencySlider.steps[index]
            if view.value != count { view.value = count }
            updateThumb(slider, count: count)
        }

        @objc func finished(_ slider: UISlider) {
            changed(slider)
            slider.value = view.position(for: view.value)
        }

        func updateThumb(_ slider: UISlider, count: Int) {
            let next = Thumb(count: count, numberSize: min(22, view.scaledNumberSize), dark: view.colorScheme == .dark)
            guard thumb != next else { return }
            thumb = next
            let image = makeThumb(next)
            slider.setThumbImage(image, for: .normal)
            slider.setThumbImage(image, for: .highlighted)
            slider.accessibilityValue = "\(count) 路"
        }

        private func makeThumb(_ thumb: Thumb) -> UIImage {
            let faceHeight = max(30, thumb.numberSize + 16)
            let size = CGSize(width: max(40, thumb.numberSize * 2 + 16), height: max(FloatingPageChrome.controlHeight, faceHeight))
            let shape = CGRect(x: 3, y: (size.height - faceHeight) / 2 + 4,
                               width: size.width - 6, height: faceHeight - 8)
            let traits = UITraitCollection(userInterfaceStyle: thumb.dark ? .dark : .light)
            let fill = thumb.dark ? UIColor.tertiarySystemBackground.resolvedColor(with: traits) : .white
            let text = NSAttributedString(string: String(thumb.count), attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: thumb.numberSize, weight: .semibold),
                .foregroundColor: UIColor.label.resolvedColor(with: traits)
            ])
            return UIGraphicsImageRenderer(size: size).image { context in
                let outline = UIBezierPath(roundedRect: shape, cornerRadius: shape.height / 2)
                context.cgContext.saveGState()
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                                            color: UIColor.black.withAlphaComponent(0.20).cgColor)
                fill.setFill()
                outline.fill()
                context.cgContext.restoreGState()
                UIColor.separator.resolvedColor(with: traits).withAlphaComponent(0.24).setStroke()
                outline.lineWidth = 0.5
                outline.stroke()
                let textSize = text.size()
                text.draw(at: CGPoint(x: shape.midX - textSize.width / 2, y: shape.midY - textSize.height / 2))
            }.withRenderingMode(.alwaysOriginal)
        }
    }
}
