import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct DiffListTests {
    private let patch = """
    diff --git a/Sources/Auth/Login.swift b/Sources/Auth/Login.swift
    --- a/Sources/Auth/Login.swift
    +++ b/Sources/Auth/Login.swift
    @@ -10,2 +10,2 @@ final class Login {
    -    let a = 1
    +    let a = 2
         let b = 3
    @@ -40,1 +40,2 @@
         done()
    +    log()
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1,1 +1,1 @@
    -Old
    +New

    """

    @Test func everyFileGetsAHeaderAndCollapsedFilesShowNothingElse() {
        let entries = DiffFileEntry.prepare(patch: patch)
        let list = DiffList.build(entries: entries, collapsed: [0], layout: .unified)
        #expect(list.rows == [
            .fileHeader(file: 0),
            .fileHeader(file: 1), .hunk(file: 1, hunk: 0), .line(file: 1, hunk: 0, line: 0), .line(file: 1, hunk: 0, line: 1),
            .fileEnd(file: 1),
        ])
        #expect(list.fileRows == [0, 1])
    }

    @Test func theSplitLayoutListsPairsInsteadOfLines() {
        let entries = DiffFileEntry.prepare(patch: patch)
        let list = DiffList.build(entries: entries, collapsed: [1], layout: .split)
        #expect(Array(list.rows.prefix(4)) == [
            .fileHeader(file: 0), .hunk(file: 0, hunk: 0), .pair(file: 0, hunk: 0, old: 0, new: 1), .pair(file: 0, hunk: 0, old: 2, new: 2),
        ])
        #expect(list.rows.contains(.pair(file: 0, hunk: 1, old: nil, new: 1)))
        #expect(list.rows.last == .fileHeader(file: 1))
    }

    @Test func hunkSeparatorsCountTheLinesTheDiffSkips() {
        let file = DiffFileEntry.prepare(patch: patch)[0].file
        #expect(DiffList.hiddenLines(before: 0, in: file) == 9)
        #expect(DiffList.hiddenLines(before: 1, in: file) == 28)
    }

    @Test func theFileTreeJoinsSingleChildDirectoriesAndListsDirectoriesFirst() {
        let items = DiffTreeItem.build(paths: ["Sources/Auth/Login.swift", "README.md", "Sources/Auth/Session.swift", "Tests/AuthTests/LoginTests.swift"])
        #expect(items == [
            DiffTreeItem(name: "Sources/Auth", depth: 0, kind: .directory),
            DiffTreeItem(name: "Login.swift", depth: 1, kind: .file(0)),
            DiffTreeItem(name: "Session.swift", depth: 1, kind: .file(2)),
            DiffTreeItem(name: "Tests/AuthTests", depth: 0, kind: .directory),
            DiffTreeItem(name: "LoginTests.swift", depth: 1, kind: .file(3)),
            DiffTreeItem(name: "README.md", depth: 0, kind: .file(1)),
        ])
    }
}
