//
//  PlaceServer+Media.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-28.
//

import Foundation
import OpenCombineShim

extension String
{
    var psi: PlaceStreamId? {
        let parts = self.split(separator: ".")
        guard parts.count == 2 else { return nil }
        return PlaceStreamId(shortClientId: String(parts[0]), incomingMediaId: String(parts[1]))
    }
}

// The actual stream that a PlaceStreamId refers to
internal struct PlaceStream: CustomStringConvertible
{
    let sender: ConnectedClient
    let stream: MediaStream
    var psi: PlaceStreamId {
        return PlaceStreamId(shortClientId: sender.cid.shortClientId, incomingMediaId: stream.mediaId)
    }
    
    public var description: String {
        "<PlaceStream \(psi) around \(stream)>"
    }
}

// A pairing of a PlaceStreamId identifying the incoming stream, and a targetClient ID, together identifying one single instance of forwarding media from one client to one client.
internal struct ForwardingId: Equatable, Hashable, CustomStringConvertible
{
    let source: PlaceStreamId
    let target: ClientId
    
    public var description: String {
        "<ForwardingId \(source.outgoingMediaId) -> \(target.shortClientId)>"
    }
}

/// `PlaceServerSFU` listens to client requests to receive an available audio or video streams, and forwards it to them if and when possible.
@MainActor
class PlaceServerSFU
{
    /// This is done by reconciling two async event streams:
    /// 1. Requests for **desired streams** come in as component changes of the type `LiveMediaListener`
    internal var desired = Set<ForwardingId>()

    /// 2. WebRTC events indicate **available** streams
    internal var available: [PlaceStreamId: PlaceStream] = [:] // All the incoming streams that are available for forwarding.
    private var availableIds: Set<PlaceStreamId> { Set(available.keys) }
    
    /// Then: **active** streams are active forwarders that forwards an available stream when it is desired.
    internal var active: [ForwardingId: MediaStreamForwarder] = [:] // the currently forwarding streams
    private var activeIds: Set<ForwardingId> { Set(active.keys) }
    
    // Internals
    private unowned let server: PlaceServer
    private var cancellables = Set<AnyCancellable>()
    internal init(server: PlaceServer)
    {
        self.server = server
        observeMediaStreams()
    }
    
    internal func stop()
    {
        for cancellable in cancellables { cancellable.cancel() }
    }
    
    // MARK: #1: Desired, requests for streams
    func observeMediaStreams()
    {
        // Changes to the LiveMediaListener component indicates a request from a client to start or stop receiving a media stream. Start or stop a Forwarder based on this. This will also trigger stopping when a client disconnects, since the client dropping will lead to its entities and thus LiveMediaListener components disappearing.
        var olds: [EntityID: Set<String>] = [:]
        server.place.observers[LiveMediaListener.self].updatedWithInitial.sink { (eid, comp) in
            let cid = self.server.place.current.entities[eid]!.ownerClientId
            let new = comp.mediaIds
            let old = olds.updateValue(new, forKey: eid) ?? []
            for lostMediaId in old.subtracting(new).flatMap(\.psi) {
                print("PlaceServer SFU lost request \(lostMediaId) -> \(cid)")
                self.desired.remove(ForwardingId(source: lostMediaId, target: cid))
            }
            for addedMediaId in new.subtracting(old).flatMap(\.psi) {
                print("PlaceServer SFU gained request \(addedMediaId) -> \(cid)")
                self.desired.insert(ForwardingId(source: addedMediaId, target: cid))
            }
            self.reconcile()
        }.store(in: &cancellables)
        server.place.observers[LiveMediaListener.self].removed.sink { (edata, comp) in
            let cid = edata.ownerClientId
            let gone = olds.removeValue(forKey: edata.id) ?? comp.mediaIds
            for lostMediaId in comp.mediaIds.flatMap(\.psi) {
                print("PlaceServer SFU lost request from removal \(lostMediaId) -> \(cid)")
                self.desired.remove(ForwardingId(source: lostMediaId, target: cid))
            }
            self.reconcile()
        }.store(in: &cancellables)
    }
    
    // MARK: #2: Available, WebRTC stream events
    /// A new incoming stream arrived. Keep track of it in case someone wants it in the future.
    internal func handle(incoming stream: MediaStream, from sender: ConnectedClient)
    {
        // Only ingress streams should be marked as available for forwarding
        if stream.streamDirection == .sendonly { return }
        
        let incoming = PlaceStream(sender: sender, stream: stream)
        print("PlaceServer SFU got new stream \(incoming)")
        available[incoming.psi] = incoming
        reconcile()
    }
    
    /// Either the client disconnected, or at least its stream was lost. Stop forwarding it.
    internal func handle(lost stream: MediaStream, from sender: ConnectedClient)
    {
        let psi = PlaceStreamId(shortClientId: sender.cid.shortClientId, incomingMediaId: stream.mediaId)
        print("PlaceServer SFU lost stream \(psi)")
        available[psi] = nil
        reconcile()
    }
    
    // MARK: Active: Start and stop forwardings based on the above two event streams
    private func reconcile()
    {
        let wanted = desired.filter { availableIds.contains($0.source) }
        let toStart = wanted.subtracting(activeIds)
        let toStop  = activeIds.subtracting(wanted)

        toStop.forEach { stop(forwarding: $0) }
        toStart.forEach { start(forwarding: $0) }
    }
    
    private func start(forwarding fid: ForwardingId)
    {
        let placestream = available[fid.source]! // !: precondition that it's avilable from reconcile()
        assert(placestream.stream.streamDirection.isRecv, "Can only forward incoming streams")
        let target = self.server.clients[fid.target]! // !: client must exist for the component that generated the `desired` entry to exist
        
        print("PlaceServer SFU START forwarding \(fid)")
        do {
            let sfu = try server.transportClass.forward(mediaStream: placestream.stream, from: placestream.sender.session.transport, to: target.session.transport)
            active[fid] = sfu
        } catch (let e)
        {
            // TODO: Would be nice to let the requesting client know that the request failed (maybe set an attribute on the component? or a generic "error message" interaction?)
            // TODO: have a `failed` set so we don't try to start it again?
            print("ERROR: Failed to start forwarding \(fid): \(e)")
        }
    }
    
    private func stop(forwarding fid: ForwardingId)
    {
        guard let forwarder = active[fid] else { return }
        print("PlaceServer SFU STOP forwarding \(fid)")
        forwarder.stop()
        active[fid] = nil
    }
}
