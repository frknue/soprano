import AppKit
import Testing
@testable import SopranoAgentsCore

struct GitCheckpointTests {
    private let ref0 = CheckpointRef.ref(threadID: "thread-1", ordinal: 0)
    private let ref1 = CheckpointRef.ref(threadID: "thread-1", ordinal: 1)

    @Test func capturingACheckpointLeavesStatusIndexAndHeadUntouchedAndIncludesUntrackedFiles() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["tracked.txt": "one\n", ".gitignore": "ignored.log\n"])
        try repo.write("tracked.txt", "one\ntwo\n")
        try repo.write("staged.txt", "staged\n")
        try await repo.git("add", "staged.txt")
        try repo.write("untracked.txt", "new\n")
        try repo.write("ignored.log", "noise\n")
        let before = try await repo.userState()

        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref0)

        #expect(try await repo.userState() == before)
        let files = try await repo.output("ls-tree", "-r", "--name-only", ref0)
        #expect(files.split(separator: "\n") == [".gitignore", "staged.txt", "tracked.txt", "untracked.txt"])
        #expect(try await repo.output("show", "\(ref0):tracked.txt") == "one\ntwo")
        #expect(try await repo.output("rev-parse", "\(ref0)^") == (try await repo.output("rev-parse", "HEAD")))
        #expect(await sandbox.service.checkpointExists(cwd: repo.path, ref: ref0))
        #expect(!(await sandbox.service.checkpointExists(cwd: repo.path, ref: ref1)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: repo.root.appendingPathComponent(".git").path)
            .filter { $0.hasPrefix("soprano-agents-index") }
        #expect(leftovers.isEmpty)
    }

    @Test func aRepositoryWithoutCommitsGetsAParentlessCheckpoint() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try repo.write("draft.md", "hello\n")
        let before = try await repo.userState()

        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref0)

        #expect(try await repo.userState() == before)
        #expect(try await repo.output("ls-tree", "-r", "--name-only", ref0) == "draft.md")
        let parents = try await repo.output("log", "-1", "--format=%P", ref0)
        #expect(parents.isEmpty)
    }

    @Test func anUntrackedNestedRepositoryWithoutCommitsDoesNotBreakCapture() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        let nested = try await sandbox.repository("repo/scratch")
        try nested.write("inner.txt", "inner\n")
        try repo.write("b.txt", "b\n")

        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref0)

        #expect(try await repo.output("ls-tree", "-r", "--name-only", ref0) == "a.txt\nb.txt")
    }

    @Test func theDiffBetweenTwoCheckpointsShowsExactlyTheAgentsEdits() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["keep.txt": "same\n", "edit.txt": "a\nb\n", "old-name.txt": "rename me\nline 2\nline 3\n"])
        // Pre-existing uncommitted work the agent did not do.
        try repo.write("user.txt", "user's own change\n")
        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref0)

        try repo.write("edit.txt", "a\nB\nc\n")
        try repo.write("added.txt", "fresh\n")
        try repo.write("image.bin", Data([0, 1, 2, 0, 255]))
        try await repo.git("mv", "old-name.txt", "new-name.txt")
        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref1)

        let files = try await sandbox.service.changedFiles(cwd: repo.path, fromRef: ref0, toRef: ref1)
        #expect(files == [
            ChangedFileStat(path: "added.txt", additions: 1, deletions: 0),
            ChangedFileStat(path: "edit.txt", additions: 2, deletions: 1),
            ChangedFileStat(path: "image.bin", additions: 0, deletions: 0),
            ChangedFileStat(path: "new-name.txt", additions: 0, deletions: 0),
        ])

        let patch = try await sandbox.service.diff(cwd: repo.path, fromRef: ref0, toRef: ref1, ignoreWhitespace: false)
        let parsed = DiffParser.parse(patch)
        #expect(parsed.map(\.path) == ["added.txt", "edit.txt", "image.bin", "new-name.txt"])
        #expect(parsed.first { $0.path == "new-name.txt" }?.kind == .renamed)
        #expect(!patch.contains("user.txt"))
        #expect(!patch.contains("keep.txt"))
    }

    @Test func ignoringWhitespaceDropsWhitespaceOnlyEdits() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["code.swift": "let a = 1\nlet b = 2\n"])
        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref0)
        try repo.write("code.swift", "let a =  1\nlet b = 3\n")
        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref1)

        let strict = try await sandbox.service.diff(cwd: repo.path, fromRef: ref0, toRef: ref1, ignoreWhitespace: false)
        let lenient = try await sandbox.service.diff(cwd: repo.path, fromRef: ref0, toRef: ref1, ignoreWhitespace: true)
        #expect(strict.contains("+let a =  1"))
        #expect(!lenient.contains("+let a =  1"))
        #expect(lenient.contains("+let b = 3"))
    }

    @Test func restoringACheckpointBringsBackOldContentAndRemovesNewFilesButKeepsHead() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["edit.txt": "original\n", "doomed.txt": "keep me\n", ".gitignore": "*.log\n"])
        try repo.write("untracked-before.txt", "was untracked\n")
        let head = try await repo.output("rev-parse", "HEAD")
        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref0)
        let before = try await repo.userState()

        try repo.write("edit.txt", "agent edit\n")
        try repo.delete("doomed.txt")
        try repo.write("created/by/agent.txt", "new\n")
        try repo.write("build.log", "ignored output\n")
        try repo.delete("untracked-before.txt")
        try await repo.git("add", "-A")

        try await sandbox.service.restoreCheckpoint(cwd: repo.path, ref: ref0)

        #expect(try repo.read("edit.txt") == "original\n")
        #expect(try repo.read("doomed.txt") == "keep me\n")
        #expect(try repo.read("untracked-before.txt") == "was untracked\n")
        #expect(!repo.exists("created"))
        #expect(repo.exists("build.log"))
        #expect(try await repo.output("rev-parse", "HEAD") == head)
        #expect(try await repo.userState() == before)
    }

    @Test func deletingRefsRemovesOnlyThoseCheckpoints() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref0)
        try await sandbox.service.captureCheckpoint(cwd: repo.path, ref: ref1)

        try await sandbox.service.deleteRefs(cwd: repo.path, refs: [ref1, CheckpointRef.ref(threadID: "thread-1", ordinal: 7)])

        #expect(await sandbox.service.checkpointExists(cwd: repo.path, ref: ref0))
        #expect(!(await sandbox.service.checkpointExists(cwd: repo.path, ref: ref1)))
    }

    @Test func oversizedPatchesAreCutOnACharacterBoundaryAndMarkedTruncated() {
        let text = "aé" + String(repeating: "x", count: 10)
        // Limit 2 falls inside "é" (2 bytes: 0xC3 0xA9).
        let capped = LiveGitService.cappedPatch(Data(text.utf8), limit: 2)
        #expect(capped == "a\n\n[truncated]")
        #expect(LiveGitService.cappedPatch(Data("short".utf8), limit: 10) == "short")
    }
}
