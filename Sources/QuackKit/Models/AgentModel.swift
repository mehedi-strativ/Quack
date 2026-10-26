import Foundation

/// Status of one Claude Code agent session as shown in the notch panel.
public enum AgentStatus: String, Codable, Sendable {
    case working
    case needsYou = "needs_you"
    case idle
}

/// One agent card: the reduced, display-ready view of a Claude Code session.
public struct AgentSnapshot: Equatable, Sendable, Identifiable {
    public var id: String { sessionID }
    public let sessionID: String
    public let project: String
    public let branch: String?
    public let model: String?
    public let status: AgentStatus
    public let statusMessage: String?
    /// 0...1 (TodoWrite ratio, else context-window fraction), nil = hide meter.
    public let progress: Double?
    /// This session's own context-window usage, 0...100 (from statusLine JSON).
    public let contextUsedPercent: Double?
    /// This session's own cumulative cost in USD (from statusLine JSON).
    public let costUSD: Double?
    /// This session's own 5h rate-limit window usage, 0...100.
    public let fiveHourUsedPercent: Double?
    /// This session's own 7d rate-limit window usage, 0...100.
    public let sevenDayUsedPercent: Double?
    public let lastUpdate: Date
    /// pid of the GUI app hosting this session (Terminal, iTerm2, VS Code,
    /// Claude desktop, ...), captured by the SessionStart hook's parent-chain
    /// walk. nil when unknown or the hook predates this field.
    public let hostPID: Int?

    public init(sessionID: String, project: String, branch: String?, model: String?,
                status: AgentStatus, statusMessage: String?, progress: Double?,
                contextUsedPercent: Double?, costUSD: Double?, fiveHourUsedPercent: Double?,
                sevenDayUsedPercent: Double?, lastUpdate: Date, hostPID: Int?) {
        self.sessionID = sessionID
        self.project = project
        self.branch = branch
        self.model = model
        self.status = status
        self.statusMessage = statusMessage
        self.progress = progress
        self.contextUsedPercent = contextUsedPercent
        self.costUSD = costUSD
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.sevenDayUsedPercent = sevenDayUsedPercent
        self.lastUpdate = lastUpdate
        self.hostPID = hostPID
    }
}

/// On-disk shape of ~/.claude/quack/sessions/<id>.state.json (written by
/// hook.sh). Every field optional — hooks are fail-soft and versions drift.
public struct StateFileRaw: Decodable, Equatable, Sendable {
    public let session_id: String?
    public let status: String?
    public let event: String?
    public let cwd: String?
    public let project: String?
    public let branch: String?
    public let ts: String?
    public let last_tool: String?
    public let last_tool_target: String?
    public let last_assistant_line: String?
    public let notification_message: String?
    public let todos_completed: Int?
    public let todos_total: Int?
    /// Model id captured from the transcript by the Stop hook (e.g. "claude-fable-5").
    public let model_id: String?
    /// pid of the GUI app hosting this session, captured at SessionStart.
    public let host_pid: Int?
    /// Name of the GUI app hosting this session (e.g. "Terminal"), captured at SessionStart.
    public let host_app: String?
}

/// On-disk shape of <id>.status.json — the raw Claude Code statusLine JSON.
/// Decoded defensively: only the fields the panel needs, all optional.
public struct StatusFileRaw: Decodable, Sendable {
    public struct Model: Decodable, Sendable { public let display_name: String? }
    public struct ContextWindow: Decodable, Sendable { public let used_percentage: Double? }

    /// One rate-limit window. `resets_at` arrives as an epoch-seconds number
    /// (the real path, per Claude Code's statusline docs) or, defensively, an
    /// ISO-8601 string — accept both.
    public struct RateWindow: Decodable, Sendable {
        public let used_percentage: Double?
        public let resetsAtDate: Date?

        enum CodingKeys: String, CodingKey { case used_percentage, resets_at }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            used_percentage = try? c.decodeIfPresent(Double.self, forKey: .used_percentage)
            if let epoch = try? c.decodeIfPresent(Double.self, forKey: .resets_at) {
                resetsAtDate = Date(timeIntervalSince1970: epoch)
            } else if let iso = try? c.decodeIfPresent(String.self, forKey: .resets_at) {
                resetsAtDate = ISO8601Parse.date(from: iso)
            } else {
                resetsAtDate = nil
            }
        }
    }

    public struct RateLimits: Decodable, Sendable {
        public let five_hour: RateWindow?
        public let seven_day: RateWindow?
    }

    public struct Cost: Decodable, Sendable { public let total_cost_usd: Double? }

    public let session_id: String?
    public let model: Model?
    public let context_window: ContextWindow?
    public let rate_limits: RateLimits?
    public let cost: Cost?
}

/// Shared defensive ISO-8601 parsing (with and without fractional seconds).
public enum ISO8601Parse {
    public static func date(from string: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: string) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: string)
    }
}

/// A tool-permission request the PermissionRequest hook is holding open,
/// waiting for an answer from the notch panel. On-disk shape of
/// ~/.claude/quack/sessions/<id>.permission.json (written by hook.sh).
public struct PermissionPrompt: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let session_id: String
    public let tool_name: String
    /// What the tool will do: the Bash command, the file path, the URL...
    public let summary: String?
    public let project: String?
    public let cwd: String?
    /// Claude Code's own `permission_suggestions` (the "don't ask again" options).
    public let suggestions: [PermissionSuggestion]?
    /// AskUserQuestion's questions; non-empty means "answer", not "allow".
    public let questions: [AskQuestion]?
    /// Unix seconds when the hook started waiting.
    public let ts: Double

    public init(id: String, session_id: String, tool_name: String, summary: String? = nil,
                project: String? = nil, cwd: String? = nil,
                suggestions: [PermissionSuggestion]? = nil, questions: [AskQuestion]? = nil, ts: Double) {
        self.id = id
        self.session_id = session_id
        self.tool_name = tool_name
        self.summary = summary
        self.project = project
        self.cwd = cwd
        self.suggestions = suggestions
        self.questions = questions
        self.ts = ts
    }

    /// The choices Claude Code offers, in its order and wording: Yes, one
    /// "Yes, and ..." per allow-type suggestion, then No. Suggestion kinds
    /// that don't grant anything (remove/deny rules) are skipped.
    public var options: [PermissionOption] {
        var out = [PermissionOption(label: "Yes", decision: .allow(suggestion: nil))]
        for (i, s) in (suggestions ?? []).enumerated() {
            if let label = s.label(project: project) {
                out.append(PermissionOption(label: label, decision: .allow(suggestion: i)))
            }
        }
        out.append(PermissionOption(label: "No, and tell Claude what to do differently",
                                    decision: .deny(message: nil)))
        return out
    }
}

/// One AskUserQuestion question with Claude's 2-4 choices.
public struct AskQuestion: Decodable, Equatable, Sendable, Identifiable {
    public struct Option: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { label }
        public let label: String
        public let description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }
    public var id: String { question }
    public let question: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool?

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool? = nil) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// One entry of Claude Code's `permission_suggestions` / `updatedPermissions`.
/// Every field optional: only the shape Quack labels is read; the hook sends
/// Claude's original entry back untouched.
public struct PermissionSuggestion: Decodable, Equatable, Sendable {
    public struct Rule: Decodable, Equatable, Sendable {
        public let toolName: String?
        public let ruleContent: String?
    }
    public let type: String?
    public let rules: [Rule]?
    public let behavior: String?
    public let mode: String?
    public let directories: [String]?
    public let destination: String?

    public init(type: String?, rules: [Rule]? = nil, behavior: String? = nil, mode: String? = nil,
                directories: [String]? = nil, destination: String? = nil) {
        self.type = type
        self.rules = rules
        self.behavior = behavior
        self.mode = mode
        self.directories = directories
        self.destination = destination
    }

    func label(project: String?) -> String? {
        let scope: String
        switch destination {
        case "session": scope = " during this session"
        case "localSettings", "projectSettings": scope = project.map { " in \($0)" } ?? " in this project"
        default: scope = ""
        }
        switch type {
        case "addRules" where behavior == "allow":
            let names = (rules ?? []).map { r -> String in
                let tool = r.toolName ?? "this tool"
                guard let content = r.ruleContent, !content.isEmpty else { return tool }
                return tool == "Bash" ? "`\(content)` commands" : "\(tool)(\(content))"
            }
            guard !names.isEmpty else { return nil }
            return "Yes, and don't ask again for \(names.joined(separator: ", "))\(scope)"
        case "setMode":
            guard let mode else { return nil }
            if mode == "acceptEdits" {
                return destination == "session" ? "Yes, allow all edits during this session" : "Yes, and allow all edits\(scope)"
            }
            return "Yes, and switch to \(mode) mode\(scope)"
        case "addDirectories":
            guard let dirs = directories, !dirs.isEmpty else { return nil }
            return "Yes, and always allow access to \(dirs.joined(separator: ", "))\(scope)"
        default:
            return nil
        }
    }
}

/// One row of a permission card.
public struct PermissionOption: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let decision: PermissionDecision
}

/// The panel's answer, written to <id>.decision.json for the waiting hook.
public enum PermissionDecision: Equatable, Sendable {
    /// `suggestion` indexes the prompt's `suggestions` ("Yes, and don't ask again").
    case allow(suggestion: Int?)
    /// `message` is the user's "what to do differently" text, if any.
    case deny(message: String?)
    /// AskUserQuestion answers: question text -> chosen label(s) or own text
    /// (multi-select labels joined with ", ", per the Agent SDK contract).
    case answer([String: String])
    /// Give up waiting and show Claude Code's own prompt in the terminal.
    case ask

    /// Body of the decision file the hook reads.
    public var fileBody: [String: Any] {
        switch self {
        case .allow(let i): return i.map { ["behavior": "allow", "suggestion": $0] } ?? ["behavior": "allow"]
        case .deny(let m): return m.flatMap { $0.isEmpty ? nil : ["behavior": "deny", "message": $0] } ?? ["behavior": "deny"]
        case .answer(let a): return ["behavior": "allow", "answers": a]
        case .ask: return ["behavior": "ask"]
        }
    }
}
