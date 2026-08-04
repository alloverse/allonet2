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
    internal func appendChanges(_ changes: [PlaceChange]) async
    {
        // Someone other than the movement sim moving an avatar (a teleport, a correction) wins:
        // drop the cached simulated position, or the next tick would undo their change.
        for case .componentUpdated(let eid, let component) in changes
            where component.componentTypeId == Transform.componentTypeId
        {
            for client in clients.values where client.avatar == eid { client.simulatedTransform = nil }
        }
        outstandingPlaceChanges.append(contentsOf: changes)
        await heartbeat.markChanged()
    }

    func applyAndBroadcastState()
    {
        let success = place.applyChangeSet(PlaceChangeSet(changes: outstandingPlaceChanges, fromRevision: place.current.revision, toRevision: place.current.revision + 1))
        assert(success) // bug if this doesn't succeed
        outstandingPlaceChanges.removeAll()
        for client in clients.values {
            let lastContents = client.ackdRevision.flatMap { place.getHistory(at: $0) } ?? PlaceContents(logger: logger)
            let changeSet = place.current.changeSet(from: lastContents)

            client.session.send(placeChangeSet: changeSet)
        }
    }

    /// Steps avatar movement at a fixed cadence while any client is moving; the heartbeat broadcasts the resulting changes.
    /// Started from the intent handler on nonzero moveDirection; ends itself once every avatar is at rest.
    internal func startMovementLoopIfNeeded()
    {
        guard movementLoop == nil else { return }
        movementLoop = Task {
            var lastTick = ContinuousClock.now
            while !Task.isCancelled
            {
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { break } // cancelled: stop without simulating another step
                let now = ContinuousClock.now
                let elapsed = now - lastTick
                lastTick = now
                let measured = Float(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
                // A stalled main actor or a sleeping host would otherwise integrate the whole
                // pause in one step and teleport the avatar; better to lose that time than to jump.
                guard await stepMovement(dt: min(measured, 0.1)) else { break }
            }
            movementLoop = nil
        }
    }

    private func stepMovement(dt: Float) async -> Bool
    {
        let transforms = place.current.components[Transform.self]
        var changes: [PlaceChange] = []
        for client in clients.values
        {
            let direction = client.latestIntent?.moveDirection ?? .zero
            guard direction != .zero || client.velocity != .zero,
                  let avatarId = client.avatar,
                  // Integrate from our own last simulated transform: several ticks can run before the
                  // heartbeat commits them, and re-reading committed state would make each of those
                  // ticks start from the same base, so all but the last displacement is overwritten.
                  let transform = client.simulatedTransform ?? transforms[avatarId]
            else { continue }

            guard let moved = MovementSimulation.step(transform: transform, velocity: &client.velocity, direction: direction, dt: dt)
            else
            {
                // At rest: drop the cache so a teleport or other external transform change is picked up.
                client.simulatedTransform = nil
                continue
            }

            client.simulatedTransform = moved
            changes.append(.componentUpdated(avatarId, AnyComponent(moved)))
        }
        guard !changes.isEmpty else { return false }
        // Deliberately not appendChanges: that invalidates the cache these changes just filled.
        outstandingPlaceChanges.append(contentsOf: changes)
        await heartbeat.markChanged()
        return true
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
