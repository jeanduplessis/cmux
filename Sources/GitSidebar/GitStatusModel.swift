import Foundation

// MARK: - Git File Status

enum GitFileStatus: Equatable, Hashable {
    case added
    case modified
    case deleted
    case renamed(from: String)
    case copied
    case typeChanged
    case untracked

    var symbol: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "?"
        }
    }

    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed(let from): return "Renamed from \(from)"
        case .copied: return "Copied"
        case .typeChanged: return "Type Changed"
        case .untracked: return "Untracked"
        }
    }

    var iconName: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .modified: return "circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        case .copied: return "doc.on.doc.fill"
        case .typeChanged: return "arrow.triangle.2.circlepath"
        case .untracked: return "questionmark.circle.fill"
        }
    }
}

// MARK: - Staging Area

enum GitStagingArea: Equatable, Hashable {
    case staged
    case unstaged
    case untracked
}

// MARK: - File Entry

struct GitFileEntry: Identifiable, Equatable, Hashable {
    let id: String
    let path: String
    let status: GitFileStatus
    let area: GitStagingArea

    /// Number of lines added in this file's diff, or nil if unavailable (e.g. binary files).
    var insertions: Int?

    /// Number of lines deleted in this file's diff, or nil if unavailable (e.g. binary files).
    var deletions: Int?

    /// Child file paths (relative to this directory) for untracked directory entries.
    /// Empty for regular file entries.
    var children: [String] = []

    /// Whether the children list was truncated (directory contains more than the display limit).
    var childrenTruncated: Bool = false

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String? {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
}

// MARK: - Repository Status

struct GitRepoStatus: Equatable {
    let branch: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    let staged: [GitFileEntry]
    let unstaged: [GitFileEntry]
    let untracked: [GitFileEntry]
    let isGitRepo: Bool

    var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }
    var totalChanges: Int { staged.count + unstaged.count + untracked.count }

    static let empty = GitRepoStatus(
        branch: nil,
        upstream: nil,
        ahead: 0,
        behind: 0,
        staged: [],
        unstaged: [],
        untracked: [],
        isGitRepo: true
    )

    static let notARepo = GitRepoStatus(
        branch: nil,
        upstream: nil,
        ahead: 0,
        behind: 0,
        staged: [],
        unstaged: [],
        untracked: [],
        isGitRepo: false
    )
}
