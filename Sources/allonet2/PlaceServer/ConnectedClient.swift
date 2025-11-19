//
//  ConnectedClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation
import Logging

internal class ConnectedClient
{
    let session: AlloSession
    let status: ConnectionStatus
    var identity: Identity? = nil
    var announced = false
    var ackdRevision : StateRevision? // Last ack'd place contents revision, or nil if none
    var cid: ClientId = UUID()
    var avatar: EntityID? // Assigned in the place server upon successful client announce
    var logger: Logger
    var remoteLoggers: [String: Logger] = [:]

    init(session: AlloSession, status: ConnectionStatus)
    {
        self.session = session
        self.status = status
        self.logger = Logger(label: "place.server").forClient(self.cid)
    }
}
