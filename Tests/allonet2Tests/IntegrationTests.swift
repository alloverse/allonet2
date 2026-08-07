import XCTest
import PotentCBOR
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

    // 4. A place that's restarting refuses signalling for a few seconds. Keep the backoff
    //    running across it, and pick up by ourselves once the place answers again.
    func testSignallingFailureRetries() async {
        let client = makeTestClient()
        client.signallingError = AlloverseError(
            code: AlloverseErrorCode.failedSignalling,
            description: "Test signalling failure"
        )

        client.stayConnected()

        await awaitClientState(client, { $0.attempt > 0 })
        XCTAssertTrue(client.state.current.isStayingConnected)

        client.signallingError = nil
        await awaitClientState(client, { $0.avatarId != nil }, timeout: 10)
        XCTAssertTrue(client.isAnnounced)

        client.disconnect()
    }

    // 5. An announce the place calls fatal — wrong protocol version, rejected credentials —
    //    won't go better on a retry, so give up and surface it.
    func testFatalAnnounceFailureDisconnects() async {
        let client = makeTestClient()
        // Set the announce response to error on the initial mock transport
        // (created by init → reset())
        client.mockTransport.announceResponse = .error(AlloverseError(
            code: AlloverseErrorCode.incompatibleProtocolVersion,
            description: "Test announce failure"
        ))

        client.stayConnected()

        await awaitClientState(client, {
            if case .disconnected = $0 { return true }; return false
        })

        XCTAssertFalse(client.isAnnounced)
        XCTAssertNil(client.avatarId)
    }

    // 5b. ...including when the code belongs to the place's own authentication app rather than to
    //     allonet, which is every real rejected login: only the raiser can tell us it's permanent.
    func testFatalAnnounceFailureFromForeignDomainDisconnects() async {
        let client = makeTestClient()
        client.mockTransport.announceResponse = .error(AlloverseError(
            domain: "works.koja.error",
            code: 2,
            description: "Incorrect credentials. Check your email and password and try again.",
            overrideIsFatal: true
        ))

        client.stayConnected()

        await awaitClientState(client, {
            if case .disconnected = $0 { return true }; return false
        })

        XCTAssertFalse(client.isAnnounced)
        XCTAssertEqual(client.connectionStatus.reconnection, .idle)
        XCTAssertEqual((client.connectionStatus.lastError as? AlloverseError)?.code, 2)
    }

    // 5c. The place answers a fatal error and then drops the client that doesn't act on it.
    //     The full exchange: the rejection has to win over the hangup that follows it, or the
    //     client mistakes being refused for a network blip and reconnects into the same refusal.
    func testFatalRejectionFollowedByHangupStaysRejected() async throws {
        let client = makeTestClient()
        client.mockTransport.announceResponse = .noResponse
        client.stayConnected()

        // Wait for the announce to go out, as the place would. Decoding failures throw: an
        // unparseable interaction is a protocol regression, not a message to poll past.
        var announce: Interaction?
        let deadline = Date().addingTimeInterval(5)
        while announce == nil, Date() < deadline {
            announce = try client.mockTransport.sentMessages
                .filter { $0.channel == .interactions }
                .map { try CBORDecoder().decode(Interaction.self, from: $0.data) }
                .first { if case .announce = $0.body { return true }; return false }
            await Task.yield()
        }
        guard let announce else { return XCTFail("Client never announced") }

        let transportAtRejection = client.mockTransport!
        transportAtRejection.deliver(announce.makeResponse(with: AlloverseError(
            domain: "works.koja.error", code: 2, description: "Incorrect credentials.",
            overrideIsFatal: true).asBody))

        await awaitClientState(client, {
            if case .disconnected = $0 { return true }; return false
        })
        XCTAssertEqual((client.connectionStatus.lastError as? AlloverseError)?.code, 2)

        // The place's backstop hangup lands on the connection the client already left; it must
        // not shake the client out of its settled verdict.
        transportAtRejection.simulateDisconnect()
        try await Task.sleep(for: .seconds(0.2))
        XCTAssertFalse(client.state.current.isStayingConnected)
        XCTAssertEqual(client.connectionStatus.reconnection, .idle)
        XCTAssertEqual((client.connectionStatus.lastError as? AlloverseError)?.code, 2)
    }

    // 6. ...but a place whose authentication provider is still restarting rejects the announce
    //    for a few seconds only, and stranding the user there needs a human to undo.
    func testTransientAnnounceFailureRetries() async {
        let client = makeTestClient()
        client.mockTransport.announceResponse = .error(AlloverseError(
            code: AlloverseErrorCode.internalServerError,
            description: "Couldn't reach authentication server"
        ))

        client.stayConnected()

        await awaitClientState(client, { $0.attempt > 0 })
        XCTAssertTrue(client.state.current.isStayingConnected)
        XCTAssertEqual(client.connectionStatus.reconnection, .waitingForReconnect)

        client.disconnect()
    }

    // 7. Disconnect cancels a pending retry
    func testDisconnectCancelsBackoff() async {
        let client = makeTestClient()
        client.signallingError = URLError(.timedOut)

        client.stayConnected()

        await awaitClientState(client, { $0.attempt > 0 })

        client.disconnect()

        XCTAssertFalse(client.state.current.isStayingConnected)
        XCTAssertEqual(client.connectionStatus.reconnection, .idle)

        // Backoff for attempt 1 is 2s; the cancelled retry must not fire after it elapses.
        try? await Task.sleep(for: .seconds(3))
        XCTAssertEqual(client.mockTransport.generateOfferCallCount, 0)
        XCTAssertFalse(client.state.current.isStayingConnected)
    }

    // 7b. An app whose own setup failed drops the connection and comes straight back.
    func testReconnectReannounces() async {
        let client = makeTestClient()
        client.stayConnected()
        await awaitClientState(client, { $0.avatarId != nil })
        let first = client.avatarId

        client.reconnect()
        await awaitClientState(client, { $0.avatarId != nil }, timeout: 10)

        XCTAssertTrue(client.isAnnounced)
        XCTAssertEqual(client.mockTransport.generateOfferCallCount, 1, "Should have built a fresh transport")
        XCTAssertNotNil(first)

        client.disconnect()
    }

    // 7c. reconnect() before we're announced belongs to the reconnection machinery, not the app;
    //     acting on it would be an invalid state transition, i.e. a crash.
    func testReconnectIsANoOpWhenNotAnnounced() async {
        let client = makeTestClient()
        client.reconnect() // disconnected
        XCTAssertFalse(client.state.current.isStayingConnected)

        client.signallingError = URLError(.timedOut)
        client.stayConnected()
        await awaitClientState(client, { $0.attempt > 0 })
        client.reconnect() // waitingToRetry
        if case .waitingToRetry = client.state.current {} else {
            XCTFail("reconnect() should have left the pending retry alone, got \(client.state.current)")
        }

        client.disconnect()
    }

    // 7d. An error code we don't know is a peer we don't fully understand, not a reason to trap
    //     on an enum unwrap — and not a reason to give up connecting either.
    func testUnknownErrorCodeFromPlaceIsNotFatal() async {
        let client = makeTestClient()
        client.mockTransport.announceResponse = .error(AlloverseError(
            domain: AlloverseErrorCode.domain,
            code: 4242,
            description: "A code from a newer place"
        ))

        client.stayConnected()

        await awaitClientState(client, { $0.attempt > 0 })
        XCTAssertTrue(client.state.current.isStayingConnected)

        client.disconnect()
    }

    // 7e. A connection that dies moments after announcing is a flap, not a blip: coming straight
    //     back to it forever is how two backends sharing a token evict each other in a tight loop.
    func testRepeatedShortLivedConnectionsBackOff() async {
        let client = makeTestClient()
        client.stayConnected()
        await awaitClientState(client, { $0.avatarId != nil })

        // First drop of an established connection still retries at once.
        client.mockTransport.simulateDisconnect()
        await awaitClientState(client, { $0.avatarId != nil }, timeout: 10)

        // The second one has now seen two short-lived connections in a row, so it waits.
        client.mockTransport.simulateDisconnect()
        await awaitClientState(client, { $0.attempt > 0 })
        XCTAssertTrue(client.state.current.isStayingConnected)

        client.disconnect()
    }

    // 7f. ...but a drop the app asked for is the app's to pace, so it stays immediate.
    func testRequestedReconnectsDoNotBackOff() async {
        let client = makeTestClient()
        client.stayConnected()
        await awaitClientState(client, { $0.avatarId != nil })

        for _ in 0..<3 {
            client.reconnect()
            await awaitClientState(client, { $0.avatarId != nil }, timeout: 10)
        }
        XCTAssertEqual(client.state.current.attempt, 0, "A requested reconnect must not accrue backoff")

        client.disconnect()
    }

    // 7g. A place that accepts the connection and then never answers the announce leaves us
    //     connected, unannounced and with nothing pending — the same dead end as giving up.
    func testUnansweredAnnounceRetries() async {
        let client = makeTestClient()
        client.announceTimeout = 1
        client.mockTransport.announceResponse = .noResponse

        client.stayConnected()

        await awaitClientState(client, { $0.attempt > 0 }, timeout: 10)
        XCTAssertTrue(client.state.current.isStayingConnected)
        XCTAssertFalse(client.isAnnounced)

        client.disconnect()
    }

    // 8. Multiple stayConnected calls are idempotent
    func testStayConnectedIdempotent() async {
        let client = makeTestClient()
        client.stayConnected()
        client.stayConnected() // should not crash or create second connection
        client.stayConnected()

        await awaitClientState(client, { $0.avatarId != nil })
        XCTAssertEqual(client.mockTransport.generateOfferCallCount, 1)

        client.disconnect()
    }

    // 9. Verify that announce interaction was sent
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
