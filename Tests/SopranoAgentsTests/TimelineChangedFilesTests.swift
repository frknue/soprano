import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

@MainActor
struct TimelineChangedFilesTests {
    private let files = [
        ChangedFileStat(path: "Sources/Auth/LoginController.swift", additions: 18, deletions: 6),
        ChangedFileStat(path: "Sources/Auth/SessionStore.swift", additions: 9, deletions: 2),
        ChangedFileStat(path: "Tests/AuthTests/LoginRedirectTests.swift", additions: 41, deletions: 0),
        ChangedFileStat(path: "README.md", additions: 1, deletions: 1),
    ]

    @Test func singleChildFolderChainsCollapseAndFoldersSumTheirFiles() {
        let tree = ChangedFileTree.build(files)
        #expect(tree.map(\.name) == ["Sources/Auth", "Tests/AuthTests", "README.md"])
        guard case let .directory(_, path, additions, deletions, children) = tree[0] else {
            Issue.record("expected a folder, got \(tree[0])")
            return
        }
        #expect(path == "Sources/Auth")
        #expect(additions == 27)
        #expect(deletions == 8)
        #expect(children.map(\.path) == ["Sources/Auth/LoginController.swift", "Sources/Auth/SessionStore.swift"])
    }

    @Test func foldersComeFirstAndNamesSortNumerically() {
        let tree = ChangedFileTree.build([
            ChangedFileStat(path: "b10.txt", additions: 0, deletions: 0),
            ChangedFileStat(path: "b9.txt", additions: 0, deletions: 0),
            ChangedFileStat(path: "z/a.txt", additions: 0, deletions: 0),
        ])
        #expect(tree.map(\.name) == ["z", "b9.txt", "b10.txt"])
    }

    @Test func closedFoldersHideTheirRows() {
        let tree = ChangedFileTree.build(files)
        let open = ChangedFileTree.rows(tree)
        #expect(open.map(\.node.name) == ["Sources/Auth", "LoginController.swift", "SessionStore.swift", "Tests/AuthTests", "LoginRedirectTests.swift", "README.md"])
        #expect(open.map(\.depth) == [0, 1, 1, 0, 1, 0])
        let closed = ChangedFileTree.rows(tree, collapsed: ["Sources/Auth"])
        #expect(closed.map(\.node.name) == ["Sources/Auth", "Tests/AuthTests", "LoginRedirectTests.swift", "README.md"])
        #expect(ChangedFileTree.directoryPaths(tree) == ["Sources/Auth", "Tests/AuthTests"])
    }

    @Test func theCardHeightFollowsTheVisibleRows() {
        let model = ChangedFilesModel(turnID: "t", turnOrdinal: 1, files: files, closedFolders: [])
        var closed = model
        closed.closedFolders = ["Sources/Auth"]
        #expect(ChangedFilesCardView.height(for: model) - ChangedFilesCardView.height(for: closed) == 2 * ChangedFilesCardView.rowHeight)
        #expect(model.additions == 69)
        #expect(model.deletions == 9)
    }
}
