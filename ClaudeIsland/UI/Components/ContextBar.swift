//
//  ContextBar.swift
//  ClaudeIsland
//
//  A hairline fill showing how much of the model's context window the session's
//  last request carried.
//

import SwiftUI

struct ContextBar: View {
    let meter: ContextMeter

    /// Amber from here, red from `critical` — the point at which the next long
    /// tool result is what triggers compaction, rather than a distant worry.
    private let warning = 0.70
    private let critical = 0.88

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))

                Capsule()
                    .fill(fillColor)
                    .frame(width: max(geometry.size.width * meter.fraction, 2))
            }
        }
        .frame(height: 2)
        .help("Context: \(meter.summary)")
    }

    private var fillColor: Color {
        switch meter.fraction {
        case critical...: return TerminalColors.red.opacity(0.8)
        case warning...: return TerminalColors.amber.opacity(0.8)
        default: return Color.white.opacity(0.22)
        }
    }
}
