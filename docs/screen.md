# Screen sharing

A shared screen is H.264 on a media data channel: the same stream, the same nine-byte frame
header and the same place-side forwarding as voice ([voice.md](voice.md) has both, and is worth
reading first). Nothing in the media path knows a screen from a voice — the kind byte in the
header and the `screen/` prefix on the channel label are the whole difference.

`AlloVideo` is the Apple-only target that turns pixels into media frames and back. It knows
nothing about entities, `LiveMedia` or Koja: a caller opens the stream, hands it a source, and
puts the resulting samples wherever it draws.

## On the wire

- **Channel**: `screen/<mediaId>`, opened in-band like every media channel, **ordered with a
  1000 ms packet lifetime** — H.264 loses every picture after a hole, but a picture nobody could
  render within a second is not worth queueing the share behind (`MediaStreamKind.reliability`).
- **Frames**: `h264Key` (2) and `h264Delta` (3). Payload is one Annex B access unit; a keyframe
  carries SPS and PPS before its IDR, so a viewer can start on any keyframe with no side-band
  parameter sets. No B pictures, so decode order is display order.
- **Timestamp**: 48 kHz ticks since the sender's first picture — the unit voice already uses, so
  a picture and a voice sit on one timeline.
- **Caps**: 1 MiB for a keyframe, 256 KiB for a delta, enforced before the fan-out on the place
  and on every receiver. Peers advertise `a=max-message-size:2097152`
  (`DataChannelTransport.maximumMessageSize`), because libdatachannel's own default of 256 KiB
  would refuse a keyframe.

## Sender

    VideoSource -> CapturedFrame -> H264Encoder -> EncodedFrame -> DataChannelMediaStream.send

- `ScreenCapturer` shows `SCContentSharingPicker`, then runs an `SCStream` over what the user
  picked: NV12, IOSurface-backed, scaled to fit 1920x1200 keeping the content's aspect, at most
  30 fps, cursor included. `PatternSource` is the same shape without the permissions - a moving
  gradient with its frame index drawn into it as a bar of light and dark blocks, which is how a
  test names the picture it decoded.
- Both keep only the newest two pictures: a consumer slower than the source drops frames rather
  than falling further behind on a growing queue.
- `H264Encoder` is a `VTCompressionSession`, hardware, real-time, no frame reordering, High
  profile at AutoLevel, keyframe every 2 s, with `DataRateLimits` capping any one second at 1.5x
  the average bitrate. It converts VideoToolbox's AVCC output to Annex B and prepends the
  parameter sets to every keyframe.
- `ScreenSender` owns the loop, and `stream.send(payload:kind:timestamp:)` numbers each frame in
  the stream's own sequence and refuses anything over its kind's cap before it reaches the wire.

### Adaptation

A data channel never says "slow down"; the only signal is `DataChannelMediaStream.bufferedBytes`
climbing, so `ScreenSender` reads it before every encode.

| | |
|---|---|
| high water | `max(300 KB, 2 x average encoded frame size)` |
| above it | drop the picture (`droppedForBackpressure`), cut the bitrate by 20 % |
| below half of it for 3 s | raise the bitrate by 10 % |
| floor / ceiling / start | 500 kbit/s / 4 Mbit/s / 2 Mbit/s |

Dropping is what stops the queue growing; the cut is what stops it happening again. A keyframe
request is rate-limited to one per second, so a burst of viewers costs one keyframe rather than
one each.

## Viewer

    observeFrames -> MediaFrame -> H264Decoder -> CMSampleBuffer -> AVSampleBufferDisplayLayer

`ScreenReceiver` takes frames on the thread that delivered them, drops non-video kinds as
`malformed`, and drops deltas until a keyframe (`droppedAwaitingKey`). It calls `needsKeyframe`,
for the owner to turn into a request to the sharer, whenever the picture cannot continue from
here: a sequence gap (`gaps`), a decode error, a delta that will not decode because this viewer
subscribed mid-GOP, and a sample `samples` evicted before the owner read it (`evicted`) — the
deltas after that sample predict from a picture the display never got. Once per episode, not
once per frame: every delta behind one hole says the same thing.

The samples carry **compressed** data plus the format description built from the stream's own
SPS/PPS: `AVSampleBufferDisplayLayer` decodes them itself, marked to display immediately since
the stream carries no timebase. That is one hardware path fewer to own; a caller who wants
pixels instead can run the same samples through a `VTDecompressionSession`, as the tests do.

`ScreenCounters` is the accounting, mirroring `VoiceCounters`: on a sender every `captured`
picture is exactly one of `encoded` (then `sent` or `sendFailed`), `droppedForBackpressure` or
`encoderDropped`; on a receiver every `received` message is exactly one of `decoded`, `malformed`
or `droppedAwaitingKey`.

## Running it

    swift test --filter ScreenE2ETests                  # codec, pipeline and a real place
    ./Scripts/soak-e2e.sh 20                            # both E2E suites, 20 times, with a watchdog
    swift run AlloPlace -n Screen -p 9180 -u 12000-13000 -b 127.0.0.1
    SCREENDEMO_BIND=127.0.0.1 SCREENDEMO_PATTERN=1280x720@15 \
        swift run screendemo alloplace2://localhost:9180 --share    # a test pattern, no picker
    swift run screendemo alloplace2://localhost:9180 --share        # the real picker
    SCREENDEMO_BIND=127.0.0.1 swift run screendemo alloplace2://localhost:9180 --view
    SCREENDEMO_NO_WINDOW=1 ... --view                   # decode and count with no window server
    SCREENDEMO_LATENCY_LOG=/tmp/screenlat.log ...       # both ends; then:
    ./Scripts/screen-latency.sh /tmp/screenlat.log

`screendemo` prints counters every 5 s. The latency log joins the sender's capture times and the
viewer's display times on the frame timestamp, so both ends must run on one machine: the times
are one monotonic clock, and across two hosts the number would be clock skew.

## Measured

2026-09-03, a Mac mini (M1) on macOS 26.5.2, release build: a place and two `screendemo`
instances on loopback, `SCREENDEMO_PATTERN=1280x720@15`, ~60 s.

| | |
|---|---|
| capture to display | p50 **4 ms**, p95 **5 ms** (n=881) |
| pictures | 976 captured, 976 encoded, 976 sent - 15.0 fps, 0 dropped for backpressure, 0 send failures |
| viewer | 806 decoded, 0 malformed, 0 gaps, 5 deltas dropped before its first keyframe |
| payload rate | ~248 kbit/s (a test pattern compresses far below the 4 Mbit/s ceiling) |
| CPU, one core | sharer 5.1-5.7 %, viewer 1.7-2.0 %, place 0.9-1.0 % |

Latency is capture to the sample being handed to the display layer; what the layer then adds
before glass is not in it. The same run in a **debug** build costs the sharer a whole core and
delivers ~9 fps of the 15 asked for - the pattern generator's per-pixel loop, not the codec -
so measure on a release build or share a real screen.

Real capture through `SCContentSharingPicker` is unmeasured: presenting the picker needs
somebody to pick.
