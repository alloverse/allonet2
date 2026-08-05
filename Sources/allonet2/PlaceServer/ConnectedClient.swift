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
    var latestIntent: Intent? // Latest intent received from this client
    var velocity: SIMD2<Float> = .zero // Current movement velocity, simulated from latestIntent.moveDirection
    var simulatedTransform: Transform? // Avatar transform the movement sim owns while moving; nil at rest
    var grabBase: (actuated: EntityID, transform: Transform)? // The actuated entity's transform at grab start; constraints measure from it
    var grabSimulated: Transform? // Last transform the grab sim queued, to skip no-op ticks

    /// Take this client out of the movement simulation, so nothing more is queued for its avatar.
    func stopMoving()
    {
        latestIntent?.moveDirection = .zero
        velocity = .zero
        simulatedTransform = nil
    }
    var cid: ClientId = UUID()
    var avatar: EntityID? // Assigned in the place server upon successful client announce
    var logger: Logger
    var remoteLoggers: [String: Logger] = [:]

    init(session: AlloSession, status: ConnectionStatus)
    {
        self.session = session
        self.status = status
        self.logger = Logger(labelSuffix: "place.server").forClient(self.cid)
    }
}
