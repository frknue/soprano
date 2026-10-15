import AppKit
import Testing
@testable import Soprano

struct SopranoGitLauncherTests {
    private let application = URL(fileURLWithPath: "/Applications/Soprano Git.app", isDirectory: true)

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-git-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func openedRepository(_ plan: SopranoGitLauncher.Plan) -> String? {
        guard case let .open(repository, _) = plan else { return nil }
        return repository.path
    }

    @Test func aTerminalDeepInsideARepositoryOpensTheRepositoryRoot() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let nested = root.appendingPathComponent("Sources/App", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            let plan = SopranoGitLauncher.plan(workingDirectory: nested.path, application: { application })

            #expect(openedRepository(plan) == root.standardizedFileURL.path)
            #expect(SopranoGitLauncher.explanation(for: plan) == nil)
        }
    }

    @Test func aLinkedWorktreeOpensItselfRatherThanItsMainRepository() throws {
        try withTemporaryDirectory { root in
            let main = root.appendingPathComponent("main", isDirectory: true)
            try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/feature"), withIntermediateDirectories: true)
            let worktree = root.appendingPathComponent("feature", isDirectory: true)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try Data("gitdir: \(main.path)/.git/worktrees/feature\n".utf8).write(to: worktree.appendingPathComponent(".git"))

            let plan = SopranoGitLauncher.plan(workingDirectory: worktree.path, application: { application })

            #expect(openedRepository(plan) == worktree.standardizedFileURL.path)
        }
    }

    @Test func aFolderOutsideAnyRepositoryIsExplainedInsteadOfOpened() throws {
        try withTemporaryDirectory { root in
            let plan = SopranoGitLauncher.plan(workingDirectory: root.path, application: { application })

            #expect(plan == .notARepository(root.path))
            #expect(SopranoGitLauncher.explanation(for: plan)?.hasSuffix("is not inside a Git repository.") == true)
        }
    }

    @Test func nothingOpensWhenSopranoGitIsNotInstalled() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)

            let plan = SopranoGitLauncher.plan(workingDirectory: root.path, application: { nil })

            #expect(plan == .notInstalled)
            #expect(SopranoGitLauncher.explanation(for: plan) == "Soprano Git isn't installed.")
        }
    }

    @Test func aTabWithoutAFolderIsExplained() {
        #expect(SopranoGitLauncher.plan(workingDirectory: nil, application: { application }) == .noWorkingDirectory)
        #expect(SopranoGitLauncher.plan(workingDirectory: "", application: { application }) == .noWorkingDirectory)
    }
}
