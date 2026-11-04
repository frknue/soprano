import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OmpTextAssistant` against a fake `omp`: `config list --json` prints settings from
/// `FAKE_OMP_CONFIG` (exit 1 when unset); `--mode rpc` answers `predict_word` like omp 18.15 —
/// "te" → "st", anything else null — and exits when the text contains "die". Every start and
/// received command is logged.
@MainActor
struct OmpTextAssistantTests {
    private static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, os, sys
    log = os.environ["FAKE_OMP_LOG"]
    def record(o):
        with open(log, "a") as f:
            f.write(json.dumps(o) + "\n")
    if sys.argv[1:4] == ["config", "list", "--json"]:
        config = os.environ.get("FAKE_OMP_CONFIG")
        if not config:
            sys.exit(1)
        print(config)
        sys.exit(0)
    record({"start": sys.argv[1:]})
    def out(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    out({"type": "ready", "protocolVersion": 1, "supportedProtocolVersions": [1, 2]})
    out({"type": "available_commands_update", "commands": []})
    for line in sys.stdin:
        msg = json.loads(line)
        record({"recv": msg})
        kind = msg.get("type")
        if kind == "predict_word":
            if "die" in msg["text"]:
                sys.exit(3)
            suffix = "st" if msg["text"][:msg["cursor"]].endswith("te") else None
            out({"type": "response", "id": msg["id"], "command": kind, "success": True, "data": {"suffix": suffix}})
        elif kind == "predict_word_feedback":
            out({"type": "response", "id": msg["id"], "command": kind, "success": True})
    """#

    private struct Fake {
        let executable: String
        let log: String

        var entries: [JSONValue] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
        }

        var starts: Int { entries.filter { $0["start"] != nil }.count }

        func received(_ type: String) -> [JSONValue] {
            entries.compactMap { $0["recv"] }.filter { $0["type"]?.stringValue == type }
        }
    }

    private func makeFake(config: String? = nil) throws -> Fake {
        let directory = EngineHarness.temporaryDirectory()
        let script = directory.appendingPathComponent("fakeomp.py")
        let log = directory.appendingPathComponent("received.log").path
        try Self.fakeCLI.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("omp")
        let configLine = config.map { "FAKE_OMP_CONFIG='\($0)' " } ?? ""
        try "#!/bin/sh\n\(configLine)FAKE_OMP_LOG='\(log)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return Fake(executable: wrapper.path, log: log)
    }

    @Test func preferencesFollowOmpSpellingSettingsAndKeepDefaultsForMissingOnes() async throws {
        let config = #"{"spelling.typoDetection": {"value": false, "type": "boolean"}, "spelling.autocomplete": {"value": "off", "type": "enum"}}"#
        let fake = try makeFake(config: config)
        let assistant = OmpTextAssistant(executablePath: { fake.executable })
        #expect(await assistant.preferences() == TextAssistPreferences(typoDetection: false, autocorrect: false, wordCompletion: false))

        let smollm = OmpTextAssistant.preferences(fromConfigList: try JSONValue.parse(
            #"{"spelling.autocomplete": {"value": "smollm"}, "spelling.autocorrect": {"value": true}}"#
        ))
        #expect(smollm == TextAssistPreferences(typoDetection: true, autocorrect: true, wordCompletion: true))
        #expect(fake.starts == 0)
    }

    @Test func unreadableSettingsGiveOmpDefaults() async throws {
        let fake = try makeFake()
        let assistant = OmpTextAssistant(executablePath: { fake.executable })
        #expect(await assistant.preferences() == TextAssistPreferences())
    }

    @Test func predictionsShareOneHelperAndAnExitedHelperRestartsOnTheNextOne() async throws {
        let fake = try makeFake()
        let assistant = OmpTextAssistant(executablePath: { fake.executable })
        defer { Task { await assistant.close() } }

        #expect(await assistant.predictWord(text: "fix the te", cursor: 10) == "st")
        #expect(await assistant.predictWord(text: "fix the te and", cursor: 14) == nil)
        #expect(fake.starts == 1)
        let first = try #require(fake.received("predict_word").first)
        #expect(first["text"]?.stringValue == "fix the te")
        #expect(first["cursor"]?.intValue == 10)
        #expect(fake.entries.first?["start"]?.arrayValue?.compactMap(\.stringValue) == OmpProtocol.probeArguments)

        #expect(await assistant.predictWord(text: "die", cursor: 3) == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await assistant.predictWord(text: "te", cursor: 2) == "st")
        #expect(fake.starts == 2)
    }

    @Test func feedbackNeverStartsTheHelperButReachesARunningOne() async throws {
        let fake = try makeFake()
        let assistant = OmpTextAssistant(executablePath: { fake.executable })
        defer { Task { await assistant.close() } }

        await assistant.wordFeedback(text: "te", cursor: 2, suggestion: "st", accepted: true)
        #expect(fake.starts == 0)

        _ = await assistant.predictWord(text: "te", cursor: 2)
        await assistant.wordFeedback(text: "te", cursor: 2, suggestion: "st", accepted: false)
        let feedback = try #require(fake.received("predict_word_feedback").first)
        #expect(feedback["suggestion"]?.stringValue == "st")
        #expect(feedback["accepted"]?.boolValue == false)
        #expect(feedback["cursor"]?.intValue == 2)
    }

    @Test func aClosedAssistantStartsNothing() async throws {
        let fake = try makeFake()
        let assistant = OmpTextAssistant(executablePath: { fake.executable })
        await assistant.close()
        #expect(await assistant.predictWord(text: "te", cursor: 2) == nil)
        #expect(fake.starts == 0)
    }
}
