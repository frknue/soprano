import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct EngineRevertTests {
    /// Runs `texts` as completed turns on a fresh thread (optionally in its own worktree).
    private func threadWithTurns(_ texts: [String], worktreePath: String? = nil) async throws -> (AgentEngine, String, ScriptedDriver, RecordingGit) {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        let engine = EngineHarness.engine(driver: driver, git: git)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let thread = AgentThread(projectID: project.id, modelSelection: .default(for: .codex), worktreePath: worktreePath)
        engine.insertThread(thread)
        for text in texts {
            try await engine.send(thread.id, text: text, attachments: [])
            driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
            #expect(await EngineHarness.eventually { engine.thread(thread.id)?.turns.last?.checkpoint != nil })
        }
        return (engine, thread.id, driver, git)
    }

    @Test func revertingRollsTheProviderBackDropsLaterTurnsAndReturnsTheMessage() async throws {
        let (engine, threadID, driver, git) = try await threadWithTurns(["one", "two", "three"])
        let second = try #require(engine.thread(threadID)?.turns[1])

        let message = try await engine.revert(threadID, toBeforeTurn: second.id, restoreFiles: false)

        #expect(message.text == "two")
        #expect(driver.session?.rollbacks.first?.ordinal == 2)
        #expect(driver.session?.rollbacks.first?.providerTurnID == "provider-turn-2")
        #expect(engine.thread(threadID)?.turns.map(\.userMessage.text) == ["one"])
        let calls = git.checkpointCalls(threadID: threadID)
        #expect(calls.filter { $0.hasPrefix("delete") } == ["delete 2", "delete 3"])
        #expect(!calls.contains { $0.hasPrefix("restore") })
    }

    @Test func revertingWithFilesRestoresTheTurnsStartingCheckpointInAnIsolatedWorktree() async throws {
        let (engine, threadID, _, git) = try await threadWithTurns(["one", "two"], worktreePath: EngineHarness.temporaryDirectory().path)
        let first = try #require(engine.thread(threadID)?.turns.first)

        _ = try await engine.revert(threadID, toBeforeTurn: first.id, restoreFiles: true)

        let calls = git.checkpointCalls(threadID: threadID)
        #expect(calls.filter { $0.hasPrefix("restore") || $0.hasPrefix("delete") } == ["restore 0", "delete 1", "delete 2"])
        #expect(engine.thread(threadID)?.turns.isEmpty == true)
    }

    @Test func restoringFilesInASharedCheckoutIsRefused() async throws {
        let (engine, threadID, driver, git) = try await threadWithTurns(["one"])
        let first = try #require(engine.thread(threadID)?.turns.first)

        await #expect(throws: EngineError.message("File restore requires an isolated worktree. This workspace may contain changes from another thread. Rewind the conversation without restoring files instead.")) {
            _ = try await engine.revert(threadID, toBeforeTurn: first.id, restoreFiles: true)
        }
        #expect(engine.thread(threadID)?.turns.count == 1)
        #expect(driver.session?.rollbacks.isEmpty == true)
        #expect(!git.calls.contains { $0.hasPrefix("restore") })
    }

    @Test func revertingWhileATurnRunsIsRefused() async throws {
        let (engine, threadID, _, _) = try await threadWithTurns(["one"])
        try await engine.send(threadID, text: "two", attachments: [])
        let first = try #require(engine.thread(threadID)?.turns.first)

        await #expect(throws: EngineError.turnRunning) {
            _ = try await engine.revert(threadID, toBeforeTurn: first.id, restoreFiles: false)
        }
        #expect(EngineError.turnRunning.errorDescription == "Interrupt the current turn before reverting checkpoints.")
    }
}
