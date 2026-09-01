//
//  ProjectSlugTests.swift
//  ClaudeIslandTests
//
//  Covers the cwd -> transcript-directory slug. Getting this wrong points every
//  JSONL reader at a directory that does not exist, and each of them fails by
//  returning nothing rather than by raising — so the notch simply shows no
//  conversation, no meters and no cost, with nothing in the log to explain it.
//
//  The expectations below were measured against Claude Code itself by running
//  `claude -p` inside directories with the characters in question and reading
//  back the directory name it created under ~/.claude/projects/.
//

import Foundation
import Testing

@Suite("Project slug")
struct ProjectSlugTests {

    // MARK: - The rule

    @Test("Path separators become dashes")
    func separatorsBecomeDashes() {
        #expect(ClaudePaths.projectSlug(for: "/Users/me/Documents/app")
                == "-Users-me-Documents-app")
    }

    @Test("Underscores become dashes")
    func underscoresBecomeDashes() {
        // The regression this file exists for: a path under a directory like
        // `_opensource` resolved to a slug that no Claude Code install writes.
        #expect(ClaudePaths.projectSlug(for: "/Users/me/Projects/_opensource/vibe-notch")
                == "-Users-me-Projects--opensource-vibe-notch")
    }

    @Test("Dots become dashes")
    func dotsBecomeDashes() {
        #expect(ClaudePaths.projectSlug(for: "/Users/me/.claude") == "-Users-me--claude")
    }

    @Test("Every other non-alphanumeric becomes a dash")
    func otherPunctuationBecomesDashes() {
        // Measured: `slug probe_a.b+c@d` -> `slug-probe-a-b-c-d`.
        #expect(ClaudePaths.projectSlug(for: "slug probe_a.b+c@d") == "slug-probe-a-b-c-d")
    }

    @Test("Letters, digits and existing dashes survive")
    func alphanumericsSurvive() {
        #expect(ClaudePaths.projectSlug(for: "vibe-notch2") == "vibe-notch2")
    }

    // MARK: - Non-ASCII

    @Test("Non-ASCII letters are replaced, one dash per character")
    func nonASCIILettersBecomeDashes() {
        // Measured: `café-Проект-日本` -> `caf` followed by exactly 11 dashes.
        #expect(ClaudePaths.projectSlug(for: "café-Проект-日本") == "caf" + String(repeating: "-", count: 11))
    }

    @Test("An astral-plane character becomes two dashes, not one")
    func astralCharacterBecomesTwoDashes() {
        // Measured: `x🎉y` -> `x--y`. Claude Code scans UTF-16 code units, so a
        // surrogate pair yields two dashes. Iterating Swift Characters or
        // unicode scalars here would produce `x-y` and miss the directory.
        #expect(ClaudePaths.projectSlug(for: "x🎉y") == "x--y")
    }

    // MARK: - Edges

    @Test("An empty path yields an empty slug")
    func emptyPath() {
        #expect(ClaudePaths.projectSlug(for: "") == "")
    }

    @Test("A trailing separator is not trimmed")
    func trailingSeparatorKept() {
        #expect(ClaudePaths.projectSlug(for: "/Users/me/") == "-Users-me-")
    }
}
