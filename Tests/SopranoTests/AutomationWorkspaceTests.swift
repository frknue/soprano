import AppKit
import Testing
@testable import Soprano

struct AutomationWorkspaceTests {
    /// A repository with one commit, plus a folder for worktrees, both thrown
    /// away after the test.
    private func makeRepository() throws -> (root: URL, worktrees: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-automation-git-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("theme", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try Git.output(["init", "--quiet", "--initial-branch=main"], in: root.path)
        _ = try Git.output(["config", "user.email", "test@example.com"], in: root.path)
        _ = try Git.output(["config", "user.name", "Test"], in: root.path)
        try "readme\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "theme\n".write(to: root.appendingPathComponent("theme/index.liquid"), atomically: true, encoding: .utf8)
        _ = try Git.output(["add", "."], in: root.path)
        _ = try Git.output(["commit", "--quiet", "-m", "init"], in: root.path)
        return (root, base.appendingPathComponent("worktrees", isDirectory: true))
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private var date: Date { Date(timeIntervalSince1970: 1_793_260_800) }

    @Test(.enabled(if: Git.executableURL != nil))
    func aRunsWorktreeStartsAtTheSamePlaceInTheRepositoryOnItsOwnBranch() throws {
        let (root, worktrees) = try makeRepository()
        defer { cleanUp(root) }

        let checkout = try AutomationWorktree.create(
            from: root.appendingPathComponent("theme").path,
            automationId: "audit",
            baseBranch: nil,
            date: date,
            under: worktrees
        )

        #expect(checkout.worktree.branch.hasPrefix("automation/audit-"))
        #expect(checkout.workingDirectory == checkout.worktree.path + "/theme")
        #expect(FileManager.default.fileExists(atPath: checkout.workingDirectory + "/index.liquid"))
        #expect(try Git.output(["rev-parse", "HEAD"], in: checkout.worktree.path) == checkout.worktree.baseCommit)
    }

    @Test(.enabled(if: Git.executableURL != nil))
    func twoRunsInTheSameMinuteGetDifferentBranches() throws {
        let (root, worktrees) = try makeRepository()
        defer { cleanUp(root) }

        let first = try AutomationWorktree.create(from: root.path, automationId: "audit", baseBranch: nil, date: date, under: worktrees)
        let second = try AutomationWorktree.create(from: root.path, automationId: "audit", baseBranch: nil, date: date, under: worktrees)

        #expect(first.worktree.branch != second.worktree.branch)
        #expect(first.worktree.path != second.worktree.path)
    }

    @Test(.enabled(if: Git.executableURL != nil))
    func aWorktreeTheRunLeftAloneCountsAsUntouchedAndIsRemovedWithItsBranch() throws {
        let (root, worktrees) = try makeRepository()
        defer { cleanUp(root) }
        let checkout = try AutomationWorktree.create(from: root.path, automationId: "audit", baseBranch: nil, date: date, under: worktrees)

        #expect(AutomationWorktree.isUntouched(checkout.worktree))
        AutomationWorktree.remove(checkout.worktree)

        #expect(!FileManager.default.fileExists(atPath: checkout.worktree.path))
        #expect((try? Git.output(["rev-parse", "--verify", "--quiet", "refs/heads/\(checkout.worktree.branch)"], in: root.path)) == nil)
    }

    @Test(.enabled(if: Git.executableURL != nil))
    func aWorktreeWithAChangeOrACommitIsNotUntouched() throws {
        let (root, worktrees) = try makeRepository()
        defer { cleanUp(root) }
        let changed = try AutomationWorktree.create(from: root.path, automationId: "audit", baseBranch: nil, date: date, under: worktrees)
        try "new\n".write(toFile: changed.worktree.path + "/notes.md", atomically: true, encoding: .utf8)

        let committed = try AutomationWorktree.create(from: root.path, automationId: "audit", baseBranch: nil, date: date, under: worktrees)
        _ = try Git.output(["commit", "--quiet", "--allow-empty", "-m", "work"], in: committed.worktree.path)

        #expect(!AutomationWorktree.isUntouched(changed.worktree))
        #expect(!AutomationWorktree.isUntouched(committed.worktree))
    }

    @Test(.enabled(if: Git.executableURL != nil))
    func aBaseBranchThatDoesNotExistFailsWithItsName() throws {
        let (root, worktrees) = try makeRepository()
        defer { cleanUp(root) }

        #expect(throws: AutomationWorktree.Failure.unknownBase("release")) {
            try AutomationWorktree.create(from: root.path, automationId: "audit", baseBranch: "release", date: date, under: worktrees)
        }
    }

    @Test func aPrecheckThatExitsZeroLetsTheRunStart() {
        let outcome = AutomationPrecheck.run("echo ready", in: "/tmp", timeout: 10, shell: "/bin/sh")

        #expect(outcome.passed)
        #expect(outcome.output == "ready")
    }

    @Test func aFailingPrecheckSaysItsExitCodeAndWhatItPrinted() {
        let outcome = AutomationPrecheck.run("echo 'no open PRs' >&2; exit 3", in: "/tmp", timeout: 10, shell: "/bin/sh")

        #expect(!outcome.passed)
        #expect(outcome.exitCode == 3)
        #expect(outcome.summary == "The precheck exited with code 3.\n\nno open PRs")
    }

    @Test func aPrecheckThatOutlivesItsTimeoutIsStoppedAndFails() {
        let started = Date()
        let outcome = AutomationPrecheck.run("sleep 30", in: "/tmp", timeout: 1, shell: "/bin/sh")

        #expect(outcome.timedOut)
        #expect(!outcome.passed)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aPrecheckThatLeavesABackgroundProcessRunningStillAnswersWhenItExits() {
        // The child inherits the output pipe; waiting for the pipe to close
        // held every automation's setup until the child was done.
        let started = Date()
        let outcome = AutomationPrecheck.run("sleep 20 & echo started", in: "/tmp", timeout: 10, shell: "/bin/sh")

        #expect(outcome.passed)
        #expect(outcome.output == "started")
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
