import Foundation
import ArgumentParser
import allonet2
import alloheadless
import Logging

private var logger = Logger(labelSuffix: "place.app")

@main @MainActor
struct PlaceServerApp: AsyncParsableCommand
{
    @Option(name: [.customShort("n"), .long], help: "Human-facing name of this Alloverse place.")
    var name: String = "Unnamed Alloverse Place"
    
    @Option(name: [.customShort("t"), .long], help: "Authentication token which lets an AlloApp connect without a registered user. Not providing it allows any app to connect unauthenticated.")
    var alloAppAuthToken: String = ""
    
    @Flag(help: "Refuse users until an app has registered as authentication provider. Without it, a place admits anyone during the window between starting up and its provider connecting.")
    var requireAuth: Bool = false

    @Option(name: [.customShort("l"), .long], help: "WebRTC IP override, e g for replacing a Docker internal IP with the host's public IP in WebRTC's published SDP candidates. Format: from_ip-to_ip. Example: 172.0.0.3-35.34.72.23")
    var ipOverride: IPOverride? = nil
    
    @Option(name: [.customShort("p"), .long], help: "TCP port to open HTTP listener on.")
    var httpPort: UInt16 = 9080
    
    @Option(name: [.customShort("u"), .long], help: "UDP port range to open WebRTC listeners on (express as `min-max`).")
    var webrtcPortRange: Range = 10000..<11000

    @Option(name: [.customShort("b"), .long], help: "Gather ICE candidates on this address only. `127.0.0.1` for a place and its clients on one machine: on a host with many interfaces, checking every one of them is how a local connection times out.")
    var bindAddress: String? = nil
    
    @Option(help: "If this Alloverse Place is designed to be used with another client app than the offical Alloverse app, specify the name of that client here.")
    var appName: String = "Alloverse"
    
    @Option(help: "Together with client-name, use this to specify where to download the custom client that this place is designed to be used with.")
    var appDownloadURL: String = "https://alloverse.com/download"
    
    @Option(help: "Together with client-name, use this to specify the URL protocol to use to launch the custom client.")
    var appURLProtocol: String = "alloplace2"

    @Option(help: "Directory to keep published assets in. Point this at a volume to keep them across restarts; the default is under the temp directory, so they're re-uploaded after a restart.")
    var assetsDir: String?

    mutating func validate() throws
    {
        // An empty app token authenticates every app that asks, and the first app to ask becomes
        // the place's authentication provider — so requiring authentication without a token just
        // hands the gate to whoever connects first.
        if requireAuth && alloAppAuthToken.isEmpty
        {
            throw ValidationError("--require-auth needs an app token (-t) as well: without one, any app that connects can become this place's authentication provider.")
        }
    }

    mutating func run() async throws
    {
        configurePrintBuffering()
        configureLogging()
        logger.info("Using libdatachannel version \(DataChannelTransport.version)")

        let name = name
        let app = AppDescription(name: appName, downloadURL: appDownloadURL, URLProtocol: appURLProtocol)
        let server = PlaceServer(
            name: name,
            httpPort: httpPort,
            customApp: app,
            options: TransportConnectionOptions(routing: .direct, ipOverride: ipOverride, portRange: webrtcPortRange, bindAddress: bindAddress),
            alloAppAuthToken: alloAppAuthToken,
            requiresAuthentication: requireAuth,
            assetsDirectory: assetsDir.map { URL(fileURLWithPath: $0) } ?? PlaceServer.defaultAssetsDirectory
        )
        
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            logger.warning("Received sigint, terminating '\(name)'...")
            Task {
                await server.stop()
            }
        }
        sigint.resume()
        
        try await server.start()
    }
    
    func configureLogging()
    {
        LoggingSystem.bootstrap
        { label in
            let module: String, sublabel: String
            let maybeModuleAndSublabel = label.split(separator:":")
            if maybeModuleAndSublabel.count > 1 {
                module = String(maybeModuleAndSublabel[0])
                sublabel = String(maybeModuleAndSublabel[1])
            } else {
                module = "koja"
                sublabel = label
            }
#if os(macOS)
            var console = OSLogHandler(subsystem: module, category: sublabel)
#else
            var console = StreamLogHandler.standardOutput(label: label)
#endif
            console.logLevel = .debug
            
            var storing = StoringLogHandler(label: label)
            storing.logLevel = .trace
            
            // TODO: Add an OpenTelemetry sender too, with associated backend (configured through env)
            
            var combined = MultiplexLogHandler([console, storing])
            return combined
        }
    }
}

extension Range<Int> : ExpressibleByArgument
{
    public init?(argument: String)
    {
        let pair = argument.split(separator: "-").flatMap { Int($0) }
        guard pair.count == 2 else { return nil }
        guard pair[0] < pair[1] else { return nil }
        self.init(uncheckedBounds: (lower: pair[0], upper: pair[1]))
    }
}

extension IPOverride : ExpressibleByArgument
{
    public init?(argument: String) {
        let pair = argument.split(separator: "-")
        guard pair.count == 2 else { return nil }
        self.init(from: String(pair[0]), to: String(pair[1]))
    }
}
