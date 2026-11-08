import AppKit
import Testing
@testable import Soprano

/// Stands in for an agent's ACP server: answers `initialize` and the session
/// methods at once and holds every `session/prompt` until the test answers it.
@MainActor
final class FakeACPAgent: JSONRPCPeer {
    var onNotification: ((String, JSONValue) -> Void)?
    var onRequest: ((String, JSONValue, @escaping @MainActor (Result<JSONValue, JSONRPCError>) -> Void) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    var requests: [(method: String, params: JSONValue)] = []
    var notifications: [(method: String, params: JSONValue)] = []
    var loadError: JSONRPCError?
    private var prompts: [CheckedContinuation<JSONValue, Error>] = []

    func start() throws {}

    func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        requests.append((method, params))
        switch method {
        case "initialize":
            return ["protocolVersion": 1, "agentCapabilities": ["loadSession": true], "_meta": ["steering": ["supported": true]]]
        case "session/new":
            return ["sessionId": "new-session", "configOptions": [
                ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "a/one",
                 "options": [["value": "a/one", "name": "One"], ["value": "a/two", "name": "Two"]]],
            ]]
        case "session/load":
            if let loadError { throw loadError }
            return [:]
        case "session/prompt":
            return try await withCheckedThrowingContinuation { prompts.append($0) }
        default:
            return [:]
        }
    }

    func notify(_ method: String, params: JSONValue) {
        notifications.append((method, params))
    }

    private(set) var isTerminated = false
    private var hasExited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Like a real agent, the process outlives the signal until `exit`.
    func terminate() {
        isTerminated = true
    }

    func waitForExit() async {
        guard !hasExited else { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    var waitingPrompts: Int { prompts.count }

    func endTurn(_ stopReason: String = "end_turn") {
        prompts.removeFirst().resume(returning: ["stopReason": .string(stopReason)])
    }

    func send(_ update: JSONValue) {
        onNotification?("session/update", ["sessionId": "new-session", "update": update])
    }

    /// Sends the agent's request and returns what the session answers.
    func ask(_ method: String, _ params: JSONValue) -> () -> JSONValue? {
        var answer: JSONValue?
        onRequest?(method, params) { result in answer = try? result.get() }
        return { answer }
    }

    func exit(status: Int32, stderr: String) {
        let waiting = prompts
        prompts.removeAll()
        waiting.forEach { $0.resume(throwing: JSONRPCError.closed) }
        hasExited = true
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
        onExit?(status, stderr)
    }

    func methods() -> [String] { requests.map(\.method) }
}

@MainActor
struct AgentChatSessionTests {
    private func makeSession() -> (AgentChatSession, FakeACPAgent, () -> [AgentChatEvent]) {
        let agent = FakeACPAgent()
        let launch = AgentChatLaunch(
            profileId: "omp", agentName: "omp", shell: "/bin/zsh", arguments: [],
            environment: [:], workingDirectory: "/work/repo", toolStyle: .omp
        )
        let session = AgentChatSession(launch: launch, makePeer: { _ in agent })
        var events: [AgentChatEvent] = []
        session.onEvent = { events.append($0) }
        return (session, agent, { events })
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func aNewChatOpensASessionAndReportsItsConversationAndSettings() async {
        let (session, agent, events) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }

        #expect(agent.methods() == ["initialize", "session/new"])
        #expect(agent.requests[1].params["cwd"] == "/work/repo")
        #expect(session.sessionId == "new-session")
        #expect(session.configOptions.map(\.currentName) == ["One"])
        #expect(events().contains(.conversation(id: "new-session", cwd: "/work/repo")))
        #expect(events().last == .status(.idle, waitingReason: nil, notify: false, message: nil))
    }

    @Test func reopeningAConversationLoadsItAndFallsBackToANewOneWhenItIsGone() async {
        let (session, agent, _) = makeSession()
        session.start(resuming: "old-session")
        await settle { session.phase == .ready }
        #expect(agent.methods() == ["initialize", "session/load"])
        #expect(session.sessionId == "old-session")

        let (missing, gone, _) = makeSession()
        gone.loadError = JSONRPCError(code: -32_002, message: "Resource not found: old-session")
        missing.start(resuming: "old-session")
        await settle { missing.phase == .ready }
        #expect(gone.methods() == ["initialize", "session/load", "session/new"])
        #expect(missing.sessionId == "new-session")
        #expect(missing.thread.preamble.first?.kind == .error(
            message: "Could not reopen the conversation: Resource not found: old-session"
        ))
    }

    @Test func promptsSentDuringATurnWaitAndGoOutWhenItEnds() async {
        let (session, agent, events) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }

        #expect(session.send("First"))
        await settle { agent.waitingPrompts == 1 }
        #expect(session.phase == .working)
        #expect(session.send("Second"))
        #expect(session.queuedPrompts == ["Second"])

        agent.send(["sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": ["type": "text", "text": "Done."]])
        agent.endTurn()
        await settle { agent.waitingPrompts == 1 && session.queuedPrompts.isEmpty }

        #expect(session.thread.turns.map(\.userMessage.text) == ["First", "Second"])
        #expect(session.thread.turns[0].items.map(\.kind) == [.assistantMessage(text: "Done.", isFinal: true)])
        #expect(session.thread.turns[0].status == .completed)
        #expect(events().contains(.status(.waiting, waitingReason: .turnEnded, notify: true, message: "Done.")))
        let sent = agent.requests.filter { $0.method == "session/prompt" }.map { $0.params["prompt"]?.array?.first?["text"] }
        #expect(sent == ["First", "Second"])
    }

    @Test func steeringSendsIntoTheRunningTurnAndEscapeCancelsIt() async {
        let (session, agent, _) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        session.send("Refactor")
        await settle { agent.waitingPrompts == 1 }

        #expect(session.steer("Keep the tests"))
        await settle { agent.methods().contains("_session/steering") }
        #expect(session.queuedPrompts.isEmpty)
        #expect(session.thread.turns.last?.steers.map(\.text) == ["Keep the tests"])

        session.cancel()
        #expect(agent.notifications.map(\.method) == ["session/cancel"])
        #expect(session.thread.activeTurn?.stopRequestedAt != nil)
        agent.endTurn("cancelled")
        await settle { session.phase == .ready }
        #expect(session.thread.turns.last?.status == .interrupted)
        #expect(session.thread.turns.last?.stopRequestedAt == nil)
    }

    @Test func stoppingATurnKeepsQueuedPromptsUntilTheNextTurnEnds() async {
        let (session, agent, _) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        session.send("Long task")
        await settle { agent.waitingPrompts == 1 }
        session.send("Follow-up")

        session.cancel()
        agent.endTurn("cancelled")
        await settle { session.phase == .ready }
        // Give a wrongly dispatched queue the chance to show.
        for _ in 0..<10 { await Task.yield() }
        #expect(session.phase == .ready)
        #expect(agent.waitingPrompts == 0)
        #expect(session.queuedPrompts == ["Follow-up"])

        session.send("Something else first")
        await settle { agent.waitingPrompts == 1 }
        #expect(session.queuedPrompts == ["Follow-up"])
        agent.endTurn()
        await settle { session.queuedPrompts.isEmpty && agent.waitingPrompts == 1 }
        let sent = agent.requests.filter { $0.method == "session/prompt" }.map { $0.params["prompt"]?.array?.first?["text"] }
        #expect(sent == ["Long task", "Something else first", "Follow-up"])
    }

    @Test func aPermissionRequestWaitsForThePersonsChoiceAndReturnsIt() async throws {
        let (session, agent, events) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        session.send("List files")
        await settle { agent.waitingPrompts == 1 }

        let answer = agent.ask("session/request_permission", [
            "sessionId": "new-session",
            "toolCall": ["toolCallId": "t1", "title": "rm -rf build", "kind": "execute", "rawInput": ["command": "rm -rf build"]],
            "options": [
                ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"],
                ["optionId": "reject_once", "name": "Reject", "kind": "reject_once"],
            ],
        ])
        guard case .permission(let permission) = session.interaction else {
            Issue.record("No permission card")
            return
        }
        #expect(permission.title == "rm -rf build")
        #expect(permission.detail == nil)
        #expect(permission.options.map(\.name) == ["Allow once", "Reject"])
        #expect(answer() == nil)
        #expect(events().last == .status(.waiting, waitingReason: .approval, notify: true, message: "rm -rf build"))
        #expect(session.thread.activeTurn?.pendingApproval?.kind == .command)
        #expect(session.thread.activeTurn?.pendingApproval?.detail == "rm -rf build")

        session.choosePermissionOption("reject_once")
        #expect(answer() == ["outcome": ["outcome": "selected", "optionId": "reject_once"]])
        #expect(session.interaction == nil)
        #expect(events().last == .status(.running, waitingReason: nil, notify: false, message: nil))
        // The turn keeps what was asked and the answer.
        let item = try #require(session.thread.activeTurn?.items.last)
        guard case let .approval(request) = item.kind else {
            Issue.record("No approval item")
            return
        }
        #expect(request.decision == .decline)
        #expect(item.status == .declined)
        #expect(session.thread.activeTurn?.pendingApproval == nil)
    }

    @Test func approveAndDeclinePickAllowOnceAndRejectOnceAndMoreHoldsTheRest() {
        let options: [ApprovalOption] = [
            ApprovalOption(id: "always", name: "Always allow", kind: "allow_always"),
            ApprovalOption(id: "once", name: "Allow once", kind: "allow_once"),
            ApprovalOption(id: "no", name: "Reject", kind: "reject_once"),
            ApprovalOption(id: "never", name: "Always reject", kind: "reject_always"),
        ]
        #expect(options.approveOption?.id == "once")
        #expect(options.declineOption?.id == "no")
        #expect(options.moreOptions.map(\.name) == ["Always allow", "Always reject"])
        #expect(ApprovalDecision.of(optionKind: "allow_always") == .acceptForSession)
        #expect(ApprovalDecision.of(optionKind: "reject_always") == .decline)
    }

    @Test func aQuestionFormBecomesFieldsInOrderWithTheirOwnAnswerKeys() throws {
        let schema = try JSONValue(parsing: Data(#"""
        {"type":"object","properties":{
          "q10":{"type":"string","title":"Last?","oneOf":[{"const":"Yes","title":"Yes"}]},
          "q0":{"type":"string","title":"Which database?","description":"Storage","oneOf":[{"const":"SQLite","title":"SQLite","description":"Local file"},{"const":"Postgres","title":"Postgres"}],"default":"SQLite"},
          "q0__other":{"type":"string","title":"Other (type your own)"},
          "q2":{"type":"array","title":"Which targets?","items":{"anyOf":[{"const":"macOS","title":"macOS"},{"const":"Linux","title":"Linux"}]}}
        }}
        """#.utf8))
        let question = try #require(AgentChatQuestion(message: "Answer 3 questions", schema: schema))
        #expect(question.fields.map(\.key) == ["q0", "q2", "q10"])
        let first = question.fields[0]
        #expect(first.title == "Which database?")
        #expect(first.detail == "Storage")
        #expect(first.choices.map(\.label) == ["SQLite", "Postgres"])
        #expect(first.choices[0].detail == "Local file")
        #expect(first.otherKey == "q0__other")
        #expect(first.recommended == "SQLite")
        #expect(question.fields[1].allowsMultiple)
        #expect(question.fields[1].otherKey == nil)
    }

    @Test func anAnsweredQuestionGoesBackAsTheFormsContent() async {
        let (session, agent, _) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        let answer = agent.ask("elicitation/create", [
            "mode": "form", "sessionId": "new-session", "message": "Pick one",
            "requestedSchema": ["type": "object", "properties": [
                "q0": ["type": "string", "title": "Pick one", "oneOf": [["const": "A", "title": "A"]]],
            ]],
        ])
        session.answerQuestion(["q0": "A"])
        #expect(answer() == ["action": "accept", "content": ["q0": "A"]])
        guard case let .userInput(request)? = session.thread.turns.last?.items.last?.kind else {
            Issue.record("No question item")
            return
        }
        #expect(request.answers == ["q0": ["A"]])
    }

    @Test func answersByQuestionBecomeTheFormsContentWithTypedAnswersUnderTheOtherKey() throws {
        let schema = try JSONValue(parsing: Data(#"""
        {"type":"object","properties":{
          "q0":{"type":"string","title":"Which database?","description":"Storage","oneOf":[{"const":"SQLite","title":"SQLite"}]},
          "q0__other":{"type":"string","title":"Other (type your own)"},
          "q1":{"type":"array","title":"Which targets?","items":{"anyOf":[{"const":"macOS","title":"macOS"},{"const":"Linux","title":"Linux"}]}},
          "q2":{"type":"string","title":"Anything else?"}
        }}
        """#.utf8))
        let question = try #require(AgentChatQuestion(message: "Answer 3 questions", schema: schema))
        let request = question.userInputRequest(id: "r")
        #expect(request.questions.map(\.header) == ["Storage", "", ""])
        #expect(request.questions.map(\.allowsOther) == [true, false, true])

        let picked = question.content(for: ["q0": ["SQLite"], "q1": ["macOS", "Linux"], "q2": ["No"]])
        #expect(picked == ["q0": "SQLite", "q1": ["macOS", "Linux"], "q2": "No"])
        let typed = question.content(for: ["q0": ["DuckDB"], "q1": [], "q2": ["No"]])
        #expect(typed == ["q0__other": "DuckDB", "q1": [], "q2": "No"])
        #expect(question.answers(from: typed) == ["q0": ["DuckDB"], "q1": [], "q2": ["No"]])
    }

    @Test func anAgentThatExitsMidTurnEndsTheTurnAndReportsWhy() async {
        let (session, agent, events) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        session.send("Go")
        await settle { agent.waitingPrompts == 1 }
        agent.send(["sessionUpdate": "tool_call", "toolCallId": "t1", "name": "bash", "title": "$ make", "status": "pending", "rawInput": ["command": "make"]])

        agent.exit(status: 1, stderr: "boot\nerror: Config overlay not found")
        await settle { !session.isRunning }

        #expect(session.thread.turns.last?.items.first?.status == .interrupted)
        let reason = "The agent exited with status 1:\nboot\nerror: Config overlay not found"
        #expect(session.phase == .stopped(reason))
        #expect(session.thread.turns.last?.items.last?.kind == .error(message: reason))
        #expect(events().last == .status(.error, waitingReason: nil, notify: true, message: reason))
        #expect(!session.send("Again"))
    }

    enum RestartPath: CaseIterable, Sendable {
        case restart
        case stopThenRestart
        case restartTwice
    }

    @Test(arguments: RestartPath.allCases)
    func restartingWaitsForTheOldAgentToExitThenReopensTheConversation(path: RestartPath) async {
        let launch = AgentChatLaunch(
            profileId: "omp", agentName: "omp", shell: "/bin/zsh", arguments: [],
            environment: [:], workingDirectory: "/work/repo", toolStyle: .omp
        )
        let first = FakeACPAgent()
        let second = FakeACPAgent()
        var peers = [first, second]
        let session = AgentChatSession(launch: launch, makePeer: { _ in peers.removeFirst() })
        var events: [AgentChatEvent] = []
        session.onEvent = { events.append($0) }
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        let reported = events.count

        switch path {
        case .restart:
            session.restart()
        case .stopThenRestart:
            session.stop()
            session.restart()
        case .restartTwice:
            session.restart()
            for _ in 0..<5 { await Task.yield() }
            session.restart()
        }
        #expect(first.isTerminated)
        // The old process still holds the conversation: nothing opens it yet.
        for _ in 0..<10 { await Task.yield() }
        #expect(second.requests.isEmpty)
        #expect(session.phase == .starting)

        first.exit(status: 0, stderr: "")
        await settle { session.phase == .ready }
        #expect(second.methods() == ["initialize", "session/load"])
        #expect(second.requests.last?.params["sessionId"] == "new-session")
        // Only a stop the person asked for reports one.
        let stopped = events.dropFirst(reported).contains(.status(.stopped, waitingReason: nil, notify: false, message: nil))
        #expect(stopped == (path == .stopThenRestart))
    }

    @Test func theChatLaunchesTheAgentsACPServerThroughTheLoginShell() throws {
        let profile = AgentProfile(
            id: "omp", name: "omp", icon: "", color: "", description: "",
            command: "omp", args: ["--model", "it's"], env: ["EXTRA": "1"]
        )
        let launch = try #require(AgentChatLaunch.forProfile(
            profile, cwd: "/work/repo", loginShell: "/bin/zsh", accounts: AccountLaunchState(),
            environment: ["PATH": "/usr/bin", "SOPRANO_PANE_ID": "pane-1"]
        ))
        #expect(launch.shell == "/bin/zsh")
        #expect(launch.arguments == ["-lic", #"exec 'omp' 'acp' '--model' 'it'\''s'"#])
        #expect(launch.workingDirectory == "/work/repo")
        #expect(launch.environment["SOPRANO_PANE_ID"] == nil)
        #expect(launch.environment["SOPRANO_AGENT_PROFILE"] == "omp")
        #expect(launch.environment["EXTRA"] == "1")
        #expect(launch.environment["PATH"] == "/usr/bin")

        let homeLaunch = try #require(AgentChatLaunch.forProfile(profile, cwd: nil, accounts: AccountLaunchState(), environment: [:]))
        #expect(homeLaunch.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(AgentChatLaunch.forProfile(DefaultAgents.codex, cwd: nil) == nil)
    }

    @Test func theAgentsCommandsFeedTheSlashMenuAndCompactSendsItsCommand() async {
        let (session, agent, _) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        #expect(!session.canCompact)
        agent.send(["sessionUpdate": "available_commands_update", "availableCommands": [
            ["name": "compact", "description": "Compact the conversation", "input": ["hint": "[focus]"]],
            ["name": "review", "description": ""],
        ]])
        #expect(session.commands == [
            AgentChatCommand(name: "compact", description: "Compact the conversation", hint: "[focus]"),
            AgentChatCommand(name: "review", description: nil, hint: nil),
        ])
        #expect(session.commands[0].insertText == "/compact ")
        #expect(session.canCompact)

        session.compact()
        await settle { agent.waitingPrompts == 1 }
        #expect(agent.requests.last?.params["prompt"]?.array?.first?["text"] == "/compact")
        #expect(!session.canCompact)
    }

    @Test func aQueuedPromptCanBeRemovedOrSteeredInByItsId() async {
        let (session, agent, _) = makeSession()
        session.start(resuming: nil)
        await settle { session.phase == .ready }
        session.send("Work")
        await settle { agent.waitingPrompts == 1 }
        session.send("Later")
        session.send("Now")
        #expect(session.thread.queue.map(\.text) == ["Later", "Now"])
        let ids = session.thread.queue.map(\.id)
        #expect(Set(ids).count == 2)

        session.removeQueuedPrompt(id: ids[0])
        session.sendQueuedPromptNow(id: ids[1])
        #expect(session.queuedPrompts.isEmpty)
        await settle { agent.methods().contains("_session/steering") }
        #expect(session.thread.activeTurn?.steers.map(\.text) == ["Now"])
    }
}
