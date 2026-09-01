//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
        static let autoApproveRules = "autoApproveRules"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }

    // MARK: - Auto-Approve Rules

    /// Standing answers to permission requests, newest last.
    ///
    /// Decoding failures return an empty list rather than a partial one: a
    /// half-understood rule set is the one case where "allow" must not be the
    /// fallback, and an empty list simply means every request is asked.
    static var autoApproveRules: [AutoApproveRule] {
        get {
            guard let data = defaults.data(forKey: Keys.autoApproveRules) else { return [] }
            guard let rules = try? JSONDecoder().decode([AutoApproveRule].self, from: data) else { return [] }
            return rules
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.autoApproveRules)
        }
    }

    /// Store a rule, ignoring one that already grants exactly the same thing.
    @discardableResult
    static func addAutoApproveRule(_ rule: AutoApproveRule) -> Bool {
        var rules = autoApproveRules
        let alreadyGranted = rules.contains {
            $0.projectPath == rule.projectPath && $0.toolName == rule.toolName && $0.scope == rule.scope
        }
        guard !alreadyGranted else { return false }
        rules.append(rule)
        autoApproveRules = rules
        return true
    }

    /// Revoke one rule. Takes effect on the next permission request — nothing
    /// is cached elsewhere.
    static func removeAutoApproveRule(id: UUID) {
        autoApproveRules = autoApproveRules.filter { $0.id != id }
    }

    /// Revoke everything, for the panic button in the settings panel.
    static func removeAllAutoApproveRules() {
        autoApproveRules = []
    }
}
