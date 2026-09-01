//
//  ClaudeBinaryResolutionTests.swift
//  ClaudeIslandTests
//
//  Covers locating the `claude` binary. Getting this wrong is silent: detection
//  returns nil, we fall back to the baseline hook set, and the user simply never
//  receives the newer events.
//

import Foundation
import Testing

@Suite("Locating the claude binary")
struct ClaudeBinaryResolutionTests {

    /// Stands in for the filesystem so path parsing can be checked without one.
    let anyClaudeBinary: (String) -> Bool = { $0.hasSuffix("/claude") }

    // MARK: - Reading `command -v` output

    @Test("A bare path is taken as-is")
    func plainAnswer() {
        let out = "/Users/x/.nvm/versions/node/v22.3.0/bin/claude\n"
        #expect(
            HookInstaller.parseShellResolvedPath(from: out, isExecutable: anyClaudeBinary)
                == "/Users/x/.nvm/versions/node/v22.3.0/bin/claude"
        )
    }

    @Test("Login banners and motd noise are ignored")
    func ignoresBanner() {
        let out = """
        Last login: Mon Sep  1 09:14:22 on ttys003
        You have new mail.
        /Users/x/.volta/bin/claude
        """
        #expect(
            HookInstaller.parseShellResolvedPath(from: out, isExecutable: anyClaudeBinary)
                == "/Users/x/.volta/bin/claude"
        )
    }

    @Test("Answers that are not executable paths are rejected", arguments: [
        "claude\n",                                  // a shell function or builtin
        "claude: aliased to claude --verbose\n",     // an alias
        "/opt/nope/claude-notes\n",                  // a path, but not our binary
        "",                                          // nothing at all
        "   \n\n  \n",                               // whitespace
    ])
    func rejectsNonPaths(output: String) {
        #expect(HookInstaller.parseShellResolvedPath(from: output, isExecutable: anyClaudeBinary) == nil)
    }

    @Test("When a shell echoes more than one path, the last one wins")
    func lastPathWins() {
        let out = "/old/claude\n/new/claude\n"
        #expect(HookInstaller.parseShellResolvedPath(from: out, isExecutable: anyClaudeBinary) == "/new/claude")
    }

    // MARK: - Reading `claude --version` output

    @Test("Version output is parsed from any surrounding text", arguments: [
        ("2.1.88", HookInstaller.ClaudeCodeVersion(major: 2, minor: 1, patch: 88)),
        ("v2.1.88", HookInstaller.ClaudeCodeVersion(major: 2, minor: 1, patch: 88)),
        ("2.1.88 (Claude Code)", HookInstaller.ClaudeCodeVersion(major: 2, minor: 1, patch: 88)),
        ("claude 10.0.3 (something)", HookInstaller.ClaudeCodeVersion(major: 10, minor: 0, patch: 3)),
    ])
    func parsesVersion(text: String, expected: HookInstaller.ClaudeCodeVersion) {
        #expect(HookInstaller.parseClaudeCodeVersion(from: text) == expected)
    }

    @Test("Unparseable version output yields nil, not a guess", arguments: [
        "not a version", "", "2.1", "vNext",
    ])
    func rejectsNonVersions(text: String) {
        #expect(HookInstaller.parseClaudeCodeVersion(from: text) == nil)
    }

    // MARK: - Driving a real (stub) login shell

    /// Writes an executable stub shell and hands back its path.
    private func stubShell(_ body: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-notch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let script = dir.appendingPathComponent("shell")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test("A shell that answers with a real path resolves it")
    func resolvesViaShell() throws {
        // A binary somewhere none of the fixed candidates would ever look.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-notch-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 9.9.9\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let shell = try stubShell("echo 'Last login: whenever'\necho \(binary.path)")
        #expect(HookInstaller.resolveClaudeViaLoginShell(shell: shell) == binary.path)
    }

    @Test("A shell that cannot find claude yields nil")
    func shellWithoutClaude() throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-notch-ran-\(UUID().uuidString)")
        let shell = try stubShell("touch '\(marker.path)'\nexit 1")
        #expect(HookInstaller.resolveClaudeViaLoginShell(shell: shell) == nil)
        // The marker is what makes this test mean anything: asserting nil alone
        // passes just as well when the probe never ran the shell at all, which
        // is exactly how a CI-only regression hid here.
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("A shell that floods stdout still resolves and does not deadlock")
    func survivesChattyShell() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-notch-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 9.9.9\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // Enough output to fill the pipe buffer many times over. Waiting for exit
        // before draining stdout would hang here forever.
        let shell = try stubShell("yes 'noise noise noise noise' | head -200000\necho \(binary.path)")
        #expect(HookInstaller.resolveClaudeViaLoginShell(shell: shell) == binary.path)
    }

    @Test("A shell that never returns is abandoned rather than blocking launch", .timeLimit(.minutes(1)))
    func survivesHangingShell() throws {
        let shell = try stubShell("sleep 120")
        let start = Date()
        #expect(HookInstaller.resolveClaudeViaLoginShell(shell: shell) == nil)
        let elapsed = Date().timeIntervalSince(start)
        // The probe runs during applicationDidFinishLaunching, so an unbounded
        // wait would be a beachball on every launch.
        #expect(elapsed < 30)
        // And a lower bound, for the same reason as the marker above: returning
        // nil immediately -- because the shell never launched -- would satisfy
        // the upper bound perfectly. This shell cannot exit on its own, so
        // anything near the 5s ceiling proves the timeout is what ended it.
        #expect(elapsed >= 4)
    }

    @Test("A shell path that is not executable is not launched")
    func rejectsBadShell() {
        #expect(HookInstaller.resolveClaudeViaLoginShell(shell: "/nope/not/a/shell") == nil)
    }
}
