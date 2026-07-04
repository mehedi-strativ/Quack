import Testing
import Foundation
@testable import QuackKit

@Suite struct ClaudeSettingsEditorTests {
    let hookCmd = "/Users/x/.claude/quack/hook.sh"
    let wrapperCmd = "/Users/x/.claude/quack/statusline-wrapper.sh"

    func obj(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func addsHooksAndWrapperPreservingUnknownKeys() throws {
        let input = Data(#"{"model":"sonnet","permissions":{"allow":["mcp__pencil"]},"statusLine":{"type":"command","command":"/Users/x/.claude/statusline.sh"}}"#.utf8)
        let (out, prev) = try ClaudeSettingsEditor.addingIntegration(to: input, hookCommand: hookCmd, statusLineCommand: wrapperCmd)
        let root = try obj(out)
        #expect(prev == "/Users/x/.claude/statusline.sh")
        #expect((root["model"] as? String) == "sonnet")
        #expect(((root["statusLine"] as? [String: Any])?["command"] as? String) == wrapperCmd)
        let hooks = root["hooks"] as! [String: Any]
        for event in ClaudeIntegrationScripts.hookEvents {
            let entries = hooks[event] as! [[String: Any]]
            let cmds = entries.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
            #expect(cmds.contains("\(hookCmd) \(event)"))
        }
        #expect(ClaudeSettingsEditor.integrationPresent(in: out))
    }

    @Test func addIsIdempotent() throws {
        let (once, _) = try ClaudeSettingsEditor.addingIntegration(to: Data("{}".utf8), hookCommand: hookCmd, statusLineCommand: wrapperCmd)
        let (twice, prev2) = try ClaudeSettingsEditor.addingIntegration(to: once, hookCommand: hookCmd, statusLineCommand: wrapperCmd)
        #expect(prev2 == nil)   // previous was already our wrapper -> not a restore target
        let hooks = try obj(twice)["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 1)
    }

    @Test func addPreservesForeignHooks() throws {
        let input = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/tool.sh"}]}]}}"#.utf8)
        let (out, _) = try ClaudeSettingsEditor.addingIntegration(to: input, hookCommand: hookCmd, statusLineCommand: wrapperCmd)
        let stop = (try obj(out)["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect(stop.count == 2)
    }

    @Test func removeRestoresStatusLineAndStripsOnlyOurs() throws {
        let input = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/tool.sh"}]}]},"model":"sonnet"}"#.utf8)
        let (added, prev) = try ClaudeSettingsEditor.addingIntegration(to: input, hookCommand: hookCmd, statusLineCommand: wrapperCmd)
        let removed = try ClaudeSettingsEditor.removingIntegration(from: added, restoringStatusLineCommand: prev)
        let root = try obj(removed)
        #expect(!ClaudeSettingsEditor.integrationPresent(in: removed))
        #expect(root["statusLine"] == nil)   // there was none before
        let stop = (root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect(stop.count == 1)             // foreign hook survives
        #expect((root["model"] as? String) == "sonnet")
    }

    @Test func removeRestoresPreviousCommand() throws {
        let input = Data(#"{"statusLine":{"type":"command","command":"/Users/x/.claude/statusline.sh"}}"#.utf8)
        let (added, prev) = try ClaudeSettingsEditor.addingIntegration(to: input, hookCommand: hookCmd, statusLineCommand: wrapperCmd)
        let removed = try ClaudeSettingsEditor.removingIntegration(from: added, restoringStatusLineCommand: prev)
        #expect(((try obj(removed)["statusLine"] as? [String: Any])?["command"] as? String) == "/Users/x/.claude/statusline.sh")
    }

    @Test func emptyOrMissingInputTreatedAsEmptyObject() throws {
        let (out, prev) = try ClaudeSettingsEditor.addingIntegration(to: Data(), hookCommand: hookCmd, statusLineCommand: wrapperCmd)
        #expect(prev == nil)
        #expect(ClaudeSettingsEditor.integrationPresent(in: out))
    }
}
