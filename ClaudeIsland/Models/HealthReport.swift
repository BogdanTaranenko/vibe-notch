//
//  HealthReport.swift
//  ClaudeIsland
//
//  Turns raw facts about the hook chain into one readable verdict per link.
//

import Foundation

/// How a single link in the chain is doing.
nonisolated enum HealthStatus: Sendable, Equatable {
    /// Verified working, with evidence in the detail line.
    case ok
    /// Degraded. The app still runs, but something is missing or reduced.
    case warning
    /// Broken. State cannot flow through this link.
    case failing
    /// Not judgeable yet — either nothing has been attempted, or a broken link
    /// upstream already explains the silence. Never claimed as `ok`.
    case waiting

    /// Rank used to pick the worst thing in a report. `waiting` sits above `ok`
    /// because "unknown" is not "fine", and below a real problem.
    var severity: Int {
        switch self {
        case .ok: return 0
        case .waiting: return 1
        case .warning: return 2
        case .failing: return 3
        }
    }
}

/// One link, its verdict, the evidence behind it, and what to do about it.
nonisolated struct HealthCheck: Identifiable, Sendable, Equatable {

    /// The chain, in the order state actually travels it: Claude Code writes to
    /// a config directory, our hooks are registered there, a Python script runs
    /// them, it writes to our socket, and events arrive.
    enum Link: String, Sendable, CaseIterable {
        case claudeDirectory
        case settings
        case hookScript
        case python
        case claudeVersion
        case socket
        case accessibility
        case events
    }

    let link: Link
    let status: HealthStatus
    /// One line of evidence — a path, a version, a timestamp, an error string.
    let detail: String
    /// What the user can do. Always present on a real problem, always nil when
    /// the link is fine.
    let remedy: String?

    var id: String { link.rawValue }

    var title: String {
        switch link {
        case .claudeDirectory: return "Claude directory"
        case .settings: return "settings.json"
        case .hookScript: return "Hook script"
        case .python: return "Python"
        case .claudeVersion: return "Claude Code"
        case .socket: return "Hook socket"
        case .accessibility: return "Accessibility"
        case .events: return "Hook events"
        }
    }
}

/// Everything the report is derived from, gathered in one pass so the
/// derivation itself stays pure and testable. A field this app could not
/// determine is nil rather than guessed.
nonisolated struct HealthFacts: Sendable, Equatable {
    var claudeDirectory: String
    var claudeDirectoryExists: Bool
    var projectsDirectoryExists: Bool

    /// Result of the most recent `HookInstaller.installIfNeeded()`, or nil when
    /// it has not run this launch.
    var installOutcome: HookInstallOutcome?
    /// The exact command registered in settings.json, if one of ours is there.
    var hookCommand: String?

    var hookScriptExists: Bool
    var hookScriptIsExecutable: Bool

    /// Interpreter named by `hookCommand`, and where it resolves for this app.
    var pythonCommand: String?
    var pythonResolvedPath: String?

    /// Version the installer detected when it chose which hook events to
    /// register — not a fresh probe, so this is what the registration is
    /// actually based on.
    var claudeVersion: String?
    var claudeBinaryPath: String?

    var accessibilityGranted: Bool

    var socketPath: String
    var socketListening: Bool

    var lastEventName: String?
    var lastEventAt: Date?
    var eventCount: Int

    init(
        claudeDirectory: String = "",
        claudeDirectoryExists: Bool = false,
        projectsDirectoryExists: Bool = false,
        installOutcome: HookInstallOutcome? = nil,
        hookCommand: String? = nil,
        hookScriptExists: Bool = false,
        hookScriptIsExecutable: Bool = false,
        pythonCommand: String? = nil,
        pythonResolvedPath: String? = nil,
        claudeVersion: String? = nil,
        claudeBinaryPath: String? = nil,
        accessibilityGranted: Bool = false,
        socketPath: String = "",
        socketListening: Bool = false,
        lastEventName: String? = nil,
        lastEventAt: Date? = nil,
        eventCount: Int = 0
    ) {
        self.claudeDirectory = claudeDirectory
        self.claudeDirectoryExists = claudeDirectoryExists
        self.projectsDirectoryExists = projectsDirectoryExists
        self.installOutcome = installOutcome
        self.hookCommand = hookCommand
        self.hookScriptExists = hookScriptExists
        self.hookScriptIsExecutable = hookScriptIsExecutable
        self.pythonCommand = pythonCommand
        self.pythonResolvedPath = pythonResolvedPath
        self.claudeVersion = claudeVersion
        self.claudeBinaryPath = claudeBinaryPath
        self.accessibilityGranted = accessibilityGranted
        self.socketPath = socketPath
        self.socketListening = socketListening
        self.lastEventName = lastEventName
        self.lastEventAt = lastEventAt
        self.eventCount = eventCount
    }
}

/// The whole chain, one check per link.
///
/// Everything this app shows depends on a sequence the user cannot see, and
/// when any part of it breaks the symptom is identical every time: the notch
/// sits there empty. This turns that into a list where the broken link names
/// itself.
nonisolated struct HealthReport: Sendable, Equatable {
    let checks: [HealthCheck]
    let generatedAt: Date

    var problems: [HealthCheck] {
        checks.filter { $0.status != .ok }
    }

    var worst: HealthStatus {
        checks.map(\.status).max { $0.severity < $1.severity } ?? .ok
    }

    var summary: String {
        switch problems.count {
        case 0: return "All \(checks.count) checks passing"
        case 1: return "1 problem"
        case let count: return "\(count) problems"
        }
    }
}

// MARK: - Derivation

extension HealthReport {

    static func make(from facts: HealthFacts, now: Date = Date()) -> HealthReport {
        let ordered: [HealthCheck] = [
            claudeDirectoryCheck(facts),
            settingsCheck(facts),
            hookScriptCheck(facts),
            pythonCheck(facts),
            claudeVersionCheck(facts),
            socketCheck(facts),
            accessibilityCheck(facts),
        ]

        return HealthReport(
            checks: ordered + [eventsCheck(facts, upstream: ordered, now: now)],
            generatedAt: now
        )
    }

    // MARK: Links

    private static func claudeDirectoryCheck(_ facts: HealthFacts) -> HealthCheck {
        let directory = facts.claudeDirectory.isEmpty ? "(unresolved)" : facts.claudeDirectory

        guard facts.claudeDirectoryExists else {
            return HealthCheck(
                link: .claudeDirectory,
                status: .failing,
                detail: "\(directory) does not exist",
                remedy: "Point Claude Directory at the folder Claude Code uses, or set CLAUDE_CONFIG_DIR."
            )
        }

        // Transcripts are read from projects/, and everything richer than a
        // coarse status comes from those. A directory without it is almost
        // always the wrong directory.
        guard facts.projectsDirectoryExists else {
            return HealthCheck(
                link: .claudeDirectory,
                status: .warning,
                detail: "\(directory) has no projects/ — transcripts are read from there",
                remedy: "Point Claude Directory at the folder Claude Code uses, or set CLAUDE_CONFIG_DIR."
            )
        }

        return HealthCheck(link: .claudeDirectory, status: .ok, detail: directory, remedy: nil)
    }

    private static func settingsCheck(_ facts: HealthFacts) -> HealthCheck {
        switch facts.installOutcome {
        case .none:
            return HealthCheck(
                link: .settings,
                status: .waiting,
                detail: "Not attempted yet this launch",
                remedy: nil
            )

        case .settingsUnreadable:
            return HealthCheck(
                link: .settings,
                status: .failing,
                detail: "settings.json could not be read as JSON — it was left untouched and no hooks were installed",
                remedy: "Fix or move the file, then toggle Hooks off and on."
            )

        case .writeFailed(let reason):
            return HealthCheck(
                link: .settings,
                status: .failing,
                detail: "Could not write settings.json: \(reason)",
                remedy: "Check permissions on the Claude directory, then toggle Hooks off and on."
            )

        case .installed, .alreadyCurrent:
            guard facts.hookCommand != nil else {
                // The write reported success and our hook is not there. Rare,
                // and indistinguishable from working until an event never comes.
                return HealthCheck(
                    link: .settings,
                    status: .failing,
                    detail: "settings.json was written but no Vibe Notch hook is registered",
                    remedy: "Toggle Hooks off and on to reinstall."
                )
            }
            return HealthCheck(
                link: .settings,
                status: .ok,
                detail: "Vibe Notch hooks registered",
                remedy: nil
            )
        }
    }

    private static func hookScriptCheck(_ facts: HealthFacts) -> HealthCheck {
        let reinstall = "Toggle Hooks off and on to reinstall the script."

        guard facts.hookScriptExists else {
            return HealthCheck(
                link: .hookScript,
                status: .failing,
                detail: "claude-island-state.py is not in the hooks directory",
                remedy: reinstall
            )
        }

        guard facts.hookScriptIsExecutable else {
            return HealthCheck(
                link: .hookScript,
                status: .failing,
                detail: "claude-island-state.py is not executable",
                remedy: reinstall
            )
        }

        return HealthCheck(
            link: .hookScript,
            status: .ok,
            detail: "claude-island-state.py installed",
            remedy: nil
        )
    }

    private static func pythonCheck(_ facts: HealthFacts) -> HealthCheck {
        guard let command = facts.pythonCommand, !command.isEmpty else {
            return HealthCheck(
                link: .python,
                status: .waiting,
                detail: "No registered hook command to read an interpreter from",
                remedy: nil
            )
        }

        guard let path = facts.pythonResolvedPath else {
            return HealthCheck(
                link: .python,
                status: .failing,
                detail: "\(command) does not resolve — the hook cannot run",
                remedy: "Install Python 3 (xcode-select --install), then toggle Hooks off and on."
            )
        }

        return HealthCheck(
            link: .python,
            status: .ok,
            detail: command == path ? command : "\(command) → \(path)",
            remedy: nil
        )
    }

    private static func claudeVersionCheck(_ facts: HealthFacts) -> HealthCheck {
        guard let version = facts.claudeVersion else {
            // Not fatal: the installer falls back to the hook events every
            // version has supported. Worth saying, because it is the reason a
            // newer event never fires.
            return HealthCheck(
                link: .claudeVersion,
                status: .warning,
                detail: "Version not detected — only the baseline hook events are registered",
                remedy: "Install Claude Code, then toggle Hooks off and on to search for it again."
            )
        }

        let detail = facts.claudeBinaryPath.map { "v\(version) · \($0)" } ?? "v\(version)"
        return HealthCheck(link: .claudeVersion, status: .ok, detail: detail, remedy: nil)
    }

    private static func socketCheck(_ facts: HealthFacts) -> HealthCheck {
        guard facts.socketListening else {
            return HealthCheck(
                link: .socket,
                status: .failing,
                detail: "Nothing is listening on \(facts.socketPath) — hook events cannot arrive",
                remedy: "Quit and reopen Vibe Notch."
            )
        }

        return HealthCheck(
            link: .socket,
            status: .ok,
            detail: "Listening on \(facts.socketPath)",
            remedy: nil
        )
    }

    private static func accessibilityCheck(_ facts: HealthFacts) -> HealthCheck {
        guard facts.accessibilityGranted else {
            // Hover and click detection are global NSEvent monitors, so without
            // this the notch renders and cannot be opened.
            return HealthCheck(
                link: .accessibility,
                status: .failing,
                detail: "Not granted — the notch cannot see hover or clicks",
                remedy: "Allow Vibe Notch in System Settings → Privacy & Security → Accessibility."
            )
        }

        return HealthCheck(link: .accessibility, status: .ok, detail: "Granted", remedy: nil)
    }

    /// Whether events are arriving is the only check that proves the whole
    /// chain, so it is derived last and reads the verdicts above it.
    private static func eventsCheck(
        _ facts: HealthFacts,
        upstream: [HealthCheck],
        now: Date
    ) -> HealthCheck {
        if let lastEventAt = facts.lastEventAt {
            // Events that arrived and then stopped are not a fault — an idle
            // session emits nothing for hours. The timestamp is the report.
            let name = facts.lastEventName ?? "event"
            return HealthCheck(
                link: .events,
                status: .ok,
                detail: "\(name), \(age(of: lastEventAt, now: now)) · \(facts.eventCount) received",
                remedy: nil
            )
        }

        // Accessibility is deliberately not in this set: it breaks clicking the
        // notch, not the flow of events, so it must not explain the silence.
        let carriers: Set<HealthCheck.Link> = [.claudeDirectory, .settings, .hookScript, .python, .socket]
        let broken = upstream.first { carriers.contains($0.link) && $0.status == .failing }

        if let broken {
            return HealthCheck(
                link: .events,
                status: .waiting,
                detail: "Waiting — \(broken.title) has to be fixed first",
                remedy: nil
            )
        }

        return HealthCheck(
            link: .events,
            status: .warning,
            detail: "Nothing received since launch",
            remedy: "Start or continue a Claude Code session to exercise the chain."
        )
    }
}

// MARK: - Age

extension HealthReport {
    /// Coarse relative time, in the largest unit that still says something.
    /// A timestamp in the future reads as "just now" rather than a negative
    /// age — clock steps happen, and they are not worth reporting.
    static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))

        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
