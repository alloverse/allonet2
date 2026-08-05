import XCTest
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

    private func makeClient(_ expectation: Identity.Expectation) -> (ConnectedClient, MockTransport)
    {
        let status = ConnectionStatus()
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: status)
        let client = ConnectedClient(session: AlloSession(side: .server, transport: transport), status: status)
        client.identity = Identity(expectation: expectation, displayName: "KojaServ",
                                   emailAddress: "", authenticationToken: "apptoken")
        return (client, transport)
    }

    /// A backend that restarted has to take the role back from its own previous session, which the
    /// place still believes is alive: a killed peer looks connected until ICE gives up on it, and
    /// refusing until then keeps the place shut to everyone for those tens of seconds.
    func testRestartedAppReplacesStaleProvider() async throws
    {
        let server = makeServer()
        let (old, oldTransport) = makeClient(.app)
        try await server.handle(placeInteraction: registration, from: old)
        XCTAssertTrue(server.authenticationProvider === old)

        let (new, _) = makeClient(.app)
        try await server.handle(placeInteraction: registration, from: new)
        XCTAssertTrue(server.authenticationProvider === new)
        XCTAssertEqual(oldTransport.disconnectCallCount, 1, "Replaced provider should be dropped")
    }

    /// Taking over is app-only, or the takeover above would let any visor that reaches the place
    /// appoint itself and approve its own credentials.
    func testOnlyAppsMayBeAuthenticationProvider() async
    {
        let server = makeServer()
        let (visor, _) = makeClient(.existingUser)
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

    /// Without an app token every client is an app, so a takeover would let anyone lift the gate
    /// off the real backend and be handed every user's credentials to approve. Nothing tells the
    /// two apart there, so nobody gets to replace anybody.
    func testTakeoverNeedsAnAppTokenToTellAppsApart()
    async {
        let server = makeServer(appToken: "")
        let (first, firstTransport) = makeClient(.app)
        do { try await server.handle(placeInteraction: registration, from: first) }
        catch { return XCTFail("First app should still become the provider: \(error)") }

        let (impostor, _) = makeClient(.app)
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
        let (client, _) = makeClient(.app)
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
        let (app, transport) = makeClient(.app)
        try await server.handle(placeInteraction: registration, from: app)
        try await server.handle(placeInteraction: registration, from: app)
        XCTAssertTrue(server.authenticationProvider === app)
        XCTAssertEqual(transport.disconnectCallCount, 0)
    }
}
