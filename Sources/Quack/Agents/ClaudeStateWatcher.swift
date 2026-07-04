import Foundation

/// Watches ~/.claude/quack/sessions/ for changes via a kqueue-backed
/// DispatchSource on the directory fd. The hook scripts always write tmp+mv,
/// so every update mutates a directory entry and fires a .write event here —
/// no per-file watches needed. Debounced: bursts (statusLine fires often)
/// collapse into one onChange. If the directory doesn't exist yet, retries
/// every few seconds until it does. No event tap, no run-loop source.
@MainActor
final class ClaudeStateWatcher {
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var directory: URL?

    func start(directory: URL) {
        self.directory = directory
        attach()
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        debounce?.cancel(); debounce = nil
        source?.cancel(); source = nil
        directory = nil
    }

    private func attach() {
        guard source == nil, let directory else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { scheduleRetry(); return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .link, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                // Directory replaced (e.g. uninstall/reinstall) — reattach.
                self.source?.cancel(); self.source = nil
                self.scheduleRetry()
            }
            self.fireDebounced()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        fireDebounced()   // initial read
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.source != nil { self.retryTimer?.invalidate(); self.retryTimer = nil; return }
                self.attach()
                if self.source != nil { self.retryTimer?.invalidate(); self.retryTimer = nil }
            }
        }
    }

    private func fireDebounced() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
