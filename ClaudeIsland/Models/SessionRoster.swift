//
//  SessionRoster.swift
//  ClaudeIsland
//
//  Pure decisions about the set of sessions: which order they appear in, which
//  of them are stale, and which earn an indicator in the collapsed notch.
//

import Foundation

/// The part of a session these decisions actually read.
///
/// Deliberately not `SessionState`. That type reaches `ConversationInfo`, which
/// lives in `ConversationParser` and would drag the whole parser into the
/// hostless test bundle. Everything here needs five fields, so it asks for five
/// fields and stays testable against a stub.
protocol SessionSlot {
    var sessionId: String { get }
    var pid: Int? { get }
    var phase: SessionPhase { get }
    var lastUserMessageDate: Date? { get }
    var lastActivity: Date { get }
}

enum SessionRoster {

    // MARK: - Ordering

    /// One order, used by both the opened list and the collapsed indicator row,
    /// so the third icon is the third row.
    ///
    /// Attention first, then most recently spoken to. The final tiebreak is not
    /// decoration: `sorted(by:)` is not stable, so slots with equal dates would
    /// otherwise swap places between renders — the list visibly reshuffles and
    /// the indicators trade positions under the user's eye.
    static func sorted<S: SessionSlot>(_ slots: [S]) -> [S] {
        slots.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            if dateA != dateB {
                return dateA > dateB
            }
            return a.sessionId < b.sessionId
        }
    }

    /// Lower number = higher priority. Approval shares a rank with processing so
    /// that answering a permission does not make the row jump.
    static func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    // MARK: - Retirement

    /// Session ids that `newSessionId` replaces, given it reported `pid`.
    ///
    /// A Claude process hosts exactly one session at a time, so a *new* session
    /// id arriving from a PID we are already tracking means the previous one is
    /// over — `/clear`, `/resume`, or a new conversation in the same terminal.
    /// Claude Code sends no event to say so, and the liveness reaper cannot tell
    /// either: the PID is still very much alive, being the one that just spoke.
    /// Left alone the old id is tracked forever, still holding whatever phase it
    /// was frozen in, and every `/clear` adds another.
    ///
    /// Matching is on PID alone. A PID identifies the process, and if the number
    /// has been recycled by an unrelated process then the entry claiming it was
    /// stale anyway. Slots with no PID are never retired this way, since nothing
    /// identifies them.
    static func superseded<S: SessionSlot>(by newSessionId: String, pid: Int?, in slots: [S]) -> [String] {
        guard let pid else { return [] }
        return slots
            .filter { $0.pid == pid && $0.sessionId != newSessionId }
            .map(\.sessionId)
    }

    // MARK: - Collapsed indicators

    /// How many per-session indicators the collapsed notch will draw before the
    /// remainder collapses into a count. The panel expands sideways into the
    /// menu bar, so this is a hard bound, not a preference.
    static let indicatorLimit = 4

    /// How long a finished session keeps its checkmark.
    static let waitingForInputWindow: TimeInterval = 30

    struct Indicators<S: SessionSlot>: Equatable where S: Equatable {
        var shown: [S] = []
        /// Active sessions beyond `indicatorLimit`, rendered as "+n".
        var overflow: Int = 0

        var isEmpty: Bool { shown.isEmpty }
        var total: Int { shown.count + overflow }
    }

    /// The sessions worth a glance without opening the notch.
    ///
    /// Working and blocked sessions always qualify. A session that has just
    /// finished qualifies only for `waitingForInputWindow` after it got there,
    /// which is why the caller passes when each one arrived — nothing in the
    /// session itself records the transition. An unknown arrival time is treated
    /// as expired rather than as "now": a session already sitting in
    /// `waitingForInput` when the app launches has not just finished, and
    /// showing it a fresh checkmark would claim something that did not happen.
    static func indicators<S: SessionSlot & Equatable>(
        for slots: [S],
        waitingSince: [String: Date],
        now: Date = Date(),
        limit: Int = indicatorLimit
    ) -> Indicators<S> {
        let active = sorted(slots).filter { slot in
            switch slot.phase {
            case .processing, .compacting, .waitingForApproval:
                return true
            case .waitingForInput:
                guard let since = waitingSince[slot.sessionId] else { return false }
                return now.timeIntervalSince(since) < waitingForInputWindow
            case .idle, .ended:
                return false
            }
        }

        guard active.count > limit else {
            return Indicators(shown: active, overflow: 0)
        }
        return Indicators(shown: Array(active.prefix(limit)), overflow: active.count - limit)
    }
}
