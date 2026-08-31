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
    ///   A non-finite point or size intersects nothing: shapes come off the wire, and a NaN
    ///   slips through comparisons as "no obstruction on this axis".
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

public extension PlaceContents
{
    /// Whether an `AudioOccluder` stands between two points, so a voice at one of them cannot be
    /// heard at the other.
    ///
    /// Each occluder's `Collision` shapes are tested in that entity's own space, so a rotated or
    /// scaled wall blocks the volume it is drawn as. An occluder with no `Collision`, or one the
    /// place cannot place - a `Transform` missing on it or an ancestor - has no shape to block
    /// with and is skipped.
    ///
    /// - Parameter listener: where the ears are, in place space (metres).
    /// - Parameter source: where the voice is, same space.
    func isAudioOccluded(from listener: SIMD3<Float>, to source: SIMD3<Float>) -> Bool
    {
        // A marker component's presence is the whole payload, so read the ids without decoding.
        let occluders = components[AudioOccluder.componentTypeId] ?? [:]
        for eid in occluders.keys
        {
            guard let collision = components[Collision.self, of: eid],
                  let occluderToPlace = transformToWorld(of: eid)
            else { continue }
            let placeToOccluder = occluderToPlace.inverse
            let a = placeToOccluder * listener, b = placeToOccluder * source
            if collision.shapes.contains(where: { $0.intersects(segmentFrom: a, to: b) }) { return true }
        }
        return false
    }
}
