//
//  ClaudeModelPricing.swift
//  ClaudeIsland
//
//  Published per-model rates, used to turn recorded tokens into an estimate.
//

import Foundation

/// What one model costs and how much context it holds.
///
/// Rates are Anthropic's first-party list prices per million tokens, as
/// published at https://platform.claude.com/docs/en/about-claude/pricing
/// (checked 2026-09-01). They are deliberately spelled out rather than derived
/// from a multiplier so a row can be corrected against the page it came from.
///
/// What this cannot know, and why the result is only ever called an estimate:
/// a subscription plan rather than API billing, negotiated or enterprise rates,
/// the batch discount, fast mode, or the 1.1x data-residency multiplier.
nonisolated struct ClaudeModelPricing: Equatable, Sendable {
    /// Tokens the model can hold in one request.
    let contextWindow: Int

    let inputPerMTok: Double
    let cacheWrite5mPerMTok: Double
    let cacheWrite1hPerMTok: Double
    let cacheReadPerMTok: Double
    let outputPerMTok: Double
}

extension ClaudeModelPricing {

    /// Keyed by the model ID as it appears in a transcript, before any dated
    /// snapshot or context-tier suffix.
    ///
    /// A model that is not in here has no price and no window, and both meters
    /// stand down for it. That is the intended behaviour for anything released
    /// after this table was written: a wrong dollar figure is worse than none,
    /// because nothing about it looks wrong.
    static let table: [String: ClaudeModelPricing] = [
        "claude-fable-5":   ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 10, cacheWrite5mPerMTok: 12.50, cacheWrite1hPerMTok: 20, cacheReadPerMTok: 1.00, outputPerMTok: 50),

        "claude-opus-5":    ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 5, cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.50, outputPerMTok: 25),
        "claude-opus-4-8":  ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 5, cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.50, outputPerMTok: 25),
        "claude-opus-4-7":  ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 5, cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.50, outputPerMTok: 25),
        "claude-opus-4-6":  ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 5, cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.50, outputPerMTok: 25),
        // The 1M window arrived with the 4.6 generation; 4.5 is a 200K model.
        "claude-opus-4-5":  ClaudeModelPricing(contextWindow: 200_000, inputPerMTok: 5, cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10, cacheReadPerMTok: 0.50, outputPerMTok: 25),

        "claude-sonnet-5":   ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 2, cacheWrite5mPerMTok: 2.50, cacheWrite1hPerMTok: 4, cacheReadPerMTok: 0.20, outputPerMTok: 10),
        "claude-sonnet-4-6": ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 3, cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6, cacheReadPerMTok: 0.30, outputPerMTok: 15),
        "claude-sonnet-4-5": ClaudeModelPricing(contextWindow: 200_000, inputPerMTok: 3, cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6, cacheReadPerMTok: 0.30, outputPerMTok: 15),

        "claude-haiku-4-5":  ClaudeModelPricing(contextWindow: 200_000, inputPerMTok: 1, cacheWrite5mPerMTok: 1.25, cacheWrite1hPerMTok: 2, cacheReadPerMTok: 0.10, outputPerMTok: 5),
    ]

    /// Rates for a model ID as a transcript spells it.
    ///
    /// Matched as a prefix, longest first: Claude Code records whatever ID it
    /// was handed, which may carry a dated snapshot (`-20250929`) or a
    /// context-tier suffix (`[1m]`). Longest-first matters — `claude-sonnet-4-5`
    /// and `claude-sonnet-4-6` are different prices, so a shorter shared prefix
    /// must never win.
    /// Takes the table as a parameter so the longest-first rule can be
    /// exercised against an ambiguous pair. The shipped table has none — see
    /// `noEntryIsAPrefixOfAnother` — so the rule is a guard against a future
    /// entry like `claude-opus-4` silently shadowing `claude-opus-4-5`.
    static func forModel(
        _ modelID: String?,
        in table: [String: ClaudeModelPricing] = ClaudeModelPricing.table
    ) -> ClaudeModelPricing? {
        guard let modelID, !modelID.isEmpty else { return nil }

        return table
            .filter { modelID.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
