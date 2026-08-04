import Testing
import simd
@testable import allonet2

@MainActor
struct MovementSimulationTests
{
    /// Run `seconds` worth of simulation at `hz`, returning the final transform and velocity.
    private func simulate(direction: SIMD2<Float>, seconds: Float, hz: Int, from: Transform? = nil, velocity: SIMD2<Float> = .zero)
        -> (transform: Transform, velocity: SIMD2<Float>, restedAfter: Int?)
    {
        var transform = from ?? Transform()
        var velocity = velocity
        var restedAfter: Int? = nil
        let dt = 1.0 / Float(hz)
        for tick in 0..<Int(seconds * Float(hz))
        {
            guard let moved = MovementSimulation.step(transform: transform, velocity: &velocity, direction: direction, dt: dt)
            else { restedAfter = tick; break }
            transform = moved
        }
        return (transform, velocity, restedAfter)
    }

    @Test func acceleratesToMaxSpeed() throws
    {
        let held = simulate(direction: [0, 1], seconds: 1, hz: 50)
        #expect(abs(simd_length(held.velocity) - MovementSimulation.maxSpeed) < 0.05)
        #expect(held.transform.matrix.translation.z < 0, "y is forward, which is -Z")
        #expect(held.restedAfter == nil)
    }

    @Test func deceleratesToRestWhenInputStops() throws
    {
        let moving = simulate(direction: [0, 1], seconds: 1, hz: 50)
        let released = simulate(direction: .zero, seconds: 5, hz: 50, from: moving.transform, velocity: moving.velocity)
        #expect(released.restedAfter != nil, "step must report rest so the server can end its loop")
        #expect(released.velocity == .zero)
    }

    @Test func capsOversizedDirection() throws
    {
        let cheating = simulate(direction: [50, 0], seconds: 2, hz: 50)
        #expect(simd_length(cheating.velocity) <= MovementSimulation.maxSpeed + 0.01)
    }

    @Test func displacementIsTickRateIndependent() throws
    {
        // Euler discretization differs slightly per rate; this guards gross dt-dependence, not that.
        let slow = simulate(direction: [1, 0], seconds: 1, hz: 20).transform.matrix.translation.x
        let fast = simulate(direction: [1, 0], seconds: 1, hz: 100).transform.matrix.translation.x
        #expect(abs(slow - fast) < fast * 0.03)
    }

    /// A non-finite direction would poison velocity forever: every comparison against NaN is false,
    /// so the avatar could never reach rest and the server would broadcast garbage transforms.
    @Test(arguments: [SIMD2<Float>(.nan, 0), SIMD2<Float>(0, .infinity), SIMD2<Float>(.nan, .nan)])
    func rejectsNonFiniteDirection(_ direction: SIMD2<Float>) throws
    {
        let hostile = simulate(direction: direction, seconds: 1, hz: 50)
        #expect(hostile.restedAfter != nil, "must come to rest instead of looping forever")
        #expect(hostile.transform.matrix.translation.x.isFinite)
        #expect(hostile.transform.matrix.translation.z.isFinite)
    }

    /// Sub-dead-zone input (stick drift) must not keep the simulation - and its 50Hz broadcast - awake.
    @Test func treatsDriftAsNoInput() throws
    {
        let drifting = simulate(direction: [0.001, 0.001], seconds: 2, hz: 50)
        #expect(drifting.restedAfter != nil)
    }
}
