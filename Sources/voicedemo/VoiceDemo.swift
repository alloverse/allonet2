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
//  VOICEDEMO_WAV=<path> loops a recording (wav/m4a/aiff) the same headless way, so a listening
//  test has speech to localise rather than a tone nobody can. Wins over VOICEDEMO_TONE.
//  VOICEDEMO_NO_VPIO=1 captures without the OS voice processor, in the device's native format.
//  VOICEDEMO_LATENCY_LOG=<path> measures mouth-to-speaker latency; see Latency.swift.
//  VOICEDEMO_BIND=127.0.0.1 gathers ICE on loopback only, to match `AlloPlace -b 127.0.0.1`.
//  VOICEDEMO_TOKEN=<place app token> announces with app credentials, for places that refuse
//  anonymous users (`--require-auth`).
//

import Foundation
import allonet2
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

        let url = URL(string: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "alloplace2://localhost:9080")!
        print("Connecting to \(url) (libopus \(Opus.version()))")

        // Decode before connecting: a bad path should fail as itself, not as a client that joins
        // the place and then says nothing.
        var recording: Recording?
        if let path = ProcessInfo.processInfo.environment["VOICEDEMO_WAV"]
        {
            do { recording = try Recording(path: path) }
            catch
            {
                FileHandle.standardError.write(Data("VOICEDEMO_WAV: \(error)\n".utf8))
                exit(1)
            }
        }

        let client = VoiceDemoClient(
            url: url,
            identity: {
                let token = ProcessInfo.processInfo.environment["VOICEDEMO_TOKEN"] ?? ""
                // A token means announce as an app; .none would route into user auth, which wants a password.
                return Identity(expectation: token.isEmpty ? .none : .app, displayName: "VoiceDemo", emailAddress: "", authenticationToken: token)
            }(),
            avatarDescription: EntityDescription(),
            connectionOptions: TransportConnectionOptions(routing: .direct, bindAddress: ProcessInfo.processInfo.environment["VOICEDEMO_BIND"])
        )
        if let path = ProcessInfo.processInfo.environment["VOICEDEMO_LATENCY_LOG"]
        {
            client.latency = try LatencyLog(path: path)
        }
        client.recording = recording
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
    private var voiceTransport: DataChannelTransport!
    private let engine = VoiceEngine(voiceProcessing: ProcessInfo.processInfo.environment["VOICEDEMO_NO_VPIO"] == nil)
    private var outgoing: DataChannelMediaStream?
    private var incoming: [MediaStreamId: DataChannelMediaStream] = [:]
    private var generator: DispatchSourceTimer?
    var latency: LatencyLog?
    var recording: Recording?
    private var outgoingMediaId: MediaStreamId?
    private var lastPolled: [MediaStreamId: UInt32] = [:]

    override func reset()
    {
        voiceTransport = DataChannelTransport(with: self.connectionOptions, status: connectionStatus)
        reset(with: voiceTransport)
    }

    func startVoice() async throws
    {
        guard let avatarId else { return }
        let mediaId = "voice-mic"
        let stream = try voiceTransport.createOutgoingMediaStream(mediaId: mediaId)
        outgoing = stream

        // The receiver knows this stream by its place-wide id, so that is the name a capture
        // time has to be filed under.
        let placeStreamId = PlaceStreamId(shortClientId: cid!.shortClientId, incomingMediaId: mediaId)
        outgoingMediaId = placeStreamId.outgoingMediaId

        let source: String
        if let recording
        {
            startGenerating(into: stream) {
                do { return Array(try recording.nextFrame()) }
                catch
                {
                    FileHandle.standardError.write(Data("Stopped sending: \(error)\n".utf8))
                    return nil
                }
            }
            source = String(format: "recording, %.0f s looping", recording.duration)
        }
        else if let hz = ProcessInfo.processInfo.environment["VOICEDEMO_TONE"].flatMap(Double.init)
        {
            startTone(hz: hz, into: stream)
            source = "tone \(hz) Hz"
        }
        else
        {
            engine.onFrameSent = { [weak self] sequence, at in self?.noteCapture(sequence, at: at) }
            try engine.startCapture(sending: stream)
            source = "microphone, voice processing: \(engine.voiceProcessingEnabled)"
        }
        if latency != nil { startLatencyPolling() }
        try await changeEntity(entityId: avatarId, addOrChange: [
            LiveMedia(mediaId: placeStreamId.outgoingMediaId,
                      format: .audio(codec: .opus, sampleRate: 48000, channelCount: 1))
        ])
        print("Sending \(placeStreamId.outgoingMediaId), \(source)")
    }

    /// Sine on a timer, not an audio clock - deliberately a little jittery.
    private func startTone(hz: Double, into stream: DataChannelMediaStream)
    {
        let frameCount = DataChannelMediaStream.frameDuration
        var phase = 0.0
        let step = 2 * Double.pi * hz / DataChannelMediaStream.sampleRate
        startGenerating(into: stream) {
            var samples = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount { samples[i] = Float(sin(phase)) * 0.25; phase += step }
            return samples
        }
    }

    /// Send one frame every 20 ms from `nextFrame`, off a timer rather than an audio clock.
    /// Returning nil stops the timer for good; the reason belongs on stderr before it does.
    private func startGenerating(into stream: DataChannelMediaStream, _ nextFrame: @escaping () -> [Float]?)
    {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "voicedemo.generator"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        let latency = self.latency
        let mediaId = outgoingMediaId
        timer.setEventHandler { [weak self] in
            guard let samples = nextFrame()
            else
            {
                Task { @MainActor in self?.generator?.cancel(); self?.generator = nil }
                return
            }
            let at = Date()
            let sequence = samples.withUnsafeBufferPointer { stream.send(samples: $0.baseAddress!, frameCount: samples.count) }
            if let sequence, let mediaId { latency?.note(capture: mediaId, sequence: sequence, at: at) }
        }
        generator = timer
        timer.resume()
    }

    private func noteCapture(_ sequence: UInt32, at: Date)
    {
        guard let latency, let outgoingMediaId else { return }
        latency.note(capture: outgoingMediaId, sequence: sequence, at: at)
    }

    /// Poll each playing stream for the frame the audio device last took. The timestamp comes
    /// from the render thread itself, so sampling here costs samples, not accuracy.
    private func startLatencyPolling()
    {
        Task { [weak self] in
            while true
            {
                try await Task.sleep(nanoseconds: 20_000_000)
                guard let self, let latency = self.latency else { return }
                for (mediaId, stream) in incoming
                {
                    guard let played = stream.lastPlayed, played.sequence != lastPolled[mediaId] else { continue }
                    lastPolled[mediaId] = played.sequence
                    latency.note(render: mediaId, sequence: played.sequence, at: played.at)
                }
            }
        }
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
        do
        {
            try engine.play(stream)
            engine.setPosition(.zero, for: stream.mediaId)   // no scene to position sources from
        }
        catch { logger.error("Failed to play \(stream.mediaId): \(error)") }
    }

    override func session(_ session: AlloSession, didRemoveMediaStream stream: MediaStream)
    {
        incoming[stream.mediaId] = nil
        engine.stop(mediaId: stream.mediaId)
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
            let ring = stream.render()
            // Where the latency sits: frames waiting in the jitter buffer, then samples waiting
            // in the ring, then the device. `depth` is those first two added up, against the
            // target the playout rate is steering them to.
            print("in  \(mediaId): \(stream.counters.snapshot) ringUnderrun=\(ring.underruns)"
                  + " jitter=\(stream.jitterBuffer.depth)/\(stream.jitterBuffer.targetDepth) ring=\(ring.availableToRead() * 1000 / Int(DataChannelMediaStream.sampleRate))ms"
                  + String(format: " depth=%.1f/%.0f rate=%.3f", stream.bufferedFrames, stream.targetFrames, stream.playoutRate))
            stream.counters.update { $0.resetPeaks() }
        }
        for measurement in latency?.report() ?? []
        {
            print(String(format: "latency %@: pipeline p50=%.0f p95=%.0f ms (n=%d), output device +%.1f ms",
                         measurement.stream, measurement.p50 * 1000, measurement.p95 * 1000,
                         measurement.count, engine.outputLatency * 1000))
        }
    }
}
