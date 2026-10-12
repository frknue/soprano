import AppKit
import Testing
@testable import Soprano

@MainActor
struct GitChangesTests {
    // MARK: - Status

    @Test func statusSplitsEachFileIntoItsStagedAndUnstagedChangesInSectionOrder() {
        let status = [
            "# branch.oid 0123456789abcdef",
            "# branch.head feature/diff",
            "1 MM N... 100644 100644 100644 aaa bbb src/both.swift",
            "1 .D N... 100644 100644 000000 aaa aaa gone.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 docs/new name.md",
            "docs/old name.md",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc merge.txt",
            "? notes 10.txt",
            "? notes 9.txt",
            "1 A. N... 000000 100644 100644 000 bbb added.swift",
        ].joined(separator: "\0") + "\0"

        let list = GitChangeList.parse(status: Data(status.utf8))

        #expect(list.branch == "feature/diff")
        #expect(list.changes.map { "\($0.area.title): \($0.letter) \($0.path)" } == [
            "Conflicts: ! merge.txt",
            "Changes: D gone.txt",
            "Changes: M src/both.swift",
            "Staged Changes: A added.swift",
            "Staged Changes: R docs/new name.md",
            "Staged Changes: M src/both.swift",
            "Untracked Files: U notes 9.txt",
            "Untracked Files: U notes 10.txt",
        ])
        #expect(list.changes.first { $0.status == .renamed }?.originalPath == "docs/old name.md")
        #expect(list.changes.first { $0.path == "src/both.swift" }?.directory == "src")
    }

    @Test func aDetachedHeadIsNamedByItsShortCommitAndAnUnbornBranchByItsName() {
        let detached = GitChangeList.parse(status: Data(
            "# branch.oid 0123456789abcdef\0# branch.head (detached)\0".utf8
        ))
        let unborn = GitChangeList.parse(status: Data(
            "# branch.oid (initial)\0# branch.head main\0".utf8
        ))

        #expect(detached.branch == "0123456")
        #expect(unborn.branch == "main")
    }

    @Test func numstatCountsLandOnTheirAreaAndBinaryFilesHaveNone() {
        var list = GitChangeList(branch: nil, changes: [
            GitChange(path: "a.txt", status: .modified, area: .staged),
            GitChange(path: "a.txt", status: .modified, area: .unstaged),
            GitChange(path: "logo.png", status: .modified, area: .unstaged),
        ])

        list.applyLineCounts(
            GitChangeList.parseNumstat(Data("3\t1\ta.txt\0-\t-\tlogo.png\0".utf8)),
            in: .unstaged
        )

        #expect(list.changes[0].linesAdded == nil)
        #expect(list.changes[1].linesAdded == 3)
        #expect(list.changes[1].linesDeleted == 1)
        #expect(list.changes[2].linesAdded == nil)
        #expect(list.changes[2].linesDeleted == nil)
    }

    @Test func untrackedLineCountsIncludeAnUnterminatedLastLineAndSkipBinaryData() {
        #expect(GitChangeList.lineCount(of: Data()) == 0)
        #expect(GitChangeList.lineCount(of: Data("a\nb\n".utf8)) == 2)
        #expect(GitChangeList.lineCount(of: Data("a\nb".utf8)) == 2)
        #expect(GitChangeList.lineCount(of: Data([0x61, 0x00, 0x0A])) == nil)
    }

    // MARK: - Patch

    @Test func aFullContextPatchBecomesTheWholeFileWithNumberedChanges() {
        let patch = """
        diff --git a/f.txt b/f.txt
        index de98044..f8f7a32 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,4 @@
         a
        -b\r
        +B\r
         c
        +d
        \\ No newline at end of file

        """

        guard case .text(let lines) = GitFileDiff.parse(patch: Data(patch.utf8)) else {
            Issue.record("Expected a text diff")
            return
        }

        #expect(lines == [
            GitDiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "a"),
            GitDiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "b"),
            GitDiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "B"),
            GitDiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "c"),
            GitDiffLine(kind: .added, oldNumber: nil, newNumber: 4, text: "d"),
        ])
    }

    @Test func patchesWithoutLineChangesAreBinaryOrUnchanged() {
        let binary = "diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n"
        let modeOnly = "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n"

        #expect(GitFileDiff.parse(patch: Data(binary.utf8)) == .binary)
        #expect(GitFileDiff.parse(patch: Data(modeOnly.utf8)) == .noChanges)
        #expect(GitFileDiff.parse(patch: Data()) == .noChanges)
    }

    @Test func aBlankContextLineWithoutItsSpaceStaysALine() {
        // `diff.suppressBlankEmpty` drops the space before empty context lines.
        let patch = "@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n"

        guard case .text(let lines) = GitFileDiff.parse(patch: Data(patch.utf8)) else {
            Issue.record("Expected a text diff")
            return
        }

        #expect(lines.map(\.kind) == [.context, .context, .removed, .added])
        #expect(lines[1] == GitDiffLine(kind: .context, oldNumber: 2, newNumber: 2, text: ""))
        #expect(lines[3].newNumber == 3)
    }

    // MARK: - Layout

    @Test func inlineRowsListEachChangesRemovalsAboveItsAdditions() {
        let lines = sampleLines()

        let layout = GitDiffLayout.inline(lines)

        #expect(layout.rows.map(\.kind) == [.context, .removed, .removed, .added, .context, .added])
        #expect(layout.rows.map(\.lineIndex) == [0, 1, 2, 3, 4, 5])
        #expect(layout.changeStarts == [1, 5])
        // "let x = 1" became "let x = 2": only the value differs.
        #expect(layout.rows[1].changedRange == NSRange(location: 8, length: 1))
        #expect(layout.rows[3].changedRange == NSRange(location: 8, length: 1))
        #expect(layout.rows[2].changedRange == nil)
    }

    @Test func sideBySideRowsFaceEachOtherAndPadTheShorterSide() {
        let lines = sampleLines()

        let (old, new) = GitDiffLayout.sideBySide(lines)

        #expect(old.rows.count == new.rows.count)
        #expect(old.rows.map(\.kind) == [.context, .removed, .removed, .context, .filler])
        #expect(new.rows.map(\.kind) == [.context, .added, .filler, .context, .added])
        #expect(old.rows.map(\.lineIndex) == [0, 1, 2, 4, nil])
        #expect(new.rows.map(\.lineIndex) == [0, 3, nil, 4, 5])
        #expect(old.changeStarts == [1, 4])
        #expect(new.changeStarts == old.changeStarts)
        #expect(new.rows[1].changedRange == NSRange(location: 8, length: 1))
    }

    @Test func changedRangesNeverSplitASurrogatePairAndIgnoreUnrelatedLines() {
        let ranges = GitDiffLayout.changedRanges(old: "a😀b", new: "a😃b")

        #expect(ranges?.old == NSRange(location: 1, length: 2))
        #expect(ranges?.new == NSRange(location: 1, length: 2))
        #expect(GitDiffLayout.changedRanges(old: "abc", new: "xyz") == nil)
        #expect(GitDiffLayout.changedRanges(old: "abc", new: "abXc")?.old == NSRange(location: 2, length: 0))
    }

    @Test func highlightsColorEachSideAsItsOwnFileAndSplitTokensPerLine() throws {
        let lines = [
            GitDiffLine(kind: .removed, oldNumber: 1, newNumber: nil, text: "/* old"),
            GitDiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "let a = 1"),
            GitDiffLine(kind: .context, oldNumber: 2, newNumber: 2, text: "end */"),
        ]
        let language = try #require(CodeLanguage.forFile(named: "main.swift"))

        let highlights = GitDiffHighlights.compute(lines, language: language)

        // On the old side the comment runs across both of its lines.
        #expect(highlights.old[0] == [SyntaxToken(range: NSRange(location: 0, length: 6), kind: .comment)])
        #expect(highlights.old[2] == [SyntaxToken(range: NSRange(location: 0, length: 6), kind: .comment)])
        #expect(highlights.old[1].isEmpty)
        #expect(highlights.new[0].isEmpty)
        #expect(highlights.new[1].first?.kind == .keyword)
        #expect(!highlights.new[2].contains { $0.kind == .comment })
    }

    // MARK: - Real Repository

    @Test func readingARealRepositoryListsChangesWithCountsAndWholeFileDiffs() throws {
        guard GitStatusReader.executableURL != nil else { return }
        try withRepository { root in
            try write("one\ntwo\nthree\n", to: "app.swift", in: root)
            try write("x\n", to: "[id].tsx", in: root)
            try git(["add", "."], in: root)
            try commit(in: root)
            try write("one\n2\nthree\n", to: "app.swift", in: root)
            try git(["add", "app.swift"], in: root)
            try write("one\n2\nthree\nfour\n", to: "app.swift", in: root)
            try write("y\n", to: "[id].tsx", in: root)
            try write("new\nfile", to: "fresh.txt", in: root)

            let list = try #require(GitStatusReader.changes(root: root.path))

            #expect(list.changes.map { "\($0.area.title) \($0.path) +\($0.linesAdded ?? -1) -\($0.linesDeleted ?? -1)" } == [
                "Changes [id].tsx +1 -1",
                "Changes app.swift +1 -0",
                "Staged Changes app.swift +1 -1",
                "Untracked Files fresh.txt +2 -0",
            ])

            let staged = GitStatusReader.diff(root: root.path, relativePath: "app.swift", staged: true)
            #expect(staged == .text([
                GitDiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "one"),
                GitDiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "two"),
                GitDiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "2"),
                GitDiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "three"),
            ]))
            let unstaged = GitStatusReader.diff(root: root.path, relativePath: "app.swift", staged: false)
            guard case .text(let unstagedLines) = unstaged else {
                Issue.record("Expected the working-tree diff")
                return
            }
            #expect(unstagedLines.map(\.kind) == [.context, .context, .context, .added])
            #expect(unstagedLines.last?.text == "four")

            let bracketed = GitStatusReader.diff(root: root.path, relativePath: "[id].tsx", staged: false)
            #expect(bracketed == .text([
                GitDiffLine(kind: .removed, oldNumber: 1, newNumber: nil, text: "x"),
                GitDiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "y"),
            ]))
            let untracked = GitStatusReader.diff(root: root.path, relativePath: "fresh.txt", staged: false)
            #expect(untracked == .text([
                GitDiffLine(kind: .added, oldNumber: nil, newNumber: 1, text: "new"),
                GitDiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "file"),
            ]))
            #expect(GitStatusReader.diff(root: root.path, relativePath: "[id].tsx", staged: true) == .noChanges)
        }
    }

    // MARK: - Tabs

    @Test func stagedAndWorkingTreeDiffsAreSeparateTabsAndShareThePreviewSlotWithFiles() throws {
        let manager = AgentManager()
        let file = URL(fileURLWithPath: "/tmp/project/app.swift")

        let preview = try #require(manager.openDiff(fileURL: file, staged: false, preview: true))
        let paneId = preview.paneId
        #expect(titles(manager, paneId) == ["app.swift (diff)"])
        #expect(manager.panes[paneId]?.activeTab?.isFilePreview == true)

        // The next preview, of any kind, takes the preview's place.
        _ = try #require(manager.openEditor(fileURL: file, preview: true))
        #expect(titles(manager, paneId) == ["app.swift"])

        let staged = try #require(manager.openDiff(fileURL: file, staged: true, preview: false))
        let unstaged = try #require(manager.openDiff(fileURL: file, staged: false, preview: false))
        #expect(staged.paneId == paneId)
        #expect(unstaged.paneId == paneId)
        #expect(staged.tabId != unstaged.tabId)
        #expect(Set(titles(manager, paneId)) == ["app.swift", "app.swift (staged diff)", "app.swift (diff)"])

        let reopened = try #require(manager.openDiff(fileURL: file, staged: true, preview: true))
        #expect(reopened.tabId == staged.tabId)
        #expect(manager.panes[paneId]?.activeTab?.id == staged.tabId)
    }

    @Test func movingAFileKeepsItsDiffTabsTitledAsDiffs() throws {
        let manager = AgentManager()
        let target = try #require(manager.openDiff(
            fileURL: URL(fileURLWithPath: "/tmp/project/old.swift"),
            staged: true,
            preview: false
        ))

        manager.relocateFileTabs(
            from: URL(fileURLWithPath: "/tmp/project/old.swift"),
            to: URL(fileURLWithPath: "/tmp/project/new.swift")
        )

        let tab = try #require(manager.panes[target.paneId]?.tabs.first { $0.id == target.tabId })
        #expect(tab.title == "new.swift (staged diff)")
        #expect(tab.url == "file:///tmp/project/new.swift")
    }

    // MARK: - Helpers

    /// Line 0 context, a two-line change replaced by one line, context, an addition.
    private func sampleLines() -> [GitDiffLine] {
        [
            GitDiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "import A"),
            GitDiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "let x = 1"),
            GitDiffLine(kind: .removed, oldNumber: 3, newNumber: nil, text: "let y = 3"),
            GitDiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "let x = 2"),
            GitDiffLine(kind: .context, oldNumber: 4, newNumber: 3, text: "print(x)"),
            GitDiffLine(kind: .added, oldNumber: nil, newNumber: 4, text: "print(y)"),
        ]
    }

    private func titles(_ manager: AgentManager, _ paneId: String) -> [String] {
        manager.panes[paneId]?.tabs.map(\.title) ?? []
    }

    private func withRepository(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-git-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try body(root)
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func commit(in root: URL) throws {
        try git(
            ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "init"],
            in: root
        )
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
}
