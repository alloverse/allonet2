import Testing
import Foundation
import PotentCBOR
@testable import allonet2

/// What each client is told every beat: one diff per distinct acked revision, and a client that
/// has fallen behind still gets a changeset that catches it all the way up.
@MainActor
@Suite struct StateBroadcastTests
{
    private func makeServer() -> PlaceServer
    {
        PlaceServer(name: "Test Place",
                    options: TransportConnectionOptions(routing: .direct),
                    alloAppAuthToken: "apptoken", requiresAuthentication: false)
    }

    private func makeClient(on server: PlaceServer, app: Bool = false) async throws -> ConnectedClient
    {
        let status = ConnectionStatus()
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: status)
        let client = ConnectedClient(session: AlloSession(side: .server, transport: transport), status: status)
        client.identity = Identity(expectation: app ? .app : .existingUser, displayName: "C",
                                   emailAddress: "", authenticationToken: "apptoken")
        transport.clientId = client.cid
        if app { try await server.authenticate(identity: client.identity!, from: client, in: client.logger) }
        client.announced = true
        server.clients[client.cid] = client
        return client
    }

    /// The changesets this client was actually sent, decoded off the wire.
    private func received(by client: ConnectedClient) throws -> [PlaceChangeSet]
    {
        let transport = client.session.transport as! MockTransport
        return try transport.sentMessages
            .filter { $0.channel == .intentWorldState }
            .map { try CBORDecoder().decode(PlaceChangeSet.self, from: $0.data) }
    }

    @Test func clientsAtTheSameRevisionGetTheSameChangeset() async throws
    {
        let server = makeServer()
        let app = try await makeClient(on: server, app: true)
        let a = try await makeClient(on: server)
        let b = try await makeClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: app)
        await server.heartbeat.awaitNextSync()

        for client in [app, a, b] { client.ackdRevision = server.place.current.revision }
        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.75))], remove: [], for: app)
        await server.heartbeat.awaitNextSync()

        let last = try [a, b].map { try #require(received(by: $0).last) }
        #expect(last[0] == last[1], "one diff, shared by every client that acked the same revision")
        #expect(last[0].changes == [.componentUpdated(ent.id, AnyComponent(Opacity(opacity: 0.75)))])
    }

    /// The memo is keyed on the acked revision, so a laggard must not be handed the changeset
    /// computed for the clients that are in step.
    @Test func aLaggardIsCaughtUpFromItsOwnRevision() async throws
    {
        let server = makeServer()
        let app = try await makeClient(on: server, app: true)
        let uptodate = try await makeClient(on: server)
        let laggard = try await makeClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: app)
        await server.heartbeat.awaitNextSync()

        let behind = server.place.current.revision
        for client in [app, uptodate, laggard] { client.ackdRevision = behind }

        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Billboard(blendFactor: 0.25))], remove: [], for: app)
        await server.heartbeat.awaitNextSync()
        // Only one of them acks the beat it just got; the other stays where it was.
        uptodate.ackdRevision = server.place.current.revision

        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.75))], remove: [], for: app)
        await server.heartbeat.awaitNextSync()

        let fresh = try #require(received(by: uptodate).last)
        let stale = try #require(received(by: laggard).last)
        #expect(fresh.fromRevision == server.place.current.revision - 1)
        #expect(fresh.changes == [.componentUpdated(ent.id, AnyComponent(Opacity(opacity: 0.75)))])
        #expect(stale.fromRevision == behind, "the laggard is caught up from where it actually is")
        #expect(stale.changes.count == 2, "both revisions it missed, in one changeset")
    }

    /// A removal and a re-add are the cases the shared diff could get wrong for one client and
    /// not another, so pin that every client's changeset applies cleanly onto what it acked.
    @Test func everyClientsChangesetAppliesOntoWhatItAcked() async throws
    {
        let server = makeServer()
        let app = try await makeClient(on: server, app: true)
        let a = try await makeClient(on: server)
        let b = try await makeClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: app)
        await server.heartbeat.awaitNextSync()
        for client in [app, a, b] { client.ackdRevision = server.place.current.revision }

        // b keeps acking; a is left one beat behind throughout.
        for step in 0..<4
        {
            switch step
            {
            case 0: try await server.changeEntity(eid: ent.id, addOrChange: [], remove: [Opacity.componentTypeId], for: app)
            case 1: try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.25))], remove: [], for: app)
            case 2: _ = try await server.createEntity(from: EntityDescription(components: [Billboard(blendFactor: 1)]), for: app)
            default: try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.9))], remove: [], for: app)
            }
            await server.heartbeat.awaitNextSync()
            b.ackdRevision = server.place.current.revision
            app.ackdRevision = server.place.current.revision
        }

        for client in [a, b]
        {
            // Through a real PlaceState, which keeps the history a changeset from an older
            // revision is applied onto - that is the whole repair path for a client that lags.
            let mirror = PlaceState(logger: testLogger)
            for changeSet in try received(by: client)
            {
                #expect(mirror.applyChangeSet(changeSet),
                        "changeset \(changeSet.fromRevision)->\(changeSet.toRevision) didn't apply")
            }
            #expect(mirror.current.changeSet(from: server.place.current).changes.isEmpty,
                    "every client converges on the place as it is")
        }
    }
}
