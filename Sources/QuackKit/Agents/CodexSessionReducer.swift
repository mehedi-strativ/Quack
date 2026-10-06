import Foundation

/// Reduces one Codex Desktop/CLI rollout JSONL file into the same display
/// snapshot used by the notch's Claude and opencode integrations.
///
/// Codex rollouts contain user messages and encrypted reasoning. This reducer
/// deliberately ignores both and only surfaces safe operational state:
/// project, model, tool activity, task state, and usage percentages.
public enum CodexSessionReducer {
    public static func snapshot(
        from lines: [String],
        fallbackSessionID: String,
        modifiedAt: Date,
        now: Date,
        staleAfter: TimeInterval = AgentReducer.defaultStaleAfter
    ) -> AgentSnapshot? {
        var sessionID = fallbackSessionID
        var projectPath: String?
        var model: String?
        var lastUpdate = modifiedAt
        var status: AgentStatus = .idle
        var statusMessage: String?
        var progress: Double?
        var contextUsedPercent: Double?
        var modelContextWindow: Double?
        var fiveHourUsedPercent: Double?
        var sevenDayUsedPercent: Double?
        var sawTask = false

        for line in lines {
            guard let object = jsonObject(from: line) else { continue }
            let timestamp = (object["timestamp"] as? String).flatMap(ISO8601Parse.date(from:))
                ?? lastUpdate
            if timestamp > lastUpdate { lastUpdate = timestamp }

            let rootType = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]

            switch rootType {
            case "session_meta":
                sessionID = (payload["id"] as? String)
                    ?? (payload["session_id"] as? String)
                    ?? sessionID
                projectPath = (payload["cwd"] as? String) ?? projectPath
            case "turn_context":
                projectPath = (payload["cwd"] as? String) ?? projectPath
                model = (payload["model"] as? String) ?? model
                modelContextWindow = number(payload["model_context_window"]) ?? modelContextWindow
            case "event_msg":
                reduceEvent(
                    payload,
                    status: &status,
                    statusMessage: &statusMessage,
                    progress: &progress,
                    contextUsedPercent: &contextUsedPercent,
                    modelContextWindow: modelContextWindow,
                    fiveHourUsedPercent: &fiveHourUsedPercent,
                    sevenDayUsedPercent: &sevenDayUsedPercent,
                    sawTask: &sawTask
                )
            case "response_item":
                reduceResponseItem(payload, status: &status, statusMessage: &statusMessage)
            default:
                break
            }
        }

        guard sawTask else { return nil }
        guard now.timeIntervalSince(lastUpdate) <= staleAfter else { return nil }

        let project = projectPath
            .map { ($0 as NSString).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "Codex"
        return AgentSnapshot(
            sessionID: "codex-\(sessionID)",
            project: project,
            branch: nil,
            model: model,
            status: status,
            statusMessage: statusMessage ?? (status == .working ? "Working in Codex" : "Ready"),
            progress: progress,
            contextUsedPercent: contextUsedPercent,
            costUSD: nil,
            fiveHourUsedPercent: fiveHourUsedPercent,
            sevenDayUsedPercent: sevenDayUsedPercent,
            lastUpdate: lastUpdate,
            hostPID: nil
        )
    }

    private static func reduceEvent(
        _ payload: [String: Any],
        status: inout AgentStatus,
        statusMessage: inout String?,
        progress: inout Double?,
        contextUsedPercent: inout Double?,
        modelContextWindow: Double?,
        fiveHourUsedPercent: inout Double?,
        sevenDayUsedPercent: inout Double?,
        sawTask: inout Bool
    ) {
        switch payload["type"] as? String {
        case "task_started":
            status = .working
            statusMessage = "Working in Codex"
            sawTask = true
        case "task_complete":
            status = .idle
            statusMessage = "Ready"
            sawTask = true
        case "item_started", "item_completed":
            if status == .working, let item = payload["item"] as? [String: Any] {
                statusMessage = itemMessage(item)
            }
        case "token_count":
            guard let info = payload["info"] as? [String: Any] else { return }
            if let last = info["last_token_usage"] as? [String: Any],
               let tokens = number(last["total_tokens"]),
               let window = modelContextWindow
                    ?? number(payload["model_context_window"])
                    ?? number(info["model_context_window"]),
               window > 0 {
                let used = min(max(tokens / window, 0), 1)
                progress = used
                contextUsedPercent = used * 100
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                fiveHourUsedPercent = percent(limits["primary"])
                sevenDayUsedPercent = percent(limits["secondary"])
            }
        default:
            break
        }
    }

    private static func reduceResponseItem(
        _ payload: [String: Any],
        status: inout AgentStatus,
        statusMessage: inout String?
    ) {
        guard status == .working else { return }
        switch payload["type"] as? String {
        case "function_call", "custom_tool_call":
            let name = payload["name"] as? String
            statusMessage = toolMessage(name: name)
        case "message":
            if payload["role"] as? String == "assistant" {
                statusMessage = "Writing response"
            }
        default:
            break
        }
    }

    private static func itemMessage(_ item: [String: Any]) -> String {
        switch item["type"] as? String {
        case "CommandExecution":
            return "Running a command"
        case "Reasoning":
            return "Thinking through the task"
        case "AgentMessage":
            return "Writing response"
        case "FunctionCall", "McpToolCall", "CustomToolCall":
            return "Using a tool"
        default:
            return "Working in Codex"
        }
    }

    private static func toolMessage(name: String?) -> String {
        switch name {
        case "exec", "exec_command":
            return "Running a command"
        case "web", "web_search":
            return "Browsing the web"
        case "image_gen":
            return "Generating an image"
        case "apply_patch":
            return "Editing files"
        default:
            return name.map { "Using \($0)" } ?? "Using a tool"
        }
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any], let used = number(object["used_percent"]) else {
            return nil
        }
        return min(max(used, 0), 100)
    }
}
