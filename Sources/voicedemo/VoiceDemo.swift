//
//  VoiceDemo.swift
//  allonet2
//
//  Mic in, voice out, over data channels. The morning's live check: run two of these against
//  one place and talk between them.
//
//  Usage: swift run voicedemo [alloplace2://host:port]
//

import Foundation
import allonet2
import alloheadless
import AlloAudio
import AlloOpus
import Logging

private var logger = Logger(labelSuffix: "voicedemo")

@main @MainActor
struct VoiceDemo
{
    static func main() async throws
    {
        Opus.install()

        let url = URL(string: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "alloplace2://localhost:9080")!
        print("Connecting to \(url) (libopus \(Opus.version()))")

        let client = VoiceDemoClient(
            url: url,
            identity: Identity(expectation: .none, displayName: "VoiceDemo", emailAddress: "", authenticationToken: ""),
            avatarDescription: EntityDescription(),
            connectionOptions: TransportConnectionOptions(routing: .direct)
        )
        client.stayConnected()

        // macOS prompts for microphone access the first time this runs, and the prompt has to
        // be answered by a human - which is why the live check is morning work.
        while client.avatarId == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        try await client.startVoice()

        print("Connected as \(client.avatarId!). Talking. Ctrl-C to stop.")
        while true
        {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            client.reportCounters()
        }
    }
}

@MainActor
final class VoiceDemoClient: AlloClient
{
    private var voiceTransport: HeadlessWebRTCTransport!
    private let capture = VoiceCapture()
    private let playout = VoicePlayout()
    private var outgoing: DataChannelMediaStream?
    private var incoming: [MediaStreamId: DataChannelMediaStream] = [:]

    override func reset()
    {
        voiceTransport = HeadlessWebRTCTransport(with: self.connectionOptions, status: connectionStatus)
        reset(with: voiceTransport)
    }

    func startVoice() async throws
    {
        guard let avatarId else { return }
        let mediaId = "voice-mic"
        let stream = try voiceTransport.createOutgoingMediaStream(mediaId: mediaId)
        outgoing = stream
        try capture.start(sending: stream)

        let placeStreamId = PlaceStreamId(shortClientId: cid!.shortClientId, incomingMediaId: mediaId)
        try await changeEntity(entityId: avatarId, addOrChange: [
            LiveMedia(mediaId: placeStreamId.outgoingMediaId,
                      format: .audio(codec: .opus, sampleRate: 48000, channelCount: 1))
        ])
        print("Sending \(placeStreamId.outgoingMediaId), voice processing: \(capture.voiceProcessingEnabled)")
    }

    /// Listen to everything in the place except ourselves.
    private func updateListeners() async throws
    {
        guard let avatarId else { return }
        let mine = PlaceStreamId(shortClientId: cid!.shortClientId, incomingMediaId: "voice-mic").outgoingMediaId
        var wanted = Set<MediaStreamId>()
        for (_, media) in placeState.current.components[LiveMedia.self] where media.mediaId != mine
        {
            wanted.insert(media.mediaId)
        }
        try await changeEntity(entityId: avatarId, addOrChange: [LiveMediaListener(mediaIds: wanted)])
    }

    override func session(_ session: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        super.session(session, didReceivePlaceChangeSet: changeset)
        Task { try? await updateListeners() }
    }

    override func session(_ session: AlloSession, didReceiveMediaStream stream: MediaStream)
    {
        guard let stream = stream as? DataChannelMediaStream else { return }
        incoming[stream.mediaId] = stream
        do { try playout.play(stream) }
        catch { logger.error("Failed to play \(stream.mediaId): \(error)") }
    }

    override func session(_ session: AlloSession, didRemoveMediaStream stream: MediaStream)
    {
        incoming[stream.mediaId] = nil
        playout.stop(stream.mediaId)
    }

    func reportCounters()
    {
        if let outgoing { print("out \(outgoing.mediaId): \(outgoing.counters.snapshot)") }
        for (mediaId, stream) in incoming { print("in  \(mediaId): \(stream.counters.snapshot)") }
    }
}
