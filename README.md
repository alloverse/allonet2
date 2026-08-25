# Allonet2

The second iteration of [allonet](https://github.com/alloverse/allonet/): the networking
library that underpins the collaborative 3D/VR/AR workspace
[Alloverse](https://alloverse.com/) and products built on it, such as
[koja.works](https://koja.works). Active development happens here. The "why Swift, why
WebRTC" background lives in [docs/history.md](docs/history.md).

Allonet connects three kinds of software:

* **Alloapps**: "widget" apps that run in a 3D space. Headless clients with app identity
  (`AlloAppClient`, on the `alloheadless` product) — they run server-side but have an API that
  feels client-side.
* **Visors**: the 3D applications that visualize a place for a user — basically a 3D web
  browser (`AlloUserClient` on `alloclient`, rendered via `AlloReality`).
* **Places**: the simulation server / network hub that users and apps connect to
  (`PlaceServer`, shipped as the `AlloPlace` executable).

## The model

A place holds the authoritative world state: an entity/component system where every entity is
just an id plus an owner, and all attributes are components (`Transform`, `Model`, `Text`,
`Collision`, `Grabbable`, `LiveMedia`, … — see `StandardComponents.swift`; custom `Codable`
components register with a `ComponentRegistry`). State flows to clients as revisioned deltas (`PlaceChangeSet`); each
client acks the revision it has, and the place diffs from there, falling back to a full resync
when a client falls too far behind. World state is not persisted — a place restart loses every
entity.

Clients change the world through three mechanisms:

1. **Interactions** — reliable, CBOR-encoded request/response RPC between entities
   (`createEntity`, `changeEntity`, `custom(...)`, …). The place routes agent-to-agent
   interactions and enforces that you only speak for entities you own.
2. **Intents** — unreliable per-heartbeat state (movement direction, grab), simulated
   server-side at a 20 ms tick.
3. **Media** — real WebRTC audio tracks, selectively forwarded by the place's SFU, driven by
   the `LiveMedia`/`LiveMediaListener` components.

## The wire

Signalling is a single HTTP(S) POST to the place (JSON `SignallingPayload`; clients connect
with an `alloplace2://host:port` URL). The WebRTC session then carries three data channels —
`interactions` (reliable), `worldstate` (unreliable: deltas down, intents up), `logs`
(reliable) — all CBOR-encoded, plus SRTP media tracks for voice. Renegotiation (needed every
time the SFU forwards a new track) runs in-band as an `internal_renegotiate` interaction,
client-polite/server-impolite. Two things deliberately do *not* ride the data channels:
**assets** (content-addressed blobs, `sha256:<hex>`, on the place's HTTP server — published
with a per-session bearer token, fetched unauthenticated and cacheable — see
[docs/assets.md](docs/assets.md)) and **voice** (media tracks above).

Announce is the application-level handshake: the client presents an `Identity` and an avatar
`EntityDescription`, protocol versions must match on major+minor, and authentication happens
there — apps present a shared token; user authentication is delegated to an alloapp that has
registered as the place's authentication provider. The place also serves a human-facing
status dashboard (`/dashboard`) and receives client logs over the `logs` channel.

The deeper maps — targets and their platforms, sync internals, transports and threading,
client lifecycle and reconnection — live in [docs/architecture.md](docs/architecture.md).

## Development

### macOS

```sh
git submodule update --init --recursive   # AlloDataChannel etc; required
swift build                               # first build downloads a large webrtc xcframework
swift run AlloPlace -n "Local Place"
```

`AlloPlace` is the place server. Useful flags:

* `-n <name>` — human-facing name of the place.
* `-p <port>` — TCP port for the HTTP listener (signalling, assets, dashboard; default 9080).
* `-u <min-max>` — UDP port range for WebRTC (default 10000-11000).
* `-t <token>` — token an AlloApp must present to be granted app privileges; omitted, any app
  that asks is authenticated. It is a role credential, not a connection gate: clients
  announcing as users are only gated by `--require-auth` + an authentication provider.
* `--require-auth` — refuse users until an authentication provider has registered. Without it,
  a place admits anyone in the window between starting up and its provider connecting.
* `--assets-dir <path>` — keep published assets across restarts (default is under the temp
  directory).
* `-l <from_ip-to_ip>` — rewrite a Docker-internal IP to the host's public one in published
  SDP candidates.
* `--app-name`, `--app-download-url`, `--app-url-protocol` — brand the landing page for a
  custom client.

Signalling is over HTTP for localhost and HTTPS when a TLS proxy fronts the place.

Also runnable from Xcode: open the package, pick the AlloPlace scheme, set the same
flags as Run arguments.

`swift run demoapp alloplace2://localhost:9080` connects the minimal example alloapp.

Wondering whether your entity actually made it into the world, and with which components?
`GET /debug/entities?token=<-t value>` on the place's HTTP port dumps the live world state as
JSON `{revision, entities: [{id, owner, components}]}` — filter it with jq instead of scraping
`/dashboard`. Gated on the app token; a place started without `-t` refuses (nothing to gate on).

### Linux

CI builds and the Docker image run on Linux (amd64 + arm64) using the `alloheadless`
transport; `alloclient` and `AlloReality` are Apple-only. See `Dockerfile`.

## Documentation

Start at [docs/index.md](docs/index.md) — architecture, the asset protocol, writing your own
alloapp, rendering measurements, gotchas, history.

Building a widget or extension for a place — your own, or a hosted one like a Koja workplace?
[docs/writing-an-alloapp.md](docs/writing-an-alloapp.md) is the guide.

Alloverse 1's conceptual documentation at [docs.alloverse.com](https://docs.alloverse.com)
(e.g. [the architecture overview](https://docs.alloverse.com/concepts/architecture)) is still
useful background: places, visors, alloapps, and the entity/component model carry over, but
allonet2's protocol details (this README, this repo's docs/) differ throughout.
