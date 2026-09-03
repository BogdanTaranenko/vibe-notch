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
        #expect(SessionPhase.idle.canTransition(to: .waitingForInput), "SessionStart lands on a session created at .idle")
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

    // MARK: - Regressions

    @Test("A fresh session can report waitingForInput straight away")
    func idleToWaitingForInputIsAllowed() {
        // SessionStart reports status "waiting_for_input" and a session is
        // created at .idle, so without this edge the very first event of a
        // session is dropped and the notch reads "Idle" instead of "Ready"
        // until the first prompt lands. See claude-island-state.py's
        // SessionStart branch and SessionStore.createSession.
        #expect(SessionPhase.idle.canTransition(to: .waitingForInput))
    }
}

//
//  Event entitlement
//
//  `canTransition(to:)` guards the shape of the machine; `admits(_:from:)`
//  guards who is allowed to drive it. Both edges exercised below are legal —
//  that is the whole problem, and why the state machine alone cannot catch it.
//

@Suite("Which events may drive a phase change")
struct PhaseAdmissionTests {

    func approval(tool: String = "Bash") -> SessionPhase {
        .waitingForApproval(PermissionContext(
            toolUseId: "toolu_01",
            toolName: tool,
            toolInput: nil,
            receivedAt: Date(timeIntervalSince1970: 0)
        ))
    }

    // MARK: - The turn is over

    /// The reported bug: the notch shows the finished check, then flips back to
    /// the working spinner and stays there.
    ///
    /// Measured against Claude Code 2.1.259: a subagent that outlives the main
    /// agent's message goes on firing `PreToolUse` on the *parent* session id
    /// (145 ms after `Stop` in the capture), and its `SubagentStop` lands
    /// seconds later still. Both map to `.processing`.
    @Test("A subagent outliving the turn cannot reopen it", arguments: [
        "PreToolUse", "SubagentStart", "SubagentStop", "PostCompact", "PermissionDenied",
    ])
    func lateTurnEventsCannotResumeAFinishedTurn(event: String) {
        #expect(
            SessionPhase.waitingForInput.admits(.processing, from: event) == false,
            "\(event) after Stop must not drag the notch back to processing"
        )
    }

    @Test("A new prompt does reopen it")
    func aPromptStartsAnotherTurn() {
        #expect(SessionPhase.waitingForInput.admits(.processing, from: "UserPromptSubmit"))
    }

    /// Claude Code injects a finished background task as a fresh prompt, which
    /// is why the gate keys on the event and not on whether a human typed.
    @Test("Every turn-starting event is one the gate lets through")
    func turnStartingEventsAreAdmitted() {
        for event in SessionPhase.turnStartingEvents {
            #expect(
                SessionPhase.waitingForInput.admits(.processing, from: event),
                "\(event) starts a turn and must be admitted"
            )
        }
    }

    /// Only the `.processing` edge is closed. A subagent still running after the
    /// turn ended can genuinely need an answer, and a permission prompt the user
    /// never sees is a worse failure than a wrong spinner.
    @Test("A finished turn still admits phases that are true when they arrive")
    func finishedTurnStillAdmitsItsOwnTruths() {
        #expect(SessionPhase.waitingForInput.admits(approval(), from: "PermissionRequest"))
        #expect(SessionPhase.waitingForInput.admits(.compacting, from: "PreCompact"))
        #expect(SessionPhase.waitingForInput.admits(.ended, from: "SessionEnd"))
        #expect(SessionPhase.waitingForInput.admits(.idle, from: "Notification"))
    }

    // MARK: - Tool completion

    /// PostToolUse says a tool finished, never that the turn did. It arrives
    /// after the `Stop` that ended the turn (a backgrounded Bash reports ~1 s
    /// late) and after an interrupt has already parked the session.
    @Test("PostToolUse never drives anything but the approval recovery")
    func postToolUseIsInert() {
        for event in ["PostToolUse", "PostToolUseFailure"] {
            #expect(SessionPhase.waitingForInput.admits(.processing, from: event) == false)
            #expect(SessionPhase.idle.admits(.processing, from: event) == false)
            #expect(SessionPhase.processing.admits(.processing, from: event) == false)
        }
    }

    /// The one thing it may still do: report a permission the user answered in
    /// the terminal, whose decision never comes back through our socket.
    @Test("PostToolUse still recovers a permission answered in the terminal")
    func postToolUseRecoversFromApproval() {
        for event in ["PostToolUse", "PostToolUseFailure"] {
            #expect(approval().admits(.processing, from: event))
        }
    }

    // MARK: - Everything else is untouched

    @Test("A working turn is driven normally")
    func normalTurnIsUnaffected() {
        #expect(SessionPhase.processing.admits(approval(), from: "PermissionRequest"))
        #expect(SessionPhase.processing.admits(.waitingForInput, from: "Stop"))
        #expect(SessionPhase.processing.admits(.processing, from: "PreToolUse"))
        #expect(SessionPhase.idle.admits(.processing, from: "PreToolUse"))
        #expect(approval().admits(.processing, from: "UserPromptSubmit"))
        #expect(SessionPhase.compacting.admits(.processing, from: "PostCompact"))
    }

    /// A session first seen mid-turn is created at `.idle`, so closing that edge
    /// too would strand the app on a session it joined late.
    @Test("A session joined mid-turn still reaches processing")
    func idleIsNotGated() {
        for event in ["PreToolUse", "SubagentStart", "SubagentStop", "PostCompact"] {
            #expect(
                SessionPhase.idle.admits(.processing, from: event),
                "\(event) must still start an idle session"
            )
        }
    }
}
