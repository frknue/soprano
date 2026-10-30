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
}
