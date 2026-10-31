import AppKit
import Testing
@testable import SopranoAgentsCore

/// The context meter's data (`AgentThread.contextUsage`) and compaction (`compact`, `/compact`).
@MainActor
struct EngineContextTests {
    /// An idle thread whose first turn completed, so it has a provider conversation.
    private func threadWithConversation(_ engine: AgentEngine, _ driver: ScriptedDriver) async throws -> String {
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "hi", attachments: [])
        driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.isRunning == false })
        await engine.runtime.waitForBackgroundWork()
        return threadID
    }

    @Test func everyTokenUpdateIsTheThreadsContextFillAndTheLatestTurnsUsage() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "hi", attachments: [])
        let session = try #require(driver.session)

        session.emit(.tokenUsage(TokenUsage(usedTokens: 1_000, contextWindow: 10_000)))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.contextUsage?.usedTokens == 1_000 })
        #expect(engine.thread(threadID)?.turns.last?.tokenUsage == TokenUsage(usedTokens: 1_000, contextWindow: 10_000))
        session.emit(.turnCompleted(outcome: .completed, error: nil))
        // An exact reading after the turn ended (omp `get_state`).
        session.emit(.tokenUsage(TokenUsage(usedTokens: 1_200, contextWindow: 10_000)))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.contextUsage?.usedTokens == 1_200 })
        #expect(engine.thread(threadID)?.turns.last?.tokenUsage?.usedTokens == 1_200)
        #expect(engine.thread(threadID)?.contextUsage?.fraction == 0.12)
        #expect(TokenUsage(usedTokens: 5, contextWindow: nil).fraction == nil)
        #expect(TokenUsage(usedTokens: 5, contextWindow: 0).fraction == nil)
    }

    @Test func compactingRunsAsATurnTheProviderCompacts() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await threadWithConversation(engine, driver)
        let session = try #require(driver.session)
        #expect(engine.canCompact(threadID))

        try await engine.compact(threadID)

        #expect(session.compactions == 1)
        #expect(session.turns.map(\.text) == ["hi"])
        let turn = try #require(engine.thread(threadID)?.activeTurn)
        #expect(turn.ordinal == 2)
        #expect(turn.userMessage.text == "/compact")
        #expect(!engine.canCompact(threadID))
        session.emit(.turnStarted(providerTurnID: "compaction-1"))
        session.emit(.itemUpdated(TurnItem(id: "notice-1", kind: .notice(text: "Context compacted"), status: .completed)))
        session.emit(.tokenUsage(TokenUsage(usedTokens: 300, contextWindow: 10_000)))
        session.emit(.turnCompleted(outcome: .completed, error: nil))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.isRunning == false })
        let compacted = try #require(engine.thread(threadID)?.turns.last)
        #expect(compacted.status == .completed)
        #expect(compacted.providerTurnID == "compaction-1")
        #expect(compacted.items.map(\.kind) == [.notice(text: "Context compacted")])
        #expect(engine.thread(threadID)?.contextUsage == TokenUsage(usedTokens: 300, contextWindow: 10_000))
        #expect(engine.canCompact(threadID))
    }

    @Test func sendingExactlySlashCompactCompactsAndAnythingLongerIsAMessage() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await threadWithConversation(engine, driver)
        let session = try #require(driver.session)

        try await engine.send(threadID, text: "  /compact \n", attachments: [])
        #expect(session.compactions == 1)
        session.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.isRunning == false })
        try await engine.send(threadID, text: "/compact keep the API notes", attachments: [])

        #expect(session.compactions == 1)
        #expect(session.turns.map(\.text) == ["hi", "/compact keep the API notes"])
    }

    @Test func compactingNeedsAConversationAndAnIdleThreadUnlessItIsQueued() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let fresh = EngineHarness.idleThread(in: engine)
        #expect(!engine.canCompact(fresh))
        await #expect(throws: EngineError.message("There is no conversation to compact yet.")) {
            try await engine.compact(fresh)
        }
        #expect(engine.thread(fresh)?.turns.isEmpty == true)

        try await engine.send(fresh, text: "hi", attachments: [])
        let session = try #require(driver.session)
        #expect(!engine.canCompact(fresh))
        await #expect(throws: EngineError.self) { try await engine.compact(fresh) }
        await #expect(throws: EngineError.self) { try await engine.send(fresh, text: "/compact", attachments: [], mode: .steer) }
        #expect(session.steers.isEmpty)
        try await engine.send(fresh, text: "/compact", attachments: [], mode: .queue)
        #expect(engine.thread(fresh)?.queue.map(\.message.text) == ["/compact"])
        // "Send now" cannot steer a compaction into the running turn.
        let queued = try #require(engine.thread(fresh)?.queue.first)
        await engine.sendQueuedNow(fresh, messageID: queued.id)
        #expect(engine.thread(fresh)?.queue.count == 1)

        session.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { session.compactions == 1 })
        #expect(engine.thread(fresh)?.queue.isEmpty == true)
        #expect(engine.thread(fresh)?.activeTurn?.userMessage.text == "/compact")
    }

    @Test func messagesSentDuringACompactionWaitForItInTheQueue() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await threadWithConversation(engine, driver)
        let session = try #require(driver.session)
        try await engine.compact(threadID)

        try await engine.send(threadID, text: "next", attachments: [], mode: .steer)

        #expect(session.steers.isEmpty)
        #expect(engine.thread(threadID)?.queue.map(\.message.text) == ["next"])
        session.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { session.turns.map(\.text) == ["hi", "next"] })
    }

    @Test func aRewindKeepsTheKeptTurnsFillAndAModelSwitchKeepsTheConversation() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        for (text, used) in [("one", 100), ("two", 200)] {
            try await engine.send(threadID, text: text, attachments: [])
            driver.session?.emit(.tokenUsage(TokenUsage(usedTokens: used, contextWindow: 1_000)))
            driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
            #expect(await EngineHarness.eventually { engine.thread(threadID)?.isRunning == false && engine.thread(threadID)?.contextUsage?.usedTokens == used })
            await engine.runtime.waitForBackgroundWork()
        }
        let second = try #require(engine.thread(threadID)?.turns.last)

        _ = try await engine.revert(threadID, toBeforeTurn: second.id, restoreFiles: false)
        #expect(engine.thread(threadID)?.contextUsage == TokenUsage(usedTokens: 100, contextWindow: 1_000))
        engine.setModelSelection(threadID, ModelSelection(provider: .omp, model: "anthropic/claude-haiku-5-5"))
        #expect(engine.thread(threadID)?.contextUsage == TokenUsage(usedTokens: 100, contextWindow: 1_000))
        #expect(engine.thread(threadID)?.providerThreadID == "conv-1")
        #expect(engine.canCompact(threadID))
    }
}
