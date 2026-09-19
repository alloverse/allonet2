//
//  EphemeralPortTests.swift
//  allonet2
//
//  An embedded place lets the OS pick its port, so `listeningPort` is the only way anything
//  can be pointed at it. `TestPlace` is built that way, which is what this asserts.
//

import Testing
import Foundation
import E2ESupport
@testable import allonet2

@MainActor
@Suite struct EphemeralPortTests
{
    @Test func aPlaceOnAnOSChosenPortReportsItAndServesAClient() async throws
    {
        try await withPlace { place in
            let port = await place.server.listeningPort
            #expect(port != nil && port != 0)
            #expect(port == place.port)
            _ = try await place.connectClient(named: "ephemeral")
        }
    }
}
