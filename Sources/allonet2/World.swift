import Foundation

public struct World
{
    public var revision: Int64 = 0
    public var components: Dictionary<String, [any Component]> = [:]
    public var entities: Dictionary<String, Entity> = [:]
    
    public init()
    {
    }
}

public protocol Component: Codable, Equatable
{
    static var componentTypeId: String { get }
    
    var entityID: String { get };
}

public extension Component
{
    func register()
    {
        ComponentRegistry.shared.register(self.self as! any Component.Type)
    }
}

public struct Entity: Codable, Equatable, Identifiable
{
    public let id: String
    public let ownerAgentId: String
}


public class WorldState
{
    public var current: World? = nil
    public var history: [World] = []
}



// MARK: Internals

public final class ComponentRegistry {
    public static let shared = ComponentRegistry()
    
    private var registry: [String: any Component.Type] = [:]
    
    public func register(_ type: any Component.Type) {
        // You can use the static componentType if you want:
        registry[type.componentTypeId] = type
        // Or simply use the type name:
        registry[String(describing: type)] = type
    }
    
    public func component(for typeName: String) -> (any Component.Type)? {
        registry[typeName]
    }
}

extension Component
{
    func isEqualTo(_ other: any Component) -> Bool {
        // They must be of the same type to be equal.
        guard let other = other as? Self else { return false }
        return self == other
    }
}

extension World: Equatable
{
    public static func == (lhs: World, rhs: World) -> Bool {
        guard lhs.revision == rhs.revision,
              lhs.entities == rhs.entities,
              lhs.components.keys == rhs.components.keys
        else { return false }
        
        for key in lhs.components.keys {
            let lhsComponents = lhs.components[key]!
            let rhsComponents = rhs.components[key]!
            
            if lhsComponents.count != rhsComponents.count {
                return false
            }
            
            // Compare each component using the helper method.
            for (l, r) in zip(lhsComponents, rhsComponents) {
                if !l.isEqualTo(r) {
                    return false
                }
            }
        }
        return true
    }
}

extension World: Codable
{
    public init(from decoder: Decoder) throws
    {
        let container = try decoder.container(keyedBy: WorldCodingKeys.self)
        revision = try container.decode(Int64.self, forKey: .revision)
        entities = try container.decode([String: Entity].self, forKey: .entities)

        var groupsContainer = try container.nestedUnkeyedContainer(forKey: .componentGroups)
        while !groupsContainer.isAtEnd {
            let groupContainer = try groupsContainer.nestedContainer(keyedBy: ComponentGroupCodingKeys.self)
            let typeId = try groupContainer.decode(String.self, forKey: .type)
            
            // Look up the concrete type.
            guard let componentType = ComponentRegistry.shared.component(for: typeId) else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: groupContainer, debugDescription: "Unknown component type: \(typeId)")
            }
            
            var componentsContainer = try groupContainer.nestedUnkeyedContainer(forKey: .components)
            var decodedComponents: [any Component] = []
            while !componentsContainer.isAtEnd {
                let comp = try componentType.init(from: componentsContainer.superDecoder())
                decodedComponents.append(comp)
            }
            components[typeId] = decodedComponents
        }
    }
    
    public func encode(to encoder: Encoder) throws
    {
        var container = encoder.container(keyedBy: WorldCodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(entities, forKey: .entities)
    
        var groupsContainer = container.nestedUnkeyedContainer(forKey: .componentGroups)
        for (typeId, comps) in components {
            var groupContainer = groupsContainer.nestedContainer(keyedBy: ComponentGroupCodingKeys.self)
            try groupContainer.encode(typeId, forKey: .type)
            
            var componentsContainer = groupContainer.nestedUnkeyedContainer(forKey: .components)
            for comp in comps {
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

/*
public struct ComponentSet {

        /// Gets or sets the component of the specified type.
        public subscript<T>(componentType: T.Type) -> T? where T : Component
        {
        
        }

        /// Gets or sets the component with a specific dynamically supplied type.
        //public subscript(componentType: any Component.Type) -> (any Component)?

        /// Adds a new component to the set, or overrides an existing one.
        ///
        /// - Parameter component: The component to add.
        //public func set<T>(_ component: T) where T : Component

        /// Adds multiple components to the set,
        /// overriding any existing components of the same type.
        ///
        /// If the input array includes multiple components of the same type,
        /// the set adds the component with the highest index.
        /// This is because the set can only hold one component of each type.
        ///
        /// - Parameter components: An array of components to add.
        //public func set(_ components: [any Component])

        /// Returns a Boolean value that indicates whether the set contains a
        /// component of the given type.
        ///
        /// - Parameters:
        ///   - componentType: A component type, like `ModelComponent.Self`.
        ///
        /// - Returns: A Boolean value that’s `true` if the set contains a component
        /// of the given type.
        //@MainActor @preconcurrency public func has(_ componentType: any Component.Type) -> Bool

        /// Removes the component of the specified type from the collection.
        @MainActor @preconcurrency public func remove(_ componentType: any Component.Type)

        /// Removes all components from the collection.
        @MainActor @preconcurrency public func removeAll()

        /// The number of components in the collection.
        @MainActor @preconcurrency public var count: Int { get }
    }
*/
