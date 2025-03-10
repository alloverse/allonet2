import XCTest
import Combine
@testable import allonet2

public struct TestComponent: Component
{
    public var entityID: String
    public var radius: Double
}
public struct Test2Component: Component
{
    public var entityID: String
    public var thingie: Int
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

final class WorldChangeSetTests: XCTestCase
{
    
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
    }

    func testChangeSetCallbacks() throws
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
    
    func testChangeSetCreation()
    {
        let old = PlaceContents(revision: 1, entities: [
            "a": Entity(id: "a", ownerAgentId: ""),
            "b": Entity(id: "b", ownerAgentId: "")
        ], components: Components(lists: [
            TestComponent.componentTypeId: [
                "a": TestComponent(entityID: "a", radius: 5.0),
                "b": TestComponent(entityID: "b", radius: 5.0)
            ],
            Test2Component.componentTypeId: [
                "a": Test2Component(entityID: "a", thingie: 4)
            ]
        ]))
        
        let new = PlaceContents(revision: 2, entities: [
            "a": Entity(id: "a", ownerAgentId: ""),
            "c": Entity(id: "c", ownerAgentId: "")
        ], components: Components(lists: [
            TestComponent.componentTypeId: [
                "a": TestComponent(entityID: "a", radius: 6.0),
                "c": TestComponent(entityID: "c", radius: 7.0)
            ]
        ]))
        
        let diff = new.changeSet(from: old)
        
        var bRemoved = false
        var bCompRemoved = false
        var componentCategoryRemoved = false
        var aCompChanged = false
        var cAdded = false
        var cCompAdded = false
        
        print("New: \(new)\nOld: \(old)\nDiff: \(diff)\n")
        
        for change in diff.changes
        {
            switch change {
            case .entityRemoved(let e) where e.id == "b":
                bRemoved = true
            case .componentRemoved(let eid, let comp as TestComponent) where eid == "b" :
                XCTAssertEqual(comp.radius, 5.0)
                bCompRemoved = true
            case .componentRemoved(let eid, let comp as Test2Component) where eid == "a" :
                XCTAssertEqual(comp.thingie, 4)
                componentCategoryRemoved = true
            case .componentUpdated(let eid, let comp as TestComponent) where eid == "a":
                XCTAssertEqual(comp.radius, 6.0, "Component update didn't generate the expected change")
                aCompChanged = true
            case .entityAdded(let e) where e.id == "c":
                cAdded = true
            case .componentAdded(let eid, let comp as TestComponent) where eid == "c":
                XCTAssertEqual(comp.radius, 7.0, "Component update didn't generate the expected change")
                cCompAdded = true
            default: continue
            }
        }
        
        XCTAssertTrue(bRemoved)
        XCTAssertTrue(bCompRemoved)
        XCTAssertTrue(componentCategoryRemoved)
        XCTAssertTrue(aCompChanged)
        XCTAssertTrue(cAdded)
        XCTAssertTrue(cCompAdded)
    }
}
