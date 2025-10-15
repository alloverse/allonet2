//
//  PlaceServerStatus.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-10-09.
//

import Foundation
import FlyingFox
import FlyingFoxMacros

@MainActor
@HTTPHandler
class PlaceServerStatus: WSMessageHandler
{
    weak var server: PlaceServer!
    let place: Place
    
    init(server: PlaceServer!)
    {
        self.server = server
        self.place = Place(state: server.place, client: nil)
    }
    
    func start(on http: HTTPServer) async throws
    {
        await http.appendRoute("GET /dashboard", to: self)
        await http.appendRoute("GET /dashboard/*", to: self)
        await http.appendRoute("GET /dashboard/logs/follow", to: .webSocket(self))
    }
    
    // MARK: Status page
    @HTTPRoute("dashboard")
    func index(_ request: HTTPRequest) async -> HTTPResponse
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
    
// - MARK: Logs
    @HTTPRoute("dashboard/logs")
    func logs(_ request: HTTPRequest) async -> HTTPResponse
    {
        let host = request.headers[.host] ?? "localhost"
        let body = """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width,initial-scale=1" />
            <title>Live Log Viewer</title>
            <style>
              :root{
                /* Light / pastel palette */
                --bg: #f6f7fb;
                --panel: #ffffff;
                --muted: #6b7280;
                --text: #0b1220;
                --border: #e5e7eb;
                --accent: #6a87ff;
                --chip-bg: #f3f5fb;
                --chip-text: #2f3b55;

                /* Pastel level colors */
                --trace: #8b8f99;
                --debug: #6aa9ff;
                --info:  #38bdf8;
                --notice:#22c55e;
                --warn:  #f59e0b;
                --error: #ef4444;
                --crit:  #e11d48;

                --shadow: 0 10px 30px rgba(15, 23, 42, .06);
                --radius: 14px;
                --radius-sm: 10px;
                --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
                --sans: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, "Helvetica Neue", Arial, "Apple Color Emoji","Segoe UI Emoji";
              }
              * { box-sizing: border-box }
              html, body {
                height: 100%;
                margin: 0;
                background:
                  radial-gradient(1200px 600px at 70% -100px, #eef1f8 0%, #f6f7fb 60%) fixed;
                color: var(--text);
                font-family: var(--sans);
              }
              .wrap {
                display: grid;
                grid-template-rows: auto auto 1fr;
                gap: 14px;
                height: 100%;
                padding: 16px;
              }
              header {
                display: grid;
                grid-template-columns: 1fr auto;
                gap: 12px;
                align-items: center;
              }
              .card {
                background: var(--panel);
                border: 1px solid var(--border);
                border-radius: var(--radius);
                box-shadow: var(--shadow);
              }
              .toolbar {
                display: grid;
                grid-template-columns: 1fr auto;
                gap: 10px;
                padding: 12px;
              }
              .row { display:flex; gap:12px; flex-wrap:wrap; align-items:center }

              input[type="text"] {
                width: 100%;
                background: #fff;
                border: 1px solid var(--border);
                color: var(--text);
                border-radius: 10px;
                padding: 10px 12px;
                outline: none;
                font: 500 14px/1.2 var(--sans);
              }
              input[type="text"]::placeholder { color: #9aa3af }

              .btn {
                appearance: none;
                border: 1px solid var(--border);
                background: linear-gradient(180deg, #ffffff, #f7f8fb);
                color: var(--text);
                padding: 10px 12px;
                border-radius: 10px;
                font: 600 14px/1 var(--sans);
                cursor: pointer;
              }
              .btn:disabled { opacity:.6; cursor: not-allowed }
              .btn.primary {
                border-color: color-mix(in srgb, var(--accent) 35%, var(--border));
                background: linear-gradient(180deg,
                  color-mix(in srgb, var(--accent) 12%, #ffffff),
                  color-mix(in srgb, var(--accent) 6%, #f7f8fb)
                );
              }

              .status {
                display:flex; align-items:center; gap:8px; padding:0 12px;
                font: 500 13px/1 var(--sans); color: var(--muted);
              }
              .dot{
                width: 10px; height: 10px; border-radius: 50%;
                box-shadow: 0 0 0 2px rgba(0,0,0,.05) inset, 0 0 10px currentColor;
              }
              .dot.gray{ color:#9ca3af; background:#9ca3af }
              .dot.green{ color:#22c55e; background:#22c55e }
              .dot.yellow{ color:#f59e0b; background:#f59e0b }
              .dot.red{ color:#ef4444; background:#ef4444 }

              .logs {
                overflow: auto;
                padding: 8px;
                border-radius: var(--radius);
                background: linear-gradient(#ffffff, #ffffff) padding-box;
                border: 1px solid var(--border);
                min-height: 0;
              }

              .line {
                font: 13px/1.5 var(--mono);
                color: var(--text);
                background: #fbfdff;
                border: 1px solid var(--border);
                border-radius: var(--radius-sm);
                margin: 6px 4px;
                padding: 8px 10px;
                transition: background .15s, border-color .15s, box-shadow .15s, transform .02s;
                cursor: pointer;         /* whole row is clickable in this theme */
              }
              .line:hover { background: #f3f7ff; border-color: #dbe2ea }
              .line:active { transform: translateY(0.5px) }
              .line.expanded { background: #eef4ff; border-color: #cfd9e6 }

              .head {
                display:flex; align-items:center; gap:8px; flex-wrap:wrap;
                white-space: pre-wrap; word-break: break-word;
              }
              .msg { flex: 1 1 auto }

              .chip {
                display: inline-flex; align-items: center; gap: 6px;
                padding: 3px 8px; border-radius: 999px;
                border: 1px solid var(--border);
                background: var(--chip-bg);
                color: var(--chip-text);
                font: 700 11px/1 var(--sans);
                text-transform: uppercase; letter-spacing:.06em;
                user-select: none;
              }
              .chip.level.trace { background:#f4f6fa; color:var(--trace); border-color:#e6eaf2 }
              .chip.level.debug { background:#eef5ff; color:var(--debug); border-color:#dae7ff }
              .chip.level.info  { background:#e9f8ff; color:var(--info);  border-color:#cfefff }
              .chip.level.notice{ background:#eafcf1; color:var(--notice);border-color:#d7f6e2 }
              .chip.level.warning{ background:#fff7e6; color:var(--warn); border-color:#ffe9bd }
              .chip.level.error { background:#ffecec; color:var(--error); border-color:#ffd3d6 }
              .chip.level.critical { background:#ffe8ef; color:var(--crit); border-color:#ffd0db }

              .chip.source { text-transform:none; font-weight:600; color:#475569; background:#f4f6fb }

              /* Metadata visibility is controlled by .expanded on the row */
              .meta {
                margin-top: 8px;
                border-top: 1px dashed #d7dbe3;
                padding-top: 8px;
                font: 12px/1.45 var(--mono);
                color: #374151;
                display: none;
              }
              .line.expanded .meta { display: block }

              .meta table { border-collapse: collapse; width: 100% }
              .meta th, .meta td { text-align:left; padding:6px 4px; vertical-align:top }
              .meta tr { border-bottom: 1px dashed #e6eaf2 }
              .meta th { color:#6b7280; font-weight:600; width:160px; white-space:nowrap }
              .pill {
                padding: 2px 6px; border-radius: 6px;
                background: #f1f5ff; border: 1px solid #dbe4ff; color: #31427a;
              }

              .foot {
                display:flex; align-items:center; justify-content: space-between;
                gap: 10px; padding: 10px 12px; color: var(--muted); font: 12px/1 var(--sans);
                border-top: 1px solid var(--border);
              }
              .lhs, .rhs { display:flex; align-items:center; gap:10px; flex-wrap:wrap }
              label { display:inline-flex; align-items:center; gap:8px; font-size:13px; color:#4b5563 }
              .small { font-size: 12px; color: var(--muted) }
              kbd {
                background:#f7f9fe; border:1px solid #e5e9f5; border-bottom-color:#dfe4f2;
                border-radius: 6px; padding: 2px 6px; font: 600 12px/1 var(--mono); color:#334155;
                box-shadow: 0 1px 0 rgba(255,255,255,.7) inset;
              }
            </style>
            </head>
            <body>
              <div class="wrap">
                <header>
                  <div class="row">
                    <div class="status"><span id="statusDot" class="dot gray"></span><span id="statusText">Disconnected</span></div>
                  </div>
                </header>

                <div class="card">
                  <div class="toolbar" style="padding-top:0">
                    <input id="filterInput" type="text" placeholder="Filter… (matches message, source, metadata) • Regex supported with /.../i" />
                    <div class="row">
                      <label title="If enabled, the view auto-scrolls only when already at the bottom.">
                        <input id="pinCheck" type="checkbox" checked /> Autoscroll
                      </label>
                    </div>
                  </div>
                </div>

                <div id="logContainer" class="logs card" aria-label="Log output" role="log"></div>

                <div class="card foot">
                  <div class="lhs">
                    <span id="counts" class="small">0 shown • 0 total</span>
                  </div>
                  <div class="rhs small">
                    <span>Keyboard: <kbd>F</kbd> focus filter • <kbd>Esc</kbd> clear</span>
                  </div>
                </div>
              </div>

            <script>
            (() => {
              /** ---------- State ---------- **/
              const levels = ["trace","debug","info","notice","warning","error","critical"];
              const levelOrder = Object.fromEntries(levels.map((l,i)=>[l,i]));
              const store = { all: [], filtered: [], regex: null, text: "" };
              let mockTimer = null;

              const FIXED_WS = 'ws://\(host)/dashboard/logs/follow';
              let ws = null;

              /** ---------- Dom ---------- **/
              const el = {
                container: document.getElementById('logContainer'),
                filter: document.getElementById('filterInput'),
                pinCheck: document.getElementById('pinCheck'),
                counts: document.getElementById('counts'),
                statusDot: document.getElementById('statusDot'),
                statusText: document.getElementById('statusText'),
                mockBtn: document.getElementById('mockBtn'),
              };

              /** ---------- Utilities ---------- **/
              const atBottom = () => {
                const c = el.container;
                return c.scrollTop + c.clientHeight >= c.scrollHeight - 8;
              };
              const scrollToBottom = () => {
                el.container.scrollTop = el.container.scrollHeight;
              };

              const setStatus = (state, text) => {
                const map = { disconnected:'gray', connecting:'yellow', connected:'green', error:'red' };
                el.statusDot.className = 'dot ' + (map[state] || 'gray');
                el.statusText.textContent = text || state[0].toUpperCase()+state.slice(1);
              };

              const debounce = (fn, ms=150) => {
                let t; return (...args) => { clearTimeout(t); t = setTimeout(()=>fn(...args), ms); };
              };

              const tryParse = (x) => {
                if (typeof x === 'object' && x !== null) return x;
                try { return JSON.parse(x); } catch { return null; }
              };

              const normLevel = (lvl) => {
                if (!lvl) return 'info';
                const s = String(lvl).toLowerCase();
                if (s === 'warn') return 'warning';
                if (levels.includes(s)) return s;
                return 'info';
              };

              const textFromLog = (log) => {
                const parts = [
                  log.message ?? '',
                  log.source ?? '',
                  ...Object.entries(log.metadata || {}).flatMap(([k,v]) => [k, String(v)])
                ];
                return parts.join(' ').toLowerCase();
              };

              const buildRegex = (q) => {
                q = q.trim();
                if (!q) return null;
                // Allow /pattern/flags style, else plain text (escaped)
                const m = q.match(/^\\/(.+)\\/([a-z]*)$/i);
                if (m) {
                  try { return new RegExp(m[1], m[2]); } catch { /* fall through */ }
                }
                const esc = q.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&');
                return new RegExp(esc, 'i');
              };

              /** ---------- Rendering ---------- **/
              const renderLine = (log) => {
                const line = document.createElement('div');
                line.className = 'line';
                line.dataset.level = log.level;
                line.dataset.source = log.source || '';

                const head = document.createElement('div');
                head.className = 'head';

                const levelChip = document.createElement('span');
                levelChip.className = `chip level ${log.level}`;
                levelChip.textContent = log.level;

                const sourceChip = document.createElement('span');
                sourceChip.className = 'chip source';
                sourceChip.textContent = log.source || 'unknown';

                const msg = document.createElement('span');
                msg.className = 'msg';
                msg.textContent = log.message ?? '';

                head.append(levelChip, sourceChip, msg);
                line.appendChild(head);

                // Build metadata section (hidden by default; CSS shows it when .expanded is on the row)
                if (log.metadata && Object.keys(log.metadata).length) {
                  const meta = document.createElement('div');
                  meta.className = 'meta';
                  const table = document.createElement('table');
                  for (const [k, v] of Object.entries(log.metadata)) {
                    const tr = document.createElement('tr');
                    const th = document.createElement('th'); th.textContent = k;
                    const td = document.createElement('td');
                    if (v && typeof v === 'object') {
                      const pre = document.createElement('pre');
                      pre.textContent = JSON.stringify(v, null, 2);
                      td.appendChild(pre);
                    } else {
                      const span = document.createElement('span');
                      span.className = 'pill';
                      span.textContent = String(v);
                      td.appendChild(span);
                    }
                    tr.append(th, td);
                    table.appendChild(tr);
                  }
                  meta.appendChild(table);
                  line.appendChild(meta);
                }

                // Toggle expansion on row click; if user clicks inside metadata, don’t re-collapse immediately
                line.addEventListener('click', (e) => {
                  // Allow text selection without toggling when dragging
                  if (window.getSelection && String(window.getSelection())) return;
                  // If click is inside links or inputs, ignore
                  const tag = (e.target.tagName || '').toLowerCase();
                  if (['a','button','input','textarea','select','label'].includes(tag)) return;
                  line.classList.toggle('expanded');
                });

                return line;
              };

              const renderMeta = (metadata) => {
                const det = document.createElement('details');
                const sum = document.createElement('summary');
                sum.innerHTML = 'Show metadata';
                const meta = document.createElement('div');
                meta.className = 'meta';

                const table = document.createElement('table');
                for (const [k, v] of Object.entries(metadata)) {
                  const tr = document.createElement('tr');
                  const th = document.createElement('th'); th.textContent = k;
                  const td = document.createElement('td');

                  // Render objects/arrays prettily
                  if (v && typeof v === 'object') {
                    const pre = document.createElement('pre');
                    pre.textContent = JSON.stringify(v, null, 2);
                    td.appendChild(pre);
                  } else {
                    const span = document.createElement('span');
                    span.className = 'pill';
                    span.textContent = String(v);
                    td.appendChild(span);
                  }
                  tr.append(th, td);
                  table.appendChild(tr);
                }
                meta.appendChild(table);
                det.append(sum, meta);
                return det;
              };

              const truncate = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;

              const updateCounts = () => {
                el.counts.textContent = `${store.filtered.length} shown • ${store.all.length} total`;
              };

              const fullRender = (keepScrollIfPinned = true) => {
                const pinned = el.pinCheck.checked && atBottom();
                el.container.innerHTML = '';
                const frag = document.createDocumentFragment();
                for (const log of store.filtered) frag.appendChild(renderLine(log));
                el.container.appendChild(frag);
                updateCounts();
                if (keepScrollIfPinned && pinned) scrollToBottom();
              };

              const appendIfVisible = (log) => {
                const pinned = el.pinCheck.checked && atBottom();
                if (matchesFilter(log)) {
                  store.filtered.push(log);
                  el.container.appendChild(renderLine(log));
                  updateCounts();
                  if (pinned) scrollToBottom();
                }
              };

              /** ---------- Filtering ---------- **/
              const matchesFilter = (log) => {
                if (!store.regex) return true;
                const hay = textFromLog(log);
                return store.regex.test(hay);
              };

              const applyFilter = () => {
                store.regex = buildRegex(store.text);
                store.filtered = store.all.filter(matchesFilter);
                fullRender(true);
              };
              const onFilterInput = debounce(() => {
                store.text = el.filter.value;
                applyFilter();
              }, 120);

              /** ---------- WebSocket ---------- **/
              const connect = () => {
                if (ws) { try { ws.close(); } catch {} }
                setStatus('connecting', 'Connecting…');
                ws = new WebSocket(FIXED_WS);

                ws.addEventListener('open', () => setStatus('connected', 'Connected'));
                ws.addEventListener('message', (evt) => {
                  const payload = tryParse(evt.data);
                  if (!payload) return;
                  const items = Array.isArray(payload) ? payload : [payload];
                  for (const raw of items) {
                    const log = normalizeLog(raw);
                    store.all.push(log);
                    appendIfVisible(log);
                  }
                });
                ws.addEventListener('close', () => setStatus('disconnected', 'Disconnected'));
                ws.addEventListener('error', () => setStatus('error', 'Error'));
              };

              const disconnect = () => {
                if (ws) { try { ws.close(1000, 'client closing'); } catch {} }
                ws = null;
                setStatus('disconnected', 'Disconnected');
                el.connect.disabled = false;
                el.disconnect.disabled = true;
              };

              const normalizeLog = (raw) => {
                const level = normLevel(raw.level || raw.LogLevel || raw.logLevel);
                const message = raw.message ?? raw.Message ?? '';
                const source = raw.source ?? raw.Source ?? '';
                const metadata = raw.metadata ?? raw.Metadata ?? {};
                return { level, message, source, metadata };
              };

              /** ---------- Events ---------- **/
              el.filter.addEventListener('input', onFilterInput);

              // Keyboard shortcuts
              window.addEventListener('keydown', (e) => {
                if (e.key.toLowerCase() === 'f' && document.activeElement == document.body) {
                  e.preventDefault();
                  el.filter.focus(); el.filter.select();
                } else if (e.key === 'Escape') {
                  if (document.activeElement === el.filter) {
                    el.filter.value = '';
                    store.text = '';
                    applyFilter();
                  }
                }
              });

              // Preserve scroll position logic when user scrolls manually
              // (We only auto-scroll if the view was already at bottom and the pin is enabled)
              el.container.addEventListener('scroll', () => {
                // No-op: logic is checked per append; this listener is here
                // in case you want to add UI indicating pinned/unpinned later.
              });

              // Autofill filter from ?filter= query param
              const params = new URLSearchParams(location.search);
              const initial = params.get('filter');
              if (initial && typeof initial === 'string') {
                el.filter.value = initial;
                store.text = initial;
              }
              // Initial empty render
              applyFilter();

              connect();
            })();
            </script>
            </body>
            </html>
        """
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/html"],
            body: body.data(using: .utf8)!
        )
    }
    
    func makeMessages(for client: AsyncStream<FlyingFox.WSMessage>) async throws -> AsyncStream<FlyingFox.WSMessage>
    {
        return AsyncStream { continuation in
            var done = false
            Task {
                do {
                    for i in 1...9999999
                    {
                        try await Task.sleep(for: .seconds(1))
                        print("Printing")
                        continuation.yield(WSMessage.text("""
                            {
                                "level": "warning",
                                "message": "hello test \(i)",
                                "source": "http",
                                "metadata": { "ClientID": "cli_\(i%4)", "Route": "/api/items" }
                            }
                        """))
                    }
                } catch {}
                print("Logger finished")
                continuation.finish()
            }
        }
    }
}

extension EntityID {
    var short: Substring
    {
        return split(separator: "-").first!
    }
}
