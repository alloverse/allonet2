//
//  SpatialAudioPlayer.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-09-12.
//

import allonet2
import alloclient
import RealityKit
import OpenCombineShim
import SwiftUICore

/// Syncs `LiveMedia` components from entities surrounding the local avatar and plays them back spatially.
@MainActor
public class SpatialAudioPlayer
{
    let mapper: RealityViewMapper
    let client: AlloUserClient
    
    public init(mapper: RealityViewMapper, client: AlloUserClient)
    {
        self.mapper = mapper
        self.client = client
        start()
    }
    
    func start()
    {
        mapper.startSyncingOf(networkComponentType: LiveMedia.self, updater: { guient, netent, liveMedia in
            // Don't try to play our own streams
            if netent.ownerClientId == self.client.cid { return }
            
        }, remover: { entity, netent, liveMedia in
        
        })
    }
}
