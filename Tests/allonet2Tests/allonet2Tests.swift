import XCTest
import Combine
@testable import allonet2

public struct TestComponent: Component
{
    public var entityID: String
    public var radius: Double
}

final class WorldCodableTests: XCTestCase
{
    
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
    }
    /*
    func testWorldEncodingDecoding() throws
    {
        // Create a sample entity.
        let entity = Entity(id: "entity1", ownerAgentId: "agentA")
        
        // Create a sample ColliderComponent.
        let test = TestComponent(entityID: "entity1", radius: 5.0)
        
        // Create a World instance containing the entity and the collider component.
        var place = PlaceContents()
        place.revision = 1
        place.entities[entity.id] = entity
        place.components[TestComponent.componentTypeId] = [test]
        
        // Encode the world to JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(place)
        
        // Decode the JSON back into a World instance.
        let decoder = JSONDecoder()
        let decodedWorld = try decoder.decode(World.self, from: data)
        
        // Assert that the original and decoded worlds are equal.
        XCTAssertEqual(place, decodedWorld, "The decoded World should equal the original World.")
    }
    */
}

final class WorldDeltaTests: XCTestCase
{
    
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
    }

/*
    func testEvents() throws
    {
        let comps = ComponentsContainer()
        let set = comps[TestComponent.self]
        var cancellables: [AnyCancellable] = []
        
        var addedEventReceived = false
        set.added.sink { _ in
            addedEventReceived = true
        }.store(in: &cancellables)
        set.add(TestComponent(entityID: "entity1", radius: 5.0))
        XCTAssertTrue(addedEventReceived, "Expected added event to fire")
        
        var updatedEventReceived = false
        set.updated.sink { comp in
            XCTAssertEqual(comp.radius, 6.0, "Expected update to fire with new value")
            updatedEventReceived = true
        }.store(in: &cancellables)
        set.update(TestComponent(entityID: "entity1", radius: 6.0))
        XCTAssertTrue(updatedEventReceived, "Expected updated event to fire")
        
        var removedEventReceived = false
        set.removed.sink { _ in
            removedEventReceived = true
        }.store(in: &cancellables)
        set.remove(for: "entity1")
        XCTAssertTrue(removedEventReceived, "Expected removed event to fire")
    }
*/

    func testDeltas() throws
    {
        var cancellables: [AnyCancellable] = []
        let state = PlaceState()
        state.delta = PlaceDelta(events: [
            .entityAdded(Entity(id: "entity1", ownerAgentId: "")),
            .componentAdded("entity1", TestComponent(entityID: "entity1", radius: 5.0)),
            .componentUpdated("entity1", TestComponent(entityID: "entity1", radius: 6.0))
        ])
        var entityAddedReceived = false
        var componentAddedReceived = false
        var componentUpdatedReceived = false
        
        state.deltaCallbacks.entityAdded.sink { e in
            entityAddedReceived = true
        }.store(in: &cancellables)
        state.deltaCallbacks[TestComponent.self].added.sink { comp in
            XCTAssertEqual(comp.radius, 5.0, "Expected initial value to be correct")
            componentAddedReceived = true
        }.store(in: &cancellables)
        state.deltaCallbacks[TestComponent.self].updated.sink { comp in
            XCTAssertEqual(comp.radius, 6.0, "Expected updated value to be correct")
            componentUpdatedReceived = true
        }.store(in: &cancellables)
        
        state.sendDeltaCallbacks()
        XCTAssertTrue(entityAddedReceived, "Expected entity added to fire")
        XCTAssertTrue(componentAddedReceived, "Expected new component event to fire")
        XCTAssertTrue(componentUpdatedReceived, "Expected updated component event to fire")
        
    }
}
