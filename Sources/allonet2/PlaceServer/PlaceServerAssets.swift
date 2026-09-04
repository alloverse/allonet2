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
    public static let defaultEphemeralTimeToLive: TimeInterval = 120
    public static let defaultEphemeralMaxBytes = 64 * 1024 * 1024
    /// Request header that asks for an ephemeral publish. `1` is the only value that means yes.
    public static let ephemeralHeader = "X-Allo-Ephemeral"
    /// FlyingFox streams file bodies in 4 KiB chunks by default, which is a lot of syscalls for a
    /// 13 MB mesh.
    static let bufferSize = 256 * 1024
    /// RFC 4918 507. FlyingFox has no constant for it, and it is the only status that says "these
    /// bytes are fine, I have nowhere to put them".
    static let insufficientStorage = HTTPStatusCode(507, phrase: "Insufficient Storage")

    let store: AssetStore
    let ephemeral: EphemeralStore
    let maxUploadBytes: Int
    let publishers = PublishTokens()
    private let logger = Logger(labelSuffix: "place.assets")

    public init(directory: URL,
                maxUploadBytes: Int = defaultMaxUploadBytes,
                ephemeralTimeToLive: TimeInterval = defaultEphemeralTimeToLive,
                ephemeralMaxBytes: Int = defaultEphemeralMaxBytes)
    {
        self.store = AssetStore(directory: directory)
        self.maxUploadBytes = maxUploadBytes
        self.ephemeral = EphemeralStore(timeToLive: ephemeralTimeToLive, maximumBytes: ephemeralMaxBytes)
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

    /// Assets the place holds in memory for a couple of minutes and never writes down.
    ///
    /// A screen's thumbnail hashes to a new address every time the picture changes, so keeping
    /// every one of them would grow the assets directory without bound for bytes nobody will ask
    /// for twice. A publisher marks those with `X-Allo-Ephemeral: 1`; fetching one is no different,
    /// and the id is still the hash of the bytes. An entity that keeps referring to an id must not
    /// use this: the fetch 404s once the lease runs out.
    ///
    /// Bounded both ways - an entry expires `timeToLive` seconds after the publish that wrote it,
    /// and the live set is at most `maximumBytes` across every publisher.
    public actor EphemeralStore
    {
        struct Held: Sendable
        {
            let data: Data
            let contentType: String
            let expires: Date
        }

        let timeToLive: TimeInterval
        let maximumBytes: Int
        private var held: [AssetID: Held] = [:]
        private var bytes = 0
        private var sweeper: Task<Void, Never>?

        init(timeToLive: TimeInterval, maximumBytes: Int)
        {
            self.timeToLive = timeToLive
            self.maximumBytes = maximumBytes
        }

        deinit { sweeper?.cancel() }

        /// Hold `data` for `timeToLive` seconds and return its address. Publishing bytes already
        /// held renews their lease, which is how an unchanging picture stays fetchable.
        ///
        /// - Throws: `AssetError.ephemeralStoreFull`, naming the size, what is held and the cap,
        ///   when these bytes do not fit beside the ones that have not expired.
        @discardableResult
        func publish(_ data: Data, contentType: String) throws -> AssetID
        {
            sweep()
            let id = AssetID(hashing: data)
            let addition = held[id] == nil ? data.count : 0
            guard bytes + addition <= maximumBytes else
            {
                throw AssetError.ephemeralStoreFull(bytes: data.count, held: bytes, max: maximumBytes)
            }
            bytes += addition
            held[id] = Held(data: data, contentType: contentType, expires: Date() + timeToLive)
            sweepPeriodically()
            return id
        }

        /// What is held for `id`, or nil once its lease has run out - or if it was never here.
        func entry(for id: AssetID) -> Held?
        {
            guard let entry = held[id], entry.expires > Date() else { return nil }
            return entry
        }

        var byteCount: Int { bytes }

        private func sweep()
        {
            let now = Date()
            for (id, entry) in held where entry.expires <= now
            {
                bytes -= entry.data.count
                held[id] = nil
            }
        }

        /// Expired bytes go when they expire rather than when someone next publishes: a sharer that
        /// left would otherwise stay resident for as long as the place runs. The sweeper stops once
        /// the store is empty, and the next publish starts it again.
        private func sweepPeriodically()
        {
            guard sweeper == nil else { return }
            let interval = max(0.1, timeToLive / 4)
            sweeper = Task { [weak self] in
                while let self
                {
                    try? await Task.sleep(for: .seconds(interval))
                    guard await self.sweepAndKeepGoing() else { return }
                }
            }
        }

        /// - Returns: whether anything is still held, i.e. whether the sweeper has work left.
        private func sweepAndKeepGoing() -> Bool
        {
            sweep()
            if held.isEmpty { sweeper = nil }
            return !held.isEmpty
        }
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

        // Durable first: the same bytes can be published both ways, and an ephemeral lease must
        // not shadow a stored asset's metadata - or expire out from under it.
        let found: AssetStore.Entry?
        do { found = try await store.entry(for: id) }
        catch { return Self.problem(.internalServerError, "\(error)") }
        guard let entry = found else
        {
            guard let held = await ephemeral.entry(for: id) else { return Self.problem(.notFound, AssetError.notFound(id)) }
            return Self.respond(id, with: held, to: request)
        }

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

    /// An ephemeral asset, straight from memory. No `Accept-Ranges`: the bytes are a thumbnail's
    /// worth, and a range of something that expires is not worth the code.
    private static func respond(_ id: AssetID, with held: EphemeralStore.Held, to request: HTTPRequest) -> HTTPResponse
    {
        var headers: HTTPHeaders = [
            .contentType: held.contentType,
            .eTag: "\"\(id)\"",
            // It disappears from under the fetcher, so nothing downstream may keep a copy of it.
            HTTPHeader("Cache-Control"): "no-store",
        ]
        guard request.method != .HEAD else
        {
            headers[.contentLength] = String(held.data.count)
            return HTTPResponse(statusCode: .ok, headers: headers)
        }
        return HTTPResponse(statusCode: .ok, headers: headers, body: held.data)
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
        if request.headers[HTTPHeader(Self.ephemeralHeader)] == "1" { return await hold(request, contentType: contentType) }

        do
        {
            let id = try await store.store(streaming: request.bodySequence, contentType: contentType, maxBytes: maxUploadBytes)
            logger.info("Stored asset \(id) (\(declared) bytes, \(contentType))")
            return try Self.published(id)
        }
        // Both paths below can fail partway through the body — a full disk, say. Whatever is left
        // unread would be parsed as the next request on this socket, so drain it first. That is
        // bounded: FlyingFox stops the sequence at Content-Length, which we checked above.
        catch AssetError.tooLarge(let bytes, let max)
        {
            await drain(request)
            return Self.problem(.payloadTooLarge, AssetError.tooLarge(bytes: bytes, max: max))
        }
        catch
        {
            logger.error("Failed to store asset: \(error)")
            await drain(request)
            return Self.problem(.internalServerError, "\(error)")
        }
    }

    /// The ephemeral half of `upload`: the body is held in memory rather than written down. Read
    /// whole because it is bounded by the Content-Length the caller already checked, and because
    /// hashing it is what names it.
    private func hold(_ request: HTTPRequest, contentType: String) async -> HTTPResponse
    {
        do
        {
            let data = try await request.bodyData
            let id = try await ephemeral.publish(data, contentType: contentType)
            logger.info("Holding ephemeral asset \(id) (\(data.count) bytes, \(contentType))")
            return try Self.published(id)
        }
        catch let error as AssetError
        {
            // The body is already read, so nothing is left on the socket to drain.
            logger.error("Refused ephemeral asset: \(error)")
            return Self.problem(Self.insufficientStorage, error)
        }
        catch
        {
            return Self.problem(.internalServerError, "\(error)")
        }
    }

    /// 201 naming what the place decided to call the bytes, having hashed them itself.
    private static func published(_ id: AssetID) throws -> HTTPResponse
    {
        HTTPResponse(
            statusCode: .created,
            headers: [.contentType: "application/json", .location: "/assets/\(id)"],
            body: try JSONEncoder().encode(AssetUploadResponse(id: id))
        )
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
