import Foundation
import QuackKit

enum CodexSessionReader {
    static let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: sessionsDirectory.path)
    }

    /// Rollout files in the YYYY/MM/DD dirs for yesterday…tomorrow (tomorrow
    /// covers a UTC-dated tree west of UTC). Codex keeps every rollout forever,
    /// so walking the whole tree on each poll grows without bound, while only
    /// files touched in the last `defaultStaleAfter` can yield a snapshot.
    /// ponytail: a single session running >1 day in an older dir drops off;
    /// widen `days` if that matters.
    static func recentRolloutFiles(now: Date = Date(), days: ClosedRange<Int> = -1...1) -> [URL] {
        let fm = FileManager.default
        let calendar = Calendar.current
        return days.flatMap { offset -> [URL] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return [] }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = sessionsDirectory.appendingPathComponent(
                String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), isDirectory: true)
            let urls = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            return urls.filter { $0.pathExtension == "jsonl" }
        }
    }

    static func snapshots(now: Date) -> [AgentSnapshot] {
        var result: [AgentSnapshot] = []
        for url in recentRolloutFiles(now: now) {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ), let modified = values.contentModificationDate else { continue }
            guard now.timeIntervalSince(modified) <= AgentReducer.defaultStaleAfter else { continue }
            guard let lines = readSampleLines(from: url) else { continue }
            let fallbackID = url.deletingPathExtension().lastPathComponent
            if let snapshot = CodexSessionReducer.snapshot(
                from: lines,
                fallbackSessionID: fallbackID,
                modifiedAt: modified,
                now: now
            ) {
                result.append(snapshot)
            }
        }
        return result
    }

    private static func readSampleLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let maxSample = 256 * 1024
        let headSize = 32 * 1024
        let tailSize = maxSample - headSize
        guard let fileSize = try? handle.seekToEnd() else { return nil }

        let data: Data
        if fileSize <= UInt64(maxSample) {
            try? handle.seek(toOffset: 0)
            data = handle.readDataToEndOfFile()
        } else {
            try? handle.seek(toOffset: 0)
            let head = handle.readData(ofLength: headSize)
            try? handle.seek(toOffset: fileSize - UInt64(tailSize))
            let tail = handle.readDataToEndOfFile()
            var sample = Data()
            sample.append(head)
            sample.append(tail)
            data = sample
        }
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}
