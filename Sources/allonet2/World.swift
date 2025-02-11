import Foundation

public struct World: Codable, Equatable
{
    public var revision: Int64 = 0
    public var components: Dictionary<String, [Component]> = [:]
    public var entities: Dictionary<String, Entity> = [:]
}

public struct Component: Codable, Equatable
{
    public let eid: String;
}

public struct Entity: Codable, Equatable
{
    public let eid: String
    public let ownerAgentId: String
}

