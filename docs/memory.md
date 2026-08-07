# allonet2 MEMORY

## Architecture
- Swift networking library for real-time spatial collaboration (Alloverse protocol)
- 4 library targets: `allonet2` (core), `alloclient` (Google WebRTC client), `alloheadless` (libdatachannel server), `AlloReality` (RealityKit)
- Transport protocol: abstraction over WebRTC with async/await offer/answer/disconnect lifecycle
- Two Transport implementations: UIWebRTCTransport (client, LiveKitWebRTC) and HeadlessWebRTCTransport (server, AlloDataChannel)
- AlloSession wraps Transport, adding CBOR-encoded data channels (interactions, worldstate, logs), media stream tracking, renegotiation with polite/impolite conflict resolution
- PlaceServer: server-side orchestrator with SFU (PlaceServerSFU) for selective media forwarding
- ECS: Entity/Component system with type-erased AnyComponent, ComponentRegistry, PlaceChangeSet delta sync

## Build
- `swift build` for standalone build
- `swift test` for unit tests (7 tests in allonet2Tests)
- Package.swift: Swift 6.0, platforms macOS 15+, iOS 18+, visionOS 2.0+
- Dependencies: PotentCodables (CBOR), LiveKitWebRTC, FlyingFox (HTTP), swift-atomics, OpenCombine

## Key Design Decisions
- UIWebRTCTransport is @MainActor; all WebRTC delegate callbacks are `nonisolated` and dispatch to main via `dispatchToMain()` helper
- `dispatchToMain` uses `MainActor.assumeIsolated` when already on main thread, `Task { @MainActor in }` otherwise
- `dispatchPrecondition(condition: .onQueue(.main))` in key methods as runtime belt-and-suspenders
- AlloSession is @MainActor; `transport(_:didReceiveData:on:)` is explicitly nonisolated for performance (CBOR parsing off main thread)
- AnyComponent uses PotentCodables AnyValue for type-erased storage; concrete types recovered via `decoded()` / ComponentRegistry
- AudioRingBuffer: lock-free SPSC ring buffer using swift-atomics for real-time audio I/O
- Whether an error is permanent (`AlloverseError.isFatal`) is what decides between retrying with backoff and ending the stay-connected loop. Only the raiser can answer it — an app's codes mean nothing to `PlaceErrorCode`/`AlloverseErrorCode` — so `asBody` puts the resolved answer on the wire and `init(with:)` reads it back. Local `overrideIsFatal` still outranks it, which is how a place calls a rejected login permanent even though the app that rejected it didn't say. A body with no flag falls back to the code tables, so peers that predate it still work

## Gotchas
- AnyComponent requires explicit wrapping: `AnyComponent(MyComponent(...))` — no implicit conversion in enum cases or dictionary literals (Swift 6)
- Test encoding must use CBOREncoder/CBORDecoder (not JSON) — JSON round-trip loses AnyValue dictionary structure
- Component types must be registered with `MyComponent.register()` before `decoded()` will work (returns nil → crash otherwise)
- HeadlessWebRTCTransport implements media forwarding; UIWebRTCTransport throws fatalError (client doesn't forward)
- ConnectionStatus is @MainActor ObservableObject used for UI binding — don't confuse with transport-level state
- AlloPlace logs to OSLog on macOS and only to stdout on Linux (`PlaceServerApp.configureLogging`), so running it locally with its output redirected to a file gives you an empty file, not a dead server
- A place can't tell a dead client from a live one until ICE gives up (tens of seconds). Anything keyed on "is that client still there?" — the authentication provider slot especially — has to tolerate the stale answer rather than wait for it
- `client.identity` on the place is whatever the client *said* in its announce, and it is stored before anything checks it. Authorization reads `client.authenticatedAsApp`, which is the place's own verdict; never `identity.expectation`
- libdatachannel calls back from its own thread pool, on several worker threads, and synchronously on the calling network thread for `Closed` (`PeerConnection::changeState`). Everything above the transport is main-actor, so `HeadlessWebRTCTransport` marshals every peer publisher through `onMain` before touching anything. The one deliberate exception is the incoming-data path: `didReceiveData` is `nonisolated` so decoding can't queue behind the main thread, and it reads `dataDelegate` rather than the isolated `delegate`
- `client.session` is replaced on every reconnection, so anything that subscribes to it — or reads it across an `await` — is bound to a connection that may already be gone. Fixed in AlloClient (`isCurrent`, and responses go to the session that asked); **still broken in `AlloReality/SpatialAudioPlayer.start()`**, which subscribes to `client.session.$incomingStreams` once, so a visor stops receiving any audio after a reconnect. Now that reconnections actually happen, that is reachable
- A response that arrives in the same breath as a disconnect is thrown away: inbound interactions reach the main actor one `Task` hop late (the nonisolated decode above), while `AlloSession.transport(didDisconnect:)` runs synchronously and abandons every outstanding request with `nil`. So a peer must never answer and hang up in the same turn. `PlaceServer` observes this via `condemn(_:)`: a fatally-refused client moves to the `waitingToDisconnect` roster (no service, no world updates, entities and publishing rights torn down) while the session stays up for the client to hang up itself, as AlloClient does; `fatalDisconnectGrace` backstops one that ignores the answer. Anything iterating "all clients" (stop(), stream cleanup) must include that third roster, and dispatch must tolerate a cid in no roster at all — it used to force-unwrap
- Known and deliberately unfixed: `awaitGatheringComplete` leaks one `$gatheringState` subscriber per peer on the success path — an AsyncPublisher iterator is only torn down by cancellation, and the success branch returns instead. Bounded by one per peer and it dies with the peer

## Recent Work (2026-03-04)
- UIWebRTCTransport: Added @MainActor, nonisolated delegates, dispatchToMain, dispatchPrecondition
- AlloSession: Added dispatchPrecondition to send/disconnect
- Tests: Fixed all 7 tests for AnyComponent/PotentCodables compatibility
