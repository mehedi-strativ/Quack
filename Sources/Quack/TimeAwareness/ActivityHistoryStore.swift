import Foundation
import QuackKit

/// Loads/saves the activity history JSON under Application Support. All
/// failures degrade to "no history" — never crash, one log line.
@MainActor
final class ActivityHistoryStore {
    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Quack", isDirectory: true)
            .appendingPathComponent("activity-history.json")
    }

    func load() -> ActivityHistory {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else {
            return ActivityHistory()   // first run / missing file
        }
        do {
            return try JSONDecoder().decode(ActivityHistory.self, from: data)
        } catch {
            Log.time.error("history decode failed — starting fresh: \(error.localizedDescription)")
            return ActivityHistory()
        }
    }

    func save(_ history: ActivityHistory) {
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.time.error("history save failed: \(error.localizedDescription)")
        }
    }
}
