//
//  Intent.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-03-11.
//

import simd
import SIMDTools // float4x4 Codable

/// "Intent" is the unreliable state being sent every heartbeat from client to server. It is used to communicate immediate movement, and protocol metadata.
public struct Intent : Codable
{
    public var ackStateRev: StateRevision

    /// Desired movement direction, normalized -1..1 per axis.
    /// x = strafe (positive = right), y = forward (positive = forward).
    /// The server applies a speed constant and delta time to convert this to actual displacement.
    public var moveDirection: SIMD2<Float> = .zero

    /// A grab in progress, or nil when not grabbing (ported from allonet1's intent grab).
    public var grab: GrabIntent? = nil
}

/// While present in the intent stream, the place server keeps `entity` posed at
/// `grabberFromEntity` relative to `grabber`, within the entity's Grabbable constraints —
/// so a carried entity follows the grabber's movement.
public struct GrabIntent: Codable, Equatable
{
    /// The entity to move. Must carry Grabbable, or the grab is ignored.
    public var entity: EntityID
    /// The entity doing the holding — the client's avatar or a descendant of it (a hand).
    public var grabber: EntityID
    /// The grabbed entity's pose in the grabber's space. Constant = rigid carry; a
    /// pointer-style client updates it per heartbeat to steer the entity instead.
    public var grabberFromEntity: simd_float4x4

    public init(entity: EntityID, grabber: EntityID, grabberFromEntity: simd_float4x4)
    {
        self.entity = entity
        self.grabber = grabber
        self.grabberFromEntity = grabberFromEntity
    }
}
