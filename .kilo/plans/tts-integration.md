# Plan: TTS Integration for Kilo Plugin

## Goal

Add text-to-speech notifications to the Kilo Code cmux plugin (`plugins/kilo/cmux-integration.ts`). When the agent needs user attention (questions, permissions, errors) or completes its work, call the local `tts` CLI with a descriptive spoken message.

## Message Format

Based on the user's requested template:

| Event | Spoken Message |
|---|---|
| `permission.asked` | "Kilo agent needs your approval in tab {N} of the {project} project" |
| `tool.execute.before` (question tool) | "Kilo agent needs you to answer a question in tab {N} of the {project} project" |
| `session.idle` | "Kilo agent has completed its work in tab {N} of the {project} project" |
| `session.error` | "Kilo agent encountered an error in tab {N} of the {project} project" |

Where:
- **{N}** = 1-based workspace tab number (from `cmux list-workspaces`)
- **{project}** = directory basename (already available as `projectName`)

## TTS CLI

The `tts` binary at `/Users/jdp/.local/bin/tts` accepts text as positional arguments:

```bash
tts "Kilo agent has completed its work in tab 3 of the cmux project"
```

## Changes

### Single file: `plugins/kilo/cmux-integration.ts`

#### 1. Add `getTabNumber()` helper (after existing helpers, ~line 137)

```typescript
/**
 * Get the 1-based tab number for the current workspace by parsing
 * `cmux list-workspaces` output. Caches the result since the workspace
 * index is stable during a session.
 */
let cachedTabNumber: number | null = null;

function getTabNumber(workspace: string | undefined): number | null {
  if (cachedTabNumber !== null) return cachedTabNumber;
  if (!workspace) return null;
  try {
    const output = execSync("cmux list-workspaces", {
      timeout: 2000,
      encoding: "utf-8",
    });
    for (const line of output.split("\n")) {
      if (line.includes(workspace)) {
        const match = line.match(/^\s*[* ]\s*(\d+):/);
        if (match) {
          cachedTabNumber = parseInt(match[1], 10) + 1; // 1-based
          return cachedTabNumber;
        }
      }
    }
  } catch {
    // ignore
  }
  return null;
}
```

#### 2. Add `speak()` helper (after `getTabNumber`)

```typescript
/**
 * Fire-and-forget TTS. Calls the `tts` CLI with the given message.
 * Does not block the event handler. Silently ignores errors.
 */
function speak($: any, message: string) {
  // Fire and forget — don't await
  $`tts ${message}`.nothrow().catch(() => {});
}
```

Key design decisions:
- **Fire-and-forget**: the `$` tagged template returns a promise; by not `await`ing it, the TTS runs in the background without blocking the event handler
- **`.nothrow()`**: prevents the shell helper from throwing if `tts` exits non-zero
- **`.catch(() => {})`**: swallows any promise rejection (e.g., if `tts` binary not found)

#### 3. Add `buildLocationSuffix()` helper

```typescript
/**
 * Build the "in tab N of the X project" suffix for TTS messages.
 */
function buildLocationSuffix(
  workspace: string | undefined,
  projectName: string,
): string {
  const tabNum = getTabNumber(workspace);
  const tabPart = tabNum !== null ? `in tab ${tabNum} of` : "in";
  return `${tabPart} the ${projectName} project`;
}
```

#### 4. Add TTS calls to existing event handlers

**In `permission.asked` handler (line ~335):** After the existing `setStatus` call, add:

```typescript
speak($, `Kilo agent needs your approval ${buildLocationSuffix(workspace, projectName)}`);
```

**In `session.idle` handler (line ~304):** After the existing `setStatus` call, add:

```typescript
speak($, `Kilo agent has completed its work ${buildLocationSuffix(workspace, projectName)}`);
```

**In `session.error` handler (line ~322):** After the existing `setStatus` call, add:

```typescript
speak($, `Kilo agent encountered an error ${buildLocationSuffix(workspace, projectName)}`);
```

**In `tool.execute.before` handler (line ~407):** Add a check for the `question` tool before the existing logic:

```typescript
if (input.tool === "question") {
  speak($, `Kilo agent needs you to answer a question ${buildLocationSuffix(workspace, projectName)}`);
}
```

## Design Notes

### Why the plugin (not the cmux custom command)?

cmux has a "Notification Command" setting that runs a shell command on every notification with `$CMUX_NOTIFICATION_TITLE`, `$CMUX_NOTIFICATION_SUBTITLE`, `$CMUX_NOTIFICATION_BODY` env vars. This could theoretically call `tts`, but:

1. **No tab number**: the env vars don't include the workspace index
2. **No agent name**: the body text mentions "Kilo Code" in the title, but parsing it is fragile
3. **No event filtering**: it fires for ALL notifications, not just the specific events we want
4. **Format control**: the plugin gives us full control over the spoken message

### Always-on (no env var gate)

TTS fires whenever the `tts` binary is available. If `tts` isn't installed, the `speak()` helper silently ignores errors.

### Tab number caching

The workspace index is looked up once (via `cmux list-workspaces`) and cached for the session. This avoids a subprocess call on every event. The cache value (`cachedTabNumber`) is module-level and persists for the plugin's lifetime.

### Overlapping speech

If multiple events fire in quick succession (e.g., permission → idle), multiple `tts` processes may run concurrently and overlap. This is acceptable for now — the events are typically seconds apart, and Kokoro TTS streams audio quickly.

## File Summary

| File | Action |
|---|---|
| `plugins/kilo/cmux-integration.ts` | **Modify** — add `getTabNumber()`, `speak()`, `buildLocationSuffix()` helpers; add `speak()` calls in 4 event handlers |
