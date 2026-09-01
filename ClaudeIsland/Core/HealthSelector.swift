//
//  HealthSelector.swift
//  ClaudeIsland
//
//  Expand/collapse state and the live health report behind the health row,
//  so NotchViewModel can grow the settings panel to fit it.
//

import Combine
import Foundation

@MainActor
class HealthSelector: ObservableObject {
    static let shared = HealthSelector()

    /// Nil until the first collection runs. The row shows a checking state
    /// rather than an invented all-clear.
    @Published private(set) var report: HealthReport?
    @Published var isExpanded: Bool = false

    /// Height of a check that is fine — one line, dot plus title plus detail.
    private let okRowHeight: CGFloat = 30

    /// Height of a check that is not — the remedy takes a second line.
    private let problemRowHeight: CGFloat = 46

    /// Height of the "checked <age>" footer with its re-check button.
    private let footerHeight: CGFloat = 28

    /// Beyond this the list scrolls inside the panel rather than growing it.
    /// The settings panel is hand-sized and eight checks with remedies would
    /// otherwise push it off the screen.
    private let maxExpandedHeight: CGFloat = 268

    private init() {}

    /// Re-read every link. A few `stat` calls and one small file read, so it
    /// runs inline rather than leaving the row showing a stale verdict while an
    /// async collection lands.
    func refresh() {
        report = HealthReport.make(from: HealthFactsCollector.collect())
    }

    /// Extra height the settings panel needs while the list is open.
    var expandedPickerHeight: CGFloat {
        guard isExpanded else { return 0 }
        guard let report else { return okRowHeight }

        let content = report.checks.reduce(CGFloat.zero) { total, check in
            total + (check.remedy == nil ? okRowHeight : problemRowHeight)
        }
        return min(content + footerHeight, maxExpandedHeight)
    }
}
