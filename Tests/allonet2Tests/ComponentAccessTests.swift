import Testing
import Foundation
@testable import allonet2

/// `components[T.self, of: eid]` answers exactly what `components[T.self][eid]` does, without
/// decoding every component of the type to get there.
@MainActor
@Suite struct ComponentAccessTests
{
    private func contents(_ changes: [PlaceChange]) throws -> PlaceContents
    {
        Transform.register()
        Relationships.register()
        let empty = PlaceContents(logger: testLogger)
        return try #require(empty.applyChangeSet(PlaceChangeSet(changes: changes, fromRevision: 0, toRevision: 1)))
    }

    @Test func matchesTheListSubscript() throws
    {
        let owner = UUID()
        let a = EntityData(id: "a", ownerClientId: owner)
        let b = EntityData(id: "b", ownerClientId: owner)
        let world = try contents([
            .entityAdded(a), .entityAdded(b),
            .componentAdded(a.id, AnyComponent(Transform(translation: [1, 2, 3]))),
            .componentAdded(b.id, AnyComponent(Relationships(parent: a.id))),
        ])

        #expect(world.components[Transform.self, of: a.id] == world.components[Transform.self][a.id])
        #expect(world.components[Transform.self, of: a.id]?.matrix.translation == [1, 2, 3])
        #expect(world.components[Relationships.self, of: b.id]?.parent == a.id)
        #expect(world.components[Transform.self, of: b.id] == nil, "b has no Transform")
        #expect(world.components[Relationships.self, of: "nobody"] == nil, "and nobody has anything")
    }

    /// The list subscript reads a type that isn't in the place at all as an empty list; reaching
    /// for one entity's must agree rather than trap.
    @Test func anAbsentComponentTypeIsNil() throws
    {
        let world = try contents([.entityAdded(EntityData(id: "a", ownerClientId: UUID()))])
        #expect(world.components[Transform.self, of: "a"] == nil)
        #expect(world.components[Transform.self].isEmpty)
    }

    /// Nothing in the wire format ties a component's payload to the type id it travels under, so
    /// the check that they agree is what lets everything downstream assume they do.
    @Test func aPayloadThatDoesntMatchItsTypeIdIsNotWellFormed() throws
    {
        Opacity.register()
        Transform.register()
        #expect(AnyComponent(Transform()).isWellFormed)
        #expect(Self.mislabelled(Opacity(opacity: 0.5), as: Transform.self).isWellFormed == false)

        var unknown = AnyComponent(Opacity(opacity: 0.5))
        unknown.componentTypeId = "NotCompiledIntoThisBinary"
        #expect(unknown.isWellFormed, "the place forwards components it can't decode without looking inside them")
    }

    /// Reachable only through a bug, since ingress refuses it — but if one is ever stored, reading
    /// it must not trap, and must not pass for absence in the log either.
    @Test func aMalformedStoredComponentReadsAsAbsent() throws
    {
        let ent = EntityData(id: "a", ownerClientId: UUID())
        let world = try contents([
            .entityAdded(ent),
            .componentAdded(ent.id, Self.mislabelled(Opacity(opacity: 0.5), as: Transform.self)),
        ])
        #expect(world.components[Transform.self, of: ent.id] == nil)
    }

    /// A component carrying one type's payload under another's type id: what a peer can put on the
    /// wire, since `AnyComponent` decodes the id and the payload independently.
    static func mislabelled(_ component: some Component, as type: (some Component).Type) -> AnyComponent
    {
        var comp = AnyComponent(component)
        comp.componentTypeId = type.componentTypeId
        return comp
    }
}
