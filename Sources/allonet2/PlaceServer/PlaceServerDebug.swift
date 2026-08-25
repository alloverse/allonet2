//
//  PlaceServerDebug.swift
//  allonet2
//
//  A snapshot of the place's entities and their components as JSON, for debugging and
//  integration verification. Replaces the standalone `placeprobe` tool, which had to connect
//  as an app and observe the synced state just to read it back out; this reads it at the source.
//

import Foundation
import FlyingFox

/// `GET /debug/entities`: dumps every entity as `{ id, owner, components }`, mirroring what
/// placeprobe emitted. Gated on the place's app token (`-t`), the same secret that grants app
/// privileges: pass it as `Authorization: Bearer <token>` or `?token=<token>`.
///
/// A place with no app token authenticates every app that asks, so there is no secret to gate on
/// and the dump would be world-readable; it is refused entirely in that case rather than exposed.
@MainActor
final class PlaceServerDebug
{
    /// The place's app token. Empty means the place trusts any app, so the endpoint is disabled.
    private let appToken: String
    /// The live world state to dump, read fresh on each request.
    private let contents: @MainActor () -> PlaceContents

    init(appToken: String, contents: @escaping @MainActor () -> PlaceContents)
    {
        self.appToken = appToken
        self.contents = contents
    }

    /// Wire floats are whatever a peer put there; a non-finite one should show up in the dump rather
    /// than fail the encode of the entity that carries it.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    func register(on http: HTTPServer) async
    {
        await http.appendRoute("GET /debug/entities") { [self] in await entities($0) }
    }

    func entities(_ request: HTTPRequest) async -> HTTPResponse
    {
        guard !appToken.isEmpty else
        {
            return Self.problem(.forbidden, "The entity dump is disabled: this place has no app token (-t) to authenticate against, so it would be world-readable.")
        }
        let presented = PlaceServerAssets.bearerToken(request.headers[.authorization]) ?? request.query["token"]
        guard presented == appToken else
        {
            return Self.problem(.unauthorized, "The entity dump requires the place's app token via 'Authorization: Bearer <token>' or '?token='.")
        }

        let contents = contents()
        let entities: [[String: Any]] = contents.entities.keys.sorted().map { id in
            [
                "id": id,
                "owner": contents.entities[id]!.ownerClientId.uuidString,
                "components": contents.components.componentsForEntity(id).mapValues { json(of: $0) },
            ]
        }
        let payload: [String: Any] = ["revision": contents.revision, "entities": entities]
        do
        {
            return HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "application/json"],
                body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        }
        catch
        {
            return Self.problem(.internalServerError, "\(error)")
        }
    }

    /// A registered component is reported as its concrete JSON; one whose type isn't compiled into
    /// this place survives as its wire value under a typed fallback, so nothing is silently dropped.
    /// Re-encoding an `AnyValue` through `JSONSerialization` needs the native `unwrapped` tree — its
    /// own `Codable` flattens dictionaries into alternating key/value arrays.
    private func json(of component: AnyComponent) -> Any
    {
        if let decoded = component.decodedIfAvailable()
        {
            do { return try JSONSerialization.jsonObject(with: encoder.encode(decoded), options: [.fragmentsAllowed]) }
            catch { return ["encodeError": "\(error)"] }
        }
        var result: [String: Any] = ["unregisteredType": component.componentTypeId]
        if let fields = component.anyValue.unwrapped, JSONSerialization.isValidJSONObject(fields) {
            result["fields"] = fields
        } else {
            result["description"] = String(describing: component.anyValue)
        }
        return result
    }

    /// Errors are *returned*, never thrown: a thrown error becomes a blanket 500 and the specific
    /// status the client needs is lost. Mirrors `PlaceServerAssets.problem`.
    private static func problem(_ status: HTTPStatusCode, _ reason: some CustomStringConvertible) -> HTTPResponse
    {
        HTTPResponse(
            statusCode: status,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: Data(reason.description.utf8)
        )
    }
}
