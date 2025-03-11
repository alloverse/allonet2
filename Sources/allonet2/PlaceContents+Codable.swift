//
//  PlaceContents+Codable.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

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

public struct AnyComponent: Component {
    public static func == (lhs: AnyComponent, rhs: AnyComponent) -> Bool {
        return lhs.base.isEqualTo(rhs.base)
    }
    
    public var base: any Component

    public var entityID: EntityID { base.entityID }
    
    public static var componentType: String { "AnyComponent" } // Not used in encoding
    
    public init(_ base: some Component) {
        self.base = base
    }
    
    // MARK: - Codable
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }
    
    public init(from decoder: Decoder) throws {
        // First, decode the type discriminator.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeId = try container.decode(String.self, forKey: .type)
        
        // Ask the registry for the correct concrete type.
        guard let componentType = ComponentRegistry.shared.component(for: typeId) else {
            throw DecodingError.dataCorruptedError(forKey: .type,
                                                   in: container,
                                                   debugDescription: "Unknown component type: \(typeId)")
        }
        
        // Decode the actual component.
        self.base = try componentType.init(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        // Create a container for both the type discriminator and the payload.
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Write out the type identifier. We use the static property from the concrete type.
        try container.encode(String(describing: type(of: base)), forKey: .type)
        // Encode the underlying component.
        try base.encode(to: encoder)
    }
}

// TODO: Make this use AnyComponent.Codable too?
extension PlaceContents: Codable
{
    private enum WorldCodingKeys: String, CodingKey
    {
        case revision, entities, componentGroups
    }

    private enum ComponentGroupCodingKeys: String, CodingKey
    {
        case type, components
    }

    public init(from decoder: Decoder) throws
    {
        let container = try decoder.container(keyedBy: WorldCodingKeys.self)
        revision = try container.decode(StateRevision.self, forKey: .revision)
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

extension PlaceChange: Codable
{
    private enum CodingKeys: String, CodingKey
    {
        case kind
        case entity, entityID, component
    }
    
    private enum ChangeKind: String, Codable
    {
        case entityAdded, entityRemoved, componentAdded, componentUpdated, componentRemoved
    }
    
    public func encode(to encoder: Encoder) throws
    {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self
        {
        case .entityAdded(let entity):
            try container.encode(ChangeKind.entityAdded, forKey: .kind)
            try container.encode(entity, forKey: .entity)
        case .entityRemoved(let entity):
            try container.encode(ChangeKind.entityRemoved, forKey: .kind)
            try container.encode(entity, forKey: .entity)
        case .componentAdded(let eid, let component):
            try container.encode(ChangeKind.componentAdded, forKey: .kind)
            try container.encode(eid, forKey: .entityID)
            // Wrap the component so we can encode it generically.
            try container.encode(AnyComponent(component), forKey: .component)
        case .componentUpdated(let eid, let component):
            try container.encode(ChangeKind.componentUpdated, forKey: .kind)
            try container.encode(eid, forKey: .entityID)
            try container.encode(AnyComponent(component), forKey: .component)
        case .componentRemoved(let eid, let component):
            try container.encode(ChangeKind.componentRemoved, forKey: .kind)
            try container.encode(eid, forKey: .entityID)
            try container.encode(AnyComponent(component), forKey: .component)
        }
    }
    
    public init(from decoder: Decoder) throws
    {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ChangeKind.self, forKey: .kind)
        switch kind
        {
        case .entityAdded:
            let entity = try container.decode(Entity.self, forKey: .entity)
            self = .entityAdded(entity)
        case .entityRemoved:
            let entity = try container.decode(Entity.self, forKey: .entity)
            self = .entityRemoved(entity)
        case .componentAdded:
            let eid = try container.decode(EntityID.self, forKey: .entityID)
            let anyComp = try container.decode(AnyComponent.self, forKey: .component)
            self = .componentAdded(eid, anyComp.base)
        case .componentUpdated:
            let eid = try container.decode(EntityID.self, forKey: .entityID)
            let anyComp = try container.decode(AnyComponent.self, forKey: .component)
            self = .componentUpdated(eid, anyComp.base)
        case .componentRemoved:
            let eid = try container.decode(EntityID.self, forKey: .entityID)
            let anyComp = try container.decode(AnyComponent.self, forKey: .component)
            self = .componentRemoved(eid, anyComp.base)
        }
    }
}
