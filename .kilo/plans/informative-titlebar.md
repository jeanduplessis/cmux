# Plan: Informative Titlebar

## Goal

Replace the minimal titlebar (currently just showing workspace title, e.g. "main") with a richer display:

```
[context name] / [workspace name]   branch *   ↑2 ↓1
```

**Format rules:**
- **Context name**: Project name (if workspace belongs to a project) or directory basename (for standalone workspaces)
- **Workspace name**: The workspace's display name (`tab.title`)
- **Git branch**: From `tab.gitBranch?.branch`
- **Dirty indicator**: A `*` or dot when `tab.gitBranch?.isDirty == true`
- **Ahead/behind**: `↑N` / `↓N` from `gitStatusService.status.ahead/behind` (only when the git status service is running)
- Separator `/` between context and workspace name
- Git info is visually de-emphasized (lighter weight, secondary color)
- Ahead/behind only shown when > 0

**Example outputs:**
| Scenario | Titlebar |
|----------|----------|
| Project workspace, clean | `cmux / main   main` |
| Project workspace, dirty, ahead | `cmux / main   feature-x *  ↑3` |
| Standalone workspace, dirty | `my-project   main *` |
| No git branch | `cmux / main` |
| No project, no git | `Terminal 1` |

## Files to Modify

### 1. `Sources/ContentView.swift`

#### a. Update `customTitlebar` view (line ~2249)

Replace the single `Text(titlebarText)` with a composed `HStack` of styled segments:

```swift
// Context name (project or directory) — bold
Text(titlebarContextName)
    .font(.system(size: 13, weight: .bold))
    .foregroundColor(fakeTitlebarTextColor)

// Separator + workspace name (only when context differs from workspace name)
if titlebarContextName != titlebarWorkspaceName {
    Text("/")
        .font(.system(size: 13, weight: .regular))
        .foregroundColor(fakeTitlebarTextColor.opacity(0.5))
    Text(titlebarWorkspaceName)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(fakeTitlebarTextColor)
}

// Git branch + dirty indicator
if let branch = titlebarGitBranch {
    Text(branch)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(fakeTitlebarTextColor.opacity(0.6))
    if titlebarGitDirty {
        Circle()
            .fill(Color.orange)
            .frame(width: 5, height: 5)
    }
}

// Ahead/behind (from gitStatusService, when available)
if titlebarGitAhead > 0 {
    Text("↑\(titlebarGitAhead)")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(.green)
}
if titlebarGitBehind > 0 {
    Text("↓\(titlebarGitBehind)")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(.orange)
}
```

#### b. Replace `titlebarText` state with structured state

Replace the single `@State private var titlebarText = ""` with:

```swift
@State private var titlebarContextName = ""
@State private var titlebarWorkspaceName = ""
@State private var titlebarGitBranch: String? = nil
@State private var titlebarGitDirty: Bool = false
@State private var titlebarGitAhead: Int = 0
@State private var titlebarGitBehind: Int = 0
```

#### c. Update `updateTitlebarText()` (line ~2303)

Rewrite to populate all the structured state variables:

```swift
private func updateTitlebarText() {
    guard let selectedId = tabManager.selectedTabId,
          let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
        titlebarContextName = ""
        titlebarWorkspaceName = ""
        titlebarGitBranch = nil
        titlebarGitDirty = false
        titlebarGitAhead = 0
        titlebarGitBehind = 0
        return
    }

    let workspaceName = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)

    // Context: project name if in a project, else directory basename
    let contextName: String
    if let project = tabManager.project(forWorkspaceId: tab.id) {
        contextName = project.name
    } else {
        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        contextName = (dir as NSString).lastPathComponent
    }

    // Git info
    let branch = tab.gitBranch?.branch
    let dirty = tab.gitBranch?.isDirty ?? false

    // Ahead/behind from git status service (available when service is running)
    let ahead = gitStatusService.status.ahead
    let behind = gitStatusService.status.behind

    // Only update state if values changed (minimize SwiftUI invalidation)
    if titlebarContextName != contextName { titlebarContextName = contextName }
    if titlebarWorkspaceName != workspaceName { titlebarWorkspaceName = workspaceName }
    if titlebarGitBranch != branch { titlebarGitBranch = branch }
    if titlebarGitDirty != dirty { titlebarGitDirty = dirty }
    if titlebarGitAhead != ahead { titlebarGitAhead = ahead }
    if titlebarGitBehind != behind { titlebarGitBehind = behind }
}
```

#### d. Add triggers for git state changes

The existing `scheduleTitlebarTextRefresh()` is called when workspace titles change. Also need to trigger updates when:
- `gitStatusService.status` changes (for ahead/behind) — add `.onChange(of: gitStatusService.status.ahead)` and `.onChange(of: gitStatusService.status.behind)`
- `tab.gitBranch` changes — this is already covered since title refresh fires on `.ghosttyDidSetTitle` which correlates with branch updates

#### e. Update `NSWindow.title` for Mission Control / Dock

Keep `TabManager.windowTitle(for:)` in sync with the new richer title so the window title in Mission Control and Dock tooltips is meaningful. Currently it sets `tab.title` — update to include the project name prefix.

### 2. No model changes needed

All required data is already available:
- Project name: `tabManager.project(forWorkspaceId:)?.name`
- Workspace title: `tab.title`
- Directory: `tab.currentDirectory`
- Git branch + dirty: `tab.gitBranch`
- Ahead/behind: `gitStatusService.status.ahead/behind`

## Notes

- The `customTitlebar` view is NOT in the typing-latency-sensitive path list in AGENTS.md, so adding a few more views is safe.
- All new strings must use `String(localized:defaultValue:)` for localization.
- The dirty indicator (orange dot) provides at-a-glance status without requiring the git sidebar to be open.
- Ahead/behind will only display when `GitStatusService` is running (git sidebar open). When the service is stopped, both default to 0 and won't render. This is acceptable — the branch name and dirty state are always available.
