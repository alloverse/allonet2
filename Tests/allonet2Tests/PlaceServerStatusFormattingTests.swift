//
//  PlaceServerStatusFormattingTests.swift
//  allonet2
//

import Testing
import Foundation
@testable import allonet2

@MainActor
@Suite("Place server status formatting")
struct PlaceServerStatusFormattingTests
{
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func age(_ seconds: TimeInterval) -> String
    {
        PlaceServerStatus.relativeTime(since: now.addingTimeInterval(-seconds), now: now)
    }

    @Test func readsInSecondsUnderAMinute()
    {
        #expect(age(0) == "0 s ago")
        #expect(age(1) == "1 s ago")
        #expect(age(59) == "59 s ago")
    }

    @Test func readsInMinutesFromAMinuteUpToAnHour()
    {
        #expect(age(60) == "1 min ago", "the first minute")
        #expect(age(119) == "1 min ago", "truncates rather than rounds")
        #expect(age(3599) == "59 min ago", "the last minute before the hour")
    }

    @Test func readsInHoursFromAnHourOn()
    {
        #expect(age(3600) == "1 h ago", "the first hour")
        #expect(age(7199) == "1 h ago")
        #expect(age(86_400) == "24 h ago", "days are still counted in hours")
    }

    /// Clocks move backwards - NTP steps, a forwarder stamped on a peer's clock - and a negative
    /// age must not render as one.
    @Test func aDateInTheFutureIsNotNegative()
    {
        #expect(PlaceServerStatus.relativeTime(since: now.addingTimeInterval(60), now: now) == "0 s ago")
    }
}
