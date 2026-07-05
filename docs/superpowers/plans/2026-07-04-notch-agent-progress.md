# Notch Claude Agent Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Claude Code agent progress (status cards, usage limits, needs-you peek) in the MacBook notch panel, unified with the existing media player.

**Architecture:** Claude Code hooks + a statusLine wrapper (installed into `~/.claude/settings.json` with explicit user consent) push per-session state files into `~/.claude/quack/sessions/`. Quack watches that directory, reduces the files to `AgentSnapshot`s + `UsageLimits` in pure QuackKit logic, and renders them in the single notch panel — agents on top, the media player as a compact strip pinned at the bottom. One service (`NotchService`, refactored from `NotchMediaService`) owns the one panel and its three states: peek / collapsed / expanded.

**Tech Stack:** Swift 5.9 SwiftPM (no Xcode project), SwiftUI + AppKit, swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`), bash+jq hook scripts, SQLite3 C API (optional usage.db enrichment).

**Spec:** `docs/superpowers/specs/2026-07-04-notch-agent-progress-design.md`

## Global Constraints

- macOS floor: `.macOS(.v13)` (Package.swift) — notch APIs are 12+.
- **Zero remote SwiftPM dependencies.** Everything vendored or hand-written.
- **No CGEvent taps anywhere in this feature** (CLAUDE.md freeze rules do not apply — but never add a tap "for convenience").
- QuackKit target = pure, side-effect-free, fully unit-tested. App target = `swift build` + manual verify (no unit tests), matching the codebase.
- Tests use swift-testing: `import Testing`, `@Suite struct`, `@Test func`, `#expect(...)`.
- `swift build` only compiles; **the running app is `/Applications/Quack.app`** — run `./Scripts/install.sh` to see changes. Don't run install.sh right after the user grants a TCC permission (this feature needs none, but the media player coexists).
- If the build fails with `accessing build database ... build.db: disk I/O error` → `rm -rf .build` and retry. If it persists in a sandboxed shell, run the build command with sandbox disabled.
- Shell scripts target macOS BSD userland: `tail -r` not `tac`, `date -u +%Y-%m-%dT%H:%M:%SZ`, bash 3.2 compatible (no `${var,,}`, no associative arrays).
- Nothing is written to `~/.claude` by the app except through `ClaudeConfigInstaller` after the user clicks "Enable Claude integration" (Task 2's manual checkpoint has its own explicit consent gate).
- Panel geometry rule: anchor panel top at `layout.cocoaNotchRect.minY`, hang content **down**. Never place content behind the physical cutout.
- Work on branch `notch-agents` (exists; spec committed).

## File Structure (end state)

```
Sources/QuackKit/
  Models/AgentModel.swift            AgentStatus, AgentSnapshot, UsageLimits,
                                     StateFileRaw, StatusFileRaw (decode types)
  Agents/AgentReducer.swift          pure merge/derive/prune/sort
  Agents/ClaudeIntegrationScripts.swift  hook.sh + statusline wrapper templates
  Agents/ClaudeSettingsEditor.swift  pure settings.json add/remove/detect
  Agents/TokenFormat.swift           215_000 -> "215k"
Sources/Quack/
  Agents/ClaudeConfigInstaller.swift install/uninstall/isInstalled (file IO)
  Agents/ClaudeStateWatcher.swift    DispatchSource dir watch, debounced
  Agents/ClaudeAgentsService.swift   watcher + reducer -> @Published snapshots
  Agents/TokensTodayReader.swift     optional usage.db SUM(output_tokens)
  Notch/NotchService.swift           REPLACES MenuBar/NotchMediaService.swift
  Notch/NotchContentViewModel.swift  REPLACES NotchMediaViewModel.swift
  Notch/NotchContentView.swift       unified panel (peek/collapsed/expanded)
  Notch/MediaStripView.swift         REPLACES NotchMediaView.swift (pinned strip)
  Notch/AgentCardView.swift          one agent card
  Notch/NotchHeaderView.swift        "N agents" + pills
  Notch/UsageLimitsView.swift        Claude 5h/7d bars
  Notch/NotchTheme.swift             shared dark theme tokens
Tests/QuackKitTests/
  AgentModelTests.swift
  AgentReducerTests.swift
  ClaudeSettingsEditorTests.swift
  ClaudeIntegrationScriptsTests.swift
  TokenFormatTests.swift
```

---

### Task 0: Green baseline on `main`

`main` (= current `notch-agents` parent) does not compile: the half-merged Knock-Notch PR left `Feature.isEnabled` non-exhaustive (`.notchReveal` missing), `AppEnvironment.notchRevealService` assigned but undeclared, `notchMediaService` declared but never initialized, and `SettingsView:1043` binding a nonexistent `\.notchRevealEnabled`. Fix = **finish** the wiring (add the flag, default false) — preserves the merged icon-reveal code, off by default.

**Files:**
- Modify: `Sources/QuackKit/Models/QuackSettings.swift`
- Modify: `Sources/QuackKit/Coordinator/ManagedService.swift:36`
- Modify: `Sources/Quack/AppEnvironment.swift:41,73`

**Interfaces:**
- Produces: `QuackSettings.notchRevealEnabled: Bool` (default `false`); a compiling tree every later task builds on.

- [ ] **Step 1: Add `notchRevealEnabled` to `QuackSettings`**

Four places, mirroring `notchMediaEnabled` exactly (property after it, init param after it, init assignment after it, decoder line after it):

```swift
    /// Dynamic notch media player controls.
    public var notchMediaEnabled: Bool
    /// Reveal menu-bar icons hidden behind the notch (needs Screen Recording + AX).
    public var notchRevealEnabled: Bool
```

```swift
        notchMediaEnabled: Bool = false,
        notchRevealEnabled: Bool = false,
```

```swift
        self.notchMediaEnabled = notchMediaEnabled
        self.notchRevealEnabled = notchRevealEnabled
```

```swift
        notchMediaEnabled = v(.notchMediaEnabled, d.notchMediaEnabled)
        notchRevealEnabled = v(.notchRevealEnabled, d.notchRevealEnabled)
```

- [ ] **Step 2: Complete the `Feature.isEnabled` switch**

In `Sources/QuackKit/Coordinator/ManagedService.swift`, after the `.temperature` case:

```swift
        case .temperature: return settings.cpuTemperatureEnabled
        case .notchReveal: return settings.notchRevealEnabled
        case .notchMedia: return settings.notchMediaEnabled
```

- [ ] **Step 3: Fix `AppEnvironment` property wiring**

At line 41, the declarations block currently ends with:

```swift
    private let notchMediaService: NotchMediaService
```

Add the missing declaration below it:

```swift
    private let notchMediaService: NotchMediaService
    private let notchRevealService: NotchIconRevealService
```

After line 73 (`self.temperatureService = TemperatureStatusItem(settings: settings)`), the init has `self.notchRevealService = NotchIconRevealService(...)` but never initializes `notchMediaService`. Add:

```swift
        self.notchRevealService = NotchIconRevealService(settings: settings, permissions: permissions)
        self.notchMediaService = NotchMediaService()
```

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | tail -5` — expected: `Build complete!`
Run: `swift test 2>&1 | tail -5` — expected: all tests pass.
(`rm -rf .build` first if build.db disk I/O error.)

- [ ] **Step 5: Hardware sanity check (media player still works)**

Run `./Scripts/install.sh`. Enable the media flag if not already on:
`defaults` are JSON-in-UserDefaults via SettingsStore — simplest is the running app; if no toggle exists yet (it doesn't until Task 10), verify with the flag flipped in code once locally OR just confirm app launches and menu bar works. Minimum bar: app launches, no crash, panel appears on notch hover when `notchMediaEnabled` is true.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "fix: restore green build — finish half-merged notchReveal wiring

notchRevealEnabled flag (default off), exhaustive Feature switch, declare
notchRevealService, initialize notchMediaService."
```

---

### Task 1: Integration script templates (QuackKit)

The bash sources for the hook script and the statusLine wrapper, as pure string constants so the installer (Task 6) writes them and tests can assert their shape.

**Files:**
- Create: `Sources/QuackKit/Agents/ClaudeIntegrationScripts.swift`
- Test: `Tests/QuackKitTests/ClaudeIntegrationScriptsTests.swift`

**Interfaces:**
- Produces:
  - `ClaudeIntegrationScripts.hookScript: String`
  - `ClaudeIntegrationScripts.statusLineWrapperTemplate: String` (contains `__PREV_STATUSLINE__` placeholder)
  - `ClaudeIntegrationScripts.statusLineWrapper(previousCommand: String?) -> String`
  - `ClaudeIntegrationScripts.hookEvents: [String]` == `["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import QuackKit

@Suite struct ClaudeIntegrationScriptsTests {
    @Test func hookScriptShape() {
        let s = ClaudeIntegrationScripts.hookScript
        #expect(s.hasPrefix("#!/bin/bash"))
        #expect(s.contains(".state.json"))
        #expect(s.contains("session_id"))
        #expect(s.contains("exit 0"))          // fail-soft: never blocks Claude Code
        #expect(!s.contains("tac "))           // BSD userland: tail -r, not tac
    }

    @Test func wrapperTemplateHasPlaceholder() {
        #expect(ClaudeIntegrationScripts.statusLineWrapperTemplate.contains("__PREV_STATUSLINE__"))
        #expect(ClaudeIntegrationScripts.statusLineWrapperTemplate.contains(".status.json"))
    }

    @Test func wrapperBakesPreviousCommand() {
        let s = ClaudeIntegrationScripts.statusLineWrapper(previousCommand: "/Users/x/.claude/statusline.sh")
        #expect(s.contains(#"printf '%s' "$INPUT" | "/Users/x/.claude/statusline.sh""#))
        #expect(!s.contains("__PREV_STATUSLINE__"))
    }

    @Test func wrapperWithoutPreviousEmitsModelName() {
        let s = ClaudeIntegrationScripts.statusLineWrapper(previousCommand: nil)
        #expect(s.contains("display_name"))
        #expect(!s.contains("__PREV_STATUSLINE__"))
    }

    @Test func hookEventsList() {
        #expect(ClaudeIntegrationScripts.hookEvents == ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClaudeIntegrationScriptsTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ClaudeIntegrationScripts'`.

- [ ] **Step 3: Implement**

`Sources/QuackKit/Agents/ClaudeIntegrationScripts.swift`:

```swift
import Foundation

/// Bash sources Quack installs into ~/.claude/quack/ when the user enables the
/// Claude Code integration. Kept as pure constants so the shape is unit-tested
/// and the installer only does file IO. Fail-soft by design: every path exits 0
/// so a broken script can never block Claude Code itself.
public enum ClaudeIntegrationScripts {
    /// Hook events Quack registers. One shared script, event name as $1.
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    public static let hookScript = #"""
    #!/bin/bash
    # Quack Claude Code integration hook. Writes per-session agent state to
    # ~/.claude/quack/sessions/<session_id>.state.json for the notch panel.
    # Installed/removed by Quack.app (Settings -> Windows -> Notch). Fail-soft:
    # every exit path is 0 so this can never block Claude Code.
    EVENT="$1"
    DIR="$HOME/.claude/quack/sessions"
    mkdir -p "$DIR" 2>/dev/null || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    INPUT=$(cat)
    SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
    [ -n "$SID" ] || exit 0
    FILE="$DIR/$SID.state.json"
    CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    STATUS=""
    case "$EVENT" in
      SessionStart) STATUS="idle" ;;
      UserPromptSubmit|PostToolUse) STATUS="working" ;;
      Stop|Notification) STATUS="needs_you" ;;
      SessionEnd) STATUS="ended" ;;
    esac

    EXTRA='{}'
    if [ "$EVENT" = "PostToolUse" ]; then
      TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
      TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.command // .tool_input.pattern // empty' 2>/dev/null | head -1 | cut -c1-200)
      EXTRA=$(jq -n --arg t "$TOOL" --arg g "$TARGET" '{last_tool:$t, last_tool_target:$g}')
      if [ "$TOOL" = "TodoWrite" ]; then
        COUNTS=$(printf '%s' "$INPUT" | jq '{todos_total: ((.tool_input.todos // [])|length), todos_completed: ([(.tool_input.todos // [])[]|select(.status=="completed")]|length)}' 2>/dev/null)
        [ -n "$COUNTS" ] && EXTRA=$(printf '%s' "$EXTRA" | jq --argjson c "$COUNTS" '. + $c')
      fi
    fi
    if [ "$EVENT" = "Notification" ]; then
      MSG=$(printf '%s' "$INPUT" | jq -r '.message // empty' 2>/dev/null | head -1 | cut -c1-200)
      [ -n "$MSG" ] && EXTRA=$(jq -n --arg m "$MSG" '{notification_message:$m}')
    fi
    if [ "$EVENT" = "Stop" ]; then
      TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
      if [ -f "$TRANSCRIPT" ]; then
        LAST=$(tail -300 "$TRANSCRIPT" 2>/dev/null | jq -rs '[.[] | select(.type=="assistant" and .isSidechain != true) | .message.content[]? | select(.type=="text") | .text] | last // empty' 2>/dev/null | head -1 | cut -c1-200)
        [ -n "$LAST" ] && EXTRA=$(jq -n --arg l "$LAST" '{last_assistant_line:$l}')
      fi
    fi

    PROJECT=""; BRANCH=""
    if [ -n "$CWD" ]; then
      PROJECT=$(basename "$CWD")
      BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
    fi

    BASE=$(jq -n --arg sid "$SID" --arg st "$STATUS" --arg ev "$EVENT" --arg cwd "$CWD" \
      --arg p "$PROJECT" --arg b "$BRANCH" --arg ts "$NOW" \
      '{session_id:$sid, status:$st, event:$ev, cwd:$cwd, project:$p, branch:$b, ts:$ts} | with_entries(select(.value != ""))')

    OLD='{}'
    if [ -f "$FILE" ]; then
      CANDIDATE=$(cat "$FILE" 2>/dev/null)
      printf '%s' "$CANDIDATE" | jq -e . >/dev/null 2>&1 && OLD="$CANDIDATE"
    fi
    printf '%s' "$OLD" | jq --argjson base "$BASE" --argjson extra "$EXTRA" '. * $base * $extra' > "$FILE.tmp" 2>/dev/null \
      && mv "$FILE.tmp" "$FILE" 2>/dev/null
    exit 0
    """#

    public static let statusLineWrapperTemplate = #"""
    #!/bin/bash
    # Quack statusLine wrapper: captures the status JSON for the notch panel,
    # then delegates to the previous statusLine command so the visible status
    # line is unchanged. Installed/removed by Quack.app.
    DIR="$HOME/.claude/quack/sessions"
    INPUT=$(cat)
    if command -v jq >/dev/null 2>&1; then
      SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
      if [ -n "$SID" ]; then
        mkdir -p "$DIR" 2>/dev/null
        printf '%s' "$INPUT" > "$DIR/$SID.status.json.tmp" 2>/dev/null \
          && mv "$DIR/$SID.status.json.tmp" "$DIR/$SID.status.json" 2>/dev/null
      fi
    fi
    __PREV_STATUSLINE__
    """#

    /// Bakes the delegation line. With a previous command, pipe the same stdin
    /// into it; without one, emit the model name so the status line isn't blank.
    public static func statusLineWrapper(previousCommand: String?) -> String {
        let delegation: String
        if let previousCommand, !previousCommand.isEmpty {
            delegation = #"printf '%s' "$INPUT" | "\#(previousCommand)""#
        } else {
            delegation = #"command -v jq >/dev/null 2>&1 && printf '%s' "$INPUT" | jq -r '.model.display_name // ""'"#
        }
        return statusLineWrapperTemplate.replacingOccurrences(of: "__PREV_STATUSLINE__", with: delegation)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ClaudeIntegrationScriptsTests 2>&1 | tail -5`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Agents/ClaudeIntegrationScripts.swift Tests/QuackKitTests/ClaudeIntegrationScriptsTests.swift
git commit -m "feat(agents): hook + statusLine wrapper script templates"
```

---

### Task 2: Hardware pipeline checkpoint (manual, needs user consent)

Prove the pipeline on this Mac **before** building Swift on top: install the scripts by hand, run a real Claude Code session, confirm both files appear with the expected fields, and capture sanitized fixtures for Tasks 3–4. **This task edits the user's live `~/.claude/settings.json` — get explicit confirmation in-session before doing it** (the user approved the approach at design time; re-confirm before touching the file).

**Files:**
- Create: `docs/superpowers/specs/fixtures-notch-agents.md` (captured real JSON, sanitized)

**Interfaces:**
- Produces: real `*.status.json` / `*.state.json` samples; confirmed presence (or absence) of `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` and `context_window.used_percentage` in this machine's statusLine JSON. Tasks 3–4 paste these into test fixtures.

- [ ] **Step 1: Confirm consent, back up settings**

Ask the user to confirm. Then:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.quack-backup
```

- [ ] **Step 2: Write the scripts from the QuackKit constants**

```bash
mkdir -p ~/.claude/quack/sessions
```

Then create `~/.claude/quack/hook.sh` with the **exact** body of `ClaudeIntegrationScripts.hookScript` (copy from the Swift source, strip the `#"""` delimiters), and `~/.claude/quack/statusline-wrapper.sh` with `statusLineWrapperTemplate`'s body, replacing `__PREV_STATUSLINE__` with:

```bash
printf '%s' "$INPUT" | "/Users/strativ/.claude/statusline.sh"
```

Finally:

```bash
chmod +x ~/.claude/quack/hook.sh ~/.claude/quack/statusline-wrapper.sh
bash -n ~/.claude/quack/hook.sh && bash -n ~/.claude/quack/statusline-wrapper.sh && echo SYNTAX-OK
```

Expected: `SYNTAX-OK`. (The on-disk content must match the Swift constants — Task 6's installer later overwrites these files with exactly those constants, so any manual drift would change behavior.)

- [ ] **Step 3: Register hooks + wrapper in `~/.claude/settings.json` with jq**

```bash
HOOK="$HOME/.claude/quack/hook.sh"
jq --arg h "$HOOK" '
  .statusLine = {type:"command", command: ($h | sub("hook.sh$"; "statusline-wrapper.sh"))} |
  .hooks = (.hooks // {}) |
  reduce ("SessionStart","UserPromptSubmit","PostToolUse","Notification","Stop","SessionEnd")[] as $e (.;
    .hooks[$e] = ((.hooks[$e] // []) + [{hooks:[{type:"command", command:($h + " " + $e)}]}]))
' ~/.claude/settings.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
```

- [ ] **Step 4: Generate real traffic and verify**

Ask the user to open a **new** Claude Code session in any project, send one prompt that triggers a tool call, let it finish, then:

```bash
ls -la ~/.claude/quack/sessions/
SID=$(ls -t ~/.claude/quack/sessions/*.state.json | head -1)
cat "$SID" | jq .
cat "${SID%.state.json}.status.json" | jq '{session_id, model, context_window, rate_limits, cost}' 
```

Expected: `.state.json` has `session_id,status,event,cwd,project,branch,ts` (+ `last_tool` after a tool ran; `last_assistant_line` after Stop). `.status.json` has `model.display_name`, and — verify and record — `context_window.used_percentage`, `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage`, and the exact type/format of `resets_at` (ISO string vs epoch number). **If field names differ, write the real names down — Task 3's decode types must match reality, not this plan.**

- [ ] **Step 5: Save sanitized fixtures**

Copy one real `.state.json` and one real `.status.json` (trim/anonymize paths if desired) into `docs/superpowers/specs/fixtures-notch-agents.md` as fenced JSON blocks, annotated with which fields were present. Leave the manual install in place (it is the feature's end state; Task 6's installer detects and adopts it).

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/fixtures-notch-agents.md
git commit -m "docs(agents): captured real hook/statusLine fixtures from hardware checkpoint"
```

---

### Task 3: Raw file decode models (QuackKit)

**Files:**
- Create: `Sources/QuackKit/Models/AgentModel.swift`
- Test: `Tests/QuackKitTests/AgentModelTests.swift`

**Interfaces:**
- Produces (all `public`):
  - `AgentStatus: String, Codable, Sendable` — `.working`, `.needsYou` (raw `"needs_you"`), `.idle`
  - `AgentSnapshot: Equatable, Sendable, Identifiable` — `sessionID: String` (== `id`), `project: String`, `branch: String?`, `model: String?`, `status: AgentStatus`, `statusMessage: String?`, `progress: Double?`, `lastUpdate: Date`; memberwise `public init`
  - `UsageLimits: Equatable, Sendable` — `fiveHourUsedPercent: Double?`, `fiveHourResetsAt: Date?`, `sevenDayUsedPercent: Double?`, `sevenDayResetsAt: Date?`; memberwise `public init`
  - `StateFileRaw: Decodable, Equatable, Sendable` — optional `session_id, status, event, cwd, project, branch, ts, last_tool, last_tool_target, last_assistant_line, notification_message: String?` and `todos_completed, todos_total: Int?`
  - `StatusFileRaw: Decodable, Sendable` — `session_id: String?`, `model: Model?` (`display_name: String?`), `context_window: ContextWindow?` (`used_percentage: Double?`), `rate_limits: RateLimits?` (`five_hour`/`seven_day: RateWindow?`; `RateWindow.used_percentage: Double?`, `RateWindow.resetsAtDate: Date?` parsed from ISO-string **or** epoch-number `resets_at`)

**Adjust field names to what Task 2 actually captured** — the shapes below are the plan's best knowledge; reality wins.

- [ ] **Step 1: Write the failing tests** (replace fixture strings with Task 2 captures where they differ)

```swift
import Testing
import Foundation
@testable import QuackKit

@Suite struct AgentModelTests {
    static let stateJSON = #"""
    {"session_id":"abc-123","status":"working","event":"PostToolUse","cwd":"/Users/x/Repositories/website",
     "project":"website","branch":"main","ts":"2026-07-04T12:00:00Z",
     "last_tool":"Edit","last_tool_target":"/Users/x/Repositories/website/settings.json",
     "todos_completed":2,"todos_total":9}
    """#

    static let statusJSON = #"""
    {"session_id":"abc-123","model":{"id":"claude-opus-4-8","display_name":"Opus 4.8"},
     "context_window":{"used_percentage":22.4},
     "rate_limits":{"five_hour":{"used_percentage":16.0,"resets_at":"2026-07-04T15:20:00Z"},
                    "seven_day":{"used_percentage":19.0,"resets_at":1783036800}}}
    """#

    @Test func decodesStateFile() throws {
        let s = try JSONDecoder().decode(StateFileRaw.self, from: Data(Self.stateJSON.utf8))
        #expect(s.session_id == "abc-123")
        #expect(s.status == "working")
        #expect(s.branch == "main")
        #expect(s.todos_total == 9)
    }

    @Test func decodesStatusFileWithBothResetFormats() throws {
        let s = try JSONDecoder().decode(StatusFileRaw.self, from: Data(Self.statusJSON.utf8))
        #expect(s.model?.display_name == "Opus 4.8")
        #expect(s.context_window?.used_percentage == 22.4)
        #expect(s.rate_limits?.five_hour?.used_percentage == 16.0)
        #expect(s.rate_limits?.five_hour?.resetsAtDate != nil)   // ISO string
        #expect(s.rate_limits?.seven_day?.resetsAtDate != nil)   // epoch number
    }

    @Test func missingFieldsDecodeToNil() throws {
        let s = try JSONDecoder().decode(StatusFileRaw.self, from: Data("{}".utf8))
        #expect(s.rate_limits == nil && s.model == nil)
        let t = try JSONDecoder().decode(StateFileRaw.self, from: Data("{}".utf8))
        #expect(t.session_id == nil)
    }

    @Test func agentStatusRawValues() {
        #expect(AgentStatus(rawValue: "needs_you") == .needsYou)
        #expect(AgentStatus.working.rawValue == "working")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter AgentModelTests 2>&1 | tail -5`
Expected: FAIL — types not found.

- [ ] **Step 3: Implement `Sources/QuackKit/Models/AgentModel.swift`**

```swift
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
    public let lastUpdate: Date

    public init(sessionID: String, project: String, branch: String?, model: String?,
                status: AgentStatus, statusMessage: String?, progress: Double?, lastUpdate: Date) {
        self.sessionID = sessionID
        self.project = project
        self.branch = branch
        self.model = model
        self.status = status
        self.statusMessage = statusMessage
        self.progress = progress
        self.lastUpdate = lastUpdate
    }
}

/// Account-global Claude usage limits (5h / 7d windows), from statusLine JSON.
public struct UsageLimits: Equatable, Sendable {
    public let fiveHourUsedPercent: Double?
    public let fiveHourResetsAt: Date?
    public let sevenDayUsedPercent: Double?
    public let sevenDayResetsAt: Date?

    public init(fiveHourUsedPercent: Double?, fiveHourResetsAt: Date?,
                sevenDayUsedPercent: Double?, sevenDayResetsAt: Date?) {
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayUsedPercent = sevenDayUsedPercent
        self.sevenDayResetsAt = sevenDayResetsAt
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
}

/// On-disk shape of <id>.status.json — the raw Claude Code statusLine JSON.
/// Decoded defensively: only the fields the panel needs, all optional.
public struct StatusFileRaw: Decodable, Sendable {
    public struct Model: Decodable, Sendable { public let display_name: String? }
    public struct ContextWindow: Decodable, Sendable { public let used_percentage: Double? }

    /// One rate-limit window. `resets_at` arrives as an ISO-8601 string or an
    /// epoch-seconds number depending on Claude Code version — accept both.
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

    public let session_id: String?
    public let model: Model?
    public let context_window: ContextWindow?
    public let rate_limits: RateLimits?
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
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AgentModelTests 2>&1 | tail -5`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Models/AgentModel.swift Tests/QuackKitTests/AgentModelTests.swift
git commit -m "feat(agents): raw state/status decode models + snapshot value types"
```

---

### Task 4: AgentReducer (QuackKit)

Pure merge of per-session file pairs → sorted `[AgentSnapshot]` + one `UsageLimits`.

**Files:**
- Create: `Sources/QuackKit/Agents/AgentReducer.swift`
- Test: `Tests/QuackKitTests/AgentReducerTests.swift`

**Interfaces:**
- Consumes: `StateFileRaw`, `StatusFileRaw`, `AgentSnapshot`, `AgentStatus`, `UsageLimits`, `ISO8601Parse` (Task 3).
- Produces (all `public`):
  - `SessionFiles: Sendable` — `sessionID: String`, `state: StateFileRaw?`, `status: StatusFileRaw?`, `stateModified: Date?`, `statusModified: Date?`; memberwise `public init`
  - `AgentReducer.defaultStaleAfter: TimeInterval` (900)
  - `AgentReducer.snapshots(from: [SessionFiles], now: Date, staleAfter: TimeInterval) -> [AgentSnapshot]`
  - `AgentReducer.usageLimits(from: [SessionFiles]) -> UsageLimits?`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import QuackKit

@Suite struct AgentReducerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(_ overrides: [String: Any]) throws -> StateFileRaw {
        var base: [String: Any] = ["session_id": "s1", "status": "working", "event": "PostToolUse",
                                   "cwd": "/r/website", "project": "website", "branch": "main"]
        base.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(StateFileRaw.self, from: JSONSerialization.data(withJSONObject: base))
    }

    func files(_ st: StateFileRaw?, status: StatusFileRaw? = nil, modified: Date? = nil) -> SessionFiles {
        SessionFiles(sessionID: st?.session_id ?? "s?", state: st, status: status,
                     stateModified: modified ?? now, statusModified: modified ?? now)
    }

    @Test func workingUsesToolPhrase() throws {
        let f = files(try state(["last_tool": "Edit", "last_tool_target": "/r/website/settings.json"]))
        let snap = AgentReducer.snapshots(from: [f], now: now, staleAfter: 900)[0]
        #expect(snap.status == .working)
        #expect(snap.statusMessage == "Editing settings.json")
    }

    @Test func needsYouFromStopUsesAssistantLine() throws {
        let f = files(try state(["status": "needs_you", "event": "Stop",
                                 "last_assistant_line": "Landing page shipped."]))
        let snap = AgentReducer.snapshots(from: [f], now: now, staleAfter: 900)[0]
        #expect(snap.status == .needsYou)
        #expect(snap.statusMessage == "Landing page shipped.")
    }

    @Test func needsYouFromNotificationPrefersNotificationMessage() throws {
        let f = files(try state(["status": "needs_you", "event": "Notification",
                                 "notification_message": "Claude needs your permission to use Bash",
                                 "last_assistant_line": "old text"]))
        #expect(AgentReducer.snapshots(from: [f], now: now, staleAfter: 900)[0].statusMessage
                == "Claude needs your permission to use Bash")
    }

    @Test func progressPrefersTodosOverContext() throws {
        let status = try JSONDecoder().decode(StatusFileRaw.self,
            from: Data(#"{"context_window":{"used_percentage":50}}"#.utf8))
        let withTodos = files(try state(["todos_completed": 3, "todos_total": 4]), status: status)
        #expect(AgentReducer.snapshots(from: [withTodos], now: now, staleAfter: 900)[0].progress == 0.75)
        let noTodos = files(try state([:]), status: status)
        #expect(AgentReducer.snapshots(from: [noTodos], now: now, staleAfter: 900)[0].progress == 0.5)
    }

    @Test func staleAndEndedArePruned() throws {
        let stale = SessionFiles(sessionID: "s1", state: try state([:]), status: nil,
                                 stateModified: now.addingTimeInterval(-1000), statusModified: nil)
        let ended = files(try state(["status": "ended", "event": "SessionEnd"]))
        #expect(AgentReducer.snapshots(from: [stale, ended], now: now, staleAfter: 900).isEmpty)
    }

    @Test func tsFieldBeatsFileMtimeForStaleness() throws {
        let fresh = SessionFiles(sessionID: "s1",
            state: try state(["ts": ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))]),
            status: nil, stateModified: now.addingTimeInterval(-5000), statusModified: nil)
        #expect(AgentReducer.snapshots(from: [fresh], now: now, staleAfter: 900).count == 1)
    }

    @Test func sortNeedsYouFirstThenWorking() throws {
        let w = files(try state(["session_id": "w"]))
        let n = files(try state(["session_id": "n", "status": "needs_you", "event": "Stop"]))
        let i = files(try state(["session_id": "i", "status": "idle", "event": "SessionStart"]))
        let out = AgentReducer.snapshots(from: [i, w, n], now: now, staleAfter: 900)
        #expect(out.map(\.sessionID) == ["n", "w", "i"])
    }

    @Test func usageLimitsFromFreshestStatus() throws {
        let old = try JSONDecoder().decode(StatusFileRaw.self,
            from: Data(#"{"rate_limits":{"five_hour":{"used_percentage":50}}}"#.utf8))
        let new = try JSONDecoder().decode(StatusFileRaw.self,
            from: Data(#"{"rate_limits":{"five_hour":{"used_percentage":16},"seven_day":{"used_percentage":19}}}"#.utf8))
        let files = [
            SessionFiles(sessionID: "a", state: nil, status: old, stateModified: nil, statusModified: now.addingTimeInterval(-600)),
            SessionFiles(sessionID: "b", state: nil, status: new, stateModified: nil, statusModified: now),
        ]
        let u = AgentReducer.usageLimits(from: files)
        #expect(u?.fiveHourUsedPercent == 16)
        #expect(u?.sevenDayUsedPercent == 19)
    }

    @Test func statusOnlySessionIsNotACard() throws {
        let status = try JSONDecoder().decode(StatusFileRaw.self, from: Data("{}".utf8))
        let f = SessionFiles(sessionID: "x", state: nil, status: status, stateModified: nil, statusModified: now)
        #expect(AgentReducer.snapshots(from: [f], now: now, staleAfter: 900).isEmpty)
    }

    @Test func projectFallsBackToCwdBasename() throws {
        let f = files(try state(["project": NSNull()]))   // project removed
        #expect(AgentReducer.snapshots(from: [f], now: now, staleAfter: 900)[0].project == "website")
    }
}
```

Note: `NSNull()` in the helper removes the key only if the helper filters it — adjust the helper: `base.merge(...)` then `base = base.filter { !($0.value is NSNull) }`. Include that line in the test helper.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter AgentReducerTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'SessionFiles' / 'AgentReducer'`.

- [ ] **Step 3: Implement `Sources/QuackKit/Agents/AgentReducer.swift`**

```swift
import Foundation

/// One session's on-disk pair (state from hooks, status from the statusLine
/// wrapper) plus file mtimes, as read by the app-layer watcher.
public struct SessionFiles: Sendable {
    public let sessionID: String
    public let state: StateFileRaw?
    public let status: StatusFileRaw?
    public let stateModified: Date?
    public let statusModified: Date?

    public init(sessionID: String, state: StateFileRaw?, status: StatusFileRaw?,
                stateModified: Date?, statusModified: Date?) {
        self.sessionID = sessionID
        self.state = state
        self.status = status
        self.stateModified = stateModified
        self.statusModified = statusModified
    }
}

/// Pure reduction of session files to display state. No system dependencies;
/// `now` is always injected so staleness is testable.
public enum AgentReducer {
    public static let defaultStaleAfter: TimeInterval = 15 * 60

    /// Live agent cards, sorted needs-you → working → idle, newest first within
    /// a group. Sessions that ended, went stale, or never emitted hook state
    /// (status-only) produce no card.
    public static func snapshots(from files: [SessionFiles], now: Date,
                                 staleAfter: TimeInterval = defaultStaleAfter) -> [AgentSnapshot] {
        files.compactMap { snapshot(from: $0, now: now, staleAfter: staleAfter) }
            .sorted { a, b in
                if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
                return a.lastUpdate > b.lastUpdate
            }
    }

    /// Account-global limits from the freshest status file that has any.
    public static func usageLimits(from files: [SessionFiles]) -> UsageLimits? {
        let best = files
            .filter { $0.status?.rate_limits != nil }
            .max { ($0.statusModified ?? .distantPast) < ($1.statusModified ?? .distantPast) }
        guard let rl = best?.status?.rate_limits else { return nil }
        return UsageLimits(
            fiveHourUsedPercent: rl.five_hour?.used_percentage,
            fiveHourResetsAt: rl.five_hour?.resetsAtDate,
            sevenDayUsedPercent: rl.seven_day?.used_percentage,
            sevenDayResetsAt: rl.seven_day?.resetsAtDate
        )
    }

    // MARK: - Internals (internal for @testable reach if needed)

    static func snapshot(from f: SessionFiles, now: Date, staleAfter: TimeInterval) -> AgentSnapshot? {
        guard let state = f.state else { return nil }
        if state.status == "ended" { return nil }
        let last = state.ts.flatMap(ISO8601Parse.date(from:))
            ?? f.stateModified ?? f.statusModified ?? .distantPast
        guard now.timeIntervalSince(last) <= staleAfter else { return nil }
        let status = agentStatus(state.status)
        return AgentSnapshot(
            sessionID: f.sessionID,
            project: state.project ?? state.cwd.map { ($0 as NSString).lastPathComponent } ?? "unknown",
            branch: state.branch,
            model: f.status?.model?.display_name,
            status: status,
            statusMessage: statusMessage(state: state, status: status),
            progress: progress(state: state, status: f.status),
            lastUpdate: last
        )
    }

    static func agentStatus(_ raw: String?) -> AgentStatus {
        AgentStatus(rawValue: raw ?? "") ?? .idle
    }

    static func statusMessage(state: StateFileRaw, status: AgentStatus) -> String? {
        switch status {
        case .working:
            return toolPhrase(tool: state.last_tool, target: state.last_tool_target) ?? "Working…"
        case .needsYou:
            if state.event == "Notification", let m = state.notification_message { return m }
            return state.last_assistant_line ?? "Waiting for you"
        case .idle:
            return state.last_assistant_line
        }
    }

    /// "Editing settings.json" style phrases from the last tool call.
    static func toolPhrase(tool: String?, target: String?) -> String? {
        guard let tool, !tool.isEmpty else { return nil }
        let base = target.map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Edit", "Write", "NotebookEdit": return base.map { "Editing \($0)" } ?? "Editing files"
        case "Read": return base.map { "Reading \($0)" } ?? "Reading files"
        case "Bash":
            guard let t = target, !t.isEmpty else { return "Running a command" }
            return "Running \(String(t.prefix(32)))"
        case "Grep", "Glob": return "Searching the codebase"
        case "Task", "Agent": return "Delegating to a subagent"
        case "WebFetch", "WebSearch": return "Browsing the web"
        case "TodoWrite": return "Updating the plan"
        default: return tool
        }
    }

    static func progress(state: StateFileRaw, status: StatusFileRaw?) -> Double? {
        if let total = state.todos_total, total > 0, let done = state.todos_completed {
            return min(max(Double(done) / Double(total), 0), 1)
        }
        if let pct = status?.context_window?.used_percentage {
            return min(max(pct / 100, 0), 1)
        }
        return nil
    }

    private static func rank(_ s: AgentStatus) -> Int {
        switch s {
        case .needsYou: return 0
        case .working: return 1
        case .idle: return 2
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AgentReducerTests 2>&1 | tail -5`
Expected: PASS (10 tests). Then full suite: `swift test 2>&1 | tail -3` — PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Agents/AgentReducer.swift Tests/QuackKitTests/AgentReducerTests.swift
git commit -m "feat(agents): pure reducer — snapshots, staleness, progress, usage limits"
```

---

### Task 5: ClaudeSettingsEditor (QuackKit)

Pure `Data -> Data` mutation of `~/.claude/settings.json`: add/remove Quack's hooks + statusLine, preserving everything else.

**Files:**
- Create: `Sources/QuackKit/Agents/ClaudeSettingsEditor.swift`
- Test: `Tests/QuackKitTests/ClaudeSettingsEditorTests.swift`

**Interfaces:**
- Consumes: `ClaudeIntegrationScripts.hookEvents` (Task 1).
- Produces (all `public`):
  - `ClaudeSettingsEditor.hookMarker: String` == `"/.claude/quack/hook.sh"`
  - `ClaudeSettingsEditor.integrationPresent(in: Data) -> Bool`
  - `ClaudeSettingsEditor.addingIntegration(to: Data, hookCommand: String, statusLineCommand: String) throws -> (updated: Data, previousStatusLineCommand: String?)` — `previousStatusLineCommand` is nil when there was none **or** it was already our wrapper.
  - `ClaudeSettingsEditor.removingIntegration(from: Data, restoringStatusLineCommand: String?) throws -> Data`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClaudeSettingsEditorTests 2>&1 | tail -5`
Expected: FAIL — type not found.

- [ ] **Step 3: Implement `Sources/QuackKit/Agents/ClaudeSettingsEditor.swift`**

```swift
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
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ClaudeSettingsEditorTests 2>&1 | tail -5`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Agents/ClaudeSettingsEditor.swift Tests/QuackKitTests/ClaudeSettingsEditorTests.swift
git commit -m "feat(agents): pure settings.json editor — add/remove/detect integration"
```

---

### Task 6: ClaudeConfigInstaller (app layer)

File IO around the editor: write scripts, edit settings.json atomically, remember the previous statusLine for uninstall.

**Files:**
- Create: `Sources/Quack/Agents/ClaudeConfigInstaller.swift`
- Modify: `Sources/Quack/AppEnvironment.swift` (expose install API)

**Interfaces:**
- Consumes: `ClaudeIntegrationScripts`, `ClaudeSettingsEditor` (QuackKit).
- Produces:
  - `ClaudeConfigInstaller` (`@MainActor final class`): `init(claudeDir: URL = default ~/.claude)`, `isInstalled() -> Bool`, `install() throws`, `uninstall() throws`, `var sessionsDirectory: URL`
  - `AppEnvironment.claudeInstaller: ClaudeConfigInstaller`

- [ ] **Step 1: Implement `Sources/Quack/Agents/ClaudeConfigInstaller.swift`**

```swift
import Foundation
import QuackKit

/// Installs/removes Quack's Claude Code integration: writes the hook +
/// statusLine wrapper scripts under ~/.claude/quack/ and registers them in
/// ~/.claude/settings.json via the pure ClaudeSettingsEditor. Only ever runs
/// from an explicit user action in Settings — never automatically.
/// Not sandbox/App-Store compatible (writes another app's config; fine for
/// Quack's direct-distribution model).
@MainActor
final class ClaudeConfigInstaller {
    private let claudeDir: URL
    private var quackDir: URL { claudeDir.appendingPathComponent("quack") }
    var sessionsDirectory: URL { quackDir.appendingPathComponent("sessions") }
    private var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    private var hookFile: URL { quackDir.appendingPathComponent("hook.sh") }
    private var wrapperFile: URL { quackDir.appendingPathComponent("statusline-wrapper.sh") }
    private var backupFile: URL { quackDir.appendingPathComponent("previous-statusline.json") }

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsFile) else { return false }
        return ClaudeSettingsEditor.integrationPresent(in: data)
            && FileManager.default.fileExists(atPath: hookFile.path)
    }

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let existing = (try? Data(contentsOf: settingsFile)) ?? Data("{}".utf8)
        let (updated, previous) = try ClaudeSettingsEditor.addingIntegration(
            to: existing, hookCommand: hookFile.path, statusLineCommand: wrapperFile.path)

        // Remember the pre-Quack statusLine exactly once: a re-install must not
        // overwrite the original backup with our own wrapper path.
        if let previous, !fm.fileExists(atPath: backupFile.path) {
            let backup = try JSONSerialization.data(withJSONObject: ["command": previous])
            try backup.write(to: backupFile, options: .atomic)
        }

        let wrapper = ClaudeIntegrationScripts.statusLineWrapper(previousCommand: previous ?? backedUpCommand())
        try ClaudeIntegrationScripts.hookScript.write(to: hookFile, atomically: true, encoding: .utf8)
        try wrapper.write(to: wrapperFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperFile.path)

        try updated.write(to: settingsFile, options: .atomic)
    }

    func uninstall() throws {
        let existing = (try? Data(contentsOf: settingsFile)) ?? Data("{}".utf8)
        let restored = try ClaudeSettingsEditor.removingIntegration(
            from: existing, restoringStatusLineCommand: backedUpCommand())
        try restored.write(to: settingsFile, options: .atomic)
        let fm = FileManager.default
        try? fm.removeItem(at: hookFile)
        try? fm.removeItem(at: wrapperFile)
        try? fm.removeItem(at: backupFile)
        // sessions/ left in place: cheap, and a re-enable picks state right up.
    }

    private func backedUpCommand() -> String? {
        guard let data = try? Data(contentsOf: backupFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["command"] as? String
    }
}
```

- [ ] **Step 2: Expose on AppEnvironment**

In `Sources/Quack/AppEnvironment.swift`, add near the other `let` services:

```swift
    let claudeInstaller = ClaudeConfigInstaller()
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3` — expected: `Build complete!`

- [ ] **Step 4: Manual round-trip verification (safe: uses a temp dir)**

The Task 2 manual install is live in `~/.claude`. Verify the installer **adopts** it rather than duplicating: temporarily add to `QuackApp`'s AppDelegate `applicationDidFinishLaunching`… — no. Simpler, zero app churn: verify against a scratch dir with a tiny snippet run via `swift repl` or a throwaway test in the app target is unavailable — instead verify the logic through the already-tested editor (Task 5) plus this one-shot shell check after Task 10 wires the Settings button. For now assert compile + code review the atomic-write paths. (Full live verification happens in Task 12 step "install/uninstall round trip".)

- [ ] **Step 5: Commit**

```bash
git add Sources/Quack/Agents/ClaudeConfigInstaller.swift Sources/Quack/AppEnvironment.swift
git commit -m "feat(agents): config installer — scripts + settings.json, backup/restore statusLine"
```

---

### Task 7: ClaudeStateWatcher + ClaudeAgentsService (app layer)

**Files:**
- Create: `Sources/Quack/Agents/ClaudeStateWatcher.swift`
- Create: `Sources/Quack/Agents/ClaudeAgentsService.swift`

**Interfaces:**
- Consumes: `AgentReducer`, `SessionFiles`, `StateFileRaw`, `StatusFileRaw`, `AgentSnapshot`, `UsageLimits` (QuackKit); `ClaudeConfigInstaller.sessionsDirectory` (Task 6).
- Produces:
  - `ClaudeStateWatcher` (`@MainActor final class`): `var onChange: (() -> Void)?`, `func start(directory: URL)`, `func stop()`
  - `ClaudeAgentsService` (`@MainActor final class ObservableObject`): `@Published private(set) var agents: [AgentSnapshot]`, `@Published private(set) var usage: UsageLimits?`, `@Published private(set) var integrationInstalled: Bool`, `init(installer: ClaudeConfigInstaller)`, `func start()`, `func stop()`, `func refreshNow()`

- [ ] **Step 1: Implement `Sources/Quack/Agents/ClaudeStateWatcher.swift`**

```swift
import Foundation

/// Watches ~/.claude/quack/sessions/ for changes via a kqueue-backed
/// DispatchSource on the directory fd. The hook scripts always write tmp+mv,
/// so every update mutates a directory entry and fires a .write event here —
/// no per-file watches needed. Debounced: bursts (statusLine fires often)
/// collapse into one onChange. If the directory doesn't exist yet, retries
/// every few seconds until it does. No event tap, no run-loop source.
@MainActor
final class ClaudeStateWatcher {
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var directory: URL?

    func start(directory: URL) {
        self.directory = directory
        attach()
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        debounce?.cancel(); debounce = nil
        source?.cancel(); source = nil
        directory = nil
    }

    private func attach() {
        guard source == nil, let directory else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { scheduleRetry(); return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .link, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                // Directory replaced (e.g. uninstall/reinstall) — reattach.
                self.source?.cancel(); self.source = nil
                self.scheduleRetry()
            }
            self.fireDebounced()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        fireDebounced()   // initial read
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.source != nil { self.retryTimer?.invalidate(); self.retryTimer = nil; return }
                self.attach()
                if self.source != nil { self.retryTimer?.invalidate(); self.retryTimer = nil }
            }
        }
    }

    private func fireDebounced() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
```

- [ ] **Step 2: Implement `Sources/Quack/Agents/ClaudeAgentsService.swift`**

```swift
import Foundation
import Combine
import QuackKit

/// Reads the session files the Claude Code integration writes and publishes
/// reduced agent snapshots + usage limits. Fail-soft: missing directory or
/// malformed files yield empty state, never a crash. A periodic tick re-runs
/// the staleness prune even when no file event arrives (an abandoned session
/// must eventually drop off the panel).
@MainActor
final class ClaudeAgentsService: ObservableObject {
    @Published private(set) var agents: [AgentSnapshot] = []
    @Published private(set) var usage: UsageLimits?
    @Published private(set) var integrationInstalled = false

    private let installer: ClaudeConfigInstaller
    private let watcher = ClaudeStateWatcher()
    private var pruneTimer: Timer?
    private var started = false

    init(installer: ClaudeConfigInstaller) {
        self.installer = installer
    }

    func start() {
        guard !started else { return }
        started = true
        integrationInstalled = installer.isInstalled()
        watcher.onChange = { [weak self] in self?.refreshNow() }
        watcher.start(directory: installer.sessionsDirectory)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
        refreshNow()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.stop()
        watcher.onChange = nil
        pruneTimer?.invalidate(); pruneTimer = nil
        agents = []; usage = nil
    }

    func refreshNow() {
        integrationInstalled = installer.isInstalled()
        let files = readSessionFiles()
        let now = Date()
        agents = AgentReducer.snapshots(from: files, now: now)
        usage = AgentReducer.usageLimits(from: files)
    }

    private func readSessionFiles() -> [SessionFiles] {
        let fm = FileManager.default
        let dir = installer.sessionsDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        var ids = Set<String>()
        for n in names {
            if n.hasSuffix(".state.json") { ids.insert(String(n.dropLast(".state.json".count))) }
            if n.hasSuffix(".status.json") { ids.insert(String(n.dropLast(".status.json".count))) }
        }
        return ids.map { id in
            let stateURL = dir.appendingPathComponent("\(id).state.json")
            let statusURL = dir.appendingPathComponent("\(id).status.json")
            return SessionFiles(
                sessionID: id,
                state: (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(StateFileRaw.self, from: $0) },
                status: (try? Data(contentsOf: statusURL)).flatMap { try? decoder.decode(StatusFileRaw.self, from: $0) },
                stateModified: modificationDate(of: stateURL),
                statusModified: modificationDate(of: statusURL)
            )
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3` — expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/Agents/ClaudeStateWatcher.swift Sources/Quack/Agents/ClaudeAgentsService.swift
git commit -m "feat(agents): directory watcher + agents service publishing snapshots"
```

---

### Task 8: Unified panel refactor — NotchService owns one panel

Rename `.notchMedia` → `.notch` (feature = whole panel), add `notchAgentsEnabled`, replace `NotchMediaService`/`NotchMediaViewModel`/`NotchMediaView` with `NotchService`/`NotchContentViewModel`/`NotchContentView`+`MediaStripView`+`NotchTheme`. Media must keep working; agents zone renders from live service data (cards arrive in Task 9 — this task uses a plain text list placeholder).

**Files:**
- Modify: `Sources/QuackKit/Models/QuackSettings.swift` (add `notchAgentsEnabled`)
- Modify: `Sources/QuackKit/Coordinator/ManagedService.swift` (rename case, new isEnabled)
- Create: `Sources/Quack/Notch/NotchTheme.swift`
- Create: `Sources/Quack/Notch/NotchContentViewModel.swift`
- Create: `Sources/Quack/Notch/NotchContentView.swift`
- Create: `Sources/Quack/Notch/MediaStripView.swift`
- Create: `Sources/Quack/Notch/NotchService.swift`
- Delete: `Sources/Quack/MenuBar/NotchMediaService.swift`, `Sources/Quack/Notch/NotchMediaViewModel.swift`, `Sources/Quack/Notch/NotchMediaView.swift`
- Modify: `Sources/Quack/AppEnvironment.swift`
- Modify (if referenced): `Tests/QuackKitTests/PermissionAndCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ClaudeAgentsService` (Task 7), `NowPlayingService`, `NotchPanel`, `NotchScreenReader`, `NotchShape`, `SettingsStore`, `TrackInfo`.
- Produces:
  - `QuackSettings.notchAgentsEnabled: Bool` (default `false`)
  - `Feature.notch` replacing `Feature.notchMedia`; `isEnabled` = `settings.notchMediaEnabled || settings.notchAgentsEnabled`
  - `NotchService: ManagedService` — `init(settings: SettingsStore, installer: ClaudeConfigInstaller)`
  - `NotchContentViewModel` (`@MainActor ObservableObject`): `isOpen`, `agents: [AgentSnapshot]`, `usage: UsageLimits?`, `tokensTodayText: String?`, `track: TrackInfo?`, `mediaEnabled`, `agentsEnabled`, `integrationInstalled`, `contentTopInset`, `onHoverChange`, `onToggle/onNext/onPrevious`; computed `needsYouCount: Int`, `activeCount: Int`, `showsPeek: Bool`
  - `NotchTheme` — `panel, card, strip, hairline, orange, orangeSoft, green, textPrimary, textSecondary, textMuted: Color`
  - `MediaStripView(model:)` — the pinned strip
- Tasks 9–10 fill `NotchContentView`'s agents zone and peek visuals.

- [ ] **Step 1: Add `notchAgentsEnabled` to `QuackSettings`** (four places, directly after `notchRevealEnabled` from Task 0):

```swift
    /// Reveal menu-bar icons hidden behind the notch (needs Screen Recording + AX).
    public var notchRevealEnabled: Bool
    /// Show Claude Code agent progress in the notch panel.
    public var notchAgentsEnabled: Bool
```

```swift
        notchRevealEnabled: Bool = false,
        notchAgentsEnabled: Bool = false,
```

```swift
        self.notchRevealEnabled = notchRevealEnabled
        self.notchAgentsEnabled = notchAgentsEnabled
```

```swift
        notchRevealEnabled = v(.notchRevealEnabled, d.notchRevealEnabled)
        notchAgentsEnabled = v(.notchAgentsEnabled, d.notchAgentsEnabled)
```

- [ ] **Step 2: Rename the feature case**

In `Sources/QuackKit/Coordinator/ManagedService.swift`: change `case notchMedia` to `case notch` and its `isEnabled` line to:

```swift
        case .notch: return settings.notchMediaEnabled || settings.notchAgentsEnabled
```

Run: `grep -rn "notchMedia\b" Sources Tests --include="*.swift" | grep -v notchMediaEnabled` — update every `.notchMedia` reference (AppEnvironment map; any coordinator tests) to `.notch`.

- [ ] **Step 3: Create `Sources/Quack/Notch/NotchTheme.swift`**

```swift
import SwiftUI

/// The notch panel's fixed dark theme (matches the approved mockup). The panel
/// visually extends the black notch, so it is always dark regardless of the
/// app-wide appearance setting.
enum NotchTheme {
    static let panel = Color(.sRGB, red: 0.086, green: 0.090, blue: 0.098, opacity: 1)   // #161719
    static let card = Color(.sRGB, red: 0.125, green: 0.129, blue: 0.153, opacity: 1)    // #202127
    static let strip = Color(.sRGB, red: 0.067, green: 0.071, blue: 0.078, opacity: 1)   // #111214
    static let hairline = Color.white.opacity(0.08)
    static let orange = Color(.sRGB, red: 0.961, green: 0.510, blue: 0.180, opacity: 1)  // #F5822E
    static let orangeSoft = Color(.sRGB, red: 0.961, green: 0.635, blue: 0.306, opacity: 1) // #F5A24E
    static let green = Color(.sRGB, red: 0.435, green: 0.812, blue: 0.341, opacity: 1)   // #6FCF57
    static let textPrimary = Color(.sRGB, red: 0.949, green: 0.949, blue: 0.941, opacity: 1)
    static let textSecondary = Color(.sRGB, red: 0.737, green: 0.741, blue: 0.729, opacity: 1)
    static let textMuted = Color(.sRGB, red: 0.549, green: 0.553, blue: 0.541, opacity: 1)
}
```

- [ ] **Step 4: Create `Sources/Quack/Notch/NotchContentViewModel.swift`**

```swift
import AppKit
import Combine
import QuackKit
import MediaRemoteAdapter

/// Observable state for the unified notch panel: agent snapshots + usage on
/// top, media strip at the bottom. Replaces NotchMediaViewModel.
@MainActor
final class NotchContentViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var agents: [AgentSnapshot] = []
    @Published var usage: UsageLimits?
    @Published var tokensTodayText: String?
    @Published var track: TrackInfo?
    @Published var mediaEnabled = false
    @Published var agentsEnabled = false
    @Published var integrationInstalled = false
    /// Real notch height for this screen; view pads content below the cutout.
    @Published var contentTopInset: CGFloat = 0

    var onHoverChange: ((Bool) -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    var needsYouCount: Int { agents.filter { $0.status == .needsYou }.count }
    var activeCount: Int { agents.filter { $0.status != .idle }.count }
    /// Ambient peek shows only when the agents zone is on and something is live.
    var showsPeek: Bool { agentsEnabled && activeCount > 0 }
}
```

- [ ] **Step 5: Create `Sources/Quack/Notch/MediaStripView.swift`** (port of NotchMediaView's open content, background/hover removed, strip-styled)

```swift
import SwiftUI

/// The media player as a compact strip pinned at the bottom of the unified
/// notch panel: artwork + title/artist + transport controls.
struct MediaStripView: View {
    @ObservedObject var model: NotchContentViewModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(NotchTheme.hairline).frame(height: 1)
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.track?.payload.title ?? "Nothing playing")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchTheme.textPrimary).lineLimit(1)
                    Text(model.track?.payload.artist ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.track != nil {
                    HStack(spacing: 14) {
                        button("backward.fill") { model.onPrevious?() }
                        button((model.track?.payload.isPlaying ?? false) ? "pause.fill" : "play.fill") { model.onToggle?() }
                        button("forward.fill") { model.onNext?() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(NotchTheme.strip)
    }

    @ViewBuilder
    private var artwork: some View {
        if let art = model.track?.payload.artwork {
            Image(nsImage: art).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(NotchTheme.textMuted))
        }
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol).font(.system(size: 13))
            .contentShape(Rectangle()).onTapGesture(perform: action)
    }
}
```

- [ ] **Step 6: Create `Sources/Quack/Notch/NotchContentView.swift`** (agents zone = placeholder rows this task; Task 9 replaces `agentRow` with `AgentCardView` etc.)

```swift
import SwiftUI
import QuackKit

/// The unified notch panel content and its three states:
/// expanded (hover) / peek (ambient dot) / collapsed (invisible hover target).
struct NotchContentView: View {
    @ObservedObject var model: NotchContentViewModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { model.onHoverChange?($0) }
    }

    @ViewBuilder
    private var content: some View {
        if model.isOpen {
            expanded
        } else if model.showsPeek {
            peek
        } else {
            Color.black.opacity(0.001)   // hover target only
        }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            if model.agentsEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    agentsZone
                }
                .padding(.horizontal, 14)
                .padding(.top, model.contentTopInset + 10)
                .padding(.bottom, 10)
            } else {
                Spacer().frame(height: model.contentTopInset + 6)
            }
            Spacer(minLength: 0)
            if model.mediaEnabled {
                MediaStripView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NotchTheme.panel)
        .clipShape(NotchShape())
        .foregroundStyle(.white)
    }

    // Task 9 replaces this placeholder with header + usage + cards.
    @ViewBuilder
    private var agentsZone: some View {
        if !model.integrationInstalled {
            Text("Enable Claude integration in Quack Settings")
                .font(.system(size: 11)).foregroundStyle(NotchTheme.textMuted)
        } else if model.agents.isEmpty {
            Text("No active agents")
                .font(.system(size: 11)).foregroundStyle(NotchTheme.textMuted)
        } else {
            ForEach(model.agents) { agent in
                Text("\(agent.project) — \(agent.status.rawValue)")
                    .font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary)
            }
        }
    }

    private var peek: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.needsYouCount > 0 ? NotchTheme.orange : NotchTheme.green)
                    .frame(width: 6, height: 6)
                Text("\(model.activeCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
```

- [ ] **Step 7: Create `Sources/Quack/Notch/NotchService.swift`** (delete the three old files in this same step)

```swift
import AppKit
import SwiftUI
import Combine
import QuackKit

/// Owns THE one notch panel and aggregates both content sources: now-playing
/// media and Claude agent snapshots. Replaces NotchMediaService — the notch is
/// a single physical spot, so a single service must own the panel, its hover
/// state, and its geometry. Zones start/stop with their settings flags.
/// Same geometry rule as before: panel top anchored at cocoaNotchRect.minY,
/// content hangs DOWN, never behind the physical cutout.
@MainActor
final class NotchService: NSObject, ManagedService {
    private let settings: SettingsStore
    private let reader = NotchScreenReader()
    private let model = NotchContentViewModel()
    private let nowPlaying = NowPlayingService()
    private let agentsService: ClaudeAgentsService
    private var panel: NotchPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var wired = false
    private var mediaRunning = false
    private var agentsRunning = false

    private let hoverMargin: CGFloat = 24
    private let expandedWidth: CGFloat = 360
    private let mediaOnlyContentHeight: CGFloat = 58

    init(settings: SettingsStore, installer: ClaudeConfigInstaller) {
        self.settings = settings
        self.agentsService = ClaudeAgentsService(installer: installer)
    }

    func start() {
        reader.onChange = { [weak self] in self?.repositionOrTeardown() }
        reader.startObserving()
        applyZoneFlags()
        guard reader.currentLayout() != nil else { return }
        buildPanelIfNeeded()
        wireIfNeeded()
        reposition()
    }

    func stop() {
        reader.stopObserving()
        reader.onChange = nil
        cancellables.removeAll()
        wired = false
        if mediaRunning { nowPlaying.stop(); mediaRunning = false }
        if agentsRunning { agentsService.stop(); agentsRunning = false }
        panel?.orderOut(nil)
        panel = nil
        model.isOpen = false
        model.track = nil
        model.agents = []
    }

    private func wireIfNeeded() {
        guard !wired else { return }
        wired = true
        model.onHoverChange = { [weak self] h in self?.handleHover(h) }
        model.onToggle = { [weak self] in self?.nowPlaying.togglePlayPause() }
        model.onNext = { [weak self] in self?.nowPlaying.next() }
        model.onPrevious = { [weak self] in self?.nowPlaying.previous() }

        nowPlaying.$track
            .sink { [weak self] t in self?.model.track = t }
            .store(in: &cancellables)
        agentsService.$agents
            .sink { [weak self] a in self?.model.agents = a; self?.repositionIfNeeded() }
            .store(in: &cancellables)
        agentsService.$usage
            .sink { [weak self] u in self?.model.usage = u }
            .store(in: &cancellables)
        agentsService.$integrationInstalled
            .sink { [weak self] i in self?.model.integrationInstalled = i }
            .store(in: &cancellables)
        settings.$settings
            .map { ($0.notchMediaEnabled, $0.notchAgentsEnabled) }
            .removeDuplicates(by: ==)
            .sink { [weak self] _ in self?.applyZoneFlags(); self?.repositionIfNeeded() }
            .store(in: &cancellables)
    }

    /// Starts/stops each zone's data source to match its flag. The coordinator
    /// handles the whole-feature lifecycle; this handles the per-zone one.
    private func applyZoneFlags() {
        let s = settings.settings
        model.mediaEnabled = s.notchMediaEnabled
        model.agentsEnabled = s.notchAgentsEnabled
        if s.notchMediaEnabled != mediaRunning {
            mediaRunning = s.notchMediaEnabled
            mediaRunning ? nowPlaying.start() : nowPlaying.stop()
        }
        if s.notchAgentsEnabled != agentsRunning {
            agentsRunning = s.notchAgentsEnabled
            agentsRunning ? agentsService.start() : agentsService.stop()
        }
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let p = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: expandedWidth, height: 40))
        guard let content = p.contentView else { return }
        let host = NSHostingView(rootView: NotchContentView(model: model))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        panel = p
    }

    private func repositionOrTeardown() {
        guard reader.currentLayout() != nil else {
            panel?.orderOut(nil); model.isOpen = false; return
        }
        buildPanelIfNeeded()
        wireIfNeeded()
        reposition()
    }

    private func repositionIfNeeded() {
        // Card count / zone flags change the expanded height while open, and
        // the peek pill needs the panel present while closed.
        reposition()
    }

    /// Same anchor rule as the media-only panel: top edge at the BOTTOM of the
    /// notch cutout (cocoaNotchRect.minY), hanging downward.
    private func reposition() {
        guard let layout = reader.currentLayout(), let panel else { return }
        let notchBottom = layout.cocoaNotchRect.minY
        let width = model.isOpen ? expandedWidth : max(layout.cocoaNotchRect.width, 120)
        let height = model.isOpen ? expandedHeight() : hoverMargin
        let centerX = layout.cocoaNotchRect.midX
        let originX = centerX - width / 2
        let originY = notchBottom - height
        model.contentTopInset = 0
        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    /// Expanded height from visible zones. Constants match the Task 9 views;
    /// tuned on hardware in Task 12.
    private func expandedHeight() -> CGFloat {
        var h: CGFloat = 10                                     // top padding
        if model.agentsEnabled {
            h += 30                                             // header row
            if model.usage != nil { h += 52 }                   // 5h/7d section
            if !model.integrationInstalled || model.agents.isEmpty {
                h += 28                                         // CTA / empty row
            } else {
                let visible = min(model.agents.count, 3)
                h += CGFloat(visible) * 92 + CGFloat(visible - 1) * 8
            }
            h += 10                                             // zone bottom pad
        } else {
            h += mediaOnlyContentHeight - 10
        }
        if model.mediaEnabled { h += 58 }                       // pinned strip
        return min(h, 480)
    }

    private func handleHover(_ hovering: Bool) {
        model.isOpen = hovering
        reposition()
    }
}
```

Delete old files:

```bash
git rm Sources/Quack/MenuBar/NotchMediaService.swift Sources/Quack/Notch/NotchMediaViewModel.swift Sources/Quack/Notch/NotchMediaView.swift
```

- [ ] **Step 8: Rewire `AppEnvironment`**

Replace the declaration (from Task 0's block):

```swift
    private let notchService: NotchService
    private let notchRevealService: NotchIconRevealService
```

Replace the init lines:

```swift
        self.notchRevealService = NotchIconRevealService(settings: settings, permissions: permissions)
        self.notchService = NotchService(settings: settings, installer: claudeInstaller)
```

(Note: `claudeInstaller` is a `let` property with an inline initializer from Task 6, so it is available here.) Replace the services-map entry:

```swift
            .notchReveal: notchRevealService,
            .notch: notchService,
```

- [ ] **Step 9: Build, test, verify media on hardware**

Run: `swift build 2>&1 | tail -3` — `Build complete!`
Run: `swift test 2>&1 | tail -3` — PASS (fix any `.notchMedia` test references found in Step 2).
Run: `./Scripts/install.sh`; with `notchMediaEnabled` on, hover the notch → media panel appears with the strip at the bottom, transport controls work. (Toggle arrives in Task 10; if the flag is off in the persisted settings, flip it by running once with a temporary `settings.update { $0.notchMediaEnabled = true }` line or wait for Task 10 — minimum bar here is a clean launch + panel when the flag is on.)

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor(notch): single NotchService owns unified panel; media becomes pinned strip"
```

---

### Task 9: Agent zone UI — header, usage bars, cards

**Files:**
- Create: `Sources/Quack/Notch/NotchHeaderView.swift`
- Create: `Sources/Quack/Notch/UsageLimitsView.swift`
- Create: `Sources/Quack/Notch/AgentCardView.swift`
- Modify: `Sources/Quack/Notch/NotchContentView.swift` (replace placeholder `agentsZone`)

**Interfaces:**
- Consumes: `NotchContentViewModel`, `NotchTheme`, `AgentSnapshot`, `AgentStatus`, `UsageLimits`.
- Produces: `NotchHeaderView(model:)`, `UsageLimitsView(usage:)`, `AgentCardView(agent:)`.

- [ ] **Step 1: Create `Sources/Quack/Notch/NotchHeaderView.swift`**

```swift
import SwiftUI

/// Header row: asterisk + "N agents" left; tokens-today and needs-you pills right.
struct NotchHeaderView: View {
    @ObservedObject var model: NotchContentViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "asterisk")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NotchTheme.orange)
            Text("\(model.agents.count) agent\(model.agents.count == 1 ? "" : "s")")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer(minLength: 8)
            if let tokens = model.tokensTodayText {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 8))
                    Text("\(tokens) today").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(NotchTheme.orangeSoft)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(NotchTheme.orangeSoft.opacity(0.14)))
            }
            if model.needsYouCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(NotchTheme.orange).frame(width: 5, height: 5)
                    Text("\(model.needsYouCount) needs you").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(NotchTheme.orange)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().stroke(NotchTheme.orange, lineWidth: 1))
            }
        }
    }
}
```

- [ ] **Step 2: Create `Sources/Quack/Notch/UsageLimitsView.swift`**

```swift
import SwiftUI
import QuackKit

/// "Claude" section: 5h and 7d rate-limit bars (green = remaining) with reset info.
struct UsageLimitsView: View {
    let usage: UsageLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: 9, weight: .bold))
                Text("Claude").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(NotchTheme.textSecondary)
            if let used = usage.fiveHourUsedPercent {
                row(label: "5h", usedPercent: used, resetsAt: usage.fiveHourResetsAt, sameDayReset: true)
            }
            if let used = usage.sevenDayUsedPercent {
                row(label: "7d", usedPercent: used, resetsAt: usage.sevenDayResetsAt, sameDayReset: false)
            }
        }
    }

    private func row(label: String, usedPercent: Double, resetsAt: Date?, sameDayReset: Bool) -> some View {
        let remaining = max(0, min(100, 100 - usedPercent))
        return HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(NotchTheme.textMuted)
                .frame(width: 16, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(NotchTheme.green)
                        .frame(width: geo.size.width * remaining / 100)
                }
            }
            .frame(width: 110, height: 5)
            Text(detail(remaining: remaining, resetsAt: resetsAt, sameDayReset: sameDayReset))
                .font(.system(size: 10)).foregroundStyle(NotchTheme.textMuted).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func detail(remaining: Double, resetsAt: Date?, sameDayReset: Bool) -> String {
        var text = "\(Int(remaining.rounded()))% left"
        if let resetsAt {
            let f = DateFormatter()
            f.dateFormat = sameDayReset ? "h:mm a" : "MMM d"
            text += " · resets \(f.string(from: resetsAt))"
        }
        return text
    }
}
```

- [ ] **Step 3: Create `Sources/Quack/Notch/AgentCardView.swift`**

```swift
import SwiftUI
import QuackKit

/// One agent card: status dot + project + branch, one-line status message,
/// then the pill row (status / model / progress).
struct AgentCardView: View {
    let agent: AgentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Image(systemName: "asterisk")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.orange)
                Text(agent.project)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary).lineLimit(1)
                if let branch = agent.branch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                        Text(branch).font(.system(size: 10))
                    }
                    .foregroundStyle(NotchTheme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(agent.statusMessage ?? " ")
                .font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary).lineLimit(1)
            HStack(spacing: 8) {
                statusPill
                if let model = agent.model { grayPill(model) }
                Spacer(minLength: 0)
                if let progress = agent.progress { progressPill(progress) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(NotchTheme.card))
    }

    private var dotColor: Color {
        switch agent.status {
        case .needsYou: return NotchTheme.orange
        case .working: return NotchTheme.green
        case .idle: return NotchTheme.textMuted
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch agent.status {
        case .needsYou:
            pill(icon: "exclamationmark.triangle", text: "NEEDS YOU",
                 fg: NotchTheme.orangeSoft, bg: NotchTheme.orangeSoft.opacity(0.16))
        case .working:
            pill(icon: "bolt.fill", text: "WORKING",
                 fg: NotchTheme.green, bg: NotchTheme.green.opacity(0.14))
        case .idle:
            pill(icon: nil, text: "IDLE",
                 fg: NotchTheme.textMuted, bg: Color.white.opacity(0.08))
        }
    }

    private func pill(icon: String?, text: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 7, weight: .bold)) }
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(bg))
    }

    private func grayPill(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .foregroundStyle(NotchTheme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func progressPill(_ progress: Double) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(Color.white.opacity(0.15))
                .frame(width: 24, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(agent.status == .needsYou ? NotchTheme.orangeSoft : NotchTheme.green)
                        .frame(width: 24 * progress)
                }
            Text("\(Int((progress * 100).rounded()))%")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}
```

- [ ] **Step 4: Replace `agentsZone` in `NotchContentView.swift`**

Replace the placeholder `agentsZone` and add the header/usage — the `if model.agentsEnabled` block in `expanded` becomes:

```swift
                VStack(alignment: .leading, spacing: 10) {
                    NotchHeaderView(model: model)
                    if let usage = model.usage { UsageLimitsView(usage: usage) }
                    agentsZone
                }
```

and:

```swift
    @ViewBuilder
    private var agentsZone: some View {
        if !model.integrationInstalled {
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.orange)
                Text("Enable Claude integration in Quack Settings")
                    .font(.system(size: 11)).foregroundStyle(NotchTheme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.agents.isEmpty {
            Text("No active agents")
                .font(.system(size: 11)).foregroundStyle(NotchTheme.textMuted)
        } else if model.agents.count > 3 {
            ScrollView(showsIndicators: false) { cards }
                .frame(maxHeight: 3 * 92 + 2 * 8)
        } else {
            cards
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(model.agents) { AgentCardView(agent: $0) }
        }
    }
```

- [ ] **Step 5: Build + hardware check**

Run: `swift build 2>&1 | tail -3` — `Build complete!`
Run `./Scripts/install.sh`. With the Task 2 manual integration live and `notchAgentsEnabled` still false, nothing changes (agents zone off). Flip `notchAgentsEnabled` on (temporary code line or wait for Task 10's toggle) → hover shows header + usage bars + a card for the session running this work. Fix visual glitches (spacing/height mismatches with `expandedHeight()`).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(notch): agent zone UI — header pills, 5h/7d usage bars, agent cards"
```

---

### Task 10: Settings UI — toggles + install/uninstall

**Files:**
- Modify: `Sources/Quack/Settings/SettingsView.swift` (windows-tab pane composition ~line 156–160; add section struct next to `NotchRevealSection` ~line 1035)
- Modify: `Sources/Quack/AppEnvironment.swift` (install/uninstall passthroughs)

**Interfaces:**
- Consumes: `s.binding(\.notchMediaEnabled)`, `s.binding(\.notchAgentsEnabled)` (SettingsBinding), `AppEnvironment.claudeInstaller`.
- Produces: `NotchSection` view; `AppEnvironment.claudeIntegrationInstalled() -> Bool`, `installClaudeIntegration() -> Bool`, `removeClaudeIntegration() -> Bool` (Bool = success; errors logged).

- [ ] **Step 1: AppEnvironment passthroughs** (near the other funcs):

```swift
    /// Claude Code integration state/actions for the settings pane. Returns
    /// success; failures are logged, never fatal (the panel degrades quietly).
    func claudeIntegrationInstalled() -> Bool {
        claudeInstaller.isInstalled()
    }

    @discardableResult
    func installClaudeIntegration() -> Bool {
        do { try claudeInstaller.install(); return true }
        catch { Log.error("Claude integration install failed: \(error)"); return false }
    }

    @discardableResult
    func removeClaudeIntegration() -> Bool {
        do { try claudeInstaller.uninstall(); return true }
        catch { Log.error("Claude integration uninstall failed: \(error)"); return false }
    }
```

Check `Log` API first: `grep -n "func " Sources/Quack/Log.swift` — use its actual error-logging function name.

- [ ] **Step 2: Add `NotchSection` to `SettingsView.swift`** (above `NotchRevealSection`):

```swift
// MARK: - Notch panel

private struct NotchSection: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var installed = false

    var body: some View {
        let s = env.settingsStore
        Section("Notch panel") {
            Toggle("Show the media player in the notch", isOn: s.binding(\.notchMediaEnabled))
            Text("Hover the notch to see the current track and control playback.")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            Toggle("Show Claude Code agents in the notch", isOn: s.binding(\.notchAgentsEnabled))
            Text("Live status of your Claude Code sessions: which agents are working, which need you, and your usage limits.")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            if s.settings.notchAgentsEnabled {
                HStack {
                    if installed {
                        Text("Claude integration installed.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Remove") {
                            env.removeClaudeIntegration()
                            installed = env.claudeIntegrationInstalled()
                        }
                    } else {
                        Text("Needs hooks in ~/.claude/settings.json to see your agents.")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Button("Enable Claude integration") {
                            env.installClaudeIntegration()
                            installed = env.claudeIntegrationInstalled()
                        }
                    }
                }
            }
        }
        .onAppear { installed = env.claudeIntegrationInstalled() }
    }
}
```

- [ ] **Step 3: Compose it in the windows tab**

At the pane composition (`case .windows:` around line 156), insert before `NotchRevealSection()`:

```swift
                NotchSection()
                NotchRevealSection()
```

- [ ] **Step 4: Build + hardware check**

`swift build 2>&1 | tail -3` → `Build complete!`; `./Scripts/install.sh`. In Settings → Windows: both toggles present; agents toggle reveals the integration row; "Claude integration installed." shows (Task 2's manual install is detected). Toggle media/agents on/off → panel zones appear/disappear on hover. Uninstall/re-install via the buttons; check `~/.claude/settings.json` diff after each (`git diff --no-index` against the backup) — statusLine preserved, hooks added/removed cleanly.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(settings): notch panel section — media/agents toggles + Claude integration install"
```

---

### Task 11: Tokens-today pill (usage.db, optional)

**Files:**
- Create: `Sources/QuackKit/Agents/TokenFormat.swift`
- Test: `Tests/QuackKitTests/TokenFormatTests.swift`
- Create: `Sources/Quack/Agents/TokensTodayReader.swift`
- Modify: `Package.swift` (link sqlite3 into the `Quack` target)
- Modify: `Sources/Quack/Notch/NotchService.swift` (populate `model.tokensTodayText`)

**Interfaces:**
- Consumes: `~/.claude/usage.db` (third-party aggregator; `turns(timestamp TEXT, output_tokens INTEGER)`).
- Produces: `TokenFormat.compact(_: Int) -> String`; `TokensTodayReader.todayOutputTokens(dbPath: String, now: Date) -> Int?`.
- Note: the spec's field-map lists statusLine as primary for tokens-today, but statusLine JSON carries no cumulative token counts (verify against Task 2's capture — if it *does*, prefer it). usage.db is the implemented source; pill hides when unavailable.

- [ ] **Step 1: Write the failing `TokenFormat` tests**

```swift
import Testing
@testable import QuackKit

@Suite struct TokenFormatTests {
    @Test func belowThousandVerbatim() { #expect(TokenFormat.compact(900) == "900") }
    @Test func thousandsRounded() {
        #expect(TokenFormat.compact(215_400) == "215k")
        #expect(TokenFormat.compact(1_499) == "1k")
    }
    @Test func millionsOneDecimalUnderTen() {
        #expect(TokenFormat.compact(1_500_000) == "1.5M")
        #expect(TokenFormat.compact(12_400_000) == "12M")
    }
}
```

Run: `swift test --filter TokenFormatTests 2>&1 | tail -3` — FAIL (type missing).

- [ ] **Step 2: Implement `Sources/QuackKit/Agents/TokenFormat.swift`**

```swift
import Foundation

/// Compact token counts for the header pill: 215_400 -> "215k", 1_500_000 -> "1.5M".
public enum TokenFormat {
    public static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000:
            return "\(tokens)"
        case ..<1_000_000:
            return "\(Int((Double(tokens) / 1000).rounded()))k"
        default:
            let m = Double(tokens) / 1_000_000
            return m >= 10 ? "\(Int(m.rounded()))M" : String(format: "%.1fM", m)
        }
    }
}
```

Run: `swift test --filter TokenFormatTests 2>&1 | tail -3` — PASS.

- [ ] **Step 3: Link sqlite3 and implement the reader**

In `Package.swift`, add to the `Quack` executable target's `linkerSettings`:

```swift
                .linkedLibrary("sqlite3"),
```

`Sources/Quack/Agents/TokensTodayReader.swift`:

```swift
import Foundation
import SQLite3

/// Optional enrichment: today's output tokens from the third-party usage.db
/// aggregator (~/.claude/usage.db), read-only. nil (db missing, locked, or
/// schema mismatch) simply hides the header pill — never an error state.
enum TokensTodayReader {
    static func todayOutputTokens(dbPath: String, now: Date = Date()) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // turns.timestamp is ISO-8601 UTC; compare lexically against local
        // midnight expressed in UTC.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let cutoff = fmt.string(from: Calendar.current.startOfDay(for: now))

        var stmt: OpaquePointer?
        let sql = "SELECT COALESCE(SUM(output_tokens), 0) FROM turns WHERE timestamp >= ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, cutoff, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let total = sqlite3_column_int64(stmt, 0)
        return total > 0 ? Int(total) : nil
    }
}
```

Verify the schema assumption against the real db first:

```bash
sqlite3 ~/.claude/usage.db "SELECT timestamp, output_tokens FROM turns ORDER BY timestamp DESC LIMIT 3"
```

Expected: ISO timestamps + integer tokens. If the format differs, adjust `cutoff` accordingly.

- [ ] **Step 4: Wire into `NotchService`**

In `applyZoneFlags()` (or a small helper called from it and from `handleHover(true)` so the number refreshes on open), set:

```swift
        model.tokensTodayText = s.notchAgentsEnabled
            ? TokensTodayReader.todayOutputTokens(
                dbPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/usage.db").path
              ).map(TokenFormat.compact)
            : nil
```

Call the refresh from `handleHover(_:)` when `hovering == true` (cheap query, on open only).

- [ ] **Step 5: Build, test, verify**

`swift test 2>&1 | tail -3` — PASS. `swift build 2>&1 | tail -3` — complete. `./Scripts/install.sh` → header shows "⚡ Nk today" when usage.db has today's rows; absent otherwise.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(notch): tokens-today header pill from optional usage.db"
```

---

### Task 12: Hardware verification (manual, final)

**Files:** none (fix-up commits as needed).

- [ ] **Step 1: Full rebuild + install** — `./Scripts/install.sh`.
- [ ] **Step 2: Install round trip** — Settings: Remove integration → check `~/.claude/settings.json` (hooks gone, `statusLine` restored to `/Users/strativ/.claude/statusline.sh`); Enable → hooks back, wrapper active, status line in a live Claude session looks unchanged (caveman badge etc. intact).
- [ ] **Step 3: Two real agents** — start Claude Code sessions in two different projects. Hover the notch: two cards, correct project names, branches, model pill, live "Editing/Running …" messages while working.
- [ ] **Step 4: Status transitions** — let one session finish (Stop) → card flips to NEEDS YOU with the last assistant line; trigger a permission prompt in the other → NEEDS YOU with the notification message; send a new prompt → back to WORKING.
- [ ] **Step 5: Peek** — without hovering: pill with dot+count below the notch; orange while any needs-you, green while only working; disappears when sessions go stale/end (wait or delete the state files).
- [ ] **Step 6: Usage section** — 5h/7d bars render with plausible percentages and reset labels; header tokens pill plausible vs `sqlite3` spot-check.
- [ ] **Step 7: Media coexistence** — play music: strip pinned at the bottom, controls work, "Nothing playing" when idle; media-only mode (agents toggle off) still behaves like the old panel; agents-only mode (media off) drops the strip.
- [ ] **Step 8: Degradation** — quit all Claude sessions → "No active agents"; `mv ~/.claude/quack/sessions ~/.claude/quack/sessions.bak` → panel shows empty state, no crash; restore.
- [ ] **Step 9: Geometry** — panel hangs below the notch cutout on this hardware (nothing hidden behind the camera housing); collapse/expand does not flicker across screen-parameter changes (plug/unplug an external display if available).
- [ ] **Step 10: Tune + commit** — fix any `expandedHeight()` vs SwiftUI-content mismatches found; final commit:

```bash
git add -A
git commit -m "fix(notch): hardware-verified sizing and polish for agent panel"
```

---

## Self-review (done at plan time)

- **Spec coverage:** decisions 1–7 → Tasks 8 (unified), 8+10 (peek/zones), 1–2+6 (push pipeline + consent), 9 (full parity UI incl. usage), 4 (A/B/C reducer rules). Baseline blocker → Task 0. Degradation table → Tasks 4 (prune/fail-soft), 7 (fail-soft reads), 9 (CTA/empty states), 12 (verified). Testing section → Tasks 1–5 unit, 2+12 hardware. Tokens-today source deviation from spec's field-map called out in Task 11 (statusLine has no cumulative tokens; usage.db implemented, pill hides otherwise).
- **Types:** `SessionFiles`/`AgentSnapshot`/`UsageLimits`/`StateFileRaw`/`StatusFileRaw` signatures consistent across Tasks 3–4–7–8–9; `statusLineWrapper(previousCommand:)` consistent Tasks 1–2–6; `Feature.notch` rename propagated Task 8 steps 2/8.
- **Known risk:** field names in `StatusFileRaw` and hook stdin are best-knowledge; Task 2 exists precisely to correct them before Tasks 3+ harden.
