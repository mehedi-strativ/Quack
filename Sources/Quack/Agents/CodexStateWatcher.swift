import Foundation

/// Polls Codex's date-partitioned rollout tree (recent day dirs only — see
/// `CodexSessionReader.recentRolloutFiles`) for changed JSONL files.
/// Codex appends to files rather than replacing directory entries, so a
/// recursive file signature is more reliable here than the existing
/// directory-only Claude watcher.
@MainActor
final class CodexStateWatcher {
    var onChange: (() -> Void)?

    private var directory: URL?
    private var timer: Timer?
    private var signature: Set<String> = []

    func start(directory: URL) {
        self.directory = directory
        poll()
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        directory = nil
        signature.removeAll()
    }

    private func poll() {
        guard directory != nil else { return }
        let next = fileSignature()
        guard next != signature else { return }
        signature = next
        onChange?()
    }

    private func fileSignature() -> Set<String> {
        var result = Set<String>()
        for url in CodexSessionReader.recentRolloutFiles() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let size = values?.fileSize ?? 0
            result.insert("\(url.path):\(modified):\(size)")
        }
        return result
    }
}
