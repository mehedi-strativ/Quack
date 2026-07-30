import Foundation

/// JS plugin Quack installs into ~/.config/opencode/plugins/ when the user
/// enables the opencode integration. Kept as a pure constant so the shape is
/// unit-tested and the installer only does file IO. Writes the SAME
/// state-file shape as the Claude Code hook (StateFileRaw) so AgentReducer
/// renders both sources unchanged. Fail-soft by design: every hook body is
/// wrapped in try/catch so a bug here can never break an opencode session —
/// a thrown error in "tool.execute.before" would otherwise abort the tool call.
public enum OpencodeIntegrationScripts {
    public static let pluginScript = #"""
    import { mkdirSync, existsSync, readFileSync, writeFileSync, renameSync } from "node:fs"
    import { homedir } from "node:os"
    import { join } from "node:path"

    // Quack notch integration for opencode. Writes per-session status to
    // ~/.config/opencode/quack/sessions/<id>.state.json in the same shape
    // Quack's Claude Code hook uses, so Quack's one reducer renders both.
    // Installed/removed by Quack.app (Settings -> Notch panel).
    const DIR = join(homedir(), ".config", "opencode", "quack", "sessions")

    function writeState(sessionID, patch) {
      try {
        if (!sessionID) return
        mkdirSync(DIR, { recursive: true })
        const file = join(DIR, `${sessionID}.state.json`)
        let prev = {}
        if (existsSync(file)) {
          try { prev = JSON.parse(readFileSync(file, "utf8")) } catch {}
        }
        const next = { ...prev, ...patch, ts: new Date().toISOString() }
        const tmp = `${file}.tmp`
        writeFileSync(tmp, JSON.stringify(next))
        renameSync(tmp, file)
      } catch {}
    }

    function truncate(s, n = 200) {
      return typeof s === "string" ? s.slice(0, n) : undefined
    }

    export const QuackNotchPlugin = async ({ directory, worktree, $ }) => {
      const cwd = directory || worktree || ""
      const project = cwd.split("/").filter(Boolean).pop() || "unknown"

      let branch
      try {
        if (cwd) branch = (await $`git -C ${cwd} branch --show-current`.text()).trim() || undefined
      } catch {}

      // Walk the parent-process chain to the hosting GUI app (Terminal,
      // iTerm2, VS Code, ...), same technique as Quack's Claude Code hook.
      let host
      try {
        let pid = process.ppid
        for (let i = 0; i < 12 && pid && pid > 1; i++) {
          const comm = (await $`ps -o comm= -p ${pid}`.text()).trim()
          const m = comm.match(/^(.*)\.app\/Contents\/MacOS\/[^/]+$/)
          if (m) { host = { pid, app: m[1].split("/").pop() }; break }
          const next = (await $`ps -o ppid= -p ${pid}`.text()).trim()
          pid = next ? parseInt(next, 10) : 0
        }
      } catch {}

      const base = () => ({
        cwd, project,
        ...(branch ? { branch } : {}),
        ...(host ? { host_pid: host.pid, host_app: host.app } : {}),
      })

      return {
        event: async ({ event }) => {
          try {
            switch (event.type) {
              case "session.created":
                writeState(event.properties?.info?.id, { ...base(), status: "idle", event: "SessionStart" })
                break
              case "session.deleted":
                writeState(event.properties?.info?.id, { ...base(), status: "ended", event: "SessionEnd" })
                break
              case "session.idle":
                writeState(event.properties?.sessionID, { ...base(), status: "idle", event: "Stop" })
                break
              case "session.error": {
                const err = event.properties?.error
                const msg = truncate(err?.data?.message || err?.name || "Session error")
                writeState(event.properties?.sessionID, { ...base(), status: "needs_you", event: "Notification", notification_message: msg })
                break
              }
              case "session.status": {
                const sid = event.properties?.sessionID
                const st = event.properties?.status
                if (st?.type === "busy") writeState(sid, { ...base(), status: "working", event: "PreToolUse" })
                else if (st?.type === "idle") writeState(sid, { ...base(), status: "idle", event: "Stop" })
                else if (st?.type === "retry") writeState(sid, { ...base(), status: "needs_you", event: "Notification", notification_message: truncate(st.message || "Retrying…") })
                break
              }
              case "permission.updated": {
                const p = event.properties
                writeState(p?.sessionID, { ...base(), status: "needs_you", event: "PermissionRequest", ...(p?.title ? { notification_message: truncate(`Needs permission: ${p.title}`) } : {}) })
                break
              }
            }
          } catch {}
        },

        "tool.execute.before": async (input, output) => {
          try {
            const args = output?.args || {}
            const target = args.filePath || args.command || args.pattern
            writeState(input.sessionID, {
              ...base(), status: "working", event: "PreToolUse",
              last_tool: input.tool, ...(target ? { last_tool_target: truncate(String(target)) } : {}),
            })
          } catch {}
        },

        "tool.execute.after": async (input) => {
          try {
            const args = input?.args || {}
            const target = args.filePath || args.command || args.pattern
            writeState(input.sessionID, {
              ...base(), status: "working", event: "PostToolUse", last_tool: input.tool,
              ...(target ? { last_tool_target: truncate(String(target)) } : {}),
            })
          } catch {}
        },

        "chat.params": async (input) => {
          try {
            const modelID = input?.model?.modelID
            if (modelID) writeState(input.sessionID, { ...base(), model_id: modelID })
          } catch {}
        },
      }
    }
    """#
}
