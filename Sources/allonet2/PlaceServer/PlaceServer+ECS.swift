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
        // Someone other than the movement sim touching an avatar wins over the simulation:
        // a teleport becomes the new base to move from (not just invalidation - a sim tick can
        // run before the heartbeat commits the queued teleport, and must not resurrect the old
        // position), and a removed avatar stops moving, or the next tick would queue an update
        // for a nonexistent component and make the whole changeset inapplicable. Removing an
        // entity involved in a grab ends the grab for the same reason.
        for change in changes
        {
            switch change
            {
            case .componentUpdated(let eid, let component) where component.componentTypeId == Transform.componentTypeId:
                for client in clients.values where client.avatar == eid
                {
                    client.simulatedTransform = component.decoded() as? Transform
                }
            case .entityRemoved(let edata):
                for client in clients.values
                {
                    if client.avatar == edata.id { client.stopMoving() }
                    let grab = client.latestIntent?.grab
                    if grab?.entity == edata.id || grab?.grabber == edata.id || client.grabBase?.actuated == edata.id { client.stopGrabbing() }
                }
            case .componentRemoved(let edata, let component) where component.componentTypeId == Transform.componentTypeId:
                for client in clients.values
                {
                    if client.avatar == edata.id { client.stopMoving() }
                    if client.grabBase?.actuated == edata.id { client.stopGrabbing() }
                }
            default: break
            }
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
        // Grabs run after movement, so a carried entity follows this tick's avatar transform.
        for client in clients.values
        {
            guard let change = stepGrab(for: client) else { continue }
            changes.append(change)
        }
        guard !changes.isEmpty else { return false }
        // Deliberately not appendChanges: that invalidates the cache these changes just filled.
        outstandingPlaceChanges.append(contentsOf: changes)
        await heartbeat.markChanged()
        return true
    }
    
    /// One grab tick for one client. Everything in the intent is untrusted: the grabbed
    /// entity must be Grabbable, the grabber must be the client's avatar or a descendant,
    /// an actuation target must really be an ancestor. Returns nil when nothing (new) should move.
    private func stepGrab(for client: ConnectedClient) -> PlaceChange?
    {
        guard let grab = client.latestIntent?.grab else {
            client.grabBase = nil
            client.grabSimulated = nil
            return nil
        }
        let contents = place.current
        guard let grabbable = contents.components[Grabbable.self][grab.entity] else {
            client.logger.warning("Ignoring grab of \(grab.entity): not Grabbable")
            return nil
        }
        guard let avatarId = client.avatar, isEntity(grab.grabber, selfOrDescendantOf: avatarId, in: contents) else {
            client.logger.warning("Ignoring grab by \(grab.grabber): not the grabbing client's avatar or a descendant")
            return nil
        }

        // The grabber may hang off the client's avatar; feed the sim this tick's
        // uncommitted avatar transform so carrying doesn't lag a walking avatar.
        var overrides: [EntityID: Transform] = [:]
        if let simulated = client.simulatedTransform
        {
            overrides[avatarId] = simulated
        }

        guard let (actuated, actuatedFromEntity) = resolveActuation(of: grab.entity, as: grabbable.actuateOn, in: contents, overrides: overrides) else {
            client.logger.warning("Ignoring grab of \(grab.entity): actuation target \(grabbable.actuateOn) is not among its ancestors")
            return nil
        }
        // Revalidated every tick: the actuated entity can lose its Transform mid-grab.
        guard let actuatedTransform = contents.components[Transform.self][actuated] else {
            client.grabBase = nil
            client.grabSimulated = nil
            return nil
        }
        if client.grabBase?.actuated != actuated
        {
            client.grabBase = (actuated, actuatedTransform)
            client.grabSimulated = nil
        }

        let parentToWorld: simd_float4x4
        if let parent = contents.components[Relationships.self][actuated]?.parent
        {
            guard let composed = contents.transformToWorld(of: parent, overrides: overrides) else { return nil }
            parentToWorld = composed
        }
        else { parentToWorld = .identity }
        guard
            let grabberToWorld = contents.transformToWorld(of: grab.grabber, overrides: overrides),
            let moved = GrabSimulation.step(grab: grab, grabbable: grabbable, base: client.grabBase!.transform,
                                            grabberToWorld: grabberToWorld, parentToWorld: parentToWorld,
                                            actuatedFromEntity: actuatedFromEntity),
            moved != client.grabSimulated
        else { return nil }

        client.grabSimulated = moved
        return .componentUpdated(actuated, AnyComponent(moved))
    }

    /// Resolves which entity a grab moves, verifying ancestry, and composes the transform
    /// from the grabbed entity's space into the actuated entity's space along the way.
    private func resolveActuation(of eid: EntityID, as actuateOn: Grabbable.ActuateOn, in contents: PlaceContents, overrides: [EntityID: Transform])
        -> (actuated: EntityID, actuatedFromEntity: simd_float4x4)?
    {
        let target: EntityID?
        switch actuateOn
        {
        case .entity: return (eid, .identity)
        case .parent: target = contents.components[Relationships.self][eid]?.parent
        case .ancestor(let ancestor): target = ancestor
        }
        guard let target else { return nil }
        var composed = simd_float4x4.identity
        var current = eid
        var visited = Set<EntityID>()
        while current != target
        {
            guard visited.insert(current).inserted,
                  let parent = contents.components[Relationships.self][current]?.parent
            else { return nil }
            composed = (overrides[current]?.matrix ?? contents.components[Transform.self][current]?.matrix ?? .identity) * composed
            current = parent
        }
        return (target, composed)
    }

    private func isEntity(_ eid: EntityID, selfOrDescendantOf ancestorId: EntityID, in contents: PlaceContents) -> Bool
    {
        var current: EntityID? = eid
        var visited = Set<EntityID>()
        while let id = current, visited.insert(id).inserted
        {
            if id == ancestorId { return true }
            current = contents.components[Relationships.self][id]?.parent
        }
        return false
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
