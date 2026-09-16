//
//  StatusLineInstaller.swift
//  ClaudeIsland
//
//  Applies StatusLineBridge's plan to disk: the bridge script, the captured
//  original status line, and settings.json.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "Hooks")

enum StatusLineOutcome: Equatable, Sendable {
    /// Our bridge is in the slot (freshly written or refreshed).
    case installed
    /// Our bridge was already in the slot, exactly as wanted.
    case alreadyCurrent
    /// The captured original was put back.
    case removed
    /// Opted out and the slot was never ours — nothing to do.
    case notInstalled
    /// The slot holds something other than a command line. Left alone.
    case unsupportedStatusLine
    /// settings.json could not be read back as an object. Left alone.
    case settingsUnreadable
    case writeFailed(String)

    /// Whether plan usage reports can be arriving.
    var isActive: Bool {
        self == .installed || self == .alreadyCurrent
    }
}

enum StatusLineInstaller {

    private static var scriptURL: URL {
        ClaudePaths.hooksDir.appendingPathComponent(StatusLineBridge.scriptName)
    }

    private static var passthroughURL: URL {
        ClaudePaths.hooksDir.appendingPathComponent(StatusLineBridge.passthroughFileName)
    }

    /// Bring settings.json in line with the opt-in. Cheap when nothing has
    /// changed — one read, no write — so it runs on every launch.
    @discardableResult
    static func sync(enabled: Bool = AppSettings.showUsageLimits) -> StatusLineOutcome {
        let fm = FileManager.default
        let settingsURL = ClaudePaths.settingsFile
        let exists = fm.fileExists(atPath: settingsURL.path)
        let existingData: Data? = exists ? try? Data(contentsOf: settingsURL) : nil

        if exists && existingData == nil {
            logger.error("settings.json exists but could not be read — leaving statusLine alone")
            return .settingsUnreadable
        }

        // Resolving the interpreter launches a process, so only pay for it
        // when the answer is used.
        let command = enabled
            ? "\(HookInstaller.detectPython()) \(ClaudePaths.statusLineScriptShellPath)"
            : ""

        // Never point settings.json at a script that is not there — that
        // would blank the user's status line.
        if enabled, !installScript() {
            return .writeFailed("Could not install the status line script")
        }

        let plan = StatusLineBridge.plan(
            existingData: existingData,
            enabled: enabled,
            command: command,
            savedPassthrough: try? Data(contentsOf: passthroughURL)
        )

        switch plan {
        case .refuse:
            logger.error("settings.json is not a JSON object — refusing to touch statusLine")
            return .settingsUnreadable

        case .unsupported:
            logger.warning("statusLine is not a command line — cannot wrap it")
            return .unsupportedStatusLine

        case .unchanged:
            return enabled ? .alreadyCurrent : .notInstalled

        case .install(let settings, let passthrough):
            // The capture lands first: a bridge that runs before it exists
            // would print nothing where the user's status line used to be.
            do {
                try passthrough.write(to: passthroughURL, options: .atomic)
            } catch {
                logger.error("Failed to save the original statusLine: \(error.localizedDescription, privacy: .public)")
                return .writeFailed(error.localizedDescription)
            }
            return write(settings, over: existingData, to: settingsURL, success: .installed)

        case .update(let settings):
            return write(settings, over: existingData, to: settingsURL, success: .installed)

        case .remove(let settings):
            let outcome = write(settings, over: existingData, to: settingsURL, success: .removed)
            // Only once the original is back in settings.json: the capture is
            // the one copy of it until then.
            if outcome == .removed {
                try? fm.removeItem(at: passthroughURL)
                try? fm.removeItem(at: scriptURL)
            }
            return outcome
        }
    }

    /// Whether settings.json currently runs our bridge, read back from disk.
    static func isInstalled() -> Bool {
        StatusLineBridge.isInstalled(settingsData: try? Data(contentsOf: ClaudePaths.settingsFile))
    }

    private static func installScript() -> Bool {
        guard let bundled = Bundle.main.url(forResource: "claude-island-statusline", withExtension: "py") else {
            logger.error("Bundled status line script is missing")
            return false
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: ClaudePaths.hooksDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: scriptURL)
            try fm.copyItem(at: bundled, to: scriptURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return true
        } catch {
            logger.error("Failed to install status line script: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func write(
        _ settings: Data,
        over existingData: Data?,
        to settingsURL: URL,
        success: StatusLineOutcome
    ) -> StatusLineOutcome {
        if let existingData {
            HookInstaller.backUpSettings(existingData, at: settingsURL)
        }
        do {
            try settings.write(to: settingsURL, options: .atomic)
            logger.info("Updated statusLine in settings.json")
            return success
        } catch {
            logger.error("Failed to write settings.json: \(error.localizedDescription, privacy: .public)")
            return .writeFailed(error.localizedDescription)
        }
    }
}
