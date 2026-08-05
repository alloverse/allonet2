import Testing
import simd
@testable import allonet2

@MainActor
struct GrabSimulationTests
{
    private func grab(of entity: EntityID = "sign", by grabber: EntityID = "avatar",
                      offset: simd_float4x4 = .identity) -> GrabIntent
    {
        GrabIntent(entity: entity, grabber: grabber, grabberFromEntity: offset)
    }

    private func translation(_ t: SIMD3<Float>) -> simd_float4x4
    {
        var m = simd_float4x4.identity
        m.translation = t
        return m
    }

    @Test func followsTheGrabberInParentSpace() throws
    {
        // Grabber at world (11,0,0), parent at (10,0,0): the entity lands at local (1,0,0).
        let moved = try #require(GrabSimulation.step(
            grab: grab(), grabbable: Grabbable(), base: Transform(),
            grabberToWorld: translation([11, 0, 0]), parentToWorld: translation([10, 0, 0])))
        #expect(simd_distance(moved.matrix.translation, [1, 0, 0]) < 1e-5)
    }

    @Test func constraintPinsAnAxisToTheGrabStart() throws
    {
        // A wall sign: [1,1,0] keeps the base z no matter where the grabber goes.
        let base = Transform(translation: [0, 1, 5])
        let moved = try #require(GrabSimulation.step(
            grab: grab(), grabbable: Grabbable(translationConstraint: [1, 1, 0], rotationConstraint: [0, 0, 0]),
            base: base, grabberToWorld: translation([2, 3, -4]), parentToWorld: .identity))
        #expect(simd_distance(moved.matrix.translation, [2, 3, 5]) < 1e-5)
    }

    @Test func fractionMeasuresFromTheBaseNotTheLastTick() throws
    {
        // 0.5 of a 2m move is 1m - and stays 1m on repeated identical steps.
        let grabbable = Grabbable(translationConstraint: [0.5, 0.5, 0.5])
        let base = Transform()
        for _ in 0..<3
        {
            let moved = try #require(GrabSimulation.step(
                grab: grab(), grabbable: grabbable, base: base,
                grabberToWorld: translation([2, 0, 0]), parentToWorld: .identity))
            #expect(simd_distance(moved.matrix.translation, [1, 0, 0]) < 1e-5)
        }
    }

    @Test func rotationConstraintZeroKeepsTheBaseRotation() throws
    {
        let base = Transform(rotation: simd_quatf(angle: .pi / 4, axis: [0, 1, 0]))
        var grabberToWorld = simd_float4x4.identity
        grabberToWorld.rotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let moved = try #require(GrabSimulation.step(
            grab: grab(), grabbable: Grabbable(rotationConstraint: [0, 0, 0]), base: base,
            grabberToWorld: grabberToWorld, parentToWorld: .identity))
        let dot = abs(simd_dot(moved.matrix.rotation, base.matrix.rotation))
        #expect(dot > 0.9999, "rotation must stay at the grab-start value")
    }

    @Test func nonFiniteClientInputMovesNothing()
    {
        // Intent matrices are untrusted; NaN must not reach the world state.
        var poisoned = simd_float4x4.identity
        poisoned.columns.3.x = .nan
        let moved = GrabSimulation.step(
            grab: grab(offset: poisoned), grabbable: Grabbable(), base: Transform(),
            grabberToWorld: .identity, parentToWorld: .identity)
        #expect(moved == nil)
    }

    @Test func eulerRoundTripsThroughQuaternion()
    {
        let q = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>([0.2, 1, 0.4])))
        let back = simd_quatf(eulerAngles: q.eulerAngles)
        #expect(abs(simd_dot(q, back)) > 0.9999)
    }
}
