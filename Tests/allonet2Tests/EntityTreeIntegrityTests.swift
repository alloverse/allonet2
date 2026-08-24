import Testing
import Foundation
@testable import allonet2

/// The place must never hold a tree with a child parented to an entity that isn't there: a
/// receiving client force-unwraps the parent, so a dangling reference crashes every visor.
/// removeEntity honours its mode, and a parent that doesn't resolve is refused at the door.
@MainActor
@Suite struct EntityTreeIntegrityTests
{
    private func makeServer() -> PlaceServer
    {
        PlaceServer(name: "Test Place", transportClass: MockTransport.self,
                    options: TransportConnectionOptions(routing: .direct),
                    alloAppAuthToken: "apptoken", requiresAuthentication: true)
    }

    private func makeAppClient(on server: PlaceServer) async -> ConnectedClient
    {
        let status = ConnectionStatus()
        let transport = MockTransport(with: TransportConnectionOptions(routing: .direct), status: status)
        let client = ConnectedClient(session: AlloSession(side: .server, transport: transport), status: status)
        client.identity = Identity(expectation: .app, displayName: "App", emailAddress: "", authenticationToken: "apptoken")
        transport.clientId = client.cid
        try? await server.authenticate(identity: client.identity!, from: client, in: client.logger)
        return client
    }

    private func child(_ parent: EntityID) -> EntityDescription
    {
        EntityDescription(components: [Relationships(parent: parent)])
    }

    @Test func cascadeRemovesTheWholeSubtree() async throws
    {
        let server = makeServer()
        let client = await makeAppClient(on: server)
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

    @Test func reparentDropsChildrenToRoot() async throws
    {
        let server = makeServer()
        let client = await makeAppClient(on: server)
        let root = try await server.createEntity(from: EntityDescription(), for: client)
        let kid = try await server.createEntity(from: child(root.id), for: client)
        await server.heartbeat.awaitNextSync()

        try await server.removeEntity(with: root.id, mode: .reparent, for: client)
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.entities[root.id] == nil)
        #expect(server.place.current.entities[kid.id] != nil, "reparent keeps the child")
        #expect(server.place.current.components[Relationships.self][kid.id] == nil, "child is reparented to root")
    }

    @Test func creatingUnderAMissingParentIsRefused() async throws
    {
        let server = makeServer()
        let client = await makeAppClient(on: server)
        await #expect(throws: AlloverseError.self) {
            _ = try await server.createEntity(from: self.child(EntityID.random()), for: client)
        }
    }

    @Test func reparentingToAMissingEntityIsRefused() async throws
    {
        let server = makeServer()
        let client = await makeAppClient(on: server)
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
