# Writing an alloapp

An alloapp is a headless allonet2 client that owns entities in a place: a plain Swift
executable that connects with app identity, spawns its widget as entities, and reacts to
interactions. It needs no graphics — visors render what you publish — and runs anywhere Swift
runs, including a Linux VM or container. `Sources/demoapp` is the minimal living example of
everything below; Koja's own domain server is a (much larger) alloapp too.

## Skeleton

An SPM executable depending on this package's `allonet2` product:

```swift
// Package.swift:
//   .package(url: "https://github.com/alloverse/allonet2", branch: "main")
//   .product(name: "allonet2", package: "allonet2")
import allonet2

let identity = Identity(expectation: .app, displayName: "StatusLight",
                        emailAddress: "", authenticationToken: appToken)
let client = AlloAppClient(url: url, identity: identity,
                           avatarDescription: EntityDescription(components: [
    Model(mesh: .cylinder(height: 1.0, radius: 0.2), material: .color(color: green, metallic: false)),
], children: []))

Task {
    for await announced in client.$isAnnounced.values where announced == true {
        // connected (or reconnected) and announced: (re)establish your state here
    }
}
client.stayConnected()   // retries with backoff forever; then park the process
```

The `avatarDescription` is your root entity, spawned at one of the place's `SpawnPoint`s;
`children` spawn as entities parented to it. `stayConnected()` redials with backoff on every
drop, and announce runs again on each reconnect — so treat the `$isAnnounced` signal as
"reconcile my entities now", not as a one-time setup hook (entities owned by a client are torn
down when its session dies).

## Your widget is entities

Compose it from the standard components (`StandardComponents.swift`): E g `Transform`,
`Relationships` (parenting), `Model`, `Text`, `Opacity`, `Billboard`, `Collision` +
`InputTarget` (tappable), `Collision` + `AudioOccluder` (blocks voice), `Grabbable`. 

Your entity can render visibly a few different ways: **primitive meshes**
(`.box`, `.plane`, `.cylinder`, `.sphere`) with `.color` or `.image(asset:)` materials;
`Text`; and **`.asset(id:)` meshes**: a published self-contained `glb` (compressed GLTF)
is the entity's whole visual, materials included — see [assets.md](assets.md#meshes).
(`.builtin` meshes are reserved, do not use.)

Mutate with `client.createEntity(from:)` / `removeEntity` / `changeEntity`, or the sugar on
an entity you hold:

```swift
try await entity.components.set(Model(mesh: .sphere(radius: 0.1),
                                      material: .color(color: red, metallic: false)))
```

Read and observe the world through `client.placeState`: `observers` gives
added/updated/removed callbacks per component type (the `*WithInitial` variants replay
current state to a new subscriber).

## Reacting to users

- `InputTarget` + `Collision` make an entity tappable; the tap arrives at its owner as a
  oneway `tap(at:)` interaction.
- Request/response RPC: register a responder keyed by the body's case name, and answer —

```swift
client.responders["custom"] = { request async -> Interaction in
    return request.makeResponse(with: .custom(value: [:]))
}
```

- A request is for answers a machine gives at once. The place answers any forwarded request
  itself after `PlaceServer.InteractionTimeout` (10 s) with "Recipient didn't respond in
  time", and that is a liveness guard, not a budget to raise: a dead responder should be
  found in seconds by every caller. Anything a person answers — "may I see your screen?" —
  is state, not a reply: send it oneway, answer it oneway, keep the pending entry and its
  expiry on each end, and send a cancel when the asker gives up, so it survives a reconnect
  and never waits on a continuation the place would have dropped.
- Custom payloads ride `.custom(value: AnyValue)`; define your own `Component` types with
  `MyComponent.register()` if you want structured shared state instead.

## Connecting

- The URL is `alloplace2://host:port` (HTTP signalling, for localhost) or
  `alloplace2s://host` (HTTPS, for anything fronted by TLS).
- Announce as `expectation: .app`. The `authenticationToken` must equal the place's `-t`
  token; a place started without `-t` accepts any app. For a hosted place — a Koja workplace,
  say — ask the place's operator for its app token.
- Client and place must agree on allonet2's major+minor version (the announce is refused
  otherwise), so build against the version the place runs.

## Deploying

Linux is a first-class target for alloapps: the transport rides libdatachannel, and this
repo's `Dockerfile` is a working Linux build recipe to crib from (the CI builds amd64 +
arm64). The process only needs outbound reachability to the place's HTTP port and UDP —
no inbound ports, so any VM or container host works.

## Worked example: a status light

Poll something (say, CI on your dev branch) and recolor three stacked spheres in the avatar's
children; update by `components.set` on the entity whose state changed, at whatever cadence
your poll runs. That's the whole app: an `AlloAppClient`, an `EntityDescription` of four
primitives, one `Task` loop, and `stayConnected()`. See `demoapp`'s orbit loop for the same
shape in motion.
