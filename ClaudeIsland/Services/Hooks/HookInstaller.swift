//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "Hooks")

/// Result of an install attempt. `settingsUnreadable` is the one the settings
/// panel surfaces: it means the user's settings.json is in a state we refuse to
/// overwrite, so hooks are *not* installed until they fix it.
enum HookInstallOutcome: Equatable, Sendable {
    /// settings.json was rewritten with our hook entries.
    case installed
    /// settings.json already held exactly the entries we wanted; nothing written.
    case alreadyCurrent
    /// settings.json exists but could not be read as a JSON object. Left untouched.
    case settingsUnreadable
    /// The write itself failed. settings.json is unchanged (the write is atomic).
    case writeFailed(String)
}

struct HookInstaller {

    /// Install hook script and update settings.json on app launch
    @discardableResult
    static func installIfNeeded() -> HookInstallOutcome {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        let outcome = updateSettings(at: ClaudePaths.settingsFile)
        setLastOutcome(outcome)
        return outcome
    }

    // MARK: - settings.json Rewrite

    /// What `updateSettings` decided to do, given the bytes currently on disk.
    /// Kept separate from the file IO so it can be exercised without a real
    /// ~/.claude — rewriting settings.json is the one thing this app does that
    /// can destroy something the user cannot get back.
    enum SettingsPlan: Equatable {
        case write(Data)
        case alreadyCurrent
        case refuse
    }

    private static func updateSettings(at settingsURL: URL) -> HookInstallOutcome {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: settingsURL.path)
        let existingData: Data? = exists ? try? Data(contentsOf: settingsURL) : nil

        // Present but unreadable (permissions, or a read that raced a save in
        // progress). Refuse for the same reason a parse failure refuses: we have
        // no idea what we would be replacing.
        if exists && existingData == nil {
            logger.error("settings.json exists but could not be read — leaving it alone")
            return .settingsUnreadable
        }

        let version = detectClaudeCodeVersion()
        setLastDetectedVersion(version)

        let plan = planSettingsUpdate(
            existingData: existingData,
            command: "\(detectPython()) \(ClaudePaths.hookScriptShellPath)",
            version: version
        )

        switch plan {
        case .refuse:
            logger.error("settings.json is not a JSON object — refusing to overwrite it")
            return .settingsUnreadable

        case .alreadyCurrent:
            logger.debug("settings.json already current — no write")
            return .alreadyCurrent

        case .write(let data):
            if let existingData {
                backUpSettings(existingData, at: settingsURL)
            }
            do {
                try data.write(to: settingsURL, options: .atomic)
                logger.info("Installed hooks into settings.json")
                return .installed
            } catch {
                logger.error("Failed to write settings.json: \(error.localizedDescription, privacy: .public)")
                return .writeFailed(error.localizedDescription)
            }
        }
    }

    /// Build the settings.json we want, or refuse.
    ///
    /// - Parameter existingData: current file contents, or nil when the file
    ///   does not exist yet (the only case where starting from `{}` is correct).
    static func planSettingsUpdate(
        existingData: Data?,
        command: String,
        version: ClaudeCodeVersion?
    ) -> SettingsPlan {
        var json: [String: Any] = [:]

        if let existingData, !isBlank(existingData) {
            // A half-written save caught mid-flight, a top-level array, binary
            // garbage — anything we can't read back as an object. (Trailing
            // commas are fine; JSONSerialization tolerates them.) Defaulting to
            // an empty dictionary here would write our hooks over the user's
            // permissions, model, env, statusLine and MCP config with no warning
            // and no way back, so we write nothing at all instead.
            guard let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                return .refuse
            }
            json = parsed
        }

        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Strip any existing Claude Island hooks from ALL event types first — even
        // events we no longer register. Fixes users who installed v1.3 on an older
        // Claude Code and now have invalid keys like PermissionDenied sitting in
        // their settings.json (issue #85).
        var cleanedHooks: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let cleaned = entries.compactMap { removingClaudeIslandHooks(from: $0) }
                if !cleaned.isEmpty {
                    cleanedHooks[event] = cleaned
                }
            } else {
                cleanedHooks[event] = value
            }
        }
        hooks = cleanedHooks

        // Register only hooks the installed Claude Code version supports.
        // When detection fails, fall back to the baseline set that every
        // Claude Code version has supported (no new v1.3+ hooks).
        let hookEvents = supportedHookEvents(
            for: version,
            withMatcher: withMatcher,
            withMatcherAndTimeout: withMatcherAndTimeout,
            withoutMatcher: withoutMatcher,
            preCompactConfig: preCompactConfig
        )

        for (event, config) in hookEvents {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + config
        }

        json["hooks"] = hooks

        guard let newData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return .refuse
        }

        // installIfNeeded() runs on every launch. Once we are the last writer the
        // file is already in this exact canonical form, so the common case is to
        // touch nothing — which also keeps the risk window as small as possible.
        if newData == existingData {
            return .alreadyCurrent
        }

        return .write(newData)
    }

    /// True for an empty or whitespace-only file, which is safe to treat as `{}`.
    /// Bytes that aren't valid UTF-8 are not blank — they fall through to the
    /// parse, and the parse refuses.
    private static func isBlank(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Backups

    private static let backupPrefix = "settings.json.vibenotch-"
    private static let backupSuffix = ".bak"

    /// How many of our own backups to keep beside settings.json.
    private static let maxBackups = 5

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var hasBackedUpThisRun = false
    nonisolated(unsafe) private static var _lastOutcome: HookInstallOutcome?
    nonisolated(unsafe) private static var _lastDetectedVersion: ClaudeCodeVersion?

    /// Result of the most recent install attempt, for the settings panel.
    static var lastOutcome: HookInstallOutcome? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastOutcome
    }

    /// The Claude Code version the last install used to decide which hook
    /// events to register. Reported by the health panel rather than a fresh
    /// probe, so what it shows is what the registration is actually based on.
    static var lastDetectedVersion: ClaudeCodeVersion? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastDetectedVersion
    }

    private static func setLastOutcome(_ outcome: HookInstallOutcome) {
        stateLock.lock()
        _lastOutcome = outcome
        stateLock.unlock()
    }

    private static func setLastDetectedVersion(_ version: ClaudeCodeVersion?) {
        stateLock.lock()
        _lastDetectedVersion = version
        stateLock.unlock()
    }

    /// Copy settings.json aside before the first write of each app run. Written
    /// from the bytes we already read rather than re-reading the file, so the
    /// backup is exactly what the write is about to replace.
    private static func backUpSettings(_ data: Data, at settingsURL: URL) {
        stateLock.lock()
        let alreadyBackedUp = hasBackedUpThisRun
        hasBackedUpThisRun = true
        stateLock.unlock()
        guard !alreadyBackedUp else { return }

        let directory = settingsURL.deletingLastPathComponent()
        let name = backupPrefix + backupTimestampFormatter.string(from: Date()) + backupSuffix
        let backupURL = directory.appendingPathComponent(name)

        do {
            try data.write(to: backupURL, options: .atomic)
            logger.info("Backed up settings.json to \(name, privacy: .public)")
        } catch {
            logger.error("Failed to back up settings.json: \(error.localizedDescription, privacy: .public)")
            return
        }

        pruneBackups(in: directory)
    }

    /// Trim our own backups to the newest `maxBackups`. Only ever removes files
    /// matching both our prefix and suffix — nothing else in the Claude
    /// directory is a candidate. The timestamp format sorts lexicographically.
    private static func pruneBackups(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        let ours = names
            .filter { $0.hasPrefix(backupPrefix) && $0.hasSuffix(backupSuffix) }
            .sorted()

        guard ours.count > maxBackups else { return }

        for name in ours.dropLast(maxBackups) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Claude Code Version Detection

    /// Simple semantic version used to gate which hook events we register.
    /// Claude Code rejects unknown hook keys, so we must only register
    /// events the installed version knows about.
    struct ClaudeCodeVersion: Comparable, CustomStringConvertible {
        let major: Int
        let minor: Int
        let patch: Int

        var description: String { "\(major).\(minor).\(patch)" }

        static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// Runs `claude --version` and parses the result. Returns nil on any
    /// failure (binary not found, non-zero exit, timeout, unparseable output),
    /// which lands us on the baseline hook set — the safe direction to fail.
    static func detectClaudeCodeVersion() -> ClaudeCodeVersion? {
        guard let claudePath = resolveClaudeBinary() else {
            logger.info("Could not locate the claude binary — registering baseline hooks only")
            return nil
        }

        guard let output = runCapturingOutput(
            executable: claudePath,
            arguments: ["--version"],
            timeout: 10
        ) else {
            return nil
        }

        let version = parseClaudeCodeVersion(from: output)
        if let version {
            logger.info("Detected Claude Code \(version.major).\(version.minor).\(version.patch) at \(claudePath, privacy: .public)")
        }
        return version
    }

    // MARK: - Locating the claude Binary

    private static let resolvedBinaryKey = "claudeBinaryPath"
    private static let failedProbeKey = "claudeBinaryProbeFailedAt"

    /// How long to leave the login shell alone after it fails to find `claude`.
    /// Probing costs a shell startup on the launch path, and the answer does not
    /// usually change between two launches a minute apart.
    private static let failedProbeCooldown: TimeInterval = 24 * 60 * 60

    /// Where we last found the `claude` binary, without probing for it. Nil
    /// when nothing has been resolved, or when the remembered path has since
    /// stopped being executable.
    static var resolvedBinaryPath: String? {
        guard let remembered = UserDefaults.standard.string(forKey: resolvedBinaryKey),
              FileManager.default.isExecutableFile(atPath: remembered) else {
            return nil
        }
        return remembered
    }

    /// Drop everything we remember about where `claude` lives, so the next
    /// resolution starts from scratch. The Hooks toggle calls this, which makes
    /// flipping it off and on a genuine retry after installing Claude Code.
    static func forgetResolvedBinary() {
        UserDefaults.standard.removeObject(forKey: resolvedBinaryKey)
        UserDefaults.standard.removeObject(forKey: failedProbeKey)
    }

    /// Well-known install locations, cheap to stat and checked before we pay for
    /// a shell. Deliberately does not cover version managers — nvm, fnm, volta,
    /// mise and bun all put `claude` on a path that only the user's shell knows.
    private static var fixedCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            // The local install lives under the Claude config dir, wherever the
            // user has actually put it — never assume ~/.claude.
            ClaudePaths.claudeDir.appendingPathComponent("local/claude").path,
            home + "/.local/bin/claude",
            home + "/.bun/bin/claude",
            "/opt/local/bin/claude",
            "/usr/bin/claude",
        ]
    }

    /// Find the `claude` executable: remembered path, then well-known
    /// locations, then the user's own login shell.
    static func resolveClaudeBinary() -> String? {
        let fm = FileManager.default

        // A path we resolved on an earlier launch. Costs one stat, and saves the
        // shell round-trip for everyone whose install has not moved.
        if let remembered = UserDefaults.standard.string(forKey: resolvedBinaryKey),
           fm.isExecutableFile(atPath: remembered) {
            return remembered
        }

        if let known = fixedCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            UserDefaults.standard.set(known, forKey: resolvedBinaryKey)
            return known
        }

        UserDefaults.standard.removeObject(forKey: resolvedBinaryKey)

        // Nothing in the usual places. The remaining installs — an npm global
        // under a version manager, most commonly — are only on the PATH that the
        // user's shell builds, and a GUI app inherits none of it. Ask the shell.
        guard let resolved = resolveClaudeViaLoginShellIfAllowed() else {
            return nil
        }

        UserDefaults.standard.set(resolved, forKey: resolvedBinaryKey)
        return resolved
    }

    /// The login-shell probe behind its cooldown.
    ///
    /// This runs on the launch path, and someone's login shell can be slow or
    /// hang outright, so one failure buys quiet until the cooldown expires
    /// rather than costing every subsequent launch the same stall. The Hooks
    /// toggle clears it via `forgetResolvedBinary()`.
    static func resolveClaudeViaLoginShellIfAllowed() -> String? {
        if let lastFailure = UserDefaults.standard.object(forKey: failedProbeKey) as? Date,
           Date().timeIntervalSince(lastFailure) < failedProbeCooldown {
            logger.debug("Skipping shell probe — the last one failed recently")
            return nil
        }

        guard let resolved = resolveClaudeViaLoginShell() else {
            UserDefaults.standard.set(Date(), forKey: failedProbeKey)
            return nil
        }

        UserDefaults.standard.removeObject(forKey: failedProbeKey)
        return resolved
    }

    /// Internal, and takes the shell as a parameter, so it can be exercised
    /// against a stub — launching someone else's login shell is the riskiest
    /// thing in this file. Tests pass a path rather than setting `SHELL`, which
    /// is process-global and would not survive parallel execution.
    static func resolveClaudeViaLoginShell(
        shell: String = Foundation.ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        // -i as well as -l: zsh reads nvm/fnm/mise setup from .zshrc, which a
        // non-interactive login shell skips entirely. Interactive shells can
        // print banners and prompts, hence the defensive parse below, and can
        // hang outright, hence the timeout.
        guard let output = runCapturingOutput(
            executable: shell,
            arguments: ["-i", "-l", "-c", "command -v claude"],
            timeout: 5
        ) else {
            return nil
        }

        let path = parseShellResolvedPath(from: output)
        if let path {
            logger.info("Resolved claude via \(shell, privacy: .public): \(path, privacy: .public)")
        }
        return path
    }

    /// Pull an executable path out of `command -v` output.
    ///
    /// An interactive shell may emit banners, prompt escapes or motd noise
    /// alongside the answer, and `command -v` returns a bare name for a shell
    /// function or alias. So: take the last line that is an absolute path we can
    /// actually execute, and ignore everything else.
    static func parseShellResolvedPath(
        from output: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && isExecutable($0) }
    }

    /// Run a command and return stdout, or nil if it fails or outlives
    /// `timeout`. HookInstaller runs before the async machinery is up and on the
    /// launch path, so nothing here may block indefinitely.
    private static func runCapturingOutput(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // An interactive shell that finds a terminal on stdin may wait for input.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.debug("Failed to launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Read on a background queue: a child that fills the pipe buffer blocks
        // until it is drained, so waiting for exit first can deadlock.
        var output = Data()
        let reader = DispatchQueue(label: "com.claudeisland.hookinstaller.read")
        let finishedReading = DispatchSemaphore(value: 0)
        reader.async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            finishedReading.signal()
        }

        let deadline = DispatchTime.now() + timeout
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }

        if exited.wait(timeout: deadline) == .timedOut {
            logger.warning("\(executable, privacy: .public) exceeded \(Int(timeout))s — terminating")
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = finishedReading.wait(timeout: .now() + 2)
            return nil
        }

        _ = finishedReading.wait(timeout: .now() + 2)

        guard process.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }

    /// Extracts the first `X.Y.Z` token from arbitrary version output.
    /// Accepts any prefix/suffix — works for "2.1.88", "v2.1.88", "claude 2.1.88 (...)" etc.
    static func parseClaudeCodeVersion(from text: String) -> ClaudeCodeVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let patchRange = Range(match.range(at: 3), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]),
              let patch = Int(text[patchRange])
        else { return nil }
        return ClaudeCodeVersion(major: major, minor: minor, patch: patch)
    }

    /// Returns the ordered list of (event, config) pairs to register, filtered
    /// to only events the installed Claude Code version knows about.
    private static func supportedHookEvents(
        for version: ClaudeCodeVersion?,
        withMatcher: [[String: Any]],
        withMatcherAndTimeout: [[String: Any]],
        withoutMatcher: [[String: Any]],
        preCompactConfig: [[String: Any]]
    ) -> [(String, [[String: Any]])] {
        // Baseline — present in every Claude Code version that supports hooks
        var events: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        // Without a detected version, stick to the baseline — better to miss
        // features than to break settings.json on older Claude Code (#85).
        guard let version else { return events }

        // v2.0.x — PostToolUseFailure shipped alongside the PostToolUse redesign
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 0) {
            events.append(("PostToolUseFailure", withMatcher))
        }
        // v2.0.43 — SubagentStart, pairs with SubagentStop
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 43) {
            events.append(("SubagentStart", withoutMatcher))
        }
        // v2.1.76 — PostCompact, pairs with PreCompact
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 76) {
            events.append(("PostCompact", preCompactConfig))
        }
        // v2.1.78 — StopFailure on API errors (rate limit, auth, billing)
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 78) {
            events.append(("StopFailure", withoutMatcher))
        }
        // v2.1.88 — PermissionDenied for auto-mode classifier denials
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 88) {
            events.append(("PermissionDenied", withMatcher))
        }

        return events
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        installedHookCommand() != nil
    }

    /// The command line settings.json currently runs for our hooks, read back
    /// from disk. This is the registration as Claude Code will actually see it,
    /// not what we intended to write.
    static func installedHookCommand() -> String? {
        guard let data = try? Data(contentsOf: ClaudePaths.settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return hookCommand(in: json)
    }

    /// First Vibe Notch hook command anywhere in a parsed settings.json.
    ///
    /// Deliberately tolerant: settings.json is the user's file and may hold any
    /// shape at any key. Anything unrecognised is skipped rather than assumed.
    nonisolated static func hookCommand(in json: [String: Any]) -> String? {
        guard let hooks = json["hooks"] as? [String: Any] else { return nil }

        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in entryHooks {
                    if let command = hook["command"] as? String, isClaudeIslandHook(hook) {
                        return command
                    }
                }
            }
        }
        return nil
    }

    /// The interpreter a hook command runs. The script path that follows it is
    /// shell-quoted and may contain spaces, so only the first word is ours.
    nonisolated static func interpreter(in command: String) -> String? {
        command.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
    }

    /// Directories searched for a bare interpreter name.
    ///
    /// Spelled out rather than shelled out for: a GUI app inherits a minimal
    /// PATH, so `which` would search roughly this list anyway, and doing it
    /// with `stat` keeps the health check off the Process path entirely.
    static let executableSearchPaths = [
        "/usr/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/bin",
        "/opt/local/bin",
    ]

    /// Where an interpreter resolves for *this* app, or nil when it does not
    /// resolve at all.
    ///
    /// Worth stating plainly: the hook itself runs from Claude Code's
    /// environment, not ours, so a name that resolves here is evidence and not
    /// proof. A name that resolves nowhere on this machine is the useful case.
    nonisolated static func resolveExecutable(
        _ name: String,
        searchPaths: [String] = executableSearchPaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard !name.isEmpty else { return nil }

        // Anything with a slash is a path already, relative or absolute, and
        // must not be looked up as a bare name.
        if name.contains("/") {
            return isExecutable(name) ? name : nil
        }

        return searchPaths
            .map { $0.hasSuffix("/") ? $0 + name : $0 + "/" + name }
            .first(where: isExecutable)
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = ClaudePaths.settingsFile

        try? FileManager.default.removeItem(at: pythonScript)

        guard let originalData = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries = entries.compactMap { removingClaudeIslandHooks(from: $0) }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            backUpSettings(originalData, at: settings)
            try? data.write(to: settings, options: .atomic)
        }
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    nonisolated private static func removingClaudeIslandHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll(where: isClaudeIslandHook)
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    nonisolated private static func isClaudeIslandHook(_ hook: [String: Any]) -> Bool {
        let cmd = hook["command"] as? String ?? ""
        return cmd.contains("claude-island-state.py")
    }
}
