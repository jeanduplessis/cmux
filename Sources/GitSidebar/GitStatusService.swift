import Foundation
import Combine

/// Service that monitors a git repository and publishes status updates.
/// Uses FSEvents for filesystem watching and `git status --porcelain=v2 --branch` for status.
@MainActor
final class GitStatusService: ObservableObject {
    @Published private(set) var status: GitRepoStatus = .empty
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var repoRoot: String?

    private var currentDirectory: String?
    private var fsEventStream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?

    /// Timestamp of the last refresh completion. Used to suppress FSEvents that
    /// fire as a side-effect of `git status` touching `.git/index`.
    private var lastRefreshCompletedAt: CFAbsoluteTime = 0

    /// Cooldown period after a refresh completes during which FSEvents are
    /// ignored. This breaks the feedback loop: git status → updates .git/index
    /// → FSEvent → git status → …
    private static let postRefreshCooldown: TimeInterval = 1.0

    private static let debounceInterval: TimeInterval = 0.3
    nonisolated private static let maxDisplayFiles: Int = 500

    /// Background queue for FSEvents scheduling.
    private static let fsEventQueue = DispatchQueue(
        label: "com.cmux.git-status.fsevents",
        qos: .utility
    )

    deinit {
        debounceWorkItem?.cancel()
        currentTask?.cancel()
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Public API

    /// Update the directory to watch. Call when workspace selection or cwd changes.
    func updateDirectory(_ directory: String?) {
        guard directory != currentDirectory else { return }
        currentDirectory = directory

        // Cancel in-flight work.
        currentTask?.cancel()
        debounceWorkItem?.cancel()
        stopWatching()

        guard let directory else {
            repoRoot = nil
            status = .empty
            return
        }

        isLoading = true

        currentTask = Task { [weak self] in
            let root = Self.detectRepoRoot(directory: directory)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.repoRoot = root

                guard let root else {
                    self.status = .notARepo
                    self.isLoading = false
                    return
                }

                self.startWatching(repoRoot: root)
                self.performRefresh(repoRoot: root)
            }
        }
    }

    /// Force a manual refresh.
    func refresh() {
        guard let repoRoot else { return }
        performRefresh(repoRoot: repoRoot)
    }

    /// Stop all watching and clear status.
    func stop() {
        currentTask?.cancel()
        currentTask = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        stopWatching()
        currentDirectory = nil
        repoRoot = nil
        status = .empty
        isLoading = false
    }

    // MARK: - Git Command Execution

    /// Run git command off-main and return stdout. Uses same pattern as WorktreeManager.
    private nonisolated static func runGitCommand(
        directory: String,
        arguments: [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = WorktreeManager.augmentedPath()
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    // MARK: - Repo Root Detection

    /// Detect git repo root from a directory. Returns nil if not a git repo.
    private nonisolated static func detectRepoRoot(directory: String) -> String? {
        let result = runGitCommand(directory: directory, arguments: ["rev-parse", "--show-toplevel"])
        guard result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Status Parsing

    /// Run git status and parse the porcelain v2 output.
    private nonisolated static func fetchStatus(repoRoot: String) -> GitRepoStatus {
        let result = runGitCommand(
            directory: repoRoot,
            arguments: ["status", "--porcelain=v2", "--branch"]
        )
        guard result.exitCode == 0 else {
            return .notARepo
        }
        let status = parseStatus(result.stdout)
        let expandedUntracked = expandUntrackedDirectories(status.untracked, repoRoot: repoRoot)
        return GitRepoStatus(
            branch: status.branch,
            upstream: status.upstream,
            ahead: status.ahead,
            behind: status.behind,
            staged: status.staged,
            unstaged: status.unstaged,
            untracked: expandedUntracked,
            isGitRepo: true
        )
    }

    /// Maximum number of child files to display for an untracked directory.
    private static let maxDirectoryChildren = 10

    /// For untracked entries that are directories (path ends with `/`), enumerate
    /// the files inside and attach them as `children` on the entry.
    private nonisolated static func expandUntrackedDirectories(
        _ entries: [GitFileEntry],
        repoRoot: String
    ) -> [GitFileEntry] {
        entries.map { entry in
            guard entry.path.hasSuffix("/") else { return entry }
            let dirURL = URL(fileURLWithPath: repoRoot)
                .appendingPathComponent(entry.path, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return entry }

            var childPaths: [String] = []
            var truncated = false
            while let fileURL = enumerator.nextObject() as? URL {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                      resourceValues.isRegularFile == true else { continue }
                if childPaths.count >= maxDirectoryChildren {
                    truncated = true
                    break
                }
                // Path relative to the directory entry itself
                let relativePath = fileURL.path.replacingOccurrences(
                    of: dirURL.path + "/",
                    with: ""
                )
                childPaths.append(relativePath)
            }

            var expanded = entry
            expanded.children = childPaths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            expanded.childrenTruncated = truncated
            return expanded
        }
    }

    /// Parse `git status --porcelain=v2 --branch` output.
    ///
    /// Format reference:
    /// ```
    /// # branch.oid <sha>
    /// # branch.head <branch>
    /// # branch.upstream <upstream>
    /// # branch.ab +<ahead> -<behind>
    /// 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
    /// 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<origPath>
    /// ? <path>
    /// ! <path>
    /// ```
    nonisolated static func parseStatus(_ output: String) -> GitRepoStatus {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var staged: [GitFileEntry] = []
        var unstaged: [GitFileEntry] = []
        var untracked: [GitFileEntry] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)

            if lineStr.hasPrefix("# branch.head ") {
                branch = String(lineStr.dropFirst("# branch.head ".count))
                if branch == "(detached)" { branch = "HEAD (detached)" }
            } else if lineStr.hasPrefix("# branch.upstream ") {
                upstream = String(lineStr.dropFirst("# branch.upstream ".count))
            } else if lineStr.hasPrefix("# branch.ab ") {
                let parts = lineStr.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count >= 2 {
                    ahead = Int(parts[0].dropFirst()) ?? 0
                    behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if lineStr.hasPrefix("1 ") || lineStr.hasPrefix("2 ") {
                parseChangedEntry(lineStr, staged: &staged, unstaged: &unstaged)
            } else if lineStr.hasPrefix("? ") {
                let path = String(lineStr.dropFirst(2))
                untracked.append(GitFileEntry(
                    id: "untracked:\(path)",
                    path: path,
                    status: .untracked,
                    area: .untracked
                ))
            }
            // Skip "!" (ignored) and unrecognised "#" headers.

            // Cap file count to avoid UI slowdowns in very large repos.
            if staged.count + unstaged.count + untracked.count >= maxDisplayFiles {
                break
            }
        }

        // Sort each section alphabetically by filename (case-insensitive),
        // matching VS Code's source control sidebar ordering.
        let sortByFileName: (GitFileEntry, GitFileEntry) -> Bool = {
            $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
        }

        return GitRepoStatus(
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            staged: staged.sorted(by: sortByFileName),
            unstaged: unstaged.sorted(by: sortByFileName),
            untracked: untracked.sorted(by: sortByFileName),
            isGitRepo: true
        )
    }

    /// Parse a "1 XY ..." or "2 XY ..." line into staged and/or unstaged entries.
    private nonisolated static func parseChangedEntry(
        _ line: String,
        staged: inout [GitFileEntry],
        unstaged: inout [GitFileEntry]
    ) {
        let isRenameOrCopy = line.hasPrefix("2 ")

        // For type 1: 1 XY sub mH mI mW hH hI <path>
        // For type 2: 2 XY sub mH mI mW hH hI Xscore <path>\t<origPath>
        // Split into at most 9 parts (the 9th captures everything after field 8).
        let parts = line.split(separator: " ", maxSplits: 8)
        guard parts.count >= 9 else { return }

        let xy = String(parts[1])
        guard xy.count == 2 else { return }
        let x = xy[xy.startIndex]
        let y = xy[xy.index(after: xy.startIndex)]

        var path: String
        var origPath: String?

        if isRenameOrCopy {
            // parts[8] for type 2 is "Xscore <path>\t<origPath>"
            // We need to skip the Xscore token and then split on tab.
            let remainder = String(parts[8])
            // Find the first space to skip past the Xscore field.
            if let spaceIdx = remainder.firstIndex(of: " ") {
                let pathPart = String(remainder[remainder.index(after: spaceIdx)...])
                if let tabIdx = pathPart.firstIndex(of: "\t") {
                    path = String(pathPart[..<tabIdx])
                    origPath = String(pathPart[pathPart.index(after: tabIdx)...])
                } else {
                    path = pathPart
                }
            } else {
                // Malformed — use remainder as path.
                path = remainder
            }
        } else {
            path = String(parts[8])
        }

        // X (staging area) — anything other than "." means staged change.
        if x != "." {
            let status = fileStatusFromChar(x, origPath: origPath)
            staged.append(GitFileEntry(
                id: "staged:\(path)",
                path: path,
                status: status,
                area: .staged
            ))
        }

        // Y (worktree) — anything other than "." means unstaged change.
        if y != "." {
            let status = fileStatusFromChar(y, origPath: origPath)
            unstaged.append(GitFileEntry(
                id: "unstaged:\(path)",
                path: path,
                status: status,
                area: .unstaged
            ))
        }
    }

    private nonisolated static func fileStatusFromChar(
        _ char: Character,
        origPath: String?
    ) -> GitFileStatus {
        switch char {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed(from: origPath ?? "")
        case "C": return .copied
        case "T": return .typeChanged
        default: return .modified
        }
    }

    // MARK: - FSEvents Watching

    /// Start watching the git repo for changes via FSEvents.
    private func startWatching(repoRoot: String) {
        stopWatching()

        let pathsToWatch = [repoRoot] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: { info in
                guard let info else { return info }
                _ = Unmanaged<GitStatusService>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<GitStatusService>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.debounceInterval,
            flags
        ) else { return }

        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, Self.fsEventQueue)
        FSEventStreamStart(stream)
    }

    /// Stop all filesystem watchers.
    private func stopWatching() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    // MARK: - Debounced Refresh

    /// Schedule a debounced status refresh on the main actor.
    /// Skips if still within the post-refresh cooldown window (breaks the
    /// feedback loop caused by `git status` touching `.git/index`).
    fileprivate func scheduleDebouncedRefresh() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRefreshCompletedAt < Self.postRefreshCooldown {
            return
        }

        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let repoRoot = self.repoRoot else { return }
                self.performRefresh(repoRoot: repoRoot)
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: workItem
        )
    }

    /// Perform the actual refresh: fetch status off-main, then publish on main.
    /// Only publishes when the new status differs from the current one.
    private func performRefresh(repoRoot: String) {
        currentTask?.cancel()
        isLoading = true

        currentTask = Task { [weak self] in
            let newStatus = Self.fetchStatus(repoRoot: repoRoot)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // Only publish when the status actually changed to avoid
                // unnecessary SwiftUI view invalidation.
                if self.status != newStatus {
                    self.status = newStatus
                }
                self.isLoading = false
                self.lastRefreshCompletedAt = CFAbsoluteTimeGetCurrent()
            }
        }
    }
}

// MARK: - FSEvents C Callback

/// Top-level C callback for FSEvents. Filters noise and dispatches a debounced
/// refresh back to the main actor.
private func fsEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }

    // Check if any event is relevant. Most `.git/` internal changes are noise
    // (especially `.git/index` which `git status` itself updates). We only care
    // about working-tree changes and the few git internals that signal user
    // actions (HEAD change, refs update, index write from `git add`/`commit`).
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let count = CFArrayGetCount(paths)
    var hasRelevantChange = false

    for i in 0..<count {
        guard let rawPath = CFArrayGetValueAtIndex(paths, i) else { continue }
        let path = Unmanaged<CFString>.fromOpaque(rawPath).takeUnretainedValue() as String

        // Skip all internal `.git/` paths except the few that reflect
        // meaningful status changes (HEAD, index, refs).
        if let dotGitRange = path.range(of: "/.git/") {
            let afterDotGit = path[dotGitRange.upperBound...]
            // These indicate user actions (branch switch, stage, commit):
            if afterDotGit == "HEAD"
                || afterDotGit == "index"
                || afterDotGit.hasPrefix("refs/") {
                hasRelevantChange = true
                break
            }
            // Everything else inside .git/ is noise (objects, logs, hooks,
            // FETCH_HEAD, ORIG_HEAD, lock files, etc.)
            continue
        }
        // Working-tree change — always relevant.
        hasRelevantChange = true
        break
    }

    guard hasRelevantChange else { return }

    let service = Unmanaged<GitStatusService>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async {
        // This runs on main so it satisfies @MainActor isolation for
        // scheduleDebouncedRefresh().
        service.scheduleDebouncedRefresh()
    }
}
