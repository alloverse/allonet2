import Testing
import Foundation
import OpenCombineShim
@testable import allonet2

/// Writing a component the value it already holds is not a change, and commits nothing.
@MainActor
@Suite struct NoOpWriteTests
{
    var cancellables = Set<AnyCancellable>()

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

    @Test func anIdenticalWriteSpendsNoRevision() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: client)
        await server.heartbeat.awaitNextSync()
        let revision = server.place.current.revision

        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.5))], remove: [], for: client)
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.revision == revision, "the value was already there, so nothing was committed")
        #expect(server.place.current.components[Opacity.self][ent.id]?.opacity == 0.5, "and the asked-for state still holds")
    }

    @Test func aMixedWriteCommitsOnlyTheRealChange() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(
            from: EntityDescription(components: [Opacity(opacity: 0.5), Billboard(blendFactor: 1.0)]), for: client)
        await server.heartbeat.awaitNextSync()
        let revision = server.place.current.revision

        try await server.changeEntity(eid: ent.id,
                                      addOrChange: [AnyComponent(Opacity(opacity: 0.5)), AnyComponent(Billboard(blendFactor: 0.25))],
                                      remove: [], for: client)
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.revision == revision + 1, "one beat, one revision")
        #expect(server.place.changeSet?.changes == [.componentUpdated(ent.id, AnyComponent(Billboard(blendFactor: 0.25)))],
                "the identical Opacity is dropped, the changed Billboard is not")
        #expect(server.place.current.components[Billboard.self][ent.id]?.blendFactor == 0.25)
        #expect(server.place.current.components[Opacity.self][ent.id]?.opacity == 0.5)
    }

    @Test mutating func aSuppressedWriteFiresNoObserver() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(
            from: EntityDescription(components: [Opacity(opacity: 0.5), Billboard(blendFactor: 1.0)]), for: client)
        await server.heartbeat.awaitNextSync()

        var opacityUpdates = 0
        var billboardUpdates = 0
        server.place.observers[Opacity.self].updated.sink { _ in opacityUpdates += 1 }.store(in: &cancellables)
        server.place.observers[Billboard.self].updated.sink { _ in billboardUpdates += 1 }.store(in: &cancellables)

        try await server.changeEntity(eid: ent.id,
                                      addOrChange: [AnyComponent(Opacity(opacity: 0.5)), AnyComponent(Billboard(blendFactor: 0.25))],
                                      remove: [], for: client)
        await server.heartbeat.awaitNextSync()

        #expect(opacityUpdates == 0, "a dropped write is not an update; remote clients never saw one either, since their deltas are diffed by value")
        #expect(billboardUpdates == 1)
    }

    /// Only the last write of a type in one request is observable; comparing each write on its own
    /// commits an intermediate value the caller already replaced.
    @Test func theLastWriteOfATypeInOneRequestWins() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: client)
        await server.heartbeat.awaitNextSync()
        let revision = server.place.current.revision

        try await server.changeEntity(eid: ent.id,
                                      addOrChange: [AnyComponent(Opacity(opacity: 0.75)), AnyComponent(Opacity(opacity: 0.5))],
                                      remove: [], for: client)
        await server.heartbeat.awaitNextSync()
        #expect(server.place.current.components[Opacity.self][ent.id]?.opacity == 0.5, "the caller's last word, not the value it overwrote")
        #expect(server.place.current.revision == revision, "which is what was already there, so nothing is committed")

        try await server.changeEntity(eid: ent.id,
                                      addOrChange: [AnyComponent(Opacity(opacity: 0.5)), AnyComponent(Opacity(opacity: 0.75))],
                                      remove: [], for: client)
        await server.heartbeat.awaitNextSync()
        #expect(server.place.current.components[Opacity.self][ent.id]?.opacity == 0.75, "and a real last write still lands")
        #expect(server.place.current.revision == revision + 1)
    }

    /// Two requests inside one coalescing window can walk a value away and back. Each queues a real
    /// change, so the beat is not empty - but its net effect on the place is.
    @Test mutating func aValueRestoredByALaterRequestInTheSameBeatCommitsNothing() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: client)
        await server.heartbeat.awaitNextSync()
        let revision = server.place.current.revision

        var opacityUpdates = 0
        server.place.observers[Opacity.self].updated.sink { _ in opacityUpdates += 1 }.store(in: &cancellables)

        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.75))], remove: [], for: client)
        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.5))], remove: [], for: client)
        try #require(server.outstandingPlaceChanges.count == 2, "both requests must land in one beat, or this tests nothing")
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.revision == revision, "the beat lands where the place already was")
        #expect(server.place.current.components[Opacity.self][ent.id]?.opacity == 0.5)
        #expect(opacityUpdates == 0, "and no observer hears about the value it walked through")
    }

    /// The dangerous shortcut: dropping queued changes that match committed state one by one would
    /// drop the re-add and keep the removal, deleting a component the caller asked to keep.
    @Test func aRemoveAndReAddOfTheSameValueInOneBeatKeepsTheComponent() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: client)
        await server.heartbeat.awaitNextSync()
        let revision = server.place.current.revision

        try await server.changeEntity(eid: ent.id, addOrChange: [], remove: [Opacity.componentTypeId], for: client)
        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.5))], remove: [], for: client)
        try #require(server.outstandingPlaceChanges.count == 2, "both requests must land in one beat, or this tests nothing")
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.components[Opacity.self][ent.id]?.opacity == 0.5, "removed and put back is the state it started in")
        #expect(server.place.current.revision == revision, "which costs nothing to commit")
    }

    /// A write folded in after a removal queued in the same beat projects as an add, which would
    /// store a component under an entity the beat deletes - and answer success.
    @Test func aChangeToAnEntityThisBeatRemovesIsRefused() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: client)
        await server.heartbeat.awaitNextSync()

        try await server.removeEntity(with: ent.id, mode: .cascade, for: client)
        await #expect(throws: AlloverseError.self, "the entity is on its way out this beat") {
            try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.75))],
                                          remove: [], for: client)
        }
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.entities[ent.id] == nil)
        #expect(server.place.current.components[Opacity.self][ent.id] == nil, "no component may outlive its entity")
    }

    /// The beat nets to a plain update of the committed value; the intermediate removal never
    /// reaches the changeset, which could not have applied a write against what it just removed.
    @Test func aRemoveAndReAddWithANewValueLandsTheNewValue() async throws
    {
        let server = makeServer()
        let client = try await makeAppClient(on: server)
        let ent = try await server.createEntity(from: EntityDescription(components: [Opacity(opacity: 0.5)]), for: client)
        await server.heartbeat.awaitNextSync()

        try await server.changeEntity(eid: ent.id, addOrChange: [], remove: [Opacity.componentTypeId], for: client)
        try await server.changeEntity(eid: ent.id, addOrChange: [AnyComponent(Opacity(opacity: 0.75))], remove: [], for: client)
        await server.heartbeat.awaitNextSync()

        #expect(server.place.current.components[Opacity.self][ent.id]?.opacity == 0.75)
    }
}
