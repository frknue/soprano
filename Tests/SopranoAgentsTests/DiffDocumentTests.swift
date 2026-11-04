import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct DiffDocumentTests {
    private func file(kind: ChangeKind = .modified, binary: Bool = false, oldMode: String? = nil, newMode: String? = nil,
                      hunks: [DiffHunk] = []) -> FileDiff {
        FileDiff(
            oldPath: "a.txt", newPath: kind == .renamed ? "b.txt" : "a.txt", kind: kind, isBinary: binary,
            oldMode: oldMode, newMode: newMode, headerLines: [], hunks: hunks
        )
    }

    private func hunk(start: Int, lines: Int) -> DiffHunk {
        DiffHunk(
            oldStart: start, oldCount: lines, newStart: start, newCount: lines, section: "",
            lines: (0..<lines).map { DiffLine(kind: .added, text: "x\($0)", oldNumber: nil, newNumber: start + $0) }
        )
    }

    @Test func filesWithoutTextHunksExplainThemselvesInOneLine() {
        #expect(DiffDocument.build(files: [], title: "a.txt").notice == "No changes.")
        #expect(DiffDocument.build(files: [file(binary: true)], title: "a.txt").notice == "Binary file. There is no text diff to show.")
        #expect(DiffDocument.build(files: [file(kind: .renamed)], title: "b.txt").notice
            == "Renamed without content changes: a.txt → b.txt.")
        #expect(DiffDocument.build(files: [file(oldMode: "100644", newMode: "100755")], title: "a.txt").notice
            == "File mode changed from 100644 to 100755.")
        #expect(DiffDocument.build(files: [file(kind: .added)], title: "a.txt").notice == "Empty file added.")
    }

    @Test func rowsListEachHunkHeaderFollowedByItsLines() {
        let document = DiffDocument.build(files: [file(hunks: [hunk(start: 1, lines: 2), hunk(start: 40, lines: 1)])], title: "a.txt")
        #expect(document.rows == [.hunk(0), .line(hunk: 0, line: 0), .line(hunk: 0, line: 1), .hunk(1), .line(hunk: 1, line: 0)])
        #expect(document.hunkRows == [0, 3])
        #expect(document.additions == 3)
        #expect(document.hunk(ofRow: 2) == 0)
        #expect(document.hunk(ofRow: 4) == 1)
        #expect(document.notice == nil)
    }

    @Test func largeDiffsStopAtTheLineLimitWithANotice() {
        let hunks = [hunk(start: 1, lines: 6), hunk(start: 100, lines: 6)]
        let document = DiffDocument.build(files: [file(hunks: hunks)], title: "a.txt", lineLimit: 8)
        #expect(document.isTruncated)
        #expect(document.hunkCount == 2)
        #expect(document.rows.filter { if case .line = $0 { true } else { false } }.count == 8)
        #expect(document.rows.last == .notice("Large diff: showing the first 8 of 12 lines."))
    }

    @Test func theTitledFileIsPickedFromAWholeCommitDiff() {
        let other = FileDiff(oldPath: "z.txt", newPath: "z.txt", kind: .modified, isBinary: false, headerLines: [], hunks: [])
        let document = DiffDocument.build(files: [other, file(kind: .renamed)], title: "b.txt")
        #expect(document.file?.newPath == "b.txt")
    }

    /// `git diff -M` output: a rename with edits, a binary file, a file without a trailing
    /// newline on both sides, and a pure rename.
    private static let realWorldPatch = """
    diff --git a/old/name.txt b/new/name.txt
    similarity index 80%
    rename from old/name.txt
    rename to new/name.txt
    index 1111111..2222222 100644
    --- a/old/name.txt
    +++ b/new/name.txt
    @@ -1,4 +1,4 @@
     keep
    -let value = 1
    -gone
    +let value = 2
    +added
     tail
    diff --git a/logo.png b/logo.png
    index 3333333..4444444 100644
    Binary files a/logo.png and b/logo.png differ
    diff --git a/end.txt b/end.txt
    index 5555555..6666666 100644
    --- a/end.txt
    +++ b/end.txt
    @@ -1,2 +1,2 @@
     first
    -last
    \\ No newline at end of file
    +last line
    \\ No newline at end of file
    diff --git a/moved.txt b/renamed.txt
    similarity index 100%
    rename from moved.txt
    rename to renamed.txt

    """

    @Test func aRenameWithEditsPairsChangeBlocksSideBySide() {
        let entries = DiffFileEntry.prepare(patch: Self.realWorldPatch)
        #expect(entries.map(\.path) == ["new/name.txt", "logo.png", "end.txt", "renamed.txt"])
        let rename = entries[0].document
        #expect(rename.file?.kind == .renamed)
        #expect(rename.file?.oldPath == "old/name.txt")
        #expect(rename.splitRows == [
            .hunk(0), .pair(hunk: 0, old: 0, new: 0), .pair(hunk: 0, old: 1, new: 3), .pair(hunk: 0, old: 2, new: 4),
            .pair(hunk: 0, old: 5, new: 5),
        ])
        #expect(rename.additions == 2)
        #expect(rename.deletions == 2)
    }

    @Test func onlyTheChangedWordsOfASimilarPairAreEmphasized() {
        let rename = DiffFileEntry.prepare(patch: Self.realWorldPatch)[0]
        #expect(rename.document.changedRange(hunk: 0, line: 1) == NSRange(location: 12, length: 1))
        #expect(rename.document.changedRange(hunk: 0, line: 3) == NSRange(location: 12, length: 1))
        // "gone" and "added" share nothing: no emphasis on either.
        #expect(rename.document.changedRange(hunk: 0, line: 2) == nil)
        #expect(DiffSurfaceViewController.emphasis(in: rename, hunk: 0, line: 1) == NSRange(location: 12, length: 1))
    }

    @Test func linesThatShareOnlyIndentationAreNotEmphasized() {
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,1 @@
        -        router.replace(with: target)
        +        await sessionStore.persist(session)

        """
        let entry = DiffFileEntry.prepare(patch: patch)[0]
        #expect(entry.document.changedRange(hunk: 0, line: 0) != nil)
        #expect(DiffSurfaceViewController.emphasis(in: entry, hunk: 0, line: 0) == nil)
        #expect(DiffSurfaceViewController.emphasis(in: entry, hunk: 0, line: 1) == nil)
    }

    @Test func binaryFilesAndPureRenamesExplainThemselves() {
        let entries = DiffFileEntry.prepare(patch: Self.realWorldPatch)
        #expect(entries[1].document.notice == "Binary file. There is no text diff to show.")
        #expect(entries[3].document.notice == "Renamed without content changes: moved.txt → renamed.txt.")
        #expect(entries[1].highlights.isEmpty)
    }

    @Test func aMissingNewlineMarkerStaysBesideTheLineItFollows() {
        let end = DiffFileEntry.prepare(patch: Self.realWorldPatch)[2].document
        let kinds = end.file?.hunks[0].lines.map(\.kind)
        #expect(kinds == [.context, .removed, .noNewlineMarker, .added, .noNewlineMarker])
        #expect(end.splitRows == [
            .hunk(0), .pair(hunk: 0, old: 0, new: 0), .pair(hunk: 0, old: 1, new: 3), .pair(hunk: 0, old: 2, new: 4),
        ])
        #expect(end.rows.count == 6)
    }
}
