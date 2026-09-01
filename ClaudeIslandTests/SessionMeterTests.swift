//
//  SessionMeterTests.swift
//  ClaudeIslandTests
//
//  Covers the context and cost meters. Both put a number in front of the user
//  that they may act on, so the cases below are mostly about refusing to show
//  one we cannot stand behind — an unknown model, or evidence that contradicts
//  the price table.
//

import Foundation
import Testing

@Suite("Model pricing table")
struct ClaudeModelPricingTests {

    @Test func knownModelsResolve() {
        #expect(ClaudeModelPricing.forModel("claude-opus-5")?.inputPerMTok == 5)
        #expect(ClaudeModelPricing.forModel("claude-sonnet-5")?.outputPerMTok == 10)
        #expect(ClaudeModelPricing.forModel("claude-haiku-4-5")?.contextWindow == 200_000)
        #expect(ClaudeModelPricing.forModel("claude-opus-5")?.contextWindow == 1_000_000)
    }

    /// Claude Code records whatever ID it was given: a dated snapshot, or the
    /// bare alias with a context-tier suffix.
    @Test func suffixedIdsResolveToTheirModel() {
        #expect(ClaudeModelPricing.forModel("claude-sonnet-4-5-20250929")?.inputPerMTok == 3)
        #expect(ClaudeModelPricing.forModel("claude-haiku-4-5-20251001")?.inputPerMTok == 1)
        #expect(ClaudeModelPricing.forModel("claude-opus-5[1m]")?.inputPerMTok == 5)
    }

    /// With one key a prefix of another, the longer one has to win. Nothing in
    /// the shipped table is ambiguous like this, which is exactly why the rule
    /// needs its own fixture: it guards a future entry, not a current one.
    @Test func theLongestMatchingPrefixWins() {
        let broad = ClaudeModelPricing(contextWindow: 200_000, inputPerMTok: 99, cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0, cacheReadPerMTok: 0, outputPerMTok: 0)
        let specific = ClaudeModelPricing(contextWindow: 1_000_000, inputPerMTok: 5, cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0, cacheReadPerMTok: 0, outputPerMTok: 0)
        let table = ["claude-opus-4": broad, "claude-opus-4-5": specific]

        #expect(ClaudeModelPricing.forModel("claude-opus-4-5-20251101", in: table)?.inputPerMTok == 5)
        #expect(ClaudeModelPricing.forModel("claude-opus-4-1-20250805", in: table)?.inputPerMTok == 99)
    }

    /// No shipped entry may be a prefix of another. This is what keeps the
    /// lookup unambiguous today; an entry that broke it would silently reprice
    /// every model under it.
    @Test func noEntryIsAPrefixOfAnother() {
        for key in ClaudeModelPricing.table.keys {
            let shadowed = ClaudeModelPricing.table.keys.filter { $0 != key && $0.hasPrefix(key) }
            #expect(shadowed.isEmpty, "\(key) is a prefix of \(shadowed)")
        }
    }

    /// The 4.6 generation and later are a different price to the 4.5 line, so a
    /// prefix must never win over a longer, more specific entry.
    @Test func theMostSpecificEntryWins() {
        #expect(ClaudeModelPricing.forModel("claude-sonnet-4-6")?.inputPerMTok == 3)
        #expect(ClaudeModelPricing.forModel("claude-sonnet-5")?.inputPerMTok == 2)
        #expect(ClaudeModelPricing.forModel("claude-opus-4-8")?.contextWindow == 1_000_000)
        #expect(ClaudeModelPricing.forModel("claude-opus-4-5")?.contextWindow == 200_000)
    }

    /// A model we do not have a price for gets no guess. A wrong dollar figure
    /// is worse than none, because the user cannot tell it is wrong.
    @Test func unknownModelsResolveToNil() {
        #expect(ClaudeModelPricing.forModel("claude-opus-9") == nil)
        #expect(ClaudeModelPricing.forModel("gpt-4o") == nil)
        #expect(ClaudeModelPricing.forModel("") == nil)
        #expect(ClaudeModelPricing.forModel("opus") == nil)
    }

    /// Anthropic's published multipliers: cache reads are 0.1x base input,
    /// 5-minute writes 1.25x, 1-hour writes 2x. If a row drifts from those the
    /// row was mistyped.
    @Test func everyRowMatchesThePublishedMultipliers() {
        // Compared with a tolerance: the rows carry the published rate to the
        // cent, and 3 x 0.1 is not 0.3 in binary floating point.
        func matches(_ written: Double, _ derived: Double) -> Bool { abs(written - derived) < 0.0001 }

        for (id, pricing) in ClaudeModelPricing.table {
            #expect(matches(pricing.cacheReadPerMTok, pricing.inputPerMTok * 0.1), "\(id) cache read")
            #expect(matches(pricing.cacheWrite5mPerMTok, pricing.inputPerMTok * 1.25), "\(id) 5m write")
            #expect(matches(pricing.cacheWrite1hPerMTok, pricing.inputPerMTok * 2), "\(id) 1h write")
        }
    }
}

// MARK: - Context

@Suite("Context meter")
struct ContextMeterTests {

    func usage(model: String?, context: Int) -> UsageInfo {
        var usage = UsageInfo()
        usage.lastModel = model
        usage.lastContextTokens = context
        return usage
    }

    @Test func reportsTheShareOfTheWindowInUse() {
        let meter = SessionMeter.context(for: usage(model: "claude-opus-5", context: 333_314))
        #expect(meter?.used == 333_314)
        #expect(meter?.window == 1_000_000)
        #expect(meter?.percent == 33)
    }

    /// A 200K model at the same token count is a completely different picture.
    @Test func theWindowComesFromTheModel() {
        let meter = SessionMeter.context(for: usage(model: "claude-haiku-4-5", context: 150_000))
        #expect(meter?.window == 200_000)
        #expect(meter?.percent == 75)
    }

    @Test func noModelMeansNoMeter() {
        #expect(SessionMeter.context(for: usage(model: nil, context: 100_000)) == nil)
        #expect(SessionMeter.context(for: usage(model: "claude-opus-9", context: 100_000)) == nil)
    }

    @Test func nothingRecordedYetMeansNoMeter() {
        #expect(SessionMeter.context(for: usage(model: "claude-opus-5", context: 0)) == nil)
    }

    /// A context larger than the window we believe in is proof the table is
    /// wrong for this session — a 1M tier we did not know about, say. Showing
    /// "150%" would be nonsense and showing "100%" would be a lie, so the meter
    /// stands down instead.
    @Test func contextBeyondTheKnownWindowWithdrawsTheMeter() {
        #expect(SessionMeter.context(for: usage(model: "claude-haiku-4-5", context: 300_000)) == nil)
    }

    @Test func aFullWindowIsStillReported() {
        let meter = SessionMeter.context(for: usage(model: "claude-haiku-4-5", context: 200_000))
        #expect(meter?.percent == 100)
        #expect(meter?.fraction == 1.0)
    }
}

// MARK: - Cost

@Suite("Cost estimate")
struct CostEstimateTests {

    func usage(_ models: [String: ModelUsage]) -> UsageInfo {
        var usage = UsageInfo()
        usage.byModel = models
        return usage
    }

    /// Worked against the published rates: 1M input at $5, 1M output at $25,
    /// 1M cache reads at $0.50, 1M 5-minute writes at $6.25, 1M 1-hour writes
    /// at $10 — $46.75 in all.
    @Test func everyTokenCategoryIsPricedSeparately() {
        let cost = SessionMeter.cost(for: usage([
            "claude-opus-5": ModelUsage(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                cacheWrite5mTokens: 1_000_000,
                cacheWrite1hTokens: 1_000_000
            )
        ]))

        #expect(cost != nil)
        #expect(abs((cost?.dollars ?? 0) - 46.75) < 0.0001)
        #expect(cost?.isPartial == false)
    }

    /// Cache reads are the bulk of an agent session's input, and they are a
    /// tenth of the price. Charging them as input would overstate the bill by
    /// an order of magnitude.
    @Test func cacheReadsAreNotChargedAsInput() {
        let reads = SessionMeter.cost(for: usage([
            "claude-opus-5": ModelUsage(cacheReadTokens: 1_000_000)
        ]))
        let input = SessionMeter.cost(for: usage([
            "claude-opus-5": ModelUsage(inputTokens: 1_000_000)
        ]))

        #expect(abs((reads?.dollars ?? 0) - 0.50) < 0.0001)
        #expect(abs((input?.dollars ?? 0) - 5.00) < 0.0001)
    }

    /// A 1-hour cache write is 2x base input where a 5-minute write is 1.25x,
    /// so the two must not be summed into one number.
    @Test func theTwoCacheWriteTiersArePricedApart() {
        let short = SessionMeter.cost(for: usage(["claude-opus-5": ModelUsage(cacheWrite5mTokens: 1_000_000)]))
        let long = SessionMeter.cost(for: usage(["claude-opus-5": ModelUsage(cacheWrite1hTokens: 1_000_000)]))

        #expect(abs((short?.dollars ?? 0) - 6.25) < 0.0001)
        #expect(abs((long?.dollars ?? 0) - 10.00) < 0.0001)
    }

    /// A session that changed model mid-way is billed at both rates.
    @Test func modelsAreSummedAtTheirOwnRates() {
        let cost = SessionMeter.cost(for: usage([
            "claude-opus-5": ModelUsage(outputTokens: 1_000_000),      // $25
            "claude-haiku-4-5": ModelUsage(outputTokens: 1_000_000),   // $5
        ]))

        #expect(abs((cost?.dollars ?? 0) - 30.0) < 0.0001)
        #expect(cost?.isPartial == false)
    }

    /// With one model priced and another not, the total is a floor rather than
    /// an answer, and has to say so.
    @Test func anUnpricedModelMakesTheTotalPartial() {
        let cost = SessionMeter.cost(for: usage([
            "claude-opus-5": ModelUsage(outputTokens: 1_000_000),
            "claude-something-new": ModelUsage(outputTokens: 1_000_000),
        ]))

        #expect(abs((cost?.dollars ?? 0) - 25.0) < 0.0001)
        #expect(cost?.isPartial == true)
        #expect(cost?.formatted.hasSuffix("+") == true)
    }

    @Test func nothingPricedMeansNoEstimate() {
        #expect(SessionMeter.cost(for: usage(["claude-something-new": ModelUsage(outputTokens: 999)])) == nil)
        #expect(SessionMeter.cost(for: usage([:])) == nil)
    }

    /// A model that is in the table but has recorded no tokens must not make
    /// the estimate read as partial.
    @Test func anEmptyModelEntryDoesNotTaintTheTotal() {
        let cost = SessionMeter.cost(for: usage([
            "claude-opus-5": ModelUsage(outputTokens: 1_000_000),
            "claude-something-new": ModelUsage(),
        ]))

        #expect(cost?.isPartial == false)
    }

    @Test func amountsAreFormattedForAGlance() {
        #expect(CostEstimate(dollars: 0, isPartial: false).formatted == "$0.00")
        #expect(CostEstimate(dollars: 0.004, isPartial: false).formatted == "<$0.01")
        #expect(CostEstimate(dollars: 0.42, isPartial: false).formatted == "$0.42")
        #expect(CostEstimate(dollars: 12.3456, isPartial: false).formatted == "$12.35")
        #expect(CostEstimate(dollars: 1234.5, isPartial: false).formatted == "$1234.50")
        #expect(CostEstimate(dollars: 0.42, isPartial: true).formatted == "$0.42+")
    }
}

// MARK: - Reading a transcript's usage block

@Suite("Usage accumulation")
struct UsageAccumulationTests {

    /// The shape a current Claude Code transcript actually writes, taken from a
    /// real assistant message.
    func liveUsage(input: Int = 2, output: Int = 193, read: Int = 332_677, write1h: Int = 635) -> [String: Any] {
        [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": read,
            "cache_creation_input_tokens": write1h,
            "cache_creation": [
                "ephemeral_5m_input_tokens": 0,
                "ephemeral_1h_input_tokens": write1h,
            ],
        ]
    }

    @Test func contextIsWhatTheLastRequestCarried() {
        var usage = UsageInfo()
        usage.accumulate(liveUsage(), model: "claude-opus-5", isSidechain: false)

        // input + cache reads + cache writes: everything the model was handed.
        #expect(usage.lastContextTokens == 333_314)
        #expect(usage.lastModel == "claude-opus-5")
    }

    /// Two turns re-send the same cached prefix, so context stays flat while
    /// cost keeps climbing. Summing occupancy would report 666K of a window
    /// that only ever held 333K.
    @Test func contextDoesNotAccumulateAcrossTurns() {
        var usage = UsageInfo()
        usage.accumulate(liveUsage(), model: "claude-opus-5", isSidechain: false)
        usage.accumulate(liveUsage(), model: "claude-opus-5", isSidechain: false)

        #expect(usage.lastContextTokens == 333_314)
        #expect(usage.byModel["claude-opus-5"]?.outputTokens == 386)
        #expect(usage.byModel["claude-opus-5"]?.cacheReadTokens == 665_354)
    }

    /// A subagent runs in its own context window. Its tokens are still billed,
    /// but reporting its occupancy as the session's would be a different
    /// conversation's number.
    @Test func aSidechainIsBilledButDoesNotSetTheContext() {
        var usage = UsageInfo()
        usage.accumulate(liveUsage(), model: "claude-opus-5", isSidechain: false)
        usage.accumulate(liveUsage(input: 50, output: 10, read: 900_000, write1h: 0),
                         model: "claude-opus-5", isSidechain: true)

        #expect(usage.lastContextTokens == 333_314)
        #expect(usage.byModel["claude-opus-5"]?.cacheReadTokens == 1_232_677)
    }

    @Test func theCacheWriteTtlBreakdownIsCarriedThrough() {
        var usage = UsageInfo()
        usage.accumulate(liveUsage(), model: "claude-opus-5", isSidechain: false)

        #expect(usage.byModel["claude-opus-5"]?.cacheWrite1hTokens == 635)
        #expect(usage.byModel["claude-opus-5"]?.cacheWrite5mTokens == 0)
    }

    /// An older transcript has no breakdown. Charging the whole write at the
    /// 1-hour rate would overstate it, so it lands on the cheaper tier.
    @Test func aMissingBreakdownFallsBackToTheCheaperTier() {
        var usage = UsageInfo()
        usage.accumulate(
            ["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40],
            model: "claude-sonnet-4-5",
            isSidechain: false
        )

        #expect(usage.byModel["claude-sonnet-4-5"]?.cacheWrite5mTokens == 40)
        #expect(usage.byModel["claude-sonnet-4-5"]?.cacheWrite1hTokens == 0)
    }

    @Test func aSessionThatChangedModelKeepsBothTotals() {
        var usage = UsageInfo()
        usage.accumulate(liveUsage(), model: "claude-sonnet-5", isSidechain: false)
        usage.accumulate(liveUsage(), model: "claude-opus-5", isSidechain: false)

        #expect(usage.byModel.count == 2)
        #expect(usage.lastModel == "claude-opus-5")
    }

    /// Transcripts are someone else's format. A shape we do not recognise must
    /// leave the totals alone rather than crash or invent zeros as data.
    @Test func unexpectedShapesAreIgnored() {
        var usage = UsageInfo()
        usage.accumulate(["input_tokens": "lots", "cache_creation": 7], model: nil, isSidechain: false)

        #expect(usage.inputTokens == 0)
        #expect(usage.byModel.isEmpty)
        #expect(usage.lastModel == nil)
    }
}
