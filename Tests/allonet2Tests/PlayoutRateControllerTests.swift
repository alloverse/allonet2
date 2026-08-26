//
//  PlayoutRateControllerTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@Suite("Playout rate controller")
struct PlayoutRateControllerTests
{
    /// Run the controller at the pump's own tick until it settles, and report where it landed.
    private func settle(error: Float, ticks: Int = 400, dt: TimeInterval = 0.01) -> Float
    {
        var controller = PlayoutRateController()
        for _ in 0..<ticks { controller.update(error: error, dt: dt) }
        return controller.rate
    }

    @Test func clampsAtBothEnds()
    {
        #expect(settle(error: 100) == PlayoutRateController.rateLimits.upperBound)
        #expect(settle(error: -100) == PlayoutRateController.rateLimits.lowerBound)
    }

    /// Fully corrected depth still wobbles by a fraction of a frame as the pump refills; the
    /// controller must not chase that.
    @Test func ignoresErrorInsideTheDeadband()
    {
        #expect(settle(error: 0.4) == 1)
        #expect(settle(error: -0.4) == 1)
        #expect(settle(error: 0) == 1)
    }

    @Test func proportionalGainSetsTheRateItSettlesAt()
    {
        let rate = settle(error: 1)
        #expect(abs(rate - (1 + PlayoutRateController.proportionalGain)) < 1e-5, "one frame ahead plays 2 % fast")
    }

    /// Counted in pump ticks, because that is the only cadence the rate may accrue at: `dt` buys
    /// no more than one tick's step however long the gap was.
    @Test func movesNoFasterThanTheSlewRate()
    {
        var controller = PlayoutRateController()
        for _ in 0..<10 { controller.update(error: 100, dt: 0.01) }
        #expect(abs(controller.rate - 1.01) < 1e-6, "0.01 per 100 ms")

        // Half the time, half the step.
        var half = PlayoutRateController()
        for _ in 0..<5 { half.update(error: 100, dt: 0.01) }
        #expect(abs(half.rate - 1.005) < 1e-6)
    }

    /// A pump that stalled - the app suspended, the device asleep - must not cash the whole gap
    /// in as one step. `rateLimits` is 4 % wide, so any cap above 0.4 s lets one update cross the
    /// entire range: a pitch step, which is what the slew exists to avoid.
    @Test func aStalledPumpResumesOneTickAtATime()
    {
        var stalled = PlayoutRateController()
        stalled.update(error: 100, dt: 30)

        let oneTick = PlayoutRateController.slewPerSecond * Float(PlayoutRateController.maximumUpdateInterval)
        #expect(abs(stalled.rate - (1 + oneTick)) < 1e-6,
                "a 30 s stall moved the rate by \(stalled.rate - 1), not one tick's \(oneTick)")
    }

    @Test func returnsToOneWhenTheDepthIsBackOnTarget()
    {
        var controller = PlayoutRateController()
        for _ in 0..<400 { controller.update(error: 3, dt: 0.01) }
        #expect(controller.rate > 1)

        for _ in 0..<400 { controller.update(error: 0, dt: 0.01) }
        #expect(controller.rate == 1)
    }
}
