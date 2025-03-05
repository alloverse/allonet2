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
        var world = World()
        world.revision = 1
        world.entities[entity.id] = entity
        world.components[TestComponent.componentTypeId] = [test]
        
        // Encode the world to JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(world)
        
        // Decode the JSON back into a World instance.
        let decoder = JSONDecoder()
        let decodedWorld = try decoder.decode(World.self, from: data)
        
        // Assert that the original and decoded worlds are equal.
        XCTAssertEqual(world, decodedWorld, "The decoded World should equal the original World.")
    }
}

final class WorldComponentsContainerTests: XCTestCase
{
    
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
    }
    
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
}
