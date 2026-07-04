# Notch Agents — Hardware Checkpoint Fixtures (Task 2)

Captured 2026-07-05 on the target Mac (macOS 26.5.x). These are the ground-truth
shapes Tasks 3–4 decode against.

## Environment findings (bind later tasks)

1. **Desktop-app sessions never invoke the statusLine command.** Only
   interactive terminal CLI sessions render a status line → only they write
   `.status.json`. Consequences:
   - Usage-limits section (5h/7d) populates only while ≥1 terminal session has
     reported; otherwise hidden (designed degradation).
   - Model pill: primary source is `state.model_id` (captured from the
     transcript by the Stop hook — commit `e9c7d3e`), NOT the statusline.
2. **Headless (`claude -p`) also never invokes statusLine** (verified by probe).
   Hooks DO fire for headless and desktop sessions.
3. Hook script content is read at exec time — edits to `~/.claude/quack/hook.sh`
   apply to already-running sessions immediately.
4. `rate_limits.*.resets_at` is **Unix epoch seconds (integer)**, not ISO-8601
   (per official statusline docs, confirmed schema below).
5. No cumulative token counts exist anywhere in the statusline payload
   (`cost` = USD + durations + line counts only) → tokens-today pill must use
   `usage.db` (Task 11) — plan's field-map note stands.
6. `model.display_name` is short ("Opus"), not versioned ("Opus 4.8") → the
   reducer maps `model_id` → versioned display name for reference-UI parity.

## Real captured `.state.json` (own session; hooks live end-to-end)

```json
{
  "session_id": "0a2b9045-11e1-41c5-800a-fe2870544ccb",
  "status": "working",
  "event": "UserPromptSubmit",
  "cwd": "/Users/strativ/Repositories/Quack",
  "project": "Quack",
  "branch": "notch-agents",
  "ts": "2026-07-04T18:35:15Z",
  "last_tool": "ScheduleWakeup",
  "last_tool_target": "",
  "last_assistant_line": "jq bug in plan's command (`(...)[]` on comma-stream). settings.json untouched (mv never ran). Fixed:",
  "model_id": "claude-fable-5"
}
```

Notes: `last_tool_target` may be `""` (not stripped in the PostToolUse EXTRA
path — decode must accept empty strings). Fields accumulate across events by
deep-merge design; `event` tells which one wrote `status`.

Observed event flow (multiple sessions): `SessionStart` → `idle`;
`UserPromptSubmit`/`PostToolUse` → `working`; `Stop`/`Notification` →
`needs_you`; `SessionEnd` → `ended`. Short-lived files containing only the
SessionStart BASE fields are common (desktop sessions opened and closed).

## `.status.json` shape (docs-verified schema; live capture pending a terminal session)

The wrapper dumps the raw statusline stdin verbatim. Official schema example
(fields the panel decodes are ✂-trimmed here; full payload has more keys):

```json
{
  "session_id": "abc123",
  "cwd": "/current/working/directory",
  "model": { "id": "claude-opus-4-8", "display_name": "Opus" },
  "workspace": { "current_dir": "/current/working/directory" },
  "cost": { "total_cost_usd": 0.01234 },
  "context_window": {
    "total_input_tokens": 15500,
    "total_output_tokens": 1200,
    "context_window_size": 200000,
    "used_percentage": 8,
    "remaining_percentage": 92
  },
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
  }
}
```

Presence rules (decode ALL of these as optional):
- `rate_limits` only for Pro/Max subscribers after first API response; each
  window independently absent.
- `context_window.current_usage` is `null` before first API call/after compact.
- Wrapper-verified manually end-to-end: stdin JSON → `<sid>.status.json`
  (atomic tmp+mv) → chains the user's existing `statusline.sh` unchanged.

## Checkpoint verdict

Hook pipeline: **PASSED live** (state files from 6+ real sessions, all fields).
StatusLine pipeline: **wrapper verified manually; schema docs-verified; live
terminal capture deferred to Task 12** (user runs desktop app; terminal session
pending).
