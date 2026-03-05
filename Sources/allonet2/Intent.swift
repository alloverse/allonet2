//
//  Intent.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import simd

/// "Intent" is the unreliable state being sent every heartbeat from client to server. It is used to communicate immediate movement, and protocol metadata.
public struct Intent : Codable
{
    public var ackStateRev: StateRevision

    /// Desired movement direction, normalized -1..1 per axis.
    /// x = strafe (positive = right), y = forward (positive = forward).
    /// The server applies a speed constant and delta time to convert this to actual displacement.
    public var moveDirection: SIMD2<Float> = .zero
}
