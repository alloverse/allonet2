import Testing
import Foundation
import FlyingFox
import FlyingSocks
import PotentCBOR
@testable import allonet2

// MARK: - Content addressing

struct AssetIDTests
{
    @Test func rejectsAnythingThatIsNotOurShape()
    {
        let hex = String(repeating: "a", count: 64)
        #expect(AssetID("sha256:\(hex)") != nil)
        #expect(AssetID(hex) == nil)                                    // no prefix
        #expect(AssetID("sha1:\(hex)") == nil)                          // wrong algorithm
        #expect(AssetID("sha256:\(String(repeating: "a", count: 63))") == nil)
        #expect(AssetID("sha256:\(String(repeating: "a", count: 65))") == nil)
        #expect(AssetID("sha256:\(hex.uppercased())") == nil)           // lowercase only, or ids stop being unique
        #expect(AssetID("sha256:\(String(repeating: "z", count: 64))") == nil)
        #expect(AssetID("sha256:") == nil)
        #expect(AssetID("") == nil)
    }

    /// A wrong digest or a hex-encoding slip would make every id in the system wrong but consistent,
    /// so pin it to the known SHA-256 of the empty input.
    @Test func matchesTheKnownVector()
    {
        #expect(AssetID(hashing: Data()).description == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(AssetID(hashing: Data("abc".utf8)).description == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hashesAFileTheSameAsItsBytes() throws
    {
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try AssetID(hashingContentsOf: file) == AssetID(hashing: bytes))
    }

    @Test func codesAsItsBareString() throws
    {
        let id = AssetID(hashing: Data("hello".utf8))
        let encoded = try JSONEncoder().encode(AssetUploadResponse(id: id))
        #expect(String(data: encoded, encoding: .utf8) == "{\"id\":\"\(id)\"}")
        #expect(try JSONDecoder().decode(AssetUploadResponse.self, from: encoded).id == id)
    }

    /// `Mesh.asset` used to carry a bare `String`; the `AssetID` retype must encode identically or
    /// the component breaks across the version gap.
    @Test @MainActor func meshAssetCodesLikeItsStringPredecessor() throws
    {
        let id = AssetID(hashing: Data("mesh".utf8))
        let encoded = try JSONEncoder().encode(Model.Mesh.asset(id: id))
        #expect(String(data: encoded, encoding: .utf8) == "{\"asset\":{\"id\":\"\(id)\"}}")
        #expect(try JSONDecoder().decode(Model.Mesh.self, from: encoded) == .asset(id: id))
    }

    /// `Model` hand-writes `init(from:)` to survive a bad id, which is exactly the kind of change
    /// that silently rewrites a wire format. Encoding is still synthesized and a valid payload must
    /// still decode to itself, byte for byte.
    @Test @MainActor func modelStillCodesAsItAlwaysDid() throws
    {
        let id = AssetID(hashing: Data("mesh".utf8))
        let model = Model(mesh: .asset(id: id))
        // Sorted because JSONEncoder's key order for this type varies between processes; the wire
        // is CBOR and keyed either way, so what's pinned is the shape and the leaf spellings.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(model)
        #expect(String(data: encoded, encoding: .utf8) == "{\"material\":{\"standard\":{}},\"mesh\":{\"asset\":{\"id\":\"\(id)\"}}}")
        #expect(try JSONDecoder().decode(Model.self, from: encoded) == model)
    }

    /// `AnyComponent.decoded()` force-tries, so a Model that throws on decode takes down every
    /// client rendering that entity — one malformed id from any peer would empty a room. An id that
    /// isn't a content address can never name bytes, so the model degrades to something visibly
    /// broken instead of throwing.
    @Test @MainActor func aModelWithAnUnparseableAssetIdDegradesInsteadOfTrapping() throws
    {
        func model(_ json: String) throws -> Model
        {
            try JSONDecoder().decode(Model.self, from: Data(json.utf8))
        }
        // The mesh's id, and the material's — both reach AssetID through a different enum.
        #expect(try model(#"{"mesh":{"asset":{"id":"placeholder"}},"material":{"standard":{}}}"#) == .unrenderable)
        #expect(try model(#"{"mesh":{"sphere":{"radius":1}},"material":{"image":{"asset":"../../etc/passwd"}}}"#) == .unrenderable)
        // A payload that is wrong in some other way is still an error: we only know what a bad id means.
        #expect(throws: (any Error).self) { try model(#"{"mesh":{"sphere":{"radius":"big"}},"material":{"standard":{}}}"#) }
    }
}

// MARK: - Announce compatibility
// The asset token rides in announceResponse, and KojaServ/KojaApp sit on older allonet2 pins, so
// both directions across the version gap have to keep working.

struct AnnounceTokenTests
{
    @Test func carriesTheTokenBothWays() throws
    {
        let body = InteractionBody.announceResponse(avatarId: "abc", placeName: "Home", assetToken: "s3cret")
        let decoded = try CBORDecoder().decode(InteractionBody.self, from: try CBOREncoder().encode(body))
        guard case .announceResponse(let avatarId, let placeName, let token) = decoded else {
            Issue.record("decoded to \(decoded)"); return
        }
        #expect(avatarId == "abc")
        #expect(placeName == "Home")
        #expect(token == "s3cret")
    }

    /// A place from before this change sends no assetToken key at all. If that failed to decode,
    /// upgrading a client against an old place would break connecting outright, not just publishing.
    @Test func decodesAnAnnounceFromAPlaceThatIssuesNoToken() throws
    {
        let old = try CBOREncoder().encode(["announceResponse": ["avatarId": "abc", "placeName": "Home"]])
        let decoded = try CBORDecoder().decode(InteractionBody.self, from: old)
        guard case .announceResponse(let avatarId, let placeName, let token) = decoded else {
            Issue.record("decoded to \(decoded)"); return
        }
        #expect(avatarId == "abc")
        #expect(placeName == "Home")
        #expect(token == nil) // no token means no publishing, which is exactly right
    }
}

// MARK: - The store

struct AssetStoreTests
{
    private func makeStore() -> AssetStore
    {
        AssetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func storingTwiceIsOneAsset() async throws
    {
        let store = makeStore()
        let bytes = Data("a room".utf8)

        let first = try await store.store(bytes, contentType: "model/vnd.usdz+zip")
        let second = try await store.store(bytes, contentType: "model/vnd.usdz+zip")
        #expect(first == second)

        let entry = try #require(try await store.entry(for: first))
        #expect(entry.size == bytes.count)
        #expect(entry.url.pathExtension == "usdz") // named so a file-based loader can open it
        #expect(try Data(contentsOf: entry.url) == bytes)
    }

    /// Whoever publishes bytes first may not have said what they are, and the extension - hence
    /// whether a loader can open the file at all - follows the type. So a publisher that knows gets
    /// to correct one that didn't.
    @Test func namingATypeCorrectsAnUnlabelledAsset() async throws
    {
        let store = makeStore()
        let bytes = Data("a room".utf8)

        let id = try await store.store(bytes, contentType: AssetStore.defaultContentType)
        #expect(try #require(try await store.entry(for: id)).url.pathExtension == "")

        #expect(try await store.store(bytes, contentType: "model/vnd.usdz+zip") == id)
        let relabelled = try #require(try await store.entry(for: id))
        #expect(relabelled.contentType == "model/vnd.usdz+zip")
        #expect(relabelled.url.pathExtension == "usdz")
        #expect(try Data(contentsOf: relabelled.url) == bytes)

        // But a second specific claim doesn't get to overwrite the first: identical bytes, and
        // nothing here can say which publisher is right.
        #expect(try await store.store(bytes, contentType: "image/png") == id)
        #expect(try #require(try await store.entry(for: id)).contentType == "model/vnd.usdz+zip")
    }

    /// Two stores over one directory don't serialize with each other, so clients that didn't ask for
    /// their own cache have to end up on the same actor rather than merely the same path.
    @MainActor
    @Test func clientsShareOneDefaultCache() throws
    {
        let a = TestAlloClient(url: URL(string: "alloplace2://localhost:1")!, identity: .none, avatarDescription: EntityDescription())
        let b = TestAlloClient(url: URL(string: "alloplace2://localhost:2")!, identity: .none, avatarDescription: EntityDescription())
        #expect(a.assetCache === b.assetCache)
        #expect(a.assetCache === AssetStore.shared)
    }

    /// A missing asset is a value, not an error: the whole publish flow is "ask, then upload on nil".
    @Test func absenceIsNilNotAThrow() async throws
    {
        let store = makeStore()
        #expect(try await store.entry(for: AssetID(hashing: Data("never stored".utf8))) == nil)
        #expect(try await store.contains(AssetID(hashing: Data("never stored".utf8))) == false)
    }

    @Test func streamingStoreAddressesWhatActuallyArrived() async throws
    {
        let store = makeStore()
        let chunks = ["one ", "two ", "three"].map { Data($0.utf8) }
        let whole = chunks.reduce(Data(), +)

        let id = try await store.store(streaming: chunks.async, contentType: "application/octet-stream", maxBytes: 1024)
        #expect(id == AssetID(hashing: whole))
        #expect(try Data(contentsOf: try #require(try await store.entry(for: id)).url) == whole)
    }

    @Test func streamingStoreStopsAtTheLimitAndLeavesNothingBehind() async throws
    {
        let store = makeStore()
        let chunks = (0..<10).map { _ in Data(repeating: 0xAB, count: 100) }

        await #expect(throws: AssetError.self) {
            try await store.store(streaming: chunks.async, contentType: "application/octet-stream", maxBytes: 250)
        }
        // Only the abandoned upload could be here, and it should have been cleaned up.
        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(left.isEmpty)
    }

    /// The consumer half of content addressing: bytes that don't hash to what was asked for are refused.
    @Test func adoptingRefusesTheWrongBytes() async throws
    {
        let store = makeStore()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not what you asked for".utf8).write(to: file)

        let wanted = AssetID(hashing: Data("what you asked for".utf8))
        await #expect(throws: AssetError.self) {
            try await store.adopt(fileAt: file, expecting: wanted, contentType: "application/octet-stream")
        }
        #expect(try await store.entry(for: wanted) == nil)
    }
}

// MARK: - Media types

struct AssetMediaTypeTests
{
    /// The two tables are hand-written and drifted apart once already: heic was publishable and
    /// then stored without an extension, so nothing could open it.
    @Test func theTwoTablesAgree()
    {
        for type in ["model/vnd.usdz+zip", "model/vnd.usda", "model/gltf-binary", "model/gltf+json",
                     "image/png", "image/jpeg", "image/heic", "image/ktx2",
                     "audio/wav", "audio/mpeg", "application/json"]
        {
            let ext = AssetStore.filenameExtension(for: type)
            #expect(ext != nil, "no extension for \(type)")
            #expect(AssetStore.contentType(forExtension: ext ?? "") == type)
        }
    }
}

// MARK: - Range parsing
// Off-wire, because a route parameter can't be exercised without a real socket but this can.

struct AssetRangeTests
{
    typealias Range_ = PlaceServerAssets.RangeRequest

    @Test func parsesTheFormsWeActuallyGet()
    {
        #expect(PlaceServerAssets.parseRange(nil, size: 100) == .whole)
        #expect(PlaceServerAssets.parseRange("bytes=0-9", size: 100) == .partial(0..<10))
        #expect(PlaceServerAssets.parseRange("bytes=10-", size: 100) == .partial(10..<100))
        #expect(PlaceServerAssets.parseRange("bytes=-20", size: 100) == .partial(80..<100))
        #expect(PlaceServerAssets.parseRange("items=0-9", size: 100) == .whole) // unknown unit is ignored
        #expect(PlaceServerAssets.parseRange("bytes=0-4, 10-14", size: 100) == .partial(0..<5)) // first range only
    }

    /// FlyingFox's own parser doesn't clamp, and an over-long range surfaces from it as a 404 —
    /// which tells a client "no such asset" when the asset is right there.
    @Test func clampsAndRejectsRatherThanLookingAbsent()
    {
        #expect(PlaceServerAssets.parseRange("bytes=90-999", size: 100) == .partial(90..<100))
        #expect(PlaceServerAssets.parseRange("bytes=100-", size: 100) == .unsatisfiable)
        #expect(PlaceServerAssets.parseRange("bytes=200-300", size: 100) == .unsatisfiable)
        #expect(PlaceServerAssets.parseRange("bytes=5-1", size: 100) == .unsatisfiable)
        #expect(PlaceServerAssets.parseRange("bytes=-0", size: 100) == .unsatisfiable)
        #expect(PlaceServerAssets.parseRange("bytes=0-0", size: 0) == .unsatisfiable)
    }

    /// An unauthenticated GET is enough to reach this, so an overflow here traps the whole place.
    @Test func survivesExtremeBounds()
    {
        #expect(PlaceServerAssets.parseRange("bytes=0-\(Int.max)", size: 100) == .partial(0..<100))
        #expect(PlaceServerAssets.parseRange("bytes=-\(Int.max)", size: 100) == .partial(0..<100))
        #expect(PlaceServerAssets.parseRange("bytes=\(Int.max)-", size: 100) == .unsatisfiable)
        #expect(PlaceServerAssets.parseRange("bytes=\(Int.min)-5", size: 100) == .unsatisfiable)
        #expect(PlaceServerAssets.parseRange("bytes=-\(Int.min)", size: 100) == .unsatisfiable)
    }
}

// MARK: - Over a real socket
// A bound port rather than calling handlers directly: FlyingFox only populates `routeParameters`
// through its own router, so `/assets/:id` cannot be exercised off-wire at all.

@Suite(.serialized)
struct AssetHTTPTests
{
    /// A place's asset endpoint on an ephemeral port, torn down when `body` returns.
    private func withAssetServer(
        maxUploadBytes: Int = PlaceServerAssets.defaultMaxUploadBytes,
        _ body: (URL, PlaceServerAssets) async throws -> Void
    ) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets = PlaceServerAssets(directory: directory, maxUploadBytes: maxUploadBytes)
        await assets.publishers.admit(Self.token)
        let http = HTTPServer(port: 0, timeout: PlaceServerHTTP.requestTimeout)
        await assets.register(on: http)

        let running = Task { try await http.run() }
        try await http.waitUntilListening(timeout: 5)
        defer { running.cancel() }

        guard case .ip6(_, port: let port)? = await http.listeningAddress else {
            Issue.record("server did not report an IPv6 port")
            return
        }

        do { try await body(URL(string: "http://localhost:\(port)")!, assets) }
        catch { await http.stop(); throw error }
        await http.stop()
    }

    /// Every server made by `withAssetServer` admits this one; publishing needs a session token.
    static let token = "test-publisher-token"

    private func post(_ bytes: Data, contentType: String, to base: URL, token: String? = AssetHTTPTests.token) async throws -> (HTTPURLResponse, Data)
    {
        var request = URLRequest(url: base.appendingPathComponent("assets"))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.upload(for: request, from: bytes)
        return (response as! HTTPURLResponse, data)
    }

    private func get(_ id: String, from base: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (HTTPURLResponse, Data)
    {
        var request = URLRequest(url: URL(string: "\(base)/assets/\(id)")!)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse, data)
    }

    /// The whole publish → reference → fetch shape in one pass. Also the only proof that a colon
    /// inside a path segment (`/assets/sha256:…`) survives FlyingFox's path decoding and routing.
    @Test func roundTripsOverHTTP() async throws
    {
        try await withAssetServer { base, _ in
            let bytes = Data((0..<5000).map { UInt8($0 % 256) })

            let (posted, body) = try await post(bytes, contentType: "model/vnd.usdz+zip", to: base)
            #expect(posted.statusCode == 201)
            let id = try JSONDecoder().decode(AssetUploadResponse.self, from: body).id
            #expect(id == AssetID(hashing: bytes)) // the place hashed it itself and agrees with us

            let (headed, headBody) = try await get(id.description, from: base, method: "HEAD")
            #expect(headed.statusCode == 200)
            #expect(headed.value(forHTTPHeaderField: "Content-Length") == String(bytes.count))
            #expect(headBody.isEmpty)

            let (got, fetched) = try await get(id.description, from: base)
            #expect(got.statusCode == 200)
            #expect(fetched == bytes)
            #expect(got.value(forHTTPHeaderField: "ETag") == "\"\(id)\"") // RFC 9110: quoted, or caches ignore it
            #expect(got.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=31536000, immutable")
            #expect(got.value(forHTTPHeaderField: "Content-Type") == "model/vnd.usdz+zip")
        }
    }

    @Test func repostingTheSameBytesIsANoOp() async throws
    {
        try await withAssetServer { base, assets in
            let bytes = Data("the same room twice".utf8)
            let (first, firstBody) = try await post(bytes, contentType: "model/vnd.usdz+zip", to: base)
            let (second, secondBody) = try await post(bytes, contentType: "model/vnd.usdz+zip", to: base)

            #expect(first.statusCode == 201)
            #expect(second.statusCode == 201)
            let firstID = try JSONDecoder().decode(AssetUploadResponse.self, from: firstBody).id
            let secondID = try JSONDecoder().decode(AssetUploadResponse.self, from: secondBody).id
            #expect(firstID == secondID)

            // One asset on disk: the bytes and their type sidecar, nothing else.
            let stored = try FileManager.default.contentsOfDirectory(atPath: assets.store.directory.path)
            #expect(stored.count == 2)
        }
    }

    @Test func servesByteRanges() async throws
    {
        try await withAssetServer { base, _ in
            let bytes = Data("0123456789".utf8)
            let (_, body) = try await post(bytes, contentType: "application/octet-stream", to: base)
            let id = try JSONDecoder().decode(AssetUploadResponse.self, from: body).id.description

            let (partial, middle) = try await get(id, from: base, headers: ["Range": "bytes=2-5"])
            #expect(partial.statusCode == 206)
            #expect(middle == Data("2345".utf8))
            #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes 2-5/10")

            let (suffix, tail) = try await get(id, from: base, headers: ["Range": "bytes=-3"])
            #expect(suffix.statusCode == 206)
            #expect(tail == Data("789".utf8))

            // 416, not the 404 that delegating to FlyingFox's FileHTTPHandler would have produced.
            let (beyond, _) = try await get(id, from: base, headers: ["Range": "bytes=99-"])
            #expect(beyond.statusCode == 416)
            #expect(beyond.value(forHTTPHeaderField: "Content-Range") == "bytes */10")
        }
    }

    @Test func rejectsAnOversizedUpload() async throws
    {
        try await withAssetServer(maxUploadBytes: 1024) { base, assets in
            let (response, _) = try await post(Data(repeating: 0x5A, count: 4096), contentType: "application/octet-stream", to: base)
            // Exactly 413: a `throw` in the handler would give 500, which also "isn't a crash".
            #expect(response.statusCode == 413)

            // Rejecting has to leave the connection usable, which means the body was drained.
            let (after, _) = try await post(Data("small".utf8), contentType: "application/octet-stream", to: base)
            #expect(after.statusCode == 201)
            #expect(try await assets.store.contains(AssetID(hashing: Data("small".utf8))))
        }
    }

    @Test func rejectsAMalformedIDWithoutFallingOver() async throws
    {
        try await withAssetServer { base, _ in
            for bad in ["not-a-hash", "sha256:zzzz", "sha1:\(String(repeating: "a", count: 64))"]
            {
                let (response, _) = try await get(bad, from: base)
                #expect(response.statusCode == 400, "expected 400 for '\(bad)'")
            }
            // Still serving.
            let (absent, _) = try await get(AssetID(hashing: Data("nope".utf8)).description, from: base)
            #expect(absent.statusCode == 404)
        }
    }

    @Test func reportsAnAbsentAssetAs404() async throws
    {
        try await withAssetServer { base, _ in
            let id = AssetID(hashing: Data("never uploaded".utf8)).description
            let (headed, _) = try await get(id, from: base, method: "HEAD")
            let (got, _) = try await get(id, from: base)
            #expect(headed.statusCode == 404)
            #expect(got.statusCode == 404)
        }
    }

    /// Writing is what fills a disk, so it takes a token the place only hands out at announce.
    @Test func refusesToPublishWithoutASessionToken() async throws
    {
        try await withAssetServer { base, assets in
            let bytes = Data("uninvited".utf8)

            let (anonymous, _) = try await post(bytes, contentType: "application/octet-stream", to: base, token: nil)
            #expect(anonymous.statusCode == 401)

            let (wrong, _) = try await post(bytes, contentType: "application/octet-stream", to: base, token: "not-the-token")
            #expect(wrong.statusCode == 401)
            #expect(try await assets.store.contains(AssetID(hashing: bytes)) == false)

            // Revoking, as a disconnect does, takes the right away again.
            await assets.publishers.revoke(Self.token)
            let (revoked, _) = try await post(bytes, contentType: "application/octet-stream", to: base)
            #expect(revoked.statusCode == 401)

            await assets.publishers.admit(Self.token)
            let (allowed, _) = try await post(bytes, contentType: "application/octet-stream", to: base)
            #expect(allowed.statusCode == 201)
        }
    }

    /// Reading stays open: assets are immutable and cacheable by any intermediary, and you need the
    /// content hash to ask for one at all.
    @Test func servesReadsWithoutAToken() async throws
    {
        try await withAssetServer { base, _ in
            let bytes = Data("public knowledge".utf8)
            let (_, body) = try await post(bytes, contentType: "application/octet-stream", to: base)
            let id = try JSONDecoder().decode(AssetUploadResponse.self, from: body).id.description

            let (got, fetched) = try await get(id, from: base)
            #expect(got.statusCode == 200)
            #expect(fetched == bytes)
        }
    }

    /// URLSession destroys the connection when a HEAD comes back with content, and a HEAD 404 is
    /// the normal path for a first publish - so the error paths must not carry one either.
    @Test func headCarriesNoBodyEvenOnErrors() async throws
    {
        try await withAssetServer { base, _ in
            for path in [AssetID(hashing: Data("absent".utf8)).description, "not-a-hash"]
            {
                let (response, _) = try await get(path, from: base, method: "HEAD")
                #expect(response.statusCode == (path.hasPrefix("sha256:") ? 404 : 400))
                // URLSession hides a HEAD body, so assert on what the server said it sent.
                let declared = response.value(forHTTPHeaderField: "Content-Length")
                #expect(declared == nil || declared == "0", "HEAD \(path) declared a \(declared ?? "?") byte body")
            }
        }
    }

    /// The client API end to end against a real place endpoint: publish, skip the second upload,
    /// fetch back byte-identical data. Needs no WebRTC session — assets ride HTTP, which is the
    /// whole point of the design.
    @MainActor
    @Test func clientPublishesAndFetches() async throws
    {
        try await withAssetServer { base, assets in
            let client = TestAlloClient(
                url: URL(string: "alloplace2://localhost:\(base.port!)")!,
                identity: Identity.none,
                avatarDescription: EntityDescription()
            )
            client.assetCache = AssetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            client.assetToken = Self.token // what announcing would have given it

            let bytes = Data((0..<20_000).map { UInt8($0 % 256) })
            let id = try await client.publish(asset: bytes, contentType: "model/vnd.usdz+zip")
            #expect(id == AssetID(hashing: bytes))
            #expect(try await assets.store.contains(id))

            // Second publish sees the place already has it and uploads nothing.
            #expect(try await client.publish(asset: bytes, contentType: "model/vnd.usdz+zip") == id)

            // Type and size in one HEAD: what a consumer needs to decide whether to fetch at all.
            let info = try #require(try await client.placeAssetInfo(id))
            #expect(info.contentType == "model/vnd.usdz+zip")
            #expect(info.byteCount == bytes.count)
            let absent = try await client.placeAssetInfo(AssetID(hashing: Data("never published".utf8)))
            #expect(absent == nil)

            // Fetch through a cold cache, so this really goes over the wire.
            let consumer = TestAlloClient(
                url: URL(string: "alloplace2://localhost:\(base.port!)")!,
                identity: Identity.none,
                avatarDescription: EntityDescription()
            )
            consumer.assetCache = AssetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

            #expect(try await consumer.fetchAsset(id) == bytes)
            // And the file it cached is named so a loader can open it.
            #expect(try await consumer.assetURL(id).pathExtension == "usdz")
        }
    }
}

// MARK: - Helpers

private extension Array where Element == Data
{
    /// The chunked body an upload handler sees, without a socket in the way.
    var async: AsyncStream<Data>
    {
        AsyncStream { continuation in
            for chunk in self { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}
