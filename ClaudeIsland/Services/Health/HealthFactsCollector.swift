//
//  HealthFactsCollector.swift
//  ClaudeIsland
//
//  Reads the current state of every link in the hook chain, in one pass.
//

import ApplicationServices
import Foundation

/// Gathers the raw facts behind ``HealthReport``.
///
/// Deliberately does no judging — every verdict is derived in `HealthReport`,
/// which is pure and covered by tests. This half only looks things up, so the
/// half that can be wrong in a way the user would believe is testable.
enum HealthFactsCollector {

    /// Name of the hook script as it is installed into the Claude hooks
    /// directory. Renaming it breaks upgrades for existing users.
    private static let hookScriptName = "claude-island-state.py"

    /// A handful of `stat` calls and one small file read — cheap enough to run
    /// wherever the panel is refreshed from. Nothing here spawns a process.
    static func collect() -> HealthFacts {
        let fm = FileManager.default

        let claudeDir = ClaudePaths.claudeDir
        let hookScript = ClaudePaths.hooksDir.appendingPathComponent(hookScriptName)

        let hookCommand = HookInstaller.installedHookCommand()
        let pythonCommand = hookCommand.flatMap { HookInstaller.interpreter(in: $0) }

        let traffic = HookSocketServer.shared.traffic

        return HealthFacts(
            claudeDirectory: claudeDir.path,
            claudeDirectoryExists: isDirectory(claudeDir, fm),
            projectsDirectoryExists: isDirectory(ClaudePaths.projectsDir, fm),
            installOutcome: HookInstaller.lastOutcome,
            hookCommand: hookCommand,
            hookScriptExists: fm.fileExists(atPath: hookScript.path),
            hookScriptIsExecutable: fm.isExecutableFile(atPath: hookScript.path),
            pythonCommand: pythonCommand,
            pythonResolvedPath: pythonCommand.flatMap { HookInstaller.resolveExecutable($0) },
            claudeVersion: HookInstaller.lastDetectedVersion?.description,
            claudeBinaryPath: HookInstaller.resolvedBinaryPath,
            accessibilityGranted: AXIsProcessTrusted(),
            socketPath: HookSocketServer.socketPath,
            socketListening: HookSocketServer.shared.isListening,
            lastEventName: traffic.lastEventName,
            lastEventAt: traffic.lastEventAt,
            eventCount: traffic.count
        )
    }

    /// A file where a directory is expected is as broken as nothing at all, so
    /// the check is for a directory rather than for existence.
    private static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
