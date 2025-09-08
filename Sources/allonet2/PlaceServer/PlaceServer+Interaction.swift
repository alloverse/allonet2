//
//  PlaceServer+Interaction.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation
import Version

extension PlaceServer
{
    nonisolated public func session(_ sess: AlloSession, didReceiveInteraction inter: Interaction)
    {
        let cid = sess.clientId!
        //print("Received interaction from \(cid): \(inter)")
        Task { @MainActor in
            let client = (self.clients[cid] ?? self.unannouncedClients[cid])!
            await self.handle(inter, from: client)
        }
    }

    func handle(_ inter: Interaction, from client: ConnectedClient) async
    {
        do throws(AlloverseError)
        {
            let senderEnt = place.current.entities[inter.senderEntityId]
            let isValidAnnounce = inter.body.caseName == "announce" && inter.senderEntityId == ""
            let isValidOtherMessage = (senderEnt != nil) && senderEnt!.ownerClientId == client.cid
            if !(isValidAnnounce || isValidOtherMessage)
            {
                throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.unauthorized.rawValue, description: "You may only send interactions from entities you own")
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
            print("Interaction error for \(client.cid) when handling \(inter): \(e)")
            if inter.type == .request
            {
                client.session.send(interaction: inter.makeResponse(with: e.asBody))
            }
        }
    }
    
    func handle(forwardingOfInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
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
                print("Request \(inter.requestId) timed out")
                outstandingClientToClientInteractions[inter.requestId] = nil
                throw AlloverseError(
                    domain: PlaceErrorCode.domain,
                    code: PlaceErrorCode.recipientTimedOut.rawValue,
                    description: "Recipient didn't respond in time."
                )
            }
        }
    }
    
    func handle(placeInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
        switch inter.body
        {

        case .registerAsAuthenticationProvider:
            // Reasons this is bad:
            // - First wins
            // - Only one provider per place server
            // - No verification that the client is actually allowed to authenticate others
            // - A client could authenticate itself
            if authenticationProvider == nil
            {
                // TODO: Authenticate all currently connected clients to make sure they're allowed by our new provider
                authenticationProvider = client
                client.session.send(interaction: inter.makeResponse(with: .success))
            }
            else
            {
                throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.invalidRequest.rawValue,
                                     description: "Place server already has an authentication provider")
            }

        case .announce(let version, let identity, let avatarDescription):
            guard
                let semantic = Version(version),
                Allonet.version().serverIsCompatibleWith(clientVersion: semantic)
            else {
                print("Client \(client.cid) has incompatible version (server \(Allonet.version()), client \(version)), disconnecting.")
                client.session.disconnect()
                return
            }

            if let authenticationProvider, let authenticationId = authenticationProvider.avatar {

                let request = Interaction(type: .request, senderEntityId: Interaction.PlaceEntity,
                                          receiverEntityId: authenticationId,
                                          body: .authenticationRequest(identity: identity))

                let answer = await authenticationProvider.session.request(interaction: request)

                switch answer.body {
                case .success: break
                case .error(let domain, let code, let description): fallthrough
                default:
                    // Should we forward the error details back to the client?
                    let error: InteractionBody = .error(domain: PlaceErrorCode.domain,
                                                        code: PlaceErrorCode.unauthorized.rawValue,
                                                        description: "Authentication failed")
                    client.session.send(interaction: inter.makeResponse(with: error))
                    // TODO: Send error as disconnection reason
                    client.session.disconnect()
                    return
                }
            }

            client.announced = true
            // Client is now announced, so move it into the main list of clients so it can get world states etc.
            clients[client.cid] = unannouncedClients.removeValue(forKey: client.cid)!
            let ent = await self.createEntity(from: avatarDescription, for: client)
            client.avatar = ent.id
            print("Accepted client \(client.cid) with email \(identity.emailAddress), display name \(identity.displayName), assigned avatar id \(ent.id)")
            await heartbeat.awaitNextSync() // make it exist before we tell client about it
            
            self.start(forwardingTo: client)
            
            client.session.send(interaction: inter.makeResponse(with: .announceResponse(avatarId: ent.id, placeName: name)))
        case .createEntity(let description):
            let ent = await self.createEntity(from: description, for: client)
            print("Spawned entity for \(client.cid) with id \(ent.id)")
            client.session.send(interaction: inter.makeResponse(with: .createEntityResponse(entityId: ent.id)))
        case .removeEntity(let eid, let mode):
            try await self.removeEntity(with: eid, mode: mode, for: client)
            client.session.send(interaction: inter.makeResponse(with: .success))
        case .changeEntity(let entityId, let addOrChange, let remove):
            try await self.changeEntity(eid: entityId, addOrChange: addOrChange, remove: remove, for: client)
            client.session.send(interaction: inter.makeResponse(with: .success))
        default:
            if inter.type == .request {
                throw AlloverseError(domain: PlaceErrorCode.domain, code: PlaceErrorCode.invalidRequest.rawValue, description: "Place server does not support this request")
            }
        }
    }

}
