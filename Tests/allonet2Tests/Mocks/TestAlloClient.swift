import Foundation
@testable import allonet2

@MainActor
final class TestAlloClient: AlloClient {
    /// Access the mock transport for test assertions and control.
    var mockTransport: MockTransport!

    /// Override to inject error into HTTP signalling.
    var signallingError: Error?

    override func reset() {
        mockTransport = MockTransport(with: connectionOptions, status: connectionStatus)
        reset(with: mockTransport)
    }

    override func performHTTPSignalling(offer: SignallingPayload) async throws -> SignallingPayload {
        if let error = signallingError { throw error }
        return SignallingPayload(sdp: "mock-answer-sdp", candidates: [], clientId: UUID())
    }
}
