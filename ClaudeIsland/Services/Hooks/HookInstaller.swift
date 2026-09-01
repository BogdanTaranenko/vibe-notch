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

        let plan = planSettingsUpdate(
            existingData: existingData,
            command: "\(detectPython()) \(ClaudePaths.hookScriptShellPath)",
            version: detectClaudeCodeVersion()
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

    /// Result of the most recent install attempt, for the settings panel.
    static var lastOutcome: HookInstallOutcome? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastOutcome
    }

    private static func setLastOutcome(_ outcome: HookInstallOutcome) {
        stateLock.lock()
        _lastOutcome = outcome
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
    struct ClaudeCodeVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// Runs `claude --version` and parses the result. Returns nil on any
    /// failure (binary not found, non-zero exit, unparseable output).
    static func detectClaudeCodeVersion() -> ClaudeCodeVersion? {
        // Claude Code can land in a few typical spots; try each until we find one
        let fm = FileManager.default
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            "/usr/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return parseClaudeCodeVersion(from: output)
        } catch {
            return nil
        }
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
        let settings = ClaudePaths.settingsFile

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("claude-island-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
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
