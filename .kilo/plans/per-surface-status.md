# Plan: Per-Surface Status Entries for Sidebar

## Problem

When multiple agent instances (e.g., Kilo Code in pane A and pane B) run in different terminal panes within the **same workspace**, they all call `set-status` with the same key (e.g. `"kilo_code"`). Since `Workspace.statusEntries` is a flat `[String: SidebarStatusEntry]` dictionary, the last agent to update overwrites the others. The user can't tell which pane is in which state.

## Solution

Add **per-surface (per-pane) status entries**, following the existing pattern used for `panelGitBranches` and `panelPullRequests`. When a plugin passes `--surface <id>`, the status is stored per-pane and displayed with a panel label. Existing workspace-level status (no `--surface`) keeps working unchanged.

## Design

### Display Format

In the sidebar, per-surface status entries show the panel identifier alongside the agent status:

```
kilo_code: Running  ← workspace-level (no surface, backward compat)
```

Becomes, with per-surface scoping:

```
[zsh] kilo_code: Running
[zsh] kilo_code: Idle
```

Where `[zsh]` is the panel title (custom title > process title > "Pane N" fallback).

If only 1 pane exists in the workspace, the panel label can be omitted for cleanliness.

### Data Flow

```
Plugin (cmux-integration.ts)
  → cmux CLI (cmux.swift) with --surface
    → socket command: set_status key value --tab=<ws> --panel=<surface>
      → TerminalController.upsertSidebarMetadata
        → Workspace.panelStatusEntries[surfaceId][key] = SidebarStatusEntry(...)
          → sidebar re-renders with per-panel entries
```

---

## Changes by Layer

### 1. Data Model — `Sources/Workspace.swift`

**Add per-panel status storage** (alongside existing `panelGitBranches`, `panelPullRequests`):

```swift
@Published var panelStatusEntries: [UUID: [String: SidebarStatusEntry]] = [:]
```

**Add aggregation method** for sidebar display:

```swift
struct SidebarStatusDisplayEntry {
    let panelId: UUID?         // nil = workspace-level
    let panelLabel: String?    // "zsh", "Pane 1", etc.
    let entry: SidebarStatusEntry
}

func sidebarAllStatusEntriesInDisplayOrder() -> [SidebarStatusDisplayEntry] {
    // 1. Collect workspace-level entries (panelId = nil)
    // 2. Collect per-panel entries keyed by panel, with panel label
    // 3. Sort all by priority desc, then timestamp desc, then key asc
    // 4. If only 1 panel has entries and no workspace-level entries exist, omit panel label
}
```

**Panel label resolution**: `panelCustomTitles[id]` > `panelTitles[id]` > "Pane N" index fallback.

**Update cleanup** — `removeAllSidebarMetadata()` and panel-removal methods should clear `panelStatusEntries` entries for removed panels.

**Session persistence**: Not needed for v1 — status is transient (agents re-register on startup).

### 2. Socket Command — `Sources/TerminalController.swift`

**Modify `upsertSidebarMetadata`** (~line 13321):

- Parse the existing `--panel` / `--surface` option from `parsed.options`
- If a panel UUID is provided:
  - Validate it exists in the resolved workspace (optional — could be lenient)
  - Write to `tab.panelStatusEntries[panelId][key]` instead of `tab.statusEntries[key]`
  - Also track agent PID in a per-panel structure if needed
- If no panel UUID: existing behavior (`tab.statusEntries[key]`)

**Modify `clearSidebarMetadata`** (~line 13406):

- Same panel routing: if `--panel`/`--surface` is present, remove from `panelStatusEntries[panelId]`
- If no panel: remove from workspace-level `statusEntries` (existing behavior)

**`shouldReplaceStatusEntry`** — no change needed (compares individual entries).

### 3. CLI — `CLI/cmux.swift`

**Modify `set-status`** (~line 1733):

Add `--surface` flag parsing. Fall back to `CMUX_SURFACE_ID` env var when not explicitly provided. Append `--panel=<surfaceId>` to the socket command.

```swift
let (surfaceFlag, r4) = parseOption(r3, name: "--surface")
let surfaceArg = surfaceFlag ?? (windowId == nil
    ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
// ... later:
if let surfaceId = surfaceArg {
    socketCmd += " --panel=\(surfaceId)"
}
```

**Modify `clear-status`** (~line 1754): Same pattern — parse `--surface`, fall back to env var.

**Update help text** (~line 5269): Document the new `--surface` flag.

### 4. Sidebar UI — `Sources/ContentView.swift`

**Modify the metadata rendering** in `TabItemView.body` (~line 11128):

Replace the current:
```swift
let metadataEntries = tab.sidebarStatusEntriesInDisplayOrder()
```

With the new aggregation method returning `[SidebarStatusDisplayEntry]`.

**Modify `SidebarMetadataRows`** (~line 12152) or create a new variant:

- Accept `[SidebarStatusDisplayEntry]` instead of `[SidebarStatusEntry]`
- For entries with `panelLabel != nil`: prepend a dimmed panel label
- For entries with `panelLabel == nil`: render exactly as before

Row layout:
```
[panelLabel]  [icon] [status value]
```

Panel label styled with `.foregroundColor(.secondary.opacity(0.5))` and `.font(.system(size: 9))`.

### 5. Plugin — `plugins/kilo/cmux-integration.ts`

**Modify `setStatus()`** (~line 52): Accept and pass `surface` parameter.

```typescript
async function setStatus(
  $: any,
  status: ...,
  workspace: string | undefined,
  surface: string | undefined,    // NEW
  customValue?: string,
) {
  const args = ["set-status", AGENT_KEY, value, "--icon", ..., "--color", ...];
  if (workspace) args.push("--workspace", workspace);
  if (surface) args.push("--surface", surface);   // NEW
  await $`cmux ${args}`.nothrow();
}
```

**Update all `setStatus()` call sites** to pass `surface` (lines 274, 311, 324, 343, 350, 387, 415).

**Modify `cleanupSync()`** (~line 139): Pass `--surface` in `clear-status` and `clear-agent-pid` calls.

---

## Backward Compatibility

| Scenario | Behavior |
|----------|----------|
| Plugin does NOT pass `--surface` | Status goes to workspace-level `statusEntries` — identical to current behavior |
| Plugin passes `--surface` | Status goes to `panelStatusEntries[surfaceId]` — new per-pane behavior |
| Mixed (some agents pass surface, some don't) | Both workspace-level and per-panel entries display in the sidebar |
| Single pane in workspace | Panel label omitted — looks identical to current behavior |

---

## Open Questions

1. **Agent PID tracking**: Should `set-agent-pid` also be per-surface? Currently it's per-workspace keyed by agent name. If two Kilo instances run in the same workspace, only one PID is tracked. (Can be a follow-up.)

2. **Panel label format**: Should we show `[panelTitle] agentKey: value` or just `agentKey: value (panelTitle)`? The user suggested "Tab 1 ([agent]): [status]" — we should match their preferred format.

---

## Files Touched

| File | Change |
|------|--------|
| `Sources/Workspace.swift` | Add `panelStatusEntries`, aggregation method, cleanup |
| `Sources/TerminalController.swift` | Route `--panel`/`--surface` to per-panel storage |
| `CLI/cmux.swift` | Add `--surface` flag to `set-status`, `clear-status` |
| `Sources/ContentView.swift` | Update `SidebarMetadataRows` for per-panel entries |
| `plugins/kilo/cmux-integration.ts` | Pass `--surface` in all status calls |
