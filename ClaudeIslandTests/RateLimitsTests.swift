//
//  RateLimitsTests.swift
//  ClaudeIslandTests
//
//  Covers parsing the plan-limit report the status line bridge forwards, and
//  the rules for when a remembered figure may still be shown. A usage number
//  is something the user paces their work by, so most cases are about
//  withdrawing one that is no longer true.
//

import Foundation
import Testing

@Suite("Rate limits")
struct RateLimitsTests {

    let now = Date(timeIntervalSince1970: 1_789_600_000)

    func decode(_ text: String) -> RateLimits? {
        RateLimits.decode(from: Data(text.utf8), receivedAt: now)
    }

    // MARK: - Parsing

    @Test("The shape Claude Code sends parses into both windows")
    func parsesRealPayload() throws {
        let limits = try #require(decode("""
        { "session_id": "s", "cwd": "/x", "event": "StatusLine", "status": "rate_limits",
          "rate_limits": {
            "five_hour": { "used_percentage": 12.5, "resets_at": 1789615800 },
            "seven_day": { "used_percentage": 55.00000000000001, "resets_at": 1789653600 }
          } }
        """))

        #expect(limits.fiveHour?.usedPercentage == 12.5)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_789_615_800))
        #expect(limits.sevenDay?.percent == 55)
        #expect(limits.receivedAt == now)
    }

    @Test("A report with no usable window is no report", arguments: [
        #"{ "event": "StatusLine" }"#,
        #"{ "rate_limits": {} }"#,
        #"{ "rate_limits": [] }"#,
        #"{ "rate_limits": { "five_hour": { "resets_at": 1789615800 } } }"#,
        #"{ "rate_limits": { "five_hour": { "used_percentage": "12" } } }"#,
        #"{ "rate_limits": { "five_hour": { "used_percentage": -1 } } }"#,
        #"{ "rate_limits": { "five_hour": { "used_percentage": true } } }"#,
        #"not json"#,
    ])
    func rejectsUnusable(text: String) {
        #expect(decode(text) == nil)
    }

    @Test("One bad window does not take the good one down with it")
    func keepsTheValidWindow() throws {
        let limits = try #require(decode("""
        { "rate_limits": {
            "five_hour": { "used_percentage": "lots" },
            "seven_day": { "used_percentage": 40, "resets_at": 1789653600 } } }
        """))
        #expect(limits.fiveHour == nil)
        #expect(limits.sevenDay?.percent == 40)
    }

    @Test("A float a hair over 100 at the limit reads as full, not as garbage")
    func clampsOverHundred() throws {
        let limits = try #require(decode(#"{ "rate_limits": { "five_hour": { "used_percentage": 100.0000001 } } }"#))
        #expect(limits.fiveHour?.percent == 100)
        #expect(limits.fiveHour?.fraction == 1)
    }

    @Test("A reset time that is not a number is dropped, not guessed")
    func dropsUnreadableResetTime() throws {
        let limits = try #require(decode(#"{ "rate_limits": { "five_hour": { "used_percentage": 3, "resets_at": "soon" } } }"#))
        #expect(limits.fiveHour?.usedPercentage == 3)
        #expect(limits.fiveHour?.resetsAt == nil)
    }

    // MARK: - What may still be shown

    func limits(
        fiveHourReset: Date?,
        sevenDayReset: Date?,
        receivedAt: Date
    ) -> RateLimits {
        RateLimits(
            fiveHour: RateLimitWindow(usedPercentage: 20, resetsAt: fiveHourReset),
            sevenDay: RateLimitWindow(usedPercentage: 60, resetsAt: sevenDayReset),
            receivedAt: receivedAt
        )
    }

    @Test("A fresh report shows both windows")
    func freshReportShowsBoth() {
        let display = limits(
            fiveHourReset: now.addingTimeInterval(3600),
            sevenDayReset: now.addingTimeInterval(86_400),
            receivedAt: now
        ).display(at: now)

        #expect(display?.fiveHour?.percent == 20)
        #expect(display?.sevenDay?.percent == 60)
        #expect(display?.isStale == false)
    }

    @Test("A window whose reset has passed is withdrawn — the old figure is no longer true")
    func withdrawsAWindowPastItsReset() {
        let display = limits(
            fiveHourReset: now.addingTimeInterval(-1),
            sevenDayReset: now.addingTimeInterval(86_400),
            receivedAt: now.addingTimeInterval(-60)
        ).display(at: now)

        #expect(display?.fiveHour == nil)
        #expect(display?.sevenDay?.percent == 60)
    }

    @Test("Nothing left to show is nil, so the meter disappears rather than rendering empty")
    func nothingLeftIsNil() {
        let display = limits(
            fiveHourReset: now.addingTimeInterval(-10),
            sevenDayReset: now.addingTimeInterval(-10),
            receivedAt: now.addingTimeInterval(-60)
        ).display(at: now)

        #expect(display == nil)
    }

    @Test("An old report still shows, but says it is old — usage elsewhere may have moved it")
    func oldReportIsMarkedStale() {
        let display = limits(
            fiveHourReset: now.addingTimeInterval(3600),
            sevenDayReset: now.addingTimeInterval(86_400),
            receivedAt: now.addingTimeInterval(-RateLimits.staleAfter - 1)
        ).display(at: now)

        #expect(display?.isStale == true)
        #expect(display?.fiveHour?.percent == 20)
    }

    @Test("A window with no reset time cannot be known to be current once the report is stale")
    func unknownResetIsWithdrawnWhenStale() {
        let old = now.addingTimeInterval(-RateLimits.staleAfter - 1)
        let display = limits(
            fiveHourReset: nil,
            sevenDayReset: now.addingTimeInterval(86_400),
            receivedAt: old
        ).display(at: now)

        #expect(display?.fiveHour == nil)
        #expect(display?.sevenDay != nil)

        let fresh = limits(fiveHourReset: nil, sevenDayReset: nil, receivedAt: now).display(at: now)
        #expect(fresh?.fiveHour?.percent == 20)
    }

    // MARK: - Formatting

    @Test("Time until reset reads the way someone planning around it would say it")
    func formatsTimeUntilReset() {
        #expect(RateLimitWindow.shortDuration(30) == "<1m")
        #expect(RateLimitWindow.shortDuration(3540) == "59m")
        #expect(RateLimitWindow.shortDuration(7500) == "2h 5m")
        #expect(RateLimitWindow.shortDuration(273_600) == "3d 4h")
    }
}
