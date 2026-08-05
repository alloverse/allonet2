import XCTest
@testable import allonet2

@MainActor
final class AuthenticationProviderTests: XCTestCase
{
    private var registration: Interaction {
        Interaction(type: .request, senderEntityId: "", receiverEntityId: Interaction.PlaceEntity,
                    body: .registerAsAuthenticationProvider)
    }

    private func makeServer() -> PlaceServer
    {
        PlaceServer(
            name: "Test Place",
            transportClass: MockTransport.self,
            options: TransportConnectionOptions(routing: .direct),
            alloAppAuthToken: "apptoken",
            requiresAuthentication: true
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
}
