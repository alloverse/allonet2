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

@MainActor
final class TransportConnectionStateTests: XCTestCase
{
    func testHappyPath()
    {
        let sm = StateMachine<TransportConnectionState>(.idle, label: "test")
        sm.transition(to: .connecting)
        sm.transition(to: .connected)
        XCTAssertEqual(sm.current.description, "connected")
    }

    func testDisconnectFromConnecting()
    {
        let sm = StateMachine<TransportConnectionState>(.idle, label: "test")
        sm.transition(to: .connecting)
        sm.transition(to: .disconnected)
        XCTAssertEqual(sm.current.description, "disconnected")
    }

    func testDisconnectFromConnected()
    {
        let sm = StateMachine<TransportConnectionState>(.idle, label: "test")
        sm.transition(to: .connecting)
        sm.transition(to: .connected)
        sm.transition(to: .disconnected)
        XCTAssertEqual(sm.current.description, "disconnected")
    }

    func testRenegotiation()
    {
        let sm = StateMachine<TransportConnectionState>(.idle, label: "test")
        sm.transition(to: .connecting)
        sm.transition(to: .connected)
        // Renegotiation: connected → connecting → connected
        sm.transition(to: .connecting)
        sm.transition(to: .connected)
        XCTAssertEqual(sm.current.description, "connected")
    }

    func testTransitionIfGuard()
    {
        let sm = StateMachine<TransportConnectionState>(.connected, label: "test")
        // Should not transition to connected if already connected
        let did = sm.transitionIf(to: .connected) { state in
            if case .connecting = state { return true }
            return false
        }
        XCTAssertFalse(did)
        XCTAssertEqual(sm.current.description, "connected")
    }
}

@MainActor
final class ClientConnectionStateTests: XCTestCase
{
    func testHappyPath()
    {
        let sm = StateMachine<ClientConnectionState>(.disconnected, label: "test")
        sm.transition(to: .waitingToRetry(attempt: 0))
        sm.transition(to: .connecting(attempt: 0))
        sm.transition(to: .announced(avatarId: "avatar-1", placeName: "Test Place"))
        XCTAssertEqual(sm.current.avatarId, "avatar-1")
        XCTAssertEqual(sm.current.placeName, "Test Place")
        XCTAssertTrue(sm.current.isStayingConnected)
    }

    func testReconnectionAfterDisconnect()
    {
        let sm = StateMachine<ClientConnectionState>(.disconnected, label: "test")
        sm.transition(to: .waitingToRetry(attempt: 0))
        sm.transition(to: .connecting(attempt: 0))
        sm.transition(to: .announced(avatarId: "avatar-1", placeName: "Test Place"))
        // Transport drops
        sm.transition(to: .waitingToRetry(attempt: 0))
        XCTAssertNil(sm.current.avatarId)
        XCTAssertTrue(sm.current.isStayingConnected)
        // Reconnect
        sm.transition(to: .connecting(attempt: 0))
        sm.transition(to: .announced(avatarId: "avatar-2", placeName: "Test Place"))
        XCTAssertEqual(sm.current.avatarId, "avatar-2")
    }

    func testFailureAndRetry()
    {
        let sm = StateMachine<ClientConnectionState>(.disconnected, label: "test")
        sm.transition(to: .waitingToRetry(attempt: 0))
        sm.transition(to: .connecting(attempt: 0))
        sm.transition(to: .failed(error: URLError(.timedOut)))
        // Retry after failure
        sm.transition(to: .waitingToRetry(attempt: 1))
        XCTAssertEqual(sm.current.attempt, 1)
        sm.transition(to: .connecting(attempt: 1))
        XCTAssertEqual(sm.current.attempt, 1)
    }

    func testUserDisconnectFromAnnounced()
    {
        let sm = StateMachine<ClientConnectionState>(.disconnected, label: "test")
        sm.transition(to: .waitingToRetry(attempt: 0))
        sm.transition(to: .connecting(attempt: 0))
        sm.transition(to: .announced(avatarId: "avatar-1", placeName: "Test Place"))
        sm.transition(to: .disconnected)
        XCTAssertFalse(sm.current.isStayingConnected)
        XCTAssertNil(sm.current.avatarId)
    }

    func testUserDisconnectFromConnecting()
    {
        let sm = StateMachine<ClientConnectionState>(.disconnected, label: "test")
        sm.transition(to: .waitingToRetry(attempt: 0))
        sm.transition(to: .connecting(attempt: 0))
        sm.transition(to: .disconnected)
        XCTAssertFalse(sm.current.isStayingConnected)
    }

    func testUserDisconnectFromWaiting()
    {
        let sm = StateMachine<ClientConnectionState>(.disconnected, label: "test")
        sm.transition(to: .waitingToRetry(attempt: 0))
        sm.transition(to: .disconnected)
        XCTAssertFalse(sm.current.isStayingConnected)
    }

    func testTransportDropDuringConnect()
    {
        // ICE failure during connection: connecting → waitingToRetry
        let sm = StateMachine<ClientConnectionState>(.disconnected, label: "test")
        sm.transition(to: .waitingToRetry(attempt: 0))
        sm.transition(to: .connecting(attempt: 0))
        sm.transition(to: .waitingToRetry(attempt: 1))
        XCTAssertEqual(sm.current.attempt, 1)
    }

    func testConvenienceAccessors()
    {
        let disconnected = ClientConnectionState.disconnected
        XCTAssertFalse(disconnected.isStayingConnected)
        XCTAssertNil(disconnected.avatarId)
        XCTAssertNil(disconnected.placeName)
        XCTAssertEqual(disconnected.attempt, 0)

        let waiting = ClientConnectionState.waitingToRetry(attempt: 3)
        XCTAssertTrue(waiting.isStayingConnected)
        XCTAssertEqual(waiting.attempt, 3)

        let connecting = ClientConnectionState.connecting(attempt: 2)
        XCTAssertTrue(connecting.isStayingConnected)
        XCTAssertEqual(connecting.attempt, 2)

        let announced = ClientConnectionState.announced(avatarId: "a", placeName: "p")
        XCTAssertTrue(announced.isStayingConnected)
        XCTAssertEqual(announced.avatarId, "a")
        XCTAssertEqual(announced.placeName, "p")

        let failed = ClientConnectionState.failed(error: URLError(.badURL))
        XCTAssertTrue(failed.isStayingConnected)
    }
}
