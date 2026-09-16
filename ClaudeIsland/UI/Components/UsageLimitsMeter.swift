//
//  UsageLimitsMeter.swift
//  ClaudeIsland
//
//  The 5-hour and weekly plan usage gauges, as a row at the top of the
//  session list.
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
                HStack(spacing: 16) {
                    if let window = display.fiveHour {
                        gauge(label: "5h", window: window, now: context.date)
                    }
                    if let window = display.sevenDay {
                        gauge(label: "7d", window: window, now: context.date)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .opacity(display.isStale ? 0.45 : 1)
                .help(tooltip(for: display, now: context.date))
            }
        }
    }

    private func gauge(label: String, window: RateLimitWindow, now: Date) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(fillColor(for: window.fraction))
                        .frame(width: max(geometry.size.width * window.fraction, 3))
                }
            }
            .frame(height: 3)

            Text("\(window.percent)%")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .monospacedDigit()
                .fixedSize()

            if let reset = window.timeUntilReset(from: now) {
                Text("resets \(reset)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// Same thresholds as the context bar: amber is worth pacing around, red
    /// means the next long turn may be the one that stops.
    private func fillColor(for fraction: Double) -> Color {
        switch fraction {
        case 0.88...: return TerminalColors.red.opacity(0.8)
        case 0.70...: return TerminalColors.amber.opacity(0.8)
        default: return Color.white.opacity(0.45)
        }
    }

    private func tooltip(for display: RateLimitDisplay, now: Date) -> String {
        let age = RateLimitWindow.shortDuration(now.timeIntervalSince(display.receivedAt))
        return display.isStale
            ? "Plan usage last reported \(age) ago — usage elsewhere may not be reflected"
            : "Plan usage, as reported by Claude Code's status line"
    }
}
