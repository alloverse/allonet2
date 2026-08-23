import Foundation
@testable import allonet2

final class MockMediaStream: MediaStream
{
    let mediaId: MediaStreamId
    let streamDirection: MediaStreamDirection

    init(mediaId: MediaStreamId, direction: MediaStreamDirection = .recvonly)
    {
        self.mediaId = mediaId
        self.streamDirection = direction
    }

    var description: String { "<MockMediaStream \(mediaId)>" }
    func render() -> AudioRingBuffer { fatalError("These tests never play audio") }
}

final class MockMediaStreamForwarder: MediaStreamForwarder
{
    private(set) var stopCount = 0
    func stop() { stopCount += 1 }

    var forwardedMessageCount: Int { 0 }
    var lastError: Error? { nil }
    var lastErrorAt: Date? { nil }
}
