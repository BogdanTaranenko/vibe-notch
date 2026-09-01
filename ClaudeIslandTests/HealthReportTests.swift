//
//  HealthReportTests.swift
//  ClaudeIslandTests
//
//  The health panel exists to answer "why is the notch empty?", so its job is
//  to be right about a broken chain. These cases are mostly about not claiming
//  a link works when we have no evidence that it does.
//

import Foundation
import Testing

// MARK: - Fixtures

/// Facts describing a machine where every link works. Each test breaks exactly
/// one thing, so a status change can only be caused by what it changed.
private func healthyFacts() -> HealthFacts {
    HealthFacts(
        claudeDirectory: "/Users/x/.claude",
        claudeDirectoryExists: true,
        projectsDirectoryExists: true,
        installOutcome: .alreadyCurrent,
        hookCommand: "python3 '/Users/x/.claude/hooks/claude-island-state.py'",
        hookScriptExists: true,
        hookScriptIsExecutable: true,
        pythonCommand: "python3",
        pythonResolvedPath: "/usr/bin/python3",
        claudeVersion: "2.1.88",
        claudeBinaryPath: "/opt/homebrew/bin/claude",
        accessibilityGranted: true,
        socketPath: "/tmp/claude-island.sock",
        socketListening: true,
        lastEventName: "PostToolUse",
        lastEventAt: Date(timeIntervalSince1970: 1_000),
        eventCount: 42
    )
}

private let now = Date(timeIntervalSince1970: 1_060)

private func check(_ link: HealthCheck.Link, in report: HealthReport) -> HealthCheck {
    guard let found = report.checks.first(where: { $0.link == link }) else {
        Issue.record("no check for \(link)")
        return HealthCheck(link: link, status: .failing, detail: "missing", remedy: nil)
    }
    return found
}

// MARK: - Shape

@Suite("Health report shape")
struct HealthReportShapeTests {

    @Test func everyLinkAppearsExactlyOnce() {
        let report = HealthReport.make(from: healthyFacts(), now: now)
        #expect(report.checks.count == HealthCheck.Link.allCases.count)
        #expect(Set(report.checks.map(\.link)).count == report.checks.count)
    }

    @Test func aHealthyMachineHasNoProblems() {
        let report = HealthReport.make(from: healthyFacts(), now: now)
        #expect(report.problems.isEmpty)
        #expect(report.worst == .ok)
        #expect(report.checks.allSatisfy { $0.remedy == nil })
    }

    @Test func problemsAreCountedInTheSummary() {
        var facts = healthyFacts()
        facts.socketListening = false
        facts.accessibilityGranted = false

        let report = HealthReport.make(from: facts, now: now)
        #expect(report.problems.count == 2)
        #expect(report.summary.contains("2"))
        #expect(report.worst == .failing)
    }

    /// A failing link outranks a warning one, so the row's colour is the worst
    /// thing in the list rather than the last thing in it.
    @Test func worstStatusOutranksAWarning() {
        var facts = healthyFacts()
        facts.claudeVersion = nil          // warning
        facts.socketListening = false      // failing

        #expect(HealthReport.make(from: facts, now: now).worst == .failing)
    }

    /// Every non-ok check has to say what to do about it — a panel that reports
    /// a problem and offers nothing is the same dead end as an empty notch.
    @Test func everyProblemCarriesARemedy() {
        var facts = healthyFacts()
        facts.claudeDirectoryExists = false
        facts.installOutcome = .settingsUnreadable
        facts.hookScriptExists = false
        facts.pythonResolvedPath = nil
        facts.claudeVersion = nil
        facts.socketListening = false
        facts.accessibilityGranted = false

        let report = HealthReport.make(from: facts, now: now)
        for problem in report.problems where problem.status != .waiting {
            #expect(problem.remedy?.isEmpty == false, "\(problem.link) has no remedy")
        }
    }
}

// MARK: - Individual links

@Suite("Health checks")
struct HealthCheckTests {

    @Test func missingClaudeDirectoryFails() {
        var facts = healthyFacts()
        facts.claudeDirectoryExists = false

        let directory = check(.claudeDirectory, in: HealthReport.make(from: facts, now: now))
        #expect(directory.status == .failing)
        #expect(directory.detail.contains("/Users/x/.claude"))
    }

    /// The directory resolving to somewhere Claude Code does not actually use
    /// is the quiet misconfiguration behind an app that shows nothing at all.
    @Test func claudeDirectoryWithoutProjectsWarns() {
        var facts = healthyFacts()
        facts.projectsDirectoryExists = false

        #expect(check(.claudeDirectory, in: HealthReport.make(from: facts, now: now)).status == .warning)
    }

    @Test func unreadableSettingsFailsAndSaysItLeftTheFileAlone() {
        var facts = healthyFacts()
        facts.installOutcome = .settingsUnreadable

        let settings = check(.settings, in: HealthReport.make(from: facts, now: now))
        #expect(settings.status == .failing)
        #expect(settings.detail.lowercased().contains("settings.json"))
        // F1's guarantee is the part the user needs to hear: we did not write.
        #expect(settings.detail.lowercased().contains("untouched")
                || settings.detail.lowercased().contains("not written"))
    }

    @Test func writeFailureCarriesTheUnderlyingReason() {
        var facts = healthyFacts()
        facts.installOutcome = .writeFailed("Permission denied")

        let settings = check(.settings, in: HealthReport.make(from: facts, now: now))
        #expect(settings.status == .failing)
        #expect(settings.detail.contains("Permission denied"))
    }

    /// Nothing has been attempted yet, so there is nothing to report. Saying
    /// "ok" here would be a guess.
    @Test func installNotAttemptedIsWaitingRatherThanOk() {
        var facts = healthyFacts()
        facts.installOutcome = nil

        #expect(check(.settings, in: HealthReport.make(from: facts, now: now)).status == .waiting)
    }

    /// The installer reporting success while no hook is actually registered is
    /// the exact state that looks fine and works not at all.
    @Test func aWrittenSettingsFileWithNoHookRegisteredFails() {
        var facts = healthyFacts()
        facts.installOutcome = .installed
        facts.hookCommand = nil

        #expect(check(.settings, in: HealthReport.make(from: facts, now: now)).status == .failing)
    }

    @Test func missingHookScriptFails() {
        var facts = healthyFacts()
        facts.hookScriptExists = false

        #expect(check(.hookScript, in: HealthReport.make(from: facts, now: now)).status == .failing)
    }

    @Test func aHookScriptWithoutTheExecutableBitFails() {
        var facts = healthyFacts()
        facts.hookScriptIsExecutable = false

        #expect(check(.hookScript, in: HealthReport.make(from: facts, now: now)).status == .failing)
    }

    @Test func unresolvablePythonFails() {
        var facts = healthyFacts()
        facts.pythonResolvedPath = nil

        let python = check(.python, in: HealthReport.make(from: facts, now: now))
        #expect(python.status == .failing)
        #expect(python.detail.contains("python3"))
    }

    /// The interpreter is only checkable once we know which one the hook names.
    @Test func pythonWaitsWhenThereIsNoHookCommandToRead() {
        var facts = healthyFacts()
        facts.hookCommand = nil
        facts.pythonCommand = nil
        facts.pythonResolvedPath = nil

        #expect(check(.python, in: HealthReport.make(from: facts, now: now)).status == .waiting)
    }

    /// An undetected version is not fatal — it costs the newer hook events, and
    /// the user should know that is why something is missing.
    @Test func undetectedClaudeVersionWarnsAboutBaselineHooksOnly() {
        var facts = healthyFacts()
        facts.claudeVersion = nil
        facts.claudeBinaryPath = nil

        let version = check(.claudeVersion, in: HealthReport.make(from: facts, now: now))
        #expect(version.status == .warning)
        #expect(version.detail.lowercased().contains("baseline"))
    }

    @Test func detectedVersionIsShown() {
        let version = check(.claudeVersion, in: HealthReport.make(from: healthyFacts(), now: now))
        #expect(version.status == .ok)
        #expect(version.detail.contains("2.1.88"))
    }

    @Test func unboundSocketFails() {
        var facts = healthyFacts()
        facts.socketListening = false

        let socket = check(.socket, in: HealthReport.make(from: facts, now: now))
        #expect(socket.status == .failing)
        #expect(socket.detail.contains("/tmp/claude-island.sock"))
    }

    /// The panel's whole value is that it explains a symptom the user cannot
    /// otherwise account for. Sending someone to switch on a switch that is
    /// already on is worse than saying nothing, so the remedy has to name the
    /// case where the grant exists and still does not apply.
    @Test func missingAccessibilityExplainsAnEntryThatLooksEnabled() {
        var facts = healthyFacts()
        facts.accessibilityGranted = false
        let accessibility = check(.accessibility, in: HealthReport.make(from: facts, now: now))

        let remedy = try! #require(accessibility.remedy)
        #expect(remedy.contains("already listed"))
        #expect(remedy.contains("differently-signed"))
        #expect(accessibility.action == .resetAccessibilityGrant)
    }

    @Test func grantedAccessibilityOffersNoAction() {
        let accessibility = check(.accessibility, in: HealthReport.make(from: healthyFacts(), now: now))
        #expect(accessibility.status == .ok)
        #expect(accessibility.action == nil)
        #expect(accessibility.remedy == nil)
    }

    /// An action is an offer to change something on the user's machine, so it
    /// belongs only where there is a problem to justify it.
    @Test func noHealthyCheckCarriesAnAction() {
        let report = HealthReport.make(from: healthyFacts(), now: now)
        for check in report.checks where check.status == .ok {
            #expect(check.action == nil, "\(check.link) offers an action while reporting ok")
        }
    }

    @Test func missingAccessibilityFails() {
        var facts = healthyFacts()
        facts.accessibilityGranted = false

        #expect(check(.accessibility, in: HealthReport.make(from: facts, now: now)).status == .failing)
    }
}

// MARK: - Events

@Suite("Hook event arrival")
struct HealthEventTests {

    @Test func arrivingEventsAreReportedWithTheirAge() {
        let events = check(.events, in: HealthReport.make(from: healthyFacts(), now: now))
        #expect(events.status == .ok)
        #expect(events.detail.contains("PostToolUse"))
        #expect(events.detail.contains("1m"))
    }

    /// Nothing has arrived and every other link checks out — that is the one
    /// combination worth flagging on its own.
    @Test func silenceOnAnOtherwiseHealthyChainWarns() {
        var facts = healthyFacts()
        facts.lastEventAt = nil
        facts.lastEventName = nil
        facts.eventCount = 0

        #expect(check(.events, in: HealthReport.make(from: facts, now: now)).status == .warning)
    }

    /// With a broken link above it, silence is explained. Reporting it as its
    /// own problem would make one fault read as two.
    @Test func silenceWaitsOnAnUpstreamFailure() {
        var facts = healthyFacts()
        facts.lastEventAt = nil
        facts.lastEventName = nil
        facts.eventCount = 0
        facts.socketListening = false

        let events = check(.events, in: HealthReport.make(from: facts, now: now))
        #expect(events.status == .waiting)
    }

    /// A missing Accessibility grant breaks clicking the notch, not the flow of
    /// hook events, so it must not swallow the silence warning.
    @Test func accessibilityDoesNotExplainSilence() {
        var facts = healthyFacts()
        facts.lastEventAt = nil
        facts.lastEventName = nil
        facts.eventCount = 0
        facts.accessibilityGranted = false

        #expect(check(.events, in: HealthReport.make(from: facts, now: now)).status == .warning)
    }

    /// Events that arrived and then stopped are not a fault: an idle session
    /// legitimately emits nothing for hours. The timestamp is the report.
    @Test func longSilenceAfterAnEventIsStillOk() {
        var facts = healthyFacts()
        facts.lastEventAt = Date(timeIntervalSince1970: 0)

        #expect(check(.events, in: HealthReport.make(from: facts, now: now)).status == .ok)
    }
}

// MARK: - Age formatting

@Suite("Age formatting")
struct HealthAgeTests {

    @Test func agesReadInTheLargestUsefulUnit() {
        let base = Date(timeIntervalSince1970: 100_000)
        #expect(HealthReport.age(of: base, now: base) == "just now")
        #expect(HealthReport.age(of: base, now: base.addingTimeInterval(4)) == "just now")
        #expect(HealthReport.age(of: base, now: base.addingTimeInterval(42)) == "42s ago")
        #expect(HealthReport.age(of: base, now: base.addingTimeInterval(120)) == "2m ago")
        #expect(HealthReport.age(of: base, now: base.addingTimeInterval(7_200)) == "2h ago")
        #expect(HealthReport.age(of: base, now: base.addingTimeInterval(172_800)) == "2d ago")
    }

    /// Clock changes and NTP steps happen; a negative age must not render as
    /// "-3s ago".
    @Test func aTimestampInTheFutureReadsAsJustNow() {
        let base = Date(timeIntervalSince1970: 100_000)
        #expect(HealthReport.age(of: base, now: base.addingTimeInterval(-30)) == "just now")
    }
}

// MARK: - Reading the installed hook command

@Suite("Installed hook command")
struct InstalledHookCommandTests {

    private func settings(_ hooks: [String: Any]) -> [String: Any] {
        ["hooks": hooks]
    }

    @Test func findsOurCommandAnywhereInTheHooksTree() {
        let json = settings([
            "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "/bin/true"]]]],
            "Stop": [["hooks": [["type": "command", "command": "python3 '/Users/x/.claude/hooks/claude-island-state.py'"]]]],
        ])

        #expect(HookInstaller.hookCommand(in: json) == "python3 '/Users/x/.claude/hooks/claude-island-state.py'")
    }

    @Test func ignoresHooksThatAreNotOurs() {
        let json = settings([
            "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "prettier --write"]]]]
        ])

        #expect(HookInstaller.hookCommand(in: json) == nil)
    }

    @Test func toleratesShapesItDoesNotRecognise() {
        #expect(HookInstaller.hookCommand(in: [:]) == nil)
        #expect(HookInstaller.hookCommand(in: ["hooks": "not an object"]) == nil)
        #expect(HookInstaller.hookCommand(in: ["hooks": ["Stop": 7]]) == nil)
        #expect(HookInstaller.hookCommand(in: ["hooks": ["Stop": [["hooks": "nope"]]]]) == nil)
    }

    /// The interpreter is the first word of the command; the script path that
    /// follows is quoted and may contain spaces.
    @Test func interpreterIsTheFirstWordOfTheCommand() {
        #expect(HookInstaller.interpreter(in: "python3 '/Users/x/My Notch/hooks/claude-island-state.py'") == "python3")
        #expect(HookInstaller.interpreter(in: "  /usr/bin/python3   '/a/b.py'") == "/usr/bin/python3")
        #expect(HookInstaller.interpreter(in: "") == nil)
        #expect(HookInstaller.interpreter(in: "   ") == nil)
    }
}

// MARK: - Resolving the interpreter

@Suite("Executable resolution")
struct ExecutableResolutionTests {

    let searchPaths = ["/usr/bin", "/opt/homebrew/bin"]

    func resolve(_ name: String, executables: Set<String>) -> String? {
        HookInstaller.resolveExecutable(
            name,
            searchPaths: searchPaths,
            isExecutable: { executables.contains($0) }
        )
    }

    @Test func aBareNameIsFoundInSearchOrder() {
        #expect(resolve("python3", executables: ["/opt/homebrew/bin/python3"]) == "/opt/homebrew/bin/python3")
        // Earlier directories win, so the answer matches what a shell would run.
        #expect(resolve("python3", executables: ["/usr/bin/python3", "/opt/homebrew/bin/python3"]) == "/usr/bin/python3")
    }

    @Test func aBareNameThatIsNowhereResolvesToNil() {
        #expect(resolve("python3", executables: ["/usr/bin/python2"]) == nil)
    }

    /// Anything carrying a slash is already a path. Appending it to a search
    /// directory would invent a location that was never named.
    @Test func aPathIsCheckedWhereItPointsAndNowhereElse() {
        #expect(resolve("/usr/local/bin/python3", executables: ["/usr/local/bin/python3"]) == "/usr/local/bin/python3")
        #expect(resolve("/usr/local/bin/python3", executables: ["/usr/bin/python3"]) == nil)
        #expect(resolve("./python3", executables: ["/usr/bin/./python3"]) == nil)
    }

    @Test func anEmptyNameResolvesToNil() {
        #expect(resolve("", executables: ["/usr/bin/"]) == nil)
    }
}
