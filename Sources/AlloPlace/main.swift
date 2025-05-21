import Foundation
import ArgumentParser
import allonet2

@main @MainActor
struct PlaceServerArgs: AsyncParsableCommand
{
    @Option(name: [.customShort("n"), .long], help: "Human-facing name of this Alloverse place.")
    var name: String = "Unnamed Alloverse Place"
    
    @Option(name: [.customShort("p"), .long], help: "Port to listen on.")
    var port: UInt16 = 9080
    
    mutating func run() async throws
    {
        let server = PlaceServer(name: name, port: port)
        try await server.start()
    }
}
