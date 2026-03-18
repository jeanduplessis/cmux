import AppKit
import SwiftUI

/// Floating utility panel that shows git blame or diff output in a Ghostty terminal surface.
///
/// The panel hosts a `TerminalSurface` with a custom `command` (e.g. `git blame --color-always`),
/// producing a scrollable ANSI viewer that respects the user's git/delta configuration.
/// One instance is created per main window and reused across clicks — each new file
/// tears down the previous surface and creates a fresh one.
@MainActor
final class GitPreviewWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - Properties

    private var terminalSurface: TerminalSurface?
    private weak var parentWindow: NSWindow?

    private static let defaultSize = NSSize(width: 900, height: 550)
    private static let minSize = NSSize(width: 500, height: 300)

    // MARK: - Initialization

    init(parentWindow: NSWindow?) {
        let panel = GitPreviewPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = String(localized: "gitPreview.title", defaultValue: "Git Preview")
        panel.isReleasedWhenClosed = false
        panel.minSize = Self.minSize
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isMovableByWindowBackground = true
        // Float above the parent window but below modal dialogs.
        panel.level = .floating
        // Allow the panel to become key for scrolling but not activate the app.
        panel.becomesKeyOnlyIfNeeded = true

        self.parentWindow = parentWindow

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Public API

    /// Show `git blame` output for the given file.
    func showBlame(filePath: String, repoRoot: String) {
        let escapedPath = shellEscape(filePath)
        let command = "git -C \(shellEscape(repoRoot)) blame --color-always -- \(escapedPath)"
        let prefix = String(localized: "gitPreview.blame.prefix", defaultValue: "Blame")
        showCommand(command, title: "\(prefix) — \(fileNameFromPath(filePath))", workingDirectory: repoRoot)
    }

    /// Show `git diff` output for the given file.
    func showDiff(filePath: String, staged: Bool, repoRoot: String) {
        let escapedPath = shellEscape(filePath)
        let escapedRoot = shellEscape(repoRoot)
        let command: String
        if staged {
            command = "git -C \(escapedRoot) diff --cached --color=always -- \(escapedPath)"
        } else {
            command = "git -C \(escapedRoot) diff --color=always -- \(escapedPath)"
        }
        let prefix = String(localized: "gitPreview.diff.prefix", defaultValue: "Diff")
        showCommand(command, title: "\(prefix) — \(fileNameFromPath(filePath))", workingDirectory: repoRoot)
    }

    /// Show `git diff --no-index /dev/null <path>` for untracked files.
    func showDiffUntracked(filePath: String, repoRoot: String) {
        let escapedPath = shellEscape(filePath)
        let escapedRoot = shellEscape(repoRoot)
        let command = "git -C \(escapedRoot) diff --color=always --no-index /dev/null -- \(escapedPath)"
        let prefix = String(localized: "gitPreview.diff.prefix", defaultValue: "Diff")
        showCommand(command, title: "\(prefix) — \(fileNameFromPath(filePath))", workingDirectory: repoRoot)
    }

    /// Dismiss the preview panel and tear down the terminal surface.
    func dismiss() {
        teardownSurface()
        window?.orderOut(nil)
    }

    // MARK: - Private Helpers

    private func showCommand(_ command: String, title: String, workingDirectory: String) {
        teardownSurface()

        guard let panel = window as? NSPanel else { return }
        panel.title = title

        // Build environment: suppress delta's own pager (the Ghostty surface provides scrollback)
        // and ensure git/delta are discoverable via the augmented PATH.
        var env: [String: String] = [:]
        env["DELTA_PAGER"] = "cat"
        env["GIT_PAGER"] = "delta --paging=never 2>/dev/null || cat"
        env["PATH"] = WorktreeManager.augmentedPath()

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: nil,
            workingDirectory: workingDirectory,
            additionalEnvironment: env,
            command: command,
            waitAfterCommand: true
        )
        self.terminalSurface = surface

        // Host the surface's scroll view in the panel's content view.
        let hostView = surface.hostedView
        hostView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        contentView.autoresizesSubviews = true
        contentView.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        panel.contentView = contentView

        positionPanel()
        panel.makeKeyAndOrderFront(nil)

        // Trigger surface creation now that the view is in a window.
        surface.requestBackgroundSurfaceStartIfNeeded()
    }

    private func teardownSurface() {
        if let surface = terminalSurface {
            surface.teardownSurface()
            surface.hostedView.removeFromSuperview()
            terminalSurface = nil
        }
    }

    /// Position the panel adjacent to the parent window's right edge.
    private func positionPanel() {
        guard let panel = window, let parent = parentWindow else { return }

        let parentFrame = parent.frame
        let panelSize = panel.frame.size

        // Try placing to the right of the parent window.
        var origin = NSPoint(
            x: parentFrame.maxX + 8,
            y: parentFrame.midY - panelSize.height / 2
        )

        // If it goes off-screen, place it overlapping the right edge of the parent.
        if let screen = parent.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            if origin.x + panelSize.width > screenFrame.maxX {
                origin.x = parentFrame.maxX - panelSize.width - 20
            }
            // Clamp vertical position.
            origin.y = max(screenFrame.minY, min(origin.y, screenFrame.maxY - panelSize.height))
        }

        panel.setFrameOrigin(origin)
    }

    private func fileNameFromPath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Escape a string for safe use in a shell command.
    private func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        teardownSurface()
    }

    /// Allow Escape to dismiss the panel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
}

/// Subclass to handle Escape key for dismissal.
private class GitPreviewPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
