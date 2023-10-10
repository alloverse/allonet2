import Foundation

@objc
class World
{
    var revision: Int64 = 0
    var components: Dictionary<String, [Component]> = [:]
    var entities: Array<Entity> = []
}

struct Component 
{
    let eid: String;
}

struct Entity
{
    let eid: String
    let ownerAgentId: String
}

@_cdecl("entity_create")
func CreateEntity(world: World, eid: String)
{
    let ent = Entity(eid: eid, ownerAgentId: "")
    world.entities.append(ent)
}