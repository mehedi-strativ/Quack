import Foundation
import QuackKit

/// Installs/removes Quack's Claude Code integration: writes the hook +
/// statusLine wrapper scripts under ~/.claude/quack/ and registers them in
/// ~/.claude/settings.json via the pure ClaudeSettingsEditor. Only ever runs
/// from an explicit user action in Settings — never automatically.
/// Not sandbox/App-Store compatible (writes another app's config; fine for
/// Quack's direct-distribution model).
@MainActor
final class ClaudeConfigInstaller {
    private let claudeDir: URL
    private var quackDir: URL { claudeDir.appendingPathComponent("quack") }
    var sessionsDirectory: URL { quackDir.appendingPathComponent("sessions") }
    private var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    private var hookFile: URL { quackDir.appendingPathComponent("hook.sh") }
    private var wrapperFile: URL { quackDir.appendingPathComponent("statusline-wrapper.sh") }
    private var backupFile: URL { quackDir.appendingPathComponent("previous-statusline.json") }

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsFile) else { return false }
        return ClaudeSettingsEditor.integrationPresent(in: data)
            && FileManager.default.fileExists(atPath: hookFile.path)
    }

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let existing = (try? Data(contentsOf: settingsFile)) ?? Data("{}".utf8)
        let (updated, previous) = try ClaudeSettingsEditor.addingIntegration(
            to: existing, hookCommand: hookFile.path, statusLineCommand: wrapperFile.path)

        // Remember the pre-Quack statusLine exactly once: a re-install must not
        // overwrite the original backup with our own wrapper path.
        if let previous, !fm.fileExists(atPath: backupFile.path) {
            let backup = try JSONSerialization.data(withJSONObject: ["command": previous])
            try backup.write(to: backupFile, options: .atomic)
        }

        let wrapper = ClaudeIntegrationScripts.statusLineWrapper(previousCommand: previous ?? backedUpCommand())
        try ClaudeIntegrationScripts.hookScript.write(to: hookFile, atomically: true, encoding: .utf8)
        try wrapper.write(to: wrapperFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperFile.path)

        try updated.write(to: settingsFile, options: .atomic)
    }

    func uninstall() throws {
        let existing = (try? Data(contentsOf: settingsFile)) ?? Data("{}".utf8)
        let restored = try ClaudeSettingsEditor.removingIntegration(
            from: existing, restoringStatusLineCommand: backedUpCommand())
        try restored.write(to: settingsFile, options: .atomic)
        let fm = FileManager.default
        try? fm.removeItem(at: hookFile)
        try? fm.removeItem(at: wrapperFile)
        try? fm.removeItem(at: backupFile)
        // sessions/ left in place: cheap, and a re-enable picks state right up.
    }

    private func backedUpCommand() -> String? {
        guard let data = try? Data(contentsOf: backupFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["command"] as? String
    }
}
