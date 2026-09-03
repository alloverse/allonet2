//
//  AlloClient+Assets.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2026-08-05.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Publishing and fetching assets. The place is the single origin: publishers push bytes to it,
/// consumers pull from it, and nobody talks to anybody else. That the transfer happens to be HTTP
/// is deliberately invisible from out here, so eager push can become lazy pull without touching a
/// single app.
///
/// This hangs off `AlloClient` rather than `AlloSession` because a session has no URL, and because
/// `AlloClient` is the one type both alloapps (`AlloAppClient`) and visors (`AlloUserClient`) are
/// built on — avatars are client-published, so both sides publish.
public extension AlloClient
{
    /// Publish `data` so any agent in the place can fetch it by the returned id. Idempotent: if the
    /// place already has these bytes, nothing is uploaded, which is what makes re-publishing across
    /// reconnects cheap.
    ///
    /// - Parameter ephemeral: keep the bytes in the place's memory for two minutes instead of on
    ///   its disk, for something replaced faster than it is worth storing - a screen's thumbnail,
    ///   a status glyph. Only for an id nothing will need again: it 404s once the lease runs out.
    ///   An ephemeral publish always uploads, because the upload is what renews that lease, and it
    ///   does not seed the local cache.
    /// - Throws: `AssetError.transferFailed` carrying the place's reason, which for an ephemeral
    ///   publish that does not fit is HTTP 507 naming the size and the cap.
    @discardableResult
    func publish(asset data: Data, contentType: String = AssetStore.defaultContentType, ephemeral: Bool = false) async throws -> AssetID
    {
        // Hashed inside the store's actor, which both keeps SHA-256 over a whole mesh off the main
        // actor and means the bytes are addressed once rather than here and again on the way in.
        let id = ephemeral ? await assetCache.address(of: data)
                           : try await assetCache.store(data, contentType: contentType)
        if !ephemeral, try await placeAlreadyKnows(id, as: contentType) { return id }

        let request = try assetUploadRequest(contentType: contentType, ephemeral: ephemeral)
        let response = try await retryingIfDropped { try await URLSession.shared.upload(for: request, from: data) }
        return try confirmUpload(response, expecting: id)
    }

    /// Publish the file at `fileURL`. Preferred over the `Data` overload for anything sizeable: the
    /// bytes go disk-to-socket without ever being held whole in memory. The media type is inferred
    /// from the file extension unless given. Unlike the `Data` overload this doesn't seed the local
    /// cache — the publisher already has the file, and copying a mesh to have it twice is the cost
    /// this overload exists to avoid.
    @discardableResult
    func publish(assetAt fileURL: URL, contentType: String? = nil) async throws -> AssetID
    {
        let type = contentType
            ?? AssetStore.contentType(forExtension: fileURL.pathExtension)
            ?? AssetStore.defaultContentType
        let id = try await assetCache.address(ofFileAt: fileURL)
        if try await placeAlreadyKnows(id, as: type) { return id }

        let request = try assetUploadRequest(contentType: type)
        let response = try await retryingIfDropped { try await URLSession.shared.upload(for: request, fromFile: fileURL) }
        return try confirmUpload(response, expecting: id)
    }

    /// The bytes for `id`, from the local cache if we have them, else from the place.
    func fetchAsset(_ id: AssetID) async throws -> Data
    {
        _ = try await assetURL(id) // ensure it's cached
        guard let data = try await assetCache.data(for: id) else { throw AssetError.notFound(id) }
        return data
    }

    /// A local file holding `id`'s bytes, fetched first if we don't have them. Named with an
    /// extension matching its media type, so it can go straight to a loader that dispatches on one
    /// — RealityKit has no data-based USDZ loader.
    func assetURL(_ id: AssetID) async throws -> URL
    {
        if let cached = try await assetCache.entry(for: id) { return cached.url }

        if let inFlight = assetFetches[id] { return try await inFlight.value.url }
        let fetch = Task { try await download(id) }
        assetFetches[id] = fetch
        defer { assetFetches[id] = nil }
        return try await fetch.value.url
    }

    /// What the place holds these bytes as, or nil if it doesn't hold them. The size is what a
    /// fetch would cost, so a consumer can decide whether to pay it before calling `fetchAsset`;
    /// it's optional because only the origin is obliged to declare one, and an intermediary may not.
    func placeAssetInfo(_ id: AssetID) async throws -> (contentType: String, byteCount: Int?)?
    {
        var request = URLRequest(url: try assetsURL(for: id))
        request.httpMethod = "HEAD"
        let (_, response) = try await retryingIfDropped { try await URLSession.shared.data(for: request) }
        let http = response as! HTTPURLResponse
        switch http.statusCode
        {
        case 200: return (
            http.value(forHTTPHeaderField: "Content-Type") ?? AssetStore.defaultContentType,
            http.value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) }
        )
        case 404: return nil
        default: throw AssetError.transferFailed(id: id, status: http.statusCode, body: "")
        }
    }

    /// The media type the place already holds these bytes under, or nil if it doesn't hold them.
    func placeAssetType(_ id: AssetID) async throws -> String?
    {
        try await placeAssetInfo(id)?.contentType
    }
}

private extension AlloClient
{
    /// Whether uploading would tell the place nothing it doesn't already have. Bytes alone aren't
    /// enough: if it holds them under `application/octet-stream` because whoever got there first
    /// didn't say, and we do know, the upload is worth making so the type - and with it the
    /// extension a loader needs - gets corrected.
    func placeAlreadyKnows(_ id: AssetID, as contentType: String) async throws -> Bool
    {
        guard let stored = try await placeAssetType(id) else { return false }
        let ours = AssetStore.bareType(of: contentType)
        return ours == AssetStore.bareType(of: stored) || ours == AssetStore.defaultContentType
    }

    /// URLSession keeps connections pooled, so the first request after a place restarts is answered
    /// by a socket that is already dead — and it will not retry a POST on its own. Every asset
    /// request here is idempotent (that is what content addressing buys), so retrying a dropped one
    /// exactly once turns a spurious failure into a hiccup. Anything else propagates untouched.
    func retryingIfDropped<T>(_ perform: () async throws -> T) async throws -> T
    {
        do { return try await perform() }
        catch let error as URLError where error.code == .networkConnectionLost
        {
            logger.info("Asset transfer lost its connection; retrying once")
            return try await perform()
        }
    }

    /// Assets live at the root of the place's HTTP server regardless of any path in the place URL.
    func assetsURL(for id: AssetID?) throws -> URL
    {
        guard var comps = URLComponents(url: try httpURL, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        comps.path = id.map { "/assets/\($0)" } ?? "/assets"
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    func assetUploadRequest(contentType: String, ephemeral: Bool = false) throws -> URLRequest
    {
        // The upload is a bare HTTP request with no session behind it, so the token from our
        // announce response is the only thing telling the place we belong here.
        guard let assetToken else { throw AssetError.notAllowedToPublish }
        var request = URLRequest(url: try assetsURL(for: nil))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(assetToken)", forHTTPHeaderField: "Authorization")
        if ephemeral { request.setValue("1", forHTTPHeaderField: PlaceServerAssets.ephemeralHeader) }
        return request
    }

    /// The place hashes uploads itself and tells us what it named the result. If that disagrees with
    /// what we computed, one of us is broken and the id we're about to reference is worthless.
    func confirmUpload(_ response: (Data, URLResponse), expecting id: AssetID) throws -> AssetID
    {
        let (data, urlResponse) = response
        let http = urlResponse as! HTTPURLResponse
        guard http.statusCode == 201 || http.statusCode == 200 else
        {
            throw AssetError.transferFailed(id: id, status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let published = try JSONDecoder().decode(AssetUploadResponse.self, from: data).id
        guard published == id else { throw AssetError.hashMismatch(expected: id, actual: published) }
        return published
    }

    /// Streamed to a file rather than `data(for:)`, so a large mesh never sits in memory, and
    /// verified on the way into the cache — content addressing only checks integrity if someone
    /// actually does the check.
    func download(_ id: AssetID) async throws -> AssetStore.Entry
    {
        let request = URLRequest(url: try assetsURL(for: id))
        let (temporary, urlResponse) = try await retryingIfDropped { try await URLSession.shared.download(for: request) }
        let http = urlResponse as! HTTPURLResponse
        guard http.statusCode == 200 else
        {
            try? FileManager.default.removeItem(at: temporary)
            if http.statusCode == 404 { throw AssetError.notFound(id) }
            throw AssetError.transferFailed(id: id, status: http.statusCode, body: "")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? AssetStore.defaultContentType
        return try await assetCache.adopt(fileAt: temporary, expecting: id, contentType: contentType)
    }
}
