import AppKit
import Testing
@testable import Soprano

/// Pane rows name a branch only when it is not the repository's default,
/// so a sidebar of checkouts on `main` is not `main` on every line.
struct GitBranchMonitorTests {
    /// A `.git` directory with just the files the monitor reads.
    private func makeRepository(head: String, originHead: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-branch-\(UUID().uuidString)", isDirectory: true)
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("refs/remotes/origin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/\(head)\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        if let originHead {
            try "ref: refs/remotes/origin/\(originHead)\n".write(
                to: git.appendingPathComponent("refs/remotes/origin/HEAD"),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    @Test func theBranchOriginNamesAsItsDefaultIsNotNotable() throws {
        let develop = try makeRepository(head: "develop", originHead: "develop")
        let main = try makeRepository(head: "main", originHead: "develop")
        defer {
            try? FileManager.default.removeItem(at: develop)
            try? FileManager.default.removeItem(at: main)
        }
        let monitor = GitBranchMonitor()

        #expect(monitor.notableBranch(for: develop.path) == nil)
        #expect(monitor.notableBranch(for: main.path) == "main")
    }

    @Test func withoutAnOriginMainAndMasterCountAsTheDefault() throws {
        let main = try makeRepository(head: "main", originHead: nil)
        let master = try makeRepository(head: "master", originHead: nil)
        let feature = try makeRepository(head: "feat/automations", originHead: nil)
        defer {
            for url in [main, master, feature] { try? FileManager.default.removeItem(at: url) }
        }
        let monitor = GitBranchMonitor()

        #expect(monitor.notableBranch(for: main.path) == nil)
        #expect(monitor.notableBranch(for: master.path) == nil)
        #expect(monitor.notableBranch(for: feature.appendingPathComponent("Sources").path) == "feat/automations")
    }

    @Test func aLinkedWorktreeReadsTheDefaultFromItsCommonGitDirectory() throws {
        let repository = try makeRepository(head: "main", originHead: "main")
        defer { try? FileManager.default.removeItem(at: repository) }
        let worktreeGit = repository.appendingPathComponent(".git/worktrees/feature", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: worktreeGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: worktreeGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let checkout = repository.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGit.path)\n".write(to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(GitBranchMonitor().notableBranch(for: checkout.path) == nil)
        #expect(GitBranchMonitor.remoteDefaultBranch(headPath: worktreeGit.appendingPathComponent("HEAD").path) == "main")
    }

    @Test func aDetachedHeadIsAlwaysNamed() throws {
        let repository = try makeRepository(head: "main", originHead: "main")
        defer { try? FileManager.default.removeItem(at: repository) }
        try "4cb9594f00d1e3b0c0ffee0000000000000000aa\n".write(
            to: repository.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )

        #expect(GitBranchMonitor().notableBranch(for: repository.path) == "4cb9594")
    }

    @Test func aFolderOutsideAnyRepositoryHasNoBranch() {
        #expect(GitBranchMonitor().notableBranch(for: "/") == nil)
    }
}
