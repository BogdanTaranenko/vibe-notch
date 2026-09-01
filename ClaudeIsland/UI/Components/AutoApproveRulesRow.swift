//
//  AutoApproveRulesRow.swift
//  ClaudeIsland
//
//  Settings row listing the standing auto-approve rules, each revocable in one
//  click.
//

import SwiftUI

struct AutoApproveRulesRow: View {
    @ObservedObject var selector: AutoApproveRuleSelector

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if selector.isExpanded {
                if selector.rules.isEmpty {
                    Text("No rules — every request is asked.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 38)
                        .padding(.vertical, 8)
                } else {
                    ForEach(selector.rules) { rule in
                        AutoApproveRuleItem(rule: rule) {
                            selector.revoke(id: rule.id)
                        }
                    }

                    Button {
                        selector.revokeAll()
                    } label: {
                        Text("Revoke all")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4).opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 38)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { selector.reload() }
    }

    private var header: some View {
        Button {
            selector.reload()
            withAnimation(.easeOut(duration: 0.18)) {
                selector.isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.badge.clock")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("Auto-approve")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundColor(selector.rules.isEmpty ? .white.opacity(0.4) : TerminalColors.amber.opacity(0.9))

                Image(systemName: selector.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var countLabel: String {
        switch selector.rules.count {
        case 0: return "None"
        case 1: return "1 rule"
        case let count: return "\(count) rules"
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - One rule

private struct AutoApproveRuleItem: View {
    let rule: AutoApproveRule
    let onRevoke: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(rule.projectName)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onRevoke) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.25))
            }
            .buttonStyle(.plain)
            .help("Revoke this rule")
        }
        .padding(.leading, 38)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}
