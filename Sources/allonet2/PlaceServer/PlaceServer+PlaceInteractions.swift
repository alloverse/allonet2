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
            // - Only one provider per place server
            // - A client could authenticate itself
            // Being *accepted* as an app is what authorizes this — not `identity`, which carries
            // only what the client said about itself and is set before it is checked.
            guard client.authenticatedAsApp else
            {
                throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "Only an app may be a place's authentication provider")
            }
            // Last writer wins, so a backend that restarted can take the role back from its own
            // dead session. The place can't tell a dead provider from a live one — a killed peer
            // looks connected until ICE gives up — and refusing until then shuts the place to
            // everyone for as long as that takes.
            //
            // What makes handing the role over safe is the app token: only its holder announces
            // as an app at all, and it already grants full management of the place. Without one
            // every client is an app, so anyone could take the gate away from the real backend
            // and see every user's credentials. Then, and only then, first writer wins.
            if let previous = authenticationProvider, previous.cid != client.cid
            {
                guard !alloAppAuthToken.isEmpty else
                {
                    throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Place server already has an authentication provider, and has no app token to tell another one apart from an impostor")
                }
                // Reassign before disconnecting: losing that session must not clear the new provider.
                authenticationProvider = client
                ilogger.warning("Replacing authentication provider \(previous.cid), disconnecting it")
                previous.session.disconnect()
            }
            authenticationProvider = client
            requiresAuthenticationProvider = true
            client.session.send(interaction: inter.makeResponse(with: .success))

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

        // Announcing twice used to force-unwrap its way out of unannouncedClients and take the
        // whole place down with it — a crash any client could ask for. It's a malformed request,
        // not a place bug.
        guard !client.announced, unannouncedClients[client.cid] != nil else
        {
            throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Already announced")
        }
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
        // Apps always go through authenticate(), even on a place with no token to check them
        // against (where it passes them): it is the only place that decides an app is an app, and
        // whatever it decides is what app privileges are granted on later.
        if requiresAuthenticationProvider || identity.expectation == .app
        {
            try await authenticate(identity: identity, from: client, in: ilogger)
        }

        // Authenticating suspends, and the client can leave during it — condemned for an
        // unauthorized request it pipelined behind this announce, or plain disconnected. Its slot
        // in unannouncedClients is gone then, and admitting it would trap on the unwrap below.
        guard !client.announced, unannouncedClients[client.cid] != nil else
        {
            throw AlloverseError(code: PlaceErrorCode.invalidRequest, description: "Client is no longer eligible to announce")
        }

        client.announced = true
        // Client is now announced, so move it into the main list of clients so it can get world states etc.
        clients[client.cid] = unannouncedClients.removeValue(forKey: client.cid)!

        // Admitted here, while the client is reachable in `clients`, and not after the awaits below:
        // a client that drops during them is revoked by the disconnect path, and admitting after
        // that has run would leave a token behind that nothing ever takes away.
        await web.assets.publishers.admit(client.assetToken)

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
            await appendChanges([.componentUpdated(avatar.id, AnyComponent(newUserTform))])
        }
        
        // Finished announcing!
        ilogger.info("Accepted client with email \(identity.emailAddress), display name \(identity.displayName), assigned avatar id \(avatar.id)")
        await heartbeat.awaitNextSync() // make it exist before we tell client about it
        
        client.session.send(interaction: announce.makeResponse(with: .announceResponse(
            avatarId: avatar.id,
            placeName: name,
            assetToken: client.assetToken
        )))
    }
    
    func authenticate(identity: Identity, from client: ConnectedClient, in ilogger: Logger) async throws(AlloverseError)
    {
        let cid = client.cid
        if identity.expectation == .app
        {
            if alloAppAuthToken.isEmpty || identity.authenticationToken == alloAppAuthToken {
                ilogger.info("Successfully authenticated app using shared secret.")
                client.authenticatedAsApp = true
                return
            } else {
                throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "Authentication failed", overrideIsFatal: true)
            }
        }

        // Deliberately not fatal: a place whose provider is restarting is closed for a few seconds,
        // not permanently, and a visor that gives up here needs a human to reconnect it.
        guard let authenticationProvider, let authenticationId = authenticationProvider.avatar else {
            throw AlloverseError(code: AlloverseErrorCode.internalServerError, description: "Couldn't reach authentication server")
        }

        let request = Interaction(type: .request, senderEntityId: Interaction.PlaceEntity,
                                  receiverEntityId: authenticationId,
                                  body: .authenticationRequest(clientId: cid, identity: identity))

        // Bounded like every other interaction the place forwards. A provider that is connected but
        // not answering — or one whose session died just before we asked, so no disconnect will
        // arrive to fail this for us — would otherwise leave the visor awaiting an announce
        // response for as long as its own connection lasts.
        guard let answer = await authenticationProvider.session.request(interaction: request,
                                                                        timeout: Self.InteractionTimeout)
        else {
            ilogger.error("Authentication provider didn't answer within \(Self.InteractionTimeout)s.")
            throw AlloverseError(code: PlaceErrorCode.recipientTimedOut,
                                 description: "Authentication server didn't answer in time")
        }

        // The role can change hands during that await — the provider was condemned, or a restarted
        // backend took the role back — and responses complete their continuation directly, before
        // any roster check. An answer from a provider the place no longer trusts must not admit
        // anyone. Non-fatal, because the successor may be seconds away.
        guard self.authenticationProvider === authenticationProvider else {
            ilogger.error("Authentication provider lost the role while answering; discarding its answer.")
            throw AlloverseError(code: AlloverseErrorCode.internalServerError,
                                 description: "Authentication provider changed; try again")
        }

        switch answer.body {
        case .success: break
        case .error(let domain, let code, let description, _):
            ilogger.error("Failed authentication (\(domain)#\(code)): \(description). Disconnecting.")
            throw AlloverseError(with: answer.body, overrideIsFatal: true)
        default:
            throw AlloverseError(code: PlaceErrorCode.unauthorized, description: "Authentication failed", overrideIsFatal: true)
        }
    }
}
