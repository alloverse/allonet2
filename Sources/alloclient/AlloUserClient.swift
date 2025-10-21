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
    public func createMicrophoneTrack() -> AudioTrack
    {
        return userTransport.createMicrophoneTrack()
    }
    
    public override init(url: URL, identity: Identity, avatarDescription: EntityDescription, connectionOptions: TransportConnectionOptions)
    {
        self.micEnabled = true
        super.init(url: url, identity: identity, avatarDescription: avatarDescription, connectionOptions: connectionOptions)
    }
    
    open override func reset()
    {
        userTransport = UIWebRTCTransport(with: self.connectionOptions, status: connectionStatus)
        reset(with: userTransport)
    }
}
