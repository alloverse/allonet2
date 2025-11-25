//
//  PlaceContents+Codable.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import Logging
import PotentCodables
import PotentCBOR

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

@MainActor
public final class ComponentRegistry
{
    public static let shared = ComponentRegistry()
    
    private var registry: [ComponentTypeID: any Component.Type] = [:]
    private var factories: [ComponentTypeID: (PlaceState) -> AnyComponentCallbacksProtocol] = [:]
    
    public func register<T: Component>(_ type: T.Type)
    {
        registry[type.componentTypeId] = type
        factories[type.componentTypeId] = { ComponentCallbacks<T>($0) }
    }
    
    public func component(for typeName: String) -> (any Component.Type)?
    {
        registry[typeName]
    }
    
    internal func createCallbacks(for typeID: ComponentTypeID, state: PlaceState) -> AnyComponentCallbacksProtocol?
    {
        return factories[typeID]?(state)
    }
}

/// `AnyComponent` lets AlloPlace only store and forward type-erased value trees of Components, while client code can use `decoded()` to receive the real concrete Component type.
@MainActor
public struct AnyComponent: Component {
    public static func == (lhs: AnyComponent, rhs: AnyComponent) -> Bool {
        return lhs.treeValue == rhs.treeValue
    }
    
    // The concrete Component type we use
    public func decoded() -> any Component
    {
        return decodedIfAvailable()!
    }
    // ... or nil, if the type is not compiled into this binary and registered with the ComponentRegistry.
    public func decodedIfAvailable() -> (any Component)?
    {
        guard
            let type = ComponentRegistry.shared.component(for: componentTypeId),
            let base = try? CBORDecoder().decodeTree(type.self, from: treeValue)
        else { return nil }
        return base
    }
    /*public func decodeCustom() -> CustomComponent
    {
        return CustomComponent(typeId: componentTypeId, fields: treeValue.anyValue)
    }*/
    
    // The type-erased content, available whether the concrete type is available or not
    public var treeValue: CBOR
    public var componentTypeId: String
    
    public init(_ base: some Component)
    {
        componentTypeId = type(of: base).componentTypeId
        treeValue = try! CBOREncoder().encodeTree(base)
    }
    
    public init(from decoder: Decoder) throws
    {
        let treeContainer = try decoder.singleValueContainer() as! TreeValueDecodingContainer
        guard
            let cbor = treeContainer.decodeTreeValue() as? CBOR,
            let map = cbor.mapValue,
            let ctypeId = cbor.componentTypeId?.utf8StringValue
        else
        {
            throw DecodingError.dataCorruptedError(in: treeContainer,
                                                   debugDescription: "Invalid Component CBOR")
        }
        treeValue = cbor
        componentTypeId = ctypeId
    }
    
    public func encode(to encoder: Encoder) throws
    {
        var treeContainer = try encoder.singleValueContainer()
        try treeContainer.encode(treeValue)
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
        case .componentRemoved(let edata, let component):
            try container.encode(ChangeKind.componentRemoved, forKey: .kind)
            try container.encode(edata, forKey: .entity)
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
            let entity = try container.decode(EntityData.self, forKey: .entity)
            self = .entityAdded(entity)
        case .entityRemoved:
            let entity = try container.decode(EntityData.self, forKey: .entity)
            self = .entityRemoved(entity)
        case .componentAdded:
            let eid = try container.decode(EntityID.self, forKey: .entityID)
            let anyComp = try container.decode(AnyComponent.self, forKey: .component)
            self = .componentAdded(eid, anyComp)
        case .componentUpdated:
            let eid = try container.decode(EntityID.self, forKey: .entityID)
            let anyComp = try container.decode(AnyComponent.self, forKey: .component)
            self = .componentUpdated(eid, anyComp)
        case .componentRemoved:
            let edata = try container.decode(EntityData.self, forKey: .entity)
            let anyComp = try container.decode(AnyComponent.self, forKey: .component)
            self = .componentRemoved(edata, anyComp)
        }
    }
}
