import XCTest
@testable import allonet2

@MainActor
final class StateMachineWrapperTests: XCTestCase
{
    func testBasicTransition()
    {
        let sm = StateMachine<NegotiationState>(.stable, label: "test")
        sm.transition(to: .negotiating(role: .offering, deferredRenegotiation: false))
        XCTAssertTrue(sm.current.isNegotiating)
        XCTAssertEqual(sm.current.role, .offering)
    }

    func testTransitionIfMatching()
    {
        let sm = StateMachine<NegotiationState>(.stable, label: "test")
        let didTransition = sm.transitionIf(to: .negotiating(role: .offering, deferredRenegotiation: false)) { state in
            if case .stable = state { return true }
            return false
        }
        XCTAssertTrue(didTransition)
        XCTAssertTrue(sm.current.isNegotiating)
    }

    func testTransitionIfNotMatching()
    {
        let sm = StateMachine<NegotiationState>(.stable, label: "test")
        let didTransition = sm.transitionIf(to: .negotiating(role: .offering, deferredRenegotiation: false)) { state in
            if case .negotiating = state { return true }
            return false
        }
        XCTAssertFalse(didTransition)
        XCTAssertFalse(sm.current.isNegotiating)
    }
}

@MainActor
final class NegotiationStateTests: XCTestCase
{
    func testStableToOffering()
    {
        let sm = StateMachine<NegotiationState>(.stable, label: "test")
        sm.transition(to: .negotiating(role: .offering, deferredRenegotiation: false))
        XCTAssertEqual(sm.current.role, .offering)
        XCTAssertFalse(sm.current.hasDeferredRenegotiation)
    }

    func testStableToAnswering()
    {
        let sm = StateMachine<NegotiationState>(.stable, label: "test")
        sm.transition(to: .negotiating(role: .answering, deferredRenegotiation: false))
        XCTAssertEqual(sm.current.role, .answering)
    }

    func testOfferingToStable()
    {
        let sm = StateMachine<NegotiationState>(
            .negotiating(role: .offering, deferredRenegotiation: false), label: "test"
        )
        sm.transition(to: .stable)
        XCTAssertFalse(sm.current.isNegotiating)
    }

    func testDeferredRenegotiation()
    {
        let sm = StateMachine<NegotiationState>(
            .negotiating(role: .offering, deferredRenegotiation: false), label: "test"
        )
        sm.transition(to: .negotiating(role: .offering, deferredRenegotiation: true))
        XCTAssertTrue(sm.current.hasDeferredRenegotiation)
    }

    func testPoliteConflictResolution()
    {
        // Offering, receive remote offer as polite -> rollback to stable, then answer
        let sm = StateMachine<NegotiationState>(
            .negotiating(role: .offering, deferredRenegotiation: false), label: "test"
        )
        sm.transition(to: .stable) // rollback
        sm.transition(to: .negotiating(role: .answering, deferredRenegotiation: false))
        XCTAssertEqual(sm.current.role, .answering)
    }

    func testConvenienceAccessors()
    {
        let stable = NegotiationState.stable
        XCTAssertFalse(stable.isNegotiating)
        XCTAssertFalse(stable.hasDeferredRenegotiation)
        XCTAssertNil(stable.role)

        let offering = NegotiationState.negotiating(role: .offering, deferredRenegotiation: false)
        XCTAssertTrue(offering.isNegotiating)
        XCTAssertFalse(offering.hasDeferredRenegotiation)
        XCTAssertEqual(offering.role, .offering)

        let deferred = NegotiationState.negotiating(role: .offering, deferredRenegotiation: true)
        XCTAssertTrue(deferred.hasDeferredRenegotiation)
    }
}
