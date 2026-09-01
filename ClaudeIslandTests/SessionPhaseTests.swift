//
//  SessionPhaseTests.swift
//  ClaudeIslandTests
//
//  Covers the session lifecycle state machine. Illegal transitions are dropped
//  rather than applied, so a missing edge here shows up as a phase that "won't
//  stick" — the UI keeps reporting the old state and no error is raised.
//

import Foundation
import Testing

@Suite("Session phase transitions")
struct SessionPhaseTests {

    func approval(tool: String = "Bash", at date: Date = Date(timeIntervalSince1970: 0)) -> SessionPhase {
        .waitingForApproval(PermissionContext(
            toolUseId: "toolu_01",
            toolName: tool,
            toolInput: nil,
            receivedAt: date
        ))
    }

    var everyPhase: [SessionPhase] {
        [.idle, .processing, .waitingForInput, approval(), .compacting, .ended]
    }

    // MARK: - Terminal state

    @Test("Nothing transitions out of ended")
    func endedIsTerminal() {
        for target in everyPhase where target != .ended {
            #expect(
                SessionPhase.ended.canTransition(to: target) == false,
                "ended -> \(target) must be refused"
            )
        }
    }

    @Test("Every phase can end")
    func anythingCanEnd() {
        for phase in everyPhase where phase != .ended {
            #expect(phase.canTransition(to: .ended), "\(phase) -> ended must be allowed")
        }
    }

    @Test("Staying put is allowed for every live phase")
    func selfTransitionsAreNoOps() {
        for phase in everyPhase where phase != .ended {
            #expect(phase.canTransition(to: phase), "\(phase) -> \(phase) must be a no-op, not a drop")
        }
    }

    @Test("Even ended -> ended is refused")
    func endedRefusesItself() {
        // `case (.ended, _)` is matched before `case (_, .ended)`, so the
        // terminal state is terminal without exception. Harmless today, because
        // an ended session is dropped from the store rather than re-signalled —
        // but worth pinning, since it is the one place the "any phase can end"
        // rule does not hold.
        #expect(SessionPhase.ended.canTransition(to: .ended) == false)
    }

    // MARK: - The edges each phase is expected to have

    @Test("A turn starting, a tool asking, and compaction all follow idle")
    func fromIdle() {
        #expect(SessionPhase.idle.canTransition(to: .processing))
        #expect(SessionPhase.idle.canTransition(to: approval()))
        #expect(SessionPhase.idle.canTransition(to: .compacting))
    }

    @Test("Processing can finish, ask, compact, or be interrupted")
    func fromProcessing() {
        #expect(SessionPhase.processing.canTransition(to: .waitingForInput))
        #expect(SessionPhase.processing.canTransition(to: approval()))
        #expect(SessionPhase.processing.canTransition(to: .compacting))
        #expect(SessionPhase.processing.canTransition(to: .idle), "an interrupt parks the session")
    }

    @Test("An approval can be granted, denied, or replaced by the next one")
    func fromWaitingForApproval() {
        #expect(approval().canTransition(to: .processing), "approved — the tool runs")
        #expect(approval().canTransition(to: .idle), "denied or cancelled")
        #expect(approval().canTransition(to: .waitingForInput), "denied, and Claude stopped")

        // Parallel tool calls queue up; the second request must be able to
        // replace the first rather than being dropped as a no-op.
        #expect(
            approval(tool: "Bash").canTransition(to: approval(tool: "Write", at: Date(timeIntervalSince1970: 1))),
            "a second pending tool must be able to take over the phase"
        )
    }

    @Test("Compaction always has a way out")
    func fromCompacting() {
        #expect(SessionPhase.compacting.canTransition(to: .processing))
        #expect(SessionPhase.compacting.canTransition(to: .idle))
        #expect(SessionPhase.compacting.canTransition(to: .waitingForInput))
    }

    @Test("A finished turn can start again, go quiet, or compact")
    func fromWaitingForInput() {
        #expect(SessionPhase.waitingForInput.canTransition(to: .processing))
        #expect(SessionPhase.waitingForInput.canTransition(to: .idle))
        #expect(SessionPhase.waitingForInput.canTransition(to: .compacting))
    }

    // MARK: - Derived properties the UI depends on

    @Test("Only the two phases a user can act on ask for attention")
    func needsAttention() {
        #expect(approval().needsAttention)
        #expect(SessionPhase.waitingForInput.needsAttention)
        #expect(!SessionPhase.idle.needsAttention)
        #expect(!SessionPhase.processing.needsAttention)
        #expect(!SessionPhase.compacting.needsAttention)
        #expect(!SessionPhase.ended.needsAttention)
    }

    @Test("Active means the notch should be showing motion")
    func isActive() {
        #expect(SessionPhase.processing.isActive)
        #expect(SessionPhase.compacting.isActive)
        #expect(!SessionPhase.idle.isActive)
        #expect(!SessionPhase.waitingForInput.isActive)
        #expect(!approval().isActive)
        #expect(!SessionPhase.ended.isActive)
    }

    @Test("An approval carries its tool name through the phase")
    func approvalExposesToolName() {
        #expect(approval(tool: "Write").approvalToolName == "Write")
        #expect(SessionPhase.processing.approvalToolName == nil)
    }

    @Test("Two approvals differing only in tool are not equal")
    func approvalEquality() {
        let at = Date(timeIntervalSince1970: 0)
        #expect(approval(tool: "Bash", at: at) != approval(tool: "Write", at: at))
        #expect(approval(tool: "Bash", at: at) == approval(tool: "Bash", at: at))
    }

    // MARK: - Documented gap

    @Test("KNOWN GAP: a fresh session cannot go straight to waitingForInput")
    func idleToWaitingForInputIsRefused() {
        // SessionStart reports status "waiting_for_input", but a session is
        // created at .idle and this edge does not exist, so the transition is
        // dropped and a newly started session reads "Idle" instead of "Ready"
        // until its first prompt. Pinned as-is so the day someone adds the edge,
        // this test is what tells them the behaviour changed on purpose.
        #expect(SessionPhase.idle.canTransition(to: .waitingForInput) == false)
    }
}
