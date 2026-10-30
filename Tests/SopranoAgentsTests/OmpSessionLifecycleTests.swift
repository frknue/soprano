import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OmpSession` against a fake `omp --mode rpc-ui` that answers like omp 18.14 (recorded live):
/// `ready`, responses echoing the command id, a session tree for `get_entries` / `fork` /
/// `new_session` (user messages `u<n>`, answers `a<n>`), `prompt` acked then ended by
/// `prompt_result`, a
/// tool approval as an `extension_ui_request` `select`, and a prompt that yields with
/// `sessionSettled:false` while a background job is still running.
@MainActor
struct OmpSessionLifecycleTests {
    private static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    log = os.environ["FAKE_OMP_LOG"]
    def record(o):
        with open(log, "a") as f:
            f.write(json.dumps(o) + "\n")
    record({"cwd": os.getcwd(), "args": args})
    session = args[args.index("--resume") + 1] if "--resume" in args else os.path.join(os.getcwd(), "fake-session.jsonl")
    def out(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def ok(msg, data=None):
        o = {"type": "response", "command": msg["type"], "success": True}
        if "id" in msg: o["id"] = msg["id"]
        if data is not None: o["data"] = data
        out(o)
    out({"type": "ready", "protocolVersion": 1, "supportedProtocolVersions": [1, 2], "maxFrameBytes": 1048576, "maxReassembledFrameBytes": 67108864})
    prompt = None
    slow = None
    busy = False
    entries = [{"type": "model_change", "id": "m0", "parentId": None}]
    leaf = "m0"
    turns = 0
    sessions = 0
    def add(entry):
        global leaf
        entry["parentId"] = leaf
        entries.append(entry)
        leaf = entry["id"]
    steers = 0
    def user(text, steering=False):
        global turns
        turns += 1
        if text.startswith("/skill:"):
            # omp records a skill invocation as its expanded body, not the submitted text.
            text = "Skill instructions for " + text[len("/skill:"):]
        message = {"role": "user", "attribution": "user", "content": [{"type": "text", "text": text}]}
        if steering: message["steering"] = True
        add({"type": "message", "id": "u%d" % turns, "message": message})
        add({"type": "custom", "id": "c%d" % turns})
    def finish(status):
        global prompt
        add({"type": "message", "id": "a%d" % turns, "message": {"role": "assistant", "content": [{"type": "text", "text": "all done"}]}})
        out({"type": "message_update", "messageId": "msg-3", "message": {"role": "assistant"}, "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "all done"}})
        out({"type": "message_update", "messageId": "msg-3", "message": {"role": "assistant"}, "assistantMessageEvent": {"type": "text_end", "contentIndex": 0, "content": "all done"}})
        out({"type": "prompt_result", "id": prompt, "agentInvoked": True, "status": status, "sessionSettled": True})
        prompt = None
    for line in sys.stdin:
        msg = json.loads(line)
        record({"recv": msg})
        kind = msg.get("type")
        if kind == "get_state":
            # omp's configured model is opus; a resumed session runs the model saved in it.
            model = "claude-haiku-5-5" if "--resume" in args else "claude-opus-5-5"
            ok(msg, {"model": {"provider": "anthropic", "id": model, "name": model, "contextWindow": 100000},
                     "thinkingLevel": "low", "sessionFile": session, "sessionId": "s1", "fastModeEnabled": False})
        elif kind == "set_ask_dialog" and os.environ.get("FAKE_REJECT_ASK"):
            out({"type": "response", "id": msg.get("id"), "command": kind, "success": False, "error": "Unknown command: set_ask_dialog"})
        elif kind == "get_entries":
            ok(msg, {"entries": entries, "leafId": leaf})
        elif kind == "fork":
            keep, cursor = [], msg["entryId"]
            byid = {e["id"]: e for e in entries}
            while cursor:
                keep.append(byid[cursor]); cursor = byid[cursor]["parentId"]
            entries = list(reversed(keep)); leaf = msg["entryId"]
            sessions += 1; session = os.path.join(os.getcwd(), "fork-%d.jsonl" % sessions)
            ok(msg, {"cancelled": False})
        elif kind == "steer":
            steers += 1
            add({"type": "message", "id": "s%d" % steers, "message": {"role": "user", "attribution": "user", "steering": True,
                 "content": [{"type": "text", "text": msg["message"]}]}})
            ok(msg)
        elif kind == "new_session":
            entries = []; leaf = None
            sessions += 1; session = os.path.join(os.getcwd(), "new-%d.jsonl" % sessions)
            ok(msg, {"cancelled": False})
        elif kind == "prompt" and busy:
            # A woken background run is streaming: omp refuses a plain prompt.
            if "streamingBehavior" not in msg:
                out({"type": "response", "id": msg["id"], "command": "prompt", "success": False,
                     "error": "Agent is already processing. Use steer() or followUp() to queue messages, or wait for completion."})
            else:
                prompt = msg["id"]
                ok(msg)
                user(msg["message"], steering=True)
                busy = False
                finish("completed")
        elif kind == "prompt":
            prompt = msg["id"]
            ok(msg)
            user(msg["message"])
            if "slow" in msg["message"]:
                # Still running when Stop arrives; a background job is pending.
                out({"type": "message_update", "messageId": "msg-1", "message": {"role": "assistant"}, "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "job started"}})
                slow = "aborted" if "aborted" in msg["message"] else "completed"
            elif "background" in msg["message"]:
                # Yield with a background job pending, as omp does after an async bash/task.
                out({"type": "message_update", "messageId": "msg-1", "message": {"role": "assistant"}, "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "job started"}})
                out({"type": "agent_end", "messages": [], "isTerminal": True, "yielded": True})
                out({"type": "prompt_result", "id": prompt, "agentInvoked": True, "status": "completed", "sessionSettled": False})
                prompt = None
                if "wakes" in msg["message"]:
                    # The job finishes and wakes the agent: a follow-up run in the same turn.
                    out({"type": "agent_start"})
                    out({"type": "tool_execution_start", "toolCallId": "t2", "toolName": "write", "args": {"path": "late.txt", "content": "x\n"}})
                    out({"type": "extension_ui_request", "id": "ui-2", "method": "select", "title": "Allow tool: write\nPath: late.txt",
                         "options": ["Approve", "Approve write for this session", "Deny"]})
            elif "approve" in msg["message"]:
                out({"type": "tool_execution_start", "toolCallId": "t1", "toolName": "bash", "args": {"command": "ls"}})
                out({"type": "extension_ui_request", "id": "ui-1", "method": "select", "title": "Allow tool: bash\nCommand: ls",
                     "options": ["Approve", "Approve bash for this session", "Deny"]})
            else:
                finish("completed")
        elif kind == "extension_ui_response" and msg["id"] == "ui-2":
            out({"type": "tool_execution_end", "toolCallId": "t2", "toolName": "write", "isError": False,
                 "result": {"content": [{"type": "text", "text": "Successfully wrote 2 bytes to late.txt"}], "details": {}}})
            out({"type": "message_update", "messageId": "msg-2", "message": {"role": "assistant"}, "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "late file written"}})
            out({"type": "message_update", "messageId": "msg-2", "message": {"role": "assistant"}, "assistantMessageEvent": {"type": "text_end", "contentIndex": 0, "content": "late file written"}})
            out({"type": "agent_end", "messages": [], "isTerminal": True, "yielded": True})
            out({"type": "session_settled"})
        elif kind == "extension_ui_response":
            out({"type": "tool_execution_end", "toolCallId": "t1", "toolName": "bash", "isError": False,
                 "result": {"content": [{"type": "text", "text": "a.txt\n"}], "details": {}}})
            finish("completed")
        elif kind == "abort" and slow:
            # omp yields after the abort; the background job keeps the session unsettled and
            # no `session_settled` follows for a long time.
            ok(msg)
            out({"type": "agent_end", "messages": [], "isTerminal": False, "yielded": True})
            out({"type": "prompt_result", "id": prompt, "agentInvoked": True, "status": slow, "sessionSettled": False})
            prompt = None
            slow = None
            # The background job finishes and wakes the agent anyway.
            out({"type": "agent_start"})
            busy = True
        elif kind == "abort":
            ok(msg)
            if prompt: finish("aborted")
        elif "id" in msg:
            ok(msg, {})
    """#

    private struct Fake {
        let executable: String
        let log: String
        let directory: URL

        private func records() -> [JSONValue] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
        }

        func launches() -> [[String]] {
            records().compactMap { $0["args"]?.arrayValue?.compactMap(\.stringValue) }
        }

        func received(_ type: String) -> [JSONValue] {
            records().compactMap { $0["recv"] }.filter { $0["type"]?.stringValue == type }
        }
    }

    private func makeFake(rejectAskDialog: Bool = false) throws -> Fake {
        let directory = EngineHarness.temporaryDirectory()
        let script = directory.appendingPathComponent("fakeomp.py")
        let log = directory.appendingPathComponent("launches.log").path
        try Self.fakeCLI.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("omp")
        let reject = rejectAskDialog ? "FAKE_REJECT_ASK=1 " : ""
        try "#!/bin/sh\n\(reject)FAKE_OMP_LOG='\(log)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return Fake(executable: wrapper.path, log: log, directory: directory)
    }

    private func config(cwd: String, runtime: RuntimeMode = .approvalRequired, resumeID: String? = nil) -> SessionConfig {
        SessionConfig(cwd: cwd, modelSelection: .default(for: .omp), runtimeMode: runtime, interactionMode: .build, resumeID: resumeID)
    }

    private func input(_ text: String, runtime: RuntimeMode = .approvalRequired) -> TurnInput {
        TurnInput(text: text, attachments: [], modelSelection: .default(for: .omp), runtimeMode: runtime, interactionMode: .build)
    }

    /// Collects session events on a background task.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ProviderEvent] = []

        init(_ session: OmpSession) {
            Task { for await event in session.events { self.append(event) } }
        }

        var events: [ProviderEvent] { lock.withLock { stored } }
        private func append(_ event: ProviderEvent) { lock.withLock { stored.append(event) } }

        func wait(_ seconds: Double = 10, until condition: @Sendable ([ProviderEvent]) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition(events) {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    nonisolated private static func completed(_ events: [ProviderEvent]) -> Bool {
        events.contains { if case .turnCompleted = $0 { true } else { false } }
    }

    @Test func aMissingWorkspaceIsRefusedBeforeOmpIsStarted() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let missing = "/tmp/soprano-agents-deleted-\(UUID().uuidString)"

        await #expect(throws: ProviderError.workspaceMissing(missing)) {
            _ = try await session.start(config(cwd: missing))
        }

        #expect(fake.launches().isEmpty)
    }

    @Test func aFreshSessionHandshakesAndReportsItsSessionFile() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })

        let id = try await session.start(config(cwd: fake.directory.path))
        await session.close()

        let args = try #require(fake.launches().first)
        #expect(id.hasSuffix("\(fake.directory.lastPathComponent)/fake-session.jsonl"))
        #expect(args == ["--mode", "rpc-ui", "--cwd", fake.directory.path, "--approval-mode", "always-ask"])
        #expect(fake.received("negotiate_protocol").first?["protocolVersion"] == 2)
        #expect(fake.received("set_ask_dialog").first?["enabled"] == true)
        #expect(fake.received("set_event_filter").first?["messageUpdates"] == "delta")
    }

    @Test func aSessionStartsWithTheAccountOverlayItIsHanded() async throws {
        let fake = try makeFake()
        let overlay = fake.directory.appendingPathComponent("omp-accounts.yml").path
        let session = OmpSession(
            executablePath: { fake.executable },
            launchAdjustments: { ProviderLaunchAdjustments(arguments: ["--config", overlay]) }
        )

        _ = try await session.start(config(cwd: fake.directory.path))
        await session.close()

        let args = try #require(fake.launches().first)
        #expect(args == ["--config", overlay, "--mode", "rpc-ui", "--cwd", fake.directory.path, "--approval-mode", "always-ask"])
    }

    @Test func aSavedSessionIsResumedOnlyWhenItsFileExists() async throws {
        let fake = try makeFake()
        let gone = fake.directory.appendingPathComponent("gone.jsonl").path
        let saved = fake.directory.appendingPathComponent("saved.jsonl").path
        try "{}\n".write(toFile: saved, atomically: true, encoding: .utf8)

        let first = OmpSession(executablePath: { fake.executable })
        _ = try await first.start(config(cwd: fake.directory.path, resumeID: gone))
        await first.close()
        let second = OmpSession(executablePath: { fake.executable })
        let resumed = try await second.start(config(cwd: fake.directory.path, resumeID: saved))
        await second.close()

        let launches = fake.launches().filter { $0.contains("rpc-ui") }
        #expect(launches.count == 2)
        #expect(!launches[0].contains("--resume"))
        #expect(launches[1].suffix(2) == ["--resume", saved])
        #expect(resumed == saved)
    }

    @Test func aPromptStreamsItsAnswerAndCompletesTheTurn() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(cwd: fake.directory.path))

        let turnID = try await session.startTurn(input("hello"))
        let finished = await recorder.wait(until: Self.completed)
        await session.close()

        let prompt = try #require(fake.received("prompt").first)
        #expect(prompt["message"] == "hello")
        #expect(finished)
        let events = recorder.events
        // The native turn id is the prompt's session entry, reported before the turn ends.
        #expect(turnID == nil)
        let started = try #require(events.firstIndex(of: .turnStarted(providerTurnID: "u1")))
        let completed = try #require(events.firstIndex(of: .turnCompleted(outcome: .completed, error: nil)))
        #expect(started < completed)
        #expect(events.contains(.assistantDelta(itemID: "msg-3:0", delta: "all done", isFinal: false)))
        #expect(events.contains { event in
            if case let .itemUpdated(item) = event { item.id == "msg-3:0" && item.kind == .assistantMessage(text: "all done", isFinal: true) } else { false }
        })
        #expect(events.contains(.turnCompleted(outcome: .completed, error: nil)))
    }

    @Test func answeringAnApprovalWritesTheExactOptionLabel() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(cwd: fake.directory.path))

        _ = try await session.startTurn(input("approve this"))
        let asked = await recorder.wait { events in
            events.contains { if case .approvalRequested = $0 { true } else { false } }
        }
        await session.respond(toApproval: "ui-1", decision: .acceptForSession, feedback: nil)
        let finished = await recorder.wait(until: Self.completed)
        await session.close()

        #expect(asked && finished)
        #expect(fake.received("extension_ui_response") == [["type": "extension_ui_response", "id": "ui-1", "value": "Approve bash for this session"]])
        let command = recorder.events.compactMap { event -> TurnItem? in
            if case let .itemUpdated(item) = event, item.id == "t1" { return item }
            return nil
        }.last
        #expect(command?.status == .completed)
    }

    @Test func interruptingAbortsThePrompt() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(cwd: fake.directory.path))

        _ = try await session.startTurn(input("approve later"))
        _ = await recorder.wait { $0.contains { if case .approvalRequested = $0 { true } else { false } } }
        await session.interrupt()
        let finished = await recorder.wait(until: Self.completed)
        await session.close()

        #expect(finished)
        #expect(fake.received("abort").count == 1)
        #expect(recorder.events.contains(.turnCompleted(outcome: .interrupted, error: nil)))
    }

    @Test func anUnsettledYieldKeepsTheTurnOpenUntilBackgroundWorkHasFinished() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(cwd: fake.directory.path))

        _ = try await session.startTurn(input("start a background job; it wakes you"))
        let asked = await recorder.wait { $0.contains { if case .approvalRequested = $0 { true } else { false } } }
        let completedBeforeSettling = Self.completed(recorder.events)
        await session.respond(toApproval: "ui-2", decision: .accept, feedback: nil)
        let finished = await recorder.wait(until: Self.completed)
        await session.close()

        // The follow-up run's dialog reached the host instead of being cancelled, and the turn
        // stayed open (so nothing checkpoints or dequeues) until `session_settled`.
        #expect(asked && finished)
        #expect(!completedBeforeSettling)
        #expect(fake.received("extension_ui_response") == [["type": "extension_ui_response", "id": "ui-2", "value": "Approve"]])
        let events = recorder.events
        let completion = try #require(events.firstIndex(of: .turnCompleted(outcome: .completed, error: nil)))
        let lateWrite = try #require(events.lastIndex { if case let .itemUpdated(item) = $0 { item.id == "t2" && item.status == .completed } else { false } })
        #expect(lateWrite < completion)
        let finals = events.compactMap { event -> String? in
            if case let .itemUpdated(item) = event, case let .assistantMessage(text, true) = item.kind { return text }
            return nil
        }
        #expect(finals == ["late file written"])
    }

    @Test func stoppingWhileBackgroundWorkRunsEndsTheTurnAtOnce() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(cwd: fake.directory.path))

        _ = try await session.startTurn(input("start a background job"))
        _ = await recorder.wait { $0.contains(.assistantDelta(itemID: "msg-1:0", delta: "job started", isFinal: false)) }
        let completedBeforeStop = await recorder.wait(0.3, until: Self.completed)
        await session.interrupt()
        let finished = await recorder.wait(until: Self.completed)
        await session.close()

        #expect(!completedBeforeStop)
        #expect(finished)
        #expect(fake.received("abort").count == 1)
        #expect(recorder.events.contains(.turnCompleted(outcome: .interrupted, error: nil)))
    }

    @Test(arguments: ["aborted", "completed"])
    func stoppingBeforeTheYieldEndsTheTurnWithoutWaitingForBackgroundJobs(status: String) async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(cwd: fake.directory.path))

        // "completed": the yield raced the abort and omp reports the prompt as completed.
        _ = try await session.startTurn(input("slow background job \(status == "aborted" ? "aborted" : "")"))
        _ = await recorder.wait { $0.contains(.assistantDelta(itemID: "msg-1:0", delta: "job started", isFinal: false)) }
        await session.interrupt()
        let finished = await recorder.wait(3, until: Self.completed)
        // The job then wakes omp; the next message must still go through.
        let before = recorder.events.count
        _ = try await session.startTurn(input("hello after stop"))
        let next = await recorder.wait(3) { Self.completed(Array($0.dropFirst(before))) }
        await session.close()

        #expect(finished)
        #expect(recorder.events.contains(.turnCompleted(outcome: .interrupted, error: nil)))
        #expect(next)
        #expect(fake.received("prompt").last?["streamingBehavior"] == "steer")
    }

    @Test func aFailedStartShowsOmpsOwnErrorOnTheTurn() async throws {
        let directory = EngineHarness.temporaryDirectory()
        let broken = directory.appendingPathComponent("omp")
        try "#!/bin/sh\necho 'omp: no credentials for anthropic' >&2\nexit 3\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [.omp: OmpDriver(executablePath: { broken.path })],
            git: RecordingGit(),
            store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory()
        ), settings: EngineSettings(generateTitles: false))
        let project = engine.addProject(path: directory.path)

        let id = try await engine.launchThread(ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp)), text: "hi", attachments: [])
        let deadline = ContinuousClock.now + .seconds(10)
        while engine.thread(id)?.turns.last?.status == .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let turn = try #require(engine.thread(id)?.turns.last)
        #expect(turn.status == .failed)
        #expect(turn.failureMessage?.contains("no credentials for anthropic") == true)
    }

    /// Runs `texts` as completed turns and returns the session (left open).
    private func sessionWithTurns(_ fake: Fake, _ texts: [String], resumeID: String? = nil) async throws -> (OmpSession, Recorder) {
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(cwd: fake.directory.path, resumeID: resumeID))
        for text in texts {
            let before = recorder.events.count
            _ = try await session.startTurn(input(text))
            _ = await recorder.wait { Self.completed(Array($0.dropFirst(before))) }
        }
        return (session, recorder)
    }

    @Test func rewindingForksANewSessionFileThatEndsBeforeTheTurn() async throws {
        let fake = try makeFake()
        let (session, recorder) = try await sessionWithTurns(fake, ["one", "two", "three"])

        try await session.rollback(beforeTurn: 2, providerTurnID: "u2")
        try await session.rollback(beforeTurn: 1, providerTurnID: "u1")
        await session.close()

        // `fork` (unlike `navigate_tree`) writes a session file of its own, so the next
        // `--resume` cannot bring the dropped turns back. It keeps everything up to turn 1's
        // answer; before turn 1 nothing is worth keeping.
        #expect(fake.received("fork").map { $0["entryId"]?.stringValue } == ["a1"])
        #expect(fake.received("new_session").count == 1)
        #expect(fake.received("navigate_tree").isEmpty)
        let files = recorder.events.compactMap { if case let .conversationID(id) = $0 { URL(fileURLWithPath: id).lastPathComponent } else { nil } }
        #expect(files == ["fake-session.jsonl", "fork-1.jsonl", "new-2.jsonl"])
    }

    @Test func turnsWithoutAnEntryIdFallBackToCountingUserMessages() async throws {
        let fake = try makeFake()
        let (session, _) = try await sessionWithTurns(fake, ["one", "two"])

        try await session.rollback(beforeTurn: 2, providerTurnID: "prompt-2")
        await #expect(throws: ProviderError.message("omp's session has no record of turn 3, so the conversation cannot be rewound.")) {
            try await session.rollback(beforeTurn: 3, providerTurnID: nil)
        }
        await session.close()

        #expect(fake.received("fork").map { $0["entryId"]?.stringValue } == ["a1"])
    }

    @Test func aResumedSessionOnDefaultSwitchesToOmpsConfiguredModel() async throws {
        let fake = try makeFake()
        let saved = fake.directory.appendingPathComponent("saved.jsonl").path
        try "{}\n".write(toFile: saved, atomically: true, encoding: .utf8)

        let (session, _) = try await sessionWithTurns(fake, ["hello"], resumeID: saved)
        await session.close()

        // The saved session ran haiku; "default" means omp's configured model (opus), asked
        // from a throwaway process in the thread's folder.
        let switches = fake.received("set_model")
        #expect(switches.map { "\($0["provider"]?.stringValue ?? "")/\($0["modelId"]?.stringValue ?? "")" } == ["anthropic/claude-opus-5-5"])
        #expect(fake.launches().contains { $0.contains("--no-session") })
    }

    @Test func aBuildWithoutTheAskDialogStillStartsAndKeepsTheSelectFallback() async throws {
        let fake = try makeFake(rejectAskDialog: true)
        let (session, recorder) = try await sessionWithTurns(fake, ["hello"])
        await session.close()

        #expect(fake.received("set_ask_dialog").count == 1)
        #expect(recorder.events.contains(.turnCompleted(outcome: .completed, error: nil)))
    }

    @Test func editingFromARewrittenPromptRewindsOmpToJustBeforeIt() async throws {
        let fake = try makeFake()
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [.omp: OmpDriver(executablePath: { fake.executable })],
            git: RecordingGit(),
            store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory()
        ), settings: EngineSettings(generateTitles: false))
        let project = engine.addProject(path: fake.directory.path)
        func waitForTurn(_ id: String, _ ordinal: Int) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if let turn = engine.thread(id)?.turns.last, turn.ordinal == ordinal, turn.status != .running { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        let id = try await engine.launchThread(ThreadDraft(projectID: project.id, modelSelection: .default(for: .omp)), text: "one", attachments: [])
        await waitForTurn(id, 1)
        // omp stores a skill invocation as its expanded body, so its text never matches.
        try await engine.send(id, text: "/skill:review two", attachments: [])
        await waitForTurn(id, 2)
        try await engine.send(id, text: "three", attachments: [])
        await waitForTurn(id, 3)
        let thread = try #require(engine.thread(id))
        let message = try await engine.revert(id, toBeforeTurn: thread.turns[1].id, restoreFiles: false)

        #expect(message.text == "/skill:review two")
        #expect(engine.thread(id)?.turns.count == 1)
        // omp keeps turn 1 (up to its answer a1) and loses the skill turn and everything after.
        #expect(fake.received("fork").map { $0["entryId"]?.stringValue } == ["a1"])
        await engine.shutdown()
    }

    @Test func aSteerWithThePromptsOwnTextDoesNotMoveTheTurnsAnchor() async throws {
        let fake = try makeFake()
        let (session, recorder) = try await sessionWithTurns(fake, ["one"])

        _ = try await session.startTurn(input("approve again"))
        _ = await recorder.wait { $0.contains { if case .approvalRequested = $0 { true } else { false } } }
        try await session.steer(input("approve again"))
        await session.respond(toApproval: "ui-1", decision: .accept, feedback: nil)
        _ = await recorder.wait { $0.filter { if case .turnCompleted = $0 { true } else { false } }.count == 2 }
        await session.close()

        let anchors = recorder.events.compactMap { if case let .turnStarted(id) = $0 { id } else { nil } }
        #expect(anchors == ["u1", "u2"])
    }

    @Test func aTurnWhoseStartIsUnknownIsNeverRewoundByGuessing() async throws {
        let fake = try makeFake()
        let (session, _) = try await sessionWithTurns(fake, ["one", "two"])

        await #expect(throws: ProviderError.message("omp could not tell where turn 2 starts, so the conversation cannot be rewound safely.")) {
            try await session.rollback(beforeTurn: 2, providerTurnID: OmpProtocol.unresolvedTurnID)
        }
        await session.close()

        #expect(fake.received("fork").isEmpty && fake.received("new_session").isEmpty)
    }

    @Test func changingTheRuntimeModeRestartsOnTheSameSessionFile() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        let file = try await session.start(config(cwd: fake.directory.path))
        try "{}\n".write(toFile: file, atomically: true, encoding: .utf8)

        _ = try await session.startTurn(input("hello", runtime: .fullAccess))
        let finished = await recorder.wait(until: Self.completed)
        await session.close()

        let launches = fake.launches()
        #expect(finished)
        #expect(!recorder.events.contains { if case .sessionEnded(.some) = $0 { true } else { false } })
        #expect(launches.count == 2)
        #expect(launches.last?.contains("yolo") == true)
        #expect(launches.last?.suffix(2) == ["--resume", file])
    }
}
