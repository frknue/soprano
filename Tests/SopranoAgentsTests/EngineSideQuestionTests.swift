import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct EngineSideQuestionTests {
    private nonisolated static func exchange(_ question: String, _ answer: String, _ status: SideQuestionStatus, at seconds: TimeInterval) -> SideQuestionExchange {
        SideQuestionExchange(question: question, answer: answer, status: status, createdAt: Date(timeIntervalSince1970: seconds))
    }

    private nonisolated static func exchange(_ question: String, _ status: SideQuestionStatus, at seconds: TimeInterval) -> SideQuestionExchange {
        exchange(question, "", status, at: seconds)
    }

    /// A thread with a live scripted session (one sent message).
    private static func liveThread(_ engine: AgentEngine) async throws -> String {
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "hello", attachments: [])
        return threadID
    }

    @Test func aStreamedAnswerSurvivesTheAskAnswerArrivingAfterIt() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)
        let started = SideQuestion(id: "t1", first: Self.exchange("why?", .running, at: 1))
        // omp reports the started topic and streams before the ask's own answer is handled.
        session.sideQuestionAnswer = { @MainActor [session] _, _ in
            session.emit(.sideQuestion(started))
            session.emit(.sideQuestionDelta(id: "t1", delta: "Because "))
            _ = await EngineHarness.eventually { engine.sideQuestions(threadID).first?.latest.answer == "Because " }
            return started
        }

        let id = try await engine.askSideQuestion(threadID, question: "  why?  ")
        session.emit(.sideQuestionDelta(id: "t1", delta: "of locks."))
        #expect(await EngineHarness.eventually { engine.sideQuestions(threadID).first?.latest.answer == "Because of locks." })

        #expect(id == "t1")
        #expect(session.askedSideQuestions.map(\.question) == ["why?"])
        #expect(engine.sideQuestions(threadID).count == 1)
        // The thread's conversation is untouched.
        #expect(engine.thread(threadID)?.turns.count == 1)
    }

    @Test func aSecondQuestionIsRefusedWhileOneIsAnsweredAndAFollowUpNamesItsTopic() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)

        let topicID = try await engine.askSideQuestion(threadID, question: "first")
        await #expect(throws: EngineError.self) { try await engine.askSideQuestion(threadID, question: "second") }

        let done = SideQuestion(id: topicID, first: Self.exchange("first", "answer", .complete, at: 1))
        session.emit(.sideQuestion(done))
        #expect(await EngineHarness.eventually { engine.sideQuestions(threadID).first?.isRunning == false })
        session.sideQuestionAnswer = { question, topic in
            SideQuestion(id: topic ?? "?", first: done.first, followUps: [Self.exchange(question, .running, at: 2)])
        }
        _ = try await engine.askSideQuestion(threadID, question: "and then?", topicID: topicID)

        #expect(session.askedSideQuestions.map(\.topicID) == [nil, topicID])
        let topic = try #require(engine.sideQuestions(threadID).first)
        #expect(topic.first.answer == "answer")
        #expect(topic.exchanges.map(\.question) == ["first", "and then?"])
        #expect(topic.isRunning)
    }

    @Test func theSessionsEndInterruptsARunningAnswerAndKeepsItsText() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)
        let topicID = try await engine.askSideQuestion(threadID, question: "why?")
        session.emit(.sideQuestionDelta(id: topicID, delta: "Partly"))
        #expect(await EngineHarness.eventually { engine.sideQuestions(threadID).first?.latest.answer == "Partly" })

        session.emit(.sessionEnded(error: "omp exited"))
        #expect(await EngineHarness.eventually { engine.sideQuestions(threadID).first?.latest.status == .interrupted })
        #expect(engine.sideQuestions(threadID).first?.latest.answer == "Partly")
        // A new question can be asked again.
        await #expect(throws: Never.self) { try await engine.askSideQuestion(threadID, question: "again?") }
    }

    @Test func aThreadWithoutAConversationNeitherAsksNorStartsAProcessForItsHistory() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)

        try await engine.loadSideQuestions(threadID)
        await #expect(throws: EngineError.self) { try await engine.askSideQuestion(threadID, question: "why?") }

        #expect(driver.sessions.isEmpty)
        #expect(engine.sideQuestions(threadID).isEmpty)
    }

    @Test func theHistoryIsReadFromALiveSessionButARunningTopicKeepsItsStreamedText() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)
        let running = SideQuestion(id: "live", first: Self.exchange("now?", .running, at: 5))
        session.emit(.sideQuestion(running))
        session.emit(.sideQuestionDelta(id: "live", delta: "Streamed so far"))
        #expect(await EngineHarness.eventually { engine.sideQuestions(threadID).first?.latest.answer == "Streamed so far" })

        // The history read lags behind the stream; an older topic came from omp's TUI.
        session.sideQuestionHistory = [
            SideQuestion(id: "live", first: Self.exchange("now?", "Stream", .running, at: 5)),
            SideQuestion(id: "tui", first: Self.exchange("earlier?", "yes", .complete, at: 1)),
        ]
        engine.runtime.thread(threadID).sideQuestionsLoaded = false
        try await engine.loadSideQuestions(threadID)

        #expect(session.historyReads == 1)
        #expect(engine.sideQuestions(threadID).map(\.id) == ["live", "tui"])
        #expect(engine.sideQuestions(threadID).first?.latest.answer == "Streamed so far")
        // While it runs, opening the panel again does not re-read.
        try await engine.loadSideQuestions(threadID)
        #expect(session.historyReads == 1)
    }

    @Test func aRewoundConversationForgetsTheOldSideQuestions() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)
        session.emit(.sideQuestion(SideQuestion(id: "old", first: Self.exchange("q", "a", .complete, at: 1))))
        #expect(await EngineHarness.eventually { !engine.sideQuestions(threadID).isEmpty })

        session.emit(.conversationID("conv-2"))
        #expect(await EngineHarness.eventually { engine.sideQuestions(threadID).isEmpty })
        #expect(engine.runtime.existingThread(threadID)?.sideQuestionsLoaded == false)
    }

    @Test func aHistoryReadTakenBeforeAQuestionStartedNeverRollsTheTopicsBack() {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)
        let first = Self.exchange("first", "done", .complete, at: 1)
        let followUp = Self.exchange("more?", "Partly", .running, at: 3)
        // Reported live: a new topic, a follow-up, a topic that finished.
        engine.restoreSideQuestions([
            SideQuestion(id: "stopped", first: Self.exchange("stop?", "St", .cancelled, at: 6)),
            SideQuestion(id: "new", first: Self.exchange("new?", "Str", .running, at: 5)),
            SideQuestion(id: "followed", first: first, followUps: [followUp]),
            SideQuestion(id: "finished", first: Self.exchange("old?", "yes", .complete, at: 0)),
        ], threadID: threadID)
        // The history read began before all of that.
        engine.restoreSideQuestions([
            SideQuestion(id: "followed", first: first),
            SideQuestion(id: "finished", first: Self.exchange("old?", "y", .running, at: 0)),
        ], threadID: threadID)

        let topics = engine.sideQuestions(threadID)
        #expect(topics.map(\.id) == ["stopped", "new", "followed", "finished"])
        #expect(topics[0].latest.status == .cancelled)
        #expect(topics[1].latest.answer == "Str")
        #expect(topics[2].followUps == [followUp])
        #expect(topics[3].latest.status == .complete)
    }

    @Test func aStartingQuestionIsReportedUntilTheAskEnds() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)
        session.sideQuestionAnswer = { [session] question, _ in
            await Self.waitForCancel(session)
            throw ProviderError.message("cancelled while starting")
        }
        #expect(!engine.isStartingSideQuestion(threadID))

        let ask = Task { try await engine.askSideQuestion(threadID, question: "why?") }
        #expect(await EngineHarness.eventually { engine.isStartingSideQuestion(threadID) })
        await engine.cancelSideQuestion(threadID)
        _ = await ask.result

        #expect(!engine.isStartingSideQuestion(threadID))
    }

    /// Opened by the test; awaited by a scripted session start.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        func open() { lock.withLock { opened = true } }
        func wait() async {
            while !lock.withLock({ opened }) { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    private nonisolated static func waitForCancel(_ session: ScriptedSession) async {
        while session.sideQuestionCancels == 0 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func stopWhileTheSessionStartsAsksNothing() async throws {
        let driver = ScriptedDriver()
        let gate = Gate()
        driver.sessionStartGate = { await gate.wait() }
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        engine.updateThread(threadID) { $0.providerThreadID = "conv-0" }

        let ask = Task { try await engine.askSideQuestion(threadID, question: "why?") }
        #expect(await EngineHarness.eventually { driver.session != nil })
        let cancelled = await engine.cancelSideQuestion(threadID)
        gate.open()
        let result = await ask.result

        #expect(cancelled)
        #expect(throws: CancellationError.self) { try result.get() }
        let session = try #require(driver.session)
        #expect(session.askedSideQuestions.isEmpty)
        #expect(engine.sideQuestions(threadID).isEmpty)
        // The next question goes through.
        _ = try await engine.askSideQuestion(threadID, question: "now?")
        #expect(session.askedSideQuestions.map(\.question) == ["now?"])
    }

    @Test func stopBeforeTheProviderTookTheQuestionUpCancelsTheTopicItStartsButNotTheTurn() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)
        // omp answers `btw` only after the cancel, which found nothing running yet.
        session.sideQuestionAnswer = { [session] question, _ in
            await Self.waitForCancel(session)
            return SideQuestion(id: "late", first: Self.exchange(question, .running, at: 1))
        }

        let ask = Task { try await engine.askSideQuestion(threadID, question: "why?") }
        #expect(await EngineHarness.eventually { !session.askedSideQuestions.isEmpty })
        let cancelled = await engine.cancelSideQuestion(threadID)
        let id = try await ask.value

        #expect(cancelled)
        #expect(id == "late")
        #expect(session.sideQuestionCancels == 2)
        #expect(session.interrupts == 0)
        #expect(engine.thread(threadID)?.isRunning == true)
    }

    @Test func aQuestionTheProviderRefusesAfterStopEndsAsCancelled() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine)
        let session = try #require(driver.session)
        session.sideQuestionAnswer = { [session] _, _ in
            await Self.waitForCancel(session)
            throw ProviderError.message("cancelled while starting")
        }

        let ask = Task { try await engine.askSideQuestion(threadID, question: "why?") }
        #expect(await EngineHarness.eventually { !session.askedSideQuestions.isEmpty })
        #expect(await engine.cancelSideQuestion(threadID))
        let result = await ask.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(session.interrupts == 0)
        #expect(engine.sideQuestions(threadID).isEmpty)
    }
}
