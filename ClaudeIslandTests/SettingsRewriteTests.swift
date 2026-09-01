//
//  SettingsRewriteTests.swift
//  ClaudeIslandTests
//
//  Covers HookInstaller's settings.json rewrite — the one thing this app does
//  that can destroy something the user cannot get back.
//

import Foundation
import Testing

@Suite("settings.json rewrite")
struct SettingsRewriteTests {

    // A command line shaped like the real one, and a version new enough to
    // unlock every gated hook event.
    let command = "python3 '/Users/x/.claude/hooks/claude-island-state.py'"
    let version = HookInstaller.ClaudeCodeVersion(major: 2, minor: 1, patch: 88)

    func plan(_ text: String?) -> HookInstaller.SettingsPlan {
        HookInstaller.planSettingsUpdate(
            existingData: text.map { Data($0.utf8) },
            command: command,
            version: version
        )
    }

    /// The object a `.write` plan would put on disk, or nil for any other plan.
    func written(_ plan: HookInstaller.SettingsPlan) -> [String: Any]? {
        guard case .write(let data) = plan else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Refusing to destroy what we cannot read

    @Test("A file we cannot read back as an object is left alone", arguments: [
        #"{ "model": "opu"#,        // truncated — a save caught mid-flight
        #"[1, 2, 3]"#,              // top-level array
        #""hello""#,                // top-level string
        #"42"#,                     // top-level number
    ])
    func refusesUnreadableSettings(contents: String) {
        #expect(plan(contents) == .refuse)
    }

    @Test("Bytes that are not valid UTF-8 are refused, not mistaken for blank")
    func refusesNonUTF8() {
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
        let result = HookInstaller.planSettingsUpdate(
            existingData: garbage,
            command: command,
            version: version
        )
        #expect(result == .refuse)
    }

    @Test("JSONSerialization tolerates trailing commas, so we must preserve the file")
    func toleratesTrailingComma() {
        // Pinned deliberately: if Foundation ever tightens this, the refusal set
        // changes and this test is how we find out.
        #expect(written(plan(#"{ "model": "opus", }"#))?["model"] as? String == "opus")
    }

    // MARK: - Filling in a file that genuinely has nothing to lose

    @Test("A missing file is created")
    func createsMissingFile() {
        #expect(written(plan(nil))?["hooks"] != nil)
    }

    @Test("An empty or whitespace-only file is safe to fill in", arguments: ["", "   \n\t \n"])
    func fillsBlankFile(contents: String) {
        #expect(written(plan(contents))?["hooks"] != nil)
    }

    // MARK: - Preserving everything that is not ours

    @Test("Unrelated top-level keys survive the rewrite")
    func preservesUnrelatedKeys() throws {
        let existing = """
        {
          "model": "opus",
          "env": { "FOO": "bar" },
          "permissions": { "allow": ["Bash(git status:*)"] },
          "statusLine": { "type": "command", "command": "mystatus" }
        }
        """
        let json = try #require(written(plan(existing)))

        #expect(json["model"] as? String == "opus")
        #expect((json["env"] as? [String: Any])?["FOO"] as? String == "bar")
        #expect(json["permissions"] != nil)
        #expect(json["statusLine"] != nil)
        #expect((json["hooks"] as? [String: Any])?["PreToolUse"] != nil)
    }

    @Test("A hook the user configured themselves is kept alongside ours")
    func preservesForeignHooks() throws {
        let existing = """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [{ "type": "command", "command": "my-own-linter" }] }
            ]
          }
        }
        """
        let json = try #require(written(plan(existing)))
        let entries = try #require((json["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])

        let keptTheirs = entries.contains { entry in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.contains { ($0["command"] as? String) == "my-own-linter" }
        }
        #expect(keptTheirs)
        #expect(entries.count == 2, "theirs plus ours")
    }

    // MARK: - Idempotency

    @Test("Running twice writes once and does not duplicate entries")
    func isIdempotent() throws {
        guard case .write(let first) = plan(#"{ "model": "opus" }"#) else {
            Issue.record("first run should write")
            return
        }

        let second = HookInstaller.planSettingsUpdate(
            existingData: first,
            command: command,
            version: version
        )
        #expect(second == .alreadyCurrent, "installIfNeeded runs on every launch")

        let json = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolUse.count == 1, "entries must not accumulate across launches")
    }

    // MARK: - Version gating (issue #85)

    @Test("Without a detected version we register only the baseline events")
    func undetectedVersionUsesBaseline() throws {
        let json = try #require(written(
            HookInstaller.planSettingsUpdate(existingData: nil, command: command, version: nil)
        ))
        let hooks = try #require(json["hooks"] as? [String: Any])

        // Claude Code rejects unknown hook keys outright, so guessing high
        // bricks settings.json for anyone on an older version.
        #expect(hooks["PermissionDenied"] == nil)
        #expect(hooks["StopFailure"] == nil)
        #expect(hooks["PreToolUse"] != nil, "baseline events still register")
        #expect(hooks["Stop"] != nil)
    }

    @Test("A recent version unlocks the newer events")
    func recentVersionUnlocksNewEvents() throws {
        let json = try #require(written(plan(nil)))
        let hooks = try #require(json["hooks"] as? [String: Any])

        #expect(hooks["PermissionDenied"] != nil)
        #expect(hooks["StopFailure"] != nil)
        #expect(hooks["PostCompact"] != nil)
        #expect(hooks["SubagentStart"] != nil)
    }

    @Test("Each gated event appears only at or above its version", arguments: [
        (HookInstaller.ClaudeCodeVersion(major: 1, minor: 9, patch: 0), false, false),
        (HookInstaller.ClaudeCodeVersion(major: 2, minor: 0, patch: 0), true, false),
        (HookInstaller.ClaudeCodeVersion(major: 2, minor: 1, patch: 88), true, true),
    ])
    func gatesEventsByVersion(
        version: HookInstaller.ClaudeCodeVersion,
        expectsPostToolUseFailure: Bool,
        expectsPermissionDenied: Bool
    ) throws {
        let json = try #require(written(
            HookInstaller.planSettingsUpdate(existingData: nil, command: command, version: version)
        ))
        let hooks = try #require(json["hooks"] as? [String: Any])

        #expect((hooks["PostToolUseFailure"] != nil) == expectsPostToolUseFailure)
        #expect((hooks["PermissionDenied"] != nil) == expectsPermissionDenied)
    }

    @Test("A stale hook key from an older install is stripped before we re-add")
    func stripsStaleEntries() throws {
        // The shape that broke settings.json in issue #85: our hook sitting on an
        // event key the installed Claude Code no longer accepts.
        let existing = """
        {
          "hooks": {
            "PermissionDenied": [
              { "matcher": "*", "hooks": [{ "type": "command", "command": "python3 '/x/claude-island-state.py'" }] }
            ]
          }
        }
        """
        let json = try #require(written(
            HookInstaller.planSettingsUpdate(existingData: Data(existing.utf8), command: command, version: nil)
        ))
        let hooks = try #require(json["hooks"] as? [String: Any])
        #expect(hooks["PermissionDenied"] == nil, "our stale entry is removed, not left behind")
    }
}
