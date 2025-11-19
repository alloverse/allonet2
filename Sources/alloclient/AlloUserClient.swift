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
    private var userTransport: UIWebRTCTransport!
    @Published public var micEnabled: Bool = false
    {
        didSet { userTransport.microphoneEnabled = micEnabled }
    }
    private var micTrack: AudioTrack? = nil
    public func createMicrophoneTrackIfNeeded() -> AudioTrack
    {
        if micTrack == nil {
            micTrack = userTransport.createMicrophoneTrack()
        }
        return micTrack!
    }
    
    public override init(url: URL, identity: Identity, avatarDescription: EntityDescription, connectionOptions: TransportConnectionOptions)
    {
        self.micEnabled = true
        super.init(url: url, identity: identity, avatarDescription: avatarDescription, connectionOptions: connectionOptions)
        startSendingLogs()
    }
    
    open override func reset()
    {
        userTransport = UIWebRTCTransport(with: self.connectionOptions, status: connectionStatus)
        let _ = createMicrophoneTrackIfNeeded()
        reset(with: userTransport)
    }
    
    var cancellables: Set<AnyCancellable> = []
    func startSendingLogs()
    {
        var task: Task<Void, Never>? = nil
        self.connectionStatus.$reconnection.sink { [weak self] in
            if $0 == .connected {
                task = Task {
                     for await log in await LogStore.shared.stream() {
                        self?.session.send(log)
                     }
                }
                // clear out history after sending the first batch
                Task { await LogStore.shared.clear() }
            } else {
                task?.cancel()
            }
        }.store(in: &cancellables)
    }
}
