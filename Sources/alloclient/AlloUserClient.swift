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
    open override func reset()
    {
        createTrackCancellable?.cancel(); createTrackCancellable = nil
        userTransport = UIWebRTCTransport(with: self.connectionOptions, status: connectionStatus)
        do {
            micTrack = try userTransport.createMicrophoneTrack()
            
            // TODO: Move LiveMedia component registration into AlloSession in some sort of createTrack() API
            createTrackCancellable = $isAnnounced.sink { [weak self] in
                guard let self, let avatar = self.avatar, $0 else { return }
                let scid = session.clientId!.shortClientId
                let tid = "voice" // TODO: Fill in with real track ID, or maybe MID
                Task { @MainActor in
                    print("Registering our microphone track output as a LiveMedia...")
                    do {
                        try await avatar.components.set(LiveMedia(
                            mediaId: PlaceStreamId(shortClientId: scid, incomingMediaId: tid).outgoingMediaId,
                            format: .audio(codec: .opus, sampleRate: 44100, channelCount: 1)
                        ))
                    } catch {
                        print("FAILED!! to register our mic track output as LiveMedia! \(error)")
                    }
                }
                self.createTrackCancellable?.cancel(); self.createTrackCancellable = nil
            }
        } catch {
            print("Failed to create microphone track: \(error)")
        }
        
        reset(with: userTransport)
    }
}
