import XCTest
@testable import allonet2

// MARK: - Async test helpers

/// Wait for a state machine to reach a state matching the predicate.
/// Times out after `timeout` seconds (default 5).
@MainActor
func awaitState<S: StateMachineState>(
    _ sm: StateMachine<S>,
    timeout: TimeInterval = 5.0,
    where predicate: @escaping (S) -> Bool,
    file: StaticString = #file,
    line: UInt = #line
) async {
    if predicate(sm.current) { return }

    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(sm.current) {
        guard Date() < deadline else {
            XCTFail("Timed out waiting for state predicate. Current: \(sm.current)",
                    file: file, line: line)
            return
        }
        await Task.yield()
    }
}

/// Convenience: wait for ClientConnectionState to match a predicate.
@MainActor
func awaitClientState(
    _ client: AlloClient,
    _ check: @escaping (ClientConnectionState) -> Bool,
    timeout: TimeInterval = 5.0,
    file: StaticString = #file,
    line: UInt = #line
) async {
    await awaitState(client.state, timeout: timeout, where: check,
                     file: file, line: line)
}

// MARK: - Factory

@MainActor
func makeTestClient() -> TestAlloClient {
    Allonet.Initialize()
    return TestAlloClient(
        url: URL(string: "alloplace2://localhost:21337")!,
        identity: Identity.none,
        avatarDescription: EntityDescription()
    )
}

// MARK: - Integration Tests

@MainActor
final class AlloClientIntegrationTests: XCTestCase {

    // 1. Happy path: stayConnected -> transport connects -> announce -> .announced
    func testHappyPathConnection() async {
        let client = makeTestClient()
        client.stayConnected()
        await awaitClientState(client, { $0.avatarId != nil })

        XCTAssertEqual(client.state.current.avatarId, "test-avatar-1")
        XCTAssertEqual(client.state.current.placeName, "Test Place")
        XCTAssertTrue(client.isAnnounced)
        XCTAssertNotNil(client.avatarId)
        XCTAssertEqual(client.placeName, "Test Place")
        XCTAssertEqual(client.connectionStatus.reconnection, .connected)
        XCTAssertTrue(client.connectionStatus.hasReceivedAnnounceResponse)

        XCTAssertEqual(client.mockTransport.generateOfferCallCount, 1)
        XCTAssertEqual(client.mockTransport.acceptAnswerCallCount, 1)

        client.disconnect()
    }

    // 2. Reconnection on transport drop
    func testReconnectionOnTransportDrop() async {
        let client = makeTestClient()
        client.stayConnected()
        await awaitClientState(client, { $0.avatarId != nil })

        XCTAssertNotNil(client.avatarId)

        // Simulate transport drop
        client.mockTransport.simulateDisconnect()

        // Should transition to waitingToRetry
        await awaitClientState(client, {
            if case .waitingToRetry = $0 { return true }; return false
        })

        // Should auto-reconnect and get announced again
        // (reset() creates a new MockTransport with default autoConnect + announceResponse)
        await awaitClientState(client, { $0.avatarId != nil }, timeout: 10)

        XCTAssertTrue(client.isAnnounced)
        XCTAssertNotNil(client.avatarId)
        // New MockTransport was created by reset(), verify it was exercised
        XCTAssertEqual(client.mockTransport.generateOfferCallCount, 1)

        client.disconnect()
    }

    // 3. User disconnect during connection attempt
    func testUserDisconnectDuringConnect() async {
        let client = makeTestClient()
        client.stayConnected()

        // Wait until we're at least connecting
        await awaitClientState(client, {
            if case .connecting = $0 { return true }; return false
        })

        client.disconnect()

        XCTAssertFalse(client.state.current.isStayingConnected)
        XCTAssertFalse(client.isAnnounced)
        XCTAssertNil(client.avatarId)
        XCTAssertEqual(client.connectionStatus.reconnection, .idle)
    }

    // 4. Signalling failure
    func testSignallingFailure() async {
        let client = makeTestClient()
        client.signallingError = AlloverseError(
            code: AlloverseErrorCode.failedSignalling,
            description: "Test signalling failure"
        )

        client.stayConnected()

        // connect() catches error, calls disconnect() → .disconnected
        await awaitClientState(client, {
            if case .disconnected = $0 { return true }; return false
        })

        XCTAssertFalse(client.isAnnounced)
        XCTAssertNil(client.avatarId)
    }

    // 5. Announce failure (place returns error)
    func testAnnounceFailure() async {
        let client = makeTestClient()
        // Set the announce response to error on the initial mock transport
        // (created by init → reset())
        client.mockTransport.announceResponse = .error(AlloverseError(
            code: AlloverseErrorCode.unexpectedResponse,
            description: "Test announce failure"
        ))

        client.stayConnected()

        // Announce error path: state → .failed(...), then disconnect() → .disconnected
        await awaitClientState(client, {
            if case .disconnected = $0 { return true }; return false
        })

        XCTAssertFalse(client.isAnnounced)
        XCTAssertNil(client.avatarId)
    }

    // 6. Disconnect cancels backoff
    func testDisconnectCancelsBackoff() async {
        let client = makeTestClient()
        client.signallingError = URLError(.timedOut)

        client.stayConnected()

        // connect() catches error, calls disconnect() → .disconnected
        await awaitClientState(client, {
            if case .disconnected = $0 { return true }; return false
        })

        XCTAssertFalse(client.state.current.isStayingConnected)
        XCTAssertEqual(client.connectionStatus.reconnection, .idle)
    }

    // 7. Multiple stayConnected calls are idempotent
    func testStayConnectedIdempotent() async {
        let client = makeTestClient()
        client.stayConnected()
        client.stayConnected() // should not crash or create second connection
        client.stayConnected()

        await awaitClientState(client, { $0.avatarId != nil })
        XCTAssertEqual(client.mockTransport.generateOfferCallCount, 1)

        client.disconnect()
    }

    // 8. Verify that announce interaction was sent
    func testAnnounceInteractionSent() async {
        let client = makeTestClient()
        client.stayConnected()

        await awaitClientState(client, { $0.avatarId != nil })

        let interactionMessages = client.mockTransport.sentMessages.filter {
            $0.channel == .interactions
        }
        XCTAssertFalse(interactionMessages.isEmpty,
                       "Should have sent at least one interaction (announce)")

        client.disconnect()
    }
}
