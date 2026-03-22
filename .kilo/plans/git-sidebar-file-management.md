# Plan: Git Sidebar File Management Operations

## Goal

Add stage, unstage, and discard operations to the Git sidebar — per-file via hover buttons and context menus, and per-section via bulk action buttons on section headers.

## Operations by File Area

| Area | Stage | Unstage | Discard |
|------|-------|---------|---------|
| **Staged Changes** | — | `git restore --staged <path>` | `git restore --staged <path>` then `git restore <path>` (unstage + revert) |
| **Changes** (unstaged) | `git add <path>` | — | `git restore <path>` |
| **Untracked Files** | `git add <path>` | — | `rm <path>` (with confirmation) |

Bulk operations on section headers:

| Section | Actions |
|---------|---------|
| Staged Changes | Unstage All → `git restore --staged .` |
| Changes | Stage All → `git add -u`, Discard All → `git restore .` (with confirmation) |
| Untracked Files | Stage All → `git add .` minus already-tracked |

## Files to Modify

### 1. `Sources/GitSidebar/GitStatusService.swift` — Add git mutation methods

Add the following public methods to `GitStatusService`:

```swift
// Single-file operations
func stageFile(_ path: String) async
func unstageFile(_ path: String) async
func discardFile(_ path: String, area: GitStagingArea) async
func deleteUntrackedFile(_ path: String) async

// Bulk operations
func stageAllUnstaged() async      // git add -u
func stageAllUntracked() async     // git add for each untracked
func unstageAll() async            // git restore --staged .
func discardAllUnstaged() async    // git restore .
func deleteAllUntracked() async    // rm each untracked file
```

Each method:
1. Runs the git command off-main via `runGitCommand`
2. Calls `refresh()` on completion for immediate UI update (rather than waiting for FSEvents 0.3s debounce)
3. Returns silently on failure (errors can be logged via `dlog` in DEBUG)

Implementation pattern (same as existing `initializeRepository()`):
```swift
func stageFile(_ path: String) async {
    guard let repoRoot else { return }
    let result = Self.runGitCommand(directory: repoRoot, arguments: ["add", "--", path])
    if result.exitCode == 0 { refresh() }
}
```

### 2. `Sources/GitSidebar/GitSidebarView.swift` — UI changes

#### 2a. Extend `GitSidebarFileActions` with new callbacks

```swift
struct GitSidebarFileActions {
    // Existing
    var onBlame: (_ filePath: String) -> Void = { _ in }
    var onDiff: (_ filePath: String, _ staged: Bool) -> Void = { _, _ in }
    var onDiffUntracked: (_ filePath: String) -> Void = { _ in }
    var onCopyPath: (_ filePath: String) -> Void = { _ in }
    
    // New — file operations
    var onStage: (_ filePath: String) -> Void = { _ in }
    var onUnstage: (_ filePath: String) -> Void = { _ in }
    var onDiscard: (_ filePath: String, _ area: GitStagingArea) -> Void = { _, _ in }
    
    // New — bulk operations
    var onStageAllUnstaged: () -> Void = {}
    var onStageAllUntracked: () -> Void = {}
    var onUnstageAll: () -> Void = {}
    var onDiscardAllUnstaged: () -> Void = {}
    var onDeleteAllUntracked: () -> Void = {}
}
```

#### 2b. Add hover buttons to `GitFileRow`

Extend the hover action area with operation-specific buttons per file area:

| Area | Hover Buttons (in order) |
|------|-------------------------|
| Staged | Blame, Diff, Copy Path, **Unstage** (minus.circle) |
| Unstaged | Blame, Diff, Copy Path, **Stage** (plus.circle), **Discard** (arrow.uturn.backward) |
| Untracked | Diff, Copy Path, **Stage** (plus.circle), **Discard/Delete** (trash) |

Widen the fixed hover zone from 52px → ~70px to accommodate the additional button(s). The diff stats ("+N -N") already hide on hover so there's no collision.

#### 2c. Add context menus to `GitFileRow`

Attach `.contextMenu` to each file row with all applicable actions:

**Staged file context menu:**
- Unstage File
- Show Diff
- Show Blame
- Copy Relative Path

**Unstaged file context menu:**
- Stage File
- Discard Changes
- Show Diff
- Show Blame
- Copy Relative Path

**Untracked file context menu:**
- Stage File
- Delete File (destructive, red text)
- Show Diff
- Copy Relative Path

#### 2d. Add section header action buttons

Modify `GitSidebarSection` to accept optional action callbacks and display small icon buttons on the right side of the section header:

- **Staged Changes** header: Unstage All button (minus.circle)
- **Changes** header: Stage All (plus.circle) + Discard All (arrow.uturn.backward)
- **Untracked Files** header: Stage All (plus.circle) + Delete All (trash)

These buttons appear to the right of the count badge, using the same `GitFileActionButton` style.

#### 2e. Confirmation dialog for destructive operations

Add `@State` properties for confirmation alerts on:
- Discard a single file (unstaged modifications)
- Discard all unstaged changes
- Delete a single untracked file
- Delete all untracked files

Use SwiftUI `.alert()` modifier with a clear warning message:
- "Discard Changes?" / "This will revert X to its last committed state. This cannot be undone."
- "Delete Untracked File?" / "This will permanently delete X. This cannot be undone."

The confirmation state needs to be lifted to `GitSidebarFileList` (or parent) since `.alert()` requires a binding.

### 3. `Sources/ContentView.swift` — Wire up new callbacks

Extend `gitSidebarFileActions` computed property to connect the new callbacks:

```swift
private var gitSidebarFileActions: GitSidebarFileActions {
    let service = gitStatusService
    return GitSidebarFileActions(
        // ... existing callbacks ...
        onStage: { [weak service] path in
            Task { await service?.stageFile(path) }
        },
        onUnstage: { [weak service] path in
            Task { await service?.unstageFile(path) }
        },
        onDiscard: { [weak service] path, area in
            Task {
                if area == .untracked {
                    await service?.deleteUntrackedFile(path)
                } else {
                    await service?.discardFile(path, area: area)
                }
            }
        },
        onStageAllUnstaged: { [weak service] in
            Task { await service?.stageAllUnstaged() }
        },
        onStageAllUntracked: { [weak service] in
            Task { await service?.stageAllUntracked() }
        },
        onUnstageAll: { [weak service] in
            Task { await service?.unstageAll() }
        },
        onDiscardAllUnstaged: { [weak service] in
            Task { await service?.discardAllUnstaged() }
        },
        onDeleteAllUntracked: { [weak service] in
            Task { await service?.deleteAllUntracked() }
        }
    )
}
```

### 4. Localization — `Resources/Localizable.xcstrings`

Add localized strings for all new UI elements:

```
gitSidebar.action.stage       = "Stage"
gitSidebar.action.unstage     = "Unstage"
gitSidebar.action.discard     = "Discard Changes"
gitSidebar.action.delete      = "Delete"
gitSidebar.action.stageAll    = "Stage All"
gitSidebar.action.unstageAll  = "Unstage All"
gitSidebar.action.discardAll  = "Discard All Changes"
gitSidebar.action.deleteAll   = "Delete All Untracked"

gitSidebar.confirm.discard.title   = "Discard Changes?"
gitSidebar.confirm.discard.message = "This will revert %@ to its last committed state. This cannot be undone."
gitSidebar.confirm.discardAll.title   = "Discard All Changes?"
gitSidebar.confirm.discardAll.message = "This will revert all modified files to their last committed state. This cannot be undone."
gitSidebar.confirm.delete.title    = "Delete Untracked File?"
gitSidebar.confirm.delete.message  = "This will permanently delete %@. This cannot be undone."
gitSidebar.confirm.deleteAll.title    = "Delete All Untracked Files?"
gitSidebar.confirm.deleteAll.message  = "This will permanently delete all untracked files. This cannot be undone."
```

## Implementation Order

1. **GitStatusService** — Add all git mutation methods (stage, unstage, discard, delete, bulk variants)
2. **GitSidebarFileActions** — Extend the callback struct with new action closures
3. **GitSidebarSection** — Add section header action buttons with callbacks
4. **GitFileRow** — Add hover buttons for stage/unstage/discard + context menus
5. **GitSidebarFileList** — Add confirmation dialog state management + `.alert()` modifiers
6. **ContentView** — Wire up all new callbacks to the service
7. **Localizable.xcstrings** — Add all new localized strings

## Design Decisions

- **Immediate refresh after operations**: Call `refresh()` after each git command rather than relying on FSEvents debounce (0.3s latency + 1.0s cooldown). This gives instant feedback.
- **No optimistic UI**: Don't update the model before the git command completes. The refresh is fast enough and avoids inconsistent state if the command fails.
- **Confirmation only for destructive ops**: Stage/unstage are always safe. Discard and delete require confirmation dialogs since they're irreversible.
- **Async methods on service**: Operations are `async` to run git commands off-main, matching the existing `initializeRepository()` pattern.
- **No error toasts**: Failed operations silently no-op (logged in DEBUG). This matches the current sidebar behavior. Error UI can be added later.
- **Hover zone width increase**: From 52px to ~70px. This is acceptable since the diff stats already hide during hover, freeing horizontal space.
