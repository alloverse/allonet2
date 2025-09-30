//
//  Place.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-24.
//

/// This file contains the convenience API for accessing and modifying the contents of a connected Place.

import simd
import Foundation

/// The current contents of the Place which you are connected, with all its entities and their components. This is the convenience API; for access to the underlying data, look at `PlaceContents`.
@MainActor
public class Place: CustomStringConvertible
{
    /// All the entities currently in the place.
    public var entities : LazyMap<EntityID, EntityData, Entity>
    {
        return LazyMap<EntityID, EntityData, Entity>(storage:state.current.entities)
        { [weak self] (k, v) in
            guard let self else { fatalError("Accessing world after deconstructing client"); }
            return Entity(state: self.state, client: self.client, id: k)
        }
    }
    
    /// Wait for a specific entity to come in and return its convenience structure.
    public func findEntity(id: EntityID) async throws -> Entity
    {
        let edata = try await state.findEntity(id)
        try Task.checkCancellation()
        // Cancellation should be the only reason why we get nil back, which should make the below force-unwrap safe with the above check
        return entities[edata.id]!
    }
    
    /// If you prefer a component-major view of the place (e g if you are writing a System which only deals with a single component type), this is a much more efficient accessor.
    public var components: ComponentLists
    {
        return self.state.current.components
    }
    
    // This is where it gets its actual data
    private var state: PlaceState
    private weak var client: EntityMutator?
    internal init(state: PlaceState, client: EntityMutator?)
    {
        self.state = state
        self.client = client
    }
    
    public var description: String
    {
        """
        Place at revision \(state.current.revision):
        \(entities.map { "\($0.value.indentedDescription("\t"))" }.joined(separator: "\n"))
        """
    }
}

/// An entity is the thing in Place that components are part of. This is the convenience API for accessing all the related data for an entity in a single place.
@MainActor
public struct Entity: CustomStringConvertible
{
    public let id: EntityID
    public let components: ComponentSet
 
    let state: PlaceState
    private weak var client: EntityMutator?
    internal init(state: PlaceState, client: EntityMutator?, id: EntityID)
    {
        self.state = state
        self.client = client
        self.id = id
        self.components = ComponentSet(state: state, client: client, id: id)
    }
    
    public var parent: Entity?
    {
        guard let parentId = self.components[Relationships.self]?.parent else
        {
            return nil
        }
        
        return Entity(state: state, client: client, id: parentId)
    }
    
    public var children: [Entity]
    {
        var children = [Entity]()
        for (eid, rels) in state.current.components[Relationships.self]
        {
            if rels.parent == self.id {
                children.append(Entity(state: state, client: client, id: eid))
            }
        }
        return children
    }
    
    public var transformToParent: simd_float4x4 {
        return self.components[Transform.self]?.matrix ?? .identity
    }
    
    public var transformToWorld: simd_float4x4 {
        var transform = self.transformToParent
        if let parent = self.parent
        {
            transform = parent.transformToWorld * transform
        }
        
        return transform
    }
    
    public var description: String { self.indentedDescription("") }
    public func indentedDescription(_ prefix: String) -> String
    {
        let desc = """
        \(prefix)<Entity \(id)>
        \(prefix)Components:
        \(components.indentedDescription("\(prefix)\t"))
        """
        let ch = children
        if ch.count == 0 { return desc }
        return desc + """
        \n\(prefix)Children:
        \( ch.map { $0.indentedDescription("\(prefix)\t") }.joined(separator: "\n") )
        """
    }
}

/// All the components that a single Entity contains in one place.
@MainActor
public struct ComponentSet: CustomStringConvertible
{
    public subscript<T>(componentType: T.Type) -> T? where T : Component
    {
        return state.current.components[componentType.componentTypeId]?[id] as! T?
    }
    public func set<T>(_ newValue: T) async throws(AlloverseError) where T: Component
    {
        guard let client else { fatalError("Modifying world after deconstructing client"); }
        try await client.changeEntity(entityId: id, addOrChange: [newValue], remove: [])
    }
    public subscript(componentTypeID: ComponentTypeID) -> (any Component)?
    {
        return state.current.components[componentTypeID]?[id]
    }
    
    private let state: PlaceState
    private weak var client: EntityMutator?
    private let id: EntityID
    internal init(state: PlaceState, client: EntityMutator?, id: EntityID)
    {
        self.state = state
        self.client = client
        self.id = id
    }
    
    public var description: String { self.indentedDescription("") }
    public func indentedDescription(_ prefix: String) -> String
    {
        let comps = state.current.components.componentsForEntity(id).values
        return comps.map { $0.indentedDescription(prefix) }.joined(separator: "\n")
    }
}

