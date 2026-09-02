//
//  PlaceServer+HTTP.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation
import FlyingFox
import Version

public struct AppDescription
{
    public let name: String
    public let downloadURL: String
    public let URLProtocol: String
    public init(name: String, downloadURL: String, URLProtocol: String) { self.name = name; self.downloadURL = downloadURL; self.URLProtocol = URLProtocol }
    public static var alloverse: Self { AppDescription(name: "Alloverse", downloadURL: "https://alloverse.com/download", URLProtocol: "alloplace2") }

    /// What a client rejected for its allonet version is shown. The first line is the user's
    /// action in the app's own terms; the second names both allonet versions, so a screenshot
    /// still tells support which pair collided.
    public func incompatibilityMessage(client: Version, server: Version) -> String
    {
        let advice = client < server
            ? "Your \(name) app is too old for this place. Update it from \(downloadURL)"
            : "This place runs an older version than your \(name) app. Ask whoever runs it to update it."
        return "\(advice)\n\nApp allonet \(client), place allonet \(server)."
    }
}

@MainActor
class PlaceServerHTTP
{
    /// Generous compared to FlyingFox's 15s default, which bounds the *whole* request including an
    /// asset upload's body: a multi-megabyte mesh over a slow link would otherwise die as a 500.
    nonisolated static let requestTimeout: TimeInterval = 120

    private var http: HTTPServer! = nil
    private let appDescription: AppDescription
    private var status: PlaceServerStatus!
    private var debug: PlaceServerDebug!
    let assets: PlaceServerAssets
    private unowned let server: PlaceServer
    private let port: UInt16

    init(server: PlaceServer, port: UInt16, appDescription: AppDescription, assetsDirectory: URL)
    {
        self.server = server
        self.status = PlaceServerStatus(server: server)
        self.debug = PlaceServerDebug(appToken: server.alloAppAuthToken) { [unowned server] in server.place.current }
        self.port = port
        self.appDescription = appDescription
        self.assets = PlaceServerAssets(directory: assetsDirectory)
    }
    func start() async throws
    {
        self.http = HTTPServer(port: port, timeout: Self.requestTimeout)
        await self.http.appendRoute("GET /") { return try await self.landingPage($0) }
        await self.http.appendRoute("POST /") { return try await self.handleIncomingClient($0) }
        try await self.status.start(on: http)
        await self.debug.register(on: http)
        await self.assets.register(on: http)

        try await http.start()
    }

    func stop() async
    {
        await http?.stop()
    }
    
    func landingPage(_ request: HTTPRequest) async -> HTTPResponse
    {
        let host = request.headers[.host] ?? "localhost"
        let path = request.path
        var proto = appDescription.URLProtocol
        if !host.contains(":") { proto += "s" } // no custom port = _likely_ https
        
        let body = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>\(server.name)</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                        padding: 2em;
                        max-width: 600px;
                        margin: auto;
                        line-height: 1.6;
                    }
                    a.button {
                        display: inline-block;
                        padding: 0.75em 1.5em;
                        margin-top: 1em;
                        background: #007aff;
                        color: white;
                        text-decoration: none;
                        border-radius: 8px;
                    }
                </style>
            </head>
            <body>
                <h1>Welcome to \(server.name).</h1>
                <p>You need to <a href="\(appDescription.downloadURL)">install the \(appDescription.name) app</a> to connect to this virtual place.</p>
                <p>Already have \(appDescription.name)?<br/> <a class="button" href="\(proto)://\(host)\(path)">Open <i>\(server.name)</i> in \(appDescription.name)</a></p>
            </body>
            </html>
            """
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/html"],
            body: body.data(using: .utf8)!
        )
    }
    
    func handleIncomingClient(_ request: HTTPRequest) async throws -> HTTPResponse
    {
        let offer = try await JSONDecoder().decode(SignallingPayload.self, from: request.bodyData)
        
        let connectionStatus = ConnectionStatus()
        let transport = DataChannelTransport(with: server.options, status: connectionStatus)
        let session = AlloSession(side: .server, transport: transport)
        session.delegate = server
        let client = ConnectedClient(session: session, status: connectionStatus)
        
        client.logger.info("Received new client \(client.cid)")
        session.transport.clientId = client.cid
        server.unannouncedClients[client.cid] = client
        
        let response = try await session.generateAnswer(offer: offer)
        client.logger.info("Client is \(session.clientId!), sending answer...")
        
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: try await JSONEncoder().encode(response)
        )
    }
}
