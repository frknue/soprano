import AppKit
import Testing
@testable import SopranoAgentsCore

/// `ClaudeSession`'s commands, context fill and `/compact` against a fake `claude` that answers
/// like Claude Code 2.1.314 (recorded live, `claude-commands-compact.jsonl`): `initialize` lists
/// the commands, every message's `system/init` names the skills, `get_context_usage` reports
/// `totalTokens` of `maxTokens`, and `/compact` runs without a model turn
/// (`system/compact_boundary`, then `result`).
@MainActor
struct ClaudeSessionCompactionTests {
    private static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, os, sys, uuid
    args = sys.argv[1:]
    log = os.environ["FAKE_CLAUDE_LOG"]
    sid = args[args.index("--session-id") + 1] if "--session-id" in args else str(uuid.uuid4())
    def out(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    commands = [
        {"name": "compact", "description": "Free up context by summarizing the conversation so far", "argumentHint": "<optional custom summarization instructions>", "builtin": True},
        {"name": "tdd", "description": "Test-driven development. (user)", "argumentHint": ""},
        {"name": "codex:setup", "description": "(codex) Check whether the local Codex CLI is ready", "argumentHint": "[--enable-review-gate|--disable-review-gate]"},
    ]
    tokens = 27143
    for line in sys.stdin:
        msg = json.loads(line)
        with open(log, "a") as f:
            f.write(json.dumps(msg) + "\n")
        if msg.get("type") == "control_request":
            request = msg["request"]
            response = {}
            if request.get("subtype") == "initialize":
                response = {"commands": commands, "claude_code_version": "2.1.314"}
            elif request.get("subtype") == "get_context_usage":
                response = {"totalTokens": tokens, "maxTokens": 1000000, "rawMaxTokens": 1000000, "percentage": tokens * 100 // 1000000}
            out({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": response}})
            continue
        if msg.get("type") != "user":
            continue
        text = msg["message"]["content"][-1]["text"]
        out({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": sid, "skills": ["tdd"], "uuid": str(uuid.uuid4())})
        if text == "/compact":
            out({"type": "system", "subtype": "status", "status": "compacting", "session_id": sid, "uuid": str(uuid.uuid4())})
            out({"type": "system", "subtype": "compact_boundary", "session_id": sid, "uuid": "boundary-1",
                 "compact_metadata": {"trigger": "manual", "pre_tokens": tokens, "post_tokens": 12856}})
            tokens = 12856
            out({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "result": "", "session_id": sid,
                 "uuid": str(uuid.uuid4()), "usage": {"input_tokens": 0, "output_tokens": 0}})
        else:
            out({"type": "assistant", "parent_tool_use_id": None, "session_id": sid, "uuid": str(uuid.uuid4()),
                 "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": "x",
                             "content": [{"type": "text", "text": "hi"}], "usage": {"input_tokens": 2, "output_tokens": 4}}})
            tokens = 37543
            out({"type": "result", "subtype": "success", "is_error": False, "result": "hi", "session_id": sid,
                 "uuid": str(uuid.uuid4()), "usage": {"input_tokens": 2, "output_tokens": 4}})
    """#

    private struct Fake {
        let executable: String
        let log: String
        let directory: URL

        func received() -> [JSONValue] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
        }

        func userTexts() -> [String] {
            received().filter { $0["type"] == "user" }.compactMap { $0["message"]?["content"]?.arrayValue?.last?["text"]?.stringValue }
        }
    }

    private func makeFake() throws -> Fake {
        let directory = EngineHarness.temporaryDirectory()
        let script = directory.appendingPathComponent("fakeclaude.py")
        let log = directory.appendingPathComponent("received.log").path
        try Self.fakeCLI.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("claude")
        try "#!/bin/sh\nFAKE_CLAUDE_LOG='\(log)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return Fake(executable: wrapper.path, log: log, directory: directory)
    }

    private func config(_ cwd: String) -> SessionConfig {
        SessionConfig(cwd: cwd, modelSelection: .default(for: .claude), runtimeMode: .fullAccess, interactionMode: .build)
    }

    private func input(_ text: String, effort: String? = nil) -> TurnInput {
        var selection = ModelSelection.default(for: .claude)
        if let effort { selection.options["effort"] = effort }
        return TurnInput(text: text, attachments: [], modelSelection: selection, runtimeMode: .fullAccess, interactionMode: .build)
    }

    /// Collects session events on a background task.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ProviderEvent] = []

        init(_ session: ClaudeSession) {
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

    @Test func initializeListsTheCommandsAndTheFirstMessageNamesTheSkills() async throws {
        let fake = try makeFake()
        let session = ClaudeSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))
        _ = try await session.startTurn(input("hello"))
        let reclassified = await recorder.wait { events in
            events.filter { if case .commands = $0 { true } else { false } }.count == 2
        }
        await session.close()

        let lists = recorder.events.compactMap { if case let .commands(list) = $0 { list } else { nil } }
        #expect(reclassified)
        #expect(lists.first?.map(\.source) == ["Built-in", "Custom", "Custom"])
        #expect(lists.last?.map(\.source) == ["Built-in", "Skill", "Custom"])
        #expect(lists.last?.map(\.insertText) == ["/compact ", "/tdd ", "/codex:setup "])
    }

    @Test func eachTurnEndsWithAContextReadingAndSlashCompactIsATurnOfItsOwn() async throws {
        let fake = try makeFake()
        let session = ClaudeSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))

        _ = try await session.startTurn(input("hello"))
        let measured = await recorder.wait { $0.contains(.tokenUsage(TokenUsage(usedTokens: 37_543, contextWindow: 1_000_000))) }
        let before = recorder.events.count
        try await session.compact()
        let compacted = await recorder.wait { $0.contains(.tokenUsage(TokenUsage(usedTokens: 12_856, contextWindow: 1_000_000))) }
        let compaction = Array(recorder.events.dropFirst(before))
        await session.close()

        #expect(measured && compacted)
        #expect(fake.userTexts() == ["hello", "/compact"])
        #expect(fake.received().filter { $0["request"]?["subtype"] == "get_context_usage" }.allSatisfy { $0["request"]?["detail"] == "summary" })
        let prompt = try #require(fake.received().last { $0["type"] == "user" }?["uuid"]?.stringValue)
        #expect(compaction.first == .turnStarted(providerTurnID: prompt))
        #expect(compaction.contains { if case let .itemUpdated(item) = $0 { item.id == "boundary-1" && item.kind == .notice(text: "Context compacted") } else { false } })
        let completion = try #require(compaction.firstIndex(of: .turnCompleted(outcome: .completed, error: nil)))
        let reading = try #require(compaction.firstIndex(of: .tokenUsage(TokenUsage(usedTokens: 12_856, contextWindow: 1_000_000))))
        #expect(completion < reading)
    }

    @Test func aSlashCommandIsSentWithoutTheUltrathinkPrefix() async throws {
        let fake = try makeFake()
        let session = ClaudeSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))

        _ = try await session.startTurn(input("/tdd add a parser test", effort: "ultrathink"))
        _ = await recorder.wait { $0.contains(.turnCompleted(outcome: .completed, error: nil)) }
        _ = try await session.startTurn(input("plan it", effort: "ultrathink"))
        _ = await recorder.wait { events in events.filter { $0 == .turnCompleted(outcome: .completed, error: nil) }.count == 2 }
        await session.close()

        #expect(fake.userTexts() == ["/tdd add a parser test", "ultrathink\n\nplan it"])
    }
}
