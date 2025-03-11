//
//  Intent.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

/// "Intent" is the unreliable state being sent every heartbeat from client to server. It is used to communicate immediate movement, and protocol metadata.
public struct Intent : Codable
{
    public let ackStateRev: StateRevision
}
