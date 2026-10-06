import Foundation
import Testing
@testable import QuackKit

@Suite struct CodexSessionReducerTests {
    @Test func reducesWorkingRolloutWithoutExposingPromptText() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let lines = [
            #"{"timestamp":"2023-11-14T22:13:20Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/Users/me/Quack"}}"#,
            #"{"timestamp":"2023-11-14T22:13:21Z","type":"turn_context","payload":{"cwd":"/Users/me/Quack","model":"gpt-5.6-luna","model_context_window":1000}}"#,
            #"{"timestamp":"2023-11-14T22:13:22Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2023-11-14T22:13:23Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec"}}"#,
            #"{"timestamp":"2023-11-14T22:13:24Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":250}},"rate_limits":{"primary":{"used_percent":12},"secondary":{"used_percent":4}}}}"#,
        ]

        let snapshot = CodexSessionReducer.snapshot(
            from: lines,
            fallbackSessionID: "fallback",
            modifiedAt: now,
            now: now.addingTimeInterval(1)
        )

        #expect(snapshot?.sessionID == "codex-thread-1")
        #expect(snapshot?.project == "Quack")
        #expect(snapshot?.model == "gpt-5.6-luna")
        #expect(snapshot?.status == .working)
        #expect(snapshot?.statusMessage == "Running a command")
        #expect(snapshot?.progress == 0.25)
        #expect(snapshot?.fiveHourUsedPercent == 12)
        #expect(snapshot?.sevenDayUsedPercent == 4)
    }

    @Test func latestTaskCompletionLeavesRecentSessionIdle() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let lines = [
            #"{"timestamp":"2023-11-14T22:13:20Z","type":"session_meta","payload":{"id":"thread-2","cwd":"/Users/me/Quack"}}"#,
            #"{"timestamp":"2023-11-14T22:13:21Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2023-11-14T22:13:22Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ]

        let snapshot = CodexSessionReducer.snapshot(
            from: lines,
            fallbackSessionID: "fallback",
            modifiedAt: now,
            now: now.addingTimeInterval(1)
        )

        #expect(snapshot?.status == .idle)
        #expect(snapshot?.statusMessage == "Ready")
    }
}
