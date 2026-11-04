import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OmpSession`'s side questions against a fake `omp --mode rpc-ui` that answers `btw` like omp
/// 18.15 (recorded live): the started `btw_record`, then the response, then `btw_delta`s and the
/// finished `btw_record`; `btw_cancel`; `get_btw_history`. A question containing "die" makes the
/// process exit mid-answer.
@MainActor
struct OmpSessionSideQuestionTests {
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
    out({"type": "ready", "protocolVersion": 1, "supportedProtocolVersions": [1, 2]})
    topics = {}
    running = None
    def turn(question, t):
        return {"question": question, "answer": "", "status": "running", "createdAt": t, "updatedAt": t}
    for line in sys.stdin:
        msg = json.loads(line)
        record({"recv": msg})
        kind = msg.get("type")
        if kind == "get_state":
            ok(msg, {"model": {"provider": "anthropic", "id": "claude-haiku-5-5", "contextWindow": 100000},
                     "sessionFile": os.path.join(os.getcwd(), "s.jsonl")})
        elif kind == "get_entries":
            ok(msg, {"entries": [], "leafId": None})
        elif kind == "get_available_commands":
            ok(msg, {"commands": []})
        elif kind == "btw":
            question = msg["question"]
            topic_id = msg.get("recordId")
            if topic_id:
                rec = topics[topic_id]
                rec.setdefault("followUps", []).append(turn(question, 1793648070000))
                current = rec["followUps"][-1]
            else:
                topic_id = "topic%d" % (len(topics) + 1)
                rec = dict(turn(question, 1793648064070), id=topic_id, leafId="a1")
                topics[topic_id] = rec
                current = rec
            out({"type": "btw_record", "record": rec})
            ok(msg, {"record": rec})
            out({"type": "btw_delta", "recordId": topic_id, "delta": "Two workers "})
            current["answer"] = "Two workers "
            if "die" in question:
                sys.exit(3)
            if "wait" in question:
                running = (topic_id, current)
                continue
            out({"type": "btw_delta", "recordId": topic_id, "delta": "share the cache."})
            current["answer"] = "Two workers share the cache."
            current["status"] = "complete"
            out({"type": "btw_record", "record": rec})
        elif kind == "btw_cancel":
            if running:
                topic_id, current = running
                current["status"] = "cancelled"
                out({"type": "btw_record", "record": topics[topic_id]})
                running = None
                ok(msg, {"cancelled": True})
            else:
                ok(msg, {"cancelled": False})
        elif kind == "get_btw_history":
            records = sorted(topics.values(), key=lambda r: r["createdAt"], reverse=True)
            records.append({"id": "old", "question": "From the TUI?", "answer": "Yes", "status": "error", "error": "rate limited",
                            "createdAt": 1793640000000, "updatedAt": 1793640001000, "leafId": None})
            ok(msg, {"records": records})
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

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ProviderEvent] = []

        init(_ session: OmpSession) {
            Task { for await event in session.events { self.append(event) } }
        }

        var events: [ProviderEvent] { lock.withLock { stored } }
        private func append(_ event: ProviderEvent) { lock.withLock { stored.append(event) } }

        var records: [SideQuestion] {
            events.compactMap { if case let .sideQuestion(record) = $0 { record } else { nil } }
        }

        var deltas: [String] {
            events.compactMap { if case let .sideQuestionDelta(_, delta) = $0 { delta } else { nil } }
        }

        func wait(_ seconds: Double = 10, until condition: @Sendable (Recorder) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition(self) {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    private func start(_ fake: Fake) async throws -> (OmpSession, Recorder) {
        let session = OmpSession(executablePath: { fake.executable })
        let recorder = Recorder(session)
        _ = try await session.start(SessionConfig(cwd: fake.directory.path, modelSelection: .default(for: .omp), runtimeMode: .fullAccess))
        return (session, recorder)
    }

    @Test func aQuestionAndAFollowUpStreamTheirAnswersAndFinish() async throws {
        let fake = try makeFake()
        let (session, recorder) = try await start(fake)

        let started = try await session.askSideQuestion("why a lock?", topicID: nil)
        let answered = await recorder.wait { $0.records.last?.latest.status == .complete }
        let followUp = try await session.askSideQuestion("and the cache?", topicID: started.id)
        let followed = await recorder.wait { $0.records.last?.followUps.last?.status == .complete }
        await session.close()

        #expect(answered && followed)
        #expect(started.id == "topic1")
        #expect(started.isRunning)
        #expect(started.first.question == "why a lock?")
        #expect(started.first.createdAt == Date(timeIntervalSince1970: 1_793_648_064.070))
        #expect(followUp.exchanges.map(\.question) == ["why a lock?", "and the cache?"])
        #expect(recorder.deltas == ["Two workers ", "share the cache.", "Two workers ", "share the cache."])
        let last = try #require(recorder.records.last)
        #expect(last.first.answer == "Two workers share the cache.")
        #expect(last.latest.answer == "Two workers share the cache.")
        #expect(fake.received("btw").map { $0["recordId"]?.stringValue } == [nil, "topic1"])
        // Nothing of it is a turn.
        #expect(!recorder.events.contains { if case .turnCompleted = $0 { true } else { false } })
    }

    @Test func cancellingStopsTheRunningAnswerAndTheHistoryListsEveryTopic() async throws {
        let fake = try makeFake()
        let (session, recorder) = try await start(fake)

        _ = try await session.askSideQuestion("wait for it", topicID: nil)
        _ = await recorder.wait { $0.deltas.count == 1 }
        let cancelled = await session.cancelSideQuestion()
        let again = await session.cancelSideQuestion()
        let history = try await session.sideQuestions()
        await session.close()

        #expect(cancelled)
        #expect(!again)
        #expect(recorder.records.last?.latest.status == .cancelled)
        #expect(history.map(\.id) == ["topic1", "old"])
        #expect(history.first?.latest.answer == "Two workers ")
        #expect(history.last?.latest.status == .failed)
        #expect(history.last?.latest.error == "rate limited")
    }

    @Test func theProcessEndingMidAnswerReportsItInterruptedWithItsText() async throws {
        let fake = try makeFake()
        let (session, recorder) = try await start(fake)

        _ = try await session.askSideQuestion("die now", topicID: nil)
        let ended = await recorder.wait { recorder in
            recorder.events.contains { if case .sessionEnded = $0 { true } else { false } }
        }
        await session.close()

        #expect(ended)
        let last = try #require(recorder.records.last)
        #expect(last.latest.status == .interrupted)
        #expect(last.latest.answer == "Two workers ")
    }
}
