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
