import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OmpSession`'s commands, context fill and compaction against a fake `omp --mode rpc-ui`
/// that answers like omp 18.14 (recorded live, `omp-commands-compact.jsonl`): an
/// `available_commands_update` at startup, `get_available_commands`, `get_state` with
/// `contextUsage`, and `compact` answered once it ended (`manual_compaction_start|end` first;
/// a second one is skipped: "Already compacted", answered with a failure).
@MainActor
struct OmpSessionCompactionTests {
    private static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, os, sys
    log = os.environ["FAKE_OMP_LOG"]
    def record(o):
        with open(log, "a") as f:
            f.write(json.dumps(o) + "\n")
    def out(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def ok(msg, data=None, success=True, error=None):
        o = {"type": "response", "command": msg["type"], "success": success}
        if "id" in msg: o["id"] = msg["id"]
        if data is not None: o["data"] = data
        if error is not None: o["error"] = error
        out(o)
    commands = [
        {"name": "compact", "description": "Compact the conversation", "input": {"hint": "[soft|remote|snapcompact] [focus]"}, "source": "builtin"},
        {"name": "skill:tdd", "description": "Test-driven development.", "input": {"hint": "arguments"}, "source": "skill"},
    ]
    out({"type": "ready", "protocolVersion": 1, "supportedProtocolVersions": [1, 2], "maxFrameBytes": 1048576, "maxReassembledFrameBytes": 67108864})
    out({"type": "available_commands_update", "commands": commands})
    entries = [{"type": "model_change", "id": "m0", "parentId": None}]
    tokens = 26974
    compacted = False
    prompt = None
    def add(entry):
        entry["parentId"] = entries[-1]["id"]
        entries.append(entry)
    for line in sys.stdin:
        msg = json.loads(line)
        record({"recv": msg})
        kind = msg.get("type")
        if kind == "get_state":
            ok(msg, {"model": {"provider": "anthropic", "id": "claude-haiku-5-5", "contextWindow": 100000},
                     "sessionFile": os.path.join(os.getcwd(), "s.jsonl"),
                     "contextUsage": {"tokens": tokens, "contextWindow": 100000, "percent": tokens / 1000.0}})
        elif kind == "get_entries":
            ok(msg, {"entries": entries, "leafId": entries[-1]["id"]})
        elif kind == "get_available_commands":
            ok(msg, {"commands": commands})
        elif kind == "prompt":
            ok(msg)
            prompt = msg["id"]
            add({"type": "message", "id": "u%d" % len(entries), "message": {"role": "user", "content": [{"type": "text", "text": msg["message"]}]}})
            if "wait" in msg["message"]:
                continue
            add({"type": "message", "id": "a%d" % len(entries), "message": {"role": "assistant", "content": [{"type": "text", "text": "hi"}]}})
            tokens = 52318
            compacted = False
            out({"type": "prompt_result", "id": prompt, "agentInvoked": True, "status": "completed", "sessionSettled": True})
        elif kind == "abort":
            ok(msg)
            if prompt:
                out({"type": "prompt_result", "id": prompt, "agentInvoked": True, "status": "aborted", "sessionSettled": True})
                prompt = None
        elif kind == "compact":
            out({"type": "manual_compaction_start"})
            if compacted:
                out({"type": "manual_compaction_end", "aborted": False, "skipped": True, "errorMessage": "Already compacted"})
                ok(msg, success=False, error="Already compacted")
            else:
                result = {"summary": "## Goal", "shortSummary": "Remote compaction", "firstKeptEntryId": entries[-1]["id"], "tokensBefore": tokens, "details": {}}
                add({"type": "compaction", "id": "cmp%d" % len(entries)})
                tokens = 50863
                compacted = True
                out({"type": "manual_compaction_end", "result": result, "aborted": False})
                ok(msg, result)
        elif "id" in msg:
            ok(msg, {})
    """#

    private struct Fake {
        let executable: String
        let log: String
        let directory: URL

        func received(_ type: String) -> [JSONValue] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
                .compactMap { $0["recv"] }.filter { $0["type"]?.stringValue == type }
        }
    }

    private func makeFake() throws -> Fake {
        let directory = EngineHarness.temporaryDirectory()
        let script = directory.appendingPathComponent("fakeomp.py")
        let log = directory.appendingPathComponent("received.log").path
        try Self.fakeCLI.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("omp")
        try "#!/bin/sh\nFAKE_OMP_LOG='\(log)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return Fake(executable: wrapper.path, log: log, directory: directory)
    }

    private func config(_ cwd: String) -> SessionConfig {
        SessionConfig(cwd: cwd, modelSelection: .default(for: .omp), runtimeMode: .fullAccess, interactionMode: .build)
    }

    private func input(_ text: String) -> TurnInput {
        TurnInput(text: text, attachments: [], modelSelection: .default(for: .omp), runtimeMode: .fullAccess, interactionMode: .build)
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

        func completions() -> Int {
            events.filter { if case .turnCompleted = $0 { true } else { false } }.count
        }
    }

    @Test func theCommandListArrivesAtStartAndEveryTurnEndsWithTheExactContextFill() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))

        _ = try await session.startTurn(input("hello"))
        let finished = await recorder.wait { _ in recorder.completions() == 1 }
        await session.close()

        #expect(finished)
        #expect(fake.received("get_available_commands").count == 1)
        let lists = recorder.events.compactMap { if case let .commands(list) = $0 { list } else { nil } }
        #expect(lists.count == 2)
        #expect(lists.last?.map(\.insertText) == ["/compact ", "/skill:tdd "])
        #expect(lists.last?.map(\.kind) == [.command, .skill])
        let events = recorder.events
        let usage = try #require(events.firstIndex(of: .tokenUsage(TokenUsage(usedTokens: 52_318, contextWindow: 100_000))))
        let completion = try #require(events.firstIndex(of: .turnCompleted(outcome: .completed, error: nil)))
        #expect(usage < completion)
    }

    @Test func aCompactionIsATurnWithItsNoticeTheNewFillAndItsEntry() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))
        _ = try await session.startTurn(input("hello"))
        _ = await recorder.wait { _ in recorder.completions() == 1 }

        let before = recorder.events.count
        try await session.compact()
        let compacted = await recorder.wait { _ in recorder.completions() == 2 }
        let firstCompaction = Array(recorder.events.dropFirst(before))
        let skippedFrom = recorder.events.count
        try await session.compact()
        let skipped = await recorder.wait { _ in recorder.completions() == 3 }
        let secondCompaction = Array(recorder.events.dropFirst(skippedFrom))
        await session.close()

        #expect(compacted && skipped)
        #expect(fake.received("compact").count == 2)
        let notices = firstCompaction.compactMap { event -> TurnItemKind? in
            if case let .itemUpdated(item) = event { return item.kind }
            return nil
        }
        #expect(notices == [.notice(text: "Context compacted")])
        #expect(Array(firstCompaction.suffix(3)) == [
            .tokenUsage(TokenUsage(usedTokens: 50_863, contextWindow: 100_000)),
            .turnStarted(providerTurnID: "cmp3"),
            .turnCompleted(outcome: .completed, error: nil),
        ])
        // Nothing left to compact: omp skips it and answers with a failure; the turn still completes.
        #expect(secondCompaction.contains { if case let .itemUpdated(item) = $0 { item.kind == .notice(text: "Already compacted") } else { false } })
        #expect(secondCompaction.last == .turnCompleted(outcome: .completed, error: nil))
    }

    @Test func compactingWhileAPromptRunsIsRefused() async throws {
        let fake = try makeFake()
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))
        _ = try await session.startTurn(input("wait for me"))

        await #expect(throws: ProviderError.self) { try await session.compact() }
        await session.interrupt()
        let stopped = await recorder.wait { _ in recorder.completions() == 1 }
        await session.close()

        #expect(stopped)
        #expect(fake.received("compact").isEmpty)
    }
}
