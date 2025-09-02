//
//  PlaceServer+Media.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-28.
//

import Foundation

extension PlaceServer
{
    // TODO: Forward audio based on interactions instead of doing everyone-to-everyone
    /// A new incoming stream arrived. Forward it to everyone.
    internal func handle(incoming stream: MediaStream, from sender: ConnectedClient)
    {
        for (cid, receiver) in self.clients
        {
            do {
                try start(forwarding: stream, from: sender, to: receiver)
            } catch let e {
                print("FAILED to forward media stream \(sender.cid).\(stream.mediaId) -> \(receiver.cid): \(e)")
            }
        }
    }
    
    /// A new client connected. Forward every existing stream to it.
    internal func start(forwardingTo receiver: ConnectedClient)
    {
        for sender in clients.values where sender !== receiver
        {
            for stream in sender.session.incomingStreams.values
            {
                do {
                    try self.start(forwarding: stream, from: sender, to: receiver)
                } catch let e {
                    print("FAILED to do initial forwarding of media stream \(sender.cid).\(stream.mediaId) -> \(receiver.cid): \(e)")
                }
            }
        }
    }
    
    /// Begin forwarding one specific stream from one sender to one receiver
    internal func start(forwarding stream: MediaStream, from sender: ConnectedClient, to receiver: ConnectedClient) throws
    {
        // Don't forward the stream back to its source
        if sender.session.clientId == receiver.session.clientId { return }
        
        let transport = receiver.session.transport
        
        let id = SFUIdentifier(fromMediaId: stream.mediaId, toClient: receiver.cid)
        if let existingSfu = sfus[id]
        {
            return
        }
        print("PlaceServer forwarding \(sender.cid).\(stream.mediaId) -> \(receiver.cid)")
        let sfu = try transportClass.forward(mediaStream: stream, to: transport)
        sfus[id] = sfu
    }
    
    /// Disconnect a specific incoming stream from being transmitted to a specific client
    internal func stop(forwarding stream: MediaStream, to client: ConnectedClient)
    {
        stop(forwarding: stream, toClientId: client.cid)
    }
    /// Disconnect all forwards that are outgoing to a specific client (likely because it disconnected)
    internal func stop(forwarding stream: MediaStream, toClientId: ClientId)
    {
        let id = SFUIdentifier(fromMediaId: stream.mediaId, toClient: toClientId)
        guard let sfu = sfus[id] else { return }
        sfu.stop()
        sfus[id] = nil
    }
    
    /// Disconnect all forwards of one specific incoming stream (likely because *
    public func stop(forwarding stream: MediaStream)
    {
        for id in sfus.keys
        {
            if id.fromMediaId == stream.mediaId
            {
                self.stop(forwarding: stream, toClientId: id.toClient)
            }
        }
    }
    
    internal func stop(forwarding client: ConnectedClient)
    {
        for stream in client.session.incomingStreams.values
        {
            self.stop(forwarding: stream)
        }
    }
    
    internal struct SFUIdentifier: Equatable, Hashable
    {
        let fromMediaId: String
        let toClient: ClientId
    }
}
