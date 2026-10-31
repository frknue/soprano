import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct WorkspaceLocationTests {
    private func engine(_ sandbox: GitSandbox) -> AgentEngine {
        AgentEngine(environment: EngineEnvironment(
            drivers: [:],
            git: sandbox.service,
            store: InMemoryThreadStore(),
            dataDirectory: sandbox.url("data")
        ))
    }

    @Test func aProjectInsideARepositoryIsNamedRepositorySlashSubfolderOnItsBranch() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository("soprano-agents")
        try await repo.commit("init", ["docs/README.md": "hi"])
        let engine = engine(sandbox)
        let project = engine.addProject(path: repo.root.appendingPathComponent("docs").path)

        let draft = try #require(await engine.workspaceLocation(.draft(projectID: project.id)))

        #expect(draft.title == "soprano-agents/docs")
        #expect(draft.kind == .checkout)
        #expect(draft.branch == "main")
        #expect(draft.path == project.path)
    }

    @Test func aWorktreeIsNamedAfterItsProjectsRepository() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.repository("app")
        try await repo.commit("init", ["README.md": "hi"])
        let worktree = sandbox.url("worktrees/app/feature-x")
        try await repo.git("worktree", "add", "--quiet", "-b", "feature/x", worktree.path)
        let engine = engine(sandbox)
        let project = engine.addProject(path: repo.path)
        var thread = AgentThread(projectID: project.id, title: "T", modelSelection: .default(for: .codex))
        thread.worktreePath = worktree.path
        engine.insertThread(thread)

        let location = try #require(await engine.workspaceLocation(.thread(thread.id)))

        #expect(location.title == "app")
        #expect(location.kind == .worktree)
        #expect(location.branch == "feature/x")
    }

    @Test func foldersOutsideGitShowTheirPathAndScratchThreadsSayScratch() async throws {
        let sandbox = try GitSandbox()
        defer { sandbox.remove() }
        let plain = sandbox.url("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let engine = engine(sandbox)
        let project = engine.addProject(path: plain.path)
        let scratch = AgentThread(projectID: nil, title: "S", modelSelection: .default(for: .codex))
        engine.insertThread(scratch)

        let folder = try #require(await engine.workspaceLocation(.draft(projectID: project.id)))
        let scratchLocation = try #require(await engine.workspaceLocation(.thread(scratch.id)))

        #expect(folder.title == (project.path as NSString).abbreviatingWithTildeInPath)
        #expect(folder.branch == nil)
        #expect(scratchLocation.title == "Scratch")
        #expect(await engine.workspaceLocation(.draft(projectID: "missing")) == nil)
    }
}
