import Foundation

/// Git state of a workspace, for the thread details card, git actions and the composer's branch picker.
public struct GitStatusSummary: Sendable, Hashable {
    public var isRepository: Bool
    /// Current branch; nil when detached or not a repository.
    public var branch: String?
    public var isDefaultBranch: Bool
    public var hasRemote: Bool
    public var hasUpstream: Bool
    public var ahead: Int
    public var behind: Int
    /// Uncommitted changes (tracked + untracked).
    public var files: [ChangedFileStat]
    /// Open pull request for the branch, when `gh` reports one.
    public var pullRequest: PullRequestInfo?

    public init(
        isRepository: Bool,
        branch: String? = nil,
        isDefaultBranch: Bool = false,
        hasRemote: Bool = false,
        hasUpstream: Bool = false,
        ahead: Int = 0,
        behind: Int = 0,
        files: [ChangedFileStat] = [],
        pullRequest: PullRequestInfo? = nil
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDefaultBranch = isDefaultBranch
        self.hasRemote = hasRemote
        self.hasUpstream = hasUpstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.pullRequest = pullRequest
    }

    public static let notARepository = GitStatusSummary(isRepository: false)

    public var hasChanges: Bool { !files.isEmpty }
    public var insertions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public struct PullRequestInfo: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable {
        case open, draft, closed, merged
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State

    public init(number: Int, title: String, url: String, state: State) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
    }
}

/// A branch for the branch picker.
public struct GitBranchRef: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// Short name (`main`, `origin/feature`).
    public var name: String
    public var isRemote: Bool
    public var isCurrent: Bool
    public var isDefault: Bool
    /// Checked out in another worktree at this path.
    public var worktreePath: String?

    public init(name: String, isRemote: Bool = false, isCurrent: Bool = false, isDefault: Bool = false, worktreePath: String? = nil) {
        self.name = name
        self.isRemote = isRemote
        self.isCurrent = isCurrent
        self.isDefault = isDefault
        self.worktreePath = worktreePath
    }
}

/// The stacked git actions of the thread details card.
public enum GitStackedAction: String, Sendable, Hashable, CaseIterable {
    case commit
    case push
    case createPullRequest = "create_pr"
    case commitAndPush = "commit_push"
    case commitPushAndPullRequest = "commit_push_pr"
}

public struct GitActionRequest: Sendable, Hashable {
    public var action: GitStackedAction
    public var cwd: String
    /// nil = generate one from the staged diff.
    public var commitMessage: String?
    /// Only these paths are committed; nil = everything.
    public var filePaths: [String]?
    /// Commit onto a new feature branch first.
    public var featureBranch: Bool

    public init(action: GitStackedAction, cwd: String, commitMessage: String? = nil, filePaths: [String]? = nil, featureBranch: Bool = false) {
        self.action = action
        self.cwd = cwd
        self.commitMessage = commitMessage
        self.filePaths = filePaths
        self.featureBranch = featureBranch
    }
}

/// Progress of a running git action ("Generating commit message...", "Pushing...").
public struct GitActionProgress: Sendable, Hashable {
    public var label: String
    public var outputLine: String?

    public init(label: String, outputLine: String? = nil) {
        self.label = label
        self.outputLine = outputLine
    }
}

public struct GitActionResult: Sendable, Hashable {
    /// Toast title ("Committed a1b2c3d", "Pushed a1b2c3d to main", "Created PR #12").
    public var title: String
    public var detail: String?
    /// URL of the created or opened pull request.
    public var pullRequestURL: String?

    public init(title: String, detail: String? = nil, pullRequestURL: String? = nil) {
        self.title = title
        self.detail = detail
        self.pullRequestURL = pullRequestURL
    }
}

/// Everything the engine and the UI ask git for. `LiveGitService` runs the git CLI;
/// fixtures and tests substitute their own.
public protocol GitService: Sendable {
    func isRepository(_ cwd: String) async -> Bool
    /// Top level of the repository containing `cwd`.
    func repositoryRoot(_ cwd: String) async -> String?

    // Checkpoints: hidden refs that never touch the user's index or HEAD.
    func captureCheckpoint(cwd: String, ref: String) async throws
    func checkpointExists(cwd: String, ref: String) async -> Bool
    /// Files changed between two checkpoint refs.
    func changedFiles(cwd: String, fromRef: String, toRef: String) async throws -> [ChangedFileStat]
    /// Unified diff between two checkpoint refs.
    func diff(cwd: String, fromRef: String, toRef: String, ignoreWhitespace: Bool) async throws -> String
    /// Unified diff of uncommitted changes against HEAD (untracked files included).
    func workingTreeDiff(cwd: String, ignoreWhitespace: Bool) async throws -> String
    /// Puts the workspace back to `ref` (tracked and untracked files), keeping HEAD.
    func restoreCheckpoint(cwd: String, ref: String) async throws
    func deleteRefs(cwd: String, refs: [String]) async throws

    func status(cwd: String) async throws -> GitStatusSummary
    func branches(cwd: String) async throws -> [GitBranchRef]
    func createBranch(cwd: String, name: String, checkout: Bool) async throws
    func switchBranch(cwd: String, name: String) async throws
    func renameBranch(cwd: String, from: String, to: String) async throws

    /// Creates `newBranch` from `baseBranch` and checks it out in a new worktree under `directory`.
    /// Returns the worktree path.
    func createWorktree(projectRoot: String, baseBranch: String, newBranch: String, directory: String) async throws -> String
    func removeWorktree(projectRoot: String, path: String, force: Bool) async throws

    /// Commit / push / create PR, reporting progress. Commit messages and PR text come from `writer`
    /// when the request has none.
    func runAction(
        _ request: GitActionRequest,
        writer: any SourceControlWriter,
        progress: @escaping @Sendable (GitActionProgress) -> Void
    ) async throws -> GitActionResult
}

/// Writes commit messages and pull request text (backed by a provider's text generation).
public protocol SourceControlWriter: Sendable {
    /// `{subject, body, branch?}` for a staged patch.
    func commitMessage(branch: String?, stagedSummary: String, stagedPatch: String, includeBranch: Bool) async throws -> (subject: String, body: String, branch: String?)
    /// `{title, body}` for a branch range.
    func pullRequest(baseBranch: String, headBranch: String, commits: String, diffStat: String, diffPatch: String) async throws -> (title: String, body: String)
}
