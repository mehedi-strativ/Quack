import Foundation
import Combine
import QuackKit

/// Reads the session files the Claude Code integration writes and publishes
/// reduced agent snapshots + usage limits. Fail-soft: missing directory or
/// malformed files yield empty state, never a crash. A periodic tick re-runs
/// the staleness prune even when no file event arrives (an abandoned session
/// must eventually drop off the panel).
@MainActor
final class ClaudeAgentsService: ObservableObject {
    @Published private(set) var agents: [AgentSnapshot] = []
    @Published private(set) var usage: UsageLimits?
    @Published private(set) var integrationInstalled = false

    private let installer: ClaudeConfigInstaller
    private let watcher = ClaudeStateWatcher()
    private var pruneTimer: Timer?
    private var started = false

    init(installer: ClaudeConfigInstaller) {
        self.installer = installer
    }

    func start() {
        guard !started else { return }
        started = true
        integrationInstalled = installer.isInstalled()
        watcher.onChange = { [weak self] in self?.refreshNow() }
        watcher.start(directory: installer.sessionsDirectory)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
        refreshNow()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.stop()
        watcher.onChange = nil
        pruneTimer?.invalidate(); pruneTimer = nil
        agents = []; usage = nil
    }

    func refreshNow() {
        integrationInstalled = installer.isInstalled()
        let files = readSessionFiles()
        let now = Date()
        agents = AgentReducer.snapshots(from: files, now: now)
        usage = AgentReducer.usageLimits(from: files)
    }

    private func readSessionFiles() -> [SessionFiles] {
        let fm = FileManager.default
        let dir = installer.sessionsDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        var ids = Set<String>()
        for n in names {
            if n.hasSuffix(".state.json") { ids.insert(String(n.dropLast(".state.json".count))) }
            if n.hasSuffix(".status.json") { ids.insert(String(n.dropLast(".status.json".count))) }
        }
        return ids.map { id in
            let stateURL = dir.appendingPathComponent("\(id).state.json")
            let statusURL = dir.appendingPathComponent("\(id).status.json")
            return SessionFiles(
                sessionID: id,
                state: (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(StateFileRaw.self, from: $0) },
                status: (try? Data(contentsOf: statusURL)).flatMap { try? decoder.decode(StatusFileRaw.self, from: $0) },
                stateModified: modificationDate(of: stateURL),
                statusModified: modificationDate(of: statusURL)
            )
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
