import Foundation
import SwiftUI

/// A Project is a pure container that groups related Workspaces under a single git repository.
/// Each Project maps to a git repo's main branch checkout. Workspaces within a Project
/// are backed by git worktrees, enabling parallel work streams on the same codebase.
@MainActor
final class Project: Identifiable, ObservableObject {
    let id: UUID

    /// Display name (defaults to the repository directory name)
    @Published var name: String

    /// Absolute path to the main git checkout
    @Published var repositoryPath: String

    /// The main branch name (e.g. "main" or "master")
    @Published var mainBranch: String

    /// Whether the project is expanded (showing child workspaces) in the sidebar
    @Published var isExpanded: Bool

    /// Ordered list of child workspace IDs
    @Published var workspaceIds: [UUID]

    /// Optional project-level color (hex string, e.g. "#C0392B")
    @Published var customColor: String?

    init(
        id: UUID = UUID(),
        name: String,
        repositoryPath: String,
        mainBranch: String,
        isExpanded: Bool = true,
        workspaceIds: [UUID] = [],
        customColor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.repositoryPath = repositoryPath
        self.mainBranch = mainBranch
        self.isExpanded = isExpanded
        self.workspaceIds = workspaceIds
        self.customColor = customColor
    }

    /// Add a workspace ID to this project's child list.
    func addWorkspaceId(_ workspaceId: UUID) {
        guard !workspaceIds.contains(workspaceId) else { return }
        workspaceIds.append(workspaceId)
    }

    /// Remove a workspace ID from this project's child list.
    func removeWorkspaceId(_ workspaceId: UUID) {
        workspaceIds.removeAll { $0 == workspaceId }
    }

    /// Returns whether the given workspace ID belongs to this project.
    func containsWorkspace(_ workspaceId: UUID) -> Bool {
        workspaceIds.contains(workspaceId)
    }
}
