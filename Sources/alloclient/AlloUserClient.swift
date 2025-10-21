//
//  AlloUserClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-06-05.
//

import allonet2
import OpenCombineShim
import Foundation

public class AlloUserClient : AlloClient
{
    private var micTrack: AudioTrack?
    private var userTransport: UIWebRTCTransport!
    @Published public var micEnabled: Bool = false
    {
        didSet { userTransport.microphoneEnabled = micEnabled }
    }
    
    public override init(url: URL, identity: Identity, avatarDescription: EntityDescription, connectionOptions: TransportConnectionOptions)
    {
        self.micEnabled = true
        super.init(url: url, identity: identity, avatarDescription: avatarDescription, connectionOptions: connectionOptions)
    }
    
    var createTrackCancellable: AnyCancellable? = nil
    var cancellables = Set<AnyCancellable>()
    open override func reset()
    {
        cancellables.removeAll()
        createTrackCancellable?.cancel(); createTrackCancellable = nil
        userTransport = UIWebRTCTransport(with: self.connectionOptions, status: connectionStatus)
        setupAudio()
        reset(with: userTransport)
    }
    
    func setupAudio()
    {
        do {
            micTrack = try userTransport.createMicrophoneTrack()
            
            // TODO: Move LiveMedia component registration into AlloSession in some sort of createTrack() API
            // Or we do it in transport(:didReceiveMediaStream:)
            // In any case, this code absolutely does not belong here, and especially not the hard-coding of finding the avatar's head.
            createTrackCancellable = $isAnnounced.sink { [weak self] in
                guard let self, let avatar = self.avatar, let cid = session.clientId, $0 else { return }
                let scid = cid.shortClientId
                let tid = "voice-mic" // TODO: Fill in with real track ID
                Task { @MainActor in
                    guard self.isAnnounced else { return }
                    let liveMedia = LiveMedia(
                        mediaId: PlaceStreamId(shortClientId: scid, incomingMediaId: tid).outgoingMediaId,
                        // TODO: set format from actual track metadata, probably as part of createTrack refactor
                        format: .audio(codec: .opus, sampleRate: 44100, channelCount: 1)
                    )
                    self.logger.info("Registering our microphone track output as a \(liveMedia). Finding head and setting component on it...")
                    do {
                        // This absolutely certainly doesn't belong here
                        guard let head = avatar.children.first(where: {
                            if case .sphere(radius: _) = $0.components[Model.self]?.mesh {
                                return true
                            }
                            return false
                        }) else {
                            fatalError("Can't find appropriate entity to attach mic audio to: missing head!")
                        }
                        try await head.components.set(liveMedia)
                    } catch {
                        self.logger.error("FAILED!! to register our mic track output as LiveMedia! \(error)")
                    }
                }
                self.createTrackCancellable?.cancel(); self.createTrackCancellable = nil
            }
        } catch {
            logger.error("Failed to create microphone track: \(error)")
        }
    }
}
