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
        // 1. Mic
        do {
            micTrack = try userTransport.createMicrophoneTrack()
            
            // TODO: Move LiveMedia component registration into AlloSession in some sort of createTrack() API
            createTrackCancellable = $isAnnounced.sink { [weak self] in
                guard let self, let avatar = self.avatar, $0 else { return }
                let scid = session.clientId!.shortClientId
                let tid = "voice-mic" // TODO: Fill in with real track ID
                Task { @MainActor in
                    guard self.isAnnounced else { return }
                    let liveMedia = LiveMedia(
                        mediaId: PlaceStreamId(shortClientId: scid, incomingMediaId: tid).outgoingMediaId,
                        // TODO: set format from actual track metadata, probably as part of createTrack refactor
                        format: .audio(codec: .opus, sampleRate: 44100, channelCount: 1)
                    )
                    print("Registering our microphone track output as a \(liveMedia)...")
                    do {
                        try await avatar.components.set(liveMedia)
                    } catch {
                        print("FAILED!! to register our mic track output as LiveMedia! \(error)")
                    }
                }
                self.createTrackCancellable?.cancel(); self.createTrackCancellable = nil
            }
        } catch {
            print("Failed to create microphone track: \(error)")
        }
        
        // 2. Setup listeners to get incoming tracks. Just ask to get everything (except our mic) forwarded.
        var streamIds = Set<String>()
        func updateListener()
        {
            Task { @MainActor in
                print("Updating listener to forward \(streamIds)")
                try? await avatar?.components.set(LiveMediaListener(mediaIds: streamIds))
            }
        }
        placeState.observers[LiveMedia.self].added.sink { [weak self] eid, liveMedia in
            guard eid != self?.avatarId else { return }
            streamIds.insert(liveMedia.mediaId)
            updateListener()
        }.store(in: &cancellables)
        placeState.observers[LiveMedia.self].removed.sink { [weak self] _eid, liveMedia in
            streamIds.remove(liveMedia.mediaId)
            updateListener()
        }.store(in: &cancellables)
    }
}
