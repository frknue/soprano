import AppKit
import Testing
@testable import SopranoAgentsCore

/// `CodexSession`'s skills and compaction against a fake `codex app-server` that answers like
/// Codex 0.166 (recorded live, `codex-skills-compact.jsonl`): `skills/list` per cwd,
/// `skills/changed` as an invalidation, `skill` input items, and `thread/compact/start` run as a
/// turn of its own.
@MainActor
struct CodexSessionSkillsTests {
    private static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, os, sys
    log = os.environ["FAKE_CODEX_LOG"]
    def out(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def notify(method, params):
        params["threadId"] = "th-1"
        out({"method": method, "params": params})
    skills = [
        {"name": "tdd", "description": "Test-driven development.", "interface": {"shortDescription": "Test-driven red-green-refactor"},
         "path": "/s/tdd/SKILL.md", "scope": "user", "enabled": True},
        {"name": "off", "description": "Disabled.", "path": "/s/off/SKILL.md", "scope": "user", "enabled": False},
    ]
    for line in sys.stdin:
        msg = json.loads(line)
        with open(log, "a") as f:
            f.write(json.dumps(msg) + "\n")
        method, rid = msg.get("method"), msg.get("id")
        if rid is None:
            continue
        if method == "initialize":
            out({"id": rid, "result": {"userAgent": "Soprano Agents/0.166.0 (Mac OS 27.0.0; arm64)"}})
        elif method == "thread/start":
            out({"id": rid, "result": {"thread": {"id": "th-1"}}})
        elif method == "skills/list":
            out({"id": rid, "result": {"data": [{"cwd": msg["params"]["cwds"][0], "skills": skills, "errors": []}]}})
        elif method == "turn/start":
            out({"id": rid, "result": {"turn": {"id": "turn-1", "status": "inProgress"}}})
            notify("turn/started", {"turn": {"id": "turn-1", "status": "inProgress"}})
            notify("item/completed", {"turnId": "turn-1", "item": {"type": "agentMessage", "id": "m1", "text": "done", "phase": "final_answer"}})
            notify("turn/completed", {"turn": {"id": "turn-1", "status": "completed"}})
            if "reload" in msg["params"]["input"][0]["text"]:
                skills.append({"name": "review", "description": "Review a diff.", "path": "/s/review/SKILL.md", "scope": "repo", "enabled": True})
                out({"method": "skills/changed", "params": {}})
        elif method == "thread/compact/start":
            out({"id": rid, "result": {}})
            notify("turn/started", {"turn": {"id": "turn-c", "status": "inProgress"}})
            notify("item/started", {"turnId": "turn-c", "item": {"type": "contextCompaction", "id": "cc1"}})
            notify("thread/tokenUsage/updated", {"turnId": "turn-c", "tokenUsage": {"last": {"totalTokens": 29619}, "modelContextWindow": 475000}})
            notify("item/completed", {"turnId": "turn-c", "item": {"type": "contextCompaction", "id": "cc1"}})
            notify("turn/completed", {"turn": {"id": "turn-c", "status": "completed"}})
        else:
            out({"id": rid, "result": {}})
    """#

    private struct Fake {
        let executable: String
        let log: String
        let directory: URL

        func received(_ method: String) -> [JSONValue] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }.filter { $0["method"]?.stringValue == method }
        }
    }

    private func makeFake() throws -> Fake {
        let directory = EngineHarness.temporaryDirectory()
        let script = directory.appendingPathComponent("fakecodex.py")
        let log = directory.appendingPathComponent("received.log").path
        try Self.fakeCLI.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("codex")
        try "#!/bin/sh\nFAKE_CODEX_LOG='\(log)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return Fake(executable: wrapper.path, log: log, directory: directory)
    }

    private func config(_ cwd: String) -> SessionConfig {
        SessionConfig(cwd: cwd, modelSelection: .default(for: .codex), runtimeMode: .fullAccess, interactionMode: .build)
    }

    private func input(_ text: String) -> TurnInput {
        TurnInput(text: text, attachments: [], modelSelection: .default(for: .codex), runtimeMode: .fullAccess, interactionMode: .build)
    }

    /// Collects session events on a background task.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ProviderEvent] = []

        init(_ session: CodexSession) {
            Task { for await event in session.events { self.append(event) } }
        }

        var events: [ProviderEvent] { lock.withLock { stored } }
        private func append(_ event: ProviderEvent) { lock.withLock { stored.append(event) } }

        var commandLists: [[ProviderCommand]] {
            events.compactMap { if case let .commands(list) = $0 { list } else { nil } }
        }

        func wait(_ seconds: Double = 10, until condition: @Sendable ([ProviderEvent]) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition(events) {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    @Test func enabledSkillsBecomeTheMenuAndAMentionCarriesItsSkillItem() async throws {
        let fake = try makeFake()
        let session = CodexSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))
        let listed = await recorder.wait { _ in !recorder.commandLists.isEmpty }

        _ = try await session.startTurn(input("use $tdd for the parser"))
        _ = await recorder.wait { $0.contains(.turnCompleted(outcome: .completed, error: nil)) }
        await session.close()

        #expect(listed)
        #expect(recorder.commandLists.first == [ProviderCommand(
            name: "tdd", kind: .skill, description: "Test-driven red-green-refactor", source: "Skill", insertText: "$tdd "
        )])
        #expect(fake.received("skills/list").first?["params"] == ["cwds": [.string(fake.directory.path)]])
        let input = fake.received("turn/start").first?["params"]?["input"]?.arrayValue ?? []
        #expect(input.dropFirst().map { $0 } == [["type": "skill", "name": "tdd", "path": "/s/tdd/SKILL.md"]])
    }

    @Test func aSkillsChangedNotificationReloadsTheList() async throws {
        let fake = try makeFake()
        let session = CodexSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))
        _ = await recorder.wait { _ in !recorder.commandLists.isEmpty }

        _ = try await session.startTurn(input("reload your skills"))
        let reloaded = await recorder.wait { _ in recorder.commandLists.count == 2 }
        await session.close()

        #expect(reloaded)
        #expect(recorder.commandLists.last?.map(\.insertText) == ["$tdd ", "$review "])
        #expect(fake.received("skills/list").last?["params"]?["forceReload"] == true)
    }

    @Test func compactingStartsCodexsCompactionTurn() async throws {
        let fake = try makeFake()
        let session = CodexSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(config(fake.directory.path))

        try await session.compact()
        let finished = await recorder.wait { $0.contains(.turnCompleted(outcome: .completed, error: nil)) }
        await session.close()

        #expect(finished)
        #expect(fake.received("thread/compact/start").first?["params"] == ["threadId": "th-1"])
        let events = recorder.events.filter { if case .commands = $0 { false } else if case .conversationID = $0 { false } else { true } }
        #expect(events.first == .turnStarted(providerTurnID: "turn-c"))
        #expect(events.contains(.tokenUsage(TokenUsage(usedTokens: 29_619, contextWindow: 475_000))))
        #expect(events.contains { if case let .itemUpdated(item) = $0 { item.kind == .notice(text: "Context compacted") } else { false } })
    }
}
