//
//  PlaceServerDebug.swift
//  allonet2
//

import Foundation
import FlyingFox

/// Serves `GET /debug/entities`: a JSON snapshot `{ revision, entities: [{ id, owner, components }] }`.
/// Gated on the place's app token (`-t`) via `Authorization: Bearer <token>` or `?token=<token>`. A
/// place with no token trusts any app, so there is nothing to gate on and the endpoint refuses.
@MainActor
final class PlaceServerDebug
{
    /// Empty disables the endpoint: nothing to gate on.
    private let appToken: String
    private let contents: @MainActor () -> PlaceContents

    init(appToken: String, contents: @escaping @MainActor () -> PlaceContents)
    {
        self.appToken = appToken
        self.contents = contents
    }

    /// A non-finite wire float becomes a string rather than failing the whole entity's encode.
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

    /// Registered types dump as concrete JSON; unknown ones fall back to their wire value, which needs
    /// `AnyValue.unwrapped` — its own `Codable` flattens dictionaries to key/value arrays.
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

    /// Returned, not thrown: a thrown error is a blanket 500, losing the status the client needs.
    private static func problem(_ status: HTTPStatusCode, _ reason: some CustomStringConvertible) -> HTTPResponse
    {
        HTTPResponse(
            statusCode: status,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: Data(reason.description.utf8)
        )
    }
}
