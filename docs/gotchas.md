# Gotchas

Hard-won non-obvious facts. Fold a new one in here when it doesn't fit a topic doc.

## Components and encoding

- `AnyComponent` requires explicit wrapping: `AnyComponent(MyComponent(...))` — no implicit
  conversion in enum cases or dictionary literals (Swift 6).
- Component types must be registered with `MyComponent.register()` before `decoded()` will work
  (returns nil → crash otherwise).
- Test encoding must use CBOREncoder/CBORDecoder (not JSON) — a JSON round-trip loses AnyValue
  dictionary structure.

## Connection lifecycle and trust

- A place can't tell a dead client from a live one until ICE gives up (tens of seconds). Anything
  keyed on "is that client still there?" — the authentication provider slot especially — has to
  tolerate the stale answer rather than wait for it.
- `client.identity` on the place is whatever the client *said* in its announce, and it is stored
  before anything checks it. Authorization reads `client.authenticatedAsApp`, which is the place's
  own verdict; never `identity.expectation`.
- Whether an error is permanent (`AlloverseError.isFatal`) is what decides between retrying with
  backoff and ending the stay-connected loop. Only the raiser can answer it — an app's codes mean
  nothing to `PlaceErrorCode`/`AlloverseErrorCode` — so `asBody` puts the resolved answer on the
  wire and `init(with:)` reads it back. Local `overrideIsFatal` still outranks it, which is how a
  place calls a rejected login permanent even though the app that rejected it didn't say. A body
  with no flag falls back to the code tables, so peers that predate it still work.
- `client.session` is replaced on every reconnection, so anything that subscribes to it — or reads
  it across an `await` — is bound to a connection that may already be gone. Fixed in AlloClient
  (`isCurrent`, and responses go to the session that asked); **still broken in
  `AlloReality/SpatialAudioPlayer.start()`**, which subscribes to `client.session.$incomingStreams`
  once, so a visor stops receiving any audio after a reconnect. Now that reconnections actually
  happen, that is reachable.
- A response that arrives in the same breath as a disconnect is thrown away: inbound interactions
  reach the main actor one `Task` hop late (the nonisolated decode), while
  `AlloSession.transport(didDisconnect:)` runs synchronously and abandons every outstanding request
  with `nil`. So a peer must never answer and hang up in the same turn. `PlaceServer` observes this
  via `condemn(_:)`: a fatally-refused client moves to the `waitingToDisconnect` roster (no
  service, no world updates, entities and publishing rights torn down) while the session stays up
  for the client to hang up itself, as AlloClient does; `fatalDisconnectGrace` backstops one that
  ignores the answer. Anything iterating "all clients" (stop(), stream cleanup) must include that
  third roster, and dispatch must tolerate a cid in no roster at all — it used to force-unwrap.
  The media stream delegate callbacks are handled synchronously on purpose: AlloSession fires
  stream removals and the disconnect in one main-actor turn, and a Task hop would let the
  disconnect's roster cleanup outrun the stream cleanup's lookup.

## Threading

- libdatachannel calls back from its own thread pool, on several worker threads, and synchronously
  on the calling network thread for `Closed` (`PeerConnection::changeState`). Everything above the
  transport is main-actor, so `DataChannelTransport` marshals every peer publisher through
  `onMain` before touching anything. The one deliberate exception is the incoming-data path:
  `didReceiveData` is `nonisolated` so decoding can't queue behind the main thread, and it reads
  `dataDelegate` rather than the isolated `delegate`.

## Process lifetime

- libdatachannel keeps every peer connection in a static map in its C API, so one that is still
  alive when `main` returns is destroyed by that map's own static destructor, after
  `SctpTransport`'s registry of live instances (also a static) is gone — the SCTP shutdown ABORT
  then segfaults in `WriteCallback`. AlloDataChannel's `Teardown` deletes everything from an
  `atexit` handler to get ahead of that; `rtcCleanup()` alone deadlocks against its own registry
  lock.
- Known and deliberately unfixed: `awaitGatheringComplete` leaks one `$gatheringState` subscriber
  per peer on the success path — an AsyncPublisher iterator is only torn down by cancellation, and
  the success branch returns instead. Bounded by one per peer and it dies with the peer.

## Observability

- `AlloPlace` logs to OSLog on macOS and only to stdout on Linux
  (`PlaceServerApp.configureLogging`), so running it locally with its output redirected to a file
  gives you an empty file, not a dead server.
- `ConnectionStatus` is a `@MainActor ObservableObject` used for UI binding — don't confuse it
  with transport-level state.
