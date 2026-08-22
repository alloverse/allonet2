# Voice

Voice is Opus audio carried as frames on WebRTC **data channels**. There is no WebRTC media
plane: no tracks, no m-lines, no offer/answer when a stream starts or stops. A stream is a
data channel; the bytes on it are the frames below; the place server copies them between
channels without decoding.

## One stream, one channel

A voice stream is a data channel whose label is `voice/<mediaId>`. The label is the stream's
identity, so frames carry no stream id and nothing is demultiplexed.

Channels are opened **in-band**: the sender creates the channel with `negotiated: false`, and
libdatachannel announces it over DCEP (Data Channel Establishment Protocol, RFC 8832) - a
`DATA_CHANNEL_OPEN` message sent on the SCTP stream itself, carrying the label and the
reliability. The receiver learns about the stream from that message. No SDP is exchanged.

Channels are **unordered with zero retransmits**: a voice frame that arrives after its play
slot is worthless, and a retransmission only delays the frames behind it.

    Speaker                        Place (SFU)                         Listener
       |                               |                                  |
       | create channel "voice/A"      |                                  |
       |------ DCEP OPEN ------------->| adopt stream A                   |
       |<----- DCEP ACK ---------------|                                  |
       |                               | forward(A -> listener):          |
       |                               | create channel "voice/A'"        |
       |                               |------ DCEP OPEN ---------------->| adopt stream A'
       |                               |<----- DCEP ACK ------------------|
       |====== frame seq N ===========>|====== frame seq N (same bytes) =>| jitter -> decode -> ring
       |====== frame seq N+1 =========>|====== frame seq N+1 ============>|
       |                               |                                  |
       | close channel                 |                                  |
       |------ SCTP stream reset ----->| forwarder stops, closes A'       |
       |                               |------ SCTP stream reset -------->| stream A' removed

`A'` is the place-side id: the speaker's short client id plus its media id, so two speakers'
streams never collide at a listener.

## Frame format

Nine-byte header, big-endian, then the codec payload:

  0               1               2               3               4
  0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |      kind     |                            sequence                           |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                           timestamp                           | payload ...
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

- `kind` (u8): `0` Opus, `1` Float32 PCM (tests only). Exists so a control message could
  share the channel later without a format change.
- `sequence` (u32): one per frame, wraps.
- `timestamp` (u32): playout position of the frame's first sample, in samples since the
  stream started. 48 kHz, 20 ms frames: advances by 960 per frame.
- payload: one Opus packet, 48 kHz mono, 20 ms, ~32 kbit/s.

## Pipeline

    capture -> encode -> frame -> channel -> [place: copy bytes] -> channel -> jitter buffer -> decode -> ring buffer -> device

`DataChannelMediaStream` is the stream in all three roles: a sender encodes and writes, the
place routes, a receiver buffers and decodes. `DataChannelForwarder` is the entire server-side
media path: it copies bytes from one channel to another.

On the receiver, the jitter buffer (`JitterBuffer`) holds frames by sequence and hands out
one 20 ms step at a time; its depth adapts to observed arrival jitter. Decoded audio goes into
an `AudioRingBuffer` that the audio device drains at its own rate.

## Loss handling

libwebrtc never retransmitted voice either; this keeps the same two tools, both inside Opus:

- **FEC (forward error correction).** Each Opus frame can carry a coarse copy of the previous
  frame. If frame N is missing but N+1 arrived, the decoder reconstructs N from N+1, and N+1
  then plays normally in its own slot. Reaches one frame back only.
- **PLC (packet loss concealment).** For a frame that is missing and not recoverable, the
  decoder is told so and extrapolates 20 ms from what it last decoded, instead of playing
  silence.

## Counters

`VoiceCounters` are values tests assert on, not log lines. On a receiver every `received`
frame ends up exactly one of `decoded`, `late`, `duplicate`, `malformed`, `overflowed`, or
still buffered; every 20 ms of playout is exactly one of `decoded`, `fecRecovered` or
`concealed`. `late` means the network was slower than the buffer depth; `overflowed` means
nothing is draining playout. They call for opposite fixes, so they are never merged.

## Codec

libopus 1.4 is vendored (`Packages/opus`, BSD-3-Clause, see `LICENSES.md`) and built as a
SwiftPM C target, so every platform gets the same codec with no per-machine setup. The place
server links no codec: it never decodes.

## Limits

A peer opens voice channels in-band, before it has announced anything, so both ends of the
channel are a trust boundary and both are bounded:

- **Eight adopted streams per transport** (`HeadlessWebRTCTransport.maximumMediaStreams`).
  The ninth channel a peer opens is closed rather than adopted, with a warning naming the
  media id. Outgoing streams don't count, so a place forwarding to a listener is unaffected -
  but a listener hearing more than eight speakers at once is not yet possible.
- **`maximumFrameBytes` per message** - one uncompressed Float32 frame, the most verbose
  kind the format has. Anything larger counts as `malformed` and is dropped before the
  fan-out, so no forwarder re-emits it and no jitter buffer holds it.
- **A media id may not contain a period.** The place names a forwarded stream
  `<shortClientId>.<mediaId>` and parses it back as exactly two components.
  `createOutgoingMediaStream` throws `MediaStreamIdError.containsPeriod` rather than opening
  a stream every listener would ignore.

## Known limitations

- **Echo cancellation does not cover our own playout.** Capture uses Apple's voice processor
  (echo cancellation, gain control, noise suppression), but it only cancels audio that its
  own `AVAudioEngine` rendered, and playout runs on a separate engine - in KojaApp, through
  RealityKit spatial audio. On speakers, a listener's playout can feed back into their
  microphone uncancelled. The fix is at the app's audio-graph level: route voice playout
  through the capture engine, or keep the two graphs and accept headphones.
- **Apple platforms other than macOS need libdatachannel slices.** `datachannel.xcframework`
  ships `macos-arm64` and `linux-x86_64`. iOS or visionOS clients need their slices added in
  AlloDataChannel's `Scripts/build-libdatachannel.sh` first.

## Running it

    swift test --filter VoiceE2ETests        # real place + real clients over loopback
    ./Scripts/soak-e2e.sh 20                 # the same, 20 times, with a hang watchdog
    swift run AlloPlace -p 9180 -u 12000-13000
    swift run voicedemo alloplace2://localhost:9180            # microphone in, voice out
    VOICEDEMO_TONE=440 swift run voicedemo alloplace2://...    # a sine instead of the mic; no permission prompt
    VOICEDEMO_NO_VPIO=1 swift run voicedemo alloplace2://...   # capture without the voice processor
    VOICEDEMO_LATENCY_LOG=/tmp/lat.log swift run voicedemo ... # both instances: capture/render times per frame
    Scripts/voice-latency.sh /tmp/lat.log                      # p50/p95 capture-to-render per receiver

With two instances on one machine the log joins on the shared clock: mouth-to-speaker latency,
minus the output device's own latency, which `voicedemo` reports separately. Pass `-b 127.0.0.1`
to the place and `VOICEDEMO_BIND=127.0.0.1` to the demos to keep a local test off the network.

Give each place its own HTTP port *and* UDP range when several run on one machine; media on
the default 10000-11000 collides and looks like a voice bug. `voicedemo` prints counters every
5 s; `capPeak`/`playPeak` are the loudest sample in that window, so a stream with frames but
no peak is silent, not slow.
