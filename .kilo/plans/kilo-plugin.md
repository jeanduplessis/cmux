# Plan: Kilo Code Rich Integration Plugin for cmux

## Goal

Create a Kilo Code plugin at `~/.config/kilo/plugins/cmux-integration.ts` that provides Claude Code-level rich integration with cmux — sidebar status, targeted notifications, OSC suppression, and agent PID tracking.

## Background

Claude Code's integration is implemented as a bash wrapper script (`Resources/bin/claude`) that intercepts the `claude` command and injects hook flags. Each hook calls `cmux claude-hook <event>` which sends socket commands. The Kilo/OpenCode plugin system gives us a cleaner approach — we run *inside* the Kilo process and subscribe to events directly, no wrapper script needed.

## Event Mapping

| Claude Hook Event | Kilo Plugin Event(s) | cmux Commands |
|---|---|---|
| `session-start` | Plugin init (runs once at startup) | `set_agent_pid kilo_code <pid>` |
| `prompt-submit` | `permission.replied` (allow/deny) | `clear_notifications`, `set-status kilo_code Running` |
| `pre-tool-use` | `tool.execute.before` | `set-status kilo_code Running` (or verbose tool description) |
| `notification` (permission) | `permission.asked` | `notify`, `set-status kilo_code Needs input` |
| `stop`/`idle` | `session.idle` | `notify` (completion), `set-status kilo_code Idle` |
| `notification` (error) | `session.error` | `notify`, `set-status kilo_code Error` |
| `session-end` | `process.on("exit")` / `beforeExit` | `clear-status kilo_code`, `clear_agent_pid kilo_code`, `clear-notifications` |

## Files to Create

### 1. `~/.config/kilo/plugins/cmux-integration.ts` — Main plugin

Single file, no external dependencies (uses Bun's built-in `$` shell helper).

### 2. No other files needed

Unlike Claude Code's integration which requires a wrapper script, session store JSON file, and app-side Settings toggle, the plugin approach is self-contained.

## Plugin Architecture

```typescript
export const CmuxIntegration = async ({ $, directory }) => {
  // ── Guard: skip if not running inside cmux ──
  // Check process.env.CMUX_SOCKET_PATH and CMUX_WORKSPACE_ID
  // If missing, return empty hooks object (no-op)

  // ── Initialization (equivalent to session-start) ──
  // 1. Verify socket is alive: `cmux ping`
  // 2. Register agent PID: send `set_agent_pid kilo_code <process.pid>` via socket
  //    This enables OSC notification suppression
  // 3. Set initial status to Idle
  // 4. Track state: lastAssistantMessage, isRunning flag

  // ── Cleanup (equivalent to session-end) ──
  // Register process.on("exit") to:
  //   - clear_status kilo_code
  //   - clear_agent_pid kilo_code
  //   - clear_notifications
  // Use synchronous child_process.execSync as last resort since async won't
  // complete in exit handlers. Alternatively, use process.on("beforeExit").

  return {
    event: async ({ event }) => { /* dispatch to handlers below */ },
    "tool.execute.before": async (input, output) => { /* verbose status */ },
    "tool.execute.after": async (input) => { /* optional: log tool completion */ },
  }
}
```

## Detailed Event Handlers

### Init (Plugin Startup)

**Runs once** when Kilo loads the plugin.

```
1. Read env vars:
   - CMUX_SOCKET_PATH (or CMUX_SOCKET)
   - CMUX_WORKSPACE_ID (or CMUX_TAB_ID)
   - CMUX_SURFACE_ID (or CMUX_PANEL_ID)
2. If CMUX_SOCKET_PATH is not set → return {} (no-op, not in cmux)
3. Verify socket is alive: `cmux ping` (with 1s timeout)
   - If fails → return {} (cmux not running)
4. Register PID:
   $ `cmux set-status kilo_code Idle --icon pause.circle.fill --color '#8E8E93'`
   (Note: set_agent_pid is a v1 socket command, not exposed as CLI subcommand.
    We need to use the raw socket or find another way — see Open Questions)
5. Register cleanup handler via process.on("beforeExit") and process.on("SIGINT")
```

### `session.idle` → Completion Notification + Idle Status

Equivalent to Claude's `stop`/`idle` hook.

```
1. Build completion notification:
   - Use tracked lastAssistantMessage (captured from message.updated events)
   - Truncate to 200 chars
   - subtitle: "Completed" (or "Completed in <project>" using directory basename)
   - body: last assistant message summary
2. Send notification:
   $ `cmux notify --title "Kilo Code" --subtitle "${subtitle}" --body "${body}"`
3. Set status:
   $ `cmux set-status kilo_code Idle --icon pause.circle.fill --color '#8E8E93'`
4. Reset isRunning flag
```

### `session.error` → Error Notification + Error Status

```
1. Send notification:
   $ `cmux notify --title "Kilo Code" --subtitle "Error" --body "Session encountered an error"`
2. Set status:
   $ `cmux set-status kilo_code Error --icon exclamationmark.triangle.fill --color '#FF3B30'`
```

### `permission.asked` → Permission Notification + Needs Input Status

Equivalent to Claude's `notification` hook (permission path).

```
1. Extract permission details from event.properties (if available):
   - action type (read/write/execute)
   - target file/command
2. Build notification body
3. Send notification:
   $ `cmux notify --title "Kilo Code" --subtitle "Permission" --body "${body}"`
4. Set status:
   $ `cmux set-status kilo_code "Needs input" --icon bell.fill --color '#4C8DFF'`
```

### `permission.replied` → Clear Notifications + Running Status

Equivalent to Claude's `prompt-submit` (user just gave input).

```
1. Clear notifications:
   $ `cmux clear-notifications`
2. Set status:
   $ `cmux set-status kilo_code Running --icon bolt.fill --color '#4C8DFF'`
```

### `tool.execute.before` → Running/Verbose Status

Equivalent to Claude's `pre-tool-use` hook.

```
1. Clear any pending notifications (user granted permission, agent resumed)
   $ `cmux clear-notifications`
2. Determine status value:
   - If CMUX_KILO_VERBOSE env var is set, use verbose description:
     - "bash" tool → "Running <first word of command>"
     - "read" tool → "Reading <filename>"
     - "edit" tool → "Editing <filename>"
     - "write" tool → "Writing <filename>"
     - "glob" tool → "Searching <pattern>"
     - "grep" tool → "Grep <pattern>"
     - Default → tool name
   - Otherwise: "Running"
3. Set status:
   $ `cmux set-status kilo_code "${status}" --icon bolt.fill --color '#4C8DFF'`
```

### `message.updated` → Track Last Assistant Message

Not sent to cmux — just updates internal state for completion notifications.

```
1. If event indicates an assistant message update:
   - Extract message content/text
   - Store as lastAssistantMessage (truncated to 200 chars)
```

### `message.part.updated` → Set Running When Agent Starts Responding

```
1. If we're not already in "Running" state:
   $ `cmux set-status kilo_code Running --icon bolt.fill --color '#4C8DFF'`
2. Set isRunning = true
```

### Cleanup (Process Exit)

```
1. process.on("beforeExit"):
   - $ `cmux clear-status kilo_code`
   - $ `cmux clear-notifications`
   (Note: clear_agent_pid not exposed via CLI — see Open Questions)
2. process.on("SIGINT") / process.on("SIGTERM"):
   - Same cleanup
   - process.exit()
```

## Open Questions / Decisions Needed

### 1. `set_agent_pid` / `clear_agent_pid` — Not Exposed as CLI Commands

The `set_agent_pid` and `clear_agent_pid` commands are v1 socket protocol commands but are NOT exposed as `cmux` CLI subcommands. Claude Code's hooks use them via the internal `sendV1Command()` function in `cmux.swift`.

**Options:**

a) **Use raw socket communication from the plugin** — Connect to `CMUX_SOCKET_PATH` directly using Bun's `net` module or `unix` socket support. Send the v1 protocol text command. This is the most correct approach but adds complexity.

b) **Add `cmux set-agent-pid` and `cmux clear-agent-pid` CLI subcommands to cmux** — Small addition to `CLI/cmux.swift`. This would make the plugin cleaner and benefit any future agent integrations. **This is the recommended approach.**

c) **Skip PID registration entirely** — Rely on cmux's stale PID sweep being the fallback. Downside: OSC notification suppression won't work, so users may get duplicate notifications if Kilo also sends raw OSC sequences. If Kilo Code doesn't emit OSC notifications natively, this is not a problem.

**Recommendation:** Option (b) — add the CLI commands. It's a small change (2 new subcommands mapping to existing socket commands) and makes the plugin robust.

### 2. Should this plugin be shipped in the cmux repo or the Kilo Code repo?

**Options:**
a) Ship in the cmux repo as documentation/example (like the current OpenCode snippet in `docs/notifications.md`)
b) Ship in the Kilo Code repo as a built-in or recommended plugin
c) Both — maintain the canonical version someplace, reference it from the other

**Recommendation:** (a) for now — create it as a file in this repo that gets installed to `~/.config/kilo/plugins/`. The cmux app could even auto-install it (like it does with the Claude wrapper), but that's a separate feature.

### 3. Event data structure uncertainty

The OpenCode/Kilo plugin `event` handler receives `{ event }` where `event.type` is the event string. The actual properties/data attached to each event are not well-documented. Specifically:

- `permission.asked` — does it include the tool name, file path, or command being requested? Based on the source, `Permission.Request` includes `id`, `tool`, and request details, but the event bus may only publish a subset.
- `message.updated` — does it include the full message content or just an ID? We may need to use `client.session.messages()` to fetch content.
- `session.idle` — does it include session ID? Likely yes based on the event bus pattern.

**Mitigation:** Start with defensive handling. If event data is insufficient, use the `client` SDK (e.g., `client.session.messages()`) to fetch what we need. We can refine as we test.

### 4. Cleanup reliability on process exit

Node.js/Bun `process.on("exit")` only allows synchronous operations. `process.on("beforeExit")` allows async but doesn't fire on `SIGKILL`. Options:

a) Use `process.on("beforeExit")` + `process.on("SIGINT")` + `process.on("SIGTERM")` for best-effort cleanup
b) Use synchronous `child_process.execSync("cmux clear-status kilo_code")` in the `exit` handler
c) Rely on cmux's stale PID sweep (if we register the PID) as the fallback

**Recommendation:** Combine (b) and (c). Use `execSync` in the synchronous `exit` handler for reliable cleanup on normal exits, and let the stale PID sweep handle abnormal termination (SIGKILL, crash).

## Implementation Steps

1. **Add `cmux set-agent-pid` and `cmux clear-agent-pid` CLI commands** (small change in `CLI/cmux.swift`)
   - Map to existing `set_agent_pid` / `clear_agent_pid` v1 socket commands
   - Accept: `cmux set-agent-pid <key> <pid> [--workspace <id>]`
   - Accept: `cmux clear-agent-pid <key> [--workspace <id>]`

2. **Create the plugin file** at `~/.config/kilo/plugins/cmux-integration.ts`
   - Implement all event handlers as described above
   - Include the cmux environment guard (no-op when not in cmux)
   - Include PID registration and cleanup

3. **Test the plugin**
   - Verify in cmux terminal: sidebar status updates through full lifecycle
   - Verify notifications appear on `permission.asked` and `session.idle`
   - Verify cleanup on process exit (status clears)
   - Verify no-op behavior outside cmux

4. **Update documentation**
   - Add Kilo Code section to `docs/notifications.md`
   - Reference the plugin file location

## Status Icon/Color Reference (matching Claude Code)

| Status | SF Symbol | Color | When |
|---|---|---|---|
| Running | `bolt.fill` | `#4C8DFF` (blue) | Agent is working (tool use, responding) |
| Idle | `pause.circle.fill` | `#8E8E93` (gray) | Turn completed, waiting for user |
| Needs input | `bell.fill` | `#4C8DFF` (blue) | Permission prompt, question |
| Error | `exclamationmark.triangle.fill` | `#FF3B30` (red) | Session error |
