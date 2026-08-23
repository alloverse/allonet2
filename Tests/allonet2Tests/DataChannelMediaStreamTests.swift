//
//  DataChannelMediaStreamTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@Suite("Data channel media stream")
struct DataChannelMediaStreamTests
{
    private func receiver() -> DataChannelMediaStream
    {
        DataChannelMediaStream(mediaId: "voice-mic", direction: .recvonly) { _ in true }
    }

    @Test func rejectsOversizedMessagesBeforeFanningThemOut()
    {
        let stream = receiver()
        let seen = FrameLog()
        stream.observeFrames { seen.append($0) }

        stream.deliver(Data(repeating: 0, count: 1_000_000))

        let counters = stream.counters.snapshot
        #expect(counters.received == 1)
        #expect(counters.malformed == 1, "an oversized message is malformed, not a frame")
        #expect(seen.count == 0, "an oversized message must not reach forwarders")
    }

    @Test func deliversAFrameAtTheSizeLimit() throws
    {
        let stream = receiver()
        let seen = FrameLog()
        stream.observeFrames { seen.append($0) }

        let payload = Data(repeating: 7, count: DataChannelMediaStream.maximumFrameBytes - VoiceFrame.headerSize)
        stream.deliver(VoiceFrame(kind: .opus, sequence: 0, timestamp: 0, payload: payload).encoded)

        #expect(stream.counters.snapshot.malformed == 0)
        #expect(seen.count == 1)
    }

    /// The RTP path is gone, so a stream that isn't a data channel is a caller error and has to
    /// name itself; silently returning no forwarder would leave a listener waiting for audio.
    @MainActor
    @Test func refusesToForwardAStreamThatIsNotADataChannel() throws
    {
        let options = TransportConnectionOptions(routing: .direct, bindAddress: "127.0.0.1")
        let sender = MockTransport(with: options, status: ConnectionStatus())
        let receiver = DataChannelTransport(with: options, status: ConnectionStatus())
        defer { receiver.disconnect() }

        #expect(throws: ForwardingError.notADataChannelStream("mic"))
        {
            try receiver.forward(mediaStream: MockMediaStream(mediaId: "mic"), from: sender)
        }
    }
}

/// Frames are emitted on whatever thread delivered them.
private final class FrameLog: @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [Data] = []
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
}
