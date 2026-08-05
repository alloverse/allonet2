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
}
