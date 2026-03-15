import Foundation

/// Describes the relationship of a project-child workspace to its parent project.
enum ProjectWorkspaceKind: Equatable {
    /// The main checkout workspace (worktreePath is nil, directory matches project repo)
    case main
    /// A git worktree workspace (worktreePath and worktreeBranch are set)
    case worktree
    /// A workspace added to the project but whose directory is outside the project repo
    case external
}

/// Represents an item in the sidebar's mixed flat+tree layout.
/// Standalone workspaces appear at the top level, while project workspaces
/// are nested under their project header.
enum SidebarItem: Identifiable {
    case standaloneWorkspace(Workspace)
    case project(Project)
    case projectWorkspace(Workspace, project: Project)

    var id: UUID {
        switch self {
        case .standaloneWorkspace(let workspace):
            return workspace.id
        case .project(let project):
            return project.id
        case .projectWorkspace(let workspace, _):
            return workspace.id
        }
    }

    /// Returns the workspace if this item represents one (standalone or project child).
    var workspace: Workspace? {
        switch self {
        case .standaloneWorkspace(let ws): return ws
        case .projectWorkspace(let ws, _): return ws
        case .project: return nil
        }
    }

    /// Returns the project if this item is a project header.
    var project: Project? {
        switch self {
        case .project(let p): return p
        default: return nil
        }
    }

    /// Returns the parent project for a project workspace, or nil for other item types.
    var parentProject: Project? {
        switch self {
        case .projectWorkspace(_, let project): return project
        default: return nil
        }
    }

    /// Whether this item represents an indented (child) workspace.
    var isIndented: Bool {
        switch self {
        case .projectWorkspace: return true
        default: return false
        }
    }

    /// Whether this item is a project header row.
    var isProjectHeader: Bool {
        switch self {
        case .project: return true
        default: return false
        }
    }

    /// For project-child workspaces, resolves whether this is the main checkout,
    /// a worktree, or an external workspace. Returns nil for non-project items.
    /// Must be called on the main actor since Workspace/Project properties are main-actor isolated.
    @MainActor var projectWorkspaceKind: ProjectWorkspaceKind? {
        switch self {
        case .projectWorkspace(let ws, let project):
            if ws.worktreePath != nil {
                return .worktree
            }
            let wsDir = ws.currentDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let repoDir = project.repositoryPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if wsDir == repoDir || wsDir.hasPrefix(repoDir + "/") {
                return .main
            }
            return .external
        default:
            return nil
        }
    }
}
