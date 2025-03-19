//
//  RealityViewMapper.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-18.
//

import RealityKit
import Combine
import allonet2

/// The RealityViewMapper creates and maintains RealityKit entities and components to perfectly match corresponding entities and components inside an Alloverse connection's PlaceContents.
public class RealityViewMapper
{
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
        startSyncingOf(networkComponentType: allonet2.Transform.self, to: RealityKit.Transform.self) { (entity, transform) in
            entity.setTransformMatrix(transform.matrix, relativeTo: entity.parent)
        }
    }
    
    /// In addition to syncing the Standard Components from `startSyncing()`, also sync other/custom components with this method, called directly after `startSyncing` but before the AlloClient connects.
    public func startSyncingOf<T, U>(networkComponentType: T.Type, to realityComponentType: U.Type, using updater: @escaping (RealityKit.Entity, T) -> Void) where T : allonet2.Component, U : RealityKit.Component
    {
        netstate.observers[networkComponentType.self].updated.sink { (eid, netcomp) in
            guard let guient = self.guiroot.findEntity(named: eid) else { return }
            updater(guient, netcomp)
        }.store(in: &cancellables)
        netstate.observers[networkComponentType.self].removed.sink { (eid, netcomp) in
            guard let guient = self.guiroot.findEntity(named: eid) else { return }
            guient.components[realityComponentType.self] = nil
        }.store(in: &cancellables)
    }
    
    /// Stop syncing Alloverse<>RealityKit. Call this to break reference cycles, e g when your RealityView disappears (i e in `onDisappear()`).
    public func stopSyncing()
    {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
}
