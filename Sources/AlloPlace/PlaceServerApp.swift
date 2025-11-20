import Foundation
import ArgumentParser
import allonet2
import alloheadless
import Logging

private var logger = Logger(label: "place.app")

@main @MainActor
struct PlaceServerApp: AsyncParsableCommand
{
    @Option(name: [.customShort("n"), .long], help: "Human-facing name of this Alloverse place.")
    var name: String = "Unnamed Alloverse Place"
    
    @Option(name: [.customShort("t"), .long], help: "Authentication token which lets an AlloApp connect without a registered user. Not providing it allows any app to connect unauthenticated.")
    var alloAppAuthToken: String = ""
    
    @Option(name: [.customShort("l"), .long], help: "WebRTC IP override, e g for replacing a Docker internal IP with the host's public IP in WebRTC's published SDP candidates. Format: from_ip-to_ip. Example: 172.0.0.3-35.34.72.23")
    var ipOverride: IPOverride? = nil
    
    @Option(name: [.customShort("p"), .long], help: "TCP port to open HTTP listener on.")
    var httpPort: UInt16 = 9080
    
    @Option(name: [.customShort("u"), .long], help: "UDP port range to open WebRTC listeners on (express as `min-max`).")
    var webrtcPortRange: Range = 10000..<11000
    
    @Option(help: "If this Alloverse Place is designed to be used with another client app than the offical Alloverse app, specify the name of that client here.")
    var appName: String = "Alloverse"
    
    @Option(help: "Together with client-name, use this to specify where to download the custom client that this place is designed to be used with.")
    var appDownloadURL: String = "https://alloverse.com/download"
    
    @Option(help: "Together with client-name, use this to specify the URL protocol to use to launch the custom client.")
    var appURLProtocol: String = "alloplace2"
    
    mutating func run() async throws
    {
        configurePrintBuffering()
        configureLogging()
        logger.info("Using libdatachannel version \(HeadlessWebRTCTransport.version)")

        let name = name
        let app = AppDescription(name: appName, downloadURL: appDownloadURL, URLProtocol: appURLProtocol)
        let server = PlaceServer(
            name: name,
            httpPort: httpPort,
            customApp: app,
            transportClass: HeadlessWebRTCTransport.self,
            options: TransportConnectionOptions(routing: .direct, ipOverride: ipOverride, portRange: webrtcPortRange),
            alloAppAuthToken: alloAppAuthToken
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
            // Demangle the name of the module that is creating this Logger instance.
            // XXX: this will bite me in the ass when Apple changes the foramt of callStackSymbols...
            var callerModule: String = "allo"
            for trace in Thread.callStackSymbols.dropFirst()
            {
                let moduleName = trace
                    .split(separator:try! Regex("\\s+"))[3] // each trace is stack #, object file, address, symbol. Pick symbol.
                    .split(separator: try! Regex("\\d+"))[1] // swift symbol is always sNmoduleN... where N is the number of characters of the upcoming symbol. split on the two numbers and get the module name.
                if moduleName != "Logging" {
                    callerModule = "allo.\(moduleName)"
                    break
                }
            }
#if os(macOS)
            var console = OSLogHandler(subsystem: callerModule, category: label)
#else
            var console = StreamLogHandler.standardOutput(label: "\(callerModule).label")
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
