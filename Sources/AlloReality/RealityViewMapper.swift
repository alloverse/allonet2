//
//  RealityViewMapper.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-18.
//

import RealityKit
import OpenCombineShim
import allonet2
import SwiftUICore

/// The RealityViewMapper creates and maintains RealityKit entities and components to perfectly match corresponding entities and components inside an Alloverse connection's PlaceContents.
@MainActor
public class RealityViewMapper
{
    public var builtinAssetsBundle: Bundle?
    private var netstate: PlaceState
    private var guiroot: RealityKit.Entity
    private var cancellables = Set<AnyCancellable>()
    
    /// Create a mapper that maps changes in the given `networkState` (taken from an AlloClient), and maintains corresponding RealityKit entities as children of `guiroot`. By default, it is inert; you need to `startSyncing()` to make it react to changes, and you should do so before connecting the associated AlloClient (so you don't miss any changes).
    public init(networkState netstate: PlaceState, addingEntitiesTo guiroot: RealityKit.Entity) {
        self.netstate = netstate
        self.guiroot = guiroot
    }
    
    /// Start syncing changes from the AlloClient into the associated RealityView Entity. This default implementation creates Entities and most of the Standard Alloverse Components. If you want to also sync any of your own custom components, you must also call `startSyncingOf(networkComponentType:to:using:)`.
    public func startSyncing()
    {
        netstate.observers.entityAdded.sink { netent in
            let guient = RealityKit.Entity()
            guient.name = netent.id
            self.guiroot.addChild(guient)
        }.store(in: &cancellables)
        netstate.observers.entityRemoved.sink { netent in
            guard let guient = self.guiroot.findEntity(named: netent.id) else { return }
            guient.removeFromParent()
        }.store(in: &cancellables)
        
        startSyncingOf(networkComponentType: allonet2.Transform.self, to: RealityKit.Transform.self)
        { (entity, _, transform) in
            entity.setTransformMatrix(transform.matrix, relativeTo: entity.parent)
        }
        
        startSyncingOf(networkComponentType: Relationships.self) { (entity, _, relationship) in
            guard entity.parent?.name != relationship.parent else { return }
            entity.removeFromParent()
            let newParent = self.guiroot.findEntity(named: relationship.parent)!
            newParent.addChild(entity)
        } remover: { (entity, _, relationship) in
            guard entity.parent != self.guiroot else { return }
            entity.removeFromParent()
            self.guiroot.addChild(entity)
        }
        
        startSyncingOfModel()
        
        startSyncingOf(networkComponentType: Collision.self, to: CollisionComponent.self)
        { entity, _, collision in
            entity.components.set(CollisionComponent(shapes: collision.realityShapes))
        }
        
        startSyncingOf(networkComponentType: Opacity.self, to: OpacityComponent.self)
        { entity, _, opacity in
            entity.components.set(OpacityComponent(opacity: opacity.opacity))
        }
        startSyncingOf(networkComponentType: Billboard.self, to: BillboardComponent.self)
        { entity, _, billboard in
            var reality = BillboardComponent()
            reality.blendFactor = billboard.blendFactor
            entity.components.set(reality)
        }
        
        if #available(macOS 15.0, *) {
            startSyncingOf(networkComponentType: InputTarget.self, to: InputTargetComponent.self)
            {
                (entity, _, inputTarget) in
                entity.components.set(InputTargetComponent())
            }
            startSyncingOf(networkComponentType: HoverEffect.self, to: HoverEffectComponent.self)
            {
                (entity, _, hoverEffect) in
                entity.components.set(HoverEffectComponent(hoverEffect.realityEffect))
            }
        }
    }
    
    /// In addition to syncing the Standard Components from `startSyncing()`, also sync other/custom components with this method, called directly after `startSyncing` but before the AlloClient connects.
    public func startSyncingOf<T>(
        networkComponentType: T.Type,
        updater: @escaping @MainActor (RealityKit.Entity, allonet2.EntityData, T) -> Void,
        remover: @escaping @MainActor (RealityKit.Entity, allonet2.EntityData, T) -> Void
    ) where T : allonet2.Component
    {
        netstate.observers[networkComponentType.self].updated.sink { (eid, netcomp) in
            guard let guient = self.guiroot.findEntity(named: eid) else { return }
            guard let netent = self.netstate.current.entities[eid] else { return }
            updater(guient, netent, netcomp)
        }.store(in: &cancellables)
        netstate.observers[networkComponentType.self].removed.sink { (edata, netcomp) in
            guard let guient = self.guiroot.findEntity(named: edata.id) else { return }
            remover(guient, edata, netcomp)
        }.store(in: &cancellables)
    }
    
    /// Convenience alternative to `startSyncingOf:updater:remover` when there's a one-to-one map between an Alloverse entity type and a RealityKit entity type.
    public func startSyncingOf<T, U>(networkComponentType: T.Type, to realityComponentType: U.Type, using updater: @escaping (RealityKit.Entity, allonet2.EntityData, T) -> Void) where T : allonet2.Component, U : RealityKit.Component
    {
        startSyncingOf(networkComponentType: networkComponentType, updater: updater, remover: {  (guient, _, netcomp) in
            guient.components[realityComponentType.self] = nil
        })
    }
    
    private struct AlloModelStateComponent: RealityKit.Component
    {
        var current: Model? = nil
        weak var entity: RealityKit.Entity? = nil
        var loadingTask: Task<Void, Error>?
    }
    
    private func startSyncingOfModel()
    {
        startSyncingOf(networkComponentType: Model.self)
        { (entity, _, model) in
            var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
            guard state.current != model else { return }
            
            if case .builtin(name: let name) = model.mesh
            {
                state.loadingTask?.cancel()
                state.loadingTask = Task {
                    var loaded: RealityKit.Entity!
                    do {
                        loaded = try await Entity(named: name, in: self.builtinAssetsBundle)
                    } catch (let e) {
                        print("Failed to load builtin model \(name) for entity \(entity.id): \(e)")
                        loaded = ModelEntity(mesh: .generateBox(size: 0.5), materials: [SimpleMaterial(color: .red, isMetallic: true)])
                    }
                    if(Task.isCancelled) { return }
                    state.loadingTask = nil
                    state.entity = loaded
                    entity.components.set(state)
                    entity.addChild(loaded)
                }
            }
            else
            {
                var realityModel = ModelComponent(mesh: model.mesh.realityMesh, materials: [])
                if let mat = model.material.realityMaterial
                {
                    realityModel.materials = [mat]
                }
                entity.components.set(realityModel)
            }
            entity.components.set(state)
        }
        remover: { (entity, _, model) in
            var state = entity.components[AlloModelStateComponent.self] ?? AlloModelStateComponent()
            state.loadingTask?.cancel()
            state.entity?.removeFromParent()
            entity.components.remove(AlloModelStateComponent.self)
        }
    }
    
    /// Stop syncing Alloverse<>RealityKit. Call this to break reference cycles, e g when your RealityView disappears (i e in `onDisappear()`).
    public func stopSyncing()
    {
        cancellables.forEach { $0.cancel() }; cancellables.removeAll()
    }
}


extension allonet2.Model.Mesh
{
    var realityMesh: RealityKit.MeshResource
    {
        switch self
        {
        case .builtin(name: let name): fatalError("Must use Model's factory to also load material")
        case .asset(id: let id): fatalError("not implemented")
        case .box(size: let size, cornerRadius: let cornerRadius):
            return .generateBox(size: size, cornerRadius: cornerRadius)
        case .plane(width: let width, depth: let depth, cornerRadius: let cornerRadius):
            return .generatePlane(width: width, depth: depth, cornerRadius: cornerRadius)
        case .sphere(radius: let radius):
            return .generateSphere(radius: radius)
        case .cylinder(height: let height, radius: let radius):
            if #available(macOS 15.0, *) {
                return .generateCylinder(height: height, radius: radius)
            } else {
                return .generateBox(size: .init(x: radius * 2, y: height, z: radius * 2), cornerRadius: radius)
            }
        }
    }
}

extension allonet2.Model.Material
{
    var realityMaterial: RealityKit.Material?
    {
        switch self
        {
        case .color(let color, let metallic):
            return RealityKit.SimpleMaterial(color: color.realityColor, isMetallic: metallic)
        default:
            return nil
        }
    }
}

extension Collision
{
    var realityShapes: [ShapeResource]
    {
        shapes.map
        {
            switch $0
            {
            case .box(let size):
                return .generateBox(size: size)
            }
        }
    }
}

extension allonet2.Color
{
    var realityColor: RealityKit.Material.Color
    {
        switch self
        {
        case .rgb(red: let red, green: let green, blue: let blue, alpha: let alpha):
            return RealityKit.Material.Color(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        case .hsv(hue: let hue, saturation: let saturation, value: let value, alpha: let alpha):
            return RealityKit.Material.Color(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: CGFloat(value), alpha: CGFloat(alpha))
       }
    }
}

@available(macOS 15.0, *)
extension HoverEffect
{
    var realityEffect: HoverEffectComponent.HoverEffect
    {
        switch style
        {
        case .spotlight(color: let color, strength: let strength):
            return .spotlight(.init(color: color.realityColor, strength: 0.5))
        }
    }
}
