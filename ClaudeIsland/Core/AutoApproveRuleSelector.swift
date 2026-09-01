//
//  AutoApproveRuleSelector.swift
//  ClaudeIsland
//
//  Expand/collapse state and the live rule list behind the auto-approve row,
//  so NotchViewModel can grow the settings panel to fit it.
//

import Combine
import Foundation

@MainActor
class AutoApproveRuleSelector: ObservableObject {
    static let shared = AutoApproveRuleSelector()

    @Published private(set) var rules: [AutoApproveRule] = []
    @Published var isExpanded: Bool = false

    /// Height of one rule row.
    private let rowHeight: CGFloat = 38

    /// Height of the "Revoke all" footer.
    private let footerHeight: CGFloat = 30

    /// Beyond this the list scrolls inside the panel rather than growing it —
    /// the settings panel is hand-sized, and an unbounded rule list would push
    /// it off the screen.
    private let maxVisibleRows: Int = 6

    private init() {
        reload()
    }

    /// Re-read from storage. Cheap, and the only way the row learns about a
    /// rule created from the chat view while the menu was closed.
    func reload() {
        rules = AppSettings.autoApproveRules
    }

    func revoke(id: UUID) {
        AppSettings.removeAutoApproveRule(id: id)
        reload()
    }

    func revokeAll() {
        AppSettings.removeAllAutoApproveRules()
        reload()
        isExpanded = false
    }

    /// Extra height the settings panel needs while the list is open.
    var expandedPickerHeight: CGFloat {
        guard isExpanded else { return 0 }
        guard !rules.isEmpty else { return rowHeight }
        let visible = min(rules.count, maxVisibleRows)
        return CGFloat(visible) * rowHeight + footerHeight + 8
    }
}
