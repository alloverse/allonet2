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
        // entity involved in a grab ends the grab, and an external transform on the actuated
        // entity rebases it, for the same reasons.
        for change in changes
        {
            switch change
            {
            case .componentUpdated(let eid, let component) where component.componentTypeId == Transform.componentTypeId:
                for client in clients.values where client.avatar == eid
                {
                    client.simulatedTransform = component.decoded() as? Transform
                }
                for client in clients.values where client.grabBase?.actuated == eid
                {
                    // The teleport becomes the new base grab constraints measure from,
                    // or the next tick would overwrite it from the old one.
                    if let transform = component.decoded() as? Transform { client.grabBase = (eid, transform) }
                    else { client.stopGrabbing() }
                    client.grabSimulated = nil
                }
            case .entityRemoved(let edata):
                pendingRemovals.insert(edata.id)
                for client in clients.values
                {
                    if client.avatar == edata.id { client.stopMoving() }
                    let grab = client.latestIntent?.grab
                    if grab?.entity == edata.id || grab?.grabber == edata.id || client.grabBase?.actuated == edata.id { client.stopGrabbing() }
                }
            case .componentRemoved(let edata, let component) where component.componentTypeId == Transform.componentTypeId:
                pendingRemovals.insert(edata.id)
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
        // An empty beat still broadcasts (keepalive) but must not spend a revision; see docs/architecture.md.
        if !outstandingPlaceChanges.isEmpty
        {
            let success = place.applyChangeSet(PlaceChangeSet(changes: outstandingPlaceChanges, fromRevision: place.current.revision, toRevision: place.current.revision + 1))
            assert(success) // bug if this doesn't succeed
            outstandingPlaceChanges.removeAll()
            pendingRemovals.removeAll()
            sweepOrphans()
        }
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
                  // A fresh intent can re-arm movement between a queued removal and its apply;
                  // the queue-time stopMoving hook alone can't prevent the poisoned update.
                  !pendingRemovals.contains(avatarId),
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
        // Revalidated every tick: the actuated entity can lose its Transform mid-grab, and a
        // fresh intent can re-arm the grab between a queued removal and its apply — the
        // queue-time stopGrabbing hook alone can't prevent the poisoned update.
        guard !pendingRemovals.contains(actuated),
              let actuatedTransform = contents.components[Transform.self][actuated] else {
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
            // Like transformToWorld, a missing Transform rejects the path rather than
            // silently posing the node at its parent's origin.
            guard visited.insert(current).inserted,
                  let parent = contents.components[Relationships.self][current]?.parent,
                  let local = overrides[current]?.matrix ?? contents.components[Transform.self][current]?.matrix
            else { return nil }
            composed = local * composed
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

    func createEntity(from description:EntityDescription, for client: ConnectedClient) async throws(AlloverseError) -> EntityData
    {
        let (ent, changes) = description.changes(for: client.cid)
        // Every parent a new entity names must resolve, to an entity that exists once this beat
        // commits or one created here; otherwise the place would hold a child nothing can render.
        var willExist = projectedEntities
        for case .entityAdded(let e) in changes { willExist.insert(e.id) }
        for change in changes
        {
            guard case .componentAdded(let eid, let comp) = change, let rel = try relationship(in: comp) else { continue }
            guard willExist.contains(rel.parent) else {
                throw AlloverseError(code: PlaceErrorCode.notFound, description: "Can't parent entity \(eid) to \(rel.parent): no such entity")
            }
        }
        client.logger.info("Creating entity \(ent.id) with \(description.components.count) components and \(description.children.count) children")
        await appendChanges(changes)

        return ent
    }
    
    func removeEntity(with id: EntityID, mode: EntityRemovalMode, for client: ConnectedClient?) async throws(AlloverseError)
    {
        var clogger = self.logger
        if let cid = client?.cid { clogger = clogger.forClient(cid) }
        let ent = place.current.entities[id]

        guard let ent = ent else {
            throw AlloverseError(code: PlaceErrorCode.notFound, description: "No such entity")
        }
        guard client == nil || ent.ownerClientId == client!.cid else {
            throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "That's not your entity to remove")
        }

        // Reparenting children to root reaches committed state through paths the checks can't
        // see and detaches subtrees on the wire in an order visors mishandle; not worth its bugs
        // until something needs it, so fail loudly rather than half-support it. The invariant is
        // held by cascade plus the commit-time sweep.
        guard mode == .cascade else {
            throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Only cascade removal is supported")
        }
        var changes: [PlaceChange] = []
        for rid in [id] + descendants(of: id, using: childIndex(place.current))
        {
            guard let e = place.current.entities[rid] else { continue }
            clogger.info("Removing entity \(rid)")
            changes.append(.entityRemoved(e))
            changes += place.current.components.componentsForEntity(rid).map { PlaceChange.componentRemoved(e, $0.value) }
        }
        await appendChanges(changes)
    }

    /// The invariant, enforced where every change commits: a client force-unwraps a child's
    /// parent, so the place must never broadcast a revision that holds one whose parent is gone.
    /// The per-interaction checks stop an app naming a missing parent, but a race the checks
    /// can't see (a parent removed while its child was still pending, a bulk owner-cleanup that
    /// doesn't reparent) can still commit an orphan; drop it and its subtree, loudly, before any
    /// client hears about it.
    private func sweepOrphans()
    {
        let present = Set(place.current.entities.keys)
        let orphans = place.current.entities.keys.filter {
            if let parent = place.current.components[Relationships.self][$0]?.parent { return !present.contains(parent) }
            return false
        }
        guard !orphans.isEmpty else { return }

        let index = childIndex(place.current)
        let doomed = Set(orphans + orphans.flatMap { descendants(of: $0, using: index) })
        logger.warning("Dropping \(doomed.count) orphaned entities whose parent is gone (\(orphans)) - an alloapp let a child outlive its parent; the place won't broadcast a dangling tree.")
        var changes: [PlaceChange] = []
        for rid in doomed
        {
            guard let e = place.current.entities[rid] else { continue }
            // Applied directly, not through appendChanges, so its simulation cleanup is run by hand:
            // a swept avatar that kept moving would queue a Transform update for a gone entity.
            noteRemovalForSimulation(of: rid)
            changes.append(.entityRemoved(e))
            changes += place.current.components.componentsForEntity(rid).map { PlaceChange.componentRemoved(e, $0.value) }
        }
        let ok = place.applyChangeSet(PlaceChangeSet(changes: changes, fromRevision: place.current.revision, toRevision: place.current.revision + 1))
        assert(ok)
    }

    /// Ends the movement and grab a removed entity was party to. `appendChanges` does this inline
    /// for queued removals; the sweep applies directly, so it calls this itself.
    private func noteRemovalForSimulation(of id: EntityID)
    {
        pendingRemovals.insert(id)
        for client in clients.values
        {
            if client.avatar == id { client.stopMoving() }
            let grab = client.latestIntent?.grab
            if grab?.entity == id || grab?.grabber == id || client.grabBase?.actuated == id { client.stopGrabbing() }
        }
    }

    /// A parent -> its direct children, built in one pass so a cascade over N entities isn't N
    /// rescans of the Relationships dictionary.
    private func childIndex(_ contents: PlaceContents) -> [EntityID: [EntityID]]
    {
        var index: [EntityID: [EntityID]] = [:]
        for (eid, rel) in contents.components[Relationships.self] { index[rel.parent, default: []].append(eid) }
        return index
    }

    /// The child index as it will be once this beat's queued relationship changes commit. A cycle
    /// check must use this, not committed state: two entities reparented beneath each other in one
    /// beat each miss the other's still-pending edge and would commit a mutual cycle.
    private func projectedChildIndex() -> [EntityID: [EntityID]]
    {
        var parentOf: [EntityID: EntityID] = [:]
        for (eid, rel) in place.current.components[Relationships.self] { parentOf[eid] = rel.parent }
        for change in outstandingPlaceChanges
        {
            switch change
            {
            case .componentAdded(let eid, let c), .componentUpdated(let eid, let c):
                if let rel = c.decoded(as: Relationships.self) { parentOf[eid] = rel.parent }
            case .componentRemoved(let e, let c) where c.componentTypeId == Relationships.componentTypeId:
                parentOf[e.id] = nil
            case .entityRemoved(let e):
                parentOf[e.id] = nil
            default:
                break
            }
        }
        var index: [EntityID: [EntityID]] = [:]
        for (child, parent) in parentOf { index[parent, default: []].append(child) }
        return index
    }

    /// The `Relationships` in `comp`, or nil when it is another component. Throws rather than traps
    /// on a malformed payload: this runs on untrusted create/change input, and `decodedIfAvailable`
    /// force-tries the decode.
    private func relationship(in comp: AnyComponent) throws(AlloverseError) -> Relationships?
    {
        guard comp.componentTypeId == Relationships.componentTypeId else { return nil }
        guard let rel = comp.decoded(as: Relationships.self) else {
            throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Malformed Relationships payload")
        }
        return rel
    }

    /// Entities that exist once this beat's queued changes commit: committed, plus pending adds,
    /// minus pending removes. A child created moments after its parent, before the heartbeat,
    /// parents to an entity that is pending rather than committed.
    private var projectedEntities: Set<EntityID>
    {
        var ids = Set(place.current.entities.keys)
        for change in outstandingPlaceChanges
        {
            switch change
            {
            case .entityAdded(let e): ids.insert(e.id)
            case .entityRemoved(let e): ids.remove(e.id)
            default: break
            }
        }
        return ids
    }

    /// Every transitive descendant of `id`, cycle-safe against a hostile Relationships loop.
    private func descendants(of id: EntityID, using index: [EntityID: [EntityID]]) -> [EntityID]
    {
        var out: [EntityID] = []
        var seen: Set<EntityID> = [id]
        var stack = index[id] ?? []
        while let next = stack.popLast()
        {
            guard seen.insert(next).inserted else { continue }
            out.append(next)
            stack += index[next] ?? []
        }
        return out
    }

    func removeEntites(ownedBy cid: ClientId) async
    {
        // Cascade, not reparent: a client's whole subtree goes when it leaves. Owner-blind on
        // purpose - a still-connected client's entity parented under the departing one goes too,
        // which the simpler code is worth until cross-owner parenting is actually a thing.
        for (eid, ent) in place.current.entities
        {
            if ent.ownerClientId == cid
            {
                try? await removeEntity(with: eid, mode: .cascade, for: nil)
            }
        }
    }

    
    func changeEntity(eid: EntityID, addOrChange: [AnyComponent], remove: [ComponentTypeID], for client: ConnectedClient?) async throws(AlloverseError)
    {
        (client?.logger ?? logger).trace("Changing entity \(eid)")
        // Projected, not just committed: a write folded in after a removal queued this beat would
        // store a component under an entity that is gone by the time the beat commits.
        guard let ent = place.current.entities[eid], projectedEntities.contains(eid) else {
            throw AlloverseError(code: PlaceErrorCode.notFound, description: "No such entity")
        }
        /*guard client == nil || ent.ownerAgentId == client!.cid.uuidString else {
            throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "That's not your entity to modify")
        }*/ // Re-enable this when we have ACLs

        // A re-parent to a gone entity, to self, or beneath its own descendant would orphan or
        // cycle the tree - and a cycle corrupts every transformToWorld through it.
        for comp in addOrChange
        {
            guard let rel = try relationship(in: comp) else { continue }
            guard rel.parent != eid, !descendants(of: eid, using: projectedChildIndex()).contains(rel.parent) else {
                throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Parenting \(eid) to \(rel.parent) would make a cycle")
            }
            guard projectedEntities.contains(rel.parent) else {
                throw AlloverseError(code: PlaceErrorCode.notFound, description: "Can't parent \(eid) to \(rel.parent): no such entity")
            }
        }

        // Writing the value that is already there is not a change; see docs/architecture.md.
        var addOrChanges: [PlaceChange] = []
        for comp in addOrChange
        {
            guard let existing = projectedComponent(comp.componentTypeId, of: eid) else {
                addOrChanges.append(.componentAdded(eid, comp))
                continue
            }
            guard existing != comp else { continue }
            addOrChanges.append(.componentUpdated(eid, comp))
        }
        let removals = try remove.map
        { (ctid: ComponentTypeID) throws(AlloverseError) -> PlaceChange in
            guard let existing = place.current.components[ctid]?[eid] else {
                throw AlloverseError(code: PlaceErrorCode.notFound, description: "No such entity")
            }
            return PlaceChange.componentRemoved(ent, existing)
        }

        let changes = addOrChanges + removals
        // The caller asked for a state the place already holds: success, and no beat to fire.
        guard !changes.isEmpty else { return }
        await appendChanges(changes)
    }

    /// The value a component type has on `eid` once this beat's queued changes commit, or nil when
    /// it won't be there. Committed state can't see an earlier write in the same coalescing window,
    /// so judging against it would call a re-add an update and make the whole changeset inapplicable.
    private func projectedComponent(_ ctid: ComponentTypeID, of eid: EntityID) -> AnyComponent?
    {
        var value = place.current.components[ctid]?[eid]
        for change in outstandingPlaceChanges
        {
            switch change
            {
            case .componentAdded(let changed, let comp), .componentUpdated(let changed, let comp):
                if changed == eid, comp.componentTypeId == ctid { value = comp }
            case .componentRemoved(let changed, let comp):
                if changed.id == eid, comp.componentTypeId == ctid { value = nil }
            default: break
            }
        }
        return value
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
