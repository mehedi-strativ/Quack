import Foundation
import Combine
import QuackKit

/// Reads the session files Quack's Claude Code hooks write and publishes
/// reduced agent snapshots. Fail-soft: missing
/// directory or malformed files yield empty state, never a crash. A periodic
/// tick re-runs the staleness prune even when no file event arrives (an
/// abandoned session must eventually drop off the panel).
@MainActor
final class AgentsService: ObservableObject {
    @Published private(set) var agents: [AgentSnapshot] = []
    /// True when the Claude integration is installed — gates the notch
    /// panel's "enable the integration" CTA vs. the empty-state message.
    @Published private(set) var integrationInstalled = false
    /// Permission requests the hook is holding open for a panel answer.
    @Published private(set) var permissions: [PermissionPrompt] = []
    /// While true (and started), the `listening` file tells the hook to hold
    /// PermissionRequests for the panel instead of showing the terminal prompt.
    var answersPermissions = false {
        didSet { updateListening() }
    }

    /// Sessions marked "Seen". Stays seen through idle follow-ups (Claude's
    /// "waiting for your input" notification) and clears once the session
    /// works again or asks something. In memory only.
    private var seen: Set<String> = []

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
        installer.migrateIfNeeded()   // pick up new hook events for older installs
        watcher.onChange = { [weak self] in self?.refreshNow() }
        watcher.start(directory: installer.sessionsDirectory)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
        updateListening()
        refreshNow()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.stop()
        pruneTimer?.invalidate(); pruneTimer = nil
        updateListening()
        agents = []
        permissions = []
    }

    /// Clears a session's needs-you until it works again or asks something.
    func markSeen(_ agent: AgentSnapshot) {
        seen.insert(agent.sessionID)
        refreshNow()
    }

    /// Answers a held request; the hook polls for this file. Atomic write so
    /// the hook never reads half a file.
    func answer(_ prompt: PermissionPrompt, _ decision: PermissionDecision) {
        let url = installer.sessionsDirectory.appendingPathComponent("\(prompt.id).decision.json")
        var body = decision.fileBody
        body["id"] = prompt.id
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            try? data.write(to: url, options: .atomic)
        }
        permissions.removeAll { $0.id == prompt.id }
    }

    /// The hook only waits when this file names a live pid, so a quit or
    /// crashed Quack never holds Claude Code's prompt hostage.
    private func updateListening() {
        let url = installer.listeningFile
        if started && answersPermissions {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("\(getpid())".utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func refreshNow() {
        integrationInstalled = installer.isInstalled()
        let files = readSessionFiles(in: installer.sessionsDirectory)
        let snapshots = AgentReducer.snapshots(from: files, now: Date())
        permissions = readPermissions(in: installer.sessionsDirectory)
        let asking = Set(permissions.map(\.session_id))
        seen = seen.filter { id in
            snapshots.contains { $0.sessionID == id && $0.status == .needsYou } && !asking.contains(id)
        }
        agents = sort(snapshots.map { seen.contains($0.sessionID) ? $0.with(status: .idle) : $0 })
    }

    /// Pending requests, oldest first. Drops ones past the hook's wait limit
    /// (the hook has given up and handed back to the terminal).
    private func readPermissions(in dir: URL) -> [PermissionPrompt] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        let cutoff = Date().timeIntervalSince1970 - ClaudeIntegrationScripts.permissionWaitSeconds
        return names
            .filter { $0.hasSuffix(".permission.json") }
            .compactMap { n in
                (try? Data(contentsOf: dir.appendingPathComponent(n)))
                    .flatMap { try? decoder.decode(PermissionPrompt.self, from: $0) }
            }
            .filter { $0.ts > cutoff }
            .sorted { $0.ts < $1.ts }
    }

    private func sort(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        agents.sorted { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            return a.lastUpdate > b.lastUpdate
        }
    }

    private func rank(_ status: AgentStatus) -> Int {
        switch status {
        case .needsYou: return 0
        case .working: return 1
        case .idle: return 2
        }
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
