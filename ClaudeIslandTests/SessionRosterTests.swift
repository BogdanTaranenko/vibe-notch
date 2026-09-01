//
//  SessionRosterTests.swift
//  ClaudeIslandTests
//
//  Covers the three roster decisions the notch cannot get wrong quietly:
//  what order sessions appear in, which ones are stale, and which earn an
//  indicator while the notch is closed.
//
//  A wrong answer here is not a crash. It is a notch that reports work nobody
//  is doing, or hides work somebody is waiting on.
//

import Foundation
import Testing

private struct Slot: SessionSlot, Equatable {
    var sessionId: String
    var pid: Int?
    var phase: SessionPhase
    var lastUserMessageDate: Date?
    var lastActivity: Date

    init(
        _ sessionId: String,
        pid: Int? = 1,
        phase: SessionPhase = .processing,
        spokeAt: TimeInterval? = nil,
        activeAt: TimeInterval = 0
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.phase = phase
        self.lastUserMessageDate = spokeAt.map { Date(timeIntervalSince1970: $0) }
        self.lastActivity = Date(timeIntervalSince1970: activeAt)
    }
}

private let approval = SessionPhase.waitingForApproval(PermissionContext(
    toolUseId: "toolu_01",
    toolName: "Bash",
    toolInput: nil,
    receivedAt: Date(timeIntervalSince1970: 0)
))

@Suite("Session roster ordering")
struct SessionRosterOrderingTests {

    @Test("Sessions needing attention or working sort ahead of finished ones")
    func attentionOutranksFinished() {
        let slots = [
            Slot("done", phase: .waitingForInput, spokeAt: 100),
            Slot("idle", phase: .idle, spokeAt: 100),
            Slot("busy", phase: .processing, spokeAt: 1),
        ]
        #expect(SessionRoster.sorted(slots).map(\.sessionId) == ["busy", "done", "idle"])
    }

    @Test("Approval and processing share a rank, so answering one does not reshuffle")
    func approvalRanksWithProcessing() {
        #expect(SessionRoster.phasePriority(approval) == SessionRoster.phasePriority(.processing))
        #expect(SessionRoster.phasePriority(.compacting) == SessionRoster.phasePriority(.processing))
    }

    @Test("Within a rank, the most recently spoken to comes first")
    func mostRecentFirst() {
        let slots = [Slot("old", spokeAt: 10), Slot("new", spokeAt: 99), Slot("mid", spokeAt: 50)]
        #expect(SessionRoster.sorted(slots).map(\.sessionId) == ["new", "mid", "old"])
    }

    @Test("With no user message yet, lastActivity stands in")
    func fallsBackToLastActivity() {
        let slots = [Slot("quiet", spokeAt: nil, activeAt: 70), Slot("older", spokeAt: nil, activeAt: 5)]
        #expect(SessionRoster.sorted(slots).map(\.sessionId) == ["quiet", "older"])
    }

    @Test("Equal dates break by session id, so the order cannot flicker")
    func stableUnderEqualDates() {
        // sorted(by:) is not stable. Without the id tiebreak these two are free
        // to swap on every render, which the user sees as icons trading places.
        let slots = [Slot("bbb", spokeAt: 42), Slot("aaa", spokeAt: 42), Slot("ccc", spokeAt: 42)]
        let once = SessionRoster.sorted(slots).map(\.sessionId)
        let again = SessionRoster.sorted(slots.reversed()).map(\.sessionId)
        #expect(once == ["aaa", "bbb", "ccc"])
        #expect(once == again)
    }
}

@Suite("Session roster retirement")
struct SessionRosterRetirementTests {

    @Test("A new session id on a known PID retires the old one")
    func newSessionRetiresPredecessor() {
        // What /clear does: same process, new session id, and no event anywhere
        // saying the old one ended.
        let slots = [Slot("old", pid: 900), Slot("other", pid: 901)]
        #expect(SessionRoster.superseded(by: "new", pid: 900, in: slots) == ["old"])
    }

    @Test("Sessions on other PIDs are untouched")
    func otherProcessesSurvive() {
        let slots = [Slot("a", pid: 900), Slot("b", pid: 901), Slot("c", pid: 902)]
        #expect(SessionRoster.superseded(by: "new", pid: 901, in: slots) == ["b"])
    }

    @Test("A session never retires itself")
    func doesNotRetireItself() {
        // Every hook event after the first arrives for a session already in the
        // store. Retiring on those would delete the live session on its own
        // second event.
        let slots = [Slot("live", pid: 900)]
        #expect(SessionRoster.superseded(by: "live", pid: 900, in: slots).isEmpty)
    }

    @Test("An unknown PID retires nothing")
    func unknownPidRetiresNothing() {
        let slots = [Slot("a", pid: 900)]
        #expect(SessionRoster.superseded(by: "new", pid: 42, in: slots).isEmpty)
        #expect(SessionRoster.superseded(by: "new", pid: nil, in: slots).isEmpty)
    }

    @Test("A session with no PID is never retired by PID match")
    func pidlessSessionsAreLeftAlone() {
        let slots = [Slot("nopid", pid: nil)]
        #expect(SessionRoster.superseded(by: "new", pid: nil, in: slots).isEmpty)
    }

    @Test("Several stale ids on one PID all retire together")
    func retiresEveryStaleIdOnThatPid() {
        let slots = [Slot("clear1", pid: 900), Slot("clear2", pid: 900), Slot("elsewhere", pid: 901)]
        #expect(Set(SessionRoster.superseded(by: "new", pid: 900, in: slots)) == ["clear1", "clear2"])
    }
}

@Suite("Collapsed notch indicators")
struct SessionRosterIndicatorTests {

    let now = Date(timeIntervalSince1970: 1_000)

    @Test("Working and blocked sessions each earn an indicator")
    func activePhasesQualify() {
        let slots = [
            Slot("busy", pid: 1, phase: .processing),
            Slot("blocked", pid: 2, phase: approval),
            Slot("compacting", pid: 3, phase: .compacting),
        ]
        let result = SessionRoster.indicators(for: slots, waitingSince: [:], now: now)
        #expect(result.shown.count == 3)
        #expect(result.overflow == 0)
    }

    @Test("Idle and ended sessions earn nothing")
    func quietPhasesDoNot() {
        let slots = [Slot("idle", pid: 1, phase: .idle), Slot("gone", pid: 2, phase: .ended)]
        #expect(SessionRoster.indicators(for: slots, waitingSince: [:], now: now).isEmpty)
    }

    @Test("A just-finished session keeps its checkmark inside the window")
    func recentlyFinishedQualifies() {
        let slots = [Slot("done", phase: .waitingForInput)]
        let result = SessionRoster.indicators(
            for: slots,
            waitingSince: ["done": now.addingTimeInterval(-5)],
            now: now
        )
        #expect(result.shown.map(\.sessionId) == ["done"])
    }

    @Test("Past the window it drops out")
    func expiredFinishedDoesNot() {
        let slots = [Slot("done", phase: .waitingForInput)]
        let result = SessionRoster.indicators(
            for: slots,
            waitingSince: ["done": now.addingTimeInterval(-SessionRoster.waitingForInputWindow - 1)],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("A finished session we never saw arrive is treated as expired, not fresh")
    func unknownArrivalIsExpired() {
        // A session already sitting in waitingForInput when the app launches did
        // not just finish. Defaulting to `now` would greet the user with a
        // checkmark for something that happened an hour ago.
        let slots = [Slot("preexisting", phase: .waitingForInput)]
        #expect(SessionRoster.indicators(for: slots, waitingSince: [:], now: now).isEmpty)
    }

    @Test("Indicators follow the same order as the opened list")
    func indicatorsShareTheListOrder() {
        let slots = [
            Slot("done", pid: 1, phase: .waitingForInput, spokeAt: 900),
            Slot("busy", pid: 2, phase: .processing, spokeAt: 100),
        ]
        let result = SessionRoster.indicators(
            for: slots,
            waitingSince: ["done": now.addingTimeInterval(-1)],
            now: now
        )
        #expect(result.shown.map(\.sessionId) == SessionRoster.sorted(slots).map(\.sessionId))
        #expect(result.shown.map(\.sessionId) == ["busy", "done"])
    }

    @Test("At the limit everything is still shown")
    func exactlyAtTheLimit() {
        let slots = (0..<SessionRoster.indicatorLimit).map { Slot("s\($0)", pid: $0, spokeAt: Double($0)) }
        let result = SessionRoster.indicators(for: slots, waitingSince: [:], now: now)
        #expect(result.shown.count == SessionRoster.indicatorLimit)
        #expect(result.overflow == 0)
    }

    @Test("Past the limit the remainder becomes a count, and nothing is lost")
    func overflowCounts() {
        let slots = (0..<7).map { Slot("s\($0)", pid: $0, spokeAt: Double($0)) }
        let result = SessionRoster.indicators(for: slots, waitingSince: [:], now: now)
        #expect(result.shown.count == SessionRoster.indicatorLimit)
        #expect(result.overflow == 3)
        #expect(result.total == 7)
    }

    @Test("Overflow keeps the highest-priority sessions, not an arbitrary four")
    func overflowKeepsTheImportantOnes() {
        let finished = (0..<4).map {
            Slot("done\($0)", pid: 10 + $0, phase: .waitingForInput, spokeAt: 900)
        }
        let blocked = Slot("blocked", pid: 1, phase: approval, spokeAt: 1)
        let waiting = Dictionary(uniqueKeysWithValues: finished.map { ($0.sessionId, now.addingTimeInterval(-1)) })

        let result = SessionRoster.indicators(for: finished + [blocked], waitingSince: waiting, now: now)
        #expect(result.shown.first?.sessionId == "blocked")
        #expect(result.overflow == 1)
    }
}
