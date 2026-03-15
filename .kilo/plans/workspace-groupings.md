# Plan: Workspace Groupings (Projects)

## Overview

Introduce a **Project** concept as a container that groups related Workspaces. A Project maps to a git repository. Each Workspace within a Project is backed by a **git worktree** branching from the project's main branch, enabling parallel work streams on the same codebase.

### Core Concepts

| Concept | Definition |
|---------|-----------|
| **Project** | A container grouping mapped to a git repository's main branch checkout. Acts as a pure container (no terminal of its own). |
| **Workspace** | An active work session. When inside a Project, backed by a git worktree. When standalone, unchanged from current behavior. |
| **Standalone Workspace** | Existing behavior preserved — a workspace not belonging to any project. |

### User-Facing Behavior

- Sidebar shows a **two-level hierarchy**: Projects with nested child Workspaces, intermixed with standalone Workspaces at the top level.
- Creating a Project: user provides a path to a git repo. The app reads the repo's main branch name and stores it.
- Creating a Workspace inside a Project: user names the workspace; the app auto-generates a branch name (slugified), creates a `git worktree` at `~/.cmux/worktrees/<project-slug>/<workspace-slug>/`, and opens a terminal in that worktree directory.
- Closing a Workspace inside a Project: user is prompted whether to keep or delete the worktree on disk.
- Projects can be collapsed/expanded in the sidebar.

---

## Design Decisions (from user input)

1. **Standalone workspaces coexist** with project-grouped workspaces in the sidebar.
2. **Worktree location**: Central — `~/.cmux/worktrees/<project-slug>/<workspace-slug>/`.
3. **Worktree cleanup**: Prompt the user on workspace close.
4. **Branch naming**: Auto-generated from workspace name (e.g., "Fix auth bug" -> `fix-auth-bug`).
5. **Project is a pure container**: Even the main branch is a child workspace (not the project row itself).

---

## Data Model Changes

### New: `Project` class

```swift
// Sources/Project.swift (new file)
@MainActor
final class Project: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String              // Display name (defaults to repo directory name)
    @Published var repositoryPath: String    // Absolute path to the main git checkout
    @Published var mainBranch: String        // e.g., "main" or "master"
    @Published var isExpanded: Bool          // Sidebar collapse state
    @Published var workspaceIds: [UUID]      // Ordered list of child workspace IDs
    @Published var customColor: String?      // Optional project-level color
}
```

### Modified: `Workspace` class

Add an optional project reference:

```swift
// In Sources/Workspace.swift
var projectId: UUID?          // nil for standalone workspaces
var worktreePath: String?     // Path to git worktree (nil for standalone or main-branch workspace)
var worktreeBranch: String?   // Branch name for the worktree
```

### Modified: `TabManager` class

The `TabManager` currently holds `tabs: [Workspace]`. It needs to additionally manage projects:

```swift
// In Sources/TabManager.swift
@Published var projects: [Project] = []
```

The `tabs` array continues to hold ALL workspaces (both standalone and project-owned). The sidebar rendering logic uses `projects` + `projectId` on each workspace to build the tree view.

### New: `SidebarItem` enum

To represent the mixed flat+tree sidebar:

```swift
enum SidebarItem: Identifiable {
    case standaloneWorkspace(Workspace)
    case project(Project)
    case projectWorkspace(Workspace, project: Project)
    
    var id: String { ... }
}
```

A computed property on `TabManager` produces the ordered sidebar items list:

```swift
var sidebarItems: [SidebarItem] {
    // Walk through tabs array, grouping project workspaces under their
    // project headers. Standalone workspaces appear at the position of
    // their first occurrence. Projects appear at the position of their
    // first child workspace.
}
```

---

## Sidebar Layout Changes

### Current: Flat list
```
[Workspace A]
[Workspace B]
[Workspace C]
```

### New: Mixed tree
```
[Standalone Workspace A]
[v Project: myapp]              <- collapsible header
  [  main]                      <- child workspace (main branch)
  [  feature-auth]              <- child workspace (worktree)
  [  fix-sidebar-crash]         <- child workspace (worktree)
[Standalone Workspace B]
[v Project: backend-api]
  [  main]
  [  refactor-db]
```

### Visual Hierarchy

- **Project row**: Shows project name, repo path, expand/collapse chevron, workspace count badge, optional color indicator. Context menu for: add workspace, rename, remove project.
- **Child workspace row**: Indented under project. Shows workspace name, branch name, git dirty status, same metadata as current workspace rows (status entries, ports, etc.). Context menu adds: close workspace (with worktree cleanup prompt).
- **Standalone workspace row**: Unchanged from current behavior.

### Implementation Approach

The existing `VerticalTabsSidebar` in `ContentView.swift` iterates `ForEach(tabManager.tabs)`. This changes to iterate over `tabManager.sidebarItems`:

```swift
ForEach(tabManager.sidebarItems) { item in
    switch item {
    case .standaloneWorkspace(let ws):
        TabItemView(tab: ws, ...)  // existing view, unchanged
    case .project(let project):
        ProjectHeaderView(project: project, ...)  // new view
    case .projectWorkspace(let ws, let project):
        TabItemView(tab: ws, ..., indented: true)  // existing view with indent
    }
}
```

When a project is collapsed (`isExpanded == false`), its `.projectWorkspace` items are filtered out.

---

## Git Worktree Management

### New: `WorktreeManager` utility

```swift
// Sources/WorktreeManager.swift (new file)
enum WorktreeManager {
    static let baseDirectory = "~/.cmux/worktrees"
    
    /// Creates a worktree for a project workspace.
    /// Runs: git -C <repoPath> worktree add <worktreePath> -b <branchName> <mainBranch>
    static func createWorktree(
        repoPath: String,
        projectSlug: String,
        branchName: String,
        baseBranch: String
    ) async throws -> String  // returns worktree absolute path
    
    /// Removes a worktree from disk.
    /// Runs: git -C <repoPath> worktree remove <worktreePath>
    static func removeWorktree(
        repoPath: String,
        worktreePath: String
    ) async throws
    
    /// Lists existing worktrees for a repo.
    /// Runs: git -C <repoPath> worktree list --porcelain
    static func listWorktrees(repoPath: String) async throws -> [WorktreeInfo]
    
    /// Detects the main branch of a repository.
    /// Tries: git -C <repoPath> symbolic-ref refs/remotes/origin/HEAD
    /// Fallback: checks for "main" or "master" branch existence
    static func detectMainBranch(repoPath: String) async throws -> String
    
    /// Slugifies a workspace name into a valid branch name.
    /// "Fix auth bug" -> "fix-auth-bug"
    static func slugify(_ name: String) -> String
}
```

### Branch Name Generation

```
Input: "Fix authentication bug"
Output: "fix-authentication-bug"

Input: "Add dark mode"  
Output: "add-dark-mode"
```

Rules:
- Lowercased
- Spaces/underscores replaced with hyphens
- Non-alphanumeric characters (except hyphens) removed
- Consecutive hyphens collapsed
- Leading/trailing hyphens stripped
- If branch already exists, append `-2`, `-3`, etc.

### Worktree Directory Structure

```
~/.cmux/worktrees/
  myapp/                        <- project slug
    fix-auth-bug/               <- workspace slug (= branch name)
      <full worktree checkout>
    add-dark-mode/
      <full worktree checkout>
  backend-api/
    refactor-db/
      <full worktree checkout>
```

---

## Session Persistence Changes

### New snapshot types

```swift
struct SessionProjectSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var repositoryPath: String
    var mainBranch: String
    var isExpanded: Bool
    var workspaceIds: [UUID]
    var customColor: String?
}
```

### Modified: `SessionWorkspaceSnapshot`

```swift
struct SessionWorkspaceSnapshot: Codable, Sendable {
    // ... existing fields ...
    var projectId: UUID?           // NEW
    var worktreePath: String?      // NEW
    var worktreeBranch: String?    // NEW
}
```

### Modified: `SessionTabManagerSnapshot`

```swift
struct SessionTabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
    var projects: [SessionProjectSnapshot]  // NEW
}
```

### Schema version bump

`SessionSnapshotSchema.currentVersion` increments from `1` to `2`. On load, version `1` snapshots are migrated: all workspaces treated as standalone (no projects).

---

## Socket Command Extensions

### New V1 commands

```
# Project management
project.create <repo-path> [--name=<display-name>]
project.list
project.remove <project-id> [--force]  (--force skips confirmation)

# Workspace creation within project
workspace.create --project=<project-id> --name=<workspace-name>
workspace.close <workspace-id> [--keep-worktree | --remove-worktree]
```

### New V2 methods

```json
{ "method": "project.create", "params": { "repoPath": "/path/to/repo", "name": "optional" } }
{ "method": "project.list" }
{ "method": "project.remove", "params": { "projectId": "uuid" } }
{ "method": "workspace.create", "params": { "projectId": "uuid", "name": "Fix auth bug" } }
```

### Modified: existing `new_workspace` / `workspace.create`

Add optional `--project` parameter. When provided, workspace is created as a child of the project with an auto-generated worktree.

---

## UI Flows

### Flow 1: Create a Project

1. User right-clicks sidebar empty area or uses menu: "New Project..."
2. Folder picker dialog opens -> user selects a git repo directory
3. App validates it's a git repo (`git -C <path> rev-parse --git-dir`)
4. App detects main branch name
5. Project is created in `TabManager.projects`
6. A "main" workspace is auto-created as the first child (working directory = repo path, no worktree needed since it IS the main checkout)
7. Sidebar shows the new project with its main workspace

### Flow 2: Add Workspace to Project

1. User right-clicks project header -> "New Workspace..."
2. Dialog asks for workspace name (e.g., "Fix auth bug")
3. App slugifies name -> `fix-auth-bug`
4. App runs `git -C <repoPath> worktree add ~/.cmux/worktrees/<project-slug>/fix-auth-bug -b fix-auth-bug <mainBranch>`
5. New workspace created with `workingDirectory = worktreePath`, `projectId = project.id`
6. Terminal opens in the worktree directory
7. Workspace appears nested under project in sidebar

### Flow 3: Close Project Workspace

1. User closes a workspace that belongs to a project
2. If workspace has a worktree (not the main workspace): alert dialog
   - "Keep worktree on disk" -> workspace removed from sidebar, worktree files remain
   - "Delete worktree" -> `git worktree remove` runs, workspace removed from sidebar
3. If workspace is the "main" workspace (no worktree), just closes normally

### Flow 4: Remove Project

1. User right-clicks project -> "Remove Project"
2. Confirmation dialog warns about open workspaces
3. All child workspaces closed (with individual worktree cleanup prompts for each)
4. Project removed from `TabManager.projects`

---

## Implementation Phases

### Phase 1: Data Model Foundation
- Create `Project` class (`Sources/Project.swift`)
- Add `projectId`, `worktreePath`, `worktreeBranch` to `Workspace`
- Add `projects` array to `TabManager`
- Add `SidebarItem` enum and computed `sidebarItems` property
- Add session persistence snapshots for projects
- Bump schema version with migration

### Phase 2: Git Worktree Manager
- Create `WorktreeManager` utility (`Sources/WorktreeManager.swift`)
- Implement `createWorktree`, `removeWorktree`, `listWorktrees`, `detectMainBranch`
- Implement `slugify` branch name generation
- Add error handling for git failures (not a repo, branch exists, disk full, etc.)

### Phase 3: Sidebar Rendering
- Add `ProjectHeaderView` for project rows (expand/collapse, context menu)
- Modify `VerticalTabsSidebar` to iterate `sidebarItems` instead of `tabs`
- Add indentation for project child workspaces
- Add drag-and-drop support for reordering within/between projects
- Handle project expand/collapse animation

### Phase 4: Creation & Cleanup Flows
- "New Project..." UI flow (folder picker, validation, auto-create main workspace)
- "New Workspace..." in project (name dialog, worktree creation, workspace creation)
- Close workspace with worktree cleanup prompt
- Remove project with cascade close
- Keyboard shortcuts and menu items

### Phase 5: Socket Commands & CLI
- Add project CRUD socket commands (V1 and V2)
- Extend `workspace.create` with `--project` parameter
- Extend `workspace.close` with `--keep-worktree`/`--remove-worktree`
- Update `list_workspaces` / `workspace.list` to include project info

### Phase 6: Polish
- Localize all new user-facing strings (English + Japanese per codebase convention)
- Session persistence round-trip testing
- Edge cases: repo deleted from disk, worktree already exists, branch conflicts
- Update shell integration to correctly report git metadata for worktree workspaces (should already work per existing `_cmux_git_resolve_head_path`)

---

## Files to Create

| File | Purpose |
|------|---------|
| `Sources/Project.swift` | Project data model |
| `Sources/WorktreeManager.swift` | Git worktree operations |

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/Workspace.swift` | Add `projectId`, `worktreePath`, `worktreeBranch` |
| `Sources/TabManager.swift` | Add `projects`, `sidebarItems`, project CRUD methods |
| `Sources/ContentView.swift` | Sidebar rendering: `ProjectHeaderView`, tree iteration, indent, drag-drop |
| `Sources/SessionPersistence.swift` | `SessionProjectSnapshot`, modified workspace/tab-manager snapshots, schema v2 |
| `Sources/TerminalController.swift` | New socket commands for project management |
| `Resources/Localizable.xcstrings` | New localized strings |
| `Resources/Info.plist` | New UTType if needed for project drag payloads |

---

## Risks & Open Questions

1. **Large repo worktrees**: Creating a worktree is fast (seconds), but for very large repos with many files, disk usage could be significant. Consider showing a progress indicator and disk space estimate.

2. **Worktree orphans**: If the app crashes or the user force-quits, worktrees may be left on disk without corresponding session data. Consider a cleanup check on app launch that reconciles `~/.cmux/worktrees/` against persisted projects.

3. **ContentView.swift complexity**: This file is already ~12,825 lines. Adding project rendering logic will increase it further. Consider extracting sidebar rendering into a separate file (`Sources/SidebarView.swift`) as a prerequisite refactor.

4. **Drag-and-drop between projects**: Should users be able to drag a workspace from one project to another? This would require moving the worktree or re-creating it. Recommend deferring cross-project drag to a future iteration.

5. **Non-git directories**: What happens if a user tries to create a project from a non-git directory? The flow should validate and show a clear error message.
