import Testing
import Foundation
import RealityKit
@testable import AlloReality

/// `Model.mesh == .asset` turns a cached file into an entity's visual. The interesting part is the
/// dispatch on the file's extension and what happens to files that aren't loadable — the bytes come
/// from a peer, and only the hash is checked before we hand them to a parser.
@MainActor
struct AssetVisualTests
{
    /// The shape `AlloClient.assetURL` hands us: content-addressed name, media-type extension.
    private func cached(_ bytes: Data, as ext: String) throws -> URL
    {
        let hex = String(repeating: "ab", count: 32)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(hex)-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url)
        return url
    }

    @Test func aGlbBecomesADrawableEntity() async throws
    {
        let url = try cached(TinyGLB.triangle, as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        let visual = try await RealityViewMapper.visual(ofAssetAt: url)
        #expect(visual.meshBearingDescendants > 0)
    }

    /// The extension is derived from a media type the publisher chose, so it can name anything.
    /// That has to surface as a typed error the caller can log — not a trap.
    @Test func anUnknownExtensionFails() async
    {
        let url = try! cached(TinyGLB.triangle, as: "zip")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: AssetVisualError.unloadableFormat(url)) {
            try await RealityViewMapper.visual(ofAssetAt: url)
        }
    }

    /// A truncated glb is the common malformed case, and it must come back as a throw: conversion
    /// to RealityKit calls `fatalError` on internal failure (upstream), so everything that can be
    /// rejected has to be rejected by the parse step before it.
    @Test func aTruncatedGlbThrowsRatherThanTraps() async
    {
        let url = try! cached(TinyGLB.triangle.prefix(40), as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) {
            try await RealityViewMapper.visual(ofAssetAt: url)
        }
    }
}

private extension RealityKit.Entity
{
    var meshBearingDescendants: Int
    {
        (components[ModelComponent.self] != nil ? 1 : 0) + children.reduce(0) { $0 + $1.meshBearingDescendants }
    }
}

/// The smallest glTF 2.0 that draws something: one unlit triangle, positions and normals, no
/// material. Generated rather than committed so the container layout stays readable — a binary
/// fixture would say nothing about why the bytes are what they are.
enum TinyGLB
{
    static let triangle: Data = {
        let json = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],\
        "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1}}]}],\
        "accessors":[\
        {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},\
        {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"}],\
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36}],\
        "buffers":[{"byteLength":72}]}
        """
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let normals: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1]

        // Both chunks are 4-byte aligned; JSON pads with spaces, BIN with zeros (glTF 2.0 §4.4.1).
        var jsonChunk = Data(json.utf8)
        jsonChunk.append(contentsOf: Array(repeating: UInt8(0x20), count: (4 - jsonChunk.count % 4) % 4))
        var binChunk = (positions + normals).withUnsafeBufferPointer { Data(buffer: $0) }
        binChunk.append(contentsOf: Array(repeating: UInt8(0), count: (4 - binChunk.count % 4) % 4))

        var glb = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { glb.append(contentsOf: $0) } }
        glb.append(contentsOf: Array("glTF".utf8)); u32(2); u32(12 + 8 + jsonChunk.count + 8 + binChunk.count)
        u32(jsonChunk.count); glb.append(contentsOf: Array("JSON".utf8)); glb.append(jsonChunk)
        u32(binChunk.count); glb.append(contentsOf: Array("BIN\0".utf8)); glb.append(binChunk)
        return glb
    }()
}
