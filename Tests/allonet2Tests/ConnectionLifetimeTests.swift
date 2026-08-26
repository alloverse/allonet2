import Testing
@testable import allonet2

/// A client builds a fresh transport and session per connection attempt, so anything that
/// outlives its replacement outlives the process: an owner captured strongly by something it
/// owns is a cycle, and a long-running client accumulated a whole WebRTC stack per attempt.
@MainActor
@Suite struct ConnectionLifetimeTests
{
    @Test func transportDiesWithItsLastReference() async throws
    {
        var transport: DataChannelTransport? = DataChannelTransport(
            with: TransportConnectionOptions(routing: .direct, portRange: 21400..<21500),
            status: ConnectionStatus())
        weak var released = transport
        _ = transport!.createDataChannel(label: .interactions, reliable: true)

        transport = nil

        #expect(released == nil, "The peer connection's publishers still hold the transport")
    }

    @Test func sessionDiesWithItsLastReference() async throws
    {
        var session: AlloSession? = AlloSession(
            side: .client,
            transport: MockTransport(with: TransportConnectionOptions(routing: .direct), status: ConnectionStatus()))
        weak var released = session

        session = nil

        #expect(released == nil, "The logger's metadata provider still holds the session")
    }
}
