//
//  StatusLineBridgeTests.swift
//  ClaudeIslandTests
//
//  Covers taking over and giving back settings.json's single statusLine slot.
//  The slot usually already holds something the user built, so the cases are
//  mostly about never losing it: captured on the way in, restored on the way
//  out, and left alone whenever its shape is not one we can wrap.
//

import Foundation
import Testing

@Suite("statusLine bridge")
struct StatusLineBridgeTests {

    let command = "python3 '/Users/x/.claude/hooks/claude-island-statusline.py'"

    func plan(_ settings: String?, enabled: Bool, saved: String? = nil) -> StatusLineBridge.Plan {
        StatusLineBridge.plan(
            existingData: settings.map { Data($0.utf8) },
            enabled: enabled,
            command: command,
            savedPassthrough: saved.map { Data($0.utf8) }
        )
    }

    func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func statusLine(in data: Data) -> [String: Any]? {
        object(data)?["statusLine"] as? [String: Any]
    }

    // MARK: - Opting in

    @Test("With no status line, ours is installed and there is nothing to pass through")
    func installsIntoEmptySlot() throws {
        guard case .install(let settings, let passthrough) = plan(#"{ "model": "opus" }"#, enabled: true) else {
            Issue.record("expected .install")
            return
        }
        #expect(statusLine(in: settings)?["command"] as? String == command)
        #expect(statusLine(in: settings)?["type"] as? String == "command")
        #expect(object(settings)?["model"] as? String == "opus")
        #expect(object(passthrough)?["statusLine"] == nil)
    }

    @Test("An existing status line is captured whole, and its other keys survive on ours")
    func capturesExistingStatusLine() throws {
        let existing = """
        { "statusLine": { "type": "command", "command": "~/bin/my-line.sh", "padding": 2, "refreshInterval": 5 } }
        """
        guard case .install(let settings, let passthrough) = plan(existing, enabled: true) else {
            Issue.record("expected .install")
            return
        }

        let ours = try #require(statusLine(in: settings))
        #expect(ours["command"] as? String == command)
        #expect(ours["padding"] as? Int == 2)
        #expect(ours["refreshInterval"] as? Int == 5)

        let captured = try #require(object(passthrough)?["statusLine"] as? [String: Any])
        #expect(captured["command"] as? String == "~/bin/my-line.sh")
        #expect(captured["padding"] as? Int == 2)
    }

    @Test("Re-taking an emptied slot keeps the earlier capture instead of overwriting it with nothing")
    func keepsCaptureWhenSlotWasEmptiedExternally() throws {
        let saved = #"{ "statusLine": { "type": "command", "command": "~/bin/my-line.sh" } }"#
        guard case .install(_, let passthrough) = plan(#"{ "model": "opus" }"#, enabled: true, saved: saved) else {
            Issue.record("expected .install")
            return
        }
        let captured = try #require(object(passthrough)?["statusLine"] as? [String: Any])
        #expect(captured["command"] as? String == "~/bin/my-line.sh")

        // A capture that is ours, or garbage, is not worth keeping.
        let ours = #"{ "statusLine": { "type": "command", "command": "python3 /h/claude-island-statusline.py" } }"#
        for junk in [ours, "not json"] {
            guard case .install(_, let fresh) = plan(#"{}"#, enabled: true, saved: junk) else {
                Issue.record("expected .install")
                continue
            }
            #expect(object(fresh)?["statusLine"] == nil)
        }
    }

    @Test("A missing or blank settings file is safe to create", arguments: [nil, "", "  \n"])
    func createsMissingFile(contents: String?) {
        guard case .install(let settings, _) = plan(contents, enabled: true) else {
            Issue.record("expected .install")
            return
        }
        #expect(statusLine(in: settings)?["command"] as? String == command)
    }

    @Test("Already ours with the same command is left untouched — launch writes nothing")
    func alreadyCurrentIsUnchanged() throws {
        guard case .install(let first, _) = plan(#"{ "model": "opus" }"#, enabled: true) else {
            Issue.record("expected .install")
            return
        }
        let text = String(decoding: first, as: UTF8.self)
        #expect(plan(text, enabled: true) == .unchanged)
    }

    @Test("Already ours under an old interpreter or path is refreshed without re-capturing ourselves")
    func refreshesOurOwnCommand() {
        let existing = """
        { "statusLine": { "type": "command", "command": "python '/old/hooks/claude-island-statusline.py'", "padding": 1 } }
        """
        guard case .update(let settings) = plan(existing, enabled: true) else {
            Issue.record("expected .update")
            return
        }
        #expect(statusLine(in: settings)?["command"] as? String == command)
        #expect(statusLine(in: settings)?["padding"] as? Int == 1)
    }

    @Test("A status line we cannot wrap is refused, not replaced", arguments: [
        #"{ "statusLine": "~/bin/line.sh" }"#,
        #"{ "statusLine": { "type": "command" } }"#,
        #"{ "statusLine": { "type": "static", "text": "hi" } }"#,
        #"{ "statusLine": { "type": "command", "command": "" } }"#,
    ])
    func refusesUnwrappableShapes(settings: String) {
        #expect(plan(settings, enabled: true) == .unsupported)
    }

    @Test("A settings file we cannot read is refused in both directions", arguments: [true, false])
    func refusesUnreadableSettings(enabled: Bool) {
        #expect(plan(#"{ "statusLine": "#, enabled: enabled) == .refuse)
        #expect(plan("[1, 2]", enabled: enabled) == .refuse)
    }

    // MARK: - Opting out

    @Test("Opting out restores exactly what was captured")
    func restoresCapturedStatusLine() throws {
        let existing = """
        { "model": "opus", "statusLine": { "type": "command", "command": "\(command)", "padding": 2 } }
        """
        let saved = #"{ "statusLine": { "type": "command", "command": "~/bin/my-line.sh", "padding": 2 } }"#

        guard case .remove(let settings) = plan(existing, enabled: false, saved: saved) else {
            Issue.record("expected .remove")
            return
        }
        #expect(statusLine(in: settings)?["command"] as? String == "~/bin/my-line.sh")
        #expect(object(settings)?["model"] as? String == "opus")
    }

    @Test("Opting out with nothing captured removes the key rather than leaving a dead script")
    func removesWhenNothingWasCaptured() {
        let existing = #"{ "statusLine": { "type": "command", "command": "python3 /h/claude-island-statusline.py" } }"#

        for saved in [nil, "{}", "not json", #"{ "statusLine": "bare" }"#] {
            guard case .remove(let settings) = plan(existing, enabled: false, saved: saved) else {
                Issue.record("expected .remove for saved=\(saved ?? "nil")")
                continue
            }
            #expect(object(settings)?["statusLine"] == nil)
        }
    }

    @Test("A captured status line that is somehow ours is never restored — that would be a loop")
    func neverRestoresOurselves() {
        let existing = #"{ "statusLine": { "type": "command", "command": "python3 /h/claude-island-statusline.py" } }"#
        let saved = #"{ "statusLine": { "type": "command", "command": "python3 /h/claude-island-statusline.py" } }"#

        guard case .remove(let settings) = plan(existing, enabled: false, saved: saved) else {
            Issue.record("expected .remove")
            return
        }
        #expect(object(settings)?["statusLine"] == nil)
    }

    @Test("Opting out when the slot is someone else's touches nothing", arguments: [
        #"{ "statusLine": { "type": "command", "command": "~/bin/my-line.sh" } }"#,
        #"{ "model": "opus" }"#,
        #"{ "statusLine": "odd" }"#,
    ])
    func optOutLeavesOthersAlone(settings: String) {
        #expect(plan(settings, enabled: false) == .unchanged)
    }

    @Test("Opting out with no settings file writes nothing")
    func optOutWithNoFile() {
        #expect(plan(nil, enabled: false) == .unchanged)
    }
}
