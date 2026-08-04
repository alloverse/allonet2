//
//  MovementSimulation.swift
//  allonet2
//

import Foundation
import simd

/// Avatar movement: velocity eases toward the intent's direction, position integrates velocity.
/// Kept pure so a client can run the same step for local prediction (cf. allonet1's allosim_stick_movement).
///
/// The direction is in **place space**, not avatar-local: x is +X and y is -Z regardless of how the
/// avatar is rotated. Clients decide what "forward" means (Koja rotates by its camera before sending),
/// which is what lets a camera-relative UI work without the server knowing about cameras.
/// Assumes the avatar is a root entity: a Relationships parent would make the integrated
/// translation parent-relative, rotating and scaling the movement.
public enum MovementSimulation
{
    /// Movement speed in meters per second. 2.0 (the old alloplace2 VR convention) reads as crawling in the top-down diorama.
    public static let maxSpeed: Float = 5.0
    /// Time constant for easing toward target velocity; ~95% there after 3*tau.
    public static let accelerationTau: Float = 0.12
    /// Below this speed with no input, movement is considered stopped.
    public static let restSpeed: Float = 0.01
    /// Input below this magnitude counts as no input at all, so drift can't keep the simulation awake.
    public static let inputDeadZone: Float = 0.05

    /// One integration step. Returns the moved transform, or nil once at rest (no update needed).
    @MainActor
    public static func step(transform: Transform, velocity: inout SIMD2<Float>, direction: SIMD2<Float>, dt: Float) -> Transform?
    {
        // Direction is untrusted client input. NaN/infinity would poison velocity permanently
        // (every comparison against them is false, so the avatar could never come to rest),
        // and the magnitude cap keeps anyone from exceeding maxSpeed.
        var capped = direction.x.isFinite && direction.y.isFinite ? direction : .zero
        let magnitude = simd_length(capped)
        if magnitude < inputDeadZone { capped = .zero }
        else if magnitude > 1 { capped /= magnitude }
        let target = capped * maxSpeed

        velocity += (target - velocity) * Float(1 - exp(Double(-dt / accelerationTau)))
        if capped == .zero && simd_length(velocity) < restSpeed
        {
            velocity = .zero
            return nil
        }

        var moved = transform
        moved.matrix.translation.x += velocity.x * dt
        moved.matrix.translation.z -= velocity.y * dt // intent y (forward) maps to -Z
        return moved
    }
}
