//
//  PlaceServer+PlaceInteractions.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-10-10.
//

import Foundation
import Version
import Logging

extension PlaceServer
{
    func handle(placeInteraction inter: Interaction, from client: ConnectedClient) async throws(AlloverseError)
    {
        let ilogger = client.logger.forInteraction(inter)
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
                authenticationProvider = client
                requiresAuthenticationProvider = true
                client.session.send(interaction: inter.makeResponse(with: .success))
            }
            else
            {
                throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Place server already has an authentication provider")
            }

        case .announce(let version, let identity, let avatarDescription):
            try await handle(announce: inter, from: client, ilogger: ilogger)
        case .createEntity(let description):
            let ent = await self.createEntity(from: description, for: client)
            ilogger.info("Spawned entity with id \(ent.id)")
            client.session.send(interaction: inter.makeResponse(with: .createEntityResponse(entityId: ent.id)))
        case .removeEntity(let eid, let mode):
            try await self.removeEntity(with: eid, mode: mode, for: client)
            client.session.send(interaction: inter.makeResponse(with: .success))
        case .changeEntity(let entityId, let addOrChange, let remove):
            try await self.changeEntity(eid: entityId, addOrChange: addOrChange, remove: remove, for: client)
            client.session.send(interaction: inter.makeResponse(with: .success))
        default:
            if inter.type == .request {
                throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Place server does not support this request")
            }
        }
    }
    
    func handle(announce: Interaction, from client: ConnectedClient, ilogger: Logger) async throws(AlloverseError)
    {
        guard case .announce(let version, let identity, let avatarDescription) = announce.body else { fatalError() }
        client.identity = identity
        
        guard
            let semantic = Version(version),
            Allonet.version().serverIsCompatibleWith(clientVersion: semantic)
        else
        {
            ilogger.error("Incompatible version (server \(Allonet.version()), client \(version)), disconnecting.")
            throw AlloverseError(
                code: AlloverseErrorCode.incompatibleProtocolVersion,
                description: "Please update your app.\n\nClient version \(version) is incompatible with server version \(Allonet.version())."
            )
        }
        if requiresAuthenticationProvider || (identity.expectation == .app && !alloAppAuthToken.isEmpty)
        {
            try await authenticate(identity: identity, in: ilogger)
        }

        client.announced = true
        // Client is now announced, so move it into the main list of clients so it can get world states etc.
        clients[client.cid] = unannouncedClients.removeValue(forKey: client.cid)!
        
        // Time to create the avatar
        let avatar = await self.createEntity(from: avatarDescription, for: client)
        client.avatar = avatar.id
        
        // Find a SpawnPoint if available and move the avatar to it
        if
            let spawnPointEntityId = place.current.components[SpawnPoint.self].keys.randomElement(),
            let spawnPointEntity = placeHelper.entities[spawnPointEntityId]
        {
            let worldTransform = spawnPointEntity.transformToWorld
            var newUserTform = Transform(matrix: worldTransform)
            // Slightly offset each new incoming user so that users never exactly overlap. This fixes the audio bug. Not okay. https://www.notion.so/alloverse/Still-no-audio-when-testing-w-Tobes-2a4383c5f0558020a885fb75df1787b2
            newUserTform.matrix.translation.x += Float.random(in: -0.02...0.02)
            newUserTform.matrix.translation.z += Float.random(in: -0.02...0.02)
            await appendChanges([.componentUpdated(avatar.id, newUserTform)])
        }
        
        // Finished announcing!
        ilogger.info("Accepted client with email \(identity.emailAddress), display name \(identity.displayName), assigned avatar id \(avatar.id)")
        await heartbeat.awaitNextSync() // make it exist before we tell client about it
        
        client.session.send(interaction: announce.makeResponse(with: .announceResponse(avatarId: avatar.id, placeName: name)))
    }
    
    func authenticate(identity: Identity, in ilogger: Logger) async throws(AlloverseError)
    {
        if identity.expectation == .app
        {
            if alloAppAuthToken.isEmpty || identity.authenticationToken == alloAppAuthToken {
                ilogger.info("Successfully authenticated app using shared secret.")
                return
            } else {
                throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "Authentication failed", overrideIsFatal: true)
            }
        }
        
        guard let authenticationProvider, let authenticationId = authenticationProvider.avatar else {
            throw AlloverseError(code: AlloverseErrorCode.internalServerError, description: "Couldn't reach authentication server", overrideIsFatal: true)
        }

        let request = Interaction(type: .request, senderEntityId: Interaction.PlaceEntity,
                                  receiverEntityId: authenticationId,
                                  body: .authenticationRequest(identity: identity))

        let answer = await authenticationProvider.session.request(interaction: request)

        switch answer.body {
        case .success: break
        case .error(let domain, let code, let description):
            ilogger.error("Failed authentication (\(domain)#\(code)): \(description). Disconnecting.")
            throw AlloverseError(with: answer.body, overrideIsFatal: true)
        default:
            throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "Authentication failed", overrideIsFatal: true)
        }
    }
}
