# Voice: implementation notes

Decisions behind [voice.md](voice.md), and the things that bit. Read voice.md first.

## Why data channels

With WebRTC media, every stream a listener gained or lost cost an SDP renegotiation - one
offer/answer round trip per stream per receiver, serialised through the place. Adding or
removing a data channel in-band costs nothing on the signalling path, so `DataChannelForwarder`
never calls `scheduleRenegotiation()`; the E2E tests assert the renegotiation counter stays
at zero through connect, stream open, forwarding and listener churn. `PlaceServerSFU` is
unchanged: it still reconciles desired/available/active streams; only `forward()`
behaves differently underneath it.

The second reason was getting googlewebrtc out of the client. Voice was the last thing using
its media plane; with voice on data channels the client runs on the same libdatachannel
transport as the server, `UIWebRTCTransport` is gone, and `LiveKitWebRTC.framework` (27 MB in
the app bundle) with it. This is possible because visionOS is not a build target; the
xcframework has no slice for it.

## The seam that was kept

`MediaStream.render() -> AudioRingBuffer` is unchanged, so `SpatialAudioPlayer` and KojaApp
needed no source changes. The one edit on that side *removed* a force-cast: the AVFoundation
read helpers moved from the `AVFAudioRingBuffer` subclass to an extension on `AudioRingBuffer`,
so the new path hands back a plain ring buffer. `AlloUserClient` keeps `micEnabled`,
`speakerEnabled` and `createMicrophoneTrackIfNeeded()`.

## Playout is self-clocking

Playout refills the ring buffer to a target level rather than decoding on a 20 ms timer. The
device drains at its true hardware rate, so a level-triggered refill follows it; a timer would
drift against the device and eventually underrun or overflow.

## Jitter buffer

- An empty buffer is an **underrun, not a loss**. The first version advanced the playhead on
  an empty slot, which put it one frame ahead of arrival for good: every later frame "late",
  every slot concealed, and which direction broke was a coin flip at priming. It now re-primes.
  Regression test: `resumesFromTheNextFrameAfterAnUnderrun`.
- FEC reaches one frame back, so two consecutive losses conceal the older slot.
- **Stopping playout resets the buffer.** Nothing arrives while stopped, so what is left when
  playout starts again is as old as the pause: up to `maximumDepth * 2` frames the listener
  already missed, played before anything current, leaving the playhead behind the sender for
  the rest of the stream. Regression test: `replayDoesNotStartOnFramesBufferedBeforeTheStop`.

## Stream lifetime

A stopped forwarder must **close its channel**. Otherwise the receiver keeps an adopted stream
that never carries another frame: a listener who joined while a crashed speaker's stream was
still advertised (ICE consent expires after ~20 s) played silence for the rest of the session.
Test: `testStoppingAForwarderRemovesTheStreamFromTheListener`.

Fixing that needed two more things. AlloDataChannel now drops *remotely* closed channels from
`dataChannels`, not only locally closed ones. And every channel's closed callback fires when
its peer connection goes down - after disconnect has already reported those streams removed -
so `AlloSession` reports each removal once.

## Threads

libdatachannel calls back from its own threads, and `@Published` emits on `willSet`, so the
value a sink is handed is the one *about to be replaced*. The rule everywhere on this path:
subscribe to be woken, hop to the main actor (`onMain` in `DataChannelTransport`), then
read the property - never act on the value the sink delivered. Tests use `waitUntil`, which
reads the property on a short poll, for the same reason.

Frames are the one exception to "hop first": subscribe to a channel's messages on the thread
that created it, because an in-band channel starts delivering the moment it is adopted and a
hop would drop the first frames. `DataChannelMediaStream` fans frames out through a locked
observer list (`FrameObservers`) rather than `@Published`.

**Touching the jitter buffer means holding the stream's lock across the decision and the
touch.** Stopping playout empties the buffer and `render()` numbers a new playout, so a check
a thread can be suspended after is no check at all: the network thread would insert a pre-stop
frame into the cleared buffer, and a cancelled pump's last tick would dequeue the replacement's
first frame into a ring nobody reads. Nothing expensive goes inside that section - the decoder
is read before it and runs after it. Regression tests:
`aFrameInFlightAcrossTheStopIsNotBuffered`,
`aTickSuspendedBeforeItsDequeueTakesNothingFromTheNextPlayout`.

## One engine

`VoiceEngine` owns the single `AVAudioEngine`: Apple's voice-processing input node on one
side, an `AVAudioEnvironmentNode` fed by one `AVAudioSourceNode` per incoming stream on the
other. Capture and playout used to be two engines (and in the app, RealityKit's audio), so the
voice processor cancelled nothing we rendered and *ducked* it instead - which the old code
fought by pinning `voiceProcessingOtherAudioDuckingConfiguration` to its minimum. With one
engine there is nothing foreign left to duck.

- Voice processing swaps the I/O unit, so it can only be toggled on a **stopped** engine and is
  fixed for the engine's lifetime (`VoiceEngine(voiceProcessing:)`, `VOICEDEMO_NO_VPIO`). A
  listener who starts speaking after playout began restarts the graph once.
- The engine touches `inputNode` only when capture is asked for: that first touch is what
  prompts for microphone access, and tone-mode `voicedemo` and a silent listener must not
  prompt.
- Mute is `isVoiceProcessingInputMuted` *plus* dropping what the frame accumulator has queued -
  never stopping the engine, which would take playout's echo reference away. So unmuting never
  flushes audio captured while muted, and the OS microphone indicator stays lit (voice.md,
  Known limitations).
- Apple's voice processor hands the input tap a `DiscreteInOrder` layout - on a Mac mini with
  a USB webcam microphone, four identical channels at 16 kHz - and `AVAudioConverter` has no
  downmix rule for discrete channels: without an explicit `channelMap` it maps none and emits
  silence. The engine sets the map. Before it did, every counter reported voice flowing while
  nothing had been captured, which is why it logs the raw tap's per-channel peaks: a silent
  microphone reads zero everywhere, a conversion that drops the signal does not.
- `VOICEDEMO_NO_VPIO=1` captures in the device's native format, to take the voice processor
  out of a diagnosis.

## Spatialisation

RealityKit says where things are; the audio engine decides what that sounds like.
`SpatialAudioPositionSystem` runs once per rendered frame and pushes, in metres relative to the
`SpatialAudioFieldComponent` entity: the listener's position and forward/up axes, every
speaking entity's position, and the occlusion raycast's verdict (0 dB clear, -100 dB blocked).
The field entity is the unit fix - a place is drawn as a diorama, so distances at the scene
root are centimetres or less and only field-relative ones are metres.

Falloff is ours, not the environment node's. `VoiceEngine.gain(atDistance:)` is the entire curve:
full gain within `referenceDistance` (1.5 m), then `20 * log10(referenceDistance / distance) *
rolloff` dB, faded to zero over the last tenth before `maxDistance` (10 m) so the cutoff has no
audible step. The environment node's own attenuation is neutralised with a zero rolloff, which is
unity gain at every distance, so the two cannot multiply. Letting it own the curve instead was
tried and rejected by ear: its `.inverse` model dives in the first few metres, plateaus mid-room,
and then ends in a hard cut, because `maximumDistance` only stops attenuation growing rather than
silencing. `VoiceEngine.referenceDistance` / `.maxDistance` / `.rolloff` are the knobs, and one
public function is what lets the app's earshot ring draw the curve playout actually renders.

That gain reaches a source as its node volume, multiplied with the two independent silencing
reasons (`VoiceEngine.volume(audible:occlusion:)`). The engine keeps the listener position, so a
listener who moves re-applies every source's gain without the position system having to ask.

The environment node spatialises **mono inputs only**, which is why every source node is one
channel. The rendering algorithm is `.HRTFHQ` unconditionally: customers listen on headphones, and
`.auto` never picks HRTF on a stereo output device, which left spatial voice as flat equal-power
panning. Choosing by output device is a separate card. HRTF has a gain floor - a source at volume
0 renders at exactly -120 dB of full scale, on every block, rather than at digital zero - so
silencing is inaudible but not free.

`VoiceEngine.isAudible` is a second, harder cutoff on top of the curve, decided per frame by the
position system, with a 2 % dead band so a source hovering at the edge doesn't chatter.

Volume, and not occlusion: occlusion is mostly a lowpass, it clamps at -100 dB, and even there it
leaves about -25 dB of signal - audible across a place. So a blocked raycast silences through the
same volume the distance cutoff uses (`VoiceEngine.volume(audible:occlusion:)`, the two reasons
kept apart so neither overrides the other), the way the hand-rolled gain went to -inf; occlusions
between the two ends still muffle through the filter, which is what it is good for. `EnvironmentNodeRenderingTests` pins both,
and the reason the second one is easy to get wrong: the gain *ramps*, so a level measured in the
first render block still shows the old one. Measuring there is how silencing was once reported,
confidently and wrongly, as a no-op.

`VoiceSourceComponent` ties an entity to the stream coming out of it, so the system reads
everything it needs off the scene and holds no reference back to `SpatialAudioPlayer`.

The one property nobody can hear their way to is whether the environment node's stereo survives
to the device - the voice processor's I/O unit can change the output format. `VoiceEngine` logs
`environment out` and `device out` when it starts; a mono device format means the spatialiser
was flattened downstream.

## Tests

- Peers in tests bind to `127.0.0.1` so a test never depends on the host's interfaces. For
  two weeks `bindAddress` was accepted by `TransportConnectionOptions` and dropped before it
  reached `AlloWebRTCPeer`, so the tests gathered on every interface while the docs said
  otherwise; honouring it costs about 2 s more per E2E test, somewhere between connect and
  announce, which is not yet explained. `AlloPlace -b` and `VOICEDEMO_BIND` reach the same
  option.
- Tear peers down before a test returns: `PlaceServer.stop()` and client `disconnect()` must
  be awaited, or the process segfaults at exit while peers are still closing.
- `Scripts/soak-e2e.sh N` runs the E2E suite N times under a hang watchdog; the merge gate is
  20/20.

## Measured

2026-08-22, two tone-mode `voicedemo` instances and a place on one Mac mini, ~70 s:

| receiver | p50 | p95 | jitter depth | ring |
|---|---|---|---|---|
| A | 133 ms | 144 ms | 3 frames | 51-77 ms |
| B | 174 ms | 189 ms | 4-5 frames | 52-77 ms |

2026-08-23, the same setup on the one-engine graph (tone mode, so no voice processor):

| receiver | p50 | p95 | jitter depth | ring |
|---|---|---|---|---|
| A | 85 ms | 95 ms | 1-2 frames | 51-79 ms |
| B | 85 ms | 94 ms | 0-1 frames | 51-79 ms |

Not a controlled comparison - a run primes at whatever depth its first arrivals suggest, and
that is where most of the number lives - but routing playout through the environment node cost
no latency.

Capture-to-render, same wall clock; the output device adds 1.3 ms on top
(`outputNode.presentationLatency`). An earlier run sat at 250 ms in both directions for
minutes with zero underruns: the jitter buffer primes at whatever depth the first bursty
arrivals suggest and **never shrinks**, so prime-time backlog becomes permanent latency. The
jitter buffer and the ring buffer account for nearly all of the number; the network and the
codec are a few ms. Reproduce with `VOICEDEMO_LATENCY_LOG` and `Scripts/voice-latency.sh`.

Earlier the same day, by ear through speakers with a real microphone: voice round-trips, zero
`late` frames either way, no howling with mic and speakers far apart.
