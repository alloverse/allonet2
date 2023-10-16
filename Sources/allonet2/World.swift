import Foundation

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

@_cdecl("world_create")
func CreateWorld()
{
    let world = World()
    print("heyooo")
}

@_cdecl("entity_create")
func CreateEntity(world: UnsafeRawPointer, eid: String)
{
    let world = world.load(as: World.self)
    let ent = Entity(eid: eid, ownerAgentId: "")
    world.entities.append(ent)
}