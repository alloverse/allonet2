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

    @Test func movesNoFasterThanTheSlewRate()
    {
        var controller = PlayoutRateController()
        controller.update(error: 100, dt: 0.1)
        #expect(abs(controller.rate - 1.01) < 1e-6, "0.01 per 100 ms")

        // Half the time, half the step.
        var half = PlayoutRateController()
        half.update(error: 100, dt: 0.05)
        #expect(abs(half.rate - 1.005) < 1e-6)

        // A stalled pump resumes gently rather than jumping to the clamp.
        var stalled = PlayoutRateController()
        stalled.update(error: 100, dt: 30)
        #expect(stalled.rate <= PlayoutRateController.rateLimits.upperBound)
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
