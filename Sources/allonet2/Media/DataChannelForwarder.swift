//
//  DataChannelForwarder.swift
//  allonet2
//

import Foundation

/// Forwards one voice stream to one receiver by copying frames between channels.
///
/// This is the whole SFU media path. Nothing is decoded, re-encoded, renumbered or
/// rewritten, and - unlike forwarding an RTP track - opening the outgoing channel needs no
/// offer/answer, so adding a listener costs no renegotiation.
public final class DataChannelForwarder: MediaStreamForwarder, @unchecked Sendable
{
    public let source: DataChannelMediaStream
    public let destination: DataChannelMediaStream

    private let lock = NSLock()
    private var token: FrameObservers.Token?
    private var messageCount = 0
    private var error: Error?
    private var errorAt: Date?

    public init(from source: DataChannelMediaStream, to destination: DataChannelMediaStream)
    {
        self.source = source
        self.destination = destination

        token = source.observeFrames { [weak self] frame in
            guard let self else { return }
            destination.counters.update { $0.forwardedIn += 1 }
            if destination.forward(frame)
            {
                lock.lock(); messageCount += 1; lock.unlock()
            }
        }
    }

    public func stop()
    {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token { source.removeObserver(token) }
    }

    deinit { stop() }

    // Debugging info. There is no RTP header to report on.
    public var ssrc: UInt32? { nil }
    public var pt: UInt8? { nil }
    public var forwardedMessageCount: Int { lock.lock(); defer { lock.unlock() }; return messageCount }
    public var lastError: Error? { lock.lock(); defer { lock.unlock() }; return error }
    public var lastErrorAt: Date? { lock.lock(); defer { lock.unlock() }; return errorAt }
}
