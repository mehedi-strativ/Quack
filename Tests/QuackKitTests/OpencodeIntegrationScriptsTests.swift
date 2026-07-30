import Testing
@testable import QuackKit

@Suite struct OpencodeIntegrationScriptsTests {
    @Test func pluginScriptShape() {
        let s = OpencodeIntegrationScripts.pluginScript
        #expect(s.contains("export const QuackNotchPlugin"))
        #expect(s.contains(".state.json"))
        #expect(s.contains("quack/sessions"))
        #expect(s.contains("session.idle"))
        #expect(s.contains("session.status"))
        #expect(s.contains("session.error"))
        #expect(s.contains("tool.execute.before"))
        #expect(s.contains("tool.execute.after"))
    }

    @Test func writesStateFileShapeCompatibleWithAgentReducer() {
        // Same field vocabulary as StateFileRaw: status/event tokens the
        // shared reducer recognizes, so both integrations render identically.
        let s = OpencodeIntegrationScripts.pluginScript
        #expect(s.contains(#"status: "working""#))
        #expect(s.contains(#"status: "idle""#))
        #expect(s.contains(#"status: "needs_you""#))
        #expect(s.contains(#"status: "ended""#))
        #expect(s.contains(#"event: "PreToolUse""#))
        #expect(s.contains(#"event: "PermissionRequest""#))
        #expect(s.contains(#"event: "Notification""#))
    }

    @Test func everyHookBodyIsWrappedFailSoft() {
        // A thrown error inside "tool.execute.before" aborts the tool call —
        // count try/catch blocks to make sure every hook guards its body.
        let s = OpencodeIntegrationScripts.pluginScript
        #expect(s.components(separatedBy: "try {").count - 1 >= 6)
        #expect(s.components(separatedBy: "} catch {}").count - 1 >= 6)
    }
}
