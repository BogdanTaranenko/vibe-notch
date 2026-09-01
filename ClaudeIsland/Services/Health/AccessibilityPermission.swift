//
//  AccessibilityPermission.swift
//  ClaudeIsland
//
//  Asking macOS for the Accessibility grant the notch cannot work without,
//  and recovering when a stale grant makes asking impossible.
//

import ApplicationServices
import AppKit
import Foundation
import os.log

/// The notch's hover and click detection are global `NSEvent` monitors, so
/// without this grant the panel draws and cannot be opened.
enum AccessibilityPermission {

    private static let logger = Logger(subsystem: "com.claudeisland", category: "Accessibility")

    /// TCC services this app can hold. Reset covers all of them because a stale
    /// row for any one of them fails the same way and for the same reason.
    private static let services = ["Accessibility", "PostEvent", "ListenEvent"]

    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Ask macOS for the grant, showing the system dialog if the decision has
    /// not been made yet.
    ///
    /// This is what puts the app in the Accessibility list *with the right code
    /// requirement attached*. Without it a user has to add the app by hand, and
    /// a hand-added entry is exactly as fragile as the signature that happened
    /// to be on disk at the time. macOS shows the dialog only while the decision
    /// is undetermined, so this is safe to call on every launch: once answered,
    /// it is a silent boolean read.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        logger.info("Accessibility trusted: \(trusted, privacy: .public)")
        return trusted
    }

    /// Clear this bundle id's TCC rows, then ask again.
    ///
    /// The case this exists for: macOS stores a grant against the bundle id and
    /// pins it to the signature that first claimed it. This app inherits its
    /// bundle id from the project it forks, so on a Mac that ever ran the
    /// original, the stored row demands a certificate this build cannot present.
    /// The switch in System Settings reads as on, every request is refused, and
    /// the only visible trace is a line in `tccd`'s log. Toggling the switch
    /// cannot fix it because the row itself is the problem; it has to go.
    ///
    /// `tccutil reset` for our own bundle id needs no privileges. Each service
    /// is reset separately rather than with `All` so this cannot quietly clear a
    /// grant belonging to something else the app was given.
    static func resetAndRequest() async {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            logger.error("No bundle identifier; cannot reset accessibility grant")
            return
        }

        for service in services {
            let result = await ProcessExecutor.shared.runWithResult(
                "/usr/bin/tccutil", arguments: ["reset", service, bundleId]
            )
            switch result {
            case .success(let process):
                logger.info("tccutil reset \(service, privacy: .public): exit \(process.exitCode, privacy: .public)")
            case .failure(let error):
                // A service this macOS version does not know is not a problem
                // worth surfacing -- the ones that matter will still have reset.
                logger.info("tccutil reset \(service, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        await MainActor.run { requestIfNeeded() }
    }

    /// Open the pane, for the half of the job macOS will not let an app do.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
