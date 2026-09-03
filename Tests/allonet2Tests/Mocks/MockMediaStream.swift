import Foundation
@testable import allonet2

final class MockMediaStream: MediaStream
{
    let mediaId: MediaStreamId
    let streamDirection: MediaStreamDirection
    let kind: MediaStreamKind
    private let observers = FrameObservers()

    init(mediaId: MediaStreamId, direction: MediaStreamDirection = .recvonly, kind: MediaStreamKind = .voice)
    {
        self.mediaId = mediaId
        self.streamDirection = direction
        self.kind = kind
    }

    /// Hand a frame to whoever is observing, as the real stream's `deliver` would.
    func emit(_ frame: Data) { observers.emit(frame) }

    @discardableResult
    func observeFrames(_ observer: @escaping (Data) -> Void) -> FrameObservers.Token { observers.add(observer) }
    func removeObserver(_ token: FrameObservers.Token) { observers.remove(token) }

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
