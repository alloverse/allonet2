# Voice

Voice is Opus audio carried as frames on WebRTC **data channels**. There is no WebRTC media
plane: no tracks, no m-lines, no offer/answer when a stream starts or stops. A stream is a
data channel; the bytes on it are the frames below; the place server copies them between
channels without decoding.

## One stream, one channel

A media stream is a data channel whose label is `<kind>/<mediaId>`: `voice/` for audio,
`video/` for pictures. The label is the stream's identity, so frames carry no stream id
and nothing is demultiplexed; the kind prefix is how the far side knows what it adopted before
a single frame arrives.

Channels are opened **in-band**: the sender creates the channel with `negotiated: false`, and
libdatachannel announces it over DCEP (Data Channel Establishment Protocol, RFC 8832) - a
`DATA_CHANNEL_OPEN` message sent on the SCTP stream itself, carrying the label and the
reliability. The receiver learns about the stream from that message. No SDP is exchanged.

The kind decides the channel's reliability (`MediaStreamKind.reliability`). `voice/` is
**unordered with zero retransmits**: a frame that arrives after its play slot is worthless, and
a retransmission only delays the frames behind it. `video/` is **ordered with a 1000 ms
lifetime**: H.264 loses every picture after a hole, so order and delivery matter, but a frame
nobody could render within a second is not worth queueing the share behind. The place forwards
a copy of a stream with the same kind, so a listener's channel is opened the way the sender's
was.

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

## Media frame format

Nine-byte header, big-endian, then the codec payload:

  0               1               2               3               4
  0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |      kind     |                            sequence                           |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                           timestamp                           | payload ...
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

- `sequence` (u32): one per frame, wraps.
- `timestamp` (u32): where the frame plays, in 48 kHz ticks since the stream started. For
  audio those ticks are its own samples, so 20 ms frames advance it by 960.
- `kind` (u8) says what the payload is, and how large it may get. The cap is per kind and is
  enforced before the fan-out, on the place and on every receiver: an oversized or
  unknown-kind message is counted `malformed` and dropped, so no forwarder re-emits it and no
  jitter buffer holds it.

| kind | payload | timestamp unit | cap |
| --- | --- | --- | --- |
| 0 `opus` | one Opus packet, 48 kHz mono, 20 ms, ~32 kbit/s | samples | 3849 B |
| 1 `pcmFloat32` | interleaved Float32, tests only | samples | 3849 B |
| 2 `h264Key` | Annex B access unit, SPS+PPS then one IDR | 48 kHz ticks | 1 MiB |
| 3 `h264Delta` | Annex B access unit, P pictures only (no B frames) | 48 kHz ticks | 256 KiB |

A well-formed frame of a kind a consumer cannot decode is not malformed: audio playout counts
it `skippedForeignKind` and forwards it anyway.

## Pipeline

    capture -> encode -> frame -> channel -> [place: copy bytes] -> channel -> jitter buffer -> decode -> ring buffer -> VoiceEngine source node -> rate node -> environment node -> device

`DataChannelMediaStream` is the stream in all three roles: a sender encodes and writes, the
place routes, a receiver buffers and decodes. `DataChannelForwarder` is the entire server-side
media path: it copies bytes from one channel to another.

On the receiver, the jitter buffer (`JitterBuffer`) holds frames by sequence and hands out
one 20 ms step at a time; its depth adapts to observed arrival jitter. Decoded audio goes into
an `AudioRingBuffer` that the audio device drains at its own rate.

The two are **one queue**, and the whole queue is the latency. `DataChannelMediaStream` measures
frames plus ring samples against the depth jitter asks for, and closes the gap by playing a
percent or two off the sender's clock (`PlayoutRateController`, applied by the rate node in front
of the spatialiser). Catching up therefore costs no audio: nothing is dropped and nothing is
inserted.

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
frame ends up exactly one of `decoded`, `late`, `duplicate`, `malformed`, `overflowed`,
`skippedForeignKind`, or still buffered; every 20 ms of playout is exactly one of `decoded`, `fecRecovered` or
`concealed`. `late` means the network was slower than the buffer depth; `overflowed` means
nothing is draining playout. They call for opposite fixes, so they are never merged.
The place status page renders them read-only, per available stream and per active forwarding.

## Codec

libopus 1.4 is vendored (`Packages/opus`, BSD-3-Clause, see `LICENSES.md`) and built as a
SwiftPM C target, so every platform gets the same codec with no per-machine setup. The place
server links no codec: it never decodes.

## Limits

A peer opens media channels in-band, before it has announced anything, so both ends of the
channel are a trust boundary and both are bounded:

- **Sixty-four adopted streams per transport** (`DataChannelTransport.maximumMediaStreams`).
  The sixty-fifth channel a peer opens is closed rather than adopted, with a warning naming
  the media id. Outgoing streams don't count, so a place forwarding to a listener is
  unaffected. Voice and video streams share the one cap.
- **`MediaFrame.Kind.maximumFrameBytes` per message**, per kind - see the table above. One
  cap for all of them would be either a keyframe that cannot fit or an audio channel licensed
  to hold a megabyte.
- **A media id may not contain a period.** The place names a forwarded stream
  `<shortClientId>.<mediaId>` and parses it back as exactly two components.
  `createOutgoingMediaStream` throws `MediaStreamIdError.containsPeriod` rather than opening
  a stream every listener would ignore.

## Known limitations

- **The voice processor sets the whole I/O unit's sample rate from the input device.** Measured
  with a USB webcam microphone: device output is stereo but 16 kHz while capture is on, so
  playback is band-limited to 8 kHz for the speaker's own ears. Spatialisation is unaffected.
  `voicedemo` logs the formats at `Engine running:`.
- **The microphone indicator stays on while muted.** Muting sets
  `isVoiceProcessingInputMuted` rather than stopping capture, so the voice processor keeps
  rendering the reference playout needs for echo cancellation. The OS therefore reports the
  microphone as in use, as it does in FaceTime.
- **Catching up shifts the pitch a little.** The rate node is `AVAudioUnitVarispeed`, which
  resamples, so a stream correcting its depth plays up to 2 % (34 cents) off pitch until it is
  back on target. The pitch-preserving `AVAudioUnitTimePitch` measured 85 ms of added pipeline
  latency on macOS 26.5.2, at every `overlap` setting - more delay than the correction removes.
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
