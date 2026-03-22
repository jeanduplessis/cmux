import SwiftUI
import AppKit

// MARK: - File Action Callbacks

/// Callbacks for file row interactions in the Git sidebar.
struct GitSidebarFileActions {
    /// Show `git blame` for the given file path (relative to repo root).
    var onBlame: (_ filePath: String) -> Void = { _ in }
    /// Show `git diff` for the given file. `staged` indicates index vs worktree diff.
    var onDiff: (_ filePath: String, _ staged: Bool) -> Void = { _, _ in }
    /// Show diff for an untracked file (diff --no-index /dev/null).
    var onDiffUntracked: (_ filePath: String) -> Void = { _ in }
    /// Copy the relative file path to the pasteboard.
    var onCopyPath: (_ filePath: String) -> Void = { _ in }

    // File operations
    /// Stage a file: `git add -- <path>`.
    var onStage: (_ filePath: String) -> Void = { _ in }
    /// Unstage a file: `git restore --staged -- <path>`.
    var onUnstage: (_ filePath: String) -> Void = { _ in }
    /// Discard changes to a tracked unstaged file: `git restore -- <path>`.
    var onDiscard: (_ filePath: String) -> Void = { _ in }
    /// Delete an untracked file.
    var onDeleteUntracked: (_ filePath: String) -> Void = { _ in }

    // Bulk operations
    /// Stage all unstaged tracked changes: `git add -u`.
    var onStageAllUnstaged: () -> Void = {}
    /// Stage all untracked files.
    var onStageAllUntracked: () -> Void = {}
    /// Unstage all staged files: `git restore --staged .`.
    var onUnstageAll: () -> Void = {}
    /// Discard all unstaged changes: `git restore .`.
    var onDiscardAllUnstaged: () -> Void = {}
    /// Delete all untracked files.
    var onDeleteAllUntracked: () -> Void = {}
}

// MARK: - Main View

struct GitSidebarView: View {
    @ObservedObject var service: GitStatusService
    @ObservedObject var sidebarState: GitSidebarState
    var fileActions: GitSidebarFileActions = GitSidebarFileActions()

    var body: some View {
        VStack(spacing: 0) {
            GitSidebarHeader(
                isLoading: service.isLoading,
                onRefresh: { service.refresh() },
                onClose: { sidebarState.toggle() }
            )

            Divider()

            if !service.status.isGitRepo {
                GitSidebarNotRepoView(onInit: { service.initializeRepository() })
            } else if service.status.isEmpty {
                if let branch = service.status.branch {
                    GitSidebarBranchBar(
                        branch: branch,
                        upstream: service.status.upstream,
                        ahead: service.status.ahead,
                        behind: service.status.behind
                    )
                    Divider()
                }
                GitSidebarEmptyView()
            } else {
                if let branch = service.status.branch {
                    GitSidebarBranchBar(
                        branch: branch,
                        upstream: service.status.upstream,
                        ahead: service.status.ahead,
                        behind: service.status.behind
                    )
                    Divider()
                }
                GitSidebarFileList(status: service.status, fileActions: fileActions)
            }
        }
        .background(GitSidebarBackdrop().ignoresSafeArea())
        .accessibilityIdentifier("GitSidebar")
    }
}

// MARK: - Header

private struct GitSidebarHeader: View {
    let isLoading: Bool
    let onRefresh: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(String(localized: "gitSidebar.title", defaultValue: "Git"))
                .font(.subheadline)
                .fontWeight(.bold)

            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .opacity(isLoading ? 1 : 0)

            Spacer()

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "gitSidebar.refresh", defaultValue: "Refresh"))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "gitSidebar.close", defaultValue: "Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Branch Info Bar

private struct GitSidebarBranchBar: View {
    let branch: String
    let upstream: String?
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .safeHelp(String(localized: "gitSidebar.currentBranch", defaultValue: "Current Branch"))

            Text(branch)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if upstream != nil {
                if ahead > 0 {
                    Text("\u{2191}\(ahead)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.green)
                        .safeHelp(String(localized: "gitSidebar.ahead", defaultValue: "ahead"))
                }
                if behind > 0 {
                    Text("\u{2193}\(behind)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                        .safeHelp(String(localized: "gitSidebar.behind", defaultValue: "behind"))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }
}

// MARK: - File List (ScrollView)

private struct GitSidebarFileList: View {
    let status: GitRepoStatus
    let fileActions: GitSidebarFileActions

    /// Confirmation dialog state for destructive operations.
    @State private var confirmAction: GitConfirmAction?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !status.staged.isEmpty {
                    GitSidebarSection(
                        title: String(localized: "gitSidebar.staged", defaultValue: "Staged Changes"),
                        count: status.staged.count,
                        files: status.staged,
                        accentColor: Color.green.opacity(0.7),
                        fileActions: fileActions,
                        sectionActions: [
                            GitSectionAction(
                                systemImage: "minus.circle",
                                help: String(localized: "gitSidebar.action.unstageAll", defaultValue: "Unstage All"),
                                action: { fileActions.onUnstageAll() }
                            ),
                        ],
                        confirmAction: $confirmAction
                    )
                }

                if !status.unstaged.isEmpty {
                    if !status.staged.isEmpty {
                        Spacer().frame(height: 12)
                    }
                    GitSidebarSection(
                        title: String(localized: "gitSidebar.unstaged", defaultValue: "Changes"),
                        count: status.unstaged.count,
                        files: status.unstaged,
                        accentColor: Color.orange.opacity(0.7),
                        fileActions: fileActions,
                        sectionActions: [
                            GitSectionAction(
                                systemImage: "plus.circle",
                                help: String(localized: "gitSidebar.action.stageAll", defaultValue: "Stage All"),
                                action: { fileActions.onStageAllUnstaged() }
                            ),
                            GitSectionAction(
                                systemImage: "arrow.uturn.backward",
                                help: String(localized: "gitSidebar.action.discardAll", defaultValue: "Discard All Changes"),
                                isDestructive: true,
                                action: {
                                    confirmAction = .discardAllUnstaged
                                }
                            ),
                        ],
                        confirmAction: $confirmAction
                    )
                }

                if !status.untracked.isEmpty {
                    if !status.staged.isEmpty || !status.unstaged.isEmpty {
                        Spacer().frame(height: 12)
                    }
                    GitSidebarSection(
                        title: String(localized: "gitSidebar.untracked", defaultValue: "Untracked Files"),
                        count: status.untracked.count,
                        files: status.untracked,
                        accentColor: .secondary,
                        fileActions: fileActions,
                        sectionActions: [
                            GitSectionAction(
                                systemImage: "plus.circle",
                                help: String(localized: "gitSidebar.action.stageAll", defaultValue: "Stage All"),
                                action: { fileActions.onStageAllUntracked() }
                            ),
                            GitSectionAction(
                                systemImage: "trash",
                                help: String(localized: "gitSidebar.action.deleteAll", defaultValue: "Delete All Untracked"),
                                isDestructive: true,
                                action: {
                                    confirmAction = .deleteAllUntracked
                                }
                            ),
                        ],
                        confirmAction: $confirmAction
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .alert(
            confirmAction?.title ?? "",
            isPresented: Binding(
                get: { confirmAction != nil },
                set: { if !$0 { confirmAction = nil } }
            ),
            presenting: confirmAction
        ) { action in
            Button(
                String(localized: "gitSidebar.confirm.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                confirmAction = nil
            }
            Button(action.confirmButtonLabel, role: .destructive) {
                action.perform(fileActions: fileActions)
                confirmAction = nil
            }
        } message: { action in
            Text(action.message)
        }
    }
}

// MARK: - Confirmation Action

/// Describes a destructive action pending user confirmation.
private enum GitConfirmAction: Identifiable {
    case discardFile(path: String)
    case discardAllUnstaged
    case deleteFile(path: String)
    case deleteAllUntracked

    var id: String {
        switch self {
        case .discardFile(let path): return "discard:\(path)"
        case .discardAllUnstaged: return "discardAll"
        case .deleteFile(let path): return "delete:\(path)"
        case .deleteAllUntracked: return "deleteAll"
        }
    }

    var title: String {
        switch self {
        case .discardFile:
            return String(localized: "gitSidebar.confirm.discard.title", defaultValue: "Discard Changes?")
        case .discardAllUnstaged:
            return String(localized: "gitSidebar.confirm.discardAll.title", defaultValue: "Discard All Changes?")
        case .deleteFile:
            return String(localized: "gitSidebar.confirm.delete.title", defaultValue: "Delete Untracked File?")
        case .deleteAllUntracked:
            return String(localized: "gitSidebar.confirm.deleteAll.title", defaultValue: "Delete All Untracked Files?")
        }
    }

    var message: String {
        switch self {
        case .discardFile(let path):
            let fileName = (path as NSString).lastPathComponent
            let template = String(localized: "gitSidebar.confirm.discard.message",
                                  defaultValue: "This will revert the file to its last committed state. This cannot be undone.")
            return template.contains("%@") ? template.replacingOccurrences(of: "%@", with: fileName) :
                "This will revert \(fileName) to its last committed state. This cannot be undone."
        case .discardAllUnstaged:
            return String(localized: "gitSidebar.confirm.discardAll.message",
                          defaultValue: "This will revert all modified files to their last committed state. This cannot be undone.")
        case .deleteFile(let path):
            let fileName = (path as NSString).lastPathComponent
            let template = String(localized: "gitSidebar.confirm.delete.message",
                                  defaultValue: "This will move the file to the Trash. You can recover it from there if needed.")
            return template.contains("%@") ? template.replacingOccurrences(of: "%@", with: fileName) :
                "This will move \(fileName) to the Trash. You can recover it from there if needed."
        case .deleteAllUntracked:
            return String(localized: "gitSidebar.confirm.deleteAll.message",
                          defaultValue: "This will move all untracked files to the Trash. You can recover them from there if needed.")
        }
    }

    var confirmButtonLabel: String {
        switch self {
        case .discardFile, .discardAllUnstaged:
            return String(localized: "gitSidebar.confirm.discard.button", defaultValue: "Discard")
        case .deleteFile, .deleteAllUntracked:
            return String(localized: "gitSidebar.confirm.delete.button", defaultValue: "Delete")
        }
    }

    func perform(fileActions: GitSidebarFileActions) {
        switch self {
        case .discardFile(let path):
            fileActions.onDiscard(path)
        case .discardAllUnstaged:
            fileActions.onDiscardAllUnstaged()
        case .deleteFile(let path):
            fileActions.onDeleteUntracked(path)
        case .deleteAllUntracked:
            fileActions.onDeleteAllUntracked()
        }
    }
}

/// Descriptor for a section header action button.
private struct GitSectionAction {
    let systemImage: String
    let help: String
    var isDestructive: Bool = false
    let action: () -> Void
}

// MARK: - Collapsible Section

private struct GitSidebarSection: View {
    let title: String
    let count: Int
    let files: [GitFileEntry]
    let accentColor: Color
    let fileActions: GitSidebarFileActions
    var sectionActions: [GitSectionAction] = []
    @Binding var confirmAction: GitConfirmAction?

    @State private var isExpanded: Bool = true
    @State private var isHeaderHovered: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack(spacing: 4) {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Section action buttons (visible on hover)
                if !sectionActions.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(sectionActions.indices, id: \.self) { index in
                            let sectionAction = sectionActions[index]
                            GitFileActionButton(
                                systemImage: sectionAction.systemImage,
                                help: sectionAction.help,
                                action: sectionAction.action
                            )
                        }
                    }
                    .opacity(isHeaderHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.12), value: isHeaderHovered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHeaderHovered = hovering
            }

            // File rows
            if isExpanded {
                ForEach(files) { file in
                    GitFileRow(file: file, fileActions: fileActions, confirmAction: $confirmAction)

                    // Show child files for untracked directory entries
                    if !file.children.isEmpty {
                        ForEach(file.children, id: \.self) { child in
                            GitDirectoryChildRow(name: child)
                        }
                        if file.childrenTruncated {
                            GitDirectoryChildRow(name: "…")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - File Row

private struct GitFileRow: View {
    let file: GitFileEntry
    let fileActions: GitSidebarFileActions
    @Binding var confirmAction: GitConfirmAction?

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: file.status.iconName)
                .font(.system(size: 10))
                .foregroundStyle(colorForStatus(file.status))
                .frame(width: 14, height: 15, alignment: .center)
                .safeHelp(file.status.label)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let directory = file.directory {
                    Text(directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            // Diff stat counts and action buttons share the same trailing space
            ZStack(alignment: .trailing) {
                // Diff stat counts (+N -N), shown only when counts are available.
                if let insertions = file.insertions, let deletions = file.deletions,
                   insertions > 0 || deletions > 0 {
                    HStack(spacing: 3) {
                        if insertions > 0 {
                            Text("+\(insertions)")
                                .foregroundStyle(Color.green.opacity(0.7))
                        }
                        if deletions > 0 {
                            Text("-\(deletions)")
                                .foregroundStyle(Color.red.opacity(0.7))
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .opacity(isHovered ? 0 : 1)
                }

                // Action icons (visible on hover)
                HStack(spacing: 2) {
                    if canShowBlame {
                        GitFileActionButton(
                            systemImage: "clock",
                            help: String(localized: "gitSidebar.action.blame", defaultValue: "Show Blame"),
                            action: { fileActions.onBlame(file.path) }
                        )
                    }

                    if canShowDiff {
                        GitFileActionButton(
                            systemImage: "arrow.left.arrow.right",
                            help: String(localized: "gitSidebar.action.diff", defaultValue: "Show Diff"),
                            action: {
                                switch file.area {
                                case .staged:
                                    fileActions.onDiff(file.path, true)
                                case .unstaged:
                                    fileActions.onDiff(file.path, false)
                                case .untracked:
                                    fileActions.onDiffUntracked(file.path)
                                }
                            }
                        )
                    }

                    GitFileActionButton(
                        systemImage: "doc.on.clipboard",
                        help: String(localized: "gitSidebar.action.copyPath", defaultValue: "Copy Relative Path"),
                        action: {
                            fileActions.onCopyPath(file.path)
                        }
                    )

                    // Area-specific action buttons
                    switch file.area {
                    case .staged:
                        // Unstage
                        GitFileActionButton(
                            systemImage: "minus.circle",
                            help: String(localized: "gitSidebar.action.unstage", defaultValue: "Unstage"),
                            action: { fileActions.onUnstage(file.path) }
                        )
                    case .unstaged:
                        // Stage
                        GitFileActionButton(
                            systemImage: "plus.circle",
                            help: String(localized: "gitSidebar.action.stage", defaultValue: "Stage"),
                            action: { fileActions.onStage(file.path) }
                        )
                        // Discard (with confirmation)
                        GitFileActionButton(
                            systemImage: "arrow.uturn.backward",
                            help: String(localized: "gitSidebar.action.discard", defaultValue: "Discard Changes"),
                            action: { confirmAction = .discardFile(path: file.path) }
                        )
                    case .untracked:
                        // Stage
                        GitFileActionButton(
                            systemImage: "plus.circle",
                            help: String(localized: "gitSidebar.action.stage", defaultValue: "Stage"),
                            action: { fileActions.onStage(file.path) }
                        )
                        // Delete (with confirmation)
                        GitFileActionButton(
                            systemImage: "trash",
                            help: String(localized: "gitSidebar.action.delete", defaultValue: "Delete"),
                            action: { confirmAction = .deleteFile(path: file.path) }
                        )
                    }
                }
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .cornerRadius(3)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu { contextMenuItems }
    }

    /// Blame is available for tracked files (not deleted, not untracked).
    private var canShowBlame: Bool {
        file.status != .deleted && file.area != .untracked
    }

    /// Diff is available for all file areas.
    private var canShowDiff: Bool {
        true
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        switch file.area {
        case .staged:
            Button {
                fileActions.onUnstage(file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.unstage", defaultValue: "Unstage File"), systemImage: "minus.circle")
            }
            Divider()
            Button {
                fileActions.onDiff(file.path, true)
            } label: {
                Label(String(localized: "gitSidebar.context.showDiff", defaultValue: "Show Diff"), systemImage: "arrow.left.arrow.right")
            }
            if canShowBlame {
                Button {
                    fileActions.onBlame(file.path)
                } label: {
                    Label(String(localized: "gitSidebar.context.showBlame", defaultValue: "Show Blame"), systemImage: "clock")
                }
            }
            Divider()
            Button {
                fileActions.onCopyPath(file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.copyPath", defaultValue: "Copy Relative Path"), systemImage: "doc.on.clipboard")
            }

        case .unstaged:
            Button {
                fileActions.onStage(file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.stage", defaultValue: "Stage File"), systemImage: "plus.circle")
            }
            Button(role: .destructive) {
                confirmAction = .discardFile(path: file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.discard", defaultValue: "Discard Changes"), systemImage: "arrow.uturn.backward")
            }
            Divider()
            Button {
                fileActions.onDiff(file.path, false)
            } label: {
                Label(String(localized: "gitSidebar.context.showDiff", defaultValue: "Show Diff"), systemImage: "arrow.left.arrow.right")
            }
            if canShowBlame {
                Button {
                    fileActions.onBlame(file.path)
                } label: {
                    Label(String(localized: "gitSidebar.context.showBlame", defaultValue: "Show Blame"), systemImage: "clock")
                }
            }
            Divider()
            Button {
                fileActions.onCopyPath(file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.copyPath", defaultValue: "Copy Relative Path"), systemImage: "doc.on.clipboard")
            }

        case .untracked:
            Button {
                fileActions.onStage(file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.stage", defaultValue: "Stage File"), systemImage: "plus.circle")
            }
            Button(role: .destructive) {
                confirmAction = .deleteFile(path: file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.delete", defaultValue: "Delete File"), systemImage: "trash")
            }
            Divider()
            Button {
                fileActions.onDiffUntracked(file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.showDiff", defaultValue: "Show Diff"), systemImage: "arrow.left.arrow.right")
            }
            Divider()
            Button {
                fileActions.onCopyPath(file.path)
            } label: {
                Label(String(localized: "gitSidebar.context.copyPath", defaultValue: "Copy Relative Path"), systemImage: "doc.on.clipboard")
            }
        }
    }

    private func colorForStatus(_ status: GitFileStatus) -> Color {
        switch status {
        case .added: return Color.green.opacity(0.7)
        case .modified: return Color.orange.opacity(0.7)
        case .deleted: return Color.red.opacity(0.7)
        case .renamed: return Color.blue.opacity(0.7)
        case .copied: return Color.cyan.opacity(0.7)
        case .typeChanged: return Color.purple.opacity(0.7)
        case .untracked: return .secondary
        }
    }
}

// MARK: - Directory Child Row

/// Indented row showing a child file inside an untracked directory.
private struct GitDirectoryChildRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            // Indent to align with file names in GitFileRow (icon width + spacing)
            Color.clear.frame(width: 14)

            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }
}

// MARK: - File Action Button

/// Small icon button used for hover actions on file rows.
private struct GitFileActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 20, height: 20, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
                )
        }
        .buttonStyle(.plain)
        .safeHelp(help)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .backport.pointerStyle(.link)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}

// MARK: - Empty State

private struct GitSidebarEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.green.opacity(0.7))
                .safeHelp(String(localized: "gitSidebar.empty", defaultValue: "Working tree clean"))
            Text(String(localized: "gitSidebar.empty", defaultValue: "Working tree clean"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Not a Repo State

private struct GitSidebarNotRepoView: View {
    let onInit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .safeHelp(String(localized: "gitSidebar.notRepo", defaultValue: "Not a git repository"))
            Text(String(localized: "gitSidebar.notRepo", defaultValue: "Not a git repository"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button(action: onInit) {
                Text(String(localized: "gitSidebar.initRepo", defaultValue: "Initialize Repository"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Backdrop (NSVisualEffectView)

/// Provides the sidebar background matching the user's configured sidebar material.
/// Reads the same `@AppStorage` keys as the left sidebar's `SidebarBackdrop`.
struct GitSidebarBackdrop: View {
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = 0.30
    @AppStorage("sidebarTintHex") private var sidebarTintHex = "#000000"
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0

    var body: some View {
        let materialOption = SidebarMaterialOption(rawValue: sidebarMaterial)
        let blendingMode = SidebarBlendModeOption(rawValue: sidebarBlendMode)?.mode ?? .behindWindow
        let tintColor = (NSColor(hex: sidebarTintHex) ?? .black).withAlphaComponent(sidebarTintOpacity)
        let cornerRadius = CGFloat(max(0, sidebarCornerRadius))
        let useLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let useWindowLevelGlass = useLiquidGlass && blendingMode == .behindWindow

        ZStack {
            if let material = materialOption?.material {
                if !useWindowLevelGlass {
                    GitSidebarVisualEffect(
                        material: material,
                        blendingMode: blendingMode,
                        state: .followsWindowActiveState,
                        opacity: sidebarBlurOpacity
                    )
                    if !useLiquidGlass {
                        Color(nsColor: tintColor)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - NSVisualEffectView Representable

private struct GitSidebarVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.alphaValue = max(0.0, min(1.0, opacity))
        nsView.needsDisplay = true
    }
}
