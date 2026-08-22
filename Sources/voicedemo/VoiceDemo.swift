//
//  VoiceDemo.swift
//  allonet2
//
//  Mic in, voice out, over data channels. Run two against one place and talk between them.
//
//  Usage: swift run voicedemo [alloplace2://host:port]
//
//  VOICEDEMO_TONE=440 sends a sine at that frequency instead of the microphone. No capture
//  engine, no voice processing, no permission prompt: a sender an agent can run headless.
//  VOICEDEMO_NO_VPIO=1 captures without the OS voice processor, in the device's native format.
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
        setvbuf(stdout, nil, _IOLBF, 0)   // counters must reach a redirected log as they happen
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

        // macOS prompts for microphone access on first run; a human has to answer it.
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
    private var tone: DispatchSourceTimer?

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
        if let hz = ProcessInfo.processInfo.environment["VOICEDEMO_TONE"].flatMap(Double.init)
        {
            startTone(hz: hz, into: stream)
        }
        else
        {
            try capture.start(sending: stream, voiceProcessing: ProcessInfo.processInfo.environment["VOICEDEMO_NO_VPIO"] == nil)
        }

        let placeStreamId = PlaceStreamId(shortClientId: cid!.shortClientId, incomingMediaId: mediaId)
        try await changeEntity(entityId: avatarId, addOrChange: [
            LiveMedia(mediaId: placeStreamId.outgoingMediaId,
                      format: .audio(codec: .opus, sampleRate: 48000, channelCount: 1))
        ])
        print("Sending \(placeStreamId.outgoingMediaId), " + (tone != nil ? "tone" : "voice processing: \(capture.voiceProcessingEnabled)"))
    }

    /// Sine on a timer, not an audio clock - deliberately a little jittery.
    private func startTone(hz: Double, into stream: DataChannelMediaStream)
    {
        let frameCount = DataChannelMediaStream.frameDuration
        var phase = 0.0
        let step = 2 * Double.pi * hz / DataChannelMediaStream.sampleRate
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "voicedemo.tone"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler {
            var samples = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount { samples[i] = Float(sin(phase)) * 0.25; phase += step }
            samples.withUnsafeBufferPointer { stream.send(samples: $0.baseAddress!, frameCount: frameCount) }
        }
        tone = timer
        timer.resume()
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
        Task
        {
            do { try await updateListeners() }
            catch { FileHandle.standardError.write(Data("Failed to update listeners: \(error)\n".utf8)) }
        }
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
        if let outgoing
        {
            print("out \(outgoing.mediaId): \(outgoing.counters.snapshot)")
            outgoing.counters.update { $0.resetPeaks() }
        }
        for (mediaId, stream) in incoming
        {
            print("in  \(mediaId): \(stream.counters.snapshot) ringUnderrun=\(stream.render().underruns)")
            stream.counters.update { $0.resetPeaks() }
        }
    }
}
