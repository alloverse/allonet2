//
//  PlaceServer+HTTP.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//

import Foundation
import FlyingFox
import FlyingFoxMacros

public struct AppDescription
{
    public let name: String
    public let downloadURL: String
    public let URLProtocol: String
    public init(name: String, downloadURL: String, URLProtocol: String) { self.name = name; self.downloadURL = downloadURL; self.URLProtocol = URLProtocol }
    public static var alloverse: Self { AppDescription(name: "Alloverse", downloadURL: "https://alloverse.com/download", URLProtocol: "alloplace2") }
}

@MainActor
@HTTPHandler
class PlaceServerHTTP
{
    private var http: HTTPServer! = nil
    private let appDescription: AppDescription
    private var status: PlaceServerStatus!
    private unowned let server: PlaceServer
    private let port: UInt16
    
    init(server: PlaceServer, port: UInt16, appDescription: AppDescription)
    {
        self.server = server
        self.status = PlaceServerStatus(server: server)
        self.port = port
        self.appDescription = appDescription
    }
    func start() async throws
    {
        self.http = HTTPServer(port: port, handler: self)
        // Routes are also added with @HTTPRoute/@JSONRoute, see below.
        await http.appendRoute("GET /dashboard", to: self.status)
        await http.appendRoute("GET /dashboard/*", to: self.status)
            
        try await http.start()
    }
    
    func stop() async
    {
        await http.stop()
    }
    
    @HTTPRoute("GET /")
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
    
    @JSONRoute("POST /")
    func handleIncomingClient(_ request: HTTPRequest) async throws -> SignallingPayload
    {
        let offer = try await JSONDecoder().decode(SignallingPayload.self, from: request.bodyData)
        
        let connectionStatus = ConnectionStatus()
        let transport = server.transportClass.init(with: server.options, status: connectionStatus)
        let session = AlloSession(side: .server, transport: transport)
        session.delegate = server
        let client = ConnectedClient(session: session, status: connectionStatus)
        
        client.logger.info("Received new client \(client.cid)")
        session.transport.clientId = client.cid
        server.unannouncedClients[client.cid] = client
        
        let response = try await session.generateAnswer(offer: offer)
        client.logger.info("Client is \(session.clientId!), sending answer...")
        
        return response
    }
}
