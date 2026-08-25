import Testing
import Foundation
import FlyingFox
@testable import allonet2

/// A component type deliberately never registered with the `ComponentRegistry`, so the endpoint
/// takes its unregistered-fallback path — the case placeprobe carried across the process boundary.
private struct DebugUnregisteredComponent: Component
{
    var secret: String
    var n: Int
}

/// The place's app token in these tests; the secret that unlocks the dump.
private let debugToken = "debug-token"

// MARK: - Over a real socket
// A bound port rather than calling the handler directly: FlyingFox only populates the request's
// query and headers through its own router, and the auth gate reads both.

@Suite(.serialized)
@MainActor
struct DebugEntitiesHTTPTests
{
    /// One entity carrying a registered component (dumped as its concrete JSON) and an unregistered
    /// one (dumped under the typed fallback).
    private func sampleContents(owner: UUID) -> PlaceContents
    {
        TestComponent.register() // deterministic: another suite's setUp might not have run
        return PlaceContents(
            revision: 42,
            entities: ["e1": EntityData(id: "e1", ownerClientId: owner)],
            components: ComponentLists(lists: [
                TestComponent.componentTypeId: ["e1": AnyComponent(TestComponent(radius: 3.5))],
                DebugUnregisteredComponent.componentTypeId: ["e1": AnyComponent(DebugUnregisteredComponent(secret: "hush", n: 7))],
            ]),
            logger: testLogger
        )
    }

    /// A debug endpoint on an ephemeral port, torn down when `body` returns.
    private func withDebugServer(
        appToken: String = debugToken,
        contents: @escaping @MainActor () -> PlaceContents,
        _ body: (URL) async throws -> Void
    ) async throws
    {
        let debug = PlaceServerDebug(appToken: appToken, contents: contents)
        let http = HTTPServer(port: 0, timeout: PlaceServerHTTP.requestTimeout)
        await debug.register(on: http)

        let running = Task { try await http.run() }
        try await http.waitUntilListening(timeout: 5)
        defer { running.cancel() }

        guard case .ip6(_, port: let port)? = await http.listeningAddress else {
            Issue.record("server did not report an IPv6 port")
            return
        }

        do { try await body(URL(string: "http://localhost:\(port)")!) }
        catch { await http.stop(); throw error }
        await http.stop()
    }

    private func get(_ base: URL, bearer: String? = nil, query: String? = nil) async throws -> (HTTPURLResponse, Data)
    {
        var path = "/debug/entities"
        if let query { path += "?token=\(query)" }
        var request = URLRequest(url: URL(string: "\(base)\(path)")!)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse, data)
    }

    // MARK: Auth gate

    /// The token that grants app privileges is the one that unlocks the dump; nothing else does.
    @Test func gatesOnTheAppToken() async throws
    {
        try await withDebugServer(contents: { self.sampleContents(owner: UUID()) }) { base in
            let (anonymous, _) = try await get(base)
            #expect(anonymous.statusCode == 401)

            let (wrong, _) = try await get(base, bearer: "not-the-token")
            #expect(wrong.statusCode == 401)

            let (bearer, _) = try await get(base, bearer: debugToken)
            #expect(bearer.statusCode == 200)

            let (queried, _) = try await get(base, query: debugToken)
            #expect(queried.statusCode == 200)
        }
    }

    /// A place with no app token authenticates every app, so there is no secret to gate on and the
    /// dump would be world-readable. It is refused outright rather than exposed.
    @Test func refusesWhenNoAppTokenIsConfigured() async throws
    {
        try await withDebugServer(appToken: "", contents: { self.sampleContents(owner: UUID()) }) { base in
            let (anonymous, _) = try await get(base)
            #expect(anonymous.statusCode == 403)
            // Even presenting the empty token doesn't open it.
            let (empty, _) = try await get(base, bearer: "")
            #expect(empty.statusCode == 403)
        }
    }

    // MARK: JSON shape

    /// One object per entity: id, owner, and a components map. A registered component is its concrete
    /// JSON; an unregistered one is a typed fallback carrying its wire fields.
    @Test func dumpsEntitiesAndComponentsInPlaceprobeShape() async throws
    {
        let owner = UUID()
        try await withDebugServer(contents: { self.sampleContents(owner: owner) }) { base in
            let (response, body) = try await get(base, bearer: debugToken)
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(root["revision"] as? Int == 42)

            let entities = try #require(root["entities"] as? [[String: Any]])
            #expect(entities.count == 1)
            let entity = entities[0]
            #expect(entity["id"] as? String == "e1")
            #expect(entity["owner"] as? String == owner.uuidString)

            let components = try #require(entity["components"] as? [String: Any])

            // Registered: dumped as the concrete component's own JSON.
            let transform = try #require(components["TestComponent"] as? [String: Any])
            #expect(transform["radius"] as? Double == 3.5)

            // Unregistered: typed fallback with the wire fields, nothing silently dropped.
            let unknown = try #require(components["DebugUnregisteredComponent"] as? [String: Any])
            #expect(unknown["unregisteredType"] as? String == "DebugUnregisteredComponent")
            let fields = try #require(unknown["fields"] as? [String: Any])
            #expect(fields["secret"] as? String == "hush")
            #expect(fields["n"] as? Int == 7)
        }
    }
}
