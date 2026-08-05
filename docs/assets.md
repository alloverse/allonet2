# Assets over HTTP

Assets are content-addressed blobs — `sha256:<64 lowercase hex>` — served by the place over the
same HTTP server that does signalling. HTTP reachability is already a precondition of a session
existing, so `GET place/assets/{id}` is never less reachable than a data channel. Publishers HEAD
then POST on miss; consumers GET on first sight of an unknown id in worldstate. No availability
announcements: worldstate sync *is* the announcement.

`AssetStore` is both the place's origin and each client's cache — same layout on both sides:

```
<hex>.<ext>   the bytes; extension derived from the media type, so the file can go straight to a
              loader that dispatches on one (RealityKit has no data-based USDZ loader)
<hex>.type    the media type, written last — its presence is the promise the bytes landed
```

The extension is a convenience; the id stays derived from content alone. Two publishers uploading
identical bytes under different media types collide on the sidecar, last writer wins.

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
  HEAD needs its own route (`"GET,HEAD /assets/:id"`), a manual `Content-Length`, and no body.
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
`Model.Mesh.asset` carries a `String`, not an `AssetID`. There is no GC, no quota, and `POST /assets`
is unauthenticated — a public place accepts blobs from anyone who can reach the port.
