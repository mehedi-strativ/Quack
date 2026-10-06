import Foundation

/// Polls Codex's date-partitioned rollout tree for changed JSONL files.
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
        guard let directory else { return }
        let next = fileSignature(in: directory)
        guard next != signature else { return }
        signature = next
        onChange?()
    }

    private func fileSignature(in directory: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let size = values?.fileSize ?? 0
            result.insert("\(url.path):\(modified):\(size)")
        }
        return result
    }
}
