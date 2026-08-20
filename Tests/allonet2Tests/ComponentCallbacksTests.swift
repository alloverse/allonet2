import Testing
import Foundation
import OpenCombineShim
@testable import allonet2

/// The *WithInitial publishers carry two obligations that have each regressed once:
/// the snapshot must be captured per subscription (a re-subscriber after a reconnection
/// must see the current place, not the first subscriber's), and repeated property access
/// must return the identical instance (SwiftUI's `onReceive` resubscribes — replaying the
/// snapshot into `@State`, re-rendering forever — whenever the publisher changes identity).
@MainActor
struct ComponentCallbacksTests
{
    let state: PlaceState
    var cancellables = Set<AnyCancellable>()

    init()
    {
        TestComponent.register()
        state = PlaceState(logger: testLogger)
    }

    private func setCurrent(_ components: [EntityID: TestComponent])
    {
        state.current = PlaceContents(
            revision: state.current.revision + 1,
            entities: Dictionary(uniqueKeysWithValues: components.keys.map { ($0, EntityData(id: $0, ownerClientId: UUID())) }),
            components: ComponentLists(lists: [
                TestComponent.componentTypeId: components.mapValues { AnyComponent($0) }
            ]),
            logger: testLogger
        )
    }

    @Test mutating func snapshotIsCapturedPerSubscription() throws
    {
        // Build the publisher while the place is empty. A snapshot captured now is empty forever.
        let publisher = state.observers[TestComponent.self].updatedWithInitial

        setCurrent(["a": TestComponent(radius: 1.0)])
        var first: [(EntityID, TestComponent)] = []
        publisher.sink { first.append($0) }.store(in: &cancellables)
        try #require(first.count == 1)
        #expect(first[0].0 == "a")

        // The world a re-subscriber after a reconnection must see: b, and no trace of a.
        setCurrent(["b": TestComponent(radius: 2.0)])
        var second: [(EntityID, TestComponent)] = []
        publisher.sink { second.append($0) }.store(in: &cancellables)
        try #require(second.count == 1)
        #expect(second[0].0 == "b")
    }

    @Test func repeatedAccessReturnsTheSameInstance()
    {
        // Bitwise equality is what SwiftUI's onReceive uses to decide whether to resubscribe.
        let a = state.observers[TestComponent.self].updatedWithInitial
        let b = state.observers[TestComponent.self].updatedWithInitial
        #expect(withUnsafeBytes(of: a) { ab in withUnsafeBytes(of: b) { $0.elementsEqual(ab) } })

        let c = state.observers[TestComponent.self].addedWithInitial
        let d = state.observers[TestComponent.self].addedWithInitial
        #expect(withUnsafeBytes(of: c) { cd in withUnsafeBytes(of: d) { $0.elementsEqual(cd) } })
    }

    @Test mutating func liveEventsStillFlowAfterTheSnapshot()
    {
        setCurrent(["a": TestComponent(radius: 1.0)])
        var received: [(EntityID, TestComponent)] = []
        state.observers[TestComponent.self].updatedWithInitial
            .sink { received.append($0) }.store(in: &cancellables)
        #expect(received.count == 1)

        state.observers[TestComponent.self].sendUpdated(entityID: "a", component: AnyComponent(TestComponent(radius: 3.0)))
        #expect(received.count == 2)
        #expect(received.last?.1.radius == 3.0)
    }
}
