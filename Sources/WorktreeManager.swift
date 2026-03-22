import Foundation

/// Manages git worktree operations for project workspaces.
/// All git commands follow the pattern used by TabManager.runGitCommand.
enum WorktreeManager {
    /// Base directory for all worktrees managed by cmux.
    static let baseDirectoryPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cmux/worktrees"
    }()

    // MARK: - Worktree Operations

    /// Creates a git worktree for a project workspace.
    /// - Parameters:
    ///   - repoPath: Absolute path to the main git repository checkout.
    ///   - projectSlug: Slugified project name for the directory structure.
    ///   - branchName: The branch name to create (e.g. "fix-auth-bug").
    ///   - baseBranch: The base branch to branch from (e.g. "main").
    /// - Returns: The absolute path to the created worktree directory.
    /// - Throws: `WorktreeError` if the operation fails.
    static func createWorktree(
        repoPath: String,
        projectSlug: String,
        branchName: String,
        baseBranch: String
    ) async throws -> String {
        let worktreePath = "\(baseDirectoryPath)/\(projectSlug)/\(branchName)"

        // Ensure the parent directory exists
        let parentPath = "\(baseDirectoryPath)/\(projectSlug)"
        try FileManager.default.createDirectory(
            atPath: parentPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // git -C <repoPath> worktree add <worktreePath> -b <branchName> <baseBranch>
        let result = runGitCommand(
            directory: repoPath,
            arguments: ["worktree", "add", worktreePath, "-b", branchName, baseBranch]
        )

        guard result.exitCode == 0 else {
            // If the branch already exists, try without -b (attach to existing branch)
            let retryResult = runGitCommand(
                directory: repoPath,
                arguments: ["worktree", "add", worktreePath, branchName]
            )
            guard retryResult.exitCode == 0 else {
                let errorMessage = retryResult.stderr ?? result.stderr ?? "Unknown error"
                throw WorktreeError.creationFailed(errorMessage)
            }
            return worktreePath
        }

        return worktreePath
    }

    /// Removes a git worktree from disk.
    /// - Parameters:
    ///   - repoPath: Absolute path to the main git repository checkout.
    ///   - worktreePath: Absolute path to the worktree to remove.
    /// - Throws: `WorktreeError` if the operation fails.
    static func removeWorktree(
        repoPath: String,
        worktreePath: String,
        force: Bool = false
    ) async throws {
        var args = ["worktree", "remove", worktreePath]
        if force {
            args.append("--force")
        }
        let result = runGitCommand(directory: repoPath, arguments: args)

        guard result.exitCode == 0 else {
            let errorMessage = result.stderr ?? "Unknown error"
            throw WorktreeError.removalFailed(errorMessage)
        }
    }

    /// Lists existing worktrees for a repository.
    /// - Parameter repoPath: Absolute path to the git repository.
    /// - Returns: Array of `WorktreeInfo` describing each worktree.
    static func listWorktrees(repoPath: String) async throws -> [WorktreeInfo] {
        let result = runGitCommand(
            directory: repoPath,
            arguments: ["worktree", "list", "--porcelain"]
        )

        guard result.exitCode == 0 else {
            let errorMessage = result.stderr ?? "Unknown error"
            throw WorktreeError.listFailed(errorMessage)
        }

        guard let output = result.stdout else { return [] }
        return parseWorktreeList(output)
    }

    /// Async wrapper that delegates to `detectMainBranchSync`.
    /// - Parameter repoPath: Absolute path to the git repository.
    /// - Returns: The main branch name (e.g. "main" or "master").
    /// - Throws: `WorktreeError.mainBranchNotDetected` if no main branch can be detected.
    static func detectMainBranch(repoPath: String) async throws -> String {
        guard let branch = detectMainBranchSync(repoPath: repoPath) else {
            throw WorktreeError.mainBranchNotDetected
        }
        return branch
    }

    /// Detects the main branch of a repository.
    /// Tries `symbolic-ref refs/remotes/origin/HEAD` first, then falls back to
    /// checking for "main" or "master" branch existence.
    /// - Parameter repoPath: Absolute path to the git repository.
    /// - Returns: The main branch name, or nil if detection fails.
    static func detectMainBranchSync(repoPath: String) -> String? {
        // Try symbolic-ref first
        let symbolicResult = runGitCommand(
            directory: repoPath,
            arguments: ["symbolic-ref", "refs/remotes/origin/HEAD"]
        )
        if symbolicResult.exitCode == 0,
           let output = symbolicResult.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty {
            let components = output.split(separator: "/")
            if let branchName = components.last {
                return String(branchName)
            }
        }

        // Fallback: check for "main" branch
        let mainResult = runGitCommand(
            directory: repoPath,
            arguments: ["rev-parse", "--verify", "refs/heads/main"]
        )
        if mainResult.exitCode == 0 {
            return "main"
        }

        // Fallback: check for "master" branch
        let masterResult = runGitCommand(
            directory: repoPath,
            arguments: ["rev-parse", "--verify", "refs/heads/master"]
        )
        if masterResult.exitCode == 0 {
            return "master"
        }

        // Fallback: read the current HEAD symbolic ref. This handles freshly
        // initialized repos where refs/heads/<branch> doesn't exist yet
        // (no commits), but HEAD already points to the intended branch.
        let headResult = runGitCommand(
            directory: repoPath,
            arguments: ["symbolic-ref", "HEAD"]
        )
        if headResult.exitCode == 0,
           let headOutput = headResult.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
           !headOutput.isEmpty {
            let components = headOutput.split(separator: "/")
            if let branchName = components.last {
                let name = String(branchName)
                if name == "main" || name == "master" {
                    return name
                }
            }
        }

        return nil
    }

    /// Validates that a path is a git repository.
    /// - Parameter path: Absolute path to check.
    /// - Returns: `true` if the path is a git repository.
    static func isGitRepository(path: String) -> Bool {
        let result = runGitCommand(
            directory: path,
            arguments: ["rev-parse", "--git-dir"]
        )
        return result.exitCode == 0
    }

    // MARK: - Branch Listing

    /// Lists local branches in a repository, sorted by most recent commit date.
    /// Excludes branches that already have a worktree checked out.
    /// - Parameter repoPath: Absolute path to the git repository.
    /// - Returns: Array of branch names (e.g. ["feature-x", "fix-y", "main"]).
    static func listBranches(repoPath: String) -> [String] {
        // Get all local branches sorted by most recent commit
        let result = runGitCommand(
            directory: repoPath,
            arguments: [
                "for-each-ref",
                "--sort=-committerdate",
                "--format=%(refname:short)",
                "refs/heads/"
            ]
        )

        guard result.exitCode == 0, let output = result.stdout else { return [] }

        let allBranches = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Discover branches already checked out in worktrees so we can exclude them
        let worktreeResult = runGitCommand(
            directory: repoPath,
            arguments: ["worktree", "list", "--porcelain"]
        )
        var checkedOutBranches = Set<String>()
        if worktreeResult.exitCode == 0, let wtOutput = worktreeResult.stdout {
            for info in parseWorktreeList(wtOutput) {
                if let branch = info.branch {
                    checkedOutBranches.insert(branch)
                }
            }
        }

        return allBranches.filter { !checkedOutBranches.contains($0) }
    }

    /// Creates a git worktree for an existing branch (no new branch creation).
    /// - Parameters:
    ///   - repoPath: Absolute path to the main git repository checkout.
    ///   - projectSlug: Slugified project name for the directory structure.
    ///   - branchName: The existing branch name to check out.
    /// - Returns: The absolute path to the created worktree directory.
    /// - Throws: `WorktreeError` if the operation fails.
    static func createWorktreeFromExistingBranch(
        repoPath: String,
        projectSlug: String,
        branchName: String
    ) async throws -> String {
        // Slugify the branch name for the directory path to avoid nested directories
        // from branch names containing slashes (e.g. "feature/foo" → "feature-foo").
        let dirName = slugify(branchName)
        let worktreePath = "\(baseDirectoryPath)/\(projectSlug)/\(dirName)"

        // Ensure the parent directory exists
        let parentPath = "\(baseDirectoryPath)/\(projectSlug)"
        try FileManager.default.createDirectory(
            atPath: parentPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // git -C <repoPath> worktree add <worktreePath> <branchName>
        let result = runGitCommand(
            directory: repoPath,
            arguments: ["worktree", "add", worktreePath, branchName]
        )

        guard result.exitCode == 0 else {
            let errorMessage = result.stderr ?? "Unknown error"
            throw WorktreeError.creationFailed(errorMessage)
        }

        return worktreePath
    }

    // MARK: - Branch Name Generation

    /// Slugifies a workspace name into a valid git branch name.
    /// - Parameter name: The workspace name (e.g. "Fix authentication bug").
    /// - Returns: A valid branch name (e.g. "fix-authentication-bug").
    static func slugify(_ name: String) -> String {
        var slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")

        // Remove non-alphanumeric characters except hyphens
        slug = slug.filter { $0.isLetter || $0.isNumber || $0 == "-" }

        // Collapse consecutive hyphens
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }

        // Strip leading/trailing hyphens
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Fallback for empty result
        if slug.isEmpty {
            slug = "workspace"
        }

        return slug
    }

    /// Generates a unique branch name by appending a suffix if the base name already exists.
    /// - Parameters:
    ///   - baseName: The desired branch name.
    ///   - repoPath: The repository path to check against.
    /// - Returns: A unique branch name (e.g. "fix-auth-bug" or "fix-auth-bug-2").
    static func uniqueBranchName(
        baseName: String,
        repoPath: String
    ) async -> String {
        // Check if base name is available
        let checkResult = runGitCommand(
            directory: repoPath,
            arguments: ["rev-parse", "--verify", "refs/heads/\(baseName)"]
        )
        if checkResult.exitCode != 0 {
            return baseName // Branch doesn't exist, use it
        }

        // Try with suffixes
        for suffix in 2...99 {
            let candidate = "\(baseName)-\(suffix)"
            let result = runGitCommand(
                directory: repoPath,
                arguments: ["rev-parse", "--verify", "refs/heads/\(candidate)"]
            )
            if result.exitCode != 0 {
                return candidate
            }
        }

        // Ultimate fallback
        return "\(baseName)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Slugifies a project name for use as a directory name.
    /// - Parameter name: The project name.
    /// - Returns: A filesystem-safe slug.
    static func projectSlug(_ name: String) -> String {
        slugify(name)
    }

    // MARK: - Orphan Cleanup

    /// Reconciles worktrees on disk against persisted project data.
    /// Returns paths of worktrees that have no corresponding project/workspace.
    static func findOrphanedWorktrees(
        knownWorktreePaths: Set<String>
    ) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectoryPath) else { return [] }

        var orphans: [String] = []
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: baseDirectoryPath) else {
            return []
        }

        for projectDir in projectDirs {
            let projectPath = "\(baseDirectoryPath)/\(projectDir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let workspaceDirs = try? fm.contentsOfDirectory(atPath: projectPath) else {
                continue
            }

            for workspaceDir in workspaceDirs {
                let worktreePath = "\(projectPath)/\(workspaceDir)"
                var isWorktreeDir: ObjCBool = false
                guard fm.fileExists(atPath: worktreePath, isDirectory: &isWorktreeDir),
                      isWorktreeDir.boolValue else {
                    continue
                }

                if !knownWorktreePaths.contains(worktreePath) {
                    orphans.append(worktreePath)
                }
            }
        }

        return orphans
    }

    // MARK: - Private Git Helpers

    private struct GitResult {
        let exitCode: Int32
        let stdout: String?
        let stderr: String?
    }

    /// Returns the current PATH augmented with common tool directories
    /// (Homebrew on Apple Silicon and Intel) so that tools like `git-lfs`
    /// are reachable even when the app is launched from Finder/Dock with a
    /// minimal GUI PATH.
    static func augmentedPath() -> String {
        let base = ProcessInfo.processInfo.environment["PATH"]
            ?? getenv("PATH").map { String(cString: $0) }
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let components = base.split(separator: ":").map(String.init)
        var result = components
        // Common directories where Homebrew / MacPorts install tools.
        let extras = ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in extras where !result.contains(dir) {
            if FileManager.default.fileExists(atPath: dir) {
                result.append(dir)
            }
        }
        return result.joined(separator: ":")
    }

    /// Runs a git command and returns the result.
    /// Follows the same pattern as TabManager.runGitCommand.
    private static func runGitCommand(
        directory: String,
        arguments: [String]
    ) -> GitResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Inherit the full process environment and ensure PATH includes
        // common tool directories so git filter processes (e.g. git-lfs)
        // are reachable.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPath()
        process.environment = env

        do {
            try process.run()
        } catch {
            return GitResult(exitCode: -1, stdout: nil, stderr: error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)
        let stderr = String(data: stderrData, encoding: .utf8)

        return GitResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: - Worktree List Parsing

    /// Parses the porcelain output of `git worktree list --porcelain`.
    private static func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var currentIsBare = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // End of a worktree entry
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch,
                        isBare: currentIsBare
                    ))
                }
                currentPath = nil
                currentBranch = nil
                currentIsBare = false
                continue
            }

            if trimmed.hasPrefix("worktree ") {
                currentPath = String(trimmed.dropFirst("worktree ".count))
            } else if trimmed.hasPrefix("branch ") {
                let fullRef = String(trimmed.dropFirst("branch ".count))
                // Extract branch name from "refs/heads/branch-name"
                if fullRef.hasPrefix("refs/heads/") {
                    currentBranch = String(fullRef.dropFirst("refs/heads/".count))
                } else {
                    currentBranch = fullRef
                }
            } else if trimmed == "bare" {
                currentIsBare = true
            }
        }

        // Handle last entry (if output doesn't end with blank line)
        if let path = currentPath {
            worktrees.append(WorktreeInfo(
                path: path,
                branch: currentBranch,
                isBare: currentIsBare
            ))
        }

        return worktrees
    }
}

// MARK: - Supporting Types

/// Information about a git worktree.
struct WorktreeInfo {
    let path: String
    let branch: String?
    let isBare: Bool
}

/// Errors that can occur during worktree operations.
enum WorktreeError: LocalizedError {
    case creationFailed(String)
    case removalFailed(String)
    case listFailed(String)
    case mainBranchNotDetected
    case notAGitRepository

    var errorDescription: String? {
        switch self {
        case .creationFailed(let message):
            return "Failed to create worktree: \(message)"
        case .removalFailed(let message):
            return "Failed to remove worktree: \(message)"
        case .listFailed(let message):
            return "Failed to list worktrees: \(message)"
        case .mainBranchNotDetected:
            return "Could not detect the main branch. Ensure the repository has a 'main' or 'master' branch."
        case .notAGitRepository:
            return "The selected directory is not a git repository."
        }
    }
}
