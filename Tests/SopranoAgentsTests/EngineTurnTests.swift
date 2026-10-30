import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct EngineTurnTests {
    private final class Recorder {
        var events: [EngineEvent] = []
    }

    @Test func aSentMessageRunsATurnUntilTheProviderCompletesIt() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)

        try await engine.send(threadID, text: "  Fix the login bug \n", attachments: [])

        let session = try #require(driver.session)
        let thread = try #require(engine.thread(threadID))
        #expect(session.configs.first?.cwd == engine.project(thread.projectID)?.path)
        #expect(session.turns.map(\.text) == ["Fix the login bug"])
        #expect(engine.thread(threadID)?.providerThreadID == "conv-1")
        let running = try #require(engine.thread(threadID)?.activeTurn)
        #expect(running.ordinal == 1)
        #expect(running.providerTurnID == "provider-turn-1")
        #expect(ThreadStatus.of(engine.thread(threadID)!).isWorking)

        session.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.last?.status == .completed })
        await engine.runtime.waitForBackgroundWork()
        let turn = try #require(engine.thread(threadID)?.turns.last)
        #expect(turn.completedAt != nil)
        #expect(turn.checkpoint?.status == .ready)
        #expect(turn.checkpoint?.files.map(\.path) == ["README.md"])
    }

    @Test func checkpointRefsAreCapturedBeforeAndAfterEachTurnInOrder() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        let engine = EngineHarness.engine(driver: driver, git: git)
        let threadID = EngineHarness.idleThread(in: engine)

        try await engine.send(threadID, text: "one", attachments: [])
        driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.last?.checkpoint != nil })
        try await engine.send(threadID, text: "two", attachments: [])
        driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.count == 2 && engine.thread(threadID)?.turns.last?.checkpoint != nil })

        // The baseline before turn 2 is turn 1's checkpoint, so it is not captured again.
        #expect(git.checkpointCalls(threadID: threadID) == [
            "capture 0",
            "capture 1", "changed 0..1",
            "capture 2", "changed 1..2",
        ])
    }

    @Test func aWorkspaceOutsideGitGetsAMissingCheckpointWithoutGitCalls() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        git.isRepo = false
        let engine = EngineHarness.engine(driver: driver, git: git)
        let threadID = EngineHarness.idleThread(in: engine)

        try await engine.send(threadID, text: "one", attachments: [])
        driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.last?.checkpoint?.status == .missing })
        #expect(git.calls.isEmpty)
    }

    @Test func streamedDeltasBuildTheAssistantMessageAndAnnounceOnlyThatItem() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "hi", attachments: [])
        let session = try #require(driver.session)
        let recorder = Recorder()
        engine.addObserver(recorder) { recorder.events.append($0) }

        session.emit(.assistantDelta(itemID: "msg", delta: "Hel", isFinal: false))
        session.emit(.assistantDelta(itemID: "msg", delta: "lo", isFinal: true))
        session.emit(.reasoningDelta(itemID: "think", delta: "Pondering"))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.activeTurn?.items.count == 2 })
        let items = try #require(engine.thread(threadID)?.activeTurn?.items)
        #expect(items[0].kind == .assistantMessage(text: "Hello", isFinal: true))
        #expect(items[1].kind == .reasoning(text: "Pondering"))
        let turnID = try #require(engine.thread(threadID)?.activeTurn?.id)
        // Creating an item re-renders the thread; appending to it only re-renders the item.
        #expect(recorder.events.filter { $0 == .threadChanged(threadID: threadID) }.count == 2)
        #expect(recorder.events.contains(.itemChanged(threadID: threadID, turnID: turnID, itemID: "msg")))
    }

    @Test func itemUpdatesReplaceByIdAndKeepTheOriginalStartTime() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "hi", attachments: [])
        let session = try #require(driver.session)
        let started = Date(timeIntervalSince1970: 100)

        session.emit(.itemUpdated(TurnItem(id: "cmd", kind: .command(CommandExecution(command: "ls")), status: .running, startedAt: started)))
        session.emit(.commandOutputDelta(itemID: "cmd", delta: "a.txt\n"))
        session.emit(.itemUpdated(TurnItem(id: "cmd", kind: .command(CommandExecution(command: "ls", output: "a.txt\n", exitCode: 0)), status: .completed, startedAt: Date())))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.activeTurn?.items.first?.status == .completed })
        let item = try #require(engine.thread(threadID)?.activeTurn?.items.first)
        #expect(engine.thread(threadID)?.activeTurn?.items.count == 1)
        #expect(item.startedAt == started)
        #expect(item.completedAt != nil)
        #expect(item.kind == .command(CommandExecution(command: "ls", output: "a.txt\n", exitCode: 0)))
    }

    @Test func anApprovalBlocksTheThreadUntilTheUserAnswersIt() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "rm it", attachments: [])
        let session = try #require(driver.session)

        session.emit(.approvalRequested(ApprovalRequest(id: "req-7", kind: .command, detail: "rm -rf build")))
        #expect(await EngineHarness.eventually { ThreadStatus.of(engine.thread(threadID)!) == .approval })

        await engine.respond(threadID, approvalID: "req-7", decision: .decline, feedback: "use make clean")

        #expect(session.responses.map(\.id) == ["req-7"])
        #expect(session.responses.first?.decision == .decline)
        #expect(session.responses.first?.feedback == "use make clean")
        let item = try #require(engine.thread(threadID)?.activeTurn?.items.first)
        #expect(item.status == .declined)
        guard case let .approval(request) = item.kind else { Issue.record("not an approval"); return }
        #expect(request.decision == .decline)
        #expect(ThreadStatus.of(engine.thread(threadID)!).isWorking)
    }

    @Test func answeredQuestionsReachTheProviderAndClearTheInputPill() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "plan", attachments: [])
        let session = try #require(driver.session)
        let question = UserInputQuestion(id: "db", header: "Database", question: "Which one?", options: [UserInputOption(label: "Postgres")])

        session.emit(.userInputRequested(UserInputRequest(id: "ask-1", questions: [question])))
        #expect(await EngineHarness.eventually { ThreadStatus.of(engine.thread(threadID)!) == .input })

        await engine.answer(threadID, requestID: "ask-1", answers: ["db": ["Postgres"]])

        #expect(session.answers.first?.id == "ask-1")
        #expect(session.answers.first?.answers == ["db": ["Postgres"]])
        #expect(ThreadStatus.of(engine.thread(threadID)!).isWorking)
    }

    @Test func aRequestTheProviderWithdrawsNoLongerBlocksTheThread() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "go", attachments: [])
        let session = try #require(driver.session)

        session.emit(.approvalRequested(ApprovalRequest(id: "req-1", kind: .fileChange, detail: "a.swift")))
        session.emit(.requestResolved(id: "req-1"))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.activeTurn?.items.first?.status == .declined })
        #expect(engine.thread(threadID)?.activeTurn?.pendingApproval == nil)
    }

    @Test func messagesSentWhileRunningSteerTheTurnOrWaitInTheQueue() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "first", attachments: [])
        let session = try #require(driver.session)

        try await engine.send(threadID, text: "also do this", attachments: [], mode: .automatic)
        try await engine.send(threadID, text: "afterwards", attachments: [], mode: .queue)

        #expect(session.steers.map(\.text) == ["also do this"])
        let turn = try #require(engine.thread(threadID)?.activeTurn)
        #expect(turn.steers.map(\.text) == ["also do this"])
        #expect(turn.steers.map(\.isSteer) == [true])
        #expect(engine.thread(threadID)?.queue.map(\.message.text) == ["afterwards"])
        #expect(session.turns.count == 1)
    }

    @Test func theQueueDrainsIntoTheNextTurnWhenTheRunningTurnCompletes() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "first", attachments: [])
        try await engine.send(threadID, text: "second", attachments: [], mode: .queue)
        let session = try #require(driver.session)

        session.emit(.turnCompleted(outcome: .completed, error: nil))

        #expect(await EngineHarness.eventually { session.turns.count == 2 })
        let thread = try #require(engine.thread(threadID))
        #expect(thread.queue.isEmpty)
        #expect(thread.turns.map(\.userMessage.text) == ["first", "second"])
        #expect(thread.turns.last?.ordinal == 2)
        #expect(thread.turns.last?.status == .running)
        #expect(driver.sessions.count == 1)
    }

    @Test func interruptingStopsTheProviderTurnAndHoldsTheQueue() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "first", attachments: [])
        try await engine.send(threadID, text: "later", attachments: [], mode: .queue)
        let session = try #require(driver.session)
        session.emit(.turnStarted(providerTurnID: "provider-turn-1"))
        session.emit(.itemUpdated(TurnItem(id: "cmd", kind: .command(CommandExecution(command: "sleep 100")))))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.activeTurn?.items.count == 1 })

        await engine.interrupt(threadID)
        #expect(session.interrupts == 1)
        session.emit(.turnCompleted(outcome: .interrupted, error: nil))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.last?.status == .interrupted })
        await engine.runtime.waitForBackgroundWork()
        let thread = try #require(engine.thread(threadID))
        #expect(thread.turns.last?.items.first?.status == .interrupted)
        #expect(thread.queue.map(\.message.text) == ["later"])
        #expect(session.turns.count == 1)
    }

    @Test func aSessionThatDiesFailsTheRunningTurnAndTheNextSendResumesIt() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "first", attachments: [])
        let session = try #require(driver.session)

        session.emit(.sessionEnded(error: "codex exited with status 1"))

        #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.last?.status == .failed })
        #expect(engine.thread(threadID)?.turns.last?.failureMessage == "codex exited with status 1")

        try await engine.send(threadID, text: "again", attachments: [])
        #expect(driver.sessions.count == 2)
        #expect(driver.session?.configs.first?.resumeID == "conv-1")
    }

    @Test func aProviderThatCannotStartTheTurnFailsIt() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        // First send creates the session; make its next turn fail.
        try await engine.send(threadID, text: "first", attachments: [])
        driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.isRunning == false })
        driver.session?.startTurnError = EngineError.message("model not found")

        try await engine.send(threadID, text: "second", attachments: [])

        #expect(engine.thread(threadID)?.turns.last?.status == .failed)
        #expect(engine.thread(threadID)?.turns.last?.failureMessage == "model not found")
    }

    @Test func emptyMessagesAreRejected() async throws {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)

        await #expect(throws: EngineError.emptyMessage) {
            try await engine.send(threadID, text: " \n ", attachments: [])
        }
        #expect(engine.thread(threadID)?.turns.isEmpty == true)
    }

    @Test func turnDiffsCompareTheTurnsOwnCheckpointsAndTheThreadDiffStartsAtTheBaseline() async throws {
        let driver = ScriptedDriver()
        let git = RecordingGit()
        let engine = EngineHarness.engine(driver: driver, git: git)
        let threadID = EngineHarness.idleThread(in: engine)
        for text in ["one", "two"] {
            try await engine.send(threadID, text: text, attachments: [])
            driver.session?.emit(.turnCompleted(outcome: .completed, error: nil))
            #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.last?.checkpoint != nil })
        }

        _ = try await engine.turnDiff(threadID, turnOrdinal: 2)
        _ = try await engine.turnDiff(threadID, turnOrdinal: nil)

        #expect(git.checkpointCalls(threadID: threadID).filter { $0.hasPrefix("diff") } == ["diff 1..2", "diff 0..2"])
    }
}
