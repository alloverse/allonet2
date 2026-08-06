import XCTest
@testable import allonet2

@MainActor
final class SessionRequestTests: XCTestCase
{
    /// A request in flight when the transport dies used to leave its continuation suspended
    /// forever. An app awaiting one during its setup then never returned — so it never noticed
    /// the reconnection it was being told about, and only a process restart brought it back.
    func testInFlightRequestFailsWhenTransportDies() async
    {
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: ConnectionStatus())
        let session = AlloSession(side: .client, transport: transport)

        let response = Task {
            await session.request(interaction: Interaction(
                type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity,
                body: .registerAsAuthenticationProvider))
        }
        // Let the request reach the transport before killing it.
        while transport.sentMessages.isEmpty { await Task.yield() }
        transport.simulateDisconnect()

        guard case .error(_, let code, _) = await response.value.body else {
            return XCTFail("Expected an error body, got \(await response.value.body)")
        }
        XCTAssertEqual(code, AlloverseErrorCode.disconnected.rawValue)
    }

    /// Waiting on an entity that the place was going to send is the other way an app could hang
    /// forever: no request is outstanding, so failing those isn't enough.
    func testFindEntityFailsWhenTheConnectionResets() async
    {
        let client = makeTestClient()
        client.stayConnected()
        await awaitClientState(client, { $0.avatarId != nil })

        let lookup = Task { try await client.place.findEntity(id: "never-arrives") }
        await Task.yield()
        client.mockTransport.simulateDisconnect()

        do
        {
            _ = try await lookup.value
            XCTFail("findEntity should not resolve after the connection went away")
        }
        catch {}

        client.disconnect()
    }

    /// A peer that is connected but not answering releases nobody by itself: no disconnect arrives
    /// to fail the request. The place asks its authentication provider exactly this way, and an
    /// unbounded wait there hangs the announcing visor for as long as its own connection lasts.
    func testRequestTimesOutWhenThePeerNeverAnswers() async
    {
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: ConnectionStatus())
        let session = AlloSession(side: .client, transport: transport)

        let answer = await session.request(interaction: Interaction(
            type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity,
            body: .registerAsAuthenticationProvider), timeout: 1)

        XCTAssertNil(answer, "Expected the request to give up rather than wait forever")
    }

    /// The timeout must not fire for a request that was answered, nor leave the entry behind.
    func testAnsweredRequestBeatsItsTimeout() async
    {
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: ConnectionStatus())
        let session = AlloSession(side: .client, transport: transport)
        let request = Interaction(type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity,
                                  body: .registerAsAuthenticationProvider)

        async let answer = session.request(interaction: request, timeout: 30)
        while transport.sentMessages.isEmpty { await Task.yield() }
        transport.deliver(request.makeResponse(with: .success))

        let body = await answer?.body
        guard case .success = body else { return XCTFail("Expected the real answer, got \(String(describing: body))") }
    }

    /// A caller whose connection died between two of its requests is ordinary, not a programmer
    /// error — this used to abort the process on a precondition.
    func testRequestWhileUnannouncedAnswersInsteadOfTrapping() async
    {
        let client = makeTestClient()
        let response = await client.request(receiverEntityId: Interaction.PlaceEntity,
                                            body: .registerAsAuthenticationProvider)
        guard case .error(_, let code, _) = response.body else {
            return XCTFail("Expected an error body, got \(response.body)")
        }
        XCTAssertEqual(code, AlloverseErrorCode.disconnected.rawValue)
    }
}
