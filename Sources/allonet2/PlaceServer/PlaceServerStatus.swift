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
                    

                    /* Core table */
                    table {
                      border-collapse: separate;
                      border-spacing: 0;
                      width: 100%;
                      font: 13px/1.45 system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, Cantarell, Noto Sans, sans-serif;
                      background: #fff;
                      border: 1px solid rgba(0,0,0,.08);
                      border-radius: 12px;
                      box-shadow: 0 1px 2px rgba(0,0,0,.04);
                    }

                    /* Sticky header */
                    table thead th {
                      position: sticky;
                      top: 0;
                      z-index: 1;
                      background: #fafafa;
                      backdrop-filter: saturate(1.2) blur(4px);
                      text-align: left;
                      font-weight: 600;
                      font-size: 12px;
                      letter-spacing: .02em;
                      text-transform: uppercase;
                      color: #444;
                      border-bottom: 1px solid rgba(0,0,0,.08);
                    }

                    /* Cells */
                    table th,
                    table td {
                      padding: 10px 12px;
                      vertical-align: top;
                      border-bottom: 1px solid rgba(0,0,0,.06);
                      max-width: 0;               /* enable truncation if you add text-overflow */
                      word-break: break-word;      /* wrap long emails/names safely */
                    }

                    /* Zebra rows + hover */
                    table tbody tr:nth-child(even) { background: #fcfcfd; }
                    table tbody tr:hover { background: #f5f7ff; }

                    /* Column-specific tweaks (1-based) */
                    table td:nth-child(1) {        /* Client ID */
                      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
                      white-space: nowrap;
                    }

                    table td:nth-child(4) {        /* Revision */
                      font-variant-numeric: tabular-nums;
                      white-space: nowrap;
                    }

                    /* Status cell: make the <br/>-separated lines read like a list */
                    table td:nth-child(5) {        /* Connection status column */
                      font-size: 12px;
                      line-height: 1.35;
                      color: #222;
                      white-space: normal;
                    }

                    /* If you can wrap each status item in a span.badge, this styles them nicely */
                    .badge {
                      display: inline-block;
                      margin: 2px 4px 2px 0;
                      padding: 2px 8px;
                      border-radius: 999px;
                      background: #eef2ff;
                      border: 1px solid #dfe4ff;
                      font-size: 11px;
                      line-height: 1.6;
                    }

                    /* Optional semantic colors if you add .ok / .warn / .err */
                    .badge.ok   { background: #eaffea; border-color: #cfeacc; }
                    .badge.warn { background: #fff6e5; border-color: #ffe3b3; }
                    .badge.err  { background: #ffefef; border-color: #ffd2d2; }
                </style>
                <script type="module">
                    import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
                    mermaid.initialize({ startOnLoad: true });
                </script>
            </head>
            <body>
                <h1>Status for \(server.name)</h1>
                
                <h2>Scenegraph at revision \(server.place.current.revision)</h2>
                <pre class="mermaid">
                    \(sceneGraph)
                </pre>
                
                <h2>Clients</h2>
                
                    \(clientTable)
                
                <h2>Media streams and forwarding state</h2>
                
                    \(sfuTable)
                
            </body>
            </html>
            """
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/html"],
            body: body.data(using: .utf8)!
        )
    }
    
    var sceneGraph: String
    {
        "flowchart TD \n\t\t" +
            server.place.current.entities.values.map { edata in
                compsSubgraph(for: edata)
            }.joined(separator: "\n\t\t") + "\n\t\t" +
            relationships()
    }
    
    func compsSubgraph(for edata: EntityData) -> String
    {
        "subgraph \(edata.id.short) [\(edata.id.short) owner=\(edata.ownerClientId.shortClientId)]\n\t\t\t" +
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
    
    var clientTable: String
    {
        return """
            <table>
                <thead><tr>
                    <th>Client ID</th>
                    <th>Identity</th>
                    <th>Avatar</th>
                    <th width="70">Revision</th>
                    <th>Connection status</th>
                    <th>Streams</th>
                </tr></thead>
            """ +
            server.clients.values.map { client in
                let identity = """
                    \(client.announced ? "<b>Announced</b>" : "<i>Unannounced</i>")<br />
                    Name: \(client.identity?.displayName ?? "Unknown")<br />
                    Email: \(client.identity?.emailAddress ?? "Unknown")
                """
                let status = stateString(for: client.status)
                
                return """
                \t\t\t\t<tr>
                \t\t\t\t    <td>\(client.cid.shortClientId)</td>
                \t\t\t\t    <td>\(identity)</td>
                \t\t\t\t    <td>\(client.avatar?.short ?? "--")</td>
                \t\t\t\t    <td>\(client.ackdRevision ?? -1)</td>
                \t\t\t\t    <td>\(status)</td>
                \t\t\t\t    <td>\(client.session.incomingStreams.values.map {
                    "<span class=\"badge\">\($0.mediaId) <i>\($0.streamDirection)</i></span>"
                }.joined(separator: "\n"))</td>
                \t\t\t\t</tr>
                """
            }.joined(separator: "\n\t\t\t\t") +
            "</table>"
    }
    
    func stateString(for status: ConnectionStatus) -> String
    {
        func spanFor(named name:String, _ state: ConnectionState) -> String
        {
            let badge = switch state {
                case .connected: "ok"
                case .connecting: "warn"
                case .failed: "err"
                case .idle: "err"
            }
            return "<span class=\"badge \(badge)\">\(name): \(state)</span>"
        }
        return spanFor(named: "iceGathering", status.iceGathering) +
            spanFor(named: "signalling", status.signalling) +
            spanFor(named: "iceConnection", status.iceConnection) +
            spanFor(named: "data", status.data)
    }
    
    var sfuTable: String
    {
        let available = """
            <h3>Available streams</h3>
            <table>
                <thead><tr>
                    <th>Source client</th>
                    <th>PlaceStreamId</th>
                </tr></thead>
            """ +
            server.sfu.available.map { (psid, stream) in
                
                return """
                \t\t\t\t<tr>
                \t\t\t\t    <td>\(psid.shortClientId)</td>
                \t\t\t\t    <td>\(psid.outgoingMediaId)</td>
                \t\t\t\t</tr>
                """
            }.joined(separator: "\n\t\t\t\t") +
            "</table>"
        let desired = """
            <h3>Desired stream forwardings</h3>
                <table>
                    <thead><tr>
                        <th>Source stream ID</th>
                        <th>Target client ID</th>
                    </tr></thead>
            """ +
            server.sfu.desired.map { (fi) in
                return """
                \t\t\t\t<tr>
                \t\t\t\t    <td>\(fi.source)</td>
                \t\t\t\t    <td>\(fi.target)</td>
                \t\t\t\t</tr>
                """
            }.joined(separator: "\n\t\t\t\t") +
            "</table>"
        
        let active = """
            <h3>Active stream forwardings</h3>
                <table>
                    <thead><tr>
                        <th>Source stream ID</th>
                        <th>Target client ID</th>
                        <th>SSRC</th>
                        <th>PT</th>
                        <th>Message count</th>
                        <th>Last error</th>
                        <th>Errored at</th>
                    </tr></thead>
            """ +
            server.sfu.active.map { (fi, forwarder) in
                return """
                \t\t\t\t<tr>
                \t\t\t\t    <td>\(fi.source)</td>
                \t\t\t\t    <td>\(fi.target)</td>
                \t\t\t\t    <td>\(forwarder.ssrc)</td>
                \t\t\t\t    <td>\(forwarder.pt)</td>
                \t\t\t\t    <td>\(forwarder.forwardedMessageCount)</td>
                \t\t\t\t    <td>\(forwarder.lastError)</td>
                \t\t\t\t    <td>\(forwarder.lastErrorAt)</td>
                \t\t\t\t</tr>
                """
            }.joined(separator: "\n\t\t\t\t") +
            "</table>"
        
        return "\(available)\n\(desired)\n\(active)"
    }
    
}

extension EntityID {
    var short: Substring
    {
        return split(separator: "-").first!
    }
}
