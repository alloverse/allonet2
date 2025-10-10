//
//  PlaceServer+PlaceInteractions.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-10-10.
//

import Foundation
import Version

extension PlaceServer
{
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
            client.identity = identity
            guard
                let semantic = Version(version),
                Allonet.version().serverIsCompatibleWith(clientVersion: semantic)
            else
            {
                print("Client \(client.cid) has incompatible version (server \(Allonet.version()), client \(version)), disconnecting.")
                client.session.send(interaction: inter.makeResponse(with: .error(
                    domain: AlloverseErrorCode.domain,
                    code: AlloverseErrorCode.incompatibleProtocolVersion.rawValue,
                    description: "Client version \(version) is incompatible with server version \(Allonet.version()). Please update your app."
                )))
                // TODO: Send error as disconnection reason
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
                case .error(let domain, let code, let description):
                    print("Client \(client.cid) failed authentication (\(domain)#\(code)): \(description). Disconnecting.")
                    fallthrough
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
