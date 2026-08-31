# Glossary

One canonical term per concept. When code, docs or conversation disagree about a word, this
file decides; if the decision looks wrong, change the file rather than the usage. Discouraged
synonyms are listed because they are in the tree today — they are what you will read, not
alternatives you may write.

## The three parties

**place** — the shared 3D space, and the server process holding it (`PlaceServer`, shipped as
the `AlloPlace` executable). One authoritative state, one endpoint, so the space and the
server are deliberately the same word.
*Discouraged: world, room, scene, space.* The `worldstate` data channel keeps its wire name.

**agent** — any process connected to a place: a visor or an alloapp. It is what owns entities
and what an interaction is addressed to.
*Note:* `AGENTS.md` uses "agent" for an LLM coding assistant. Same spelling, unrelated concept
— say "coding agent" for that one.

**visor** — a 3D application that renders a place for a human, essentially a 3D browser
(`AlloUserClient` + `AlloReality`).
*Discouraged: client* (too broad; `AlloAppClient` is one too), *viewer, app.*

**alloapp** — a headless agent with app identity that contributes content to a place
(`AlloAppClient`). Runs alongside the place but has a client-shaped API.
*Discouraged: widget, app, extension.*

**user** — the human. Not a synonym for visor, agent or avatar.

## The place and its state

**place contents** (`PlaceContents`) — one immutable, revisioned snapshot of everything in a
place: its entities and their components.
*Discouraged: world, world state.*

**place state** (`PlaceState`) — the mutable container around the current place contents: the
history behind it, the latest changeset, and the observers. Not interchangeable with place
contents — one is the box, the other is what is in it right now.

**revision** — the place contents' version number, bumped only by a beat that actually changes
something. Unrelated to the *protocol* version exchanged in `announce`.

**changeset** (`PlaceChangeSet`) — the changes between two revisions, and the unit in which
state reaches an agent.
*Discouraged: delta, diff, update, world update.*

**announce** — the interaction that turns a connected agent into a participating one: it
presents identity and an avatar description, and the place answers with the avatar's entity id
and an asset token. Before it, an agent has a connection and nothing else.

## Entities and geometry

**entity** — a thing in a place: an id plus an owner. Every attribute is a component. Spelled
`eid` where a short local name is wanted; `EntityID` is the type.

**component** — one typed attribute of an entity (`Transform`, `Model`, `Collision`, …). The
only place entity data lives.

**avatar** — the entity the place creates for an agent at announce, and the root of everything
that agent hangs off itself. Alloapps have one too, not just visors.

**place space** — a place's own coordinate frame, in metres: what every `Transform` chain
composes into. `Entity.transformToWorld` and `PlaceContents.transformToWorld(of:)` produce it
despite their names.
*Discouraged: world space, field space, scene space.* A renderer's own frame is renderer space,
and is nobody else's business — a place drawn as a diorama is still authored in metres.

**peer** — whoever authored the data you are holding. Used as a trust statement: "the string is
a peer's word" means validate it before you act on it.

## Talking to a place

**interaction** (`Interaction`) — a reliable message between agents, or between an agent and
the place: request, response, oneway or publication. The RPC mechanism.
*Discouraged: message, RPC call.*

**intent** (`Intent`) — the unreliable state an agent sends up every heartbeat: movement
direction, grab, and the revision it has acked. The place simulates it; it is never applied
verbatim.
*Discouraged: input, command.*

**session** (`AlloSession`) — the protocol layer over one transport: the three fixed data
channels, CBOR coding, renegotiation. Replaced wholesale on every reconnection, which is why
subscriptions to it have to be rebound.

**transport** (`Transport`, `DataChannelTransport`) — the connection underneath: ICE, data
channels, media forwarding. One session, one transport.

## Voice and spatial audio

**media stream** (`MediaStream`, `MediaStreamId`) — one one-way flow of media; today one data
channel carrying one mono voice stream. Nothing is multiplexed inside one and nothing bundles
several.
*Discouraged: track, audio track, RTP track.* "Track" survives in `AudioTrack` /
`MicrophoneTrack`, which are on/off switches over a stream rather than a media concept, and in
`README.md`, which still describes voice as SRTP tracks and is stale.

**forward** — what the place's SFU does with a media stream: copy it to the agents whose
`LiveMediaListener` asks for it.
*Discouraged: relay, mix* — nothing is mixed.

**listener** — the entity whose position and orientation are the local user's ears.

**source** — a media stream being played back, positioned at the entity carrying its
`LiveMedia`.
*Discouraged: talker.*

**speaker** — the audio output device, and nothing else; `AlloUserClient.speakerEnabled` is
that sense. For the person, say *source* or "the entity speaking".

**occluder** — an entity whose `Collision` shapes block voice between a listener and a source;
marked with the `AudioOccluder` component today.
*Discouraged: wall, blocker, obstruction.*
Occlusion is binary: `setOcclusion` is full attenuation or none, so a curtain and a concrete wall
sound the same. Graded occlusion is an acoustic material with an absorption coefficient, of which
"occludes" is absorption 1 — so `AudioOccluder` would gain a coefficient rather than be replaced,
and the term survives either way.

**deafened** — not playing others' audio, and asking the place to stop forwarding it
(`speakerEnabled == false`). Distinct from **muted**, which is the microphone: capture keeps
running so the echo canceller keeps its reference, and the frames are dropped.

## Clocks

**beat** — one cycle of the place's broadcast loop: drain the queued changes, commit their net
effect, spend a revision if anything really changed, broadcast. Self-clocking, coalesced at
20 ms.

**tick** — one step of a server-side simulation (movement, grab), also 20 ms. A different clock
from the beat; `PlaceContents.revision`'s own doc comment calls a beat a "server tick", which
is wrong.

**heartbeat** (`HeartbeatTimer`) — the timer that drives a beat, and the client's matching
intent send. The thing that fires, not the thing that happens.
