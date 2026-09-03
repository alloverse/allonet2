//
//  PlaceServerStatusTests.swift
//  allonet2
//
//  PlaceServerStatus only renders from a live PlaceServer, so this runs against the shared
//  end-to-end harness instead of a fake server state.
//

import Testing
import Foundation
import E2ESupport
@testable import allonet2

@MainActor
@Suite struct PlaceServerStatusTests
{
    @Test func statusPageRendersForwardingCounters() async throws
    {
        try await withPlace { place in
            let speaker = try await place.connectClient(named: "speaker")
            let listener = try await place.connectClient(named: "listener")

            let outgoing = try speaker.startSpeaking(mediaId: "voice-mic")
            let placeStreamId = try await speaker.advertise(mediaId: "voice-mic")
            try await listener.listen(to: [placeStreamId])
            let incoming = try await listener.awaitStream(placeStreamId)

            let frameCount = 30
            for frame in 0..<frameCount
            {
                var samples = VoiceE2ETests.markerSamples(frame: frame)
                samples.withUnsafeBufferPointer { buffer in
                    outgoing.send(samples: buffer.baseAddress!, frameCount: buffer.count)
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try await waitUntil(timeout: 5) { incoming.counters.snapshot.received >= frameCount - 2 }

            // The server's own view of the speaker's stream, distinct from `incoming` (the
            // listener's local copy, post-forward).
            let psi = try #require(placeStreamId.psi)
            let sourceStream = try #require(place.server.sfu.available[psi]?.stream as? DataChannelMediaStream)
            let available = sourceStream.counters.snapshot

            let status = PlaceServerStatus(server: place.server)
            let html = status.sfuTable

            #expect(available.received > 0)
            #expect(html.contains("<td>\(available.received)</td>"), "\(html)")
            #expect(html.contains("<td>\(available.malformed)</td>"), "\(html)")

            let forwarder = try #require(place.server.sfu.active.values.first as? DataChannelForwarder)
            let forwarded = forwarder.destination.counters.snapshot
            #expect(forwarded.forwardedOut > 0)
            #expect(html.contains("<td>\(forwarded.forwardedOut)</td>"), "\(html)")
            #expect(html.contains("<td>\(forwarded.forwardDropped)</td>"), "\(html)")
            #expect(html.contains("<td>-</td>"), "no forwarding error occurred, so the cell should read \"-\": \(html)")
        }
    }
}
