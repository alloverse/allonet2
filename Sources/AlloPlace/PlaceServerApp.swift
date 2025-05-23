import Foundation
import ArgumentParser
import allonet2

@main @MainActor
struct PlaceServerApp: AsyncParsableCommand
{
    @Option(name: [.customShort("n"), .long], help: "Human-facing name of this Alloverse place.")
    var name: String = "Unnamed Alloverse Place"
    
    @Option(name: [.customShort("p"), .long], help: "Port to open HTTP listener on.")
    var port: UInt16 = 9080
    
    @Option(help: "If this Alloverse Place is designed to be used with another client app than the offical Alloverse app, specify the name of that client here.")
    var appName: String = "Alloverse"
    
    @Option(help: "Together with client-name, use this to specify where to download the custom client that this place is designed to be used with.")
    var appDownloadURL: String = "https://alloverse.com/download"
    
    @Option(help: "Together with client-name, use this to specify the URL protocol to use to launch the custom client.")
    var appURLProtocol: String = "alloplace2"
    
    mutating func run() async throws
    {
        let app = AppDescription(name: appName, downloadURL: appDownloadURL, URLProtocol: appURLProtocol)
        let server = PlaceServer(name: name, port: port, customApp: app)
        try await server.start()
    }
}
