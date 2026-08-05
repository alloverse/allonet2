//
//  PlaceServerAssets.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2026-08-05.
//

import Foundation
import FlyingFox
import Logging

/// The place as the single origin for assets: publishers push bytes here, consumers pull them.
/// Deliberately *not* `@MainActor` — hashing and file I/O for a multi-megabyte asset must not run
/// on the actor the simulation lives on.
public final class PlaceServerAssets: Sendable
{
    public static let defaultMaxUploadBytes = 32 * 1024 * 1024
    /// FlyingFox streams file bodies in 4 KiB chunks by default, which is a lot of syscalls for a
    /// 13 MB mesh.
    static let bufferSize = 256 * 1024

    let store: AssetStore
    let maxUploadBytes: Int
    let publishers = PublishTokens()
    private let logger = Logger(labelSuffix: "place.assets")

    public init(directory: URL, maxUploadBytes: Int = defaultMaxUploadBytes)
    {
        self.store = AssetStore(directory: directory)
        self.maxUploadBytes = maxUploadBytes
    }

    /// Who may write to the store. Reading assets is open — they are immutable, cacheable by any
    /// intermediary, and you need the content hash to ask for one at all — but writing is what
    /// fills a disk, so it is restricted to agents that have announced themselves over a session.
    /// An actor because the place admits and revokes from the main actor while uploads check from
    /// FlyingFox's own task tree.
    public actor PublishTokens
    {
        private var tokens: Set<String> = []

        func admit(_ token: String) { tokens.insert(token) }
        func revoke(_ token: String) { tokens.remove(token) }
        func allows(_ token: String) -> Bool { tokens.contains(token) }
        var count: Int { tokens.count }
    }

    public func register(on http: HTTPServer) async
    {
        await http.appendRoute("GET,HEAD /assets/:id") { [self] in await fetch($0) }
        await http.appendRoute("POST /assets") { [self] in await upload($0) }
    }

    // MARK: - Fetching

    func fetch(_ request: HTTPRequest) async -> HTTPResponse
    {
        let response = await resolve(request)
        guard request.method == .HEAD else { return response }
        // RFC 9110 9.3.2: a HEAD response carries no content, and FlyingFox's encoder writes
        // whatever body it is handed. URLSession answers a body on a HEAD by destroying the
        // connection - and a HEAD 404 is the normal path for the first publish of any asset, so
        // leaving the body on costs a TCP (and behind a TLS proxy, a TLS) handshake every time.
        return HTTPResponse(version: response.version, statusCode: response.statusCode, headers: response.headers)
    }

    private func resolve(_ request: HTTPRequest) async -> HTTPResponse
    {
        guard let raw = request.routeParameters["id"], let id = AssetID(raw) else
        {
            return Self.problem(.badRequest, AssetError.malformedID(request.routeParameters["id"] ?? request.path))
        }

        let found: AssetStore.Entry?
        do { found = try await store.entry(for: id) }
        catch { return Self.problem(.internalServerError, "\(error)") }
        guard let entry = found else { return Self.problem(.notFound, AssetError.notFound(id)) }

        // Content-addressed, so the bytes behind an id can never change: cache them forever.
        var headers: HTTPHeaders = [
            .contentType: entry.contentType,
            .eTag: "\"\(entry.id)\"", // RFC 9110 8.8.3: an entity tag is a quoted string, or caches ignore it
            .acceptRanges: "bytes",
            HTTPHeader("Cache-Control"): "public, max-age=31536000, immutable",
        ]

        // HEAD reports the size it would have sent; fetch() is what guarantees no body follows.
        if request.method == .HEAD
        {
            headers[.contentLength] = String(entry.size)
            return HTTPResponse(statusCode: .ok, headers: headers)
        }

        do
        {
            switch Self.parseRange(request.headers[.range], size: entry.size)
            {
            case .unsatisfiable:
                headers[.contentRange] = "bytes */\(entry.size)"
                return HTTPResponse(statusCode: .rangeNotSatisfiable, headers: headers)
            case .partial(let range):
                headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(entry.size)"
                return HTTPResponse(
                    statusCode: .partialContent,
                    headers: headers,
                    body: try HTTPBodySequence(file: entry.url, range: range, suggestedBufferSize: Self.bufferSize)
                )
            case .whole:
                return HTTPResponse(
                    statusCode: .ok,
                    headers: headers,
                    body: try HTTPBodySequence(file: entry.url, suggestedBufferSize: Self.bufferSize)
                )
            }
        }
        catch
        {
            return Self.problem(.internalServerError, "\(error)")
        }
    }

    // MARK: - Uploading

    func upload(_ request: HTTPRequest) async -> HTTPResponse
    {
        let length = request.headers[.contentLength].flatMap(Int.init)

        // Checked before any work is done. A token can go stale mid-upload when a publish races a
        // disconnect, and that client keeps its connection, so a body we would have accepted anyway
        // is drained to keep the socket parseable. An oversized one is not: a stranger doesn't get
        // to make us read gigabytes, and a dead connection is the right answer for them.
        guard let token = Self.bearerToken(request.headers[.authorization]), await publishers.allows(token) else
        {
            if let length, length <= maxUploadBytes { await drain(request) }
            return Self.problem(.unauthorized, "Publishing assets requires the token from your announce response")
        }

        // FlyingFox decodes a missing Content-Length as an empty body and has no chunked request
        // decoder at all, so without this we would cheerfully store the hash of nothing.
        guard let declared = length else
        {
            return Self.problem(.lengthRequired, "Content-Length is required; chunked uploads are not supported")
        }
        guard declared <= maxUploadBytes else
        {
            // The client keeps this connection, so the body it is still sending has to be read and
            // dropped or the next request on the socket parses out of the middle of it.
            await drain(request)
            return Self.problem(.payloadTooLarge, AssetError.tooLarge(bytes: declared, max: maxUploadBytes))
        }

        let contentType = request.headers[.contentType] ?? AssetStore.defaultContentType
        do
        {
            let id = try await store.store(streaming: request.bodySequence, contentType: contentType, maxBytes: maxUploadBytes)
            logger.info("Stored asset \(id) (\(declared) bytes, \(contentType))")
            return HTTPResponse(
                statusCode: .created,
                headers: [.contentType: "application/json", .location: "/assets/\(id)"],
                body: try JSONEncoder().encode(AssetUploadResponse(id: id))
            )
        }
        catch AssetError.tooLarge(let bytes, let max)
        {
            // Content-Length lied about how much was coming.
            return Self.problem(.payloadTooLarge, AssetError.tooLarge(bytes: bytes, max: max))
        }
        catch
        {
            logger.error("Failed to store asset: \(error)")
            return Self.problem(.internalServerError, "\(error)")
        }
    }

    static func bearerToken(_ header: String?) -> String?
    {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
        let token = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    private func drain(_ request: HTTPRequest) async
    {
        do { for try await _ in request.bodySequence {} }
        catch { logger.debug("Rejected upload disconnected while draining: \(error)") }
    }

    // MARK: - Range requests

    enum RangeRequest: Equatable
    {
        case whole
        case unsatisfiable
        case partial(Range<Int>)
    }

    /// Parse a `Range:` header against a known size. FlyingFox has its own parser but it is
    /// internal, doesn't clamp to the file (an over-long range surfaces as 404 rather than 416) and
    /// ignores suffix ranges. Only the first range of a multi-range header is served, which the
    /// spec permits.
    static func parseRange(_ header: String?, size: Int) -> RangeRequest
    {
        guard let header else { return .whole }
        let spec = (header.split(separator: ",").first?.trimmingCharacters(in: .whitespaces)) ?? ""
        // An unrecognised unit is ignored rather than rejected, per RFC 9110.
        guard spec.hasPrefix("bytes=") else { return .whole }

        let bounds = spec.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return .unsatisfiable }

        switch (Int(bounds[0]), Int(bounds[1]))
        {
        case (nil, let suffix?): // bytes=-N, the last N bytes
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix) ..< size)
        case (let start?, nil): // bytes=N-, from N to the end
            guard start >= 0, start < size else { return .unsatisfiable }
            return .partial(start ..< size)
        case (let start?, let end?): // bytes=N-M, clamped to what we actually have
            guard start >= 0, start <= end, start < size else { return .unsatisfiable }
            // Clamp before incrementing: `min(end + 1, size)` traps on `bytes=0-<Int.max>`, which is
            // a one-line remote crash of the place.
            return .partial(start ..< (end < size ? end + 1 : size))
        case (nil, nil):
            return .unsatisfiable
        }
    }

    // MARK: - Errors

    /// Errors are *returned*, never thrown: a thrown error becomes a blanket 500 and the specific
    /// status the client needs to react to is lost.
    static func problem(_ status: HTTPStatusCode, _ reason: some CustomStringConvertible) -> HTTPResponse
    {
        HTTPResponse(
            statusCode: status,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: Data(reason.description.utf8)
        )
    }
}

/// Response body of `POST /assets`. The place names the asset, having hashed it itself.
struct AssetUploadResponse: Codable
{
    let id: AssetID
}
