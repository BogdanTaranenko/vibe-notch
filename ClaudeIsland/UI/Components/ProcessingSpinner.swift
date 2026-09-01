//
//  ProcessingSpinner.swift
//  ClaudeIsland
//
//  Animated symbol spinner for processing state
//

import Combine
import SwiftUI

struct ProcessingSpinner: View {
    @State private var phase: Int = ProcessingSpinner.phase(at: Date())

    private static let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private static let tick: TimeInterval = 0.15
    private let color: Color

    private let timer = Timer.publish(every: tick, on: .main, in: .common).autoconnect()

    /// Frame index derived from the wall clock rather than counted per view.
    ///
    /// The collapsed notch can show several of these at once, one per session.
    /// A per-view counter starts wherever that view appeared, so a row of
    /// spinners drifts out of phase and reads as several unrelated things
    /// flickering. Off a shared clock they step together without any shared
    /// state, and each view still owns its own timer.
    private static func phase(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / tick) % symbols.count
    }

    init(color: Color = Color(red: 0.85, green: 0.47, blue: 0.34)) {  // Claude orange
        self.color = color
    }

    var body: some View {
        // Keep this a leaf view with its own state. Ticking the phase from a
        // parent — a row in the instances list, say — re-evaluates that whole
        // parent body 6.7 times a second, and inside a lazy stack an
        // invalidated cell makes the layout re-place every visible row.
        Text(Self.symbols[phase % Self.symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            // The glyphs have different advances, so pin the width: an unpinned
            // frame resizes on every tick and drags the enclosing layout along.
            .frame(width: 12, alignment: .center)
            .onReceive(timer) { now in
                phase = Self.phase(at: now)
            }
    }
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
