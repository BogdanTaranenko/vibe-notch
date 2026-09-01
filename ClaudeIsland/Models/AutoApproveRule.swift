//
//  AutoApproveRule.swift
//  ClaudeIsland
//
//  A user-created rule that answers a permission request without asking.
//

import Foundation

/// How much a rule is willing to allow beyond the tool name itself.
///
/// There are deliberately only two scopes. Anything looser — a prefix match on
/// a Bash command, a glob over paths — reads as convenient and is not: `git
/// status` as a prefix also matches `git status; rm -rf ~`, and a path glob is
/// only as good as the traversal check behind it. Two scopes are small enough
/// to reason about completely.
enum AutoApproveScope: Codable, Sendable, Equatable, Hashable {
    /// Any invocation of the tool, provided every path it names stays inside
    /// the rule's project. Only ever honoured for ``AutoApproveRule/readOnlyTools``.
    case anyInput

    /// One exact set of arguments, compared against a canonical encoding of the
    /// whole tool input. The only scope available to a tool that can write,
    /// run a command, or reach the network.
    case exactInput(canonical: String, display: String)
}

/// A standing answer to one shape of permission request, scoped to one project.
///
/// Rules are matched entirely in this app: ``HookSocketServer`` writes `allow`
/// back on the still-open hook socket and never parks the request. Nothing is
/// written to the user's Claude Code settings, so removing a rule here removes
/// it everywhere, immediately.
struct AutoApproveRule: Codable, Sendable, Equatable, Identifiable {
    let id: UUID

    /// Absolute path of the project this rule applies to. Compared for
    /// equality against the session's cwd — never as a prefix, so a rule for
    /// `/work/api` cannot leak into `/work/api-secrets`.
    let projectPath: String

    /// Exact tool name as Claude Code reports it, e.g. `Read`, `Bash`,
    /// `mcp__linear__create_issue`.
    let toolName: String

    let scope: AutoApproveScope
    let createdAt: Date

    init(
        id: UUID = UUID(),
        projectPath: String,
        toolName: String,
        scope: AutoApproveScope,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectPath = projectPath
        self.toolName = toolName
        self.scope = scope
        self.createdAt = createdAt
    }
}

// MARK: - The safety envelope

extension AutoApproveRule {
    /// Tools whose only effect is to read, and which may therefore carry an
    /// ``AutoApproveScope/anyInput`` rule.
    ///
    /// This is enforced at *match* time, not only at rule-creation time. A
    /// rule that claims `.anyInput` for `Bash` never matches, however it got
    /// into the store — a hand-edited defaults plist included.
    static let readOnlyTools: Set<String> = ["Read", "NotebookRead", "Grep", "Glob"]

    /// For each read-only tool, the input keys that name a filesystem path.
    ///
    /// "Always allow Read in this project" must not become permission to read
    /// `~/.ssh/id_rsa` from a session that merely *runs* in the project, so
    /// every one of these that is present has to resolve inside the project.
    /// A key that is absent defaults to the cwd, which is inside by definition.
    static let pathArguments: [String: [String]] = [
        "Read": ["file_path"],
        "NotebookRead": ["notebook_path"],
        "Grep": ["path"],
        "Glob": ["path"],
    ]
}

// MARK: - Matching

extension AutoApproveRule {
    /// The first rule that answers this request, or nil to ask the user.
    ///
    /// Order is stable — rules are stored newest-last and scanned in order —
    /// but which rule matches never changes the decision, only the audit line.
    static func firstMatch(
        in rules: [AutoApproveRule],
        cwd: String,
        toolName: String?,
        toolInput: [String: AnyCodable]?
    ) -> AutoApproveRule? {
        rules.first { $0.matches(cwd: cwd, toolName: toolName, toolInput: toolInput) }
    }

    /// Whether this rule allows the given request. Every branch fails closed:
    /// anything unrecognised, unencodable or merely unexpected returns false
    /// and the user is asked as usual.
    func matches(cwd: String, toolName: String?, toolInput: [String: AnyCodable]?) -> Bool {
        guard let toolName, !toolName.isEmpty, toolName == self.toolName else { return false }

        let project = Self.normalize(projectPath)
        guard !project.isEmpty, project != "/", Self.normalize(cwd) == project else { return false }

        switch scope {
        case .anyInput:
            guard Self.readOnlyTools.contains(toolName) else { return false }
            return Self.everyPathStaysInside(project: project, toolName: toolName, toolInput: toolInput)

        case .exactInput(let canonical, _):
            guard let incoming = Self.canonicalize(toolInput) else { return false }
            return incoming == canonical
        }
    }

    /// True when every path argument this tool carries resolves inside `project`.
    ///
    /// A path key that is present but is not a string is a shape we did not
    /// anticipate, so it refuses rather than skipping the check.
    static func everyPathStaysInside(
        project: String,
        toolName: String,
        toolInput: [String: AnyCodable]?
    ) -> Bool {
        guard let keys = pathArguments[toolName] else { return false }

        for key in keys {
            guard let wrapped = toolInput?[key] else { continue }
            if wrapped.value is NSNull { continue }
            guard let raw = wrapped.value as? String else { return false }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let candidate = resolve(trimmed, relativeTo: project)
            guard candidate == project || candidate.hasPrefix(project + "/") else { return false }
        }

        return true
    }

    /// Absolute, `..`-free, symlink-resolved form of a path, without a trailing
    /// slash. Used on both sides of every containment check so the comparison
    /// is between two canonical strings rather than two spellings.
    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }

        let resolved = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        var trimmed = resolved
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// Resolve a possibly-relative path argument against the project root.
    static func resolve(_ raw: String, relativeTo root: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return normalize(expanded) }
        return normalize(root + "/" + expanded)
    }

    /// Deterministic encoding of a whole tool input, used as the identity of an
    /// ``AutoApproveScope/exactInput`` rule. Returns nil when the input cannot
    /// be encoded, which makes such a request unmatchable rather than equal to
    /// some other unencodable one.
    static func canonicalize(_ toolInput: [String: AnyCodable]?) -> String? {
        guard let toolInput, !toolInput.isEmpty else { return "{}" }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(toolInput),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

// MARK: - Proposing a rule from a live request

extension AutoApproveRule {
    /// The rule the UI may offer for a request, or nil when none is safe.
    ///
    /// The widest scope a request can earn is ``AutoApproveScope/anyInput``,
    /// and only a read-only tool already staying inside its project earns it.
    /// Everything else — every write, every command, every network call — is
    /// offered as this exact input and nothing more.
    static func proposal(
        cwd: String,
        toolName: String?,
        toolInput: [String: AnyCodable]?,
        now: Date = Date()
    ) -> AutoApproveRule? {
        guard let toolName, !toolName.isEmpty else { return nil }

        let project = normalize(cwd)
        guard !project.isEmpty, project != "/" else { return nil }

        if readOnlyTools.contains(toolName),
           everyPathStaysInside(project: project, toolName: toolName, toolInput: toolInput) {
            return AutoApproveRule(
                projectPath: project,
                toolName: toolName,
                scope: .anyInput,
                createdAt: now
            )
        }

        guard let canonical = canonicalize(toolInput) else { return nil }
        return AutoApproveRule(
            projectPath: project,
            toolName: toolName,
            scope: .exactInput(canonical: canonical, display: describe(toolName: toolName, toolInput: toolInput)),
            createdAt: now
        )
    }

    /// One-line human description of a tool input, for the rules list and the
    /// button that creates one. Display only — never used for matching.
    static func describe(toolName: String, toolInput: [String: AnyCodable]?) -> String {
        let preferredKeys = ["command", "file_path", "notebook_path", "pattern", "url", "path", "query"]

        for key in preferredKeys {
            if let value = toolInput?[key]?.value as? String, !value.isEmpty {
                return collapse(value)
            }
        }

        guard let canonical = canonicalize(toolInput), canonical != "{}" else { return toolName }
        return collapse(canonical)
    }

    /// Squash newlines and runs of whitespace so a multi-line command renders
    /// as one line in a list row.
    private static func collapse(_ text: String) -> String {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = parts.joined(separator: " ")
        return joined.count > 120 ? String(joined.prefix(119)) + "…" : joined
    }
}

// MARK: - Display

extension AutoApproveRule {
    /// Name of the project folder, for a rules list grouped by project.
    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// What this rule allows, phrased for the settings list.
    var summary: String {
        switch scope {
        case .anyInput:
            return "any \(toolName) in this project"
        case .exactInput(_, let display):
            return "\(toolName): \(display)"
        }
    }
}
