//
//  AlloUserClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-06-05.
//

import allonet2
import alloheadless
import AlloAudio
import AlloOpus
import OpenCombineShim
import Foundation
import Logging

public class AlloUserClient : AlloClient
{
    private var userTransport: DataChannelTransport!

    @Published public var micEnabled: Bool = false
    {
        didSet { micTrack?.isEnabled = micEnabled }
    }
    /// Whether to play back others' audio. Off = deafened: SpatialAudioPlayer asks the
    /// place to stop forwarding streams entirely, so this also stops inbound audio traffic.
    @Published public var speakerEnabled: Bool = true

    private var micTrack: MicrophoneTrack? = nil

    /// The microphone, as a track the UI can mute. Backed by a voice stream on its own data
    /// channel; nothing is captured until the transport connects.
    public func createMicrophoneTrackIfNeeded() -> AudioTrack
    {
        if micTrack == nil
        {
            micTrack = MicrophoneTrack(transport: userTransport, isEnabled: micEnabled)
        }
        return micTrack!
    }

    public override init(url: URL, identity: Identity, avatarDescription: EntityDescription, connectionOptions: TransportConnectionOptions)
    {
        Opus.install()
        self.micEnabled = true
        super.init(url: url, identity: identity, avatarDescription: avatarDescription, connectionOptions: connectionOptions)
        startSendingLogs()
    }

    open override func reset()
    {
        micTrack?.stop()
        micTrack = nil
        userTransport = DataChannelTransport(with: self.connectionOptions, status: connectionStatus)
        let _ = createMicrophoneTrackIfNeeded()
        reset(with: userTransport)
    }

    var cancellables: Set<AnyCancellable> = []
    func startSendingLogs()
    {
        var task: Task<Void, Never>? = nil
        self.connectionStatus.$reconnection.sink { [weak self] in
            guard let self else { return }
            if $0 == .connected {
                // Capture only once a channel exists to send on.
                micTrack?.transportConnected()
                task = Task {
                     for await log in await LogStore.shared.stream() {
                        self.session.send(log)
                     }
                }
                // clear out history after sending the first batch
                Task { await LogStore.shared.clear() }
            } else {
                micTrack?.stop()
                task?.cancel()
            }
        }.store(in: &cancellables)
    }
}

/// A mutable on/off switch over a voice stream on its own data channel.
@MainActor
final class MicrophoneTrack: AudioTrack
{
    /// Matches what KojaApp registers in its `LiveMedia` component.
    static let mediaId = "voice-mic"

    private weak var transport: DataChannelTransport?
    private let capture = VoiceCapture()
    private var stream: DataChannelMediaStream?
    private var micLogger = Logger(labelSuffix: "client.microphone")
    private var connected = false

    var isEnabled: Bool
    {
        didSet { apply() }
    }

    init(transport: DataChannelTransport, isEnabled: Bool)
    {
        self.transport = transport
        self.isEnabled = isEnabled
    }

    func transportConnected()
    {
        connected = true
        apply()
    }

    func stop()
    {
        capture.stop()
        connected = false
    }

    private func apply()
    {
        guard connected, let transport else { return }
        if isEnabled
        {
            guard !capture.isRunning else { return }
            do
            {
                let stream = try self.stream ?? transport.createOutgoingMediaStream(mediaId: Self.mediaId)
                self.stream = stream
                try capture.start(sending: stream)
                micLogger.info("Microphone on, voice processing: \(capture.voiceProcessingEnabled)")
            }
            catch
            {
                micLogger.error("Could not start the microphone: \(error)")
            }
        }
        else
        {
            capture.stop()
        }
    }
}
