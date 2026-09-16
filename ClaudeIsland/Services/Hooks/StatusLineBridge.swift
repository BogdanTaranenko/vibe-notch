//
//  StatusLineBridge.swift
//  ClaudeIsland
//
//  Decides how to take over, refresh or give back settings.json's statusLine
//  slot, which is the only place Claude Code reports plan usage limits.
//

import Foundation

/// settings.json holds exactly one `statusLine`, and it usually already runs
/// something the user built. Opting in wraps it: ours is installed in its
/// place, the original is captured to a sidecar file, and the bridge script
/// runs the original with the same input and prints what it prints. Opting
/// out puts the captured one back.
///
/// Pure and Foundation-only so every branch can be tested without a real
/// ~/.claude; the file IO lives in `StatusLineInstaller`.
nonisolated enum StatusLineBridge {
    static let scriptName = "claude-island-statusline.py"
    static let passthroughFileName = "claude-island-statusline.json"

    /// The `event` the bridge script sends. Never a Claude Code hook name, so
    /// it cannot be mistaken for one.
    static let eventName = "StatusLine"

    enum Plan: Equatable {
        /// Write `passthrough` first, then `settings` — so the script never
        /// runs without knowing what it wraps.
        case install(settings: Data, passthrough: Data)
        /// Ours already; only the command line changed (interpreter, config
        /// directory). The captured original is kept as it is.
        case update(settings: Data)
        /// Write `settings`, then delete the sidecar.
        case remove(settings: Data)
        case unchanged
        /// The slot holds a shape we cannot run on the user's behalf. Left
        /// alone; the feature stays off.
        case unsupported
        /// settings.json cannot be read back as an object. Nothing is written.
        case refuse
    }

    static func plan(
        existingData: Data?,
        enabled: Bool,
        command: String,
        savedPassthrough: Data?
    ) -> Plan {
        var json: [String: Any] = [:]

        if let existingData, !isBlank(existingData) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                return .refuse
            }
            json = parsed
        }

        let current = json["statusLine"]

        guard enabled else {
            guard let currentLine = current as? [String: Any], isOurs(currentLine) else {
                return .unchanged
            }

            // Restore only a captured line that is a real object and is not
            // ours — putting ourselves back would leave a script that wraps
            // nothing, and one that wraps itself.
            if let restored = capturedStatusLine(in: savedPassthrough), !isOurs(restored) {
                json["statusLine"] = restored
            } else {
                json.removeValue(forKey: "statusLine")
            }
            return encode(json).map { .remove(settings: $0) } ?? .refuse
        }

        guard let current else {
            json["statusLine"] = ["type": "command", "command": command]

            // An empty slot does not prove there was never anything to give
            // back: a dotfiles sync or a hand edit can clear the key while we
            // are opted in. A capture from earlier is still the user's only
            // copy of their line, so it is carried over rather than wiped.
            var carried: [String: Any] = [:]
            if let earlier = capturedStatusLine(in: savedPassthrough), !isOurs(earlier) {
                carried["statusLine"] = earlier
            }

            guard let settings = encode(json), let passthrough = encode(carried) else { return .refuse }
            return .install(settings: settings, passthrough: passthrough)
        }

        guard let currentLine = current as? [String: Any] else {
            return .unsupported
        }

        if isOurs(currentLine) {
            guard currentLine["command"] as? String != command else { return .unchanged }
            var refreshed = currentLine
            refreshed["command"] = command
            json["statusLine"] = refreshed
            return encode(json).map { .update(settings: $0) } ?? .refuse
        }

        // Only a command line can be run on the user's behalf.
        guard currentLine["type"] as? String == "command",
              let original = currentLine["command"] as? String,
              !original.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .unsupported
        }

        // Keep padding, refreshInterval and anything newer we do not know
        // about: they describe how the line is displayed, which is unchanged.
        var wrapped = currentLine
        wrapped["command"] = command
        json["statusLine"] = wrapped

        guard let settings = encode(json),
              let passthrough = encode(["statusLine": currentLine])
        else { return .refuse }
        return .install(settings: settings, passthrough: passthrough)
    }

    static func isOurs(_ statusLine: [String: Any]) -> Bool {
        (statusLine["command"] as? String)?.contains(scriptName) == true
    }

    /// Whether the slot currently holds our bridge.
    static func isInstalled(settingsData: Data?) -> Bool {
        guard let settingsData,
              let json = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let line = json["statusLine"] as? [String: Any]
        else { return false }
        return isOurs(line)
    }

    private static func capturedStatusLine(in data: Data?) -> [String: Any]? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["statusLine"] as? [String: Any]
    }

    /// Same options as the hook rewrite, so the two writers agree on the
    /// canonical form and neither reformats the file behind the other.
    private static func encode(_ json: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    private static func isBlank(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
