import Foundation
import OpenCombineShim
import Logging

/// This file contains the low-level data API for accessing and listening to changes of the contents of a connected Place.

public typealias EntityID = String
public typealias ComponentTypeID = String
public typealias StateRevision = Int64

/// The current and historical state of the place. This is the stateful underlying representation of a Place; use `Place` instead for a simpler API.
@MainActor
public class PlaceState
{
    /// Immutable representation of the world, as known by this server or client right now.
    internal(set) public var current: PlaceContents
    
    /// Changes in this world between the latest historic entry and current. Use this as a "callback list" of events to apply to react to changes in the world.
    internal(set) public var changeSet: PlaceChangeSet?
    
    /// Convenience for listening to relevant changes each time a new delta comes in. Useful when you have a subsystem that only cares about a specific component type, for example.
    public var observers = PlaceObservers()
    
    /// Previous versions of the world. Mostly useful to calculate deltas internally. Oldest first, newest at the end.
    public var history: [PlaceContents]
    
    public func getHistory(at revision: StateRevision) -> PlaceContents?
    {
        // revision 0 is a shorthand for the completely empty place
        if revision == 0 { return PlaceContents(logger: logger) }
        
        return history.reversed().first {
            return $0.revision == revision
        }
    }
    
    /// Wait for a specific entity to come in.
    public func findEntity(_ id: EntityID) async throws -> EntityData
    {
        if let ent = current.entities[id] {
            return ent
        }
        var iter = observers.subjectFor(id).values.makeAsyncIterator()
        if let ent = await iter.next() {
            return ent
        }
        throw CancellationError()
    }
    
    internal func callChangeObservers()
    {
        for event in changeSet?.changes ?? []
        {
            switch event
            {
            case .entityAdded(let entity):
                observers.entityAddedSubject.send(entity)
                if let waitingForEntitySubject = observers.waitingForEntitySubjects.removeValue(forKey: entity.id)
                {
                    waitingForEntitySubject.send(entity)
                    waitingForEntitySubject.send(completion: .finished)
                }
            case .entityRemoved(let entity):
                observers.entityRemovedSubject.send(entity)
            case .componentAdded(let entityID, let comp):
                observers[type(of: comp).componentTypeId].sendAdded(entityID: entityID, component: comp)
                observers[type(of: comp).componentTypeId].sendUpdated(entityID: entityID, component: comp)
            case .componentUpdated(let entityID, let comp):
                observers[type(of: comp).componentTypeId].sendUpdated(entityID: entityID, component: comp)
            case .componentRemoved(let entityData, let comp):
                observers[type(of: comp).componentTypeId].sendRemoved(entityData: entityData, component: comp)
            }
        }
    }
    
    public init(logger: Logger)
    {
        self.logger = logger
        self.current = PlaceContents(logger: self.logger)
        self.history = [PlaceContents(logger: self.logger)]
        self.observers.state = self
    }
    
    // TODO: I did this to detect any awaits that should fail because of object tree teardown; but it's zombie ressurrection doing it in deinit, so it would have to be implemented in a layer above this.
    /*@MainActor deinit {
        for subject in observers.waitingForEntitySubjects.values
        {
            subject.send(completion: .finished)
        }
    }*/
    
    var logger: Logger
}

/// A full representation of the world in the connected Place. Everything in a Place is represented as an Entity, but an Entity itself is only an ID; all its attributes are described by its child Components of various types.
@MainActor
public struct PlaceContents
{
    /// What revision of the place is this? Every tick in the server bumps this by 1. Due to network conditions, a client might miss a few revisions here and there and it might not see every sequential revision.
    public let revision: StateRevision
    /// The list of entities; basically just a list of IDs of things in the Place.
    public let entities: Dictionary<EntityID, EntityData>
    /// All the attributes for the entities, as various typed components.
    public let components : ComponentLists
    
    public init(logger: Logger)
    {
        self.revision = 0
        self.entities = [:]
        self.components = ComponentLists()
        self.logger = logger
    }
    public init(revision: StateRevision, entities: Dictionary<EntityID, EntityData>, components: ComponentLists, logger: Logger)
    {
        self.revision = revision
        self.entities = entities
        self.components = components
        self.logger = logger
    }
    
    var logger: Logger
}

/// An entity is the thing in Place that components are part of. This is the underlying data structure that just informs that it exists and has an owner. Use `Entity` for a more convenient API.
@MainActor
public struct EntityData: Codable, Equatable, Identifiable
{
    /// Unique ID within this Place
    public let id: EntityID
    
    /// ID of the user/process that owns this ID. Only available server-side.
    public let ownerClientId: ClientId
}

/// Base for all component types.
@MainActor
public protocol Component: Codable, Equatable, CustomStringConvertible
{
    /// Internals: how to disambiguate this component on the wire protocol. Uses `String(describing:type(of:self))`.
    static var componentTypeId: ComponentTypeID { get }
    
    // For debugging
    func indentedDescription(_ prefix: String) -> String
}

public extension Component
{
    /// Every component type must be registered early in the process lifetime for it to work.
    static func register()
    {
        ComponentRegistry.shared.register(self.self)
    }
}

/// A list of all the lists of components in a Place, grouped by type.
@MainActor
public struct ComponentLists
{
    public subscript<T>(componentType: T.Type) -> [EntityID: T] where T : Component
    {
        return (decodedLists[componentType.componentTypeId] ?? [:]) as! [EntityID: T]
    }
    public subscript(componentTypeID: ComponentTypeID) -> [EntityID: AnyComponent]?
    {
        return lists[componentTypeID]
    }

    
    public init()
    {
        lists = [:]
    }
    
    internal let lists: Dictionary<ComponentTypeID, [EntityID: AnyComponent]>
    internal var decodedLists : LazyMap<ComponentTypeID, [EntityID: AnyComponent], [EntityID: any Component]>
    {
        return LazyMap<ComponentTypeID, [EntityID: AnyComponent], [EntityID: any Component]>(storage:lists)
        { (k, v) in
            return v.mapValues { $0.decoded() }
        }
    }
    
    internal init(lists: Dictionary<ComponentTypeID, [EntityID: AnyComponent]>)
    {
        self.lists = lists
    }
    
    /// Collects all the components of all types for a single entity and returns as a map.
    public func componentsForEntity(_ entityID: EntityID) -> [ComponentTypeID: AnyComponent]
    {
        var result: [ComponentTypeID: AnyComponent] = [:]
        for (componentTypeID, list) in lists {
            if let component = list[entityID] {
                result[componentTypeID] = component
            }
        }
        return result
    }
}

/// List of changes in a Place since the last time it got an update. Useful as a list of what to react to. For example, if a TransformComponent has changed, this means an Entity has changed its spatial location.
@MainActor
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
@MainActor
public enum PlaceChange
{
    case entityAdded(EntityData)
    case entityRemoved(EntityData)
    case componentAdded(EntityID, AnyComponent)
    case componentUpdated(EntityID, AnyComponent)
    case componentRemoved(EntityData, AnyComponent)
}

/// Convenience callbacks, including per-component-typed callbacks for when entities and components change in the place.
@MainActor
public struct PlaceObservers
{
    /// There's a new entity.
    public var entityAdded: AnyPublisher<EntityData, Never> { entityAddedSubject.eraseToAnyPublisher() }
    public var entityAddedWithInitial: AnyPublisher<EntityData, Never> {
        entityAdded.prepend(state.current.entities.values).eraseToAnyPublisher()
    }
    /// An entity has been removed.
    public var entityRemoved: AnyPublisher<EntityData, Never> { entityRemovedSubject.eraseToAnyPublisher() }
    internal let entityAddedSubject = PassthroughSubject<EntityData, Never>()
    internal let entityRemovedSubject = PassthroughSubject<EntityData, Never>()
    internal var waitingForEntitySubjects: [EntityID: PassthroughSubject<EntityData, Never>] = [:]
    mutating internal func subjectFor(_ eid: EntityID) -> PassthroughSubject<EntityData, Never>
    {
        return waitingForEntitySubjects[eid, setDefault: PassthroughSubject<EntityData, Never>()]
    }
    
    
    /// Get a type-safe set of callbacks for a specific Component type
    public subscript<T>(componentType: T.Type) -> ComponentCallbacks<T> where T : Component
    {
        mutating get {
            return lists[componentType.componentTypeId, setDefault: ComponentCallbacks<T>(state)] as! ComponentCallbacks<T>
        }
    }
    internal subscript(componentTypeID: ComponentTypeID) -> AnyComponentCallbacksProtocol
    {
        mutating get {
            return lists[componentTypeID, setDefault: ComponentRegistry.shared.createCallbacks(for: componentTypeID, state: state)!]
        }
    }
    
    private var lists: Dictionary<ComponentTypeID, AnyComponentCallbacksProtocol> = [:]
    internal weak var state: PlaceState! = nil
}

@MainActor
public struct ComponentCallbacks<T: Component>  : AnyComponentCallbacksProtocol
{
    /// An entity has received a new component of this type
    public var added: AnyPublisher<(EntityID, T), Never> { addedSubject.eraseToAnyPublisher() }
    public var addedWithInitial: AnyPublisher<(EntityID, T), Never> {
        let initial = state.current.components[T.self].map { ($0.key, $0.value) }
        return added.prepend(initial).eraseToAnyPublisher()
    }
    /// An entity has received an update to a component with the following contents. NOTE: This is also called immediately after `added`, so you can put all your "react to property changes regardless of add or update" in one place.
    public var updated: AnyPublisher<(EntityID, T), Never> { updatedSubject.eraseToAnyPublisher() }
    public var updatedWithInitial: AnyPublisher<(EntityID, T), Never> {
        let initial = state.current.components[T.self].map { ($0.key, $0.value) }
        return updated.prepend(initial).eraseToAnyPublisher()
    }
    /// A component has been removed from an entity.
    public var removed: AnyPublisher<(EntityData, T), Never> { removedSubject.eraseToAnyPublisher() }

    internal func sendAdded  (entityID: String, component: any Component) { addedSubject.send((entityID, component as! T)) }
    internal func sendUpdated(entityID: String, component: any Component) { updatedSubject.send((entityID, component as! T)) }
    internal func sendRemoved(entityData: EntityData, component: any Component) { removedSubject.send((entityData, component as! T)) }
    private let addedSubject = PassthroughSubject<(EntityID, T), Never>()
    private let updatedSubject = PassthroughSubject<(EntityID, T), Never>()
    private let removedSubject = PassthroughSubject<(EntityData, T), Never>()
    
    internal init(_ state: PlaceState)
    {
        self.state = state
    }
    internal weak var state: PlaceState! = nil
}


// MARK: Internals
@MainActor
protocol AnyComponentCallbacksProtocol {
    func sendAdded(entityID: EntityID, component: any Component)
    func sendUpdated(entityID: EntityID, component: any Component)
    func sendRemoved(entityData: EntityData, component: any Component)
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

extension Component
{
    public var description: String { self.indentedDescription("") }
    public func indentedDescription(_ prefix: String) -> String
    {
        var desc = "\(prefix)\(Self.componentTypeId):"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard
            let data = try? encoder.encode(self),
            let string = String(data: data, encoding: .utf8)
         else { return desc }
        let lines = string.split(separator: "\n").dropFirst().dropLast()
        desc += "\n\(prefix)\t" + lines.joined(separator: "\n\(prefix)\t")
        return desc
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

