import Foundation
@testable import allonet2
import PotentCBOR

// MARK: - MockDataChannel

@MainActor
final class MockDataChannel: DataChannel {
    let alloLabel: DataChannelLabel
    var isOpen: Bool

    init(label: DataChannelLabel, isOpen: Bool = true) {
        self.alloLabel = label
        self.isOpen = isOpen
    }
}

// MARK: - MockTransport

@MainActor
final class MockTransport: Transport {
    // --- Protocol requirements ---
    var clientId: ClientId?
    weak var delegate: TransportDelegate?

    private let connectionOptions: TransportConnectionOptions
    private let connectionStatus: ConnectionStatus

    // --- Test control ---

    /// When true, acceptAnswer() will auto-fire didConnect on the next MainActor tick.
    var autoConnect: Bool = true

    /// Controls what happens when an announce Interaction is sent.
    var announceResponse: AnnounceResponseBehavior = .success(
        avatarId: "test-avatar-1",
        placeName: "Test Place"
    )

    enum AnnounceResponseBehavior {
        case success(avatarId: String, placeName: String)
        case error(AlloverseError)
        case noResponse
    }

    /// If set, generateOffer() will throw this error.
    var generateOfferError: Error?

    // --- Observables for assertions ---
    private(set) var generateOfferCallCount = 0
    private(set) var acceptAnswerCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var sentMessages: [(data: Data, channel: DataChannelLabel)] = []

    private var channels: [DataChannelLabel: MockDataChannel] = [:]

    // --- Init ---
    init(with connectionOptions: TransportConnectionOptions, status: ConnectionStatus) {
        self.connectionOptions = connectionOptions
        self.connectionStatus = status
    }

    // --- Transport protocol ---
    func generateOffer() async throws -> SignallingPayload {
        generateOfferCallCount += 1
        if let error = generateOfferError { throw error }
        clientId = UUID()
        return SignallingPayload(sdp: "mock-offer-sdp", candidates: [], clientId: clientId)
    }

    func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload {
        fatalError("MockTransport is client-only; generateAnswer not supported")
    }

    func acceptAnswer(_ answer: SignallingPayload) async throws {
        acceptAnswerCallCount += 1
        if clientId == nil { clientId = answer.clientId }
        if autoConnect {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.transport(didConnect: self)
            }
        }
    }

    func rollbackOffer() async throws {
        // No-op for mock
    }

    func disconnect() {
        disconnectCallCount += 1
        // The real transport calls the delegate back synchronously from here (see
        // DataChannelTransport.disconnect), which is what makes reentrancy during teardown
        // possible at all. A mock that stays quiet can't catch a regression in that.
        guard !isDisconnected else { return }
        isDisconnected = true
        delegate?.transport(didDisconnect: self)
    }
    private var isDisconnected = false

    func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel? {
        let ch = MockDataChannel(label: label, isOpen: true)
        channels[label] = ch
        return ch
    }

    func send(data: Data, on channel: DataChannelLabel) {
        sentMessages.append((data: data, channel: channel))

        if channel == .interactions {
            autoRespondToAnnounce(data: data)
        }
    }

    func forward(mediaStream: MediaStream, from sender: any Transport) throws -> MediaStreamForwarder {
        MockMediaStreamForwarder()
    }

    // --- Test helpers ---

    /// Simulate transport disconnect (as if ICE failed)
    func simulateDisconnect() {
        delegate?.transport(didDisconnect: self)
    }

    /// Hand an interaction back to the session as if the peer had sent it.
    func deliver(_ interaction: Interaction) {
        guard let data = try? CBOREncoder().encode(interaction) else { return }
        let channel = channels[.interactions] ?? MockDataChannel(label: .interactions, isOpen: true)
        delegate?.transport(self, didReceiveData: data, on: channel)
    }

    /// Simulate receiving data on a channel
    func simulateReceiveData(_ data: Data, on label: DataChannelLabel) {
        guard let ch = channels[label] else {
            fatalError("No channel \(label) created yet")
        }
        delegate?.transport(self, didReceiveData: data, on: ch)
    }

    // --- Private ---

    private func autoRespondToAnnounce(data: Data) {
        let decoder = CBORDecoder()
        guard let interaction = try? decoder.decode(Interaction.self, from: data) else { return }
        guard case .announce = interaction.body else { return }

        let responseBody: InteractionBody
        switch announceResponse {
        case .success(let avatarId, let placeName):
            responseBody = .announceResponse(avatarId: avatarId, placeName: placeName)
        case .error(let error):
            responseBody = error.asBody
        case .noResponse:
            return
        }

        let response = interaction.makeResponse(with: responseBody)
        let encoder = CBOREncoder()
        guard let responseData = try? encoder.encode(response) else { return }

        // Deliver on the next tick (simulating network latency)
        Task { @MainActor [weak self] in
            guard let self, let ch = self.channels[.interactions] else { return }
            self.delegate?.transport(self, didReceiveData: responseData, on: ch)
        }
    }
}
