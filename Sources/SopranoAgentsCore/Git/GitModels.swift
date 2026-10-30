import Foundation

// Value types describing a repository. Everything is Sendable so results
// cross from git's background tasks to the main actor unchanged.

// MARK: - Commits

public struct Signature: Sendable, Hashable {
    public var name: String
    public var email: String
    public var date: Date

    public init(name: String, email: String, date: Date) {
        self.name = name
        self.email = email
        self.date = date
    }
}

public struct Commit: Sendable, Hashable, Identifiable {
    /// Full object id (40 hex for SHA-1 repositories, 64 for SHA-256).
    public var id: String
    /// Parent ids in git order; the first parent is the mainline.
    public var parents: [String]
    public var author: Signature
    public var committer: Signature
    /// First line of the message.
    public var summary: String

    public var shortID: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(id: String, parents: [String], author: Signature, committer: Signature, summary: String) {
        self.id = id
        self.parents = parents
        self.author = author
        self.committer = committer
        self.summary = summary
    }
}

public struct CommitDetail: Sendable, Hashable {
    public var commit: Commit
    /// Message after the summary line, leading/trailing blank lines removed.
    public var body: String
    /// Changes against the first parent (the empty tree for a root commit).
    public var files: [ChangedFile]

    public init(commit: Commit, body: String, files: [ChangedFile]) {
        self.commit = commit
        self.body = body
        self.files = files
    }
}

public enum ChangeKind: String, Sendable, Hashable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unmerged = "U"
    case untracked = "?"
}

/// One file in a commit, stash, or diff listing.
public struct ChangedFile: Sendable, Hashable, Identifiable {
    public var path: String
    /// Source path of a rename or copy.
    public var oldPath: String?
    public var kind: ChangeKind
    /// Line counts; nil for binary files.
    public var additions: Int?
    public var deletions: Int?

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, kind: ChangeKind, additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
    }
}

// MARK: - Refs

public enum Head: Sendable, Hashable {
    /// On a branch; the short name, e.g. "main".
    case branch(String)
    /// Detached at a commit id.
    case detached(String)
    /// A branch with no commits yet (fresh repository).
    case unborn(String)
}

public struct Branch: Sendable, Hashable, Identifiable {
    /// Short name: "main" for local, "origin/main" for remote-tracking.
    public var name: String
    /// Full ref: "refs/heads/main" or "refs/remotes/origin/main".
    public var fullName: String
    /// Commit the branch points at.
    public var target: String
    public var isRemote: Bool
    /// Remote-tracking branches: the remote name ("origin").
    public var remoteName: String?
    /// Local branches: upstream short name ("origin/main"), if configured.
    public var upstream: String?
    /// Commits ahead/behind the upstream; 0 without an upstream.
    public var ahead: Int
    public var behind: Int
    /// The configured upstream no longer exists on the remote.
    public var upstreamGone: Bool
    /// Checked out in this worktree.
    public var isHead: Bool

    public var id: String { fullName }

    public init(
        name: String, fullName: String, target: String, isRemote: Bool, remoteName: String? = nil,
        upstream: String? = nil, ahead: Int = 0, behind: Int = 0, upstreamGone: Bool = false, isHead: Bool = false
    ) {
        self.name = name
        self.fullName = fullName
        self.target = target
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isHead = isHead
    }
}

public struct Tag: Sendable, Hashable, Identifiable {
    public var name: String
    public var fullName: String
    /// Commit the tag resolves to (peeled for annotated tags).
    public var target: String
    public var isAnnotated: Bool
    /// Subject of an annotated tag's message.
    public var message: String?

    public var id: String { fullName }

    public init(name: String, fullName: String, target: String, isAnnotated: Bool, message: String? = nil) {
        self.name = name
        self.fullName = fullName
        self.target = target
        self.isAnnotated = isAnnotated
        self.message = message
    }
}

public struct Remote: Sendable, Hashable, Identifiable {
    public var name: String
    public var fetchURL: String?
    public var pushURL: String?

    public var id: String { name }

    public init(name: String, fetchURL: String?, pushURL: String?) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }
}

public struct Stash: Sendable, Hashable, Identifiable {
    /// Position in `git stash list` (0 = newest).
    public var index: Int
    /// The stash commit id.
    public var id: String
    /// The commit the stash was made on (the stash commit's first parent).
    public var base: String
    public var message: String
    public var date: Date

    /// "stash@{N}".
    public var reference: String { "stash@{\(index)}" }

    public init(index: Int, id: String, base: String, message: String, date: Date) {
        self.index = index
        self.id = id
        self.base = base
        self.message = message
        self.date = date
    }
}

public struct RefSnapshot: Sendable, Hashable {
    public var head: Head
    /// Commit HEAD points at; nil for an unborn branch.
    public var headCommit: String?
    public var localBranches: [Branch]
    public var remoteBranches: [Branch]
    public var tags: [Tag]
    public var remotes: [Remote]

    public static let empty = RefSnapshot(
        head: .unborn("main"), headCommit: nil, localBranches: [], remoteBranches: [], tags: [], remotes: []
    )

    public init(
        head: Head, headCommit: String?, localBranches: [Branch], remoteBranches: [Branch], tags: [Tag], remotes: [Remote]
    ) {
        self.head = head
        self.headCommit = headCommit
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.tags = tags
        self.remotes = remotes
    }

    /// The checked-out local branch, if HEAD is on one.
    public var currentBranch: Branch? { localBranches.first(where: \.isHead) }
}

// MARK: - Working tree

public enum ConflictKind: String, Sendable, Hashable {
    case bothModified = "UU"
    case bothAdded = "AA"
    case bothDeleted = "DD"
    case addedByUs = "AU"
    case addedByThem = "UA"
    case deletedByUs = "DU"
    case deletedByThem = "UD"
}

/// One path from `git status`. A file can be staged and unstaged at once.
public struct StatusEntry: Sendable, Hashable, Identifiable {
    public var path: String
    /// Rename/copy source in the index.
    public var oldPath: String?
    /// Index side (porcelain X); nil when the index matches HEAD.
    public var staged: ChangeKind?
    /// Worktree side (porcelain Y); `.untracked` for untracked files.
    public var unstaged: ChangeKind?
    /// Set for unmerged paths; `staged`/`unstaged` are nil then.
    public var conflict: ConflictKind?

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, staged: ChangeKind? = nil, unstaged: ChangeKind? = nil, conflict: ConflictKind? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.staged = staged
        self.unstaged = unstaged
        self.conflict = conflict
    }
}

/// A multi-step operation git has paused, usually on conflicts.
public enum OperationInProgress: Sendable, Hashable {
    case merge(mergingHead: String?)
    /// `step`/`total` come from the rebase todo when git exposes them.
    case rebase(headName: String?, onto: String?, step: Int?, total: Int?)
    case cherryPick(commit: String?)
    case revert(commit: String?)

    public var title: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    /// Whether `skip` is meaningful (rebase and cherry-pick).
    public var canSkip: Bool {
        switch self {
        case .rebase, .cherryPick, .revert: true
        case .merge: false
        }
    }
}

public struct WorkingTreeStatus: Sendable, Hashable {
    public var entries: [StatusEntry]
    public var operation: OperationInProgress?

    public static let clean = WorkingTreeStatus(entries: [], operation: nil)

    public init(entries: [StatusEntry], operation: OperationInProgress?) {
        self.entries = entries
        self.operation = operation
    }

    public var isClean: Bool { entries.isEmpty }
    public var conflicted: [StatusEntry] { entries.filter { $0.conflict != nil } }
    public var staged: [StatusEntry] { entries.filter { $0.staged != nil } }
    public var unstaged: [StatusEntry] { entries.filter { $0.unstaged != nil } }
}

// MARK: - Diffs

public enum DiffTarget: Sendable, Hashable {
    /// Index → worktree. Untracked files diff against /dev/null.
    case unstaged(path: String)
    /// HEAD → index (the empty tree before the first commit).
    case staged(path: String)
    /// First parent → commit (empty tree for a root commit). nil path = every file.
    case commit(id: String, path: String?)
    /// Stash base → stash, including the stash's untracked files. nil path = every file.
    case stash(index: Int, path: String?)
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case added
        case removed
        /// "\ No newline at end of file", attached to the line before it.
        case noNewlineMarker
    }

    public var kind: Kind
    /// Line text without the leading +/-/space and without the newline.
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the closing "@@" (usually the enclosing function), may be empty.
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

public struct FileDiff: Sendable, Hashable {
    /// nil when the old side is /dev/null (added file).
    public var oldPath: String?
    /// nil when the new side is /dev/null (deleted file).
    public var newPath: String?
    public var kind: ChangeKind
    public var isBinary: Bool
    public var oldMode: String?
    public var newMode: String?
    /// Raw header lines from "diff --git" through "+++", kept verbatim so a
    /// hunk can be turned back into an applicable patch.
    public var headerLines: [String]
    public var hunks: [DiffHunk]

    public var path: String { newPath ?? oldPath ?? "" }

    public init(
        oldPath: String?, newPath: String?, kind: ChangeKind, isBinary: Bool, oldMode: String? = nil,
        newMode: String? = nil, headerLines: [String], hunks: [DiffHunk]
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.kind = kind
        self.isBinary = isBinary
        self.oldMode = oldMode
        self.newMode = newMode
        self.headerLines = headerLines
        self.hunks = hunks
    }
}

// MARK: - Command options

public enum MergeMode: String, Sendable, Hashable, CaseIterable {
    /// Fast-forward when possible, merge commit otherwise (git default).
    case fastForwardIfPossible
    case fastForwardOnly
    /// Always create a merge commit.
    case noFastForward
}

public enum PullMode: String, Sendable, Hashable, CaseIterable {
    /// `git pull --ff`: fast-forward if possible, merge otherwise (GitKraken's default).
    case fastForwardIfPossible = "ff"
    /// `git pull --ff-only`.
    case fastForwardOnly = "ff-only"
    /// `git pull --rebase`.
    case rebase
}

public enum ResetMode: String, Sendable, Hashable, CaseIterable {
    case soft
    case mixed
    case hard
}

public enum ConflictSide: Sendable, Hashable {
    case ours
    case theirs
}

// MARK: - Errors

/// A git invocation that exited with a status outside its accepted set.
public struct GitError: Error, Sendable, Hashable, LocalizedError {
    public var arguments: [String]
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(arguments: [String], exitCode: Int32, stdout: String, stderr: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }
        return "git \(arguments.first ?? "") exited with status \(exitCode)"
    }
}

public enum GitSetupError: Error, Sendable, Hashable, LocalizedError {
    /// No usable git executable was found.
    case gitNotFound
    /// The path is not inside a git worktree.
    case notARepository(String)
    /// git could not be launched.
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "No git executable found. Install Git (Homebrew or the Xcode Command Line Tools) or set git.path in settings.json."
        case let .notARepository(path):
            "\(path) is not a git repository."
        case let .launchFailed(reason):
            "Could not run git: \(reason)"
        }
    }
}
