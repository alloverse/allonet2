import XCTest
@testable import allonet2

/// libdatachannel calls back from its own thread pool, so everything the transport hands upwards
/// crosses a thread boundary into main-actor state. These pin the two consequences.
final class TransportIsolationTests: XCTestCase
{
    /// Every delegate call has to arrive on the main actor. Off it, the delegate chain mutates
    /// AlloSession's and AlloClient's state — dictionaries and a state machine — from a
    /// libdatachannel worker thread.
    @MainActor
    func testDelegateCallbacksArriveOnMain() async throws
    {
        let recorder = ThreadRecordingDelegate()
        let transport = DataChannelTransport(
            with: TransportConnectionOptions(routing: .direct, portRange: 21200..<21300),
            status: ConnectionStatus())
        transport.delegate = recorder
        _ = transport.createDataChannel(label: .interactions, reliable: true)

        _ = try await transport.generateOffer()
        try await Task.sleep(for: .seconds(1))

        XCTAssertFalse(recorder.calls.isEmpty, "Expected at least one delegate callback to assert about")
        XCTAssertEqual(recorder.offMainCalls, [], "Delegate was called off the main thread")
        transport.disconnect()
    }

    /// Smoke check only, and it says so because it passes without the gathering wait too: on
    /// loopback the host candidates are already in the array by the time createOffer() returns.
    /// The wait earns its place on interfaces slower than that, which a unit test can't produce.
    @MainActor
    func testOfferCarriesGatheredCandidates() async throws
    {
        let transport = DataChannelTransport(
            with: TransportConnectionOptions(routing: .direct, portRange: 21300..<21400),
            status: ConnectionStatus())
        _ = transport.createDataChannel(label: .interactions, reliable: true)

        let offer = try await transport.generateOffer()
        XCTAssertFalse(offer.candidates.isEmpty, "Offer went out with no ICE candidates in it")
        transport.disconnect()
    }
}

@MainActor
private final class ThreadRecordingDelegate: TransportDelegate
{
    var calls: [String] = []
    var offMainCalls: [String] = []

    private func record(_ what: String)
    {
        calls.append(what)
        if !Thread.isMainThread { offMainCalls.append(what) }
    }

    func transport(didConnect transport: Transport) { record("didConnect") }
    func transport(didDisconnect transport: Transport) { record("didDisconnect") }
    func transport(_ transport: Transport, didChangeSignallingState state: TransportSignallingState) { record("signalling(\(state))") }
    func transport(_ transport: Transport, didReceiveMediaStream stream: MediaStream) { record("mediaStream") }
    func transport(_ transport: Transport, didRemoveMediaStream stream: MediaStream) { record("removeMediaStream") }
    func transport(requestsRenegotiation transport: Transport) { record("renegotiate") }
    nonisolated func transport(_ transport: Transport, didReceiveData data: Data, on channel: DataChannel) {}
}
