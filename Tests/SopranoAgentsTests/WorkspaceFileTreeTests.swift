import AppKit
import Testing
@testable import SopranoAgents

struct WorkspaceFileTreeTests {
    private let paths = [
        "Package.swift",
        "README.md",
        "Sources/Auth/LoginController.swift",
        "Sources/Auth/SessionStore.swift",
        "Sources/app.swift",
        "Tests/AuthTests/LoginRedirectTests.swift",
        "docs/guide/setup.md",
        "docs/Login.md",
        "assets/logo.png",
    ]

    @Test func foldersComeBeforeFilesAndEachSortsAlphabeticallyIgnoringCase() {
        let tree = WorkspaceFileTree(paths: paths)
        #expect(tree.roots.map(\.name) == ["assets", "docs", "Sources", "Tests", "Package.swift", "README.md"])
        let sources = tree.roots[2]
        #expect(sources.isDirectory)
        #expect(sources.children.map(\.name) == ["Auth", "app.swift"])
        #expect(sources.children[0].children.map(\.path) == ["Sources/Auth/LoginController.swift", "Sources/Auth/SessionStore.swift"])
        #expect(tree.roots[1].children.map(\.name) == ["guide", "Login.md"])
    }

    @Test func nodesCarryTheirWorkspaceRelativePathAndFolder() {
        let tree = WorkspaceFileTree(paths: paths)
        let setup = tree.roots[1].children[0].children[0]
        #expect(setup.path == "docs/guide/setup.md")
        #expect(setup.directory == "docs/guide")
        #expect(!setup.isDirectory)
        #expect(tree.roots[4].directory == "")
        #expect(tree.directoryPaths == ["assets", "docs", "docs/guide", "Sources", "Sources/Auth", "Tests", "Tests/AuthTests"])
    }

    @Test func searchRanksFileNameMatchesBeforePathAndSubsequenceMatches() {
        let tree = WorkspaceFileTree(paths: paths)
        #expect(tree.search("login") == [
            "Sources/Auth/LoginController.swift",
            "Tests/AuthTests/LoginRedirectTests.swift",
            "docs/Login.md",
        ])
        let ranked = WorkspaceFileTree(paths: ["a/u/t/h.txt", "auth/notes.txt", "lib/oauth.swift", "lib/AUTH.swift"])
        #expect(ranked.search(" Auth ") == ["lib/AUTH.swift", "lib/oauth.swift", "auth/notes.txt", "a/u/t/h.txt"])
        #expect(ranked.search("zz").isEmpty)
    }

    @Test func emptyQueriesMatchNothingAndResultsStopAtTheLimit() {
        let many = WorkspaceFileTree(paths: (0..<800).map { "lib/file\($0).txt" })
        #expect(many.search("   ").isEmpty)
        #expect(many.search("file").count == WorkspaceFileTree.searchLimit)
        #expect(many.search("file", limit: 3) == ["lib/file0.txt", "lib/file1.txt", "lib/file2.txt"])
    }

    @Test func anEmptyListingHasNoRows() {
        let tree = WorkspaceFileTree(paths: [])
        #expect(tree.isEmpty)
        #expect(tree.roots.isEmpty)
    }
}
