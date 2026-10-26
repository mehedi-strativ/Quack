import Foundation
import Testing
@testable import QuackKit

/// Runs the real hook script against a temp HOME: the PermissionRequest path
/// must answer from a decision file, and must never wait when nobody listens.
@Suite(.serialized) struct PermissionHookTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("quack-hook-\(UUID().uuidString)")
    var quackDir: URL { home.appendingPathComponent(".claude/quack") }
    var sessions: URL { quackDir.appendingPathComponent("sessions") }

    static let jqAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")
        || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/jq")

    static let bashInput = #"{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"}]}"#
    static let questionInput = #"{"session_id":"s1","cwd":"/tmp/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one?","header":"Pick","options":[{"label":"A","description":"first"},{"label":"B","description":"second"}],"multiSelect":false}]}}"#

    /// Starts the hook; returns the process and its stdout pipe.
    func run(_ input: String = bashInput) throws -> (Process, Pipe) {
        let script = home.appendingPathComponent("hook.sh")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try ClaudeIntegrationScripts.hookScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "PermissionRequest"]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        return (p, stdout)
    }

    func waitForRequest() throws -> PermissionPrompt? {
        for _ in 0..<100 {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
            if let n = names.first(where: { $0.hasSuffix(".permission.json") }) {
                let data = try Data(contentsOf: sessions.appendingPathComponent(n))
                return try JSONDecoder().decode(PermissionPrompt.self, from: data)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    @Test(.enabled(if: jqAvailable)) func allowFromDecisionFile() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: quackDir, withIntermediateDirectories: true)
        try Data("\(getpid())".utf8).write(to: quackDir.appendingPathComponent("listening"))
        let (p, out) = try run()
        let req = try #require(try waitForRequest())
        #expect(req.tool_name == "Bash")
        #expect(req.summary == "rm -rf build")
        #expect(req.project == "proj")
        try Data(#"{"behavior":"allow"}"#.utf8)
            .write(to: sessions.appendingPathComponent("\(req.id).decision.json"))
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let decision = (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "allow")
        #expect(decision?["updatedPermissions"] == nil)
        // Request and decision files are cleaned up.
        let left = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
        #expect(!left.contains { $0.hasSuffix(".permission.json") || $0.hasSuffix(".decision.json") })
    }

    /// Runs one request through to a decision; returns the hook's decision object.
    func decide(_ input: String, _ body: String) throws -> (PermissionPrompt, [String: Any]?) {
        try FileManager.default.createDirectory(at: quackDir, withIntermediateDirectories: true)
        try Data("\(getpid())".utf8).write(to: quackDir.appendingPathComponent("listening"))
        let (p, out) = try run(input)
        let req = try #require(try waitForRequest())
        try Data(body.utf8).write(to: sessions.appendingPathComponent("\(req.id).decision.json"))
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (req, (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
    }

    @Test(.enabled(if: jqAvailable)) func dontAskAgainEchoesClaudesSuggestion() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (req, decision) = try decide(Self.bashInput, #"{"behavior":"allow","suggestion":0}"#)
        #expect(req.options.map(\.label) == ["Yes", "Yes, and don't ask again for `rm -rf build` commands in proj",
                                              "No, and tell Claude what to do differently"])
        let updates = decision?["updatedPermissions"] as? [[String: Any]]
        #expect(updates?.first?["type"] as? String == "addRules")
        #expect(updates?.first?["destination"] as? String == "localSettings")
    }

    @Test(.enabled(if: jqAvailable)) func denyCarriesTypedMessage() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (_, decision) = try decide(Self.bashInput, #"{"behavior":"deny","message":"use trash instead"}"#)
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "use trash instead")
    }

    @Test(.enabled(if: jqAvailable)) func answersQuestionViaUpdatedInput() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (req, decision) = try decide(Self.questionInput, #"{"behavior":"allow","answers":{"Pick one?":"B"}}"#)
        #expect(req.questions?.first?.options.map(\.label) == ["A", "B"])
        let input = decision?["updatedInput"] as? [String: Any]
        #expect((input?["answers"] as? [String: String]) == ["Pick one?": "B"])
        #expect((input?["questions"] as? [Any])?.count == 1)   // Claude's own input kept
    }

    @Test(.enabled(if: jqAvailable)) func askFallsBackSilently() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: quackDir, withIntermediateDirectories: true)
        try Data("\(getpid())".utf8).write(to: quackDir.appendingPathComponent("listening"))
        let (p, out) = try run()
        let req = try #require(try waitForRequest())
        try Data(#"{"behavior":"ask"}"#.utf8)
            .write(to: sessions.appendingPathComponent("\(req.id).decision.json"))
        p.waitUntilExit()
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test(.enabled(if: jqAvailable)) func noListenerNeverWaits() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let start = Date()
        let (p, out) = try run()
        p.waitUntilExit()
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
        // State is still recorded for the agent card.
        #expect(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("s1.state.json").path))
    }
}
