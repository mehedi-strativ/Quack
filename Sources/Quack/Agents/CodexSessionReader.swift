import Foundation
import QuackKit

enum CodexSessionReader {
    static let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: sessionsDirectory.path)
    }

    static func snapshots(now: Date) -> [AgentSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [AgentSnapshot] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
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
