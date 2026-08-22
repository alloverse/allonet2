# Voice: implementation notes

Decisions behind [voice.md](voice.md), and the things that bit. Read voice.md first.

## Why data channels

With WebRTC media, every stream a listener gained or lost cost an SDP renegotiation - one
offer/answer round trip per stream per receiver, serialised through the place. Adding or
removing a data channel in-band costs nothing on the signalling path, so `DataChannelForwarder`
never calls `scheduleRenegotiation()`; the E2E tests assert the renegotiation counter stays
at zero through connect, stream open, forwarding and listener churn. `PlaceServerSFU` is
unchanged: it still reconciles desired/available/active streams; only `Transport.forward()`
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
subscribe to be woken, hop to the main actor (`onMain` in `HeadlessWebRTCTransport`), then
read the property - never act on the value the sink delivered. Tests use `waitUntil`, which
reads the property on a short poll, for the same reason.

Frames are the one exception to "hop first": subscribe to a channel's messages on the thread
that created it, because an in-band channel starts delivering the moment it is adopted and a
hop would drop the first frames. `DataChannelMediaStream` fans frames out through a locked
observer list (`FrameObservers`) rather than `@Published`.

## Capture

- Apple's voice processor hands the input tap a `DiscreteInOrder` layout - on a Mac mini with
  a USB webcam microphone, four identical channels at 16 kHz - and `AVAudioConverter` has no
  downmix rule for discrete channels: without an explicit `channelMap` it maps none and emits
  silence. `VoiceCapture` sets the map. Before it did, every counter reported voice flowing
  while nothing had been captured, which is why `VoiceCapture` logs the raw tap's per-channel
  peaks: a silent microphone reads zero everywhere, a conversion that drops the signal does not.
- The voice processor **ducks audio it did not render itself**, including our playout engine.
  `voiceProcessingOtherAudioDuckingConfiguration` is set to the minimum. One engine for capture
  and playout would remove the ducking and give the echo canceller its reference; see the
  limitation in voice.md.
- `VOICEDEMO_NO_VPIO=1` captures in the device's native format, to take the voice processor
  out of a diagnosis.

## Tests

- Peers in tests bind to `127.0.0.1`. A headless test process on this host gathers no ICE
  candidates otherwise, and loopback pairs connect in ~5 ms.
- Tear peers down before a test returns: `PlaceServer.stop()` and client `disconnect()` must
  be awaited, or the process segfaults at exit while peers are still closing.
- `Scripts/soak-e2e.sh N` runs the E2E suite N times under a hang watchdog; the merge gate is
  20/20.

## Heard live

2026-08-22, two `voicedemo` instances on one Mac mini through speakers, webcam microphone:
voice round-trips, zero `late` frames either direction over minutes, mouth-to-speaker delay
felt like 200-500 ms, no howling - with the caveat that mic and speakers were far apart. A
measured pipeline latency is the next number to get; ears gave a range.
