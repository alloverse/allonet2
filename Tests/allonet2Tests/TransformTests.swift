import Testing
import simd
@testable import allonet2

@MainActor
struct TransformTests
{
    @Test func initRoundTripsTranslationRotationAndNonUniformScale()
    {
        let translation = SIMD3<Float>(1, -2, 3)
        let rotation = simd_quatf(angle: 1.1, axis: simd_normalize([1, 2, 3]))
        let scale = SIMD3<Float>(2, 0.5, 3)
        let transform = Transform(translation: translation, rotation: rotation, scale: scale)

        #expect(simd_distance(transform.translation, translation) < 1e-5)
        #expect(simd_distance(transform.scale, scale) < 1e-5)
        // q and -q are the same rotation.
        #expect(abs(simd_dot(transform.rotation, rotation)) > 1 - 1e-5)

        // Scale applies in the entity's own axes, before rotation.
        let expected = rotation.act(scale * [1, 1, 1]) + translation
        let actual = transform.matrix * SIMD4<Float>(1, 1, 1, 1)
        #expect(simd_distance(SIMD3(actual.x, actual.y, actual.z), expected) < 1e-5)
    }
}
