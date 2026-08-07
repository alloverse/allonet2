//
//  PlaceServer+Interaction.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation

extension PlaceServer
{
    public func session(_ sess: AlloSession, didReceiveInteraction inter: Interaction)
    {
        
        let cid = sess.clientId!

        Task { @MainActor in
            // Condemned clients still have interactions in flight — they get no further service.
            // And an unknown cid is hostile input, not a place bug; neither may trap.
            guard let client = self.clients[cid] ?? self.unannouncedClients[cid] else
            {
                self.logger.forClient(cid).info("Dropping interaction from client we no longer serve: \(inter)")
                return
            }
            let ilogger = client.logger.forInteraction(inter)
            ilogger.trace("Received and now handling interaction from \(cid): \(inter)")
            await self.handle(inter, from: client)
        }
    }

    func handle(_ inter: Interaction, from client: ConnectedClient) async
    {
        let ilogger = client.logger.forInteraction(inter)
        do throws(AlloverseError)
        {
            let senderEnt = place.current.entities[inter.senderEntityId]
            let isValidAnnounce = inter.body.caseName == "announce" && inter.senderEntityId == ""
            let isValidOtherMessage = (senderEnt != nil) && senderEnt!.ownerClientId == client.cid
            if !(isValidAnnounce || isValidOtherMessage)
            {
                throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "You may only send interactions from entities you own")
            }
            if inter.receiverEntityId == Interaction.PlaceEntity
            {
                try await self.handle(placeInteraction: inter, from: client)
            } else {
                try await self.handle(forwardingOfInteraction: inter, from: client)
            }
        
        }
        catch (let e as AlloverseError)
        {
            ilogger.error("Interaction error when handling \(inter): \(e)")
            if inter.type == .request
            {
                client.session.send(interaction: inter.makeResponse(with: e.asBody))
                if e.isFatal
                {
                    ilogger.error("Interaction error was fatal, condemning the client.")
                    await condemn(client)
                }
            }
        }
    }
    
    /// A fatal error ends this client's stay, but the response saying *why* has to win the race
    /// with the hangup: the bytes may not have flushed, and even received, the client processes
    /// interactions one main-actor hop later than a disconnect. So the client's presence ends now
    /// — off the rosters, no more service or world updates, entities and publishing rights torn
    /// down — while the session stays up for the client to act on the answer and hang up itself,
    /// as AlloClient does. The backstop disconnect is only for one that ignores the answer.
    func condemn(_ client: ConnectedClient) async
    {
        let cid = client.cid
        guard waitingToDisconnect[cid] == nil else { return } // a second fatal error changes nothing
        // A client no longer in any roster already disconnected — dropped while authenticate()
        // awaited the provider, say — and that path tore it down. Quarantining it now would leak
        // it: its transport is closed, so no disconnect callback will ever clear the entry.
        guard clients.removeValue(forKey: cid) != nil || unannouncedClients.removeValue(forKey: cid) != nil else { return }
        waitingToDisconnect[cid] = client
        if authenticationProvider === client
        {
            // Condemned means no longer trusted with anything, least of all everyone's credentials.
            authenticationProvider = nil
        }
        await web.assets.publishers.revoke(client.assetToken)
        client.stopMoving()
        // Media stops both ways now, not when the session closes: streams it publishes lose their
        // airtime to the room, and forwarders it receives stop rather than waiting out the
        // heartbeat that removes its listener components.
        for stream in client.session.incomingStreams.values
        {
            sfu.handle(lost: stream, from: client)
        }
        sfu.drop(target: cid)
        await removeEntites(ownedBy: cid)

        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.fatalDisconnectGrace ?? 0)) }
            catch { return } // Cancelled is not expired: dropping the client early isn't ours to do.
            guard let self, let squatter = self.waitingToDisconnect.removeValue(forKey: cid) else { return }
            // Removed here, not by the disconnect callback: a transport that died in the
            // meantime delivers no callback, and the entry would squat in the roster forever.
            squatter.logger.warning("Client didn't act on a fatal error, dropping it")
            squatter.session.disconnect()
        }
    }

    func handle(forwardingOfInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
        let ilogger = client.logger.forInteraction(inter)
        // Go look for the recipient entity, and map it to recipient client.
        guard let receivingEntity = place.current.entities[inter.receiverEntityId],
              let recipient = clients[receivingEntity.ownerClientId] else
        {
            throw AlloverseError(
                domain: PlaceErrorCode.domain,
                code: PlaceErrorCode.recipientUnavailable.rawValue,
                description: "No such recipient for entity \(inter.receiverEntityId)"
            )
        }
        
        // If it's a request, save it so we can keep track of mapping the response so the correct client responds.
        // And if it's a response, map it back and check that it's the right one.
        let correctRecipient = outstandingClientToClientInteractions[inter.requestId]
        if inter.type == .request
        {
            outstandingClientToClientInteractions[inter.requestId] = client.session.clientId!
        }
        else if(inter.type == .response)
        {
            guard let correctRecipient else
            {
                throw AlloverseError(
                    domain: PlaceErrorCode.domain,
                    code: PlaceErrorCode.invalidResponse.rawValue,
                    description: "No such request \(inter.requestId) for your response, maybe it timed out before you replied, or you repliced twice?"
                )
            }
            guard receivingEntity.ownerClientId == correctRecipient else
            {
                throw AlloverseError(
                    domain: PlaceErrorCode.domain,
                    code: PlaceErrorCode.invalidResponse.rawValue,
                    description: "That's not your request to respond to."
                )
            }
            
            // We're now sending our response, so clear it out of the outstandings
            outstandingClientToClientInteractions[inter.requestId] = nil
        }
        
        // All checks passed! Send it off!
        recipient.session.send(interaction: inter)
        
        // Now check for timeout, so the requester at _least_ gets a timeout answer if nothing else.
        if inter.type == .request
        {
            try? await Task.sleep(for: .seconds(PlaceServer.InteractionTimeout))
            
            if outstandingClientToClientInteractions[inter.requestId] != nil
            {
                ilogger.error("Request \(inter.requestId) timed out")
                outstandingClientToClientInteractions[inter.requestId] = nil
                throw AlloverseError(
                    domain: PlaceErrorCode.domain,
                    code: PlaceErrorCode.recipientTimedOut.rawValue,
                    description: "Recipient didn't respond in time."
                )
            }
        }
    }
}
