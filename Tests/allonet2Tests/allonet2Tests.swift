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
    
    func testWorldEncodingDecoding() throws
    {
        // Create a sample entity.
        let entity = Entity(id: "entity1", ownerAgentId: "agentA")
        
        // Create a sample ColliderComponent.
        let test = TestComponent(entityID: "entity1", radius: 5.0)
        
        // Create a World instance containing the entity and the collider component.
        var place = PlaceContents(
            revision: 1,
            entities: [ entity.id: entity],
            components: Components(lists:[
                TestComponent.componentTypeId: [test.entityID: test]
            ])
        )
        
        // Encode the world to JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(place)
        
        // Decode the JSON back into a World instance.
        let decoder = JSONDecoder()
        let decodedPlace = try decoder.decode(PlaceContents.self, from: data)
        
        // Assert that the original and decoded worlds are equal.
        XCTAssertEqual(place, decodedPlace, "The decoded World should equal the original World.")
    }
}

final class WorldDeltaTests: XCTestCase
{
    
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
    }

    func testDeltas() throws
    {
        var cancellables: [AnyCancellable] = []
        let state = PlaceState()
        state.changeSet = PlaceChangeSet(changes: [
            .entityAdded(Entity(id: "entity1", ownerAgentId: "")),
            .componentAdded("entity1", TestComponent(entityID: "entity1", radius: 5.0)),
            .componentUpdated("entity1", TestComponent(entityID: "entity1", radius: 6.0))
        ])
        var entityAddedReceived = false
        var componentAddedReceived = false
        var componentUpdatedReceived = false
        
        state.observers.entityAdded.sink { e in
            entityAddedReceived = true
        }.store(in: &cancellables)
        state.observers[TestComponent.self].added.sink { comp in
            XCTAssertEqual(comp.radius, 5.0, "Expected initial value to be correct")
            componentAddedReceived = true
        }.store(in: &cancellables)
        state.observers[TestComponent.self].updated.sink { comp in
            XCTAssertEqual(comp.radius, 6.0, "Expected updated value to be correct")
            componentUpdatedReceived = true
        }.store(in: &cancellables)
        
        state.callChangeObservers()
        XCTAssertTrue(entityAddedReceived, "Expected entity added to fire")
        XCTAssertTrue(componentAddedReceived, "Expected new component event to fire")
        XCTAssertTrue(componentUpdatedReceived, "Expected updated component event to fire")
        
    }
}
