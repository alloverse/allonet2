import Testing
import Foundation
import RealityKit
import OpenCombineShim
@testable import AlloReality
@testable import alloclient
@testable import allonet2

/// Deafening asks the place to stop forwarding, so the streams really do go away and come back.
/// The player has to be able to play a media id it has already stopped once.
@MainActor
struct SpatialAudioPlayerTests
{
    @Test func aStreamThatReturnsAfterDeafeningPlaysAgain() throws
    {
        let world = try TestWorld()

        world.streamArrives()
        try #require(world.isPlaying, "the first stream never played, so the test proves nothing")

        // Deafen: the place drops the forwarding, and the channel closing removes the stream.
        world.client.speakerEnabled = false
        world.streamGoesAway()
        #expect(!world.isPlaying)

        // Undeafen: the place forwards again, on a new channel with the same media id.
        world.client.speakerEnabled = true
        world.streamArrives()
        #expect(world.isPlaying)
    }

    /// The mirror image: a stream whose `LiveMedia` component only shows up afterwards.
    @Test func aStreamThatArrivesBeforeItsComponentPlaysWhenTheComponentLands() throws
    {
        let world = try TestWorld(advertised: false)

        world.streamArrives()
        #expect(!world.isPlaying)

        try world.advertiseLiveMedia()
        #expect(world.isPlaying)
    }
}

/// One listener, one talker, and a client whose transport goes nowhere: everything the player
/// reacts to is delivered by hand.
@MainActor
private final class TestWorld
{
    static let listenerEid: EntityID = "listener"
    static let talkerEid: EntityID = "talker"

    let mediaId: MediaStreamId
    let client: TestUserClient
    let player: SpatialAudioPlayer
    private let guiroot = RealityKit.Entity()
    private var revision: StateRevision = 0

    /// Whether the player has the talker wired up to the engine right now.
    var isPlaying: Bool { guiroot.findEntity(named: Self.talkerEid)?.components[VoiceSourceComponent.self] != nil }

    init(mediaId: MediaStreamId = "3F2504E0.voice-mic", advertised: Bool = true) throws
    {
        self.mediaId = mediaId
        client = TestUserClient(url: URL(string: "alloplace2://localhost:21337")!,
                                identity: .none,
                                avatarDescription: EntityDescription(),
                                connectionOptions: TransportConnectionOptions(routing: .direct))
        player = SpatialAudioPlayer(mapper: RealityViewMapper(networkState: client.placeState, addingEntitiesTo: guiroot),
                                    client: client)

        for eid in [Self.listenerEid, Self.talkerEid]
        {
            let guient = RealityKit.Entity()
            guient.name = eid
            guiroot.addChild(guient)
        }
        try apply([.entityAdded(EntityData(id: Self.listenerEid, ownerClientId: UUID())),
                   .entityAdded(EntityData(id: Self.talkerEid, ownerClientId: UUID()))])
        if advertised { try advertiseLiveMedia() }
        player.useAsListener(Self.listenerEid)
    }

    func advertiseLiveMedia() throws
    {
        let media = LiveMedia(mediaId: mediaId, format: .audio(codec: .opus, sampleRate: 48000, channelCount: 1))
        try apply([.componentAdded(Self.talkerEid, AnyComponent(media))])
    }

    /// The place opened a channel for the forwarded stream and the transport adopted it.
    func streamArrives()
    {
        let stream = DataChannelMediaStream(mediaId: mediaId, direction: .recvonly, sendFrame: { _ in true })
        client.session.transport(client.transport, didReceiveMediaStream: stream)
    }

    /// The place stopped forwarding, so the channel under the stream closed.
    func streamGoesAway()
    {
        guard let stream = client.session.incomingStreams[mediaId] else { return }
        client.session.transport(client.transport, didRemoveMediaStream: stream)
    }

    private func apply(_ changes: [PlaceChange]) throws
    {
        let changeSet = PlaceChangeSet(changes: changes, fromRevision: revision, toRevision: revision + 1)
        try #require(client.placeState.applyChangeSet(changeSet))
        revision += 1
    }
}

/// An `AlloUserClient` that never dials anything. Everything the place would say is injected.
@MainActor
private final class TestUserClient: AlloUserClient
{
    override func reset() { reset(with: SilentTransport()) }
}

/// Connects to nothing and drops what is sent on it. The player's listener updates go out as
/// interactions; nobody is there to answer, and no test here needs one to.
private final class SilentTransport: Transport
{
    enum Unsupported: Error { case thisTransportNeverConnects }

    var clientId: ClientId?
    weak var delegate: TransportDelegate?

    func generateOffer() async throws -> SignallingPayload { throw Unsupported.thisTransportNeverConnects }
    func generateAnswer(for offer: SignallingPayload) async throws -> SignallingPayload { throw Unsupported.thisTransportNeverConnects }
    func acceptAnswer(_ answer: SignallingPayload) async throws { throw Unsupported.thisTransportNeverConnects }
    func rollbackOffer() async throws { throw Unsupported.thisTransportNeverConnects }
    func disconnect() {}
    func createDataChannel(label: DataChannelLabel, reliable: Bool) -> DataChannel? { nil }
    func send(data: Data, on channel: DataChannelLabel) {}
    func forward(mediaStream: MediaStream, from sender: any Transport) throws -> MediaStreamForwarder { throw Unsupported.thisTransportNeverConnects }
}
