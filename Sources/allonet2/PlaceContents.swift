import Foundation
import Combine

public typealias EntityID = String
public typealias ComponentTypeID = String
public typealias StateRevision = Int64

/// The current and historical state of the place.
public class PlaceState
{
    /// Immutable representation of the world, as known by this server or client right now.
    internal(set) public var current = PlaceContents()
    
    /// Changes in this world between the latest historic entry and current. Use this as a "callback list" of events to apply to react to changes in the world.
    internal(set) public var changeSet: PlaceChangeSet?
    
    /// Convenience for listening to relevant changes each time a new delta comes in. Useful when you have a subsystem that only cares about a specific component type, for example.
    public var observers = PlaceObservers()
    
    /// Previous versions of the world. Mostly useful to calculate deltas internally. Oldest first, newest at the end.
    public var history: [PlaceContents] = [PlaceContents()]
    
    public func getHistory(at revision: StateRevision) -> PlaceContents?
    {
        // revision 0 is a shorthand for the completely empty place
        if revision == 0 { return PlaceContents() }
        
        return history.reversed().first {
            return $0.revision == revision
        }
    }
    
    internal func callChangeObservers()
    {
        for event in changeSet?.changes ?? []
        {
            switch event
            {
            case .entityAdded(let entity):
                observers.entityAddedSubject.send(entity)
            case .entityRemoved(let entity):
                observers.entityRemovedSubject.send(entity)
            case .componentAdded(let entityID, let comp):
                observers[type(of: comp).componentTypeId].sendAdded(entityID: entityID, component: comp)
                observers[type(of: comp).componentTypeId].sendUpdated(entityID: entityID, component: comp)
            case .componentUpdated(let entityID, let comp):
                observers[type(of: comp).componentTypeId].sendUpdated(entityID: entityID, component: comp)
            case .componentRemoved(let entityID, let comp):
                observers[type(of: comp).componentTypeId].sendRemoved(entityID: entityID, component: comp)
            }
        }
    }
}

/// A full representation of the world in the connected Place. Everything in a Place is represented as an Entity, but an Entity itself is only an ID; all its attributes are described by its child Components of various types.
public struct PlaceContents
{
    /// What revision of the place is this? Every tick in the server bumps this by 1. Due to network conditions, a client might miss a few revisions here and there and it might not see every sequential revision.
    public let revision: StateRevision
    /// The list of entities; basically just a list of IDs of things in the Place.
    public let entities: Dictionary<EntityID, Entity>
    /// All the attributes for the entities, as various typed components.
    public let components : Components
    
    public init()
    {
        revision = 0
        entities = [:]
        components = Components()
    }
    public init(revision: StateRevision, entities: Dictionary<EntityID, Entity>, components: Components)
    {
        self.revision = revision
        self.entities = entities
        self.components = components
    }
}

/// An entity: a Thing in a Place.
public struct Entity: Codable, Equatable, Identifiable
{
    /// Unique ID within this Place
    public let id: EntityID
    
    /// ID of the user/process that owns this ID. Only available server-side.
    public let ownerAgentId: String
}

/// Base for all component types.
public protocol Component: Codable, Equatable
{
    /// Internals: how to disambiguate this component on the wire protocol
    static var componentTypeId: ComponentTypeID { get }
}

public extension Component
{
    /// Every component type must be registered early in the process lifetime for it to work.
    static func register()
    {
        ComponentRegistry.shared.register(self.self)
    }
}

public struct Components
{
    public subscript<T>(componentType: T.Type) -> [EntityID: T] where T : Component
    {
        return lists[componentType.componentTypeId] as! [EntityID: T]
    }
    public subscript(componentTypeID: ComponentTypeID) -> [EntityID: any Component]?
    {
        return lists[componentTypeID]
    }

    
    public init()
    {
        lists = [:]
    }
    
    internal let lists: Dictionary<ComponentTypeID, [EntityID: any Component]>
    internal init(lists: Dictionary<ComponentTypeID, [EntityID: any Component]>)
    {
        self.lists = lists
    }
    
    // TODO: Return something like ComponentSet from RealityKit, and rename this class ComponentList (or use better names)
    public func componentsForEntity(_ entityID: EntityID) -> [ComponentTypeID: any Component]
    {
        var result: [ComponentTypeID: any Component] = [:]
        for (componentTypeID, list) in lists {
            if let component = list[entityID] {
                result[componentTypeID] = component
            }
        }
        return result
    }
}

/// List of changes in a Place since the last time it got an update. Useful as a list of what to react to. For example, if a TransformComponent has changed, this means an Entity has changed its spatial location.
public struct PlaceChangeSet: Codable, Equatable
{
    /// This is the list of changes. All entityAdded changes will come first; and then all entityRemoved; and then component-related changes.
    let changes: [PlaceChange]
    /// Which revision should the receiver use as a base to apply these changes?
    let fromRevision: StateRevision
    /// Which revision do we end up at after applying these changes?
    let toRevision: StateRevision
}

/// The different kinds of changes that can happen to a Place state
public enum PlaceChange
{
    case entityAdded(Entity)
    case entityRemoved(Entity)
    case componentAdded(EntityID, any Component)
    case componentUpdated(EntityID, any Component)
    case componentRemoved(EntityID, any Component)
}

/// Convenience callbacks, including per-component-typed callbacks for when entities and components change in the place.
public struct PlaceObservers
{
    /// There's a new entity.
    public var entityAdded: AnyPublisher<Entity, Never> { entityAddedSubject.eraseToAnyPublisher() }
    /// An entity has been removed.
    public var entityRemoved: AnyPublisher<Entity, Never> { entityRemovedSubject.eraseToAnyPublisher() }
    internal let entityAddedSubject = PassthroughSubject<Entity, Never>()
    internal let entityRemovedSubject = PassthroughSubject<Entity, Never>()
    
    /// Get a type-safe set of callbacks for a specific Component type
    public subscript<T>(componentType: T.Type) -> ComponentCallbacks<T> where T : Component
    {
        mutating get {
            return lists[componentType.componentTypeId, setDefault: ComponentCallbacks<T>()] as! ComponentCallbacks<T>
        }
    }
    internal subscript(componentTypeID: ComponentTypeID) -> AnyComponentCallbacksProtocol
    {
        mutating get {
            return lists[componentTypeID, setDefault: ComponentRegistry.shared.createCallbacks(for: componentTypeID)!]
        }
    }
    
    private var lists: Dictionary<ComponentTypeID, AnyComponentCallbacksProtocol> = [:]
}

public struct ComponentCallbacks<T: Component>  : AnyComponentCallbacksProtocol
{
    /// An entity has received a new component of this type
    public var added: AnyPublisher<(EntityID, T), Never> { addedSubject.eraseToAnyPublisher() }
    /// An entity has received an update to a component with the following contents. NOTE: This is also called immediately after `added`, so you can put all your "react to property changes regardless of add or update" in one place.
    public var updated: AnyPublisher<(EntityID, T), Never> { updatedSubject.eraseToAnyPublisher() }
    /// A component has been removed from an entity.
    public var removed: AnyPublisher<(EntityID, T), Never> { removedSubject.eraseToAnyPublisher() }

    internal func sendAdded  (entityID: String, component: any Component) { addedSubject.send((entityID, component as! T)) }
    internal func sendUpdated(entityID: String, component: any Component) { updatedSubject.send((entityID, component as! T)) }
    internal func sendRemoved(entityID: String, component: any Component) { removedSubject.send((entityID, component as! T)) }
    private let addedSubject = PassthroughSubject<(EntityID, T), Never>()
    private let updatedSubject = PassthroughSubject<(EntityID, T), Never>()
    private let removedSubject = PassthroughSubject<(EntityID, T), Never>()
}


// MARK: Internals

protocol AnyComponentCallbacksProtocol {
    func sendAdded(entityID: EntityID, component: any Component)
    func sendUpdated(entityID: EntityID, component: any Component)
    func sendRemoved(entityID: EntityID, component: any Component)
}

extension Component
{
    public static var componentTypeId: ComponentTypeID { String(describing: self) }
}

extension Component
{
    func isEqualTo(_ other: any Component) -> Bool
    {
        // They must be of the same type to be equal.
        guard let other = other as? Self else { return false }
        return self == other
    }
}

extension PlaceChange: Equatable {
    public static func == (lhs: PlaceChange, rhs: PlaceChange) -> Bool {
        switch (lhs, rhs) {
        case (.entityAdded(let e1), .entityAdded(let e2)):
            return e1 == e2
        case (.entityRemoved(let e1), .entityRemoved(let e2)):
            return e1 == e2
        case (.componentAdded(let id1, let comp1), .componentAdded(let id2, let comp2)):
            return id1 == id2 && comp1.isEqualTo(comp2)
        case (.componentUpdated(let id1, let comp1), .componentUpdated(let id2, let comp2)):
            return id1 == id2 && comp1.isEqualTo(comp2)
        case (.componentRemoved(let id1, let comp1), .componentRemoved(let id2, let comp2)):
            return id1 == id2 && comp1.isEqualTo(comp2)
        default:
            return false
        }
    }
}
