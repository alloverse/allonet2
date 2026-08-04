import XCTest
import simd
@testable import allonet2

@MainActor
final class MovementSimulationTests: XCTestCase
{
    func testAcceleratesToMaxSpeedAndStops() throws
    {
        var transform = Transform()
        var velocity = SIMD2<Float>.zero
        let forward = SIMD2<Float>(0, 1)

        // Hold forward for 1s at 50Hz: should reach ~maxSpeed and move roughly maxSpeed*(1s - tau).
        for _ in 0..<50 {
            transform = MovementSimulation.step(transform: transform, velocity: &velocity, direction: forward, dt: 0.02) ?? transform
        }
        XCTAssertEqual(simd_length(velocity), MovementSimulation.maxSpeed, accuracy: 0.05)
        XCTAssertLessThan(transform.matrix.translation.z, 0, "forward is -Z")

        // Release: decelerates to rest and reports it by returning nil.
        var atRest = false
        for _ in 0..<50 {
            if MovementSimulation.step(transform: transform, velocity: &velocity, direction: .zero, dt: 0.02) == nil { atRest = true; break }
        }
        XCTAssertTrue(atRest)
        XCTAssertEqual(velocity, .zero)
    }

    func testOversizedDirectionIsCapped() throws
    {
        var velocity = SIMD2<Float>.zero
        for _ in 0..<100 {
            _ = MovementSimulation.step(transform: Transform(), velocity: &velocity, direction: SIMD2<Float>(50, 0), dt: 0.02)
        }
        XCTAssertLessThanOrEqual(simd_length(velocity), MovementSimulation.maxSpeed + 0.01)
    }

    func testDisplacementIsTickRateIndependent() throws
    {
        func distance(hz: Int) -> Float {
            var transform = Transform()
            var velocity = SIMD2<Float>.zero
            let dt = 1.0 / Float(hz)
            for _ in 0..<hz {
                transform = MovementSimulation.step(transform: transform, velocity: &velocity, direction: SIMD2<Float>(1, 0), dt: dt) ?? transform
            }
            return transform.matrix.translation.x
        }
        // Euler discretization of the easing differs slightly per tick rate; guard against gross dt-dependence, not that.
        let reference = distance(hz: 100)
        XCTAssertEqual(distance(hz: 20), reference, accuracy: reference * 0.03)
    }
}
