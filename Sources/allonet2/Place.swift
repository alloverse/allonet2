//
//  Place.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-24.
//

/// This file contains the convenience API for accessing and modifying the contents of a connected Place.

/// The current contents of the Place which you are connected, with all its entities and their components. This is the convenience API; for access to the underlying data, look at `PlaceContents`.
@MainActor
public class Place
{
    /// All the entities currently in the place.
    public var entities : LazyMap<EntityID, EntityData, Entity>
    {
        return LazyMap<EntityID, EntityData, Entity>(storage:state.current.entities)
        { [weak self] (k, v) in
            guard let self, let client = self.client else { precondition(false, "Accessing world after deconstructing client") }
            return Entity(state: self.state, client: client, id: k)
        }
    }
    
    /// If you prefer a component-major view of the place (e g if you are writing a System which only deals with a single component type), this is a much more efficient accessor.
    public var components: ComponentLists
    {
        return self.state.current.components
    }
    
    // This is where it gets its actual data
    private var state: PlaceState
    private weak var client: AlloClient?
    internal init(state: PlaceState, client: AlloClient)
    {
        self.state = state
        self.client = client
    }
}

/// An entity is the thing in Place that components are part of. This is the convenience API for accessing all the related data for an entity in a single place.
@MainActor
public struct Entity
{
    public let id: EntityID
    public let components: ComponentSet
 
    let state: PlaceState
    private weak var client: AlloClient?
    internal init(state: PlaceState, client: AlloClient, id: EntityID)
    {
        self.state = state
        self.client = client
        self.id = id
        self.components = ComponentSet(state: state, client: client, id: id)
    }
}

/// All the components that a single Entity contains in one place.
@MainActor
public struct ComponentSet
{
    public subscript<T>(componentType: T.Type) -> T where T : Component
    {
        return state.current.components[componentType.componentTypeId]?[id] as! T
    }
    public func set<T>(_ newValue: T) async throws(AlloverseError) where T: Component
    {
        guard let client else { precondition(false, "Modifying world after deconstructing client") }
        try await client.changeEntity(entityId: id, addOrChange: [newValue])
    }
    public subscript(componentTypeID: ComponentTypeID) -> (any Component)?
    {
        return state.current.components[componentTypeID]?[id]
    }
    
    private let state: PlaceState
    private weak var client: AlloClient?
    private let id: EntityID
    internal init(state: PlaceState, client: AlloClient, id: EntityID)
    {
        self.state = state
        self.client = client
        self.id = id
    }
}
