import Foundation

/// One searchable settings control. `tabID` is the raw value of the UI-layer
/// tab enum (QuackKit stays UI-agnostic); `anchorID` identifies the section to
/// flash after jumping.
public struct SettingEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tabID: String
    public let section: String
    public let keywords: [String]

    public init(id: String, title: String, tabID: String, section: String, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.tabID = tabID
        self.section = section
        self.keywords = keywords
    }
}

/// Pure search over the settings registry. Rank: title prefix > title word
/// prefix > title substring > keyword prefix > keyword substring. Ties keep
/// registry order (stable sort) so results follow the sidebar's own order.
public enum SettingsSearch {
    public static func matches(_ query: String, in entries: [SettingEntry], limit: Int = 12) -> [SettingEntry] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let scored: [(SettingEntry, Int)] = entries.compactMap { e in
            guard let s = score(q, e) else { return nil }
            return (e, s)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func score(_ q: String, _ e: SettingEntry) -> Int? {
        let title = normalize(e.title)
        if title.hasPrefix(q) { return 100 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 80 }
        if title.contains(q) { return 60 }
        for k in e.keywords {
            let kw = normalize(k)
            if kw.hasPrefix(q) { return 40 }
            if kw.contains(q) { return 20 }
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
