//
//  SessionMeter.swift
//  ClaudeIsland
//
//  Turns recorded token usage into the two numbers people actually want:
//  how close the session is to compaction, and roughly what it has cost.
//

import Foundation

/// How much of the model's context window the last request carried.
nonisolated struct ContextMeter: Equatable, Sendable {
    let used: Int
    let window: Int

    /// 0...1, for a bar.
    var fraction: Double {
        window > 0 ? min(Double(used) / Double(window), 1) : 0
    }

    var percent: Int {
        Int((fraction * 100).rounded())
    }

    /// e.g. "333K of 1M (33%)".
    var summary: String {
        "\(Self.short(used)) of \(Self.short(window)) (\(percent)%)"
    }

    static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let millions = Double(tokens) / 1_000_000
            return millions == millions.rounded()
                ? String(format: "%.0fM", millions)
                : String(format: "%.1fM", millions)
        }
        if tokens >= 1_000 {
            return String(format: "%.0fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

/// What the session has cost at list prices.
nonisolated struct CostEstimate: Equatable, Sendable {
    let dollars: Double

    /// True when the session used a model with no entry in the price table, so
    /// the real total is higher than this one. Rendered as a trailing `+`
    /// rather than quietly presented as the answer.
    let isPartial: Bool

    var formatted: String {
        let suffix = isPartial ? "+" : ""
        if dollars > 0 && dollars < 0.01 {
            return "<$0.01" + suffix
        }
        return String(format: "$%.2f", dollars) + suffix
    }
}

/// Both meters, derived from usage the parser already collected.
nonisolated enum SessionMeter {

    /// How full the context is, or nil when we cannot say honestly.
    ///
    /// Returns nil when the model is unknown, when nothing has been recorded
    /// yet, or when the recorded context exceeds the window we believe in —
    /// that last case is direct evidence the table is wrong for this session
    /// (a larger context tier we do not know about), and "150%" or a clamped
    /// "100%" would both be inventions.
    static func context(for usage: UsageInfo) -> ContextMeter? {
        guard usage.lastContextTokens > 0,
              let pricing = ClaudeModelPricing.forModel(usage.lastModel),
              usage.lastContextTokens <= pricing.contextWindow
        else { return nil }

        return ContextMeter(used: usage.lastContextTokens, window: pricing.contextWindow)
    }

    /// What the session has cost, or nil when nothing in it can be priced.
    static func cost(for usage: UsageInfo) -> CostEstimate? {
        var dollars = 0.0
        var priced = false
        var unpriced = false

        for (model, tokens) in usage.byModel {
            guard !tokens.isEmpty else { continue }

            guard let pricing = ClaudeModelPricing.forModel(model) else {
                unpriced = true
                continue
            }

            priced = true
            dollars += perMillion(tokens.inputTokens, pricing.inputPerMTok)
                + perMillion(tokens.outputTokens, pricing.outputPerMTok)
                + perMillion(tokens.cacheReadTokens, pricing.cacheReadPerMTok)
                + perMillion(tokens.cacheWrite5mTokens, pricing.cacheWrite5mPerMTok)
                + perMillion(tokens.cacheWrite1hTokens, pricing.cacheWrite1hPerMTok)
        }

        guard priced else { return nil }
        return CostEstimate(dollars: dollars, isPartial: unpriced)
    }

    private static func perMillion(_ tokens: Int, _ rate: Double) -> Double {
        Double(tokens) / 1_000_000 * rate
    }
}
