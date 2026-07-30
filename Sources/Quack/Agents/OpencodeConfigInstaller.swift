import Foundation
import QuackKit

/// Installs/removes Quack's opencode integration: drops a plugin file into
/// opencode's global plugin directory. Unlike Claude Code, opencode
/// auto-loads any file in ~/.config/opencode/plugins/ at startup — no
/// settings.json registration needed. install/uninstall run only from an
/// explicit user action in Settings; `migrateIfNeeded` also re-applies
/// automatically on launch when an older plugin version is detected.
@MainActor
final class OpencodeConfigInstaller {
    private let configDir: URL
    private var quackDir: URL { configDir.appendingPathComponent("quack") }
    var sessionsDirectory: URL { quackDir.appendingPathComponent("sessions") }
    private var pluginsDir: URL { configDir.appendingPathComponent("plugins") }
    private var pluginFile: URL { pluginsDir.appendingPathComponent("quack-notch.js") }

    init(configDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode")) {
        self.configDir = configDir
    }

    func isInstalled() -> Bool {
        (try? String(contentsOf: pluginFile, encoding: .utf8)) != nil
    }

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try OpencodeIntegrationScripts.pluginScript.write(to: pluginFile, atomically: true, encoding: .utf8)
    }

    /// Re-applies the integration when the shipped plugin content has drifted
    /// from an older install. Safe: overwriting is idempotent.
    func migrateIfNeeded() {
        guard isInstalled() else { return }
        let current = try? String(contentsOf: pluginFile, encoding: .utf8)
        guard current != OpencodeIntegrationScripts.pluginScript else { return }
        try? install()
    }

    func uninstall() throws {
        try? FileManager.default.removeItem(at: pluginFile)
        // sessions/ left in place: cheap, and a re-enable picks state right up.
    }
}
