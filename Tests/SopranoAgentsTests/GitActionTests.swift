import AppKit
import Testing
@testable import SopranoAgentsCore

struct GitActionTests {
    @Test func committingWithAnExplicitMessageUsesItsFirstLineAsSubjectAndTheRestAsBody() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try repo.write("a.txt", "a\nb\n")
        try repo.write("new.txt", "new\n")
        let writer = FakeSourceControlWriter(subject: "unused")
        let log = ProgressLog()

        let result = try await sandbox.service.runAction(
            GitActionRequest(action: .commit, cwd: repo.path, commitMessage: "Add b\n\nMore detail."),
            writer: writer, progress: log.record
        )

        let sha = try await repo.output("rev-parse", "--short=7", "HEAD")
        #expect(result.title == "Committed \(sha)")
        #expect(result.detail == "Add b")
        #expect(try await repo.output("log", "-1", "--format=%s%n%b") == "Add b\nMore detail.")
        #expect(try await repo.output("status", "--porcelain").isEmpty)
        #expect(writer.stagedSummaries.isEmpty)
        #expect(log.labels == ["Committing..."])
    }

    @Test func committingWithoutAMessageAsksTheWriterWithTheStagedChanges() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try repo.write("a.txt", "changed\n")
        try repo.write("untracked.txt", "u\n")
        let writer = FakeSourceControlWriter(subject: "Update the a file.\nignored second line", body: "- details")
        let log = ProgressLog()

        let result = try await sandbox.service.runAction(
            GitActionRequest(action: .commit, cwd: repo.path), writer: writer, progress: log.record
        )

        #expect(log.labels == ["Generating commit message...", "Committing..."])
        #expect(writer.stagedSummaries == ["M\ta.txt\nA\tuntracked.txt"])
        #expect(writer.stagedPatches.first?.contains("+changed") == true)
        #expect(result.detail == "Update the a file")
        #expect(try await repo.output("log", "-1", "--format=%s%n%b") == "Update the a file\n- details")
    }

    @Test func committingSelectedFilesLeavesTheOthersUncommitted() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "a2\n")
        try repo.write("b.txt", "b2\n")
        try await repo.git("add", "b.txt")
        let writer = FakeSourceControlWriter(subject: "Change a")

        _ = try await sandbox.service.runAction(
            GitActionRequest(action: .commit, cwd: repo.path, filePaths: ["a.txt"]), writer: writer, progress: { _ in }
        )

        #expect(writer.stagedSummaries == ["M\ta.txt"])
        #expect(try await repo.output("show", "--name-only", "--format=", "HEAD") == "a.txt")
        #expect(try await repo.output("status", "--porcelain") == "M b.txt")
    }

    @Test func committingOnANewBranchUsesTheWritersBranchSuggestion() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try await repo.git("branch", "feature/login-fix")
        try repo.write("a.txt", "b\n")
        let writer = FakeSourceControlWriter(subject: "Fix login", branch: "login fix")
        let log = ProgressLog()

        _ = try await sandbox.service.runAction(
            GitActionRequest(action: .commit, cwd: repo.path, featureBranch: true), writer: writer, progress: log.record
        )

        #expect(try await repo.output("symbolic-ref", "--short", "HEAD") == "feature/login-fix-2")
        #expect(try await repo.output("log", "-1", "--format=%s") == "Fix login")
        #expect(try await repo.output("rev-parse", "main") != (try await repo.output("rev-parse", "HEAD")))
        #expect(writer.stagedSummaries.count == 1)
        #expect(log.labels == ["Preparing feature branch...", "Generating commit message...", "Committing..."])
    }

    @Test func pushingPublishesTheBranchToTheRemoteAndSkipsWhenUpToDate() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let remote = try await sandbox.bareRemote()
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try await repo.git("remote", "add", "origin", remote.path)
        try await repo.git("switch", "--quiet", "-c", "topic")
        try repo.write("a.txt", "topic\n")
        let writer = FakeSourceControlWriter(subject: "unused")
        let log = ProgressLog()

        let result = try await sandbox.service.runAction(
            GitActionRequest(action: .commitAndPush, cwd: repo.path, commitMessage: "Topic change"),
            writer: writer, progress: log.record
        )

        let sha = try await repo.output("rev-parse", "--short=7", "HEAD")
        #expect(result.title == "Pushed \(sha) to topic")
        #expect(result.detail == "Topic change")
        #expect(log.labels == ["Committing...", "Pushing..."])
        let remoteHead = try await sandbox.runner.run(["rev-parse", "refs/heads/topic"], in: remote).trimmed
        #expect(remoteHead == (try await repo.output("rev-parse", "HEAD")))
        #expect(try await repo.output("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/topic")
        let status = try await sandbox.service.status(cwd: repo.path)
        #expect(status.hasUpstream && status.ahead == 0)

        let again = try await sandbox.service.runAction(
            GitActionRequest(action: .push, cwd: repo.path), writer: writer, progress: { _ in }
        )
        #expect(again.title == "Done")
        #expect(again.detail == "Branch is up to date. No action needed.")
    }

    @Test func pushingWithoutARemoteFailsWithT3CodesMessage() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])

        await #expect(throws: GitActionError("Cannot push because no git remote is configured for this repository.")) {
            try await sandbox.service.runAction(
                GitActionRequest(action: .push, cwd: repo.path), writer: FakeSourceControlWriter(subject: ""), progress: { _ in }
            )
        }
    }

    @Test func committingWithNothingToCommitCreatesNoCommit() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        let head = try await repo.commit("initial", ["a.txt": "a\n"])

        let result = try await sandbox.service.runAction(
            GitActionRequest(action: .commit, cwd: repo.path, commitMessage: "Nothing"),
            writer: FakeSourceControlWriter(subject: ""), progress: { _ in }
        )

        #expect(result.title == "Done")
        #expect(result.detail == "No changes to commit.")
        #expect(try await repo.output("rev-parse", "HEAD") == head)
    }

    @Test func generatedFeatureBranchNamesAreSanitized() {
        #expect(LiveGitService.sanitizeFeatureBranchName("Fix Login: Redirect loop!") == "feature/fix-login-redirect-loop")
        #expect(LiveGitService.sanitizeFeatureBranchName("fix/oauth_token") == "fix/oauth_token")
        #expect(LiveGitService.sanitizeFeatureBranchName("  !!! ") == "feature/update")
        #expect(LiveGitService.normalizedSubject("Add search.\nsecond") == "Add search")
        #expect(LiveGitService.normalizedSubject("   ") == "Update project files")
    }
}
