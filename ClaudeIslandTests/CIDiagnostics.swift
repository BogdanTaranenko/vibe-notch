//
//  CIDiagnostics.swift
//  ClaudeIslandTests
//
//  TEMPORARY. Finds out why resolveClaudeViaLoginShell returns nil on the CI
//  runner while passing locally. It reports its findings by recording an issue,
//  because print() from a test is swallowed by xcodebuild's formatter and the
//  xcresult is the only channel that survives to the build log. It therefore
//  always "fails" — that is the delivery mechanism, not a result.
//
//  Delete once the question is settled.
//

import Foundation
import Testing

@Suite("CI diagnostics")
struct CIDiagnostics {

    @Test("Report why the login-shell probe resolves nil")
    func reportShellProbeEnvironment() throws {
        let fm = FileManager.default
        var out: [String] = []
        func p(_ s: String) { out.append(s) }

        p("tmpdir=\(NSTemporaryDirectory())")
        p("TMPDIR-env=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "<unset>")")
        p("cpus=\(ProcessInfo.processInfo.activeProcessorCount)")

        // Build exactly what resolvesViaShell() builds.
        let binDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-notch-bin-\(UUID().uuidString)")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 9.9.9\n".write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // Hypothesis (b): isExecutableFile is false for this file on the runner.
        let attrs = try fm.attributesOfItem(atPath: binary.path)
        p("binary.exists=\(fm.fileExists(atPath: binary.path))")
        p("binary.isExecutableFile=\(fm.isExecutableFile(atPath: binary.path))")
        p("binary.perms=\(String(describing: attrs[.posixPermissions]))")
        p("binary.owner=\(String(describing: attrs[.ownerAccountName]))")
        p("binary.access(X_OK)=\(access(binary.path, X_OK) == 0)")
        p("euid=\(geteuid())")

        let stubDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-notch-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: stubDir, withIntermediateDirectories: true)
        let script = stubDir.appendingPathComponent("shell")
        try "#!/bin/sh\necho 'Last login: whenever'\necho \(binary.path)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        p("stub.isExecutableFile=\(fm.isExecutableFile(atPath: script.path))")

        // Hypothesis (a): the probe's 5s timeout expires. Run the stub here with
        // no ceiling and time it, so a slow spawn is distinguishable from a
        // parse that rejects a correct answer.
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script.path)
        process.arguments = ["-i", "-l", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        var raw = ""
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            raw = String(data: data, encoding: .utf8) ?? "<not utf8>"
            p("direct.elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            p("direct.exit=\(process.terminationStatus)")
            p("direct.output=\(raw.replacingOccurrences(of: "\n", with: "\\n"))")
        } catch {
            p("direct.RUN-THREW=\(error)")
        }

        // Does the parser accept what the shell actually said?
        p("parse(raw)=\(String(describing: HookInstaller.parseShellResolvedPath(from: raw)))")

        // And the real call, timed.
        let resolveStart = Date()
        let resolved = HookInstaller.resolveClaudeViaLoginShell(shell: script.path)
        p("resolve.elapsed=\(String(format: "%.2f", Date().timeIntervalSince(resolveStart)))s")
        p("resolve.result=\(String(describing: resolved))")
        p("resolve.expected=\(binary.path)")

        Issue.record(Comment(rawValue: "CIDIAG " + out.joined(separator: " | ")))
    }
}
