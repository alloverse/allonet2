//
//  PlaceContents+Changes.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-10.
//

extension PlaceState
{
    /// Client: Find the historical state at the given revision, and apply the given changeset to it, and use it as the freshly updated current state.
    /// Server: Apply the accumulated changes from interactions since last tick, and create a new state that we can broadcast to clients.
    internal func applyChangeSet(_ changeSet: PlaceChangeSet, from oldRevision: Int64, to newRevision: Int64) -> Bool
    {
        guard let old = getHistory(at: oldRevision) else { return false }
        
        let new = old.applyChangeSet(changeSet, for: newRevision)
        self.changeSet = changeSet
        setCurrent(contents: new)
        callChangeObservers()
        return true
    }
    
    /// Client: When server can't give us a delta, use this full snapshot instead. This is e g true for the first delta.
    internal func applyFullSnapshot(_ snapshot: PlaceContents)
    {
        // Derive a delta so we can use it for calling callbacks
        self.changeSet = current.changeSet(from: self.current)
        setCurrent(contents: snapshot)
        
        callChangeObservers()
    }
    
    private func getHistory(at revision: Int64) -> PlaceContents?
    {
        return history.reversed().first {
            return $0.revision == revision
        }
    }
    
    // Also adds the new current state to history
    private func setCurrent(contents: PlaceContents)
    {
        history.append(contents)
        // maybe go by age in wall time instead?
        if history.count > 100 { history.removeFirst() }
        current = contents
    }
}

extension PlaceContents
{
    internal func changeSet(from previous: PlaceContents) -> PlaceChangeSet
    {
        // Capturing new and removed entities is easy. Just diff the two lists.
        let newEntities = entities.filter {
            !previous.entities.keys.contains($0.key)
        }.map { PlaceChange.entityAdded($0.value) }
        let removedEntities = previous.entities.filter {
            !entities.keys.contains($0.key)
        }.map { PlaceChange.entityRemoved($0.value) }
        
        // Then we have dicts of dicts of components to do added-updated-removed checks for too;
        // do this non-functionally so we don't have to do more comparisons than needed.
        var added : [PlaceChange] = []
        var updated : [PlaceChange] = []
        var removed : [PlaceChange] = []
        
        // For every component type in the new set of components...
        for (componentTypeId, newOrUpdatedComponents) in components.lists
        {
            let prevComponents = previous.components.lists[componentTypeId] ?? [:]
            
            // compare to the old list of the same component type to see if it's been added or updated
            for (entityId, component) in newOrUpdatedComponents
            {
                let prev = prevComponents[entityId]
                if prev == nil
                {
                    added.append(.componentAdded(entityId, component))
                }
                else if !component.isEqualTo(prev!)
                {
                    updated.append(.componentUpdated(entityId, component))
                }
            }
            // compare the old list to the new to see if any are missing in the new, which means removal
            for (entityId, prevComponent) in prevComponents
            {
                let new = newOrUpdatedComponents[entityId]
                if new == nil
                {
                    removed.append(.componentRemoved(entityId, prevComponent))
                }
            }
        }
        
        // Since the above is based on the new list of components, it won't catch removal of the
        // last component of the type, since that list won't be in the list of lists at all. So special case it.
        for (componentTypeId, prevComponents) in previous.components.lists
        {
            let newOrUpdatedComponents = components.lists[componentTypeId]
            if newOrUpdatedComponents == nil
            {
                for (entityId, prevComponent) in prevComponents
                {
                    removed.append(.componentRemoved(entityId, prevComponent))
                }
            }
        }
        
        return PlaceChangeSet(changes: newEntities + removedEntities + added + updated + removed)
    }
    
    internal func applyChangeSet(_ changeSet: PlaceChangeSet, for newRevision: Int64) -> PlaceContents
    {
        var entities: [EntityID: Entity] = self.entities
        var lists = self.components.lists
        for change in changeSet.changes
        {
            switch change
            {
            case .entityAdded(let e):
                entities[e.id] = e
            case .entityRemoved(let e):
                entities[e.id] = nil
            case .componentAdded(let eid, let component):
                let key = type(of:component).componentTypeId
                lists[key, default: [:]][eid] = component
            case .componentUpdated(let eid, let component):
                let key = type(of:component).componentTypeId
                lists[key]![eid]! = component
            case .componentRemoved(let eid, let component):
                lists[type(of:component).componentTypeId]![eid] = nil
            }
        }
        return PlaceContents(revision: newRevision, entities: entities, components: Components(lists: lists))
    }
}

