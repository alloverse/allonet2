# Documentation index

Deep documentation lives here: architecture, protocol mechanics, and hard-won facts that
aren't easily rediscovered from the code. Pick the doc whose situation matches yours.

| Doc | Read it when… |
| --- | --- |
| [glossary.md](glossary.md) | You are naming something, or two words in the tree seem to mean the same thing and you need to know which one to write. |
| [architecture.md](architecture.md) | You need the module map: which target does what, and how state sync, the wire, auth or reconnection actually work. |
| [writing-an-alloapp.md](writing-an-alloapp.md) | You want to build your own alloapp — a widget or extension for a place, your own or a hosted Koja one. |
| [assets.md](assets.md) | You publish, fetch or name an asset, and want to know what content addressing buys you and what the rules are. |
| [assets-implementation.md](assets-implementation.md) | You are inside the asset pipeline: the place's HTTP server (FlyingFox has teeth), or making a peer's mesh fail as an error instead of a crash. |
| [voice.md](voice.md) | You touch voice or any other media stream: how a stream becomes a data channel, stream kinds and their reliability, the media frame format, loss handling, counters, how to run it. |
| [voice-implementation.md](voice-implementation.md) | You change the voice path and want the decisions, the thread rules, and the bugs that were already found once. |
| [realitykit-rendering.md](realitykit-rendering.md) | You render `Text` or textured materials through RealityKit and the geometry or alpha looks wrong. |
| [gotchas.md](gotchas.md) | Something behaves weirdly — a component won't decode, audio dies after reconnect, a client won't leave. |
| [history.md](history.md) | You wonder why Swift, why WebRTC, what happened to ProtoBuf — or whether Windows works. |
