//
//  PlaceServer+ECS.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation
import simd

extension PlaceServer
{
    /// Movement speed in meters per second (matching old alloplace2 convention)
    static let movementSpeed: Float = 2.0

    internal func appendChanges(_ changes: [PlaceChange]) async
    {
        outstandingPlaceChanges.append(contentsOf: changes)
        await heartbeat.markChanged()
    }

    func applyAndBroadcastState()
    {
        simulateMovement()

        let success = place.applyChangeSet(PlaceChangeSet(changes: outstandingPlaceChanges, fromRevision: place.current.revision, toRevision: place.current.revision + 1))
        assert(success) // bug if this doesn't succeed
        outstandingPlaceChanges.removeAll()
        for client in clients.values {
            let lastContents = client.ackdRevision.flatMap { place.getHistory(at: $0) } ?? PlaceContents(logger: logger)
            let changeSet = place.current.changeSet(from: lastContents)

            client.session.send(placeChangeSet: changeSet)
        }
    }

    /// Apply movement from client intents to avatar transforms.
    /// Called every heartbeat tick before state is broadcast.
    private func simulateMovement()
    {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(now - lastSimulationTime)
        lastSimulationTime = now

        // Clamp dt to avoid huge jumps after long idle periods
        let clampedDt = min(dt, 0.25)

        let transforms = place.current.components[Transform.self]
        var anyMoving = false
        for client in clients.values
        {
            guard
                let intent = client.latestIntent,
                intent.moveDirection != .zero,
                let avatarId = client.avatar,
                let currentTransform = transforms[avatarId]
            else { continue }

            anyMoving = true
            let displacement = intent.moveDirection * Self.movementSpeed * clampedDt
            var newTransform = currentTransform
            newTransform.matrix.translation.x += displacement.x
            newTransform.matrix.translation.z -= displacement.y // SIMD2.y (forward) maps to -Z in 3D

            outstandingPlaceChanges.append(
                .componentUpdated(avatarId, AnyComponent(newTransform))
            )
        }

        // Keep ticking while clients are moving
        if anyMoving
        {
            Task { await heartbeat.markChanged() }
        }
    }
    
    func createEntity(from description:EntityDescription, for client: ConnectedClient) async -> EntityData
    {
        let (ent, changes) = description.changes(for: client.cid)
        client.logger.info("Creating entity \(ent.id) with \(description.components.count) components and \(description.children.count) children")
        await appendChanges(changes)
        
        return ent
    }
    
    func removeEntity(with id: EntityID, mode: EntityRemovalMode, for client: ConnectedClient?) async throws(AlloverseError)
    {
        var clogger = self.logger
        if let cid = client?.cid { clogger = clogger.forClient(cid) }
        clogger.info("Removing entity \(id)")
        let ent = place.current.entities[id]

        guard let ent = ent else {
            throw AlloverseError(code: PlaceErrorCode.notFound, description: "No such entity")
        }
        guard client == nil || ent.ownerClientId == client!.cid else {
            throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "That's not your entity to remove")
        }
        
        await appendChanges([
            .entityRemoved(ent)
        ] + place.current.components.componentsForEntity(id).map {
            PlaceChange.componentRemoved(ent, $0.value)
        })
                
        // TODO: Handle child entities
    }
    
    func removeEntites(ownedBy cid: ClientId) async
    {
        for (eid, ent) in place.current.entities
        {
            if ent.ownerClientId == cid
            {
                try? await removeEntity(with: eid, mode: .reparent, for: nil)
            }
        }
    }

    
    func changeEntity(eid: EntityID, addOrChange: [AnyComponent], remove: [ComponentTypeID], for client: ConnectedClient?) async throws(AlloverseError)
    {
        (client?.logger ?? logger).trace("Changing entity \(eid)")
        let ent = place.current.entities[eid]
        
        guard let ent = ent else {
            throw AlloverseError(code: PlaceErrorCode.notFound, description: "No such entity")
        }
        /*guard client == nil || ent.ownerAgentId == client!.cid.uuidString else {
            throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "That's not your entity to modify")
        }*/ // Re-enable this when we have ACLs
        
        let addOrChanges = addOrChange.map
        {
            if let _ = place.current.components[$0.componentTypeId]?[eid]
            {
                return PlaceChange.componentUpdated(eid, $0)
            }
            else
            {
                return PlaceChange.componentAdded(eid, $0)
            }
        }
        let removals = try remove.map
        { (ctid: ComponentTypeID) throws(AlloverseError) -> PlaceChange in
            guard let existing = place.current.components[ctid]?[eid] else {
                throw AlloverseError(code: PlaceErrorCode.notFound, description: "No such entity")
            }
            return PlaceChange.componentRemoved(ent, existing)
        }
        
        await appendChanges(addOrChanges + removals)
    }

}

internal extension EntityDescription
{
    internal func changes(for ownerClientId: ClientId) -> (EntityData, [PlaceChange])
    {
        let ent = EntityData(id: EntityID.random(), ownerClientId: ownerClientId)
        return (
            ent,
            [
                .entityAdded(ent),
                .componentAdded(ent.id, AnyComponent(Transform())) // every entity should have Transform
            ]
            + components.map { .componentAdded(ent.id, $0) }
            + children.flatMap {
                let (child, changes) = $0.changes(for: ownerClientId)
                let relationship = PlaceChange.componentAdded(child.id, AnyComponent(Relationships(parent: ent.id)))
                return changes + [relationship]
            }
        )
    }
}
