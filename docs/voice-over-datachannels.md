# Voice over data channels

Voice travels as Opus frames on unreliable data channels, not as WebRTC media. There are no
m-lines, no offer/answer for media, and no RTP crossing between libwebrtc and libdatachannel.

## Shape

One stream is one data channel. The channel label carries the id (`voice/<mediaId>`), so
there is nothing to demultiplex and no stream id in the frame header. Channels are opened
**in-band** (`negotiated: false`) — the far side discovers them over DCEP — and are
**unordered with zero retransmits**, because a retransmitted voice frame arrives too late to
play.

Frame header is 9 bytes, big-endian: `kind` (u8), `sequence` (u32), `timestamp` in samples
(u32), then payload. `kind` exists so a later control message can share the channel without
a format change.

    capture → encode → VoiceFrame → channel → [SFU: copy bytes] → channel → jitter → decode → AudioRingBuffer

`DataChannelMediaStream` is all three roles: a sender encodes and writes, the server routes
without decoding, a receiver buffers and decodes. `DataChannelForwarder` is the entire SFU
media path — it copies bytes between channels and **does not renegotiate**, which is the
churn this design exists to delete (previously one renegotiation per stream per receiver).

`PlaceServerSFU` is unchanged: it still reconciles desired/available/active, only
`Transport.forward()` behaves differently.

## The seam that was preserved

`MediaStream.render() -> AudioRingBuffer` is untouched, so `SpatialAudioPlayer` and KojaApp
did not have to change. The one edit was *removing* a force-cast: the AVFoundation read
helpers moved from the `AVFAudioRingBuffer` subclass to an extension on `AudioRingBuffer`,
so the new path can hand back a plain ring buffer.

Playout refills the ring to a target level rather than decoding on a fixed schedule. The
audio device drains at the true hardware rate, so refilling to a level self-clocks; a 20 ms
timer would slowly drift against the device.

## Loss handling

libwebrtc never retransmitted audio either. Recovery is:

- **In-band FEC** — frame N+1 carries a coarse copy of frame N. If N is missing but N+1
  arrived, the jitter buffer emits `.recoverFromFEC(next:)` and the decoder reconstructs N
  from N+1's payload. N+1 stays buffered and plays normally in its own slot.
- **PLC** — a nil payload makes Opus extrapolate from what it already decoded, rather than
  inserting silence.

FEC only reaches one frame back, so two consecutive losses conceal the older slot.

## Gotchas

- **`waitFor` on a `@Published` property used to hang the process, not fail.** On timeout the
  task group cancelled a child suspended in `withCheckedContinuation`, which ignores
  cancellation, so the group never drained. Fixed in AlloDataChannel, but the shape is worth
  recognising: any `withCheckedContinuation` inside a task group needs
  `withTaskCancellationHandler`.
- **Prefer polling a property over subscribing, for libdatachannel state.** It publishes from
  its own threads; `waitUntil { peer.state == .connected }` reads the truth, a subscription
  races it.
- **Subscribe to a channel's messages on the thread that created it.** For in-band channels
  that is libdatachannel's network thread, inside the `dataChannels` observer — which is why
  `DataChannelMediaStream` uses a locked fan-out (`FrameObservers`) rather than `@Published`
  for frames.
- **This host gathers zero ICE candidates in a headless test process.** Tests and the E2E
  harness pass `bindAddress: "127.0.0.1"`, which also makes peer pairs connect in ~5 ms.
- **Tear down peers before the test returns.** `PlaceServer.stop()` and client `disconnect()`
  must be awaited; letting a test return while peers are closing segfaults at process exit.
- **Apple's echo canceller only cancels what it renders.** `setVoiceProcessingEnabled(true)`
  on the input node gives AEC/AGC/NS, but voice played through a different graph (RealityKit
  spatial audio) is not in its reference signal. Verify echo with speakers, not headphones.

## libopus

Vendored as a submodule (`Packages/opus`, v1.4, BSD-3) and built as a SwiftPM C target, so
macOS, visionOS and Linux get the same codec with no per-machine setup. Architecture-specific
kernels are excluded; the generic C path is far more than enough for one 32 kbit/s mono
stream. `opus_encoder_ctl` is a C variadic that Swift cannot call, hence the `COpusShim`
target.

The server links no codec at all — it only copies bytes — which is what keeps libopus off
the Linux server build. `VoiceCodecs.makeEncoder/makeDecoder` is the registry; `Opus.install()`
fills it in on clients.

## Counters

`VoiceCounters` are data, not log lines: tests assert on them. Every frame that leaves a hop
is accounted for at the next one — on a receiver, every `received` frame is eventually
`decoded`, or dropped as `late`, `duplicate`, `malformed` or `overflowed`, or still sitting
in the jitter buffer. Every 20 ms of playout is exactly one of `decoded`, `fecRecovered` or
`concealed`.

`late` and `overflowed` are deliberately separate: a late frame means the network was
slower than the buffer depth, an overflowed one means *nothing is draining playout*. They
call for opposite fixes.

## Removing googlewebrtc

Done on the branch (`ed9dc4a`) and it works on macOS — all tests green, KojaApp needs no
source changes, debug bundle 112 MB → 90 MB — but it **cannot ship until AlloDataChannel
gains platform slices**. `Binaries/datachannel.xcframework` contains only `macos-arm64` and
`linux-x86_64`, which was fine while libdatachannel was server-side only and is a hard
blocker once the client uses it:

    datachannel.xcframework: While building for visionOS Simulator, no library for this
    platform was found

`Scripts/build-libdatachannel.sh` builds those same two slices, so adding visionOS (device +
simulator, and iOS later) is real work there first. That is the single prerequisite for
deleting googlewebrtc.

- **Voice processing hands out a `DiscreteInOrder` input layout** (four identical 16 kHz
  channels on a Mac mini with a USB webcam mic), and `AVAudioConverter` has no downmix rule for
  discrete channels: without an explicit `channelMap` it maps none and emits silence. Every
  counter said voice was flowing; nothing was captured. The raw-tap peak log in `VoiceCapture`
  exists to tell a silent microphone from a conversion that drops the signal.
- **Voice processing ducks audio it did not render itself**, which includes playout on a second
  `AVAudioEngine`. `voiceProcessingOtherAudioDuckingConfiguration` is set to the minimum; one
  engine for capture and playout is the real fix and also gives AEC its reference.
- **An empty jitter buffer is an underrun, not a loss.** Advancing the playhead on an empty slot
  put it one frame ahead of arrival for good: every frame "late", every slot concealed. It
  re-primes instead, and the regression test is `resumesFromTheNextFrameAfterAnUnderrun`.
- **A stopped forwarder must close its channel.** Otherwise the receiver keeps an adopted stream
  that never carries another frame - a listener who joined while a crashed speaker's media was
  still advertised (ICE consent expiry is ~20 s) played silence for the rest of the session.
  This also needed AlloDataChannel to drop *remotely* closed channels from `dataChannels`, and
  exposed that every channel's closed callback fires when a peer connection goes down, after
  disconnect has already reported those streams: `AlloSession` reports each removal once.

## Heard live

2026-08-22, two `voicedemo` instances on one Mac mini through speakers, webcam microphone:
mouth-to-speaker delay felt like 200-500 ms (a guess, not a measurement), no howling - though
with mic and speakers that far apart, feedback is hard to provoke. Zero `late` frames in either
direction over minutes. A real latency number needs a loopback measurement, not ears.

## Running it

    swift test --filter VoiceE2ETests     # real server + real clients over loopback
    ./Scripts/soak-e2e.sh 20              # the same, 20 times, with a hang watchdog
    swift run voicedemo                   # mic in, voice out (needs a human for the mic prompt)
    VOICEDEMO_TONE=440 swift run voicedemo # a sine instead of the mic: headless, no VPIO, no prompt
    VOICEDEMO_NO_VPIO=1 swift run voicedemo # capture in the device's native format

Other agents run places on this machine: give yours its own HTTP port *and* UDP range
(`AlloPlace -p 9180 -u 12000-13000`), or media collides on the default 10000-11000 and
looks like a voice bug. Counters print every 5 s: `capPeak`/`playPeak` are the loudest sample
in that window, so a stream with frames but no peak is silent, not slow.
