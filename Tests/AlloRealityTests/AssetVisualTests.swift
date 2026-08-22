import Testing
import Foundation
import RealityKit
import GLTFKit2
@testable import AlloReality

/// Turning a cached file into a visual. The bytes are a peer's and only their hash was checked, so
/// most of this is about files that shouldn't load.
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
        let url = try cached(TinyGLB.triangle(), as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        let visual = try await RealityViewMapper.visual(ofAssetAt: url)
        #expect(visual.meshBearingDescendants > 0)
    }

    /// The publisher chose the media type the extension came from, so it can name anything.
    @Test func anUnknownExtensionFails() async throws
    {
        let url = try cached(TinyGLB.triangle(), as: "zip")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: AssetVisualError.unloadableFormat(url)) {
            try await RealityViewMapper.visual(ofAssetAt: url)
        }
    }

    /// `.gltf` is a media type the store accepts but this deliberately won't load.
    @Test func jsonGltfIsRefusedRatherThanResolvedAgainstTheCacheDirectory() async throws
    {
        let url = try cached(TinyGLB.triangle(), as: "gltf")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: AssetVisualError.unloadableFormat(url)) {
            try await RealityViewMapper.visual(ofAssetAt: url)
        }
    }

    /// The common malformed case, and conversion has no error path — so the parser must catch it.
    @Test func aTruncatedGlbThrowsFromTheParser() async throws
    {
        let url = try cached(TinyGLB.triangle().prefix(40), as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        do
        {
            _ = try await RealityViewMapper.visual(ofAssetAt: url)
            Issue.record("a truncated glb produced a visual")
        }
        catch let error as NSError
        {
            #expect(error.domain == GLTFErrorDomain)
        }
    }

    /// Parses fine, then asserts below Swift where no `catch` reaches it (measured: SIGTRAP).
    @Test func attributesThatDisagreeAboutVertexCountAreRejected() async throws
    {
        let url = try cached(TinyGLB.triangle(normals: 1), as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: AssetVisualError.self) {
            try await RealityViewMapper.visual(ofAssetAt: url)
        }
    }

    /// ... and an accessor reading past the end of its buffer view is the same class of trap.
    @Test func anAccessorReadingPastItsBufferViewIsRejected() async throws
    {
        let url = try cached(TinyGLB.triangle(normalViewLength: 12), as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: AssetVisualError.self) {
            try await RealityViewMapper.visual(ofAssetAt: url)
        }
    }

    /// The bounds check is arithmetic on a peer's numbers, so it must survive numbers picked to
    /// overflow it before the comparison that would have rejected them.
    @Test func anAbsurdVertexCountIsRejectedRatherThanOverflowing() async throws
    {
        let url = try cached(TinyGLB.triangle(vertexCount: "9223372036854775807"), as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: AssetVisualError.self) {
            try await RealityViewMapper.visual(ofAssetAt: url)
        }
    }

    /// A `.glb` can name external buffers too; parsing from bytes leaves nothing to resolve against.
    @Test func aGlbReferencingAnExternalBufferCannotReachIt() async throws
    {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("assets-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // What a traversal would be after, one level above the cache.
        try Data(repeating: 0x41, count: 64).write(to: root.appendingPathComponent("secret.bin"))

        for uri in ["../secret.bin", "..%2Fsecret.bin"]
        {
            let url = cache.appendingPathComponent("\(String(repeating: "ab", count: 32)).glb")
            try TinyGLB.triangle(bufferURI: uri).write(to: url)
            await #expect(throws: (any Error).self, "\(uri) resolved") {
                try await RealityViewMapper.visual(ofAssetAt: url)
            }
            try fm.removeItem(at: url)
        }
    }

    /// `guiForEid` searches the whole tree, so a node named after another entity would collect its
    /// updates and its removal.
    @Test func aNodeNamedLikeAnEntityCannotHijackLookups() async throws
    {
        let eid = "E3B0C442-98FC-1C14-9AFB-F4C8996FB924"
        let url = try cached(TinyGLB.triangle(nodeName: eid), as: "glb")
        defer { try? FileManager.default.removeItem(at: url) }
        let visual = try await RealityViewMapper.visual(ofAssetAt: url)

        // The name really does survive the load, so this fails if anonymize becomes a no-op.
        #expect(visual.findEntity(named: eid) != nil)

        // The shape guiForEid searches: guiroot -> entity -> asset subtree.
        let guiroot = RealityKit.Entity()
        let mapped = RealityKit.Entity()
        mapped.name = "9F2B1E44-0000-4000-8000-000000000001"
        guiroot.addChild(mapped)
        RealityViewMapper.anonymize(visual)
        mapped.addChild(visual)

        #expect(guiroot.findEntity(named: eid) == nil)
        #expect(guiroot.findEntity(named: mapped.name) === mapped)
    }
}

private extension RealityKit.Entity
{
    var meshBearingDescendants: Int
    {
        (components[ModelComponent.self] != nil ? 1 : 0) + children.reduce(0) { $0 + $1.meshBearingDescendants }
    }
}

/// The smallest glTF 2.0 that draws something. Generated rather than committed so each hostile
/// variant differs from the good one by exactly the field under test.
enum TinyGLB
{
    /// - Parameters:
    ///   - normals: how many NORMAL vectors the accessor claims; 3 (one per vertex) is correct.
    ///   - normalViewLength: byte length its buffer view claims; nil for the honest 12 per normal.
    ///   - bufferURI: a `uri` on a second buffer, which a self-contained glb never has.
    ///   - vertexCount: set on *both* accessors, so an absurd value reaches the byte-range check.
    ///   - nodeName: the glTF node's name, which is a peer's to choose.
    static func triangle(normals: Int = 3, normalViewLength: Int? = nil, bufferURI: String? = nil,
                         vertexCount: String = "3", nodeName: String? = nil) -> Data
    {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let normalData: [Float] = (0..<3).flatMap { _ -> [Float] in [0, 0, 1] }
        let normalBytes = normalData.count * 4
        let json = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],\
        "nodes":[{"mesh":0\(nodeName.map { ",\"name\":\"\($0)\"" } ?? "")}],\
        "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1}}]}],\
        "accessors":[\
        {"bufferView":0,"componentType":5126,"count":\(vertexCount),"type":"VEC3","min":[0,0,0],"max":[1,1,0]},\
        {"bufferView":1,"componentType":5126,"count":\(normals == 3 ? vertexCount : String(normals)),"type":"VEC3"}],\
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},\
        {"buffer":0,"byteOffset":36,"byteLength":\(normalViewLength ?? normalBytes)}],\
        "buffers":[{"byteLength":\(36 + normalBytes)}\
        \(bufferURI.map { ",{\"byteLength\":64,\"uri\":\"\($0)\"}" } ?? "")]}
        """

        // Chunks are 4-byte aligned; JSON pads with spaces, BIN with zeros (glTF 2.0 §4.4.1).
        var jsonChunk = Data(json.utf8)
        jsonChunk.append(contentsOf: Array(repeating: UInt8(0x20), count: (4 - jsonChunk.count % 4) % 4))
        var binChunk = (positions + normalData).withUnsafeBufferPointer { Data(buffer: $0) }
        binChunk.append(contentsOf: Array(repeating: UInt8(0), count: (4 - binChunk.count % 4) % 4))

        var glb = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { glb.append(contentsOf: $0) } }
        glb.append(contentsOf: Array("glTF".utf8)); u32(2); u32(12 + 8 + jsonChunk.count + 8 + binChunk.count)
        u32(jsonChunk.count); glb.append(contentsOf: Array("JSON".utf8)); glb.append(jsonChunk)
        u32(binChunk.count); glb.append(contentsOf: Array("BIN\0".utf8)); glb.append(binChunk)
        return glb
    }
}
