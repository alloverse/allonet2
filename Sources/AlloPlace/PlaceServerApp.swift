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
    
    @Option(help: "If this Alloverse Place is designed to be used with another client than the offical Alloverse app, specify the name of that client here.")
    var clientName: String = "Alloverse"
    
    @Option(help: "Together with clientName, use this to specify where to download the custom client that this place is designed to be used with.")
    var clientDownloadURL: String = "https://alloverse.com/download"
    
    mutating func run() async throws
    {
        let server = PlaceServer(name: name, port: port, clientName: clientName, clientDownloadURL: clientDownloadURL)
        try await server.start()
    }
}
