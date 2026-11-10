import SwiftUI

/// One shared track with two independently adjustable, non-crossing handles.
struct VideoDurationRangeControl: View {
    private enum DragStart {
        case ignored
        case handle(lower: Bool, index: Int)
    }

    @Binding var range: VideoDurationRange?
    @GestureState private var dragStart: DragStart?
    private let inset: CGFloat = 22
    private var value: VideoDurationRange { range ?? .init() }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    endpointMenu(lower: true).fixedSize()
                    Spacer(minLength: 8)
                    endpointMenu(lower: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    endpointMenu(lower: true)
                    endpointMenu(lower: false)
                }
            }
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 2 * inset)
                let finiteFraction = Double((width - min(52, width * 0.25)) / width)
                let lower = position(currentIndex(lower: true), width: width, finiteFraction: finiteFraction)
                let upper = position(currentIndex(lower: false), width: width, finiteFraction: finiteFraction)
                let finiteEnd = position(VideoDurationScale.finiteLastIndex, width: width, finiteFraction: finiteFraction)
                ZStack(alignment: .topLeading) {
                    Capsule().fill(.quaternary).frame(width: width, height: 4).offset(x: inset, y: 20)
                    Capsule().fill(Color.accentColor)
                        .frame(width: upper - lower, height: 4).offset(x: lower, y: 20)
                    Rectangle().fill(.secondary.opacity(0.65)).frame(width: 1, height: 8).position(x: finiteEnd, y: 22)
                    thumb(lower: true).position(x: lower, y: 22)
                    thumb(lower: false).position(x: upper, y: 22)
                }
                .frame(width: geometry.size.width, height: 44)
                .contentShape(Rectangle())
                .simultaneousGesture(drag(width: width, finiteFraction: finiteFraction))
            }.frame(height: 44)
        }
    }
    private func position(_ index: Int, width: CGFloat, finiteFraction: Double) -> CGFloat {
        inset + CGFloat(VideoDurationScale.fraction(for: index, finiteFraction: finiteFraction)) * width
    }
    private func moving(to index: Int, lower: Bool) -> VideoDurationRange {
        lower ? VideoDurationScale.movingLower(index, in: value) : VideoDurationScale.movingUpper(index, in: value)
    }
    private func currentIndex(lower: Bool) -> Int {
        lower ? VideoDurationScale.lowerIndex(value) : VideoDurationScale.upperIndex(value)
    }
    private func endpointMenu(lower: Bool) -> some View {
        let index = currentIndex(lower: lower)
        return Menu {
            Button(index == VideoDurationScale.terminalIndex ? "设为02:00" : "减少1秒") { range = moving(to: index - 1, lower: lower) }
                .disabled(moving(to: index - 1, lower: lower) == value)
            if index < VideoDurationScale.terminalIndex {
                Button(index == VideoDurationScale.finiteLastIndex ? (lower ? "超过02:00" : "不限") : "增加1秒") { range = moving(to: index + 1, lower: lower) }
                    .disabled(moving(to: index + 1, lower: lower) == value)
            }
            if index < VideoDurationScale.finiteLastIndex {
                Button(lower ? "超过02:00" : "不限") { range = moving(to: VideoDurationScale.terminalIndex, lower: lower) }
                    .disabled(lower && value.maximumSeconds != nil)
            }
        } label: {
            ZStack(alignment: lower ? .leading : .trailing) {
                // Size the whole label so the chevron stays next to the value.
                endpointLabel(lower: lower, title: lower ? "超过02:00" : "02:00").hidden().accessibilityHidden(true)
                if !lower { endpointLabel(lower: false, title: "不限").hidden().accessibilityHidden(true) }
                endpointLabel(lower: lower, title: lower ? value.minimumTitle : value.maximumTitle)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lower ? "微调最短视频时长" : "微调最长视频时长")
        .accessibilityValue(lower ? value.minimumTitle : value.maximumTitle)
        .accessibilityIdentifier(lower ? "duration.range.minimum.menu" : "duration.range.maximum.menu")
    }
    private func endpointLabel(lower: Bool, title: String) -> some View {
        HStack(spacing: 5) {
            Text(lower ? "最短" : "最长").foregroundStyle(.secondary)
            Text(title).fontWeight(.semibold).monospacedDigit().foregroundStyle(.primary)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }.font(.subheadline)
    }

    private func thumb(lower: Bool) -> some View {
        Circle().fill(.white).frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            .frame(width: 44, height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lower ? "最短视频时长" : "最长视频时长")
            .accessibilityIdentifier(lower ? "duration.range.minimum" : "duration.range.maximum")
            .accessibilityValue(lower ? value.minimumTitle : value.maximumTitle)
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 1 : -1
                range = moving(to: currentIndex(lower: lower) + delta, lower: lower)
            }
    }

    private func drag(width: CGFloat, finiteFraction: Double) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .updating($dragStart) { gesture, start, _ in
                if start == nil { start = chooseHandle(gesture, width: width, finiteFraction: finiteFraction) }
            }
            .onChanged { gesture in
                guard range != nil,
                      case let .handle(lower, start) = dragStart ?? chooseHandle(gesture, width: width, finiteFraction: finiteFraction) else { return }
                let x = position(start, width: width, finiteFraction: finiteFraction) + gesture.translation.width
                let index = VideoDurationScale.index(atFraction: Double((x - inset) / width), finiteFraction: finiteFraction)
                let updated = moving(to: index, lower: lower)
                if range != updated { range = updated }
            }
    }

    private func chooseHandle(_ gesture: DragGesture.Value, width: CGFloat, finiteFraction: Double) -> DragStart {
        guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return .ignored }
        let minimum = currentIndex(lower: true), maximum = currentIndex(lower: false)
        let lowerDistance = abs(gesture.startLocation.x - position(minimum, width: width, finiteFraction: finiteFraction))
        let upperDistance = abs(gesture.startLocation.x - position(maximum, width: width, finiteFraction: finiteFraction))
        guard min(lowerDistance, upperDistance) <= inset else { return .ignored }
        // At a shared point the outward drag identifies the bound to open.
        let lower = abs(lowerDistance - upperDistance) < 0.5 ? gesture.translation.width < 0 : lowerDistance < upperDistance
        return .handle(lower: lower, index: lower ? minimum : maximum)
    }
}
