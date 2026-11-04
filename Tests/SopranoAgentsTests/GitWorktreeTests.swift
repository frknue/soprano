import AppKit
import CryptoKit
import Testing
@testable import SopranoAgentsCore

struct GitWorktreeTests {
    @Test func worktreeFoldersReplaceSlashesAndShortenLongBranchNamesWithAHash() {
        #expect(LiveGitService.worktreePath(directory: "/w", projectRoot: "/code/app", branch: "soprano/1a2b3c4d")
            == "/w/app/soprano-1a2b3c4d")

        let exactly40 = "feature/" + String(repeating: "a", count: 32)
        #expect(LiveGitService.worktreePath(directory: "/w", projectRoot: "/code/app", branch: exactly40)
            == "/w/app/feature-" + String(repeating: "a", count: 32))

        let long = "soprano/add-a-very-long-descriptive-branch-name-here"
        let digest = SHA256.hash(data: Data(long.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = LiveGitService.worktreePath(directory: "/w", projectRoot: "/code/app", branch: long)
        #expect(path == "/w/app/soprano-add-a-very-long-" + digest.prefix(16))
        #expect(URL(fileURLWithPath: path).lastPathComponent.count == 40)
    }

    @Test func aWorktreeWhoseSubmodulesFailToCheckOutLeavesNoFolderOrBranchBehind() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository("app")
        try await repo.commit("base", ["a.txt": "a\n"])
        let base = try await repo.output("rev-parse", "HEAD")
        // A submodule whose URL does not exist: `submodule update` fails after the worktree exists.
        try repo.write(".gitmodules", "[submodule \"lib\"]\n\tpath = lib\n\turl = \(sandbox.url("missing-remote").path)\n")
        try await repo.git("add", ".gitmodules")
        try await repo.git("update-index", "--add", "--cacheinfo", "160000,\(base),lib")
        try await repo.git("commit", "-m", "add submodule")
        let branch = try await repo.output("symbolic-ref", "--short", "HEAD")
        let worktrees = sandbox.url("worktrees").path

        await #expect(throws: (any Error).self) {
            try await sandbox.service.createWorktree(
                projectRoot: repo.path, baseBranch: branch, newBranch: "soprano/broken", directory: worktrees
            )
        }

        #expect(!FileManager.default.fileExists(atPath: "\(worktrees)/app/soprano-broken"))
        #expect(try await repo.output("branch", "--list", "soprano/broken").isEmpty)
    }

    @Test func stoppingDuringSubmoduleSetupStillRemovesTheWorktreeAndBranch() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository("app")
        try await repo.commit("base", ["a.txt": "a\n"])
        let base = try await repo.output("rev-parse", "HEAD")
        // A submodule remote that never answers, so `submodule update` hangs until cancelled.
        let config = sandbox.url("gitconfig")
        try (String(contentsOf: config, encoding: .utf8) + "[protocol \"ext\"]\n\tallow = always\n")
            .write(to: config, atomically: true, encoding: .utf8)
        try repo.write(".gitmodules", "[submodule \"lib\"]\n\tpath = lib\n\turl = ext::sleep 30\n")
        try await repo.git("add", ".gitmodules")
        try await repo.git("update-index", "--add", "--cacheinfo", "160000,\(base),lib")
        try await repo.git("commit", "-m", "add submodule")
        let branch = try await repo.output("symbolic-ref", "--short", "HEAD")
        let worktrees = sandbox.url("worktrees").path
        let folder = "\(worktrees)/app/soprano-stopped"

        let setup = Task {
            try await sandbox.service.createWorktree(
                projectRoot: repo.path, baseBranch: branch, newBranch: "soprano/stopped", directory: worktrees
            )
        }
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: "\(folder)/.gitmodules"), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        setup.cancel()
        _ = await setup.result

        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(try await repo.output("branch", "--list", "soprano/stopped").isEmpty)
    }

    @Test func aBranchWhoseFolderBelongsToAnotherWorktreeFailsWithoutTouchingThatWorktree() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository("app")
        try await repo.commit("base", ["a.txt": "a\n"])
        let branch = try await repo.output("symbolic-ref", "--short", "HEAD")
        let worktrees = sandbox.url("worktrees").path
        // "feature/a" and "feature-a" both map to the folder "feature-a".
        let first = try await sandbox.service.createWorktree(
            projectRoot: repo.path, baseBranch: branch, newBranch: "feature/a", directory: worktrees
        )
        try "unsaved work\n".write(toFile: first + "/notes.txt", atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            try await sandbox.service.createWorktree(
                projectRoot: repo.path, baseBranch: branch, newBranch: "feature-a", directory: worktrees
            )
        }

        #expect(FileManager.default.fileExists(atPath: first + "/notes.txt"))
        let worktree = GitScript(root: URL(fileURLWithPath: first), runner: sandbox.runner)
        #expect(try await worktree.output("symbolic-ref", "--short", "HEAD") == "feature/a")
        #expect(try await repo.output("branch", "--list", "feature-a").isEmpty)
    }

    @Test func creatingAWorktreeBranchesFromTheBaseAndChecksItOutAtTheRulePath() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository("app")
        try await repo.commit("base", ["a.txt": "a\n"])
        let base = try await repo.output("rev-parse", "HEAD")
        try await repo.commit("later on main", ["b.txt": "b\n"])
        try await repo.git("branch", "release", base)
        let worktrees = sandbox.url("worktrees").path

        let path = try await sandbox.service.createWorktree(
            projectRoot: repo.path, baseBranch: "release", newBranch: "soprano/1a2b3c4d", directory: worktrees
        )

        #expect(path == "\(worktrees)/app/soprano-1a2b3c4d")
        let worktree = GitScript(root: URL(fileURLWithPath: path), runner: sandbox.runner)
        #expect(try await worktree.output("symbolic-ref", "--short", "HEAD") == "soprano/1a2b3c4d")
        #expect(try await worktree.output("rev-parse", "HEAD") == base)
        #expect(!worktree.exists("b.txt"))
        // The main checkout stays where it was.
        #expect(try await repo.output("symbolic-ref", "--short", "HEAD") == "main")
        // The new branch does not track the base, so the first push publishes it under its own name.
        let upstream = try await sandbox.runner.run(
            ["config", "--get", "branch.soprano/1a2b3c4d.merge"], in: repo.root, acceptedExitCodes: [0, 1]
        )
        #expect(upstream.exitCode == 1)

        try await sandbox.service.removeWorktree(projectRoot: repo.path, path: path, force: false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func branchesMarkTheCurrentDefaultAndOtherWorktreeBranches() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let remote = try await sandbox.bareRemote()
        let repo = try await sandbox.repository("app")
        try await repo.commit("initial", ["a.txt": "a\n"])
        try await repo.git("remote", "add", "origin", remote.path)
        try await repo.git("push", "--quiet", "-u", "origin", "main")
        try await repo.git("switch", "--quiet", "-c", "feature/current")
        try await repo.git("branch", "idle")
        let elsewhere = try await sandbox.service.createWorktree(
            projectRoot: repo.path, baseBranch: "main", newBranch: "soprano/elsewhere", directory: sandbox.url("wt").path
        )

        let branches = try await sandbox.service.branches(cwd: repo.path)

        #expect(branches.map(\.name) == ["feature/current", "main", "idle", "soprano/elsewhere", "origin/main"]
            || branches.map(\.name) == ["feature/current", "main", "soprano/elsewhere", "idle", "origin/main"])
        let byName = Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0) })
        #expect(byName["feature/current"]?.isCurrent == true)
        #expect(byName["feature/current"]?.worktreePath == nil)
        #expect(byName["main"]?.isDefault == true)
        #expect(byName["main"]?.isCurrent == false)
        #expect(byName["soprano/elsewhere"]?.worktreePath == elsewhere)
        #expect(byName["idle"]?.worktreePath == nil)
        #expect(byName["origin/main"]?.isRemote == true)

        // Seen from the other worktree, the main checkout's branch is the one elsewhere.
        let fromWorktree = try await sandbox.service.branches(cwd: elsewhere)
        let viewed = Dictionary(uniqueKeysWithValues: fromWorktree.map { ($0.name, $0) })
        #expect(viewed["soprano/elsewhere"]?.isCurrent == true)
        #expect(viewed["feature/current"]?.worktreePath == repo.path)
    }

    @Test func switchingToARemoteBranchCreatesALocalTrackingBranch() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let remote = try await sandbox.bareRemote()
        let repo = try await sandbox.repository()
        try await repo.commit("initial", ["a.txt": "a\n"])
        try await repo.git("remote", "add", "origin", remote.path)
        try await repo.git("push", "--quiet", "origin", "main", "main:shared")
        try await repo.git("fetch", "--quiet")

        try await sandbox.service.switchBranch(cwd: repo.path, name: "origin/shared")
        #expect(try await repo.output("symbolic-ref", "--short", "HEAD") == "shared")
        #expect(try await repo.output("rev-parse", "--abbrev-ref", "shared@{upstream}") == "origin/shared")

        try await sandbox.service.renameBranch(cwd: repo.path, from: "shared", to: "renamed")
        try await sandbox.service.createBranch(cwd: repo.path, name: "side", checkout: false)
        #expect(try await repo.output("symbolic-ref", "--short", "HEAD") == "renamed")
        try await sandbox.service.switchBranch(cwd: repo.path, name: "side")
        #expect(try await repo.output("symbolic-ref", "--short", "HEAD") == "side")
    }
}
