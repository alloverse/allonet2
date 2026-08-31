//
//  SpatialAudio.swift
//  allonet2
//

import simd

public extension Collision.Shape
{
    /// Whether the straight line from `a` to `b` passes through this shape.
    ///
    /// Both points are in the coordinate space of the entity the shape belongs to - the shape
    /// itself is centred on that entity's origin - so an oriented or scaled shape is tested by
    /// putting the segment through the inverse of the entity's world transform first.
    ///
    /// - Parameter a: one end of the segment, in entity space.
    /// - Parameter b: the other end, same space.
    /// - Returns: true if any point of the segment lies inside the shape, endpoints included.
    ///   Nothing intersects a non-finite segment or size: a NaN passes every comparison below as
    ///   "no obstruction on this axis", and a degenerate occluder transform inverts to exactly
    ///   that. A caller composing the segment itself does not have to pre-check it.
    func intersects(segmentFrom a: SIMD3<Float>, to b: SIMD3<Float>) -> Bool
    {
        switch self
        {
        case .box(let size):
            let half = SIMD3<Float>(abs(size.x), abs(size.y), abs(size.z)) / 2
            guard (0..<3).allSatisfy({ a[$0].isFinite && b[$0].isFinite && half[$0].isFinite })
            else { return false }

            // Slab test: clip the segment's 0...1 parameter range against each pair of faces,
            // and it hits iff anything is left of the range.
            let direction = b - a
            var near: Float = 0, far: Float = 1
            for axis in 0..<3
            {
                guard abs(direction[axis]) > .leastNormalMagnitude else
                {
                    // Parallel to this pair of faces: either between them all along, or never.
                    guard abs(a[axis]) <= half[axis] else { return false }
                    continue
                }
                let inverse = 1 / direction[axis]
                let first = (-half[axis] - a[axis]) * inverse
                let second = (half[axis] - a[axis]) * inverse
                near = max(near, min(first, second))
                far = min(far, max(first, second))
                if near > far { return false }
            }
            return true
        }
    }
}

/// Every `AudioOccluder` in a place, with the geometry an occlusion query needs already composed.
///
/// Build one per place revision and reuse it for every voice. Composing an occluder's place
/// transform walks its whole ancestor chain and inverts a matrix; asking the place directly, once
/// per source, would redo all of that per source as well.
///
/// ```swift
/// let occluders = AudioOccluders(of: client.placeState.current)
/// for source in sources
/// {
///     engine.setOcclusion(occluders.isOccluded(from: ears, to: source.position) ? -100 : 0,
///                         for: source.mediaId)
/// }
/// ```
///
/// A snapshot: it answers for the contents it was built from and does not follow later changes.
@MainActor
public struct AudioOccluders
{
    private struct Occluder
    {
        /// Place space into this occluder's own space, where its shapes are centred on the origin.
        let placeToOccluder: simd_float4x4
        let shapes: [Collision.Shape]
    }
    private let occluders: [Occluder]

    /// Collect the occluders of `contents`. An entity marked `AudioOccluder` with no `Collision`
    /// shapes, or one the place cannot place, has nothing to block with and is left out.
    public init(of contents: PlaceContents)
    {
        // A marker component's presence is the whole payload, so read the ids without decoding.
        let marked = contents.components[AudioOccluder.componentTypeId] ?? [:]
        occluders = marked.keys.compactMap { eid in
            guard let collision = contents.components[Collision.self, of: eid],
                  !collision.shapes.isEmpty,
                  let occluderToPlace = contents.transformToWorld(of: eid)
            else { return nil }
            return Occluder(placeToOccluder: occluderToPlace.inverse, shapes: collision.shapes)
        }
    }

    /// Whether an occluder stands between two points, so a voice at one of them cannot be heard at
    /// the other.
    ///
    /// - Parameter listener: where the ears are, in place space (metres).
    /// - Parameter source: where the voice is, same space.
    public func isOccluded(from listener: SIMD3<Float>, to source: SIMD3<Float>) -> Bool
    {
        occluders.contains { occluder in
            let a = occluder.placeToOccluder * listener, b = occluder.placeToOccluder * source
            return occluder.shapes.contains { $0.intersects(segmentFrom: a, to: b) }
        }
    }
}
