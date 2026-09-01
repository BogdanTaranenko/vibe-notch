//
//  HealthRow.swift
//  ClaudeIsland
//
//  Settings row showing every link in the hook chain with its live state, so
//  "it doesn't work" becomes a screenshot that answers itself.
//

import SwiftUI

struct HealthRow: View {
    @ObservedObject var selector: HealthSelector

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if selector.isExpanded {
                if let report = selector.report {
                    ForEach(report.checks) { check in
                        HealthCheckItem(check: check, onRunAction: run)
                    }
                    footer(for: report)
                } else {
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 38)
                        .padding(.vertical, 8)
                }
            }
        }
        .onAppear { selector.refresh() }
    }

    /// Runs a remedy and re-reads the panel, so the row answers for itself
    /// instead of leaving the user to guess whether it worked.
    private func run(_ action: HealthAction) {
        switch action {
        case .resetAccessibilityGrant:
            Task {
                await AccessibilityPermission.resetAndRequest()
                await MainActor.run {
                    AccessibilityPermission.openSettings()
                    selector.refresh()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            selector.refresh()
            withAnimation(.easeOut(duration: 0.18)) {
                selector.isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("Health")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                if let report = selector.report {
                    Circle()
                        .fill(color(for: report.worst))
                        .frame(width: 6, height: 6)

                    Text(report.summary)
                        .font(.system(size: 11))
                        .foregroundColor(report.worst == .ok ? .white.opacity(0.4) : color(for: report.worst))
                        .lineLimit(1)
                } else {
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

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

    // MARK: - Footer

    private func footer(for report: HealthReport) -> some View {
        HStack(spacing: 6) {
            Text("Checked at \(report.generatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))

            Spacer(minLength: 4)

            Button {
                selector.refresh()
            } label: {
                Text("Re-check")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 38)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - One check

private struct HealthCheckItem: View {
    let check: HealthCheck
    let onRunAction: (HealthAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color(for: check.status))
                .frame(width: 5, height: 5)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(check.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .fixedSize()

                    Text(check.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let remedy = check.remedy {
                    Text(remedy)
                        .font(.system(size: 10))
                        .foregroundColor(color(for: check.status).opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let action = check.action {
                    HealthActionButton(action: action, onRun: onRunAction)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 38)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Status colour

private func color(for status: HealthStatus) -> Color {
    switch status {
    case .ok: return TerminalColors.green
    case .warning: return TerminalColors.amber
    case .failing: return TerminalColors.red
    case .waiting: return .white.opacity(0.3)
    }
}

/// The button a remedy can carry. Deliberately quiet: it changes something on
/// the user's machine, so it should not read as the obvious next click.
private struct HealthActionButton: View {
    let action: HealthAction
    let onRun: (HealthAction) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onRun(action)
        } label: {
            Text(action.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 0.95 : 0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.top, 3)
    }
}
