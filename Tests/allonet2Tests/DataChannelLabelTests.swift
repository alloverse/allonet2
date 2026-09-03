//
//  DataChannelLabelTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

/// The label is how a peer learns what a channel is: it is the only thing carried in the DCEP
/// OPEN message, and a peer picks it, so parsing it is a trust boundary.
@Suite("Data channel labels")
struct DataChannelLabelTests
{
    @Test func mediaLabelsRoundTripWithTheirKind() throws
    {
        for kind in MediaStreamKind.allCases
        {
            let label = DataChannelLabel.media(kind, "3F2504E0.mic")
            #expect(label.rawValue == "\(kind.rawValue)/3F2504E0.mic")
            #expect(DataChannelLabel(rawValue: label.rawValue) == label)
            #expect(label.isMedia)
            #expect(label.channelId == nil, "media channels are opened in-band")
        }
        #expect(DataChannelLabel(rawValue: "screen/x") == .media(.screen, "x"))
    }

    @Test func rejectsLabelsThatAreNeitherControlNorMedia()
    {
        #expect(DataChannelLabel(rawValue: "video/x") == nil)
        #expect(DataChannelLabel(rawValue: "voice/") == nil, "a prefix with no id names no stream")
        #expect(DataChannelLabel(rawValue: "screen") == nil)
        #expect(DataChannelLabel(rawValue: "") == nil)
    }

    @Test func controlLabelsKeepTheirPreAgreedStreams()
    {
        #expect(DataChannelLabel(rawValue: "interactions") == .interactions)
        #expect(DataChannelLabel(rawValue: "worldstate") == .intentWorldState)
        #expect(DataChannelLabel(rawValue: "logs") == .logs)
    }
}
