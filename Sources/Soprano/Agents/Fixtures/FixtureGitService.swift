import Foundation
import SopranoAgentsCore

/// Canned git answers for the snapshot harness and tests: never touches a repository.
struct FixtureGitService: GitService {
    var statusSummary = GitStatusSummary(
        isRepository: true,
        branch: "soprano/fix-login-redirect",
        isDefaultBranch: false,
        hasRemote: true,
        hasUpstream: true,
        ahead: 2,
        behind: 0,
        files: [
            ChangedFileStat(path: "Sources/Auth/LoginController.swift", additions: 18, deletions: 6),
            ChangedFileStat(path: "Sources/Auth/SessionStore.swift", additions: 9, deletions: 2),
            ChangedFileStat(path: "Tests/AuthTests/LoginRedirectTests.swift", additions: 41, deletions: 0),
        ],
        pullRequest: PullRequestInfo(number: 128, title: "Fix login redirect loop", url: "https://github.com/acme/app/pull/128", state: .open)
    )
    var branchList: [GitBranchRef] = [
        GitBranchRef(name: "main", isDefault: true),
        GitBranchRef(name: "soprano/fix-login-redirect", isCurrent: true),
        GitBranchRef(name: "feature/dark-mode", worktreePath: "/Users/demo/.soprano-agents/worktrees/app/feature-dark-mode"),
        GitBranchRef(name: "release/2.4"),
        GitBranchRef(name: "origin/main", isRemote: true),
        GitBranchRef(name: "origin/release/2.4", isRemote: true),
    ]

    func isRepository(_ cwd: String) async -> Bool { true }
    func repositoryRoot(_ cwd: String) async -> String? { cwd }
    func checkedOutBranch(_ cwd: String) async -> String? { statusSummary.branch }
    func captureCheckpoint(cwd: String, ref: String) async throws {}
    func checkpointExists(cwd: String, ref: String) async -> Bool { true }

    func changedFiles(cwd: String, fromRef: String, toRef: String) async throws -> [ChangedFileStat] {
        statusSummary.files
    }

    func diff(cwd: String, fromRef: String, toRef: String, ignoreWhitespace: Bool) async throws -> String {
        DemoFixtures.sampleDiff
    }

    func workingTreeDiff(cwd: String, ignoreWhitespace: Bool) async throws -> String {
        DemoFixtures.sampleDiff
    }

    func restoreCheckpoint(cwd: String, ref: String) async throws {}
    func deleteRefs(cwd: String, refs: [String]) async throws {}
    func status(cwd: String) async throws -> GitStatusSummary { statusSummary }
    func branches(cwd: String) async throws -> [GitBranchRef] { branchList }
    func createBranch(cwd: String, name: String, checkout: Bool) async throws {}
    func switchBranch(cwd: String, name: String) async throws {}
    func renameBranch(cwd: String, from: String, to: String) async throws {}

    func createWorktree(projectRoot: String, baseBranch: String, newBranch: String, directory: String) async throws -> String {
        "\(directory)/\(URL(fileURLWithPath: projectRoot).lastPathComponent)/\(newBranch.replacingOccurrences(of: "/", with: "-"))"
    }

    func removeWorktree(projectRoot: String, path: String, force: Bool) async throws {}

    func runAction(
        _ request: GitActionRequest,
        writer: any SourceControlWriter,
        progress: @escaping @Sendable (GitActionProgress) -> Void
    ) async throws -> GitActionResult {
        progress(GitActionProgress(label: "Committing..."))
        return GitActionResult(title: "Committed a1b2c3d", detail: "Fix login redirect loop")
    }
}
