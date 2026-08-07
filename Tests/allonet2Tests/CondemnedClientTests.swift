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
        #expect(server.waitingToDisconnect[client.cid] == nil,
                "The backstop clears the roster itself; a dead transport delivers no callback to do it")
    }

    /// A fatal verdict can resume after the client already dropped — it hung up while
    /// authenticate() was awaiting the provider, and the disconnect path tore it down. Condemning
    /// it then would park a closed session in the roster with nothing left to ever clear it.
    @Test func condemningAnAlreadyGoneClientDoesNotResurrectIt() async throws
    {
        let server = makeServer()
        let (client, _) = makeClient(on: server, in: \.unannouncedClients)
        // What the disconnect path leaves behind: the client in no roster.
        server.unannouncedClients.removeValue(forKey: client.cid)

        await sendUnauthorizedInteraction(to: server, from: client)

        #expect(server.waitingToDisconnect[client.cid] == nil)
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

    /// An authentication answer only counts from the provider that currently holds the role: a
    /// condemned provider's session lives through the grace, and responses complete their
    /// continuation before any roster check, so its `.success` would otherwise admit a visor on
    /// the word of a peer the place already threw out.
    @Test func condemnedProvidersPendingAuthenticationsDoNotAdmit() async throws
    {
        let server = makeServer()
        server.fatalDisconnectGrace = 10
        let (provider, providerTransport) = makeClient(on: server, in: \.clients)
        provider.identity = Identity(expectation: .app, displayName: "KojaServ",
                                     emailAddress: "", authenticationToken: "apptoken")
        provider.authenticatedAsApp = true
        provider.announced = true
        provider.avatar = "auth-entity"
        server.authenticationProvider = provider

        let (visor, _) = makeClient(on: server, in: \.unannouncedClients)
        let auth = Task { try await server.authenticate(identity: visor.identity!, from: visor, in: visor.logger) }

        // Wait for the place to ask the provider, as the visor's announce would.
        var request: Interaction?
        let deadline = Date().addingTimeInterval(5)
        while request == nil, Date() < deadline {
            request = providerTransport.sentMessages.lazy
                .filter { $0.channel == .interactions }
                .compactMap { try? CBORDecoder().decode(Interaction.self, from: $0.data) }
                .first { if case .authenticationRequest = $0.body { return true }; return false }
            await Task.yield()
        }
        let pending = try #require(request)

        await server.condemn(provider)
        providerTransport.deliver(pending.makeResponse(with: .success))

        guard case .failure(let error) = await auth.result else {
            Issue.record("A condemned provider's answer must not authenticate anyone")
            return
        }
        #expect((error as? AlloverseError)?.isFatal != true,
                "Refusal must stay retryable; the successor may be seconds away")
    }

    /// An announce suspended in authenticate() can outlive its client's welcome: the client
    /// pipelines an unauthorized request behind it and gets condemned, or just hangs up. When the
    /// provider's answer then resumes the announce, admitting the client trapped on the roster
    /// unwrap — a crash any authenticated place's visitor could trigger.
    @Test func condemnedMidAnnounceIsNotAdmitted() async throws
    {
        let server = makeServer()
        server.fatalDisconnectGrace = 10
        let (provider, providerTransport) = makeClient(on: server, in: \.clients)
        provider.authenticatedAsApp = true
        provider.announced = true
        provider.avatar = "auth-entity"
        server.authenticationProvider = provider

        let (visor, _) = makeClient(on: server, in: \.unannouncedClients)
        let announce = Interaction(type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity,
                                   body: .announce(version: Allonet.version().description,
                                                   identity: visor.identity!, avatar: EntityDescription()))
        let announcing = Task { try await server.handle(placeInteraction: announce, from: visor) }

        // Wait until the announce is suspended awaiting the provider...
        var request: Interaction?
        let deadline = Date().addingTimeInterval(5)
        while request == nil, Date() < deadline {
            request = providerTransport.sentMessages.lazy
                .filter { $0.channel == .interactions }
                .compactMap { try? CBORDecoder().decode(Interaction.self, from: $0.data) }
                .first { if case .authenticationRequest = $0.body { return true }; return false }
            await Task.yield()
        }
        let pending = try #require(request)

        // ...condemn the client behind its back, then let the provider approve it.
        await sendUnauthorizedInteraction(to: server, from: visor)
        #expect(server.waitingToDisconnect[visor.cid] != nil)
        providerTransport.deliver(pending.makeResponse(with: .success))

        guard case .failure = await announcing.result else {
            Issue.record("A condemned client must not be admitted")
            return
        }
        #expect(server.clients[visor.cid] == nil)
    }

    /// Forwarders a condemned client *receives* stop at condemn time too: its listener components
    /// only clean up on the next heartbeat, and it shouldn't keep hearing the room for that beat.
    @Test func condemnStopsForwardingToTheClient() async throws
    {
        let server = makeServer()
        server.fatalDisconnectGrace = 10
        let (publisher, publisherTransport) = makeClient(on: server, in: \.clients)
        publisher.announced = true
        publisher.session.delegate = server
        publisher.session.transport(publisherTransport, didReceiveMediaStream: MockMediaStream(mediaId: "mic"))

        let (listener, _) = makeClient(on: server, in: \.clients)
        listener.announced = true
        let psi = PlaceStreamId(shortClientId: publisher.cid.shortClientId, incomingMediaId: "mic")
        server.sfu.desired.insert(ForwardingId(source: psi, target: listener.cid))

        await sendUnauthorizedInteraction(to: server, from: listener)

        #expect(server.sfu.desired.allSatisfy { $0.target != listener.cid },
                "A condemned client's desires leave the SFU with it")
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
