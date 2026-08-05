//
//  GrabSimulation.swift
//  allonet2
//

import Foundation
import simd

/// Grabbed entities: each tick, pose the actuated entity at the grabber's transform
/// composed with the grab's offset, constrained per axis against where the grab started.
/// Kept pure, like MovementSimulation, so it's testable and client-predictable.
public enum GrabSimulation
{
    /// The actuated entity's new local transform, or nil when the input is unusable
    /// (non-finite or degenerate matrix — client input is untrusted) and nothing must move.
    ///
    /// `base` is the actuated entity's local transform at grab start: constraints measure
    /// the *movement* from there, so a fraction limits displacement, not convergence rate.
    /// `actuatedFromEntity` maps the grabbed entity's space into the actuated entity's:
    /// identity when they're the same; otherwise the ancestor follows the handle at its offset.
    @MainActor
    public static func step(grab: GrabIntent, grabbable: Grabbable, base: Transform,
                            grabberToWorld: simd_float4x4, parentToWorld: simd_float4x4,
                            actuatedFromEntity: simd_float4x4 = .identity) -> Transform?
    {
        guard grab.grabberFromEntity.isFinite else { return nil }
        let entityToWorld = grabberToWorld * grab.grabberFromEntity
        let targetLocal = parentToWorld.inverse * entityToWorld * actuatedFromEntity.inverse

        let t = clamp(grabbable.translationConstraint, min: 0, max: 1)
        let r = clamp(grabbable.rotationConstraint, min: 0, max: 1)

        // Constraints act per axis in the actuated entity's grab-start local frame, and the
        // output is rebuilt from the base scale plus constrained rotation and translation,
        // so a client-supplied matrix can't inject scale or shear.
        let baseRotation = base.matrix.rotation
        let deltaLocal = baseRotation.inverse.act(targetLocal.translation - base.matrix.translation)
        // Euler-lerp is exact for the common all-0/all-1 fractions; approximate between.
        let relativeEuler = (baseRotation.inverse * targetLocal.rotation).eulerAngles

        var constrained = simd_float4x4.identity
        constrained.rotation = baseRotation * simd_quatf(eulerAngles: relativeEuler * r)
        constrained.scale = base.matrix.scale
        constrained.translation = base.matrix.translation + baseRotation.act(deltaLocal * t)
        // Rotation extraction from a degenerate (non-rotation) input can go non-finite.
        guard constrained.isFinite else { return nil }
        return Transform(matrix: constrained)
    }
}

public extension simd_float4x4
{
    var isFinite: Bool
    {
        for column in [columns.0, columns.1, columns.2, columns.3]
        {
            if !(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite) { return false }
        }
        return true
    }
}

public extension simd_quatf
{
    /// Intrinsic XYZ euler decomposition; recomposing with init(eulerAngles:) round-trips.
    var eulerAngles: SIMD3<Float>
    {
        let m = simd_float3x3(self)
        // Guard asin's domain: accumulated float error can push the value a hair outside ±1.
        let sinY = max(-1, min(1, -m[0].z))
        let y = asin(sinY)
        if abs(sinY) > 0.9999
        {
            // Gimbal lock: z is unrecoverable, fold it into x.
            return [atan2(-m[2].y, m[1].y), y, 0]
        }
        return [atan2(m[1].z, m[2].z), y, atan2(m[0].y, m[0].x)]
    }

    init(eulerAngles e: SIMD3<Float>)
    {
        self = simd_quatf(angle: e.z, axis: [0, 0, 1])
            * simd_quatf(angle: e.y, axis: [0, 1, 0])
            * simd_quatf(angle: e.x, axis: [1, 0, 0])
    }
}

public extension PlaceContents
{
    /// Composes a world transform by walking Relationships. `overrides` supplies local
    /// transforms the simulation hasn't committed yet. Returns nil on a Relationships cycle
    /// or a missing Transform along the path — client-writable data must not hang the
    /// server, and a Transform-less node must not silently pose at its parent's origin.
    func transformToWorld(of eid: EntityID, overrides: [EntityID: Transform] = [:]) -> simd_float4x4?
    {
        var transform = simd_float4x4.identity
        var current: EntityID? = eid
        var visited = Set<EntityID>()
        while let id = current
        {
            guard visited.insert(id).inserted,
                  let local = overrides[id]?.matrix ?? components[Transform.self][id]?.matrix
            else { return nil }
            transform = local * transform
            current = components[Relationships.self][id]?.parent
        }
        return transform
    }
}
