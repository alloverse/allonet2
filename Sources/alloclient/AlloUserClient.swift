//
//  AlloUserClient.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-06-05.
//

import allonet2
import Combine
import Foundation

public class AlloUserClient : AlloClient
{
    private var micTrack: AudioTrack?
    private var userTransport: UIWebRTCTransport!
    @Published public var micEnabled: Bool = false
    {
        didSet { userTransport.microphoneEnabled = micEnabled }
    }
    
    public override init(url: URL, avatarDescription: EntityDescription)
    {
        self.micEnabled = true
        super.init(url: url, avatarDescription: avatarDescription)
    }
    
    open override func reset()
    {
        userTransport = UIWebRTCTransport(with: .direct, status: connectionStatus)
        do {
            micTrack = try userTransport.createMicrophoneTrack()
        } catch {
            print("Failed to create microphone track: \(error)")
        }
        
        reset(with: userTransport)
    }
}
