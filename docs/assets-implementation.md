# Assets: implementation notes

The parts of the asset pipeline that bite. Concepts and vocabulary are in [assets.md](assets.md).

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
- `AlloReality` and its tests are Darwin-only, and SwiftPM would happily try to build them on Linux
  and fail. What saves CI is the Dockerfile asking for `--product AlloPlace`, which reaches neither.
  GLTFKit2 is an xcframework binaryTarget, like `webrtc-xcframework` already is: Linux downloads the
  artifact during resolve and never builds against it.

## Loading glTF

[GLTFKit2](https://github.com/warrenm/GLTFKit2) (MIT), pinned exactly — it ships as a binary, so a
version bump can change behaviour without changing an API.

Loading splits into two halves that cost wildly different amounts, so we call them separately rather
than using `GLTFRealityKitLoader.load(from:)`. Measured on an M-series Mac: parsing 12.7 MB takes
9 ms, converting that same 86k-triangle scene takes 3.1 s, and a 1.4 MB single object converts in
35 ms. Parsing is synchronous and runs off the main actor; conversion is main-actor-only, so it is
frame time. **That ratio is the argument for one asset per part rather than one per room**, and for
checking cancellation between the halves.

Upstream gaps, none of them ours to fix: `KHR_texture_transform` is ignored, `TEXCOORD_1` is
ignored, and every primitive gets its own `PhysicallyBasedMaterial` with no dedup. Base colour,
normal, metallic-roughness, occlusion, emissive, alpha modes and double-sidedness all arrive
correctly.

## Surviving a hostile mesh

A fetched file's bytes are a peer's choice and only their hash was checked. `convert` has no error
path at all — it calls `fatalError` on internal failure — so everything must be rejected before it,
and the parse step alone is not enough.

**Parse from bytes, never from a URL.** `GLTFAsset(url:)` gives cgltf a base directory to resolve
`buffer.uri` and `image.uri` against, and cgltf percent-decodes *after* joining, so an encoded `../`
walks out of the cache and reads any local file straight into a vertex buffer. This is not only a
`.gltf` problem — a `.glb`'s JSON chunk can carry the same URIs, and probing confirmed the bytes of
a file one directory above the cache arriving in `buffers[1].data`, via both `../secret.bin` and
`..%2Fsecret.bin`. Checking after the fact does not work: GLTFKit2 clears `uri` once it has resolved
it, so by the time there is a `GLTFAsset` to inspect, the read has happened. `GLTFAsset(data:)`
leaves nothing to join against, which makes the traversal unrepresentable rather than detected.
`data:` URIs still resolve, so embedded textures are unaffected; the cost is holding the file in
memory for the length of the parse.

**`.gltf` has no loader**, even though `model/gltf+json` is a media type the store accepts. Beyond
the traversal above, a JSON glTF names its buffers and textures as relative URIs and a store holding
one file per content address has no siblings to resolve them against — it could never have worked.
Publishers ship `.glb`.

**Validate geometry before converting.** GLTFKit2 never runs `cgltf_validate`, so a file that parses
can still contradict itself, and `MeshResource` then asserts below Swift where no `catch` reaches.
Measured: a primitive with `POSITION` count 3 and `NORMAL` count 1 kills the process with SIGTRAP.
So every attribute of a primitive must describe the same vertex count, and every accessor's window
must fit its buffer view. That window is `offset + (count - 1) * stride + element`, computed from
four numbers a peer wrote — it uses overflow-reporting arithmetic, because an `Int` overflow traps
exactly as hard as the assertion the check exists to avoid. Still unchecked: index *values* pointing
past the vertex count, which would need a walk of the whole index buffer, and where it is unmeasured
whether RealityKit traps at all.

**Strip names off the loaded subtree.** `guiForEid` resolves an `EntityID` through
`findEntity(named:)`, which searches the whole tree, so a node named after another entity would
quietly collect that entity's component updates and its removal. Names inside an asset are cosmetic
by contract; for a file a peer wrote, the safe reading of cosmetic is gone. This costs the
name-based bindings RealityKit uses for skeletal animation, which nothing we ship uses yet.

**A malformed id is a different boundary**, and is handled in the protocol layer. `AnyComponent`
force-tries its decode, so `Model` hand-writes `init(from:)` and degrades an unparseable `AssetID`
to `Model.unrenderable` — the same red box a failed load shows — instead of throwing. A throw there
would trap every client rendering that entity, which makes one bad string from any peer a way to
empty a room.
