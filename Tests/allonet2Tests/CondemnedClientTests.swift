import Testing
import Foundation
import PotentCBOR
@testable import allonet2

/// A client told a fatal error is condemned: quarantined in `waitingToDisconnect`, torn out of
/// the place, and given `fatalDisconnectGrace` to act on the answer and hang up itself before
/// the place drops it. These cover that window — the response has to win the race with the
/// hangup, and a condemned client must get nothing further out of the place.
@MainActor
@Suite struct CondemnedClientTests
{
    private func makeServer() -> PlaceServer
    {
        let server = PlaceServer(
            name: "Test Place",
            transportClass: MockTransport.self,
            options: TransportConnectionOptions(routing: .direct),
            alloAppAuthToken: "apptoken",
            requiresAuthentication: true
        )
        server.fatalDisconnectGrace = 0.2
        return server
    }

    /// A client as the signalling handshake leaves it: unannounced, session up. `roster` places it
    /// the way the scenario under test needs (fresh clients belong in `unannouncedClients`).
    private func makeClient(on server: PlaceServer,
                            in roster: ReferenceWritableKeyPath<PlaceServer, [ClientId: ConnectedClient]>) -> (ConnectedClient, MockTransport)
    {
        let status = ConnectionStatus()
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: status)
        let client = ConnectedClient(session: AlloSession(side: .server, transport: transport), status: status)
        client.identity = Identity(expectation: .existingUser, displayName: "Visor",
                                   emailAddress: "visor@example.com", authenticationToken: "hunter2")
        transport.clientId = client.cid
        server[keyPath: roster][client.cid] = client
        return (client, transport)
    }

    /// Anything unauthorized coming through the generic interaction handler; fatal per PlaceErrorCode.
    private func sendUnauthorizedInteraction(to server: PlaceServer, from client: ConnectedClient) async
    {
        await server.handle(Interaction(type: .request, senderEntityId: "not-yours",
                                        receiverEntityId: Interaction.PlaceEntity,
                                        body: .createEntity(EntityDescription())),
                            from: client)
    }

    /// The response to a fatal error is the client's only chance to learn that coming back won't
    /// help. It has to say so in the response itself, and the place must not hang up in the same
    /// turn — the client acts on the answer and hangs up itself; dropping it is only a backstop.
    @Test func fatalErrorResponseSaysSoAndTheHangupWaitsForIt() async throws
    {
        let server = makeServer()
        let (client, transport) = makeClient(on: server, in: \.unannouncedClients)

        await sendUnauthorizedInteraction(to: server, from: client)

        let lastSent = try #require(transport.sentMessages.last { $0.channel == .interactions })
        let response: Interaction = try CBORDecoder().decode(Interaction.self, from: lastSent.data)
        guard case .error(_, let code, _, let isFatal) = response.body else {
            Issue.record("Expected an error response, got \(response.body)")
            return
        }
        #expect(code == PlaceErrorCode.unauthorized.rawValue)
        #expect(isFatal == true, "A client that isn't told will just reconnect and be refused again")
        #expect(transport.disconnectCallCount == 0, "Hanging up in the same turn races the response")
        #expect(server.unannouncedClients[client.cid] == nil)
        #expect(server.waitingToDisconnect[client.cid] != nil)

        try await Task.sleep(for: .seconds(0.5))
        #expect(transport.disconnectCallCount == 1, "A client that ignores the answer still gets dropped")
    }

    /// A client that did act on the answer is gone from the roster by the time the backstop fires,
    /// and there is nothing left for it to drop.
    @Test func backstopStandsDownWhenClientHungUpItself() async throws
    {
        let server = makeServer()
        let (client, transport) = makeClient(on: server, in: \.unannouncedClients)

        await sendUnauthorizedInteraction(to: server, from: client)

        // The client acts on the answer: its hangup arrives as a session disconnect.
        server.session(didDisconnect: client.session)

        try await Task.sleep(for: .seconds(0.5))
        #expect(transport.disconnectCallCount == 0)
        #expect(server.waitingToDisconnect[client.cid] == nil)
    }

    /// Condemned means gone from the place, not lingering with reduced standing: entities leave,
    /// and interactions still in flight are dropped rather than served — or worse, trapping the
    /// place, as the roster lookup used to when it assumed every sender was in one.
    @Test func condemnedClientIsTornDownAndUnserved() async throws
    {
        let server = makeServer()
        server.fatalDisconnectGrace = 10 // Out of the picture; this tests the quarantine itself.
        let (client, transport) = makeClient(on: server, in: \.clients)
        client.announced = true
        let avatar = await server.createEntity(from: EntityDescription(), for: client)
        client.avatar = avatar.id
        await server.heartbeat.awaitNextSync()
        #expect(server.place.current.entities[avatar.id] != nil)

        await sendUnauthorizedInteraction(to: server, from: client)

        #expect(server.clients[client.cid] == nil)
        #expect(server.waitingToDisconnect[client.cid] != nil)
        await server.heartbeat.awaitNextSync()
        #expect(server.place.current.entities[avatar.id] == nil, "A condemned client's entities leave the place")

        let sentBefore = transport.sentMessages.count
        server.session(client.session, didReceiveInteraction:
            Interaction(type: .request, senderEntityId: avatar.id, receiverEntityId: Interaction.PlaceEntity,
                        body: .createEntity(EntityDescription())))
        try await Task.sleep(for: .seconds(0.2))
        #expect(transport.sentMessages.count == sentBefore, "No response owed to a condemned client")
        #expect(transport.disconnectCallCount == 0)
    }

    /// Streams a condemned client publishes stop forwarding at condemn time, not when the session
    /// finally closes — being refused mustn't come with a grace period of airtime to the room.
    @Test func condemnSilencesPublishedStreams() async throws
    {
        let server = makeServer()
        server.fatalDisconnectGrace = 10
        let (client, transport) = makeClient(on: server, in: \.clients)
        client.announced = true
        client.session.delegate = server

        client.session.transport(transport, didReceiveMediaStream: MockMediaStream(mediaId: "mic"))
        #expect(server.sfu.available.count == 1)

        await sendUnauthorizedInteraction(to: server, from: client)

        #expect(server.sfu.available.isEmpty, "A condemned client's streams leave the SFU immediately")
    }
}
