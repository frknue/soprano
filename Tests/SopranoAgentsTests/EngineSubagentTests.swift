import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct EngineSubagentTests {
    private final class Recorder {
        var listChanges = 0
    }

    private static func traceEvents() throws -> [ProviderEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/omp-subagent.jsonl")
        var mapper = OmpSubagentMapper(cwd: "/tmp/omp-sub")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .flatMap { mapper.map(try JSONValue.parse(String($0))) }
    }

    /// A thread with a live scripted session (one finished turn).
    private static func liveThread(_ engine: AgentEngine, _ driver: ScriptedDriver) async throws -> String {
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "spawn a helper", attachments: [])
        return threadID
    }

    @Test func aSubagentsRunsAreFoldedIntoTheThread() throws {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)
        let recorder = Recorder()
        engine.addObserver(recorder) { [recorder] event in
            if case .subagentListChanged = event { recorder.listChanges += 1 }
        }
        for event in try Self.traceEvents() { engine.apply(event, threadID: threadID) }

        let subagent = try #require(engine.subagent(threadID, "Reader"))
        #expect(subagent.agent == "sonic")
        #expect(subagent.status == .completed)
        #expect(subagent.completedAt != nil)
        #expect(subagent.isDetached)
        #expect(subagent.assignment?.hasPrefix("Run `cat a.txt`") == true)
        #expect(subagent.model == "anthropic/claude-haiku-5-5")
        #expect(subagent.turns.count == 1)

        let run = try #require(subagent.turns.first)
        #expect(run.status == .completed)
        #expect(run.userMessage.text.hasPrefix("Complete assignment thoroughly:"))
        #expect(run.steers.map(\.text) == ["Also say DONE at the end."])
        #expect(run.steers.allSatisfy { $0.isSteer })
        let commands = run.items.compactMap { item -> String? in
            if case let .command(execution) = item.kind { return execution.command }
            return nil
        }
        #expect(commands == ["cat a.txt", "cat b.txt"])
        #expect(run.items.contains { item in
            if case let .assistantMessage(text, _) = item.kind { return text.hasSuffix("DONE") }
            return false
        })
        #expect(recorder.listChanges > 0)
        #expect(run.items.allSatisfy { !$0.status.isActive })
        // The thread's own turns are untouched.
        #expect(engine.thread(threadID)?.turns.isEmpty == true)
    }

    @Test func aSubagentsAdvisorReviewsLandInTheirRunsAtRunBoundariesWithoutPhantomRuns() throws {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)
        var mapper = OmpSubagentMapper()
        func review(_ note: String, _ severity: String) -> [String] {
            let message = #"{"role":"custom","customType":"advisor","content":"The following is an aggregated review from other models.\n<advisory>\n"# + note + #"\n</advisory>","display":true,"details":{"notes":[{"note":""# + note + #"","severity":""# + severity + #""}]}}"#
            return ["message_start", "message_end"].map { #"{"type":""# + $0 + #"","message":"# + message + "}" }
        }
        let run = [#"{"type":"message_start","message":{"role":"assistant","content":[]}}"#, #"{"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop"}]}"#]
        let events = [#"{"type":"agent_start"}"#, #"{"type":"message_start","message":{"role":"user","content":"List files"}}"#] + run
            + review("Idle note", "nit") // after the run ended, nothing starts
            + [#"{"type":"agent_start"}"#] + review("Fix it", "concern") + run // a review that starts the next run
        for event in events {
            let frame = try JSONValue.parse(#"{"type":"subagent_event","payload":{"id":"Lister","event":"# + event + "}}")
            for providerEvent in mapper.map(frame) { engine.apply(providerEvent, threadID: threadID) }
        }

        let turns = try #require(engine.subagent(threadID, "Lister")?.turns)
        #expect(turns.map(\.userMessage.text) == ["List files", "Advisor review"])
        #expect(turns.map(\.status) == [.completed, .completed])
        #expect(turns.map { $0.items.map(\.kind) } == [
            [.advisory([AdvisorNote(text: "Idle note")])],
            [.advisory([AdvisorNote(text: "Fix it", severity: .concern)])],
        ])
    }

    @Test func editingFromATurnDropsTheSubagentsItsRewoundTurnsStarted() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        for (text, call, name) in [("one", "call-1", "Scout"), ("two", "call-2", "Reader")] {
            try await engine.send(threadID, text: text, attachments: [])
            let session = try #require(driver.session)
            session.emit(.itemUpdated(TurnItem(id: call, kind: .toolCall(ToolCall(name: "task", category: .subagent, title: "Subagent: \(name)")), status: .completed)))
            session.emit(.subagent(id: name, .updated(SubagentInfo(agent: "sonic", status: .completed, sessionFile: "/s1/\(name).jsonl", parentToolCallID: call))))
            session.emit(.turnCompleted(outcome: .completed, error: nil))
            #expect(await EngineHarness.eventually { engine.thread(threadID)?.turns.last?.checkpoint != nil })
        }
        #expect(engine.thread(threadID)?.subagents.map(\.id) == ["Scout", "Reader"])

        let second = try #require(engine.thread(threadID)?.turns[1])
        _ = try await engine.revert(threadID, toBeforeTurn: second.id, restoreFiles: false)
        // omp's new session can hand out "Reader" again: the old one must not absorb it.
        #expect(engine.thread(threadID)?.subagents.map(\.id) == ["Scout"])

        // The rewound session hands out the kept "Scout" name again for a new subagent: it gets
        // its own entry, and the new name's events and messages go to it, not the old one.
        let session = try #require(driver.session)
        session.emit(.subagent(id: "Scout", .updated(SubagentInfo(agent: "scout", status: .running, sessionFile: "/s2/Scout.jsonl", parentToolCallID: "call-3"))))
        session.emit(.subagent(id: "Scout", .runStarted(message: "new work")))
        #expect(await EngineHarness.eventually { engine.thread(threadID)?.subagents.count == 2 })
        let subagents = try #require(engine.thread(threadID)?.subagents)
        #expect(subagents.map(\.name) == ["Scout", "Scout"])
        #expect(Set(subagents.map(\.id)).count == 2)
        #expect(subagents[0].sessionFile == "/s1/Scout.jsonl" && subagents[0].turns.isEmpty && subagents[0].status == .completed)
        #expect(subagents[1].sessionFile == "/s2/Scout.jsonl" && subagents[1].turns.map(\.userMessage.text) == ["new work"])

        try await engine.steerSubagent(threadID, subagents[1].id, text: "go on")
        #expect(session.subagentSteers.map(\.id) == ["Scout"])
        await #expect(throws: EngineError.self) { try await engine.steerSubagent(threadID, subagents[0].id, text: "old") }
    }

    @Test func messagesAndStopsGoToARunningSubagentOnly() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine, driver)
        let session = try #require(driver.session)
        engine.apply(.subagent(id: "Reader", .updated(SubagentInfo(agent: "sonic", status: .running))), threadID: threadID)

        try await engine.steerSubagent(threadID, "Reader", text: "  also count them \n")
        try await engine.cancelSubagent(threadID, "Reader")
        #expect(session.subagentSteers.map(\.text) == ["also count them"])
        #expect(session.subagentCancels == ["Reader"])

        engine.apply(.subagent(id: "Reader", .updated(SubagentInfo(status: .completed))), threadID: threadID)
        await #expect(throws: EngineError.self) {
            try await engine.steerSubagent(threadID, "Reader", text: "one more")
        }
        try await engine.cancelSubagent(threadID, "Reader")
        #expect(session.subagentSteers.count == 1)
        #expect(session.subagentCancels == ["Reader"])
    }

    @Test func theSessionsEndAbortsItsRunningSubagents() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = try await Self.liveThread(engine, driver)
        engine.apply(.subagent(id: "Reader", .updated(SubagentInfo(agent: "sonic", status: .running))), threadID: threadID)
        engine.apply(.subagent(id: "Reader", .runStarted(message: "read the files")), threadID: threadID)
        engine.apply(.subagent(id: "Reader", .itemUpdated(TurnItem(id: "t1", kind: .command(CommandExecution(command: "cat a.txt")), status: .running))), threadID: threadID)
        engine.apply(.subagent(id: "Done", .updated(SubagentInfo(agent: "scout", status: .completed))), threadID: threadID)

        driver.session?.emit(.sessionEnded(error: "omp exited"))
        #expect(await EngineHarness.eventually { engine.subagent(threadID, "Reader")?.status == .aborted })
        let reader = try #require(engine.subagent(threadID, "Reader"))
        #expect(reader.turns.last?.status == .interrupted)
        #expect(reader.turns.last?.items.first?.status == .interrupted)
        #expect(engine.subagent(threadID, "Done")?.status == .completed)
    }

    @Test func runningSubagentsComeBackAbortedAfterACrash() throws {
        var thread = AgentThread(projectID: nil, modelSelection: .default(for: .omp))
        let run = Turn(ordinal: 1, userMessage: UserMessage(text: "go"), modelSelection: thread.modelSelection, items: [
            TurnItem(id: "t1", kind: .command(CommandExecution(command: "ls")), status: .running),
        ])
        thread.subagents = [Subagent(id: "Reader", agent: "sonic", turns: [run])]

        let recovered = JSONFileThreadStore.recovered(thread)
        let subagent = try #require(recovered.subagents.first)
        #expect(subagent.status == .aborted)
        #expect(subagent.turns.first?.status == .interrupted)
        #expect(subagent.turns.first?.items.first?.status == .interrupted)
    }

    @Test func threadFilesWithoutSubagentsStillLoad() throws {
        let thread = AgentThread(projectID: nil, title: "Old", modelSelection: .default(for: .omp))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
        object.removeValue(forKey: "subagents")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentThread.self, from: data)
        #expect(decoded.title == "Old")
        #expect(decoded.subagents.isEmpty)
    }
}
