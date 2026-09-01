//
//  UsageInfo.swift
//  ClaudeIsland
//
//  Token usage read out of a session transcript.
//

import Foundation

/// Tokens billed against one model over the life of a session.
///
/// The four input categories are priced differently — a cache read is a tenth
/// of base input, a 1-hour cache write is twice it — so they are counted apart
/// and never rolled into one number.
nonisolated struct ModelUsage: Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWrite5mTokens: Int = 0
    var cacheWrite1hTokens: Int = 0

    var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0
            && cacheWrite5mTokens == 0 && cacheWrite1hTokens == 0
    }
}

/// Token usage information from a session.
nonisolated struct UsageInfo: Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    /// Everything the session has spent, split by the model that spent it.
    /// Summed over the whole transcript, because every request in it was
    /// billed — a `/clear` resets the conversation, not the invoice.
    var byModel: [String: ModelUsage] = [:]

    /// What the most recent request actually carried into the model, and which
    /// model read it.
    ///
    /// Context occupancy is a property of one request, never a sum: the same
    /// cached prefix is re-sent every turn, so adding turns together measures
    /// nothing. A compaction or a `/clear` shows up here as the number falling.
    var lastContextTokens: Int = 0
    var lastModel: String?

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Formatted string for display (e.g., "12.5K tokens")
    var formattedTotal: String {
        let total = totalTokens
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
    }
}

// MARK: - Reading a transcript's usage block

nonisolated extension UsageInfo {

    /// Fold one assistant message's `usage` block into the running totals.
    ///
    /// Two different questions are being answered here. Cost accumulates across
    /// every message including subagent sidechains -- all of it was billed --
    /// and is kept per model, since a session that switched models is billed at
    /// both rates. Context occupancy is instead overwritten by each message and
    /// skips sidechains, because it is a property of one request into one
    /// context window, and a subagent has its own.
    mutating func accumulate(
        _ usageDict: [String: Any],
        model: String?,
        isSidechain: Bool
    ) {
        let input = usageDict["input_tokens"] as? Int ?? 0
        let output = usageDict["output_tokens"] as? Int ?? 0
        let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usageDict["cache_creation_input_tokens"] as? Int ?? 0

        inputTokens += input
        outputTokens += output
        cacheReadTokens += cacheRead
        cacheCreationTokens += cacheCreation

        // Newer transcripts break cache writes down by TTL, and the two tiers
        // are priced differently (1.25x vs 2x base input). Without the
        // breakdown, treat the whole thing as the cheaper 5-minute tier so the
        // estimate errs low rather than inventing a premium.
        let breakdown = usageDict["cache_creation"] as? [String: Any]
        var write5m = breakdown?["ephemeral_5m_input_tokens"] as? Int ?? 0
        let write1h = breakdown?["ephemeral_1h_input_tokens"] as? Int ?? 0
        if write5m + write1h == 0 { write5m = cacheCreation }

        if let model, !model.isEmpty {
            var billed = byModel[model] ?? ModelUsage()
            billed.inputTokens += input
            billed.outputTokens += output
            billed.cacheReadTokens += cacheRead
            billed.cacheWrite5mTokens += write5m
            billed.cacheWrite1hTokens += write1h
            byModel[model] = billed
        }

        guard !isSidechain else { return }
        lastContextTokens = input + cacheRead + cacheCreation
        lastModel = model
    }
}
