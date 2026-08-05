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
    @discardableResult
    func publish(asset data: Data, contentType: String = AssetStore.defaultContentType) async throws -> AssetID
    {
        let id = AssetID(hashing: data)
        try await assetCache.store(data, contentType: contentType)
        if try await placeHasAsset(id) { return id }

        let request = try assetUploadRequest(contentType: contentType)
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
        let id = try AssetID(hashingContentsOf: fileURL)
        if try await placeHasAsset(id) { return id }

        let request = try assetUploadRequest(contentType: type)
        let response = try await retryingIfDropped { try await URLSession.shared.upload(for: request, fromFile: fileURL) }
        return try confirmUpload(response, expecting: id)
    }

    /// The bytes for `id`, from the local cache if we have them, else from the place.
    func fetchAsset(_ id: AssetID) async throws -> Data
    {
        try Data(contentsOf: try await assetURL(id))
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

    /// Whether the place already holds these bytes, so we can skip uploading them.
    func placeHasAsset(_ id: AssetID) async throws -> Bool
    {
        var request = URLRequest(url: try assetsURL(for: id))
        request.httpMethod = "HEAD"
        let (_, response) = try await retryingIfDropped { try await URLSession.shared.data(for: request) }
        let http = response as! HTTPURLResponse
        switch http.statusCode
        {
        case 200: return true
        case 404: return false
        default: throw AssetError.transferFailed(id: id, status: http.statusCode, body: "")
        }
    }
}

private extension AlloClient
{
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

    func assetUploadRequest(contentType: String) throws -> URLRequest
    {
        var request = URLRequest(url: try assetsURL(for: nil))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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
