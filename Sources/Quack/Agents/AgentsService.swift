import Foundation
import Combine
import QuackKit

/// Reads the session files any installed agent-tool integration (Claude Code,
/// opencode, ...) writes and publishes reduced agent snapshots merged across
/// all of them — session IDs are per-tool-formatted and never collide, so
/// `AgentReducer` just sees one combined `[SessionFiles]`. Fail-soft: missing
/// directory or malformed files yield empty state, never a crash. A periodic
/// tick re-runs the staleness prune even when no file event arrives (an
/// abandoned session must eventually drop off the panel).
@MainActor
final class AgentsService: ObservableObject {
    @Published private(set) var agents: [AgentSnapshot] = []
    /// True when at least one source integration is installed — gates the
    /// notch panel's "enable an integration" CTA vs. the empty-state message.
    @Published private(set) var integrationInstalled = false

    /// One agent-tool integration's on-disk contract: where it writes state,
    /// and how to check/refresh its install.
    struct Source {
        let sessionsDirectory: URL
        let isInstalled: () -> Bool
        let migrateIfNeeded: () -> Void
    }

    private let sources: [Source]
    private var watchers: [ClaudeStateWatcher] = []
    private var pruneTimer: Timer?
    private var started = false

    init(sources: [Source]) {
        self.sources = sources
    }

    func start() {
        guard !started else { return }
        started = true
        sources.forEach { $0.migrateIfNeeded() }   // pick up new hook events for older installs
        integrationInstalled = sources.contains { $0.isInstalled() }
        watchers = sources.map { source in
            let watcher = ClaudeStateWatcher()
            watcher.onChange = { [weak self] in self?.refreshNow() }
            watcher.start(directory: source.sessionsDirectory)
            return watcher
        }
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
        watchers.forEach { $0.stop() }
        watchers = []
        pruneTimer?.invalidate(); pruneTimer = nil
        agents = []
    }

    func refreshNow() {
        integrationInstalled = sources.contains { $0.isInstalled() }
        let files = sources.flatMap { readSessionFiles(in: $0.sessionsDirectory) }
        let now = Date()
        agents = AgentReducer.snapshots(from: files, now: now)
    }

    private func readSessionFiles(in dir: URL) -> [SessionFiles] {
        let fm = FileManager.default
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
