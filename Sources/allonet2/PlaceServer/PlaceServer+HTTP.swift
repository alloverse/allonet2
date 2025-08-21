//
//  PlaceServer+HTTP.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-08-21.
//
import FlyingFox
import Foundation

public struct AppDescription
{
    public let name: String
    public let downloadURL: String
    public let URLProtocol: String
    public init(name: String, downloadURL: String, URLProtocol: String) { self.name = name; self.downloadURL = downloadURL; self.URLProtocol = URLProtocol }
    public static var alloverse: Self { AppDescription(name: "Alloverse", downloadURL: "https://alloverse.com/download", URLProtocol: "alloplace2") }
}

extension PlaceServer
{
    public func start() async throws
    {
        let myIp = options.ipOverride?.to ?? "localhost"
        print("Serving '\(name)' at http://\(myIp):\(httpPort)/ and UDP ports \(options.portRange)")

        // On incoming connection, create a WebRTC socket.
        await http.appendRoute("POST /", handler: self.handleIncomingClient)
        await http.appendRoute("GET /", handler: self.landingPage)
            
        try await http.start()
    }
    
    public func stop() async
    {
        await http.stop()
        for client in Array(clients.values) + Array(unannouncedClients.values)
        {
            client.session.disconnect()
        }
    }
    
    @Sendable
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
                <title>\(name)</title>
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
                <h1>Welcome to \(name).</h1>
                <p>You need to <a href="\(appDescription.downloadURL)">install the \(appDescription.name) app</a> to connect to this virtual place.</p>
                <p>Already have \(appDescription.name)?<br/> <a class="button" href="\(proto)://\(host)\(path)">Open <i>\(name)</i> in \(appDescription.name)</a></p>
            </body>
            </html>
            """
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/html"],
            body: body.data(using: .utf8)!
        )
    }
    
    @Sendable
    func handleIncomingClient(_ request: HTTPRequest) async throws -> HTTPResponse
    {
        let offer = try await JSONDecoder().decode(SignallingPayload.self, from: request.bodyData)
            
        let transport = transportClass.init(with: options, status: connectionStatus)
        let session = AlloSession(side: .server, transport: transport)
        session.delegate = self
        let client = ConnectedClient(session: session)
        
        print("Received new client")
        
        let response = try await session.generateAnswer(offer: offer)
        self.unannouncedClients[session.clientId!] = client
        print("Client is \(session.clientId!), shaking hands...")
        
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: try! JSONEncoder().encode(response)
        )
    }
}
