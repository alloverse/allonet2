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

## Gotchas
- AnyComponent requires explicit wrapping: `AnyComponent(MyComponent(...))` — no implicit conversion in enum cases or dictionary literals (Swift 6)
- Test encoding must use CBOREncoder/CBORDecoder (not JSON) — JSON round-trip loses AnyValue dictionary structure
- Component types must be registered with `MyComponent.register()` before `decoded()` will work (returns nil → crash otherwise)
- HeadlessWebRTCTransport implements media forwarding; UIWebRTCTransport throws fatalError (client doesn't forward)
- ConnectionStatus is @MainActor ObservableObject used for UI binding — don't confuse with transport-level state
- AlloPlace logs to OSLog on macOS and only to stdout on Linux (`PlaceServerApp.configureLogging`), so running it locally with its output redirected to a file gives you an empty file, not a dead server
- A place can't tell a dead client from a live one until ICE gives up (tens of seconds). Anything keyed on "is that client still there?" — the authentication provider slot especially — has to tolerate the stale answer rather than wait for it
- `client.identity` on the place is whatever the client *said* in its announce, and it is stored before anything checks it. Authorization reads `client.authenticatedAsApp`, which is the place's own verdict; never `identity.expectation`
- Known and deliberately unfixed, all pre-existing: a drop from `.announced` retries with no delay and no escalation, because `ClientConnectionState.attempt` is 0 for `.announced` — harmless for one client per place, but two live backends sharing an app token will trade the provider role back and forth at handshake speed; the place's authentication request to the provider has no timeout, so a provider that is connected but silent hangs the announcing visor (a provider that *disconnects* is covered, since its outstanding requests are failed); and whether libdatachannel's callbacks really arrive on the main actor is still the open question at the top of `HeadlessWebRTCTransport.swift`, which every delegate call out of that sink depends on

## Recent Work (2026-03-04)
- UIWebRTCTransport: Added @MainActor, nonisolated delegates, dispatchToMain, dispatchPrecondition
- AlloSession: Added dispatchPrecondition to send/disconnect
- Tests: Fixed all 7 tests for AnyComponent/PotentCodables compatibility
