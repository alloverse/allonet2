import Foundation

class World: Codable
{
    var revision: Int64 = 0
    var components: Dictionary<String, [Component]> = [:]
    var entities: Array<Entity> = []
}

struct Component: Codable
{
    let eid: String;
}

struct Entity: Codable
{
    let eid: String
    let ownerAgentId: String
}

