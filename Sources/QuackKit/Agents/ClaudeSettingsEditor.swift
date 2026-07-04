import Foundation

/// Pure add/remove of Quack's Claude Code integration inside a settings.json
/// blob. All file IO lives in the app-layer installer; this is Data -> Data so
/// the exact mutation is unit-tested. Quack's entries are identified by the
/// hook-script path marker — nothing else is ever touched.
public enum ClaudeSettingsEditor {
    public static let hookMarker = "/.claude/quack/hook.sh"

    public static func integrationPresent(in json: Data) -> Bool {
        guard let root = decode(json), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains(where: isOurs)
        }
    }

    public static func addingIntegration(to json: Data, hookCommand: String,
                                         statusLineCommand: String) throws -> (updated: Data, previousStatusLineCommand: String?) {
        var root = decode(json) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in ClaudeIntegrationScripts.hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            if !entries.contains(where: isOurs) {
                entries.append(["hooks": [["type": "command", "command": "\(hookCommand) \(event)"]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks

        var previous: String?
        if let sl = root["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String, cmd != statusLineCommand {
            previous = cmd
        }
        root["statusLine"] = ["type": "command", "command": statusLineCommand]
        return (try encode(root), previous)
    }

    public static func removingIntegration(from json: Data,
                                           restoringStatusLineCommand previous: String?) throws -> Data {
        var root = decode(json) ?? [:]
        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll(where: isOurs)
                if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        if let previous, !previous.isEmpty {
            root["statusLine"] = ["type": "command", "command": previous]
        } else {
            root.removeValue(forKey: "statusLine")
        }
        return try encode(root)
    }

    // MARK: - Internals

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? [])
            .contains { (($0["command"] as? String) ?? "").contains(hookMarker) }
    }

    private static func decode(_ json: Data) -> [String: Any]? {
        guard !json.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
