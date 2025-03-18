import XCTest
import Combine
@testable import allonet2

public struct TestComponent: Component
{
    public var radius: Double
}
public struct Test2Component: Component
{
    public var thingie: Int
}

final class PlaceCodableTests: XCTestCase
{
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
    }
    
    func testPlaceEncodingDecoding() throws
    {
        // Create a sample entity.
        let entity = Entity(id: "entity1", ownerAgentId: "agentA")
        
        // Create a sample ColliderComponent.
        let test = TestComponent(radius: 5.0)
        
        // Create a World instance containing the entity and the collider component.
        let place = PlaceContents(
            revision: 1,
            entities: [ entity.id: entity],
            components: Components(lists:[
                TestComponent.componentTypeId: [entity.id: test]
            ])
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(place)
        
        let decoder = JSONDecoder()
        let decodedPlace = try decoder.decode(PlaceContents.self, from: data)
        
        XCTAssertEqual(place, decodedPlace, "The decoded Place should equal the original Place.")
    }
}

final class PlaceChangeCodingTests: XCTestCase
{
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
        Test2Component.register()
    }
    
    func testChangeSetEncodingDecoding() throws
    {
        let changeSet = PlaceChangeSet(changes: [
            .entityAdded(Entity(id: "c", ownerAgentId: "")),
            .entityRemoved(Entity(id: "b", ownerAgentId: "")),
            .componentAdded("c", TestComponent(radius: 6.0)),
            .componentAdded("c", Test2Component(thingie: 3)),
            .componentUpdated("a", TestComponent(radius: 7.0)),
            .componentRemoved("b", TestComponent(radius: 5.0))
        ], fromRevision: 0, toRevision: 1)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(changeSet)
        
        let decoder = JSONDecoder()
        let decodedChangeSet = try decoder.decode(PlaceChangeSet.self, from: data)
        
        XCTAssertEqual(changeSet, decodedChangeSet, "The decoded ChangeSet should equal the original ChangeSet.")
        XCTAssertEqual(decodedChangeSet.toRevision, 1, "Unexpected revision number in decoded ChangeSet.")
        
    }
}

final class PlaceChangeSetTests: XCTestCase
{
    
    override func setUp()
    {
        super.setUp()
        TestComponent.register()
    }

    func testChangeSetCallbacks() throws
    {
        var cancellables = Set<AnyCancellable>()
        let state = PlaceState()
        state.changeSet = PlaceChangeSet(changes: [
            .entityAdded(Entity(id: "entity1", ownerAgentId: "")),
            .componentAdded("entity1", TestComponent(radius: 5.0)),
            .componentUpdated("entity1", TestComponent(radius: 6.0))
        ], fromRevision: 0, toRevision: 1)
        var entityAddedReceived = false
        var componentAddedReceived = false
        var componentUpdatedReceived = false
        
        state.observers.entityAdded.sink { e in
            entityAddedReceived = true
        }.store(in: &cancellables)
        state.observers[TestComponent.self].added.sink { (eid, comp) in
            XCTAssertEqual(comp.radius, 5.0, "Expected initial value to be correct")
            componentAddedReceived = true
        }.store(in: &cancellables)
        var initial = true
        state.observers[TestComponent.self].updated.sink { (eid, comp) in
            if initial {
                XCTAssertEqual(comp.radius, 5.0, "Expected initial value to be correct")
                initial = false
            } else {
                XCTAssertEqual(comp.radius, 6.0, "Expected updated value to be correct")
            }
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
                "a": TestComponent(radius: 5.0),
                "b": TestComponent(radius: 5.0)
            ],
            Test2Component.componentTypeId: [
                "a": Test2Component(thingie: 4)
            ]
        ]))
        
        let new = PlaceContents(revision: 2, entities: [
            "a": Entity(id: "a", ownerAgentId: ""),
            "c": Entity(id: "c", ownerAgentId: "")
        ], components: Components(lists: [
            TestComponent.componentTypeId: [
                "a": TestComponent(radius: 6.0),
                "c": TestComponent(radius: 7.0)
            ]
        ]))
        
        let diff = new.changeSet(from: old)
        
        var bRemoved = false
        var bCompRemoved = false
        var componentCategoryRemoved = false
        var aCompChanged = false
        var cAdded = false
        var cCompAdded = false
        
        for change in diff.changes
        {
            switch change
            {
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
    
    func testChangeSetApplication()
    {
        let old = PlaceContents(revision: 1, entities: [
            "a": Entity(id: "a", ownerAgentId: ""),
            "b": Entity(id: "b", ownerAgentId: "")
        ], components: Components(lists: [
            TestComponent.componentTypeId: [
                "a": TestComponent(radius: 5.0),
                "b": TestComponent(radius: 5.0)
            ]
        ]))
        
        let changeSet = PlaceChangeSet(changes: [
            .entityAdded(Entity(id: "c", ownerAgentId: "")),
            .entityRemoved(Entity(id: "b", ownerAgentId: "")),
            .componentAdded("c", TestComponent(radius: 6.0)),
            .componentAdded("c", Test2Component(thingie: 3)),
            .componentUpdated("a", TestComponent(radius: 7.0)),
            .componentRemoved("b", TestComponent(radius: 5.0))
        ], fromRevision: 1, toRevision: 2)
        
        let new = old.applyChangeSet(changeSet)
        
        dump(old)
        dump(changeSet)
        dump(new)
        
        XCTAssertTrue(new.entities["b"] == nil, "Changeset should have removed entity 'b'")
        XCTAssertTrue(new.entities["c"] != nil, "Changeset should have created entity 'c'")
        XCTAssertEqual(new.components[TestComponent.self]["a"]!.radius, 7.0, "Changeset should have updated component 'a'")
        XCTAssertEqual(new.components[TestComponent.self]["c"]!.radius, 6.0, "Changeset should have added component 'c'")
        XCTAssertNil(new.components[TestComponent.self]["b"], "Changeset should have removed component for entity 'b'")
    }
    
    func testOverlappingChangeSets()
    {
        var cancellables = Set<AnyCancellable>()
        let state = PlaceState()
        let change1 = PlaceChangeSet(changes: [
            .entityAdded(Entity(id: "entity1", ownerAgentId: "")),
        ], fromRevision: 0, toRevision: 1)
        let change2 = PlaceChangeSet(changes: [
            .entityAdded(Entity(id: "entity1", ownerAgentId: "")),
            .entityAdded(Entity(id: "entity2", ownerAgentId: "")),
        ], fromRevision: 0, toRevision: 2)
        
        var entity1CallbackCount = 0
        var entity2CallbackCount = 0
        state.observers.entityAdded.sink { e in
            if e.id == "entity1" {
                entity1CallbackCount += 1
            } else if e.id == "entity2" {
                entity2CallbackCount += 1
            }
        }.store(in: &cancellables)
        
        let success1 = state.applyChangeSet(change1)
        let success2 = state.applyChangeSet(change2)
        XCTAssertTrue(success1 && success2, "Changesets from rev 0 should always succeed")
        
        XCTAssertEqual(entity1CallbackCount, 1, "Entity1's creation should only generate one callback.")
        XCTAssertEqual(entity2CallbackCount, 1, "Entity2's creation should only generate one callback")
        // Otherwise, GUI code on top of it will think there are duplicate entities
    }
}
