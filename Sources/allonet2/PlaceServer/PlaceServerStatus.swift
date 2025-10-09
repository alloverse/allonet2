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
            server.place.current.entities.values.map {
                let short = $0.id.split(separator:"-").first!
                return "\($0.id)[\"\(short)\"]"
            }.joined(separator: "\n\t\t") + "\n\t\t" +
            server.place.current.components[Relationships.self].map {
                let parent = $0.value.parent
                let child = $0.key
                return "\(parent) --> \(child)"
            }.joined(separator: "\n\t\t")
    }
}
