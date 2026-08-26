import Testing
import Foundation
@testable import allonet2

/// The place must never hold a tree with a child parented to an entity that isn't there: a
/// receiving client force-unwraps the parent, so a dangling reference crashes every visor.
/// Removal cascades, a parent that won't resolve or would cycle is refused, and any orphan that
/// still reaches a commit is swept before broadcast.
@MainActor
@Suite struct EntityTreeIntegrityTests
{
    private func makeServer() -> PlaceServer
    {
        PlaceServer(name: "Test Place",
                    options: TransportConnectionOptions(routing: .direct),
                    alloAppAuthToken: "apptoken", requiresAuthentication: true)
    }

    private func makeAppClient(on server: PlaceServer) async throws -> ConnectedClient
    {
        let status = ConnectionStatus()
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: status)
        let client = ConnectedClient(session: AlloSession(side: .server, transport: transport), status: status)
        client.identity = Identity(expectation: .app, displayName: "App", emailAddress: "", authenticationToken: "apptoken")
        transport.clientId = client.cid
        try await server.authenticate(identity: client.identity!, from: client, in: client.logger)
        return client
    }

    private func child(_ parent: EntityID) -> EntityDescription
    {
        EntityDescription(components: [Relationships(parent: parent)])
    }

    @Test func cascadeRemovesTheWholeSubtree() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let root = try await server.createEntity(from: EntityDescription(), for: client)
        let mid = try await server.createEntity(from: child(root.id), for: client)
        let leaf = try await server.createEntity(from: child(mid.id), for: client)
        await server.heartbeat.awaitNextSync()

        try await server.removeEntity(with: root.id, mode: .cascade, for: client)
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.entities[root.id] == nil)
        #expect(server.place.current.entities[mid.id] == nil)
        #expect(server.place.current.entities[leaf.id] == nil, "cascade removes transitive descendants")
    }

    @Test func reparentRemovalIsRefused() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let root = try await server.createEntity(from: EntityDescription(), for: client)
        await server.heartbeat.awaitNextSync()
        await #expect(throws: AlloverseError.self, "only cascade is supported") {
            try await server.removeEntity(with: root.id, mode: .reparent, for: client)
        }
    }

    @Test func reparentingBeneathADescendantIsRefused() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let a = try await server.createEntity(from: EntityDescription(), for: client)
        let b = try await server.createEntity(from: child(a.id), for: client)
        await server.heartbeat.awaitNextSync()
        await #expect(throws: AlloverseError.self, "parenting A under its own child B is a cycle") {
            try await server.changeEntity(eid: a.id, addOrChange: [AnyComponent(Relationships(parent: b.id))],
                                          remove: [], for: client)
        }
    }

    @Test func anOrphanReachingCommitIsSweptBeforeBroadcast() async throws
    {
        // A parent removed by a path that doesn't reparent (a bulk owner-cleanup, a race with a
        // still-pending child) would commit a dangling child. The commit-time sweep is the backstop.
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let parent = try await server.createEntity(from: EntityDescription(), for: client)
        let kid = try await server.createEntity(from: child(parent.id), for: client)
        await server.heartbeat.awaitNextSync()
        #expect(server.place.current.entities[kid.id] != nil)

        // Remove only the parent, bypassing removeEntity's cascade/reparent.
        await server.appendChanges([.entityRemoved(server.place.current.entities[parent.id]!)])
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.entities[parent.id] == nil)
        #expect(server.place.current.entities[kid.id] == nil, "an orphaned child never survives a commit")
    }

    @Test func aMutualCycleWithinOneHeartbeatIsRefused() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let a = try await server.createEntity(from: EntityDescription(), for: client)
        let b = try await server.createEntity(from: EntityDescription(), for: client)
        await server.heartbeat.awaitNextSync()
        // Queue A -> B, then B -> A in the same beat: the second must see the first's pending edge.
        try await server.changeEntity(eid: a.id, addOrChange: [AnyComponent(Relationships(parent: b.id))], remove: [], for: client)
        await #expect(throws: AlloverseError.self, "B under A after A under B is a cycle") {
            try await server.changeEntity(eid: b.id, addOrChange: [AnyComponent(Relationships(parent: a.id))], remove: [], for: client)
        }
    }

    @Test func creatingUnderAMissingParentIsRefused() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        await #expect(throws: AlloverseError.self) {
            _ = try await server.createEntity(from: self.child(EntityID.random()), for: client)
        }
    }

    @Test func reparentingToAMissingEntityIsRefused() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let e = try await server.createEntity(from: EntityDescription(), for: client)
        await server.heartbeat.awaitNextSync()
        await #expect(throws: AlloverseError.self) {
            try await server.changeEntity(eid: e.id, addOrChange: [AnyComponent(Relationships(parent: EntityID.random()))],
                                          remove: [], for: client)
        }
        await #expect(throws: AlloverseError.self, "an entity can't be its own parent") {
            try await server.changeEntity(eid: e.id, addOrChange: [AnyComponent(Relationships(parent: e.id))],
                                          remove: [], for: client)
        }
    }
}
