import XCTest
import PotentCBOR
@testable import allonet2

@MainActor
final class AuthenticationProviderTests: XCTestCase
{
    private var registration: Interaction {
        Interaction(type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity,
                    body: .registerAsAuthenticationProvider)
    }

    private func makeServer(appToken: String = "apptoken") -> PlaceServer
    {
        PlaceServer(
            name: "Test Place",
            transportClass: MockTransport.self,
            options: TransportConnectionOptions(routing: .direct),
            alloAppAuthToken: appToken,
            requiresAuthentication: !appToken.isEmpty
        )
    }

    /// Announces through the place's own authentication, rather than setting `authenticatedAsApp`
    /// by hand: the point of these tests is the trust boundary, and a helper that grants app
    /// standing itself would pass whatever the boundary did. `token` is what the client claims.
    private func makeClient(_ expectation: Identity.Expectation, on server: PlaceServer,
                            token: String = "apptoken") async -> (ConnectedClient, MockTransport)
    {
        let status = ConnectionStatus()
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: status)
        let client = ConnectedClient(session: AlloSession(side: .server, transport: transport), status: status)
        client.identity = Identity(expectation: expectation, displayName: "KojaServ",
                                   emailAddress: "", authenticationToken: token)
        // Mirrors handle(announce:): apps always go through it, users need a provider we don't have.
        if expectation == .app
        {
            try? await server.authenticate(identity: client.identity!, from: client, in: client.logger)
        }
        return (client, transport)
    }

    /// A backend that restarted has to take the role back from its own previous session, which the
    /// place still believes is alive: a killed peer looks connected until ICE gives up on it, and
    /// refusing until then keeps the place shut to everyone for those tens of seconds.
    func testRestartedAppReplacesStaleProvider() async throws
    {
        let server = makeServer()
        let (old, oldTransport) = await makeClient(.app, on: server)
        try await server.handle(placeInteraction: registration, from: old)
        XCTAssertTrue(server.authenticationProvider === old)

        let (new, _) = await makeClient(.app, on: server)
        try await server.handle(placeInteraction: registration, from: new)
        XCTAssertTrue(server.authenticationProvider === new)
        XCTAssertEqual(oldTransport.disconnectCallCount, 1, "Replaced provider should be dropped")
    }

    /// Taking over is app-only, or the takeover above would let any visor that reaches the place
    /// appoint itself and approve its own credentials.
    func testOnlyAppsMayBeAuthenticationProvider() async
    {
        let server = makeServer()
        let (visor, _) = await makeClient(.existingUser, on: server)
        do
        {
            try await server.handle(placeInteraction: registration, from: visor)
            XCTFail("A visor must not be able to become the place's authentication provider")
        }
        catch
        {
            XCTAssertEqual(error.code, PlaceErrorCode.unauthorized.rawValue)
        }
        XCTAssertNil(server.authenticationProvider)
    }

    /// Claiming to be an app is free — `identity` is written from the announce before anything
    /// checks it. Only the place's own verdict on the token may open this door.
    func testClaimingToBeAnAppWithoutTheTokenIsNotEnough() async
    {
        let server = makeServer(appToken: "apptoken")
        let (impostor, _) = await makeClient(.app, on: server, token: "not-the-token")
        XCTAssertEqual(impostor.identity?.expectation, .app, "It claims to be an app...")
        XCTAssertFalse(impostor.authenticatedAsApp, "...but the place didn't accept it as one")
        do
        {
            try await server.handle(placeInteraction: registration, from: impostor)
            XCTFail("A client that failed the token check must not become the provider")
        }
        catch
        {
            XCTAssertEqual(error.code, PlaceErrorCode.unauthorized.rawValue)
        }
        XCTAssertNil(server.authenticationProvider)
    }

    /// Without an app token every client is an app, so a takeover would let anyone lift the gate
    /// off the real backend and be handed every user's credentials to approve. Nothing tells the
    /// two apart there, so nobody gets to replace anybody.
    func testTakeoverNeedsAnAppTokenToTellAppsApart()
    async {
        let server = makeServer(appToken: "")
        let (first, firstTransport) = await makeClient(.app, on: server)
        do { try await server.handle(placeInteraction: registration, from: first) }
        catch { return XCTFail("First app should still become the provider: \(error)") }

        let (impostor, _) = await makeClient(.app, on: server)
        do
        {
            try await server.handle(placeInteraction: registration, from: impostor)
            XCTFail("A token-less place must not hand the provider role to a second app")
        }
        catch
        {
            XCTAssertEqual(error.code, PlaceErrorCode.invalidRequest.rawValue)
        }
        XCTAssertTrue(server.authenticationProvider === first)
        XCTAssertEqual(firstTransport.disconnectCallCount, 0, "The real backend must stay connected")
    }

    /// Announcing twice took the whole place down on a force-unwrap — a crash any client could ask
    /// for. It's a malformed request.
    func testSecondAnnounceIsRejectedRatherThanCrashingThePlace() async
    {
        let server = makeServer()
        let (client, _) = await makeClient(.app, on: server)
        client.announced = true
        let announce = Interaction(type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity,
                                   body: .announce(version: Allonet.version().description,
                                                   identity: client.identity!,
                                                   avatar: EntityDescription()))
        do
        {
            try await server.handle(placeInteraction: announce, from: client)
            XCTFail("A second announce must be refused")
        }
        catch
        {
            XCTAssertEqual(error.code, PlaceErrorCode.invalidRequest.rawValue)
        }
    }

    /// Re-registering from the session that already holds the role is a no-op, not a self-eviction.
    func testReregisteringTheSameClientKeepsItConnected() async throws
    {
        let server = makeServer()
        let (app, transport) = await makeClient(.app, on: server)
        try await server.handle(placeInteraction: registration, from: app)
        try await server.handle(placeInteraction: registration, from: app)
        XCTAssertTrue(server.authenticationProvider === app)
        XCTAssertEqual(transport.disconnectCallCount, 0)
    }

    /// The place hangs up on a fatal error, so the response it sends first is the client's only
    /// chance to learn that coming back won't help. It has to say so in the response itself.
    func testFatalErrorResponseSaysSoBeforeTheDisconnect() async throws
    {
        let server = makeServer()
        let (client, transport) = await makeClient(.existingUser, on: server)

        // Acting through an entity you don't own is unauthorized, which the place calls fatal.
        await server.handle(Interaction(type: .request, senderEntityId: "not-yours",
                                        receiverEntityId: Interaction.PlaceEntity,
                                        body: .createEntity(EntityDescription())),
                            from: client)

        let lastSent = try XCTUnwrap(transport.sentMessages.last { $0.channel == .interactions })
        let response: Interaction = try CBORDecoder().decode(Interaction.self, from: lastSent.data)
        guard case .error(_, let code, _, let isFatal) = response.body else {
            return XCTFail("Expected an error response, got \(response.body)")
        }
        XCTAssertEqual(code, PlaceErrorCode.unauthorized.rawValue)
        XCTAssertEqual(isFatal, true, "A client that isn't told will just reconnect and be refused again")
        XCTAssertEqual(transport.disconnectCallCount, 1)
    }
}
