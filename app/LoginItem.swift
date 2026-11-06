import Foundation
import ServiceManagement

/// Login item for the main app.
///
/// `SMAppService.mainApp` is the only API that puts the app under
/// System Settings → General → Login Items → "Open at Login".
/// LaunchAgents land under "Allow in the Background" instead, which is not
/// what we want for an app the user explicitly starts at login.
///
/// Ad-hoc signing means every build changes the cdhash, so the installer's
/// preinstall unregisters the *old* installed binary before replacing it, and
/// the new build re-registers on first launch when the preference is on.
enum LoginItem {
    static let label = "com.jerry.soundbridge"

    static var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func enable() throws {
        guard #available(macOS 13.0, *) else { return }
        removeLegacyAgent()
        try SMAppService.mainApp.register()
    }

    static func disable() throws {
        guard #available(macOS 13.0, *) else { return }
        if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
        removeLegacyAgent()
    }

    /// Called at launch. Cleans up the short-lived LaunchAgent implementation
    /// and re-registers this build if the user had launch-at-login enabled
    /// before an update replaced the app bundle.
    static func reconcile(prefEnabled: Bool) {
        removeLegacyAgent()
        guard #available(macOS 13.0, *) else { return }
        if prefEnabled && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    static func removeLegacyAgent() {
        guard FileManager.default.fileExists(atPath: legacyAgentURL.path) else { return }
        bootoutLegacyAgent()
        try? FileManager.default.removeItem(at: legacyAgentURL)
    }

    private static func bootoutLegacyAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
