//
//  ProcessingSpinner.swift
//  ClaudeIsland
//
//  Animated symbol spinner for processing state
//

import Combine
import SwiftUI

struct ProcessingSpinner: View {
    @State private var phase: Int = 0

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let color: Color

    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(color: Color = Color(red: 0.85, green: 0.47, blue: 0.34)) {  // Claude orange
        self.color = color
    }

    var body: some View {
        // Keep this a leaf view with its own state. Ticking the phase from a
        // parent — a row in the instances list, say — re-evaluates that whole
        // parent body 6.7 times a second, and inside a lazy stack an
        // invalidated cell makes the layout re-place every visible row.
        Text(symbols[phase % symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            // The glyphs have different advances, so pin the width: an unpinned
            // frame resizes on every tick and drags the enclosing layout along.
            .frame(width: 12, alignment: .center)
            .onReceive(timer) { _ in
                phase = (phase + 1) % symbols.count
            }
    }
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
