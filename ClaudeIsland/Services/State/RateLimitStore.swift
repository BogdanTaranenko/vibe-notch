//
//  RateLimitStore.swift
//  ClaudeIsland
//
//  Holds the latest plan usage report and the opt-in that makes reports
//  arrive at all.
//

import Combine
import Foundation

/// Plan limits belong to the account, not to any one session, so they live
/// here rather than in `SessionStore` — every session's status line reports
/// the same two numbers, and the latest report wins.
@MainActor
final class RateLimitStore: ObservableObject {
    static let shared = RateLimitStore()

    @Published private(set) var limits: RateLimits?
    @Published private(set) var isEnabled: Bool = AppSettings.showUsageLimits

    /// Result of the last attempt to apply the opt-in to settings.json, for
    /// the settings row. Nil until the first sync.
    @Published private(set) var outcome: StatusLineOutcome?

    private init() {}

    func record(_ report: RateLimits) {
        guard isEnabled else { return }
        if let limits, limits.receivedAt > report.receivedAt { return }
        limits = report
    }

    /// Re-apply the stored opt-in to settings.json — on launch, and whenever
    /// the Claude directory or the hook registration changes underneath it.
    func sync() {
        outcome = StatusLineInstaller.sync(enabled: isEnabled)
    }

    /// Give the slot back, without changing the opt-in, for the Hooks toggle.
    /// The next `sync()` takes it again if the user still wants the meter.
    func release() {
        outcome = StatusLineInstaller.sync(enabled: false)
        limits = nil
    }

    /// The settings toggle. An opt-in that cannot be applied is reverted, so
    /// the row never reads On while nothing can arrive; the outcome stays to
    /// say why, and tapping again retries.
    func setEnabled(_ enabled: Bool) {
        let result = StatusLineInstaller.sync(enabled: enabled)
        outcome = result

        let applied = enabled ? result.isActive : !StatusLineInstaller.isInstalled()
        let nowEnabled = applied ? enabled : !enabled

        AppSettings.showUsageLimits = nowEnabled
        isEnabled = nowEnabled
        if !nowEnabled {
            limits = nil
        }
    }
}
