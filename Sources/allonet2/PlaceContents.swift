import Foundation
import Combine

public typealias EntityID = String
public typealias ComponentTypeID = String

/// The current and historical state of the place.
public class PlaceState
{
    /// Immutable representation of the world, as known by this server or client right now.
    internal(set) public var current = PlaceContents()
    
    /// Changes in this world between the latest historic entry and current. Use this as a "callback list" of events to apply to react to changes in the world.
    internal(set) public var changeSet: PlaceChangeSet?
    
    /// Convenience for listening to relevant changes each time a new delta comes in. Useful when you have a subsystem that only cares about a specific component type, for example.
    public var observers = PlaceObservers()
    
    /// Previous versions of the world. Mostly useful to calculate deltas internally.
    public var history: [PlaceContents] = []
    
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
    public let revision: Int64
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
    public init(revision: Int64, entities: Dictionary<EntityID, Entity>, components: Components)
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
    
    /// What entity is this component an aspect of?
    var entityID: EntityID { get };
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
    
    public init()
    {
        lists = [:]
    }
    
    internal let lists: Dictionary<ComponentTypeID, [EntityID: any Component]>
    internal init(lists: Dictionary<ComponentTypeID, [EntityID: any Component]>)
    {
        self.lists = lists
    }
}

/// List of changes in a Place since the last time it got an update. Useful as a list of what to react to. For example, if a TransformComponent has changed, this means an Entity has changed its spatial location.
public struct PlaceChangeSet
{
    /// This is the list of changes. All entityAdded changes will come first; and then all entityRemoved; and then component-related changes.
    let changes: [PlaceChange]
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
    public var added: AnyPublisher<T, Never> { addedSubject.eraseToAnyPublisher() }
    /// An entity has received an update to a component with the following contents.
    public var updated: AnyPublisher<T, Never> { updatedSubject.eraseToAnyPublisher() }
    /// A component has been removed from an entity.
    public var removed: AnyPublisher<T, Never> { removedSubject.eraseToAnyPublisher() }

    internal func sendAdded  (entityID: String, component: any Component) { addedSubject.send(component as! T) }
    internal func sendUpdated(entityID: String, component: any Component) { updatedSubject.send(component as! T) }
    internal func sendRemoved(entityID: String, component: any Component) { removedSubject.send(component as! T) }
    private let addedSubject = PassthroughSubject<T, Never>()
    private let updatedSubject = PassthroughSubject<T, Never>()
    private let removedSubject = PassthroughSubject<T, Never>()
}


// MARK: Internals

protocol AnyComponentCallbacksProtocol {
    func sendAdded(entityID: String, component: any Component)
    func sendUpdated(entityID: String, component: any Component)
    func sendRemoved(entityID: String, component: any Component)
}

extension Component
{
    public static var componentTypeId: ComponentTypeID { String(describing: self) }
}

public final class ComponentRegistry
{
    public static let shared = ComponentRegistry()
    
    private var registry: [ComponentTypeID: any Component.Type] = [:]
    private var factories: [ComponentTypeID: () -> AnyComponentCallbacksProtocol] = [:]
    
    public func register<T: Component>(_ type: T.Type)
    {
        registry[type.componentTypeId] = type
        factories[type.componentTypeId] = { ComponentCallbacks<T>() }
    }
    
    public func component(for typeName: String) -> (any Component.Type)?
    {
        registry[typeName]
    }
    
    internal func createCallbacks(for typeID: ComponentTypeID) -> AnyComponentCallbacksProtocol?
    {
        return factories[typeID]?()
    }
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


extension PlaceContents: Equatable
{
    public static func == (lhs: PlaceContents, rhs: PlaceContents) -> Bool {
        guard lhs.revision == rhs.revision,
              lhs.entities == rhs.entities,
              lhs.components.lists.keys == rhs.components.lists.keys
        else { return false }
        
        for key in lhs.components.lists.keys {
            let lhsComponents = lhs.components.lists[key]!
            let rhsComponents = rhs.components.lists[key]!
            
            if lhsComponents.count != rhsComponents.count {
                return false
            }
            
            // Compare each component using the helper method.
            for (l, r) in zip(lhsComponents, rhsComponents) {
                if !l.value.isEqualTo(r.value) {
                    return false
                }
            }
        }
        return true
    }
}

extension PlaceContents: Codable
{
    public init(from decoder: Decoder) throws
    {
        let container = try decoder.container(keyedBy: WorldCodingKeys.self)
        revision = try container.decode(Int64.self, forKey: .revision)
        entities = try container.decode([String: Entity].self, forKey: .entities)

        var groupsContainer = try container.nestedUnkeyedContainer(forKey: .componentGroups)
        var lists: Dictionary<ComponentTypeID, [EntityID: any Component]> = [:]
        while !groupsContainer.isAtEnd {
            let groupContainer = try groupsContainer.nestedContainer(keyedBy: ComponentGroupCodingKeys.self)
            let typeId = try groupContainer.decode(String.self, forKey: .type)
            
            // Look up the concrete type.
            guard let componentType = ComponentRegistry.shared.component(for: typeId) else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: groupContainer, debugDescription: "Unknown component type: \(typeId)")
            }
            
            var componentsContainer = try groupContainer.nestedUnkeyedContainer(forKey: .components)
            var decodedComponents: [EntityID : any Component] = [:]
            while !componentsContainer.isAtEnd {
                let comp = try componentType.init(from: componentsContainer.superDecoder())
                decodedComponents[comp.entityID] = comp
            }
            lists[typeId] = decodedComponents
        }
        components = Components(lists: lists)
    }
    
    public func encode(to encoder: Encoder) throws
    {
        var container = encoder.container(keyedBy: WorldCodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(entities, forKey: .entities)
    
        var groupsContainer = container.nestedUnkeyedContainer(forKey: .componentGroups)
        for (typeId, comps) in components.lists {
            var groupContainer = groupsContainer.nestedContainer(keyedBy: ComponentGroupCodingKeys.self)
            try groupContainer.encode(typeId, forKey: .type)
            
            var componentsContainer = groupContainer.nestedUnkeyedContainer(forKey: .components)
            for (_, comp) in comps {
                try comp.encode(to: componentsContainer.superEncoder())
            }
        }
    }
}


enum WorldCodingKeys: String, CodingKey
{
    case revision, entities, componentGroups
}

enum ComponentGroupCodingKeys: String, CodingKey
{
    case type, components
}


