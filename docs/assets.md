# Assets

An **asset** is an immutable blob — a mesh, a texture, a sound — that entities refer to by content
address rather than by name. Implementation details, pitfalls and measured costs live in
[assets-implementation.md](assets-implementation.md); this is the shape of the thing.

## Vocabulary

**`AssetID`** is the address: `sha256:` followed by 64 lowercase hex digits, and nothing else parses.
It is derived from the bytes alone, so the same bytes are the same id everywhere, forever. Because
it names content rather than a location, an id is safe to cache indefinitely and safe to hand to
anyone; because it is *only* content, an id tells you nothing about who published it or what it is.

**`AssetStore`** is a directory of those blobs. The place has one and so does every client — the
same type, the same layout, once as the origin and once as a cache:

```
<hex>.<ext>   the bytes; extension derived from the media type
<hex>.type    the media type, written last — its presence is the promise the bytes landed
```

The extension exists because loaders dispatch on it (RealityKit has no data-based USDZ loader). It
is a convenience derived from the declared media type; the id still comes from content alone.

**The place is the origin.** Assets are served over the same HTTP server that does signalling, so
`GET place/assets/{id}` is never less reachable than a data channel — HTTP reachability is already a
precondition of a session existing.

## Publishing and fetching

A publisher HEADs first and POSTs only on a miss, so re-publishing identical bytes costs one round
trip. A consumer GETs the first time it sees an unknown id in worldstate. There are no availability
announcements: **worldstate sync is the announcement**, and an id appearing in a component is the
signal to go get it. Publish before you reference — an id nobody has is a 404, and since the
component then never changes again, nothing would make a consumer try a second time.

Reads are open; writes are not. `POST /assets` needs a bearer token the place mints at announce and
revokes on disconnect, so publishing is a privilege of having a session — the HTTP request carrying
the bytes has no other way to say who it is. That token is a live credential: never log an
`InteractionBody` whole, because `announceResponse` carries it and visors stream their logs back to
the place. GET and HEAD stay unauthenticated on purpose, since assets are immutable, cacheable by
any intermediary, and you need the content hash to ask for one at all.

The flow does not reverse. Alloapps and visors have no inbound reachability — that is why signalling
is a POST *to* the place — so a place-initiated fetch would have to ride the data channel and
rebuild allonet1's chunking and back-pressure. Lazy pull, if it ever lands, moves only the *trigger*
in-band and still needs this token on the POST that follows.

## Media types

The publisher declares one, and it decides the stored extension and therefore which loader can open
the file. `application/octet-stream` is the default for "I didn't say". When two publishers upload
identical bytes under different types, a specific claim corrects that default and the blob is
renamed to match; otherwise the first specific claim stands, since nothing here can adjudicate
between two of them. Without that rule one lazy publisher would poison an id for everybody.

## Meshes

`Model.mesh == .asset(id:)` means the file at that address *is* the entity's visual, opaquely —
nothing addresses inside it, and its own materials are its materials. `RealityViewMapper` loads it
by extension: `glb` through GLTFKit2, `usdz`/`usda` through `Entity(contentsOf:)`, anything else a
typed `AssetVisualError`. So ship one asset per thing that needs its own entity: a room is many
entities, one per part, not one big file.

Everything in that file is a peer's choice, and only the hash was checked on the way in. A malformed
one must therefore fail as an error rather than a crash — which takes real work, because the
underlying loaders trap where they should throw. That is the bulk of
[assets-implementation.md](assets-implementation.md).

## Not done yet

There is no GC and no quota, so a connected agent can still fill the place's disk — the token bounds
*who* can write, not how much. A consumer download is likewise uncapped: a malicious place can hand
a client more bytes than it asked for, and the hash is only checked once the file has landed.
