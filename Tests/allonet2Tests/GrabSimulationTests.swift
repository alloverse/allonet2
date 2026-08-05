import Testing
import simd
import Foundation
import Logging
@testable import allonet2

@MainActor
struct GrabSimulationTests
{
    private func grab(of entity: EntityID = "sign", by grabber: EntityID = "avatar",
                      offset: simd_float4x4 = .identity) -> GrabIntent
    {
        GrabIntent(entity: entity, grabber: grabber, grabberFromEntity: offset)
    }

    private func translation(_ t: SIMD3<Float>) -> simd_float4x4
    {
        var m = simd_float4x4.identity
        m.translation = t
        return m
    }

    @Test func followsTheGrabberInParentSpace() throws
    {
        // Grabber at world (11,0,0), parent at (10,0,0): the entity lands at local (1,0,0).
        let moved = try #require(GrabSimulation.step(
            grab: grab(), grabbable: Grabbable(), base: Transform(),
            grabberToWorld: translation([11, 0, 0]), parentToWorld: translation([10, 0, 0])))
        #expect(simd_distance(moved.matrix.translation, [1, 0, 0]) < 1e-5)
    }

    @Test func constraintPinsAnAxisToTheGrabStart() throws
    {
        // A wall sign: [1,1,0] keeps the base z no matter where the grabber goes.
        let base = Transform(translation: [0, 1, 5])
        let moved = try #require(GrabSimulation.step(
            grab: grab(), grabbable: Grabbable(translationConstraint: [1, 1, 0], rotationConstraint: [0, 0, 0]),
            base: base, grabberToWorld: translation([2, 3, -4]), parentToWorld: .identity))
        #expect(simd_distance(moved.matrix.translation, [2, 3, 5]) < 1e-5)
    }

    @Test func fractionMeasuresFromTheBaseNotTheLastTick() throws
    {
        // 0.5 of a 2m move is 1m - and stays 1m on repeated identical steps.
        let grabbable = Grabbable(translationConstraint: [0.5, 0.5, 0.5])
        let base = Transform()
        for _ in 0..<3
        {
            let moved = try #require(GrabSimulation.step(
                grab: grab(), grabbable: grabbable, base: base,
                grabberToWorld: translation([2, 0, 0]), parentToWorld: .identity))
            #expect(simd_distance(moved.matrix.translation, [1, 0, 0]) < 1e-5)
        }
    }

    @Test func rotationConstraintZeroKeepsTheBaseRotation() throws
    {
        let base = Transform(rotation: simd_quatf(angle: .pi / 4, axis: [0, 1, 0]))
        var grabberToWorld = simd_float4x4.identity
        grabberToWorld.rotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let moved = try #require(GrabSimulation.step(
            grab: grab(), grabbable: Grabbable(rotationConstraint: [0, 0, 0]), base: base,
            grabberToWorld: grabberToWorld, parentToWorld: .identity))
        let dot = abs(simd_dot(moved.matrix.rotation, base.matrix.rotation))
        #expect(dot > 0.9999, "rotation must stay at the grab-start value")
    }

    @Test func nonFiniteClientInputMovesNothing()
    {
        // Intent matrices are untrusted; NaN must not reach the world state.
        var poisoned = simd_float4x4.identity
        poisoned.columns.3.x = .nan
        let moved = GrabSimulation.step(
            grab: grab(offset: poisoned), grabbable: Grabbable(), base: Transform(),
            grabberToWorld: .identity, parentToWorld: .identity)
        #expect(moved == nil)
    }

    @Test func eulerRoundTripsThroughQuaternion()
    {
        let q = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>([0.2, 1, 0.4])))
        let back = simd_quatf(eulerAngles: q.eulerAngles)
        #expect(abs(simd_dot(q, back)) > 0.9999)
    }

    @Test func actuatedAncestorFollowsTheHandleAtItsOffset() throws
    {
        // A handle at local (0,0,-1) on a widget at (5,0,0): grabbing must not move the
        // widget until the grabber does, and then by the grabber's displacement.
        let handleOffset = translation([0, 0, -1])
        let base = Transform(translation: [5, 0, 0])
        let grabberFromEntity = translation([5, 0, -1]) // handle's world pose, grabber at identity
        let still = try #require(GrabSimulation.step(
            grab: grab(offset: grabberFromEntity), grabbable: Grabbable(actuateOn: .parent), base: base,
            grabberToWorld: .identity, parentToWorld: .identity, actuatedFromEntity: handleOffset))
        #expect(simd_distance(still.matrix.translation, [5, 0, 0]) < 1e-5)
        let carried = try #require(GrabSimulation.step(
            grab: grab(offset: grabberFromEntity), grabbable: Grabbable(actuateOn: .parent), base: base,
            grabberToWorld: translation([1, 0, 0]), parentToWorld: .identity, actuatedFromEntity: handleOffset))
        #expect(simd_distance(carried.matrix.translation, [6, 0, 0]) < 1e-5)
    }

    @Test func clientSuppliedScaleIsDiscarded() throws
    {
        // The offset matrix is untrusted; only the base's scale may survive.
        var scaled = translation([1, 0, 0])
        scaled.columns.0.x = 3; scaled.columns.1.y = 3; scaled.columns.2.z = 3
        let moved = try #require(GrabSimulation.step(
            grab: grab(offset: scaled), grabbable: Grabbable(), base: Transform(),
            grabberToWorld: .identity, parentToWorld: .identity))
        #expect(simd_distance(moved.matrix.scale, [1, 1, 1]) < 1e-4)
        #expect(simd_distance(moved.matrix.translation, [1, 0, 0]) < 1e-5)
    }

    @Test func translationConstraintActsInTheGrabStartLocalFrame() throws
    {
        // Entity yawed 90°: its local x is world -z. [1,0,0] must follow world -z and pin world x.
        let base = Transform(rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let grabbable = Grabbable(translationConstraint: [1, 0, 0], rotationConstraint: [0, 0, 0])
        let pinned = try #require(GrabSimulation.step(
            grab: grab(offset: base.matrix), grabbable: grabbable, base: base,
            grabberToWorld: translation([1, 0, 0]), parentToWorld: .identity))
        #expect(simd_distance(pinned.matrix.translation, [0, 0, 0]) < 1e-5)
        let slid = try #require(GrabSimulation.step(
            grab: grab(offset: base.matrix), grabbable: grabbable, base: base,
            grabberToWorld: translation([0, 0, -1]), parentToWorld: .identity))
        #expect(simd_distance(slid.matrix.translation, [0, 0, -1]) < 1e-5)
    }

    @Test func transformToWorldComposesAncestorsAndHonorsOverrides() throws
    {
        let c = contents(parents: ["hand": "avatar"],
                         transforms: ["hand": Transform(translation: [0, 0, -1]), "avatar": Transform(translation: [10, 0, 0])])
        let world = try #require(c.transformToWorld(of: "hand"))
        #expect(simd_distance(world.translation, [10, 0, -1]) < 1e-5)
        let overridden = try #require(c.transformToWorld(of: "hand", overrides: ["avatar": Transform(translation: [20, 0, 0])]))
        #expect(simd_distance(overridden.translation, [20, 0, -1]) < 1e-5)
    }

    @Test func transformToWorldRejectsCyclesAndMissingTransforms()
    {
        // Relationships are client-writable: a cycle must not hang the server, and a
        // Transform-less node must not silently pose at its parent's origin.
        let cyclic = contents(parents: ["a": "b", "b": "a"],
                              transforms: ["a": Transform(), "b": Transform()])
        #expect(cyclic.transformToWorld(of: "a") == nil)
        let bare = contents(parents: ["hand": "avatar"], transforms: ["hand": Transform()])
        #expect(bare.transformToWorld(of: "hand") == nil)
    }

    private func contents(parents: [EntityID: EntityID], transforms: [EntityID: Transform]) -> PlaceContents
    {
        Allonet.Initialize()
        let eids = Set(parents.keys).union(parents.values).union(transforms.keys)
        let entities = Dictionary(uniqueKeysWithValues: eids.map { ($0, EntityData(id: $0, ownerClientId: UUID())) })
        let lists: [ComponentTypeID: [EntityID: AnyComponent]] = [
            Transform.componentTypeId: transforms.mapValues { AnyComponent($0) },
            Relationships.componentTypeId: parents.mapValues { AnyComponent(Relationships(parent: $0)) },
        ]
        return PlaceContents(revision: 0, entities: entities, components: ComponentLists(lists: lists), logger: Logger(label: "test"))
    }

    @Test func degenerateClientInputStaysRigidOrMovesNothing()
    {
        // An all-zero matrix is finite but not a pose. Whatever the sim makes of it
        // must still be finite and unscaled — or nothing must move.
        let moved = GrabSimulation.step(
            grab: grab(offset: simd_float4x4()), grabbable: Grabbable(), base: Transform(),
            grabberToWorld: .identity, parentToWorld: .identity)
        if let moved
        {
            #expect(moved.matrix.isFinite)
            #expect(simd_distance(moved.matrix.scale, [1, 1, 1]) < 1e-4)
        }
    }
}
