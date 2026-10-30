import AppKit
import Testing
@testable import SopranoAgentsCore

/// `ClaudeSession` against a fake `claude` that answers like Claude Code 2.1.314 (recorded live):
/// a `"priority":"now"` message aborts the running request with `result` / `terminal_reason:
/// "aborted_tools"` (subtype success), then answers the steer with a second `result`.
@MainActor
struct ClaudeSessionLifecycleTests {
    private static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, os, sys, uuid
    args = sys.argv[1:]
    log = os.environ.get("FAKE_CLAUDE_LOG")
    if log:
        with open(log, "a") as f:
            f.write(json.dumps({"cwd": os.getcwd(), "args": args}) + "\n")
    sid = None
    for flag in ("--session-id", "--resume"):
        if flag in args:
            sid = args[args.index(flag) + 1]
    sid = sid or str(uuid.uuid4())
    def out(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def init():
        out({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": sid, "model": "x", "tools": [], "uuid": str(uuid.uuid4())})
    def text(message_id, value):
        out({"type": "assistant", "parent_tool_use_id": None, "session_id": sid, "uuid": str(uuid.uuid4()),
             "message": {"id": message_id, "type": "message", "role": "assistant", "model": "x",
                         "content": [{"type": "text", "text": value}], "usage": {"input_tokens": 1, "output_tokens": 1}}})
    def result(reason, value):
        out({"type": "result", "subtype": "success", "is_error": False, "terminal_reason": reason, "result": value,
             "session_id": sid, "uuid": str(uuid.uuid4()), "usage": {"input_tokens": 1, "output_tokens": 1}})
    for line in sys.stdin:
        msg = json.loads(line)
        if msg.get("type") == "control_request":
            out({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {}}})
        elif msg.get("type") == "user" and msg.get("priority") == "now":
            result("aborted_tools", "")
            init()
            text("msg_steer", "STEERED REPLY")
            result("completed", "STEERED REPLY")
        elif msg.get("type") == "user":
            init()
            text("msg_first", "working on the first request")
    """#

    private struct Fake {
        let executable: String
        let log: String
        let directory: URL

        func launches() -> [(cwd: String, args: [String])] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let value = try? JSONValue.parse(String(line)) else { return nil }
                return (value["cwd"]?.stringValue ?? "", value["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            }
        }
    }

    /// Writes the fake CLI; `FAKE_CLAUDE_LOG` is passed through the executable path wrapper.
    private func makeFake() throws -> Fake {
        let directory = EngineHarness.temporaryDirectory()
        let script = directory.appendingPathComponent("fakeclaude.py")
        let log = directory.appendingPathComponent("launches.log").path
        try Self.fakeCLI.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("claude")
        try "#!/bin/sh\nFAKE_CLAUDE_LOG='\(log)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return Fake(executable: wrapper.path, log: log, directory: directory)
    }

    private func config(cwd: String, resumeID: String? = nil) -> SessionConfig {
        SessionConfig(cwd: cwd, modelSelection: .default(for: .claude), runtimeMode: .fullAccess, interactionMode: .build, resumeID: resumeID)
    }

    @Test func steeringARunningTurnKeepsTheTurnAliveUntilTheSteeredReplyArrives() async throws {
        let fake = try makeFake()
        let environment = EngineEnvironment(
            drivers: [.claude: ClaudeDriver(executablePath: { fake.executable })],
            git: RecordingGit(),
            store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory()
        )
        let engine = AgentEngine(environment: environment, settings: EngineSettings(generateTitles: false))
        let project = engine.addProject(path: fake.directory.path)
        let thread = AgentThread(projectID: project.id, modelSelection: .default(for: .claude))
        engine.insertThread(thread)

        try await engine.send(thread.id, text: "first", attachments: [])
        #expect(await EngineHarness.eventually { engine.runtime.existingThread(thread.id)?.liveTurnID != nil })
        try await engine.send(thread.id, text: "actually do this", attachments: [], mode: .steer)
        let finished = await waitUntil(5) { engine.thread(thread.id)?.isRunning == false }
        #expect(finished)

        let turns = engine.thread(thread.id)?.turns ?? []
        let finalTexts = turns.flatMap(\.items).compactMap { item -> String? in
            if case let .assistantMessage(text, true) = item.kind { return text }
            return nil
        }
        #expect(turns.count == 1)
        #expect(turns.first?.status == .completed)
        #expect(finalTexts == ["STEERED REPLY"])
        await engine.shutdown()
    }

    @Test func aMissingWorkspaceIsRefusedBeforeClaudeIsStarted() async throws {
        let fake = try makeFake()
        let session = ClaudeSession(executablePath: { fake.executable })
        let missing = "/tmp/soprano-agents-deleted-\(UUID().uuidString)"

        await #expect(throws: ProviderError.self) {
            _ = try await session.start(config(cwd: missing))
        }

        #expect(fake.launches().isEmpty)
    }

    @Test func aSavedSessionWithoutATranscriptStartsFreshUnderTheSameID() async throws {
        let fake = try makeFake()
        let claudeHome = EngineHarness.temporaryDirectory()
        let session = ClaudeSession(executablePath: { fake.executable }, configDirectory: claudeHome.path)
        let saved = UUID().uuidString.lowercased()

        let id = try await session.start(config(cwd: fake.directory.path, resumeID: saved))
        await session.close()

        let args = fake.launches().first?.args ?? []
        #expect(id == saved)
        #expect(!args.contains("--resume"))
        #expect(args.split(separator: "--session-id").count == 2 && args.contains(saved))
    }

    @Test func aSavedSessionWithATranscriptIsResumed() async throws {
        let fake = try makeFake()
        let claudeHome = EngineHarness.temporaryDirectory()
        let saved = UUID().uuidString.lowercased()
        let projectFolder = claudeHome.appendingPathComponent("projects/-tmp-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        try "{}\n".write(to: projectFolder.appendingPathComponent("\(saved).jsonl"), atomically: true, encoding: .utf8)
        let session = ClaudeSession(executablePath: { fake.executable }, configDirectory: claudeHome.path)

        _ = try await session.start(config(cwd: fake.directory.path, resumeID: saved))
        await session.close()

        let args = fake.launches().first?.args ?? []
        #expect(args.firstIndex(of: "--resume").map { args[$0 + 1] } == saved)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
