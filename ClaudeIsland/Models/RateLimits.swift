//
//  RateLimits.swift
//  ClaudeIsland
//
//  The plan's 5-hour and weekly usage limits, as Claude Code reports them to
//  its status line, and the rules for when a remembered figure is still true.
//

import Foundation

/// One limit window: how much of it is used, and when it starts over.
nonisolated struct RateLimitWindow: Equatable, Sendable {
    /// 0...100.
    let usedPercentage: Double
    /// Nil when the report carried no readable reset time.
    let resetsAt: Date?

    /// 0...1, for a bar.
    var fraction: Double {
        usedPercentage / 100
    }

    var percent: Int {
        Int(usedPercentage.rounded())
    }

    /// e.g. "2h 5m", or nil when the reset time is unknown or already past.
    func timeUntilReset(from now: Date) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }
        return Self.shortDuration(resetsAt.timeIntervalSince(now))
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }

        return "\(hours / 24)d \(hours % 24)h"
    }

    /// Lenient per window: anything that is not a finite, non-negative number
    /// is no window at all. A float a hair over 100 at the limit is clamped
    /// rather than rejected, since that is exactly when the number matters.
    fileprivate init?(json: Any?) {
        guard let object = json as? [String: Any],
              let used = Self.number(object["used_percentage"]),
              used.isFinite, used >= 0
        else { return nil }

        self.usedPercentage = min(used, 100)
        if let reset = Self.number(object["resets_at"]), reset.isFinite, reset > 0 {
            self.resetsAt = Date(timeIntervalSince1970: reset)
        } else {
            self.resetsAt = nil
        }
    }

    init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// JSONSerialization hands booleans back as NSNumber too, so they are
    /// excluded by type rather than trusted as 0 or 1.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }
}

/// The most recent report, as received.
nonisolated struct RateLimits: Equatable, Sendable {
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?
    let receivedAt: Date

    /// Past this age a figure is still shown but marked old. Usage on
    /// claude.ai or another machine counts against the same limits and never
    /// reaches this app, so a quiet status line is not proof nothing changed.
    static let staleAfter: TimeInterval = 15 * 60

    /// Parse the payload the status line bridge forwards, or nil when it holds
    /// no usable window — an API-key login sends no `rate_limits` at all.
    static func decode(from data: Data, receivedAt: Date) -> RateLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return nil }

        let fiveHour = RateLimitWindow(json: limits["five_hour"])
        let sevenDay = RateLimitWindow(json: limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return RateLimits(fiveHour: fiveHour, sevenDay: sevenDay, receivedAt: receivedAt)
    }

    /// What may honestly be shown at `now`, or nil for nothing.
    ///
    /// A window past its reset is withdrawn: the remembered figure described
    /// the previous window, and the new one's is unknown. A window with no
    /// reset time can only be vouched for while the report is fresh.
    func display(at now: Date) -> RateLimitDisplay? {
        let isStale = now.timeIntervalSince(receivedAt) > Self.staleAfter

        func current(_ window: RateLimitWindow?) -> RateLimitWindow? {
            guard let window else { return nil }
            if let resetsAt = window.resetsAt {
                return resetsAt > now ? window : nil
            }
            return isStale ? nil : window
        }

        let fiveHour = current(fiveHour)
        let sevenDay = current(sevenDay)
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return RateLimitDisplay(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            receivedAt: receivedAt,
            isStale: isStale
        )
    }
}

/// The windows still worth showing, and whether they are old news.
nonisolated struct RateLimitDisplay: Equatable, Sendable {
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?
    let receivedAt: Date
    let isStale: Bool
}
