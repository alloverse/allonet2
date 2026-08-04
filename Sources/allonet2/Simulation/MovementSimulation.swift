//
//  MovementSimulation.swift
//  allonet2
//

import Foundation
import simd

/// Avatar movement: velocity eases toward the intent's direction, position integrates velocity.
/// Kept pure so a client can run the same step for local prediction (cf. allonet1's allosim_stick_movement).
public enum MovementSimulation
{
    /// Movement speed in meters per second. 2.0 (the old alloplace2 VR convention) reads as crawling in the top-down diorama.
    public static let maxSpeed: Float = 5.0
    /// Time constant for easing toward target velocity; ~95% there after 3*tau.
    public static let accelerationTau: Float = 0.12
    /// Below this speed with no input, movement is considered stopped.
    public static let restSpeed: Float = 0.01

    /// One integration step. Returns the moved transform, or nil once at rest (no update needed).
    @MainActor
    public static func step(transform: Transform, velocity: inout SIMD2<Float>, direction: SIMD2<Float>, dt: Float) -> Transform?
    {
        // Direction is untrusted client input; cap its magnitude so nobody exceeds maxSpeed.
        let magnitude = simd_length(direction)
        let capped = magnitude > 1 ? direction / magnitude : direction
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
