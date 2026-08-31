import Testing
import simd
import Foundation
import Logging
@testable import allonet2

/// The renderer-independent half of spatial audio: which pose a voice sounds from, and whether
/// anything stands in the way. No engine, no scene, just the place.
@MainActor
struct SpatialAudioTests
{
    // MARK: - Segment against one shape, in the shape's own space

    private var unitBox: Collision.Shape { .box(size: [2, 2, 2]) }

    @Test func aSegmentThroughTheBoxHits()
    {
        #expect(unitBox.intersects(segmentFrom: [0, 0, 3], to: [0, 0, -3]))
    }

    @Test func aSegmentPassingBesideTheBoxMisses()
    {
        // Parallel to the box on x, three metres out from a one-metre half extent.
        #expect(!unitBox.intersects(segmentFrom: [3, 0, 3], to: [3, 0, -3]))
    }

    @Test func aBoxBehindTheSegmentMisses()
    {
        // The infinite ray would hit it; the segment stops short, and sound only travels between
        // the two ends.
        #expect(!unitBox.intersects(segmentFrom: [0, 0, 3], to: [0, 0, 2]))
    }

    @Test func anEndpointInsideTheBoxHits()
    {
        #expect(unitBox.intersects(segmentFrom: [0, 0, 0], to: [0, 0, 10]))
    }

    @Test func aNonFiniteBoxBlocksNothing()
    {
        // Shapes come off the wire; a NaN half extent slips through every comparison as "no
        // obstruction on this axis", which would silence the whole place.
        let poisoned = Collision.Shape.box(size: [2, .nan, 2])
        #expect(!poisoned.intersects(segmentFrom: [0, 0, 3], to: [0, 0, -3]))
    }

    // MARK: - Segment against the occluders in a place

    @Test func aWallBetweenListenerAndSpeakerOccludes()
    {
        let contents = place([
            "wall": [transform([0, 0, 0]), Collision(shapes: [.box(size: [10, 3, 0.2])]), AudioOccluder()],
        ])
        #expect(AudioOccluders(of: contents).isOccluded(from: [0, 0, 2], to: [0, 0, -2]))
    }

    @Test func aWallToTheSideDoesNotOcclude()
    {
        let contents = place([
            "wall": [transform([20, 0, 0]), Collision(shapes: [.box(size: [10, 3, 0.2])]), AudioOccluder()],
        ])
        #expect(!AudioOccluders(of: contents).isOccluded(from: [0, 0, 2], to: [0, 0, -2]))
    }

    @Test func aRotatedWallOccludesTheVolumeItIsDrawnAs()
    {
        // Thin in z as authored, so it separates two people standing along z. Turned a quarter
        // turn about Y it is thin in x instead, and the same two hear each other.
        let shapes: [Collision.Shape] = [.box(size: [10, 3, 0.2])]
        let facing = place(["wall": [transform([0, 0, 0]), Collision(shapes: shapes), AudioOccluder()]])
        #expect(AudioOccluders(of: facing).isOccluded(from: [3, 0, 2], to: [3, 0, -2]))

        var turned = simd_float4x4.identity
        turned.rotation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        let sideways = place(["wall": [Transform(matrix: turned), Collision(shapes: shapes), AudioOccluder()]])
        #expect(!AudioOccluders(of: sideways).isOccluded(from: [3, 0, 2], to: [3, 0, -2]))
    }

    @Test func anOccluderPosedByItsParentOccludesThere()
    {
        // The wall's own transform puts it at the origin; only the parent says where the room is.
        let contents = place([
            "room": [transform([0, 0, 0])],
            "wall": [transform([0, 0, 0]), Relationships(parent: "room"),
                     Collision(shapes: [.box(size: [10, 3, 0.2])]), AudioOccluder()],
        ])
        #expect(AudioOccluders(of: contents).isOccluded(from: [0, 0, 2], to: [0, 0, -2]))

        let moved = place([
            "room": [transform([0, 0, 50])],
            "wall": [transform([0, 0, 0]), Relationships(parent: "room"),
                     Collision(shapes: [.box(size: [10, 3, 0.2])]), AudioOccluder()],
        ])
        #expect(!AudioOccluders(of: moved).isOccluded(from: [0, 0, 2], to: [0, 0, -2]))
    }

    @Test func aSourceStandingOnAnOccludingFloorIsHeard()
    {
        // A floor 0.2 m thick with its top face at y = 0, and a source resting exactly on it. The
        // segment terminates on the box, which is contact, not obstruction.
        let contents = place([
            "floor": [transform([0, -0.1, 0]), Collision(shapes: [.box(size: [10, 0.2, 10])]), AudioOccluder()],
        ])
        #expect(!AudioOccluders(of: contents).isOccluded(from: [0, 1.7, 3], to: [0, 0, 0]))
    }

    @Test func twoSourcesStandingOnTheSameOccludingFloorHearEachOther()
    {
        // Both endpoints on the top face, so the segment runs along it for its whole length -
        // parallel to the slab and exactly on its boundary, which is the worse half of the bug.
        let contents = place([
            "floor": [transform([0, -0.1, 0]), Collision(shapes: [.box(size: [10, 0.2, 10])]), AudioOccluder()],
        ])
        #expect(!AudioOccluders(of: contents).isOccluded(from: [2, 0, 0], to: [-2, 0, 0]))
    }

    /// Pins current behaviour rather than asserting it is right: a listener and a source inside the
    /// same occluder are silenced from each other, so modelling a room as one box would deafen
    /// everyone standing in it. Walls and floors are the intended shape.
    @Test func aSegmentEntirelyInsideAnOccluderCountsAsBlocked()
    {
        #expect(unitBox.intersects(segmentFrom: [-0.5, 0, 0], to: [0.5, 0, 0]))
    }

    @Test func collisionWithoutTheMarkerOccludesNothing()
    {
        // Collision is also the tap area: a button between two people must not silence them.
        let contents = place([
            "button": [transform([0, 0, 0]), Collision(shapes: [.box(size: [10, 3, 0.2])])],
        ])
        #expect(!AudioOccluders(of: contents).isOccluded(from: [0, 0, 2], to: [0, 0, -2]))
    }

    @Test func theMarkerWithoutCollisionOccludesNothing()
    {
        let contents = place([
            "ghost": [transform([0, 0, 0]), AudioOccluder()],
        ])
        #expect(!AudioOccluders(of: contents).isOccluded(from: [0, 0, 2], to: [0, 0, -2]))
    }

    // MARK: - Where the listener and the sources are

    @Test func aHeadPosesAtItsComposedPlaceTransform() throws
    {
        // The listener is a head parented to an avatar: only the composition is in place metres.
        let contents = place([
            "avatar": [transform([3, 0, -4])],
            "head": [transform([0, 1.6, 0]), Relationships(parent: "avatar")],
        ])
        let head = try #require(contents.transformToWorld(of: "head"))
        #expect(simd_distance(head.translation, [3, 1.6, -4]) < 1e-5)
    }

    @Test func anEntityWithoutATransformHasNoPose()
    {
        // Nil rather than the parent's origin: a source with no pose keeps the one it had, instead
        // of jumping into the listener's ear.
        let contents = place([
            "avatar": [transform([3, 0, -4])],
            "head": [Relationships(parent: "avatar")],
        ])
        #expect(contents.transformToWorld(of: "head") == nil)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func aNonFiniteAncestorTransformHasNoPose(_ poison: Float)
    {
        // A peer can put anything in a Transform, and one NaN composes into everything below it.
        var poisoned = simd_float4x4.identity
        poisoned.columns.3.x = poison
        let contents = place([
            "avatar": [Transform(matrix: poisoned)],
            "head": [transform([0, 1.6, 0]), Relationships(parent: "avatar")],
        ])
        #expect(contents.transformToWorld(of: "head") == nil)
        #expect(contents.transformToWorld(of: "avatar") == nil)
    }

    @Test func aNonFiniteOccluderIsLeftOut()
    {
        var poisoned = simd_float4x4.identity
        poisoned.columns.3.z = .nan
        let contents = place([
            "wall": [Transform(matrix: poisoned), Collision(shapes: [.box(size: [10, 3, 0.2])]), AudioOccluder()],
        ])
        #expect(!AudioOccluders(of: contents).isOccluded(from: [0, 0, 2], to: [0, 0, -2]))
    }

    // MARK: - Fixtures

    private func transform(_ translation: SIMD3<Float>) -> Transform
    {
        var matrix = simd_float4x4.identity
        matrix.translation = translation
        return Transform(matrix: matrix)
    }

    private func place(_ entities: [EntityID: [any Component]]) -> PlaceContents
    {
        let owner = UUID()
        var datas: [EntityID: EntityData] = [:]
        var lists: [ComponentTypeID: [EntityID: AnyComponent]] = [:]
        for (eid, components) in entities
        {
            datas[eid] = EntityData(id: eid, ownerClientId: owner)
            for component in components
            {
                lists[type(of: component).componentTypeId, default: [:]][eid] = AnyComponent(component)
            }
        }
        return PlaceContents(revision: 1, entities: datas,
                             components: ComponentLists(lists: lists),
                             logger: Logger(label: "spatialaudiotests"))
    }
}
