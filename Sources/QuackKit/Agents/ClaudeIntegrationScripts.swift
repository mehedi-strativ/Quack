import Foundation

/// Bash sources Quack installs into ~/.claude/quack/ when the user enables the
/// Claude Code integration. Kept as pure constants so the shape is unit-tested
/// and the installer only does file IO. Fail-soft by design: every path exits 0
/// so a broken script can never block Claude Code itself.
public enum ClaudeIntegrationScripts {
    /// Hook events Quack registers. One shared script, event name as $1.
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "PermissionRequest", "Stop", "SessionEnd"]

    /// How long a PermissionRequest waits for a notch answer before handing
    /// back to Claude Code's own prompt. Under the 600s command-hook timeout.
    public static let permissionWaitSeconds: Double = 300

    public static let hookScript = #"""
    #!/bin/bash
    # Quack Claude Code integration hook. Writes per-session agent state to
    # ~/.claude/quack/sessions/<session_id>.state.json for the notch panel.
    # Installed/removed by Quack.app (Settings -> Screen -> Notch). Fail-soft:
    # every exit path is 0 so this can never block Claude Code. The one wait:
    # a PermissionRequest is held for a notch-panel answer, but only while
    # Quack is running and listening, and never past the wait limit.
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
      UserPromptSubmit|PreToolUse|PostToolUse) STATUS="working" ;;
      Stop|Notification|PermissionRequest) STATUS="needs_you" ;;
      SessionEnd) STATUS="ended" ;;
    esac

    EXTRA='{}'
    # A blocking, user-facing tool means Claude has stopped and is waiting on
    # YOU — PostToolUse won't fire until you answer, so PreToolUse is the only
    # signal. Flip to needs_you and surface the question text.
    if [ "$EVENT" = "PreToolUse" ]; then
      TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
      case "$TOOL" in
        AskUserQuestion)
          STATUS="needs_you"
          MSG=$(printf '%s' "$INPUT" | jq -r '(.tool_input.questions // [])[0].question // empty' 2>/dev/null | head -1 | cut -c1-200)
          [ -z "$MSG" ] && MSG="Waiting for your answer"
          EXTRA=$(jq -n --arg m "$MSG" '{notification_message:$m}') ;;
        ExitPlanMode)
          STATUS="needs_you"
          EXTRA=$(jq -n '{notification_message:"Waiting for plan approval"}') ;;
      esac
    fi
    if [ "$EVENT" = "PermissionRequest" ]; then
      TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
      [ -n "$TOOL" ] && EXTRA=$(jq -n --arg t "$TOOL" '{notification_message:("Needs permission: " + $t)}')
    fi
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
    if [ "$EVENT" = "SessionStart" ]; then
      PID=$$
      HOST_PID=""; HOST_APP=""
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
        [ -n "$PID" ] && [ "$PID" -gt 1 ] 2>/dev/null || break
        CMD=$(ps -o comm= -p "$PID" 2>/dev/null)
        case "$CMD" in
          *.app/Contents/MacOS/*)
            HOST_PID="$PID"
            HOST_APP=$(printf '%s' "$CMD" | sed -E 's|.*/([^/]+)\.app/Contents/MacOS/.*|\1|')
            break ;;
        esac
      done
      [ -n "$HOST_PID" ] && EXTRA=$(jq -n --arg p "$HOST_PID" --arg a "$HOST_APP" '{host_pid:($p|tonumber), host_app:$a}')
    fi
    if [ "$EVENT" = "Stop" ]; then
      TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
      if [ -f "$TRANSCRIPT" ]; then
        LAST=$(tail -300 "$TRANSCRIPT" 2>/dev/null | jq -rs '[.[] | select(.type=="assistant" and .isSidechain != true) | .message.content[]? | select(.type=="text") | .text] | last // empty' 2>/dev/null | awk 'NF && $0 !~ /^```/ {print; exit}' | cut -c1-200)
        [ -n "$LAST" ] && EXTRA=$(jq -n --arg l "$LAST" '{last_assistant_line:$l}')
        # Model id from the transcript: desktop-app sessions never invoke the
        # statusLine command, so this is the only model source there.
        MODEL_ID=$(tail -300 "$TRANSCRIPT" 2>/dev/null | jq -rs '[.[] | select(.type=="assistant" and .isSidechain != true) | .message.model // empty] | last // empty' 2>/dev/null | head -1 | cut -c1-64)
        [ -n "$MODEL_ID" ] && EXTRA=$(printf '%s' "$EXTRA" | jq --arg m "$MODEL_ID" '. + {model_id:$m}')
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

    # The session moved on: any request still listed was answered elsewhere.
    case "$EVENT" in
      UserPromptSubmit|Stop|SessionEnd) rm -f "$DIR/$SID".*.permission.json 2>/dev/null ;;
    esac

    # Hold the request for the notch panel. Output only on a panel answer;
    # anything else (timeout, "Terminal", Quack gone) exits silently so
    # Claude Code shows its own prompt.
    LISTEN="$HOME/.claude/quack/listening"
    if [ "$EVENT" = "PermissionRequest" ] && [ -n "$TOOL" ]; then
      LPID=$(cat "$LISTEN" 2>/dev/null)
      if [ -n "$LPID" ] && kill -0 "$LPID" 2>/dev/null; then
        RID="$SID.$$"
        REQ="$DIR/$RID.permission.json"
        DEC="$DIR/$RID.decision.json"
        trap 'rm -f "$REQ" "$REQ.tmp" "$DEC"' EXIT
        trap 'exit 0' TERM INT HUP
        SUMMARY=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.url // .tool_input.pattern // .tool_input.plan // (.tool_input | tostring)' 2>/dev/null | head -3 | cut -c1-300)
        QUESTIONS=$(printf '%s' "$INPUT" | jq -c '.tool_input.questions // [] | if type == "array" then . else [] end' 2>/dev/null)
        [ -n "$QUESTIONS" ] || QUESTIONS='[]'
        SUGGESTIONS=$(printf '%s' "$INPUT" | jq -c '.permission_suggestions // []' 2>/dev/null)
        [ -n "$SUGGESTIONS" ] || SUGGESTIONS='[]'
        jq -n --arg id "$RID" --arg sid "$SID" --arg t "$TOOL" --arg s "$SUMMARY" --arg p "$PROJECT" --arg cwd "$CWD" \
          --argjson sug "$SUGGESTIONS" --argjson q "$QUESTIONS" --argjson ts "$(date +%s)" \
          '{id:$id, session_id:$sid, tool_name:$t, summary:$s, project:$p, cwd:$cwd, ts:$ts} | with_entries(select(.value != "")) | . + {suggestions:$sug, questions:$q}' > "$REQ.tmp" 2>/dev/null \
          && mv "$REQ.tmp" "$REQ" 2>/dev/null || exit 0
        END=$(( $(date +%s) + \#(Int(permissionWaitSeconds)) ))
        while [ "$(date +%s)" -lt "$END" ]; do
          if [ -f "$DEC" ]; then
            # "suggestion" is an index into Claude's own permission_suggestions
            # (re-read from this hook's stdin, never from the decision file).
            # "message" is the user's "tell Claude what to do instead" text.
            # "answers" ({question: label}) answers an AskUserQuestion: the
            # tool runs with Claude's own input plus the answers.
            IDX=$(jq -r '.suggestion // empty' "$DEC" 2>/dev/null)
            ANSWERS=$(jq -c 'if (.answers | type) == "object" then .answers else empty end' "$DEC" 2>/dev/null)
            case "$(jq -r '.behavior // empty' "$DEC" 2>/dev/null)" in
              allow) if [ -n "$ANSWERS" ]; then
                printf '%s' "$INPUT" | jq -c --argjson a "$ANSWERS" '{hookSpecificOutput:{hookEventName:"PermissionRequest",
                  decision:{behavior:"allow", updatedInput:((.tool_input // {}) + {answers:$a})}}}'
              else
                UPDATE='[]'
                case "$IDX" in ''|*[!0-9]*) ;; *)
                  UPDATE=$(printf '%s' "$SUGGESTIONS" | jq -c --argjson i "$IDX" '[.[$i] // empty]' 2>/dev/null) ;;
                esac
                [ -n "$UPDATE" ] || UPDATE='[]'
                jq -nc --argjson u "$UPDATE" '{hookSpecificOutput:{hookEventName:"PermissionRequest",
                  decision:({behavior:"allow"} + (if ($u|length) > 0 then {updatedPermissions:$u} else {} end))}}'
              fi ;;
              deny)
                MSG=$(jq -r '.message // empty' "$DEC" 2>/dev/null)
                [ -n "$MSG" ] || MSG="The user denied this from the Quack notch panel."
                jq -nc --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}' ;;
            esac
            exit 0
          fi
          kill -0 "$LPID" 2>/dev/null && [ -f "$LISTEN" ] || exit 0   # Quack quit or stopped listening
          [ -f "$REQ" ] || exit 0                                     # cleared: answered in the terminal
          sleep 0.3
        done
      fi
    fi
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
    /// The previous command is emitted single-quoted (escaping embedded single
    /// quotes with the `'\''` idiom) rather than double-quoted, so a `"` in the
    /// path can never break out of the wrapper script.
    public static func statusLineWrapper(previousCommand: String?) -> String {
        let delegation: String
        if let previousCommand, !previousCommand.isEmpty {
            delegation = #"printf '%s' "$INPUT" | \#(shellSingleQuoted(previousCommand))"#
        } else {
            delegation = #"command -v jq >/dev/null 2>&1 && printf '%s' "$INPUT" | jq -r '.model.display_name // ""'"#
        }
        return statusLineWrapperTemplate.replacingOccurrences(of: "__PREV_STATUSLINE__", with: delegation)
    }

    /// Wraps `value` in single quotes for safe use as one shell word, escaping
    /// any embedded single quote as `'\''` (close quote, escaped literal quote,
    /// reopen quote).
    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
