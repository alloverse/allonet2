//
//  ConnectedClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation

internal class ConnectedClient
{
    let session: AlloSession
    var announced = false
    var ackdRevision : StateRevision? // Last ack'd place contents revision, or nil if none
    var cid: ClientId = UUID()
    var avatar: EntityID? // Assigned in the place server upon successful client announce

    init(session: AlloSession)
    {
        self.session = session
    }
}
