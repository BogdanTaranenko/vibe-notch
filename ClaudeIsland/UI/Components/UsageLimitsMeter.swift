//
//  UsageLimitsMeter.swift
//  ClaudeIsland
//
//  Compact 5-hour and weekly plan usage gauges for the opened notch header.
//

import SwiftUI

struct UsageLimitsMeter: View {
    let limits: RateLimits

    /// Re-evaluated on a timer as well as on each report, so a window that
    /// resets while no session is running disappears on time.
    private let tick: TimeInterval = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: tick)) { context in
            if let display = limits.display(at: context.date) {
                HStack(spacing: 10) {
                    if let window = display.fiveHour {
                        gauge(label: "5h", window: window)
                    }
                    if let window = display.sevenDay {
                        gauge(label: "7d", window: window)
                    }
                }
                .opacity(display.isStale ? 0.45 : 1)
                .help(tooltip(for: display, now: context.date))
            }
        }
    }

    private func gauge(label: String, window: RateLimitWindow) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(fillColor(for: window.fraction))
                    .frame(width: max(24 * window.fraction, 2))
            }
            .frame(width: 24, height: 3)

            Text("\(window.percent)%")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .monospacedDigit()
        }
    }

    /// Same thresholds as the context bar: amber is worth pacing around, red
    /// means the next long turn may be the one that stops.
    private func fillColor(for fraction: Double) -> Color {
        switch fraction {
        case 0.88...: return TerminalColors.red.opacity(0.8)
        case 0.70...: return TerminalColors.amber.opacity(0.8)
        default: return Color.white.opacity(0.35)
        }
    }

    private func tooltip(for display: RateLimitDisplay, now: Date) -> String {
        var lines: [String] = []
        if let window = display.fiveHour {
            lines.append(describe("5-hour limit", window, now: now))
        }
        if let window = display.sevenDay {
            lines.append(describe("Weekly limit", window, now: now))
        }
        let age = RateLimitWindow.shortDuration(now.timeIntervalSince(display.receivedAt))
        lines.append(display.isStale
            ? "Last reported \(age) ago — usage elsewhere may not be reflected"
            : "Reported by Claude Code's status line")
        return lines.joined(separator: "\n")
    }

    private func describe(_ name: String, _ window: RateLimitWindow, now: Date) -> String {
        let reset = window.timeUntilReset(from: now).map { " · resets in \($0)" } ?? ""
        return "\(name): \(window.percent)% used\(reset)"
    }
}
