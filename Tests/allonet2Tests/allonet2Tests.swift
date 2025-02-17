import XCTest
@testable import allonet2

public struct TestComponent: Component {
    public static var componentTypeId: String { "TestComponent" }
    
    public var entityID: String
    public var radius: Double
}

final class WorldCodableTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        ComponentRegistry.shared.register(TestComponent.self)
    }
    
    func testWorldEncodingDecoding() throws {
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
