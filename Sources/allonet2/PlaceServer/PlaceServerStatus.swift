//
//  PlaceServerStatus.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-10-09.
//

import Foundation
import FlyingFox

@MainActor
struct PlaceServerStatus
{
    weak var server: PlaceServer!
    let place: Place
    
    init(server: PlaceServer!)
    {
        self.server = server
        self.place = Place(state: server.place, client: nil)
    }
    
    func page(_ request: HTTPRequest) async -> HTTPResponse
    {
        let body = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Status for \(server.name)</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                        padding: 2em;
                        margin: auto;
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
                    .nodeLabel { 
                        text-align: left !important;
                        font-family: monospace;
                        white-space: pre;
                    }
                </style>
                <script type="module">
                    import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
                    mermaid.initialize({ startOnLoad: true });
                </script>
            </head>
            <body>
                <h1>Status for \(server.name)</h1>
                
                <h2>Scenegraph</h2>
                <pre class="mermaid">
                    \(sceneGraph)
                </pre>
                
                <h2>Clients</h2>
                
                // todo
                
                <h2>Media streams and forwarding state</h2>
                
                // todo
                
            </body>
            </html>
            """
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/html"],
            body: body.data(using: .utf8)!
        )
    }
    
    var sceneGraph: String {
        "flowchart TD \n\t\t" +
            server.place.current.entities.values.map { edata in
                compsSubgraph(for: edata)
            }.joined(separator: "\n\t\t") + "\n\t\t" +
            relationships()
    }
    
    func compsSubgraph(for edata: EntityData) -> String
    {
        "subgraph \(edata.id.short)\n\t\t\t" +
        server.place.current.components.componentsForEntity(edata.id).map { (cname, comp) in
            let cdesc = comp.indentedDescription("").replacingOccurrences(of: "\"", with: "")
            return "\(edata.id.short)_\(cname)[\"` <pre><code>\(cdesc)</pre></code> `\"]"
        }.joined(separator: "\n\t\t\t") +
        "\n\t\tend"
    }
    
    func relationships() -> String
    {
        server.place.current.components[Relationships.self].map {
            let parent = $0.value.parent
            let child = $0.key
            return "\(parent.short) --> \(child.short)"
        }.joined(separator: "\n\t\t")
    }
}

extension EntityID {
    var short: Substring
    {
        return split(separator: "-").first!
    }
}
