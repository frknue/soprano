import AppKit
import Testing
@testable import SopranoAgentsCore

struct GitStatusTests {
    @Test func statusCountsAheadAndBehindAgainstTheUpstreamOnABareRemote() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let remote = try await sandbox.bareRemote()
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try await repo.git("remote", "add", "origin", remote.path)
        try await repo.git("push", "--quiet", "-u", "origin", "main")
        // Another clone pushes one commit; we make two local ones.
        try await sandbox.runner.run(["clone", "--quiet", remote.path, sandbox.url("other").path], in: sandbox.directory)
        let other = GitScript(root: sandbox.url("other"), runner: sandbox.runner)
        try await other.commit("theirs", ["b.txt": "b\n"])
        try await other.git("push", "--quiet")
        try await repo.commit("mine 1", ["c.txt": "c\n"])
        try await repo.commit("mine 2", ["d.txt": "d\n"])
        try await repo.git("fetch", "--quiet")

        let status = try await sandbox.service.status(cwd: repo.path)

        #expect(status.isRepository)
        #expect(status.branch == "main")
        #expect(status.isDefaultBranch)
        #expect(status.hasRemote)
        #expect(status.hasUpstream)
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
        #expect(status.files.isEmpty)
        #expect(status.pullRequest == nil)
    }

    @Test func statusListsTrackedAndUntrackedChangesWithLineCounts() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "1\n2\n3\n", ".gitignore": "*.log\n"])
        try await repo.git("switch", "--quiet", "-c", "feature/x")
        try repo.write("a.txt", "1\n3\n4\n5\n")
        try repo.write("new/file.txt", "x\ny\n")
        try repo.write("debug.log", "ignored\n")
        let before = try await repo.userState()

        let status = try await sandbox.service.status(cwd: repo.path)

        #expect(status.branch == "feature/x")
        #expect(!status.isDefaultBranch)
        #expect(!status.hasRemote)
        #expect(!status.hasUpstream)
        #expect(status.files == [
            ChangedFileStat(path: "a.txt", additions: 2, deletions: 1),
            ChangedFileStat(path: "new/file.txt", additions: 2, deletions: 0),
        ])
        #expect(try await repo.userState() == before)
    }

    @Test func aBranchWithoutUpstreamIsAheadByTheCommitsNoRemoteHas() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let remote = try await sandbox.bareRemote()
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try await repo.git("remote", "add", "origin", remote.path)
        try await repo.git("push", "--quiet", "origin", "main")
        try await repo.git("switch", "--quiet", "-c", "topic")
        try await repo.commit("topic work", ["t.txt": "t\n"])

        let status = try await sandbox.service.status(cwd: repo.path)

        #expect(status.hasRemote)
        #expect(!status.hasUpstream)
        #expect(status.ahead == 1)
        #expect(!status.isDefaultBranch)
    }

    @Test func statusOfAFolderOutsideGitIsNotARepository() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let folder = sandbox.url("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(try await sandbox.service.status(cwd: folder.path) == .notARepository)
        #expect(!(await sandbox.service.isRepository(folder.path)))
        #expect(await sandbox.service.repositoryRoot(folder.path) == nil)
    }

    @Test func theWorkingTreeDiffShowsTrackedEditsAndUntrackedFilesAsAdditions() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "old\n", ".gitignore": "*.log\n"])
        try repo.write("a.txt", "new\n")
        try repo.write("brand-new.txt", "hello\n")
        try repo.write("skip.log", "ignored\n")
        let before = try await repo.userState()

        let patch = try await sandbox.service.workingTreeDiff(cwd: repo.path, ignoreWhitespace: false)

        let files = DiffParser.parse(patch)
        #expect(files.map(\.path) == ["a.txt", "brand-new.txt"])
        #expect(files.last?.kind == .added)
        #expect(patch.contains("+hello"))
        #expect(try await repo.userState() == before)
    }

    @Test func pullRequestStatesFromGhMapDraftsAndClosedRequests() {
        func parse(_ state: String, draft: Bool) -> PullRequestInfo.State? {
            let json = #"{"number":12,"title":"Fix","url":"https://github.com/o/r/pull/12","state":"\#(state)","isDraft":\#(draft)}"#
            return GitHubCLI.parsePullRequest(Data(json.utf8))?.state
        }
        #expect(parse("OPEN", draft: false) == .open)
        #expect(parse("OPEN", draft: true) == .draft)
        #expect(parse("MERGED", draft: false) == .merged)
        #expect(parse("CLOSED", draft: false) == .closed)
        #expect(GitHubCLI.parsePullRequest(Data("no pull requests found".utf8)) == nil)
    }
}
