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
                GitSidebarNotRepoView()
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
            .help(String(localized: "gitSidebar.refresh", defaultValue: "Refresh"))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(String(localized: "gitSidebar.close", defaultValue: "Close"))
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
                        .help(String(localized: "gitSidebar.ahead", defaultValue: "ahead"))
                }
                if behind > 0 {
                    Text("\u{2193}\(behind)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                        .help(String(localized: "gitSidebar.behind", defaultValue: "behind"))
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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !status.staged.isEmpty {
                    GitSidebarSection(
                        title: String(localized: "gitSidebar.staged", defaultValue: "Staged Changes"),
                        count: status.staged.count,
                        files: status.staged,
                        accentColor: Color.green.opacity(0.7),
                        fileActions: fileActions
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
                        fileActions: fileActions
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
                        fileActions: fileActions
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Collapsible Section

private struct GitSidebarSection: View {
    let title: String
    let count: Int
    let files: [GitFileEntry]
    let accentColor: Color
    let fileActions: GitSidebarFileActions

    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Section header
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

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // File rows
            if isExpanded {
                ForEach(files) { file in
                    GitFileRow(file: file, fileActions: fileActions)

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

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: file.status.iconName)
                .font(.system(size: 10))
                .foregroundStyle(colorForStatus(file.status))
                .frame(width: 14, height: 15, alignment: .center)

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

            // Hover action icons replace the status symbol on hover.
            ZStack {
                // Status letter (visible when not hovered)
                Text(file.status.symbol)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(colorForStatus(file.status))
                    .frame(height: 15, alignment: .center)
                    .opacity(isHovered ? 0 : 1)

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
                }
                .opacity(isHovered ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .cornerRadius(3)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// Blame is available for tracked files (not deleted, not untracked).
    private var canShowBlame: Bool {
        file.status != .deleted && file.area != .untracked
    }

    /// Diff is available for all file areas.
    private var canShowDiff: Bool {
        true
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
                .font(.system(size: 10))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 16, height: 15, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
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
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange.opacity(0.7))
            Text(String(localized: "gitSidebar.notRepo", defaultValue: "Not a git repository"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Backdrop (NSVisualEffectView)

/// Provides the sidebar background matching the user's configured sidebar material.
/// Reads the same `@AppStorage` keys as the left sidebar's `SidebarBackdrop`.
struct GitSidebarBackdrop: View {
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = 0.18
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
