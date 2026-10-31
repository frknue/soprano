import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct EngineWorkspaceTests {
    private func failure(of threadID: String, in engine: AgentEngine) async -> String? {
        _ = await EngineHarness.eventually { engine.thread(threadID)?.isRunning == false }
        return engine.thread(threadID)?.turns.last?.failureMessage
    }

    @Test func aThreadWhoseWorktreeWasDeletedFailsItsTurnWithoutStartingTheAgent() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let missing = "/tmp/soprano-agents-deleted-\(UUID().uuidString)"
        let thread = AgentThread(projectID: project.id, modelSelection: .default(for: .omp), worktreePath: missing)
        engine.insertThread(thread)

        try await engine.send(thread.id, text: "go", attachments: [])

        #expect(driver.session == nil)
        #expect(await failure(of: thread.id, in: engine)?.contains(missing) == true)
    }

    @Test func aFailedWorktreeSetupNeverFallsBackToTheProjectRoot() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        git.worktreeError = EngineError.message("worktree add failed")
        var settings = EngineSettings(generateTitles: false)
        settings.worktreesDirectory = EngineHarness.temporaryDirectory().path
        let engine = EngineHarness.engine(driver: driver, git: git, settings: settings)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let draft = ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp), workspace: .newWorktree(baseBranch: "main"))
        let threadID = try await engine.launchThread(draft, text: "first", attachments: [])
        #expect(await failure(of: threadID, in: engine) == "worktree add failed")

        try await engine.send(threadID, text: "second", attachments: [])

        #expect(driver.session == nil)
        #expect(engine.thread(threadID)?.worktreePath != project.path)
        #expect(await failure(of: threadID, in: engine) != nil)
    }

    @Test func aFailedFileRestoreStillRewindsTheConversationItRolledBack() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        let engine = EngineHarness.engine(driver: driver, git: git)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let worktree = EngineHarness.temporaryDirectory().path
        let thread = AgentThread(projectID: project.id, modelSelection: .default(for: .omp), worktreePath: worktree)
        engine.insertThread(thread)
        for text in ["one", "two"] {
            try await engine.send(thread.id, text: text, attachments: [])
            driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
            #expect(await EngineHarness.eventually { engine.thread(thread.id)?.turns.last?.checkpoint != nil })
        }
        git.restoreError = EngineError.message("Git's index is locked.")
        let second = try #require(engine.thread(thread.id)?.turns[1])

        await #expect(throws: (any Error).self) {
            _ = try await engine.revert(thread.id, toBeforeTurn: second.id, restoreFiles: true)
        }

        #expect(driver.session?.rollbacks.count == 1)
        #expect(engine.thread(thread.id)?.turns.map(\.userMessage.text) == ["one"])
    }
}
