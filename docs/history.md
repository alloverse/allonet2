# History and rationale

Design context from the start of the rewrite (2023–2024), kept for the "why", not the "how".
Where this file and the code disagree, the code won.

## Why a rewrite

[Allonet 1](https://github.com/alloverse/allonet) was written in C: portable everywhere, but
constant memory corruption, no abstraction, and no standard library worth mentioning.
Requirements for the rewrite:

* Interfaces with C, so it can be used over C FFI from C#, lua, C++, Java, etc, and integrated
  with any game engine or app platform
* A modern, object-oriented language also suited to functional style, with good async and
  threading support
* A package manager and a wide library of functionality

Both Swift and Rust match. Rust won't play well with my brain, despite many tries. So Swift it is.

## Protocol choices, and how they landed

* **Transport.** Allonet was always meant to ride a web-compatible udp-like protocol. QUIC or
  WebTransport would be preferable, but had no working Swift libraries, so **WebRTC** it is —
  as in allonet 1.
* **Signalling.** P2P is ignored in favour of a server-client model, so the server's SDP never
  changes and renegotiation matters less; a single HTTP(S) POST exchanges the handshake instead
  of an active signalling channel. This held, with one amendment: media tracks brought
  renegotiation back, over a data channel rather than new HTTP calls.
* **Encoding.** Allonet 1's worst part was JSON. The plan was **ProtoBuf**, with BinaryCodable
  as a stop-gap. What actually shipped is **CBOR** (via PotentCodables), which turned out to be
  the keeper: schemaless like JSON, compact like a binary format, and `Codable` end to end.
  An idea that never landed: dynamic schemas, where each agent shares the component schemas it
  publishes and the place merges them into one authoritative set.

## Windows

Early in the rewrite, allonet2 built on Windows (Swift 5.9, Developer PowerShell for VS 2019,
`swift build`). No CI covers it and no current dependency has been tried there; treat it as
unsupported until someone does.
