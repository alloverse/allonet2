import Foundation
import ArgumentParser
import allonet2
import alloheadless

@main @MainActor
struct PlaceServerApp: AsyncParsableCommand
{
    @Option(name: [.customShort("n"), .long], help: "Human-facing name of this Alloverse place.")
    var name: String = "Unnamed Alloverse Place"
    
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
        let name = name
        let app = AppDescription(name: appName, downloadURL: appDownloadURL, URLProtocol: appURLProtocol)
        let server = PlaceServer(
            name: name,
            httpPort: httpPort,
            customApp: app,
            transportClass: HeadlessWebRTCTransport.self,
            options: TransportConnectionOptions(routing: .direct, ipOverride: ipOverride, portRange: webrtcPortRange)
        )
        
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            print("Received sigint, terminating '\(name)'...")
            Task {
                await server.stop()
            }
        }
        sigint.resume()
        
        try await server.start()
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
