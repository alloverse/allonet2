//
//  ScreenDemo.swift
//  allonet2
//
//  Share a screen into a place, or watch the screens shared in one. Run two against one place.
//
//  Usage: swift run screendemo [alloplace2://host:port] --share | --view
//
//  SCREENDEMO_PATTERN=1280x720@15 shares a moving test pattern instead of a screen: no picker,
//  no screen-recording permission, deterministic pictures. What the measurements use.
//  SCREENDEMO_LATENCY_LOG=<path> writes one line per picture at both ends; join them with
//  Scripts/screen-latency.sh.
//  SCREENDEMO_NO_WINDOW=1 decodes and counts without opening a window, for a viewer on a
//  machine with no window server to talk to.
//  SCREENDEMO_BIND=127.0.0.1 gathers ICE on loopback only, to match `AlloPlace -b 127.0.0.1`.
//  SCREENDEMO_TOKEN=<place app token> announces with app credentials, for places that refuse
//  anonymous users (`--require-auth`).
//

import Foundation
import AppKit
import AVFoundation
import allonet2
import AlloVideo

@main @MainActor
struct ScreenDemo
{
    static func main() async throws
    {
        setvbuf(stdout, nil, _IOLBF, 0)   // counters must reach a redirected log as they happen

        let arguments = CommandLine.arguments.dropFirst()
        let sharing = arguments.contains("--share")
        let viewing = arguments.contains("--view")
        guard sharing != viewing else
        {
            FileHandle.standardError.write(Data("usage: screendemo [alloplace2://host:port] --share | --view\n".utf8))
            exit(2)
        }
        let url = URL(string: arguments.first { !$0.hasPrefix("--") } ?? "alloplace2://localhost:9080")!
        print("Connecting to \(url) to \(sharing ? "share" : "view") a screen")

        let client = ScreenDemoClient(
            url: url,
            identity: {
                let token = ProcessInfo.processInfo.environment["SCREENDEMO_TOKEN"] ?? ""
                return Identity(expectation: token.isEmpty ? .none : .app, displayName: "ScreenDemo", emailAddress: "", authenticationToken: token)
            }(),
            avatarDescription: EntityDescription(),
            connectionOptions: TransportConnectionOptions(routing: .direct, bindAddress: ProcessInfo.processInfo.environment["SCREENDEMO_BIND"])
        )
        if let path = ProcessInfo.processInfo.environment["SCREENDEMO_LATENCY_LOG"]
        {
            client.latency = try LatencyLog(path: path)
        }
        client.viewing = viewing
        let windowed = viewing && ProcessInfo.processInfo.environment["SCREENDEMO_NO_WINDOW"] == nil
        client.windowed = windowed
        client.stayConnected()

        while client.avatarId == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        if sharing { try await client.startSharing() }
        print("Connected as \(client.avatarId!). Ctrl-C to stop.")

        if windowed
        {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.finishLaunching()
            NSApplication.shared.activate()
        }
        Task
        {
            while true
            {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                client.reportCounters()
            }
        }

        while true
        {
            // AppKit and Swift concurrency both want the main thread. `NSApplication.run()` never
            // gives it back, and everything this client does - listening, receiving, decoding -
            // is main-actor work behind an await, so the run loop is pumped a slice at a time
            // instead. Without a pump nothing is ever drawn; without the awaits nothing arrives.
            if windowed { pumpAppKit() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class ScreenDemoClient: AlloClient
{
    var latency: LatencyLog?
    var viewing = false
    var windowed = false

    private var screenTransport: DataChannelTransport!
    private var sender: ScreenSender?
    private var receivers: [MediaStreamId: ScreenReceiver] = [:]
    private var windows: [MediaStreamId: ViewerWindow?] = [:]
    private var outgoingMediaId: MediaStreamId?

    override func reset()
    {
        screenTransport = DataChannelTransport(with: self.connectionOptions, status: connectionStatus)
        reset(with: screenTransport)
    }

    func startSharing() async throws
    {
        guard let avatarId else { return }
        let mediaId = "screen-demo"
        let stream = try screenTransport.createOutgoingMediaStream(mediaId: mediaId, kind: .screen)
        let placeStreamId = PlaceStreamId(shortClientId: cid!.shortClientId, incomingMediaId: mediaId)
        outgoingMediaId = placeStreamId.outgoingMediaId

        let source: any VideoSource
        let size: (width: Int, height: Int)
        if let pattern = ProcessInfo.processInfo.environment["SCREENDEMO_PATTERN"]
        {
            guard let parsed = PatternSpec(pattern) else
            {
                FileHandle.standardError.write(Data("SCREENDEMO_PATTERN must look like 1280x720@15, got '\(pattern)'\n".utf8))
                exit(2)
            }
            source = PatternSource(width: parsed.width, height: parsed.height, fps: parsed.fps)
            size = (parsed.width, parsed.height)
            print("Sharing a \(parsed.width)x\(parsed.height) pattern at \(parsed.fps) fps")
        }
        else
        {
            let capturer = ScreenCapturer()
            try await capturer.pickAndStart()
            source = capturer
            // Advisory only: a viewer sizes itself from the bitstream.
            size = (Int(ScreenCapturer.Configuration().maxPixelSize.width), Int(ScreenCapturer.Configuration().maxPixelSize.height))
            print("Sharing the picked window or display")
        }

        let sender = ScreenSender(source: source, stream: stream)
        let latency = self.latency
        let loggedId = placeStreamId.outgoingMediaId
        sender.onFrameSent = { timestamp, capturedAt in
            latency?.note("capture", loggedId, timestamp, at: capturedAt)
        }
        self.sender = sender

        try await changeEntity(entityId: avatarId, addOrChange: [
            LiveMedia(mediaId: placeStreamId.outgoingMediaId, format: .video(codec: .h264, width: size.width, height: size.height))
        ])
        print("Sending \(placeStreamId.outgoingMediaId)")

        Task
        {
            do { try await sender.start() }
            catch { FileHandle.standardError.write(Data("Sharing stopped: \(error)\n".utf8)) }
            print("Source ended; nothing more to share")
        }
    }

    /// Listen to every screen in the place except our own.
    private func updateListeners() async throws
    {
        guard viewing, let avatarId else { return }
        var wanted = Set<MediaStreamId>()
        for (_, media) in placeState.current.components[LiveMedia.self]
        {
            guard case .video = media.format, media.mediaId != outgoingMediaId else { continue }
            wanted.insert(media.mediaId)
        }
        guard wanted != listening else { return }
        listening = wanted
        try await changeEntity(entityId: avatarId, addOrChange: [LiveMediaListener(mediaIds: wanted)])
    }
    private var listening: Set<MediaStreamId> = []

    override func session(_ session: AlloSession, didReceivePlaceChangeSet changeset: PlaceChangeSet)
    {
        super.session(session, didReceivePlaceChangeSet: changeset)
        Task
        {
            do { try await updateListeners() }
            catch { FileHandle.standardError.write(Data("Failed to update listeners: \(error)\n".utf8)) }
        }
    }

    override func session(_ session: AlloSession, didReceiveMediaStream stream: MediaStream)
    {
        guard stream.kind == .screen else { return }
        let mediaId = stream.mediaId
        let window = windowed ? ViewerWindow(title: mediaId) : nil
        windows[mediaId] = window
        let receiver = ScreenReceiver(stream: stream)
        receivers[mediaId] = receiver
        // Wave 1 has no interaction to ask a sharer with; the sharer's periodic keyframe is what
        // recovers a viewer here. KojaNet's screen.requestKeyframe is where this goes.
        receiver.needsKeyframe = { print("Lost the picture on \(mediaId); waiting for the next keyframe") }

        let latency = self.latency
        Task
        {
            for await sample in receiver.samples
            {
                window?.show(sample)
                receiver.counters.update { $0.displayed += 1 }
                let timestamp = UInt32(truncatingIfNeeded: CMSampleBufferGetPresentationTimeStamp(sample).value)
                latency?.note("render", mediaId, timestamp, at: monotonicSeconds())
            }
        }
    }

    override func session(_ session: AlloSession, didRemoveMediaStream stream: MediaStream)
    {
        receivers.removeValue(forKey: stream.mediaId)?.stop()
        windows.removeValue(forKey: stream.mediaId)??.close()
    }

    func reportCounters()
    {
        if let sender
        {
            print("out: \(sender.counters.snapshot) bitrate=\(sender.bitrate.map { $0 / 1000 } ?? 0)kbit/s")
        }
        for (mediaId, receiver) in receivers
        {
            print("in  \(mediaId): \(receiver.counters.snapshot)")
        }
    }
}

/// Ten milliseconds of AppKit: dispatch what the window server sent, then let the run loop draw.
/// Synchronous on purpose - it blocks the main actor for that slice, which is the price of
/// sharing the main thread, and the awaits around it are what let anything else happen.
@MainActor
func pumpAppKit()
{
    while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
    {
        NSApp.sendEvent(event)
    }
    CFRunLoopRunInMode(.defaultMode, 0.01, true)
}

/// `WIDTHxHEIGHT@FPS`.
struct PatternSpec
{
    let width: Int
    let height: Int
    let fps: Double

    init?(_ text: String)
    {
        let parts = text.split(separator: "@")
        guard parts.count == 2 else { return nil }
        let size = parts[0].split(separator: "x")
        guard size.count == 2,
              let width = Int(size[0]), let height = Int(size[1]), let fps = Double(parts[1]),
              width > 0, height > 0, fps > 0
        else { return nil }
        self.width = width
        self.height = height
        self.fps = fps
    }
}

/// One window per incoming screen, showing compressed samples through the display layer's own
/// decoder. Resizes itself to the first picture's size.
@MainActor
final class ViewerWindow
{
    private let window: NSWindow
    private let layer = AVSampleBufferDisplayLayer()
    private var sized = false

    init(title: String)
    {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView?.wantsLayer = true
        layer.videoGravity = .resizeAspect
        layer.frame = window.contentView!.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        window.contentView?.layer?.addSublayer(layer)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func show(_ sample: CMSampleBuffer)
    {
        if !sized, let format = CMSampleBufferGetFormatDescription(sample)
        {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            window.setContentSize(NSSize(width: Int(size.width), height: Int(size.height)))
            layer.frame = window.contentView!.bounds
            sized = true
        }
        // A renderer that failed once stays failed until it is flushed; a share must survive that.
        if layer.sampleBufferRenderer.status == .failed { layer.sampleBufferRenderer.flush() }
        layer.sampleBufferRenderer.enqueue(sample)
    }

    func close() { window.close() }
}

func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// One line per picture at each end, joined on media id and frame timestamp by
/// `Scripts/screen-latency.sh`. Both ends read the same monotonic clock, which is only true on
/// one machine - across two it would measure clock skew.
final class LatencyLog: @unchecked Sendable
{
    enum Failure: Error, CustomStringConvertible
    {
        case cannotOpen(path: String, code: Int32)
        var description: String
        {
            switch self
            {
            case .cannotOpen(let path, let code): "cannot open latency log \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    private let out: Int32

    init(path: String) throws
    {
        // O_APPEND makes each line atomic against the other screendemo writing the same file.
        out = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard out >= 0 else { throw Failure.cannotOpen(path: path, code: errno) }
    }

    deinit { close(out) }

    func note(_ event: String, _ mediaId: MediaStreamId, _ timestamp: UInt32, at: Double)
    {
        let bytes = Array("\(event) \(mediaId) \(timestamp) \(at)\n".utf8)
        let written = bytes.withUnsafeBufferPointer { write(out, $0.baseAddress, $0.count) }
        if written != bytes.count
        {
            fputs("latency log write failed: \(String(cString: strerror(errno)))\n", stderr)
        }
    }
}
