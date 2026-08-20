# Assets over HTTP

Assets are content-addressed blobs — `sha256:<64 lowercase hex>` — served by the place over the
same HTTP server that does signalling. HTTP reachability is already a precondition of a session
existing, so `GET place/assets/{id}` is never less reachable than a data channel. Publishers HEAD
then POST on miss; consumers GET on first sight of an unknown id in worldstate. No availability
announcements: worldstate sync *is* the announcement.

Reads are open; writes are not. `POST /assets` needs a bearer token the place mints at announce and
revokes on disconnect, so publishing is a privilege of having a session — the HTTP request carrying
the bytes has no other way to say who it is. It is a live credential, so never log an
`InteractionBody` whole: `announceResponse` carries the token, and a visor streams its logs back to
the place. Visors get one too, since avatars are client-published.
GET and HEAD stay unauthenticated on purpose: assets are immutable and cacheable by any
intermediary, and you need the content hash to ask for one at all.

Turning the flow around — the place fetching from the publisher instead — doesn't work: alloapps and
visors have no inbound reachability, which is why signalling is a POST *to* the place. A
place-initiated fetch would have to ride the data channel and rebuild allonet1's chunking and
back-pressure protocol. Lazy pull, if it ever lands, moves only the *trigger* in-band and still
needs this token on the POST that follows.

`AssetStore` is both the place's origin and each client's cache — same layout on both sides:

```
<hex>.<ext>   the bytes; extension derived from the media type, so the file can go straight to a
              loader that dispatches on one (RealityKit has no data-based USDZ loader)
<hex>.type    the media type, written last — its presence is the promise the bytes landed
```

The extension is a convenience; the id stays derived from content alone. When two publishers upload
identical bytes under different media types, a publisher that names a type corrects one that left it
at `application/octet-stream` (the default for "I didn't say"), and the blob is renamed to match —
otherwise the first claim stands, since nothing here can adjudicate two specific claims about
identical bytes. This matters because the extension is what decides whether a loader can open the
file at all, so one lazy publisher would otherwise poison an id for everybody.

## FlyingFox pitfalls

Version 0.26.2. Each of these ships as a bug if you don't handle it:

- **A missing `Content-Length` decodes as an empty body**, not an error (`HTTPDecoder.readBody` does
  `?? 0`), and there is no chunked *request* decoder at all. Without an explicit 411 the place
  stores the SHA-256 of nothing. This is also why the client must never use `httpBodyStream`, which
  forces chunked encoding on Linux — use `upload(for:from:)` / `upload(for:fromFile:)`.
- **Handlers are wrapped in a timeout that covers the whole request**, body included, defaulting to
  15 s. A multi-megabyte upload over a slow link dies as a 500. `PlaceServerHTTP` raises it to 120 s
  for the whole server, signalling included.
- **Nothing enforces a max body size.** Checking `Content-Length` before touching the body costs
  nothing; rejecting without draining the body desyncs the connection, because keep-alive is decided
  by the *request* (`HTTPConnection`), so a `Connection: close` on the response won't save you.
- **HEAD is never derived from a GET route** and the encoder writes whatever body it is handed, so
  HEAD needs its own route (`"GET,HEAD /assets/:id"`), a manual `Content-Length`, and no body — on
  *every* path including errors. URLSession answers a HEAD carrying content by destroying the
  connection, and a HEAD 404 is the normal path for the first publish of any asset, so a body on the
  error path costs a TCP (and behind a TLS proxy, a TLS) handshake per publish.
- **Range bounds are attacker-supplied integers.** `min(end + 1, size)` traps on
  `bytes=0-<Int.max>`, and an arithmetic trap kills the whole place. Clamp before incrementing.
- **`FileHTTPHandler` looks like it does Range for you, and half does.** It streams and emits
  206/`Content-Range`, but an unsatisfiable range surfaces as **404** rather than 416 — telling a
  client "no such asset" about an asset that is right there — it ignores suffix ranges
  (`bytes=-500` returns the whole file as 200), serves only the first of a multi-range header, and
  emits no `ETag`/`Cache-Control`. Hence our own `parseRange`.
- **`HTTPBodySequence(file:)` defaults to a 4 KiB buffer**, i.e. thousands of syscalls for one mesh.
- **Route parameters only exist on the wire.** `HTTPRequest.matchedRoute` is internal to FlyingFox
  and only its router populates it, so `routeParameters` is always empty when you call a handler
  directly — anything behind `/assets/:id` can only be tested against a bound port.

## Linux

- `URLSession.bytes(for:)`/`AsyncBytes` **do not exist** on corelibs-foundation: using them is a
  compile error, not a runtime fallback. `download(for:)` does stream to a temp file, so that is the
  consumer path.
- `FileManager`'s caches directory resolves out of `/etc/default/useradd`, not `$HOME`, landing on
  `/home/.cache` inside the AlloPlace container. Both the store's default and `--assets-dir` avoid
  it; point the flag at a volume to keep assets across restarts.
- SHA-256 comes from `swift-crypto`. On Apple platforms `import Crypto` is a CryptoKit re-export
  compiling zero C, so BoringSSL is only ever built in the Linux image — which also means a
  crypto-side Linux break is invisible to the macOS merge gate.

## Not done yet

`Model.mesh == .asset(id:)` still traps in `RealityViewMapper`; nothing renders a fetched asset.
There is no GC and no quota, so a connected
agent can still fill the place's disk — the token bounds *who* can write, not how much. A consumer
download is likewise uncapped: a malicious place can hand a client more bytes than it asked for, and
the hash is only checked once the file has landed.
