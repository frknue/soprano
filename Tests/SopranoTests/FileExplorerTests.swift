import AppKit
import Testing
@testable import Soprano

@MainActor
struct FileExplorerTests {
    // MARK: - Listing

    @Test func listingPutsFoldersFirstInNaturalOrderAndHidesGitAndNodeModules() throws {
        try withTemporaryDirectory { root in
            for folder in ["src", ".git", "node_modules", "Docs"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            for file in ["file10.txt", "file2.txt", "B.md", "a.md", ".env"] {
                try Data().write(to: root.appendingPathComponent(file))
            }

            let names = try FileExplorerListing.entries(in: root).map(\.name)

            #expect(names == ["Docs", "src", ".env", "a.md", "B.md", "file2.txt", "file10.txt"])
        }
    }

    @Test func dotfileDetectionLooksAtEverySegment() {
        #expect(FileExplorerListing.isDotfile(relativePath: ".github/workflows/ci.yml"))
        #expect(FileExplorerListing.isDotfile(relativePath: "config/.env"))
        #expect(!FileExplorerListing.isDotfile(relativePath: "src/main.swift"))
        #expect(!FileExplorerListing.isDotfile(relativePath: "../outside"))
    }

    // MARK: - Git Decorations

    @Test func porcelainStatusMapsEveryRecordKindToItsPath() {
        let records = [
            "1 .M N... 100644 100644 100644 abc abc Sources/App/main.swift",
            "1 A. N... 000000 100644 100644 000 abc docs/new guide.md",
            "2 R. N... 100644 100644 100644 abc abc R100 Sources/Renamed.swift",
            "Sources/Old.swift",
            "u UU N... 100644 100644 100644 100644 a b c conflicted.txt",
            "? notes/todo.txt",
        ]
        let data = Data((records.joined(separator: "\0") + "\0").utf8)

        let snapshot = GitStatusSnapshot(entries: GitStatusSnapshot.parseStatus(data))

        #expect(snapshot.fileStatuses == [
            "Sources/App/main.swift": .modified,
            "docs/new guide.md": .added,
            "Sources/Renamed.swift": .renamed,
            "conflicted.txt": .modified,
            "notes/todo.txt": .untracked,
        ])
    }

    @Test func foldersShowTheirMostImportantChangeButNeverADeletion() {
        let snapshot = GitStatusSnapshot(entries: [
            ("src/a/added.swift", .added),
            ("src/a/modified.swift", .modified),
            ("src/b/gone.swift", .deleted),
            ("src/b/new.swift", .untracked),
            ("only-deleted/x.swift", .deleted),
        ])

        #expect(snapshot.status(forRelativePath: "src", isDirectory: true) == .modified)
        #expect(snapshot.status(forRelativePath: "src/a", isDirectory: true) == .modified)
        #expect(snapshot.status(forRelativePath: "src/b", isDirectory: true) == .untracked)
        #expect(snapshot.status(forRelativePath: "only-deleted", isDirectory: true) == nil)
    }

    @Test func aFileStagedAndModifiedAgainShowsTheHigherRankedStatus() {
        let snapshot = GitStatusSnapshot(entries: GitStatusSnapshot.parseStatus(
            Data("1 AM N... 000000 100644 100644 000 abc new.swift\0".utf8)
        ))

        #expect(snapshot.fileStatuses["new.swift"] == .modified)
    }

    @Test func ignoredFoldersCoverEverythingBeneathThem() {
        let ignored = GitStatusSnapshot.parseIgnored(Data(".build/\0debug.log\0".utf8))
        let snapshot = GitStatusSnapshot(ignoredPaths: ignored)

        #expect(snapshot.isIgnored(relativePath: ".build"))
        #expect(snapshot.isIgnored(relativePath: ".build/debug/Soprano"))
        #expect(snapshot.isIgnored(relativePath: "debug.log"))
        #expect(!snapshot.isIgnored(relativePath: ".buildozer"))
        #expect(!snapshot.isIgnored(relativePath: "Sources/debug.log"))
    }

    @Test func readingARealRepositoryReportsChangesAndIgnoredPaths() throws {
        guard GitStatusReader.executableURL != nil else { return }
        try withTemporaryDirectory { root in
            try git(["init", "-q"], in: root)
            try Data("ignored/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("ignored"),
                withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent("ignored/cache.bin"))
            try Data("one".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            try git(["add", "tracked.txt", ".gitignore"], in: root)
            try git(
                ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "init"],
                in: root
            )
            try Data("two".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            try Data().write(to: root.appendingPathComponent("fresh.txt"))

            let snapshot = GitStatusReader.snapshot(root: root.path)

            #expect(snapshot.fileStatuses == ["tracked.txt": .modified, "fresh.txt": .untracked])
            #expect(snapshot.isIgnored(relativePath: "ignored/cache.bin"))
            #expect(GitStatusReader.listFiles(root: root.path)?.sorted()
                == [".gitignore", "fresh.txt", "tracked.txt"])
        }
    }

    // MARK: - Name Filter

    @Test func everyFilterTokenMustAppearInThePathIgnoringCase() {
        let tokens = FileNameFilter.tokens("  explorer VIEW ")

        #expect(tokens == ["explorer", "view"])
        #expect(FileNameFilter.matches("Sources/Views/FileExplorerView.swift", tokens: tokens))
        #expect(!FileNameFilter.matches("Sources/Views/SidebarView.swift", tokens: tokens))
        #expect(FileNameFilter.matches("anything", tokens: []))
    }

    // MARK: - Names

    @Test func duplicatesCountUpPastExistingCopies() {
        let taken: Set<String> = ["notes copy.txt", "notes copy 2.txt"]

        #expect(FileExplorerNaming.duplicateName(for: "notes.txt") { taken.contains($0) } == "notes copy 3.txt")
        #expect(FileExplorerNaming.duplicateName(for: "Makefile") { _ in false } == "Makefile copy")
        #expect(FileExplorerNaming.duplicateName(for: ".env") { _ in false } == ".env copy")
    }

    @Test func renamingPreselectsTheNameBeforeTheLastDot() {
        #expect(FileExplorerNaming.stemRange(of: "archive.tar.gz") == NSRange(location: 0, length: 11))
        #expect(FileExplorerNaming.stemRange(of: "README") == NSRange(location: 0, length: 6))
        #expect(FileExplorerNaming.stemRange(of: ".gitignore") == NSRange(location: 0, length: 10))
    }

    // MARK: - Root

    @Test func aLinkedWorktreeAlsoWatchesItsGitDirectory() throws {
        try withTemporaryDirectory { root in
            let mainGit = root.appendingPathComponent("main/.git")
            let worktreeGit = mainGit.appendingPathComponent("worktrees/feature")
            try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
            try Data("ref: refs/heads/feature\n".utf8).write(to: worktreeGit.appendingPathComponent("HEAD"))
            try Data("ref: refs/heads/main\n".utf8).write(to: mainGit.appendingPathComponent("HEAD"))
            let worktree = root.appendingPathComponent("feature")
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try Data("gitdir: \(worktreeGit.path)\n".utf8).write(to: worktree.appendingPathComponent(".git"))

            let external = FileExplorerView.externalGitDirectory(forRoot: worktree.path)
            let expected = try #require(realpath(worktreeGit.path, nil))
            defer { free(expected) }
            #expect(external == String(cString: expected))
            #expect(FileExplorerView.externalGitDirectory(forRoot: root.appendingPathComponent("main").path) == nil)
        }
    }

    @Test func theRootIsTheWorkingTreeContainingThePanesDirectory() throws {
        try withTemporaryDirectory { root in
            let nested = root.appendingPathComponent("repo/Sources/App")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("repo/.git"),
                withIntermediateDirectories: true
            )
            let worktree = root.appendingPathComponent("repo/Sources/linked")
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try Data("gitdir: /elsewhere\n".utf8).write(to: worktree.appendingPathComponent(".git"))
            let plain = root.appendingPathComponent("plain/sub")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

            let repoRoot = FileExplorerView.explorerRoot(forWorkingDirectory: nested.path)
            #expect(repoRoot.path == root.appendingPathComponent("repo").standardizedFileURL.path)
            #expect(repoRoot.isGitRepository)

            let worktreeRoot = FileExplorerView.explorerRoot(
                forWorkingDirectory: worktree.appendingPathComponent(".").path
            )
            #expect(worktreeRoot.path == worktree.standardizedFileURL.path)

            let plainRoot = FileExplorerView.explorerRoot(forWorkingDirectory: plain.path)
            #expect(plainRoot.path == plain.standardizedFileURL.path)
            #expect(!plainRoot.isGitRepository)
        }
    }

    // MARK: - Operations

    @Test func creatingNeverReplacesAnExistingItem() throws {
        try withTemporaryDirectory { root in
            let operations = FileExplorerOperations()
            try Data("keep".utf8).write(to: root.appendingPathComponent("taken.txt"))

            #expect(throws: FileExplorerOperationError.alreadyExists("taken.txt")) {
                try operations.createFile(named: "taken.txt", in: root)
            }
            #expect(throws: FileExplorerOperationError.alreadyExists("taken.txt")) {
                try operations.createFolder(named: "taken.txt", in: root)
            }
            #expect(throws: FileExplorerOperationError.invalidName("a/b")) {
                try operations.createFile(named: "a/b", in: root)
            }
            #expect(try String(contentsOf: root.appendingPathComponent("taken.txt"), encoding: .utf8) == "keep")
        }
    }

    @Test func renamingRefusesToOverwriteButAllowsACaseOnlyChange() throws {
        try withTemporaryDirectory { root in
            let operations = FileExplorerOperations()
            let first = root.appendingPathComponent("first.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: root.appendingPathComponent("second.txt"))

            #expect(throws: FileExplorerOperationError.alreadyExists("second.txt")) {
                try operations.rename(first, to: "second.txt")
            }

            let renamed = try operations.rename(first, to: "First.txt")
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("First.txt"))
            #expect(try String(contentsOf: renamed, encoding: .utf8) == "first")
        }
    }

    @Test func movingAFolderTogetherWithItsOwnFileMovesItOnce() throws {
        try withTemporaryDirectory { root in
            let operations = FileExplorerOperations()
            let folder = root.appendingPathComponent("folder")
            let inner = folder.appendingPathComponent("inner.txt")
            let target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: inner)

            let moved = try operations.move([folder, inner], into: target)

            #expect(moved.map(\.target.path) == [target.appendingPathComponent("folder").path])
            #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("folder/inner.txt").path))
        }
    }

    @Test func undoingACaseOnlyRenameNeverReplacesAFileCreatedInTheMeantime() throws {
        try withCaseSensitiveVolume { root in
            let operations = FileExplorerOperations()
            var undoFailures: [Error] = []
            operations.onUndoFailure = { undoFailures.append($0) }
            let original = root.appendingPathComponent("foo")
            try Data("original".utf8).write(to: original)

            let renamed = try operations.rename(original, to: "Foo")
            // Another program claims the old spelling before the user hits Undo.
            try Data("newcomer".utf8).write(to: original)
            operations.undoManager.undo()

            #expect(undoFailures.map { $0 as? FileExplorerOperationError } == [.alreadyExists("foo")])
            #expect(try String(contentsOf: original, encoding: .utf8) == "newcomer")
            #expect(try String(contentsOf: renamed, encoding: .utf8) == "original")

            // The forward direction refuses the same collision.
            #expect(throws: FileExplorerOperationError.alreadyExists("foo")) {
                try operations.rename(renamed, to: "foo")
            }
            #expect(try String(contentsOf: original, encoding: .utf8) == "newcomer")
        }
    }

    @Test func aFolderCannotMoveIntoItself() throws {
        try withTemporaryDirectory { root in
            let operations = FileExplorerOperations()
            let folder = root.appendingPathComponent("folder")
            let child = folder.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

            #expect(throws: FileExplorerOperationError.moveIntoItself("folder")) {
                try operations.move([folder], into: child)
            }
            #expect(FileManager.default.fileExists(atPath: child.path))
        }
    }

    @Test func undoWalksMovesBackAndRedoReappliesThem() throws {
        try withTemporaryDirectory { root in
            let operations = FileExplorerOperations()
            let file = root.appendingPathComponent("note.txt")
            let folder = root.appendingPathComponent("archive")
            try Data("hello".utf8).write(to: file)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let moved = try operations.move([file], into: folder)
            #expect(moved.map(\.target) == [folder.appendingPathComponent("note.txt")])

            operations.undoManager.undo()
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("note.txt").path))

            operations.undoManager.redo()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8) == "hello")
        }
    }

    @Test func deletingMovesToTheTrashAndUndoRestoresTheFile() throws {
        try withTemporaryDirectory { root in
            let operations = FileExplorerOperations()
            let file = root.appendingPathComponent("draft.txt")
            try Data("draft".utf8).write(to: file)

            try operations.trash([file])
            #expect(!FileManager.default.fileExists(atPath: file.path))

            operations.undoManager.undo()
            #expect(try String(contentsOf: file, encoding: .utf8) == "draft")

            // Redo trashes it again; clean the Trash up afterwards.
            operations.undoManager.redo()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            operations.undoManager.undo()
            try FileManager.default.removeItem(at: file)
        }
    }

    @Test func dropsFromOutsideAreCopiedUnderAFreeName() throws {
        try withTemporaryDirectory { root in
            let operations = FileExplorerOperations()
            let outside = root.appendingPathComponent("outside")
            let inside = root.appendingPathComponent("inside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            let source = outside.appendingPathComponent("logo.png")
            try Data("png".utf8).write(to: source)
            try Data("old".utf8).write(to: inside.appendingPathComponent("logo.png"))

            let copied = try operations.copy([source], into: inside)

            #expect(copied == [inside.appendingPathComponent("logo copy.png")])
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: inside.appendingPathComponent("logo.png"), encoding: .utf8) == "old")
        }
    }

    // MARK: - Explorer View

    @Test func theExplorerShowsTheActivePanesProjectAndFollowsTheDisk() async throws {
        guard GitStatusReader.executableURL != nil else { return }
        // The temporary directory sits behind the /var → /private/var symlink,
        // so this also covers matching FSEvents' resolved paths to the root.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-explorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try Data().write(to: root.appendingPathComponent("Sources/app.swift"))
        try Data().write(to: root.appendingPathComponent("README.md"))

        let agentManager = AgentManager()
        let paneId = agentManager.activePaneId
        let tabId = try #require(agentManager.panes[paneId]?.activeTab?.id)
        agentManager.updateWorkingDirectory(
            paneId: paneId,
            tabId: tabId,
            to: root.appendingPathComponent("Sources").path
        )
        let suiteName = "soprano-explorer-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let explorer = FileExplorerView(
            agentManager: agentManager,
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            defaults: defaults
        )
        explorer.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        explorer.setActive(true)
        defer { explorer.setActive(false) }

        #expect(explorer.rootURL?.path == root.path)
        let outline = explorer.outlineView
        try await waitUntil { outline.numberOfRows == 2 && explorer.gitStatus != .empty }
        let names = (0..<outline.numberOfRows).compactMap {
            (outline.item(atRow: $0) as? FileExplorerNode)?.name
        }
        #expect(names == ["Sources", "README.md"])
        #expect(explorer.gitStatus.status(forRelativePath: "Sources", isDirectory: true) == .untracked)

        outline.expandItem(outline.item(atRow: 0))
        try await waitUntil { outline.numberOfRows == 3 }
        #expect((outline.item(atRow: 1) as? FileExplorerNode)?.relativePath == "Sources/app.swift")

        // Files created by other programs (an agent, git) appear on their own.
        try Data().write(to: root.appendingPathComponent("Sources/generated.swift"))
        try await waitUntil { outline.numberOfRows == 4 }
        #expect((outline.item(atRow: 2) as? FileExplorerNode)?.relativePath == "Sources/generated.swift")
    }

    // MARK: - Helpers

    /// Runs the body in a scratch case-sensitive APFS volume, where `foo`
    /// and `Foo` can be two different files (the default volume cannot).
    private func withCaseSensitiveVolume(_ body: (URL) throws -> Void) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let image = scratch.appendingPathComponent("volume")
        let mountPoint = scratch.appendingPathComponent("mnt")
        try hdiutil(["create", "-size", "8m", "-fs", "Case-sensitive APFS", "-volname", "SopranoCase",
                     "-type", "SPARSE", "-quiet", image.path])
        try hdiutil(["attach", "-nobrowse", "-noverify", "-quiet", "-mountpoint", mountPoint.path,
                     image.path + ".sparseimage"])
        defer { try? hdiutil(["detach", "-force", "-quiet", mountPoint.path]) }
        try body(mountPoint)
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "hdiutil \(arguments.first ?? "") failed")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-explorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = GitStatusReader.executableURL
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for the explorer")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
