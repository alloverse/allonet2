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
    /// Set by the place when it accepted this client *as an app*, unlike `identity`, which is
    /// whatever the client claimed to be. Anything granting app privileges reads this one.
    var authenticatedAsApp = false
    var announced = false
    var ackdRevision : StateRevision? // Last ack'd place contents revision, or nil if none
    var latestIntent: Intent? // Latest intent received from this client
    var velocity: SIMD2<Float> = .zero // Current movement velocity, simulated from latestIntent.moveDirection
    var simulatedTransform: Transform? // Avatar transform the movement sim owns while moving; nil at rest
    var grabBase: (actuated: EntityID, transform: Transform)? // The actuated entity's transform at grab start; constraints measure from it
    var grabSimulated: Transform? // Last transform the grab sim queued, to skip no-op ticks

    /// Take this client out of the movement and grab simulations, so nothing more is queued for its entities.
    func stopMoving()
    {
        latestIntent?.moveDirection = .zero
        velocity = .zero
        simulatedTransform = nil
        stopGrabbing()
    }

    /// Forget an in-progress grab, so nothing more is queued for the grabbed entity.
    func stopGrabbing()
    {
        latestIntent?.grab = nil
        grabBase = nil
        grabSimulated = nil
    }
    var cid: ClientId = UUID()
    /// Bearer token this client uses to publish assets over HTTP, where it has no session to
    /// identify it. Minted at announce, revoked on disconnect. 256 bits from the system CSPRNG.
    let assetToken = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
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
