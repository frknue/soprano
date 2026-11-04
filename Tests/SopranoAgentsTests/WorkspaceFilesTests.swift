import AppKit
import Testing
@testable import SopranoAgentsCore

struct WorkspaceFilesTests {
    /// A plain (non-git) folder inside a sandbox, with `files` written into it.
    private func folder(_ sandbox: GitSandbox, _ files: [String: Data]) throws -> URL {
        let root = sandbox.url("plain")
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    @Test func aRepositoryListsTrackedAndUntrackedFilesButNotIgnoredOnes() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("init", [".gitignore": "build/\n*.log\n", "Sources/App.swift": "app"])
        try repo.write("Sources/New File ü.swift", "new")
        try repo.write("build/output.o", "ignored")
        try repo.write("debug.log", "ignored")

        let files = try await LiveWorkspaceFileService(runner: sandbox.runner).listFiles(root: repo.path)

        #expect(files == [".gitignore", "Sources/App.swift", "Sources/New File ü.swift"])
    }

    @Test func aTrackedFileDeletedFromDiskIsNotListed() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("init", ["kept.txt": "a", "gone.txt": "b"])
        try repo.delete("gone.txt")

        let files = try await LiveWorkspaceFileService(runner: sandbox.runner).listFiles(root: repo.path)

        #expect(files == ["kept.txt"])
    }

    @Test func aFileWithAMergeConflictIsListedOnce() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository()
        try await repo.commit("base", ["shared.txt": "base\n"])
        try await repo.git("checkout", "--quiet", "-b", "other")
        try await repo.commit("other", ["shared.txt": "other\n"])
        try await repo.git("checkout", "--quiet", "main")
        try await repo.commit("main", ["shared.txt": "main\n"])
        _ = try await sandbox.runner.run(["merge", "--quiet", "other"], in: repo.root, acceptedExitCodes: [1])

        let files = try await LiveWorkspaceFileService(runner: sandbox.runner).listFiles(root: repo.path)

        #expect(files == ["shared.txt"])
    }

    @Test func aFolderOutsideGitIsWalkedSkippingGitAndDependencyFolders() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let root = try folder(sandbox, [
            ".env": Data("A=1".utf8),
            "src/main.js": Data("x".utf8),
            ".git/config": Data("not a repository".utf8),
            "node_modules/left-pad/index.js": Data("x".utf8),
            ".build/debug/App": Data("x".utf8),
        ])

        let files = try await LiveWorkspaceFileService(runner: sandbox.runner).listFiles(root: root.path)

        #expect(files == [".env", "src/main.js"])
    }

    @Test func readingRejectsPathsThatEscapeTheWorkspace() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let root = try folder(sandbox, ["inside.txt": Data("inside".utf8)])
        try Data("secret".utf8).write(to: sandbox.directory.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("escape").path,
            withDestinationPath: sandbox.directory.appendingPathComponent("secret.txt").path
        )
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "inside.txt")
        let service = LiveWorkspaceFileService(runner: sandbox.runner)

        for path in ["../secret.txt", "sub/../../secret.txt", "escape", sandbox.directory.appendingPathComponent("secret.txt").path] {
            await #expect(throws: EngineError.self, "\(path)") {
                _ = try await service.readFile(root: root.path, relativePath: path)
            }
        }
        #expect(try await service.readFile(root: root.path, relativePath: "alias") == .text("inside"))
        #expect(try await service.readFile(root: root.path, relativePath: "sub/../inside.txt") == .text("inside"))
    }

    @Test func readingClassifiesBinaryOversizedAndImageFiles() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let large = Data(repeating: UInt8(ascii: "a"), count: WorkspaceFileLimits.maximumTextBytes + 1)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let root = try folder(sandbox, [
            "notes.md": Data("# Hi ✓\n".utf8),
            "blob.bin": Data([0x41, 0x00, 0x42]),
            "latin1.txt": Data([0x63, 0x61, 0x66, 0xE9]),
            "huge.log": large,
            "Logo.PNG": png,
        ])
        let service = LiveWorkspaceFileService(runner: sandbox.runner)

        #expect(try await service.readFile(root: root.path, relativePath: "notes.md") == .text("# Hi ✓\n"))
        #expect(try await service.readFile(root: root.path, relativePath: "blob.bin") == .binary(byteCount: 3))
        #expect(try await service.readFile(root: root.path, relativePath: "latin1.txt") == .binary(byteCount: 4))
        #expect(try await service.readFile(root: root.path, relativePath: "huge.log") == .tooLarge(byteCount: large.count))
        #expect(try await service.readFile(root: root.path, relativePath: "Logo.PNG") == .image(png))
    }

    @MainActor
    @Test func theEngineResolvesThreadPathsInsideItsWorkingDirectoryOnly() async throws {
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [:],
            git: RecordingGit(),
            store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory(),
            files: LiveWorkspaceFileService(runner: nil)
        ))
        let threadID = EngineHarness.idleThread(in: engine)
        let workspace = WorkspaceRef.thread(threadID)
        let root = try #require(engine.thread(threadID).map { engine.workingDirectory(for: $0) })
        try Data("hello".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("hello.txt"))

        #expect(engine.workspaceFileURL(workspace, path: "hello.txt")?.path == WorkspaceFilePath.canonical(root) + "/hello.txt")
        #expect(engine.workspaceFileURL(workspace, path: "../hello.txt") == nil)
        #expect(engine.workspaceFileURL(.thread("missing"), path: "hello.txt") == nil)
        #expect(try await engine.workspaceFiles(workspace) == ["hello.txt"])
        #expect(try await engine.readWorkspaceFile(workspace, path: "hello.txt") == .text("hello"))
        await #expect(throws: EngineError.self) {
            _ = try await engine.readWorkspaceFile(workspace, path: "../hello.txt")
        }
    }
}
