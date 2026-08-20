# Architecture

The module map and the mechanics behind the README's concept map. File references are the
source of truth; update this doc when they move.

## Targets

| Target | Kind | What it is |
|---|---|---|
| `allonet2` | library | Core: ECS world model and wire types, `AlloSession`, `AlloClient` base, `PlaceServer` (interactions, ECS sync, SFU, assets, HTTP, dashboard), simulations, logging, errors. Linux-capable. |
| `alloclient` | library | Visor-side transport: `UIWebRTCTransport` on LiveKitWebRTC, mic capture, `AlloUserClient`. Apple-only in practice (AVFAudio, the webrtc xcframework). |
| `alloheadless` | library | App/place-side transport: `HeadlessWebRTCTransport` on libdatachannel (the `Packages/AlloDataChannel` submodule), `AlloAppClient`. This is what Linux and Docker use. |
| `AlloReality` | library | RealityKit layer: `RealityViewMapper` mirrors `PlaceState` into an entity tree; spatial audio playback + attenuation. Apple-only. |
| `AlloPlace` | executable | The place server CLI (ArgumentParser) wiring `PlaceServer` to `HeadlessWebRTCTransport`. |
| `demoapp` | executable | Minimal example alloapp: spawns an avatar, orbits it, answers a `custom` interaction. |

`Package.swift` has no platform conditions; Apple-only-ness is enforced by what a consumer
links. Swift tools 6.1, language mode 5, platforms macOS 15 / iOS 18 / visionOS 2.

## State sync

- `PlaceContents` is an immutable snapshot: `revision` + `entities` + component-major
  `ComponentLists`. `EntityData` is only `id` + `ownerClientId`; everything else is a
  component (`PlaceContents.swift`).
- The place applies changes as `PlaceChangeSet(from:to:)` and keeps up to 100 revisions of
  history (`PlaceContents+Changes.swift`); per client it diffs from that client's
  `ackdRevision` (`PlaceServer/PlaceServer+ECS.swift`). A client that can't apply a delta
  acks revision 0, which requests a full resync (`AlloClient.swift`,
  `didReceivePlaceChangeSet`).
- Broadcast cadence: `HeartbeatTimer`, server side 20 ms coalesce / 1 s keepalive; the
  client's intent heartbeat is 5 ms / 1.1 s (`PlaceServer/HeartbeatTimer.swift`,
  `AlloClient.swift`).
- App code observes changes via `PlaceState.observers` (`ComponentCallbacks<T>`:
  added/updated/removed, plus `*WithInitial` variants that replay current state per
  subscription — see gotchas for the replay trap).
- Ownership: a client may only send interactions from entities it owns
  (`PlaceServer+InteractionMachinery.swift`). The equivalent check for entity *modification*
  is commented out pending ACLs (`PlaceServer+ECS.swift`) — don't build a feature that
  depends on it existing.

## Wire and transports

- `Transport` protocol (`TransportProtocol.swift`): offer/answer lifecycle, data channels,
  media forwarding. Implementations: `UIWebRTCTransport` (alloclient) and
  `HeadlessWebRTCTransport` (alloheadless); only the headless one forwards media.
- `AlloSession` wraps a `Transport` with the three fixed data channels — `interactions`
  (reliable, stream id 1), `worldstate` (unreliable, id 2; `PlaceChangeSet` down, `Intent`
  up), `logs` (reliable, id 3) — CBOR-encoded via PotentCodables (`AlloSession.swift`;
  encoder/decoder are chosen there and nowhere else).
- Signalling: one JSON POST to the place (`RTCSignalling.swift`, `PlaceServerHTTP.swift`).
  Renegotiation is in-band (`internal_renegotiate` interaction) with perfect-negotiation
  conflict resolution: client polite, server impolite (`AlloSession.swift`). Every SFU
  forward triggers one.
- The SFU (`PlaceServer/PlaceServerSFU.swift`) reconciles desired (from `LiveMediaListener`
  components) × available (incoming tracks) × active (running forwarders) on every trigger —
  the reconcile-don't-fire-once pattern.
- The same FlyingFox HTTP server serves the landing page, signalling, `/dashboard` (+ log
  WebSocket) and `/assets` (see [assets.md](assets.md)).

## Client lifecycle

- `AlloClient` is the shared base; `AlloUserClient` (visor) and `AlloAppClient` (app) mostly
  just install their transport. `stayConnected()` retries with exponential backoff capped at
  60 s, escalating when connections flap; `isCurrent(_:)` guards code that crosses an `await`
  against a replaced session (`AlloClient.swift`).
- Announce (`PlaceServer+PlaceInteractions.swift`): version gate (major+minor must match),
  authentication, avatar creation from `EntityDescription`, spawn at a `SpawnPoint`, reply
  with `avatarId` + `placeName` + the asset publish token.
- Authentication: apps present the shared `-t` token; user auth is delegated to an alloapp
  that sent `registerAsAuthenticationProvider` — the place forwards each user's
  `authenticationRequest` to it with a 10 s timeout. `--require-auth` keeps the place closed
  until a provider exists.
- Fatally-refused clients are condemned to a third roster (`waitingToDisconnect`) rather than
  disconnected — see gotchas for why, and for what "iterate all clients" must include.
- Errors: `AlloverseError` carries whether it is fatal *on the wire* (the raiser resolves it;
  fatality decides retry-vs-give-up — `Error.swift`, and the fatality entry in gotchas).

## Threading

Everything above the transports is `@MainActor`. Both transports marshal their callbacks onto
main, with one deliberate exception: the incoming-data decode path is `nonisolated` so CBOR
parsing can't queue behind the main thread. Real-time audio I/O goes through `AudioRingBuffer`
(lock-free SPSC, swift-atomics). Details and traps in [gotchas.md](gotchas.md).

## What is not here

- **No persistence**: world state is in-memory; the only durable state is the asset store
  directory. A place restart loses every entity — domain state that must survive belongs in
  an alloapp (KojaServ does exactly this).
- **No clock sync**: sequencing is `ackStateRev`; simulation runs on the server's own 20 ms
  tick.
- **No schema negotiation**: components are runtime-registered Codables; unknown ones decode
  as `CustomComponent`.
