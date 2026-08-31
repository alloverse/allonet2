import Testing
import Foundation
import simd
import OpenCombineShim
import AlloAudio
@testable import alloclient
@testable import allonet2

@MainActor
struct SpatialAudioPlayerTests
{
    /// Deafening asks the place to stop forwarding, so the streams really do go away and come
    /// back. The player has to be able to play a media id it has already stopped once.
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

    /// Poses come from the place, not from a scene: the talker's own `Transform` decides how far
    /// away it sounds, and a place update is what makes the engine notice it moved.
    @Test func theTalkersPlaceTransformDecidesWhetherItIsHeard() throws
    {
        let world = try TestWorld()
        world.streamArrives()
        try #require(world.isPlaying)

        try world.move(Self.talkerEid, to: [0, 0, -1])
        #expect(world.client.voiceEngine.isAudible(world.mediaId), "a talker one metre away must be heard")

        try world.move(Self.talkerEid, to: [0, 0, -VoiceEngine.maxDistance * 10])
        #expect(!world.client.voiceEngine.isAudible(world.mediaId), "a talker far past maxDistance must not be")
    }

    /// The listener is an entity in the place too, so walking up to a distant talker is the same
    /// arithmetic from the other end.
    @Test func movingTheListenerBringsATalkerBackIntoEarshot() throws
    {
        let world = try TestWorld()
        world.streamArrives()
        try #require(world.isPlaying)

        let far = SIMD3<Float>(0, 0, -VoiceEngine.maxDistance * 10)
        try world.move(Self.talkerEid, to: far)
        try #require(!world.client.voiceEngine.isAudible(world.mediaId))

        try world.move(Self.listenerEid, to: far + [0, 0, 1])
        #expect(world.client.voiceEngine.isAudible(world.mediaId))
    }

    static let listenerEid: EntityID = "listener"
    static let talkerEid: EntityID = "talker"
}

/// One listener, one talker, and a client whose transport goes nowhere: everything the player
/// reacts to is delivered by hand.
@MainActor
private final class TestWorld
{
    let mediaId: MediaStreamId
    let client: TestUserClient
    let player: SpatialAudioPlayer
    private var revision: StateRevision = 0

    /// Whether the player has the talker wired up to the engine right now.
    var isPlaying: Bool { player.playing[mediaId] == SpatialAudioPlayerTests.talkerEid }

    init(mediaId: MediaStreamId = "3F2504E0.voice-mic", advertised: Bool = true) throws
    {
        self.mediaId = mediaId
        client = TestUserClient(url: URL(string: "alloplace2://localhost:21337")!,
                                identity: .none,
                                avatarDescription: EntityDescription(),
                                connectionOptions: TransportConnectionOptions(routing: .direct))
        player = SpatialAudioPlayer(client: client)

        try apply([.entityAdded(EntityData(id: SpatialAudioPlayerTests.listenerEid, ownerClientId: UUID())),
                   .entityAdded(EntityData(id: SpatialAudioPlayerTests.talkerEid, ownerClientId: UUID()))])
        try move(SpatialAudioPlayerTests.listenerEid, to: .zero)
        try move(SpatialAudioPlayerTests.talkerEid, to: .zero)
        if advertised { try advertiseLiveMedia() }
        player.useAsListener(SpatialAudioPlayerTests.listenerEid)
    }

    func advertiseLiveMedia() throws
    {
        let media = LiveMedia(mediaId: mediaId, format: .audio(codec: .opus, sampleRate: 48000, channelCount: 1))
        try apply([.componentAdded(SpatialAudioPlayerTests.talkerEid, AnyComponent(media))])
    }

    /// Put an entity somewhere in place space, as the place server would.
    func move(_ eid: EntityID, to position: SIMD3<Float>) throws
    {
        var matrix = simd_float4x4.identity
        matrix.translation = position
        let transform = AnyComponent(allonet2.Transform(matrix: matrix))
        let known = client.placeState.current.components[allonet2.Transform.componentTypeId]?[eid] != nil
        try apply([known ? .componentUpdated(eid, transform) : .componentAdded(eid, transform)])
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
