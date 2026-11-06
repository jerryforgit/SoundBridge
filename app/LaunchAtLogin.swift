import Foundation

/// Launch-at-login via a per-user LaunchAgent.
///
/// SMAppService was the original implementation, but it keys registrations by
/// code-signing identity. With ad-hoc signing every rebuild changes the
/// cdhash, which leaves stale login items behind and makes an uninstaller
/// unable to remove them. A LaunchAgent is a plain file the uninstaller can
/// always delete, and `launchctl` can unload it deterministically.
enum LaunchAtLogin {
    static let label = "com.jerry.soundbridge"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func enable() throws {
        let executable = Bundle.main.executablePath
            ?? "/Applications/SoundBridge.app/Contents/MacOS/SoundBridge"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--background"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]

        // Unload an older copy first so bootstrap never sees a duplicate label.
        bootout()

        try FileManager.default.createDirectory(
            at: agentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(getuid())", agentURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // A stale loaded job is the most common cause; retry once.
            bootout()
            let retry = Process()
            retry.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            retry.arguments = ["bootstrap", "gui/\(getuid())", agentURL.path]
            retry.standardOutput = FileHandle.nullDevice
            retry.standardError = FileHandle.nullDevice
            try? retry.run()
            retry.waitUntilExit()
        }
    }

    static func disable() {
        bootout()
        try? FileManager.default.removeItem(at: agentURL)
    }

    private static func bootout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
