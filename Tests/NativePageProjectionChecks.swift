import Foundation
import Observation

// A display payload double lets this focused macOS check compile the production
// publication model without starting UIKit, a simulator or any media.
struct AnyView { let value: Int }
@MainActor final class PublicationCounts { var values = [0, 0, 0] }
// INSERT_PROJECTION
// INSERT_PRESENTATION

@main struct NativePageProjectionChecks {
    struct Input: Equatable { var id: Int; var active: Bool; var preview = 0 }
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let first = Input(id: 1, active: false), second = Input(id: 2, active: true), third = Input(id: 3, active: false)
        let models = [first, second, third].map { NativePagePresentation(input: NativeMediaPageProjection($0), content: AnyView(value: $0.id)) }
        let publications = PublicationCounts()
        var renders = [0, 0, 0]
        for (index, model) in models.enumerated() {
            withObservationTracking { _ = model.content } onChange: { MainActor.assumeIsolated { publications.values[index] += 1 } }
        }
        for _ in 0..<60 {
            for (index, input) in [first, second, third].enumerated() {
                models[index].update(input: NativeMediaPageProjection(input)) { renders[index] += 1; return AnyView(value: input.id) }
            }
        }
        check(publications.values == [0, 0, 0] && renders == [0, 0, 0], "Identical inputs, callback refreshes and queue appends publish and rebuild no pages")
        let nextInputs = [first, Input(id: 2, active: false), Input(id: 3, active: true)]
        for (index, input) in nextInputs.enumerated() {
            models[index].update(input: NativeMediaPageProjection(input)) { renders[index] += 1; return AnyView(value: input.id) }
        }
        check(publications.values == [0, 1, 1] && renders == [0, 1, 1], "Settlement updates only the old and new active page, preserving the other neighbor")
        var preview = nextInputs[2]; preview.preview = 1
        withObservationTracking { _ = models[2].content } onChange: { MainActor.assumeIsolated { publications.values[2] += 1 } }
        models[2].update(input: NativeMediaPageProjection(preview)) { renders[2] += 1; return AnyView(value: 30) }
        check(publications.values == [0, 1, 2] && models[2].content.value == 30, "A decoded preview updates only its owning page")
        check(NativeMediaPageProjection(first) != NativeMediaPageProjection(1), "Different concrete projection types never compare equal")
        print("NativePageProjectionChecks: \(checks) regression checks passed")
    }
}
