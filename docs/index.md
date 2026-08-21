# Documentation index

Read the doc whose situation matches yours. This index is `@`-included into every session; the
docs themselves are not, so the "read it when…" column is what makes them reachable.

| Doc | Read it when… |
| --- | --- |
| [architecture.md](architecture.md) | You need the module map: which target does what, and how state sync, the wire, auth or reconnection actually work. |
| [assets.md](assets.md) | You touch anything that publishes, fetches or names an asset — or the place's HTTP server (FlyingFox has teeth). |
| [realitykit-rendering.md](realitykit-rendering.md) | You render `Text` or textured materials through RealityKit and the geometry or alpha looks wrong. |
| [gotchas.md](gotchas.md) | Something behaves weirdly — a component won't decode, audio dies after reconnect, a client won't leave. Also where a new non-obvious fact lands by default. |
| [history.md](history.md) | You wonder why Swift, why WebRTC, what happened to ProtoBuf — or whether Windows works. |

When you learn something deep that isn't easily rediscovered from the code, fold it into the
matching doc — or start a new one — and add its row here. The docs are the project's memory.
