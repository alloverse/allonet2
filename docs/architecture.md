# Architecture

The module map and the mechanics behind the README's concept map. File references are the
source of truth; update this doc when they move.

## Targets

| Target | Kind | What it is |
|---|---|---|
| `allonet2` | library | Core: ECS world model and wire types, `DataChannelTransport` on libdatachannel (the `Packages/AlloDataChannel` submodule), `AlloSession`, `AlloClient` + `AlloAppClient`, `PlaceServer` (interactions, ECS sync, SFU, assets, HTTP, dashboard), simulations, logging, errors. Linux-capable. |
| `AlloAudio` | library | `VoiceEngine`: the one `AVAudioEngine` voice runs on - voice-processing capture and spatialised playout through an `AVAudioEnvironmentNode`. Apple-only (AVFAudio). |
| `alloclient` | library | Visor-side client: `AlloUserClient`, which owns the `VoiceEngine` and the microphone track, on the same transport; `SpatialAudioPlayer` drives spatial voice off `PlaceState`, with no renderer involved. Apple-only in practice. |
| `AlloReality` | library | RealityKit layer: `RealityViewMapper` mirrors `PlaceState` into an entity tree. Apple-only. |
| `AlloVideo` | library | Screen capture, H.264 encode and decode, and the sender/receiver that put pictures on a media stream (`ScreenCapturer`, `H264Encoder`, `H264Decoder`, `VideoSender`, `VideoReceiver`). Apple-only (ScreenCaptureKit, VideoToolbox). |
| `AlloPlace` | executable | The place server CLI (ArgumentParser) around `PlaceServer`. |
| `demoapp` | executable | Minimal example alloapp: spawns an avatar, orbits it, answers a `custom` interaction. |
| `voicedemo` | executable | Two of them on one place is a voice call: microphone or tone in, spatialised voice out, counters and latency. Apple-only. |
| `screendemo` | executable | The same for screens: `--share` a picked window or a test pattern, `--view` every screen in the place. Apple-only. |

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
  `didReceivePlaceChangeSet`). The diff is over the whole place, so it is computed once per
  distinct acked revision and shared by every client sitting on it.
- The beat runs on the main actor and self-clocks: its period is the 20 ms coalesce *plus*
  however long it takes, so anything superlinear in the size of the place surfaces as a
  collapsed beat rate rather than as one slow function. `ComponentLists`' typed list subscript
  (`components[T.self]`) decodes every component of that type on every access and caches
  nothing — reaching through it for one entity, inside a loop over entities, is what made
  `sweepOrphans` quadratic and cost 9 ms a beat at 110 entities. Use
  `components[T.self, of: eid]` for a single lookup, and hoist the list out of any loop.
- A beat commits only its net effect on committed state, so a write of the value already there
  — or one walked away and back by two requests inside the same coalescing window — leaves
  `revision` alone (`PlaceServer+ECS.swift`): a spent revision costs every client a delta and
  shortens the 100-revision window a lagging one can resync from.
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

- `DataChannelTransport` (`Transport/DataChannelTransport.swift`) is the only transport, on
  libdatachannel: offer/answer lifecycle, data channels, media forwarding. `PlaceServer` and the
  clients construct it by name.
- The `Transport` protocol it conforms to (`Transport/TransportProtocol.swift`) survives **for
  the tests**: `MockTransport` in `allonet2Tests` is what lets a session, a client or a whole
  place be driven without ICE, timing or a network. Nothing in `Sources` chooses between
  implementations, so don't add a second one to production code without a reason of its own.
- `AlloSession` wraps a `Transport` with the three fixed data channels — `interactions`
  (reliable, stream id 1), `worldstate` (unreliable, id 2; `PlaceChangeSet` down, `Intent`
  up), `logs` (reliable, id 3) — CBOR-encoded via PotentCodables (`AlloSession.swift`;
  encoder/decoder are chosen there and nowhere else).
- Media rides its own in-band channels, one per stream, in two kinds: `voice/` unordered with
  no retransmits, `video/` ordered with a 1000 ms lifetime ([voice.md](voice.md)).
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
- Authentication: an announce with `expectation: .app` is always checked against the shared
  `-t` token (an empty token authenticates any app) — this is the only path that grants app
  privileges. Users are only authenticated when a provider is registered (or `--require-auth`
  demands one): auth is delegated to the alloapp that sent
  `registerAsAuthenticationProvider`, and the place forwards each user's
  `authenticationRequest` to it with a 10 s timeout.
- Fatally-refused clients are condemned to a third roster (`waitingToDisconnect`) rather than
  disconnected — see gotchas for why, and for what "iterate all clients" must include.
- Errors: `AlloverseError` carries whether it is fatal *on the wire* (the raiser resolves it;
  fatality decides retry-vs-give-up — `Error.swift`, and the fatality entry in gotchas).

## Threading

Everything above the transport is `@MainActor`, with two deliberate exceptions. The transport
marshals its callbacks onto main, except the incoming-data decode path, which is
`nonisolated` so CBOR parsing can't queue behind the main thread. And `PlaceServerAssets` is
explicitly *not* `@MainActor`: asset hashing and file I/O run in FlyingFox's own task tree,
with only the publish-token set actor-isolated — don't hang shared mutable state off it
assuming the main actor protects it. Real-time audio I/O goes through `AudioRingBuffer`
(lock-free SPSC, swift-atomics). Details and traps in [gotchas.md](gotchas.md).

## What is not here

- **No persistence**: world state is in-memory; the only durable state is the asset store
  directory. A place restart loses every entity — domain state that must survive belongs in
  an alloapp (KojaServ does exactly this).
- **No clock sync**: sequencing is `ackStateRev`; simulation runs on the server's own 20 ms
  tick.
- **No schema negotiation**: components are runtime-registered Codables. An unknown component
  survives on the wire as `AnyComponent`; `decodeCustom()` turns it into a `CustomComponent`,
  while plain `decoded()` **traps** on any unregistered type.
