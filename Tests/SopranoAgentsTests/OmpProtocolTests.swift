import AppKit
import Testing
@testable import SopranoAgentsCore

struct OmpProtocolTests {
    // MARK: - Chunk reassembly

    private static func chunks(_ object: JSONValue, id: String = "rpc-1", pieces: Int = 3, byteLength: Int? = nil) -> [String] {
        let bytes = Data(object.jsonString().utf8)
        let size = (bytes.count + pieces - 1) / pieces
        return (0..<pieces).map { index in
            let slice = bytes.subdata(in: min(index * size, bytes.count)..<min((index + 1) * size, bytes.count))
            let frame: JSONValue = [
                "type": "rpc_chunk", "chunkId": .string(id), "index": .number(Double(index)), "count": .number(Double(pieces)),
                "byteLength": .number(Double(byteLength ?? bytes.count)), "data": .string(slice.base64EncodedString()),
            ]
            return frame.jsonString()
        }
    }

    private static let big: JSONValue = ["type": "response", "id": "m", "command": "get_available_models", "success": true,
                                         "data": ["models": [["provider": "anthropic", "id": "claude-haiku-5-5", "name": "Claude Haiku 5.5 — ü"]]]]

    @Test func chunksInOrderReassembleIntoTheOriginalFrame() {
        var decoder = OmpFrameDecoder()
        let outputs = Self.chunks(Self.big).flatMap { decoder.decode($0) }

        #expect(outputs == [.frame(Self.big)])
    }

    @Test func plainFramesPassThroughUntouched() {
        var decoder = OmpFrameDecoder()

        #expect(decoder.decode(#"{"type":"agent_start"}"#) == [.frame(["type": "agent_start"])])
        #expect(decoder.decode("not json").isEmpty)
    }

    @Test func anInterleavedSequenceIsRejected() {
        var decoder = OmpFrameDecoder()
        let first = Self.chunks(Self.big, id: "rpc-1")
        let second = Self.chunks(Self.big, id: "rpc-2")

        #expect(decoder.decode(first[0]).isEmpty)
        let outputs = decoder.decode(second[1])

        #expect(outputs.count == 1)
        if case .rejected = outputs.first {} else { Issue.record("expected a rejection, got \(outputs)") }
        #expect(decoder.decode(first[1]).allSatisfy { if case .rejected = $0 { true } else { false } })
    }

    @Test func anInterruptedSequenceIsRejectedAndTheInterruptingFrameStillArrives() {
        var decoder = OmpFrameDecoder()
        let pieces = Self.chunks(Self.big)

        _ = decoder.decode(pieces[0])
        let outputs = decoder.decode(#"{"type":"turn_start"}"#)

        #expect(outputs.count == 2)
        if case .rejected = outputs.first {} else { Issue.record("expected a rejection first") }
        #expect(outputs.last == .frame(["type": "turn_start"]))
    }

    @Test func aSequenceShorterThanItsByteLengthIsRejected() {
        var decoder = OmpFrameDecoder()
        let length = Self.big.jsonString().utf8.count
        let outputs = Self.chunks(Self.big, byteLength: length + 5).flatMap { decoder.decode($0) }

        #expect(outputs.count == 1)
        if case .rejected = outputs.first {} else { Issue.record("expected a rejection, got \(outputs)") }
    }

    @Test func aSequenceLongerThanItsByteLengthIsRejected() {
        var decoder = OmpFrameDecoder()
        let length = Self.big.jsonString().utf8.count
        let outputs = Self.chunks(Self.big, byteLength: length - 5).flatMap { decoder.decode($0) }

        #expect(!outputs.contains { if case .frame = $0 { true } else { false } })
        #expect(outputs.contains { if case .rejected = $0 { true } else { false } })
    }

    @Test func aSequenceOverTheReassemblyLimitIsRejected() {
        var decoder = OmpFrameDecoder(maxBytes: 16)
        let outputs = Self.chunks(Self.big).flatMap { decoder.decode($0) }

        #expect(!outputs.contains { if case .frame = $0 { true } else { false } })
        #expect(outputs.contains { if case .rejected = $0 { true } else { false } })
    }

    @Test func aSequenceNotStartingAtIndexZeroIsRejected() {
        var decoder = OmpFrameDecoder()
        let outputs = decoder.decode(Self.chunks(Self.big)[1])

        #expect(outputs.count == 1)
        if case .rejected = outputs.first {} else { Issue.record("expected a rejection") }
    }

    // MARK: - Approvals

    private static let plainOptions = ["Approve", "Approve bash for this session", "Deny"]
    private static let cachedOptions = [
        "Approve Directory: /tmp/demo", "Approve File", "Always Approve Directory: /tmp/demo",
        "Always Approve File", "Approve Once", "Approve write for this session", "Deny",
    ]
    private static let cachedWithoutSession = [
        "Approve Directory: /tmp/demo", "Approve File", "Always Approve Directory: /tmp/demo",
        "Always Approve File", "Approve Once", "Deny",
    ]

    @Test func approvalDecisionsPickTheExactLabelsOfThePlainShape() {
        #expect(OmpProtocol.approvalLabel(for: .accept, options: Self.plainOptions) == "Approve")
        #expect(OmpProtocol.approvalLabel(for: .acceptForSession, options: Self.plainOptions) == "Approve bash for this session")
        #expect(OmpProtocol.approvalLabel(for: .decline, options: Self.plainOptions) == "Deny")
        #expect(OmpProtocol.approvalLabel(for: .cancel, options: Self.plainOptions) == nil)
    }

    @Test func approvalDecisionsPickTheExactLabelsOfTheCachedShape() {
        #expect(OmpProtocol.approvalLabel(for: .accept, options: Self.cachedOptions) == "Approve Once")
        #expect(OmpProtocol.approvalLabel(for: .acceptForSession, options: Self.cachedOptions) == "Approve write for this session")
        #expect(OmpProtocol.approvalLabel(for: .acceptForSession, options: Self.cachedWithoutSession) == "Approve File")
        #expect(OmpProtocol.approvalLabel(for: .decline, options: Self.cachedOptions) == "Deny")
        #expect(OmpProtocol.approvalLabel(for: .cancel, options: Self.cachedOptions) == nil)
    }

    @Test func offeredDecisionsFollowTheLabels() {
        #expect(OmpProtocol.approvalDecisions(options: Self.plainOptions) == [.cancel, .decline, .acceptForSession, .accept])
        #expect(OmpProtocol.approvalDecisions(options: ["Approve", "Deny"]) == [.cancel, .decline, .accept])
    }

    // MARK: - ask answers

    private static let questions: [JSONValue] = [
        ["id": "color", "question": "Which color?", "options": [["label": "red"], ["label": "blue"]]],
        ["id": "tools", "question": "Which tools?", "multi": true, "options": [["label": "git"], ["label": "swift"], ["label": "bun"]]],
    ]

    @Test func askAnswersCarrySelectionsPerQuestionInOrder() {
        let answers = OmpProtocol.askAnswers(questions: Self.questions, answers: ["color": ["blue"], "tools": ["git", "bun"]])

        #expect(answers == [
            ["id": "color", "selectedOptions": ["blue"]],
            ["id": "tools", "selectedOptions": ["git", "bun"]],
        ])
    }

    @Test func freeTextBecomesTheCustomInput() {
        let answers = OmpProtocol.askAnswers(questions: Self.questions, answers: ["color": ["green please"]])

        #expect(answers == [
            ["id": "color", "selectedOptions": [], "customInput": "green please"],
            ["id": "tools", "selectedOptions": []],
        ])
    }

    @Test func dismissingADialogCancelsIt() {
        let request = OmpUIRequest(["type": "extension_ui_request", "id": "ask-1", "method": "ask", "questions": .array(Self.questions)])!
        let select = OmpUIRequest(["type": "extension_ui_request", "id": "sel-1", "method": "select", "title": "Pick", "options": ["a", "b"]])!

        #expect(OmpSession.response(to: request, answers: [:]) == ["type": "extension_ui_response", "id": "ask-1", "cancelled": true])
        #expect(OmpSession.response(to: select, answers: [:]) == ["type": "extension_ui_response", "id": "sel-1", "cancelled": true])
    }

    @Test func dialogAnswersUseThePayloadOfTheirMethod() {
        func request(_ method: String) -> OmpUIRequest {
            OmpUIRequest(["type": "extension_ui_request", "id": "r", "method": .string(method), "title": "T", "options": ["a", "b"]])!
        }
        let id = OmpUIRequest.singleQuestionID

        #expect(OmpSession.response(to: request("select"), answers: [id: ["b"]]) == ["type": "extension_ui_response", "id": "r", "value": "b"])
        #expect(OmpSession.response(to: request("confirm"), answers: [id: ["Yes"]]) == ["type": "extension_ui_response", "id": "r", "confirmed": true])
        #expect(OmpSession.response(to: request("confirm"), answers: [id: ["No"]]) == ["type": "extension_ui_response", "id": "r", "confirmed": false])
        #expect(OmpSession.response(to: request("input"), answers: [id: ["hello"]]) == ["type": "extension_ui_response", "id": "r", "value": "hello"])
        #expect(OmpSession.response(to: request("editor"), answers: [id: ["a", "b"]]) == ["type": "extension_ui_response", "id": "r", "value": "a\nb"])
    }

    // MARK: - Command lines

    @Test func runtimeModesMapToApprovalModes() {
        #expect(OmpProtocol.approvalMode(.approvalRequired) == "always-ask")
        #expect(OmpProtocol.approvalMode(.autoAcceptEdits) == "write")
        #expect(OmpProtocol.approvalMode(.auto) == "always-ask-cached")
        #expect(OmpProtocol.approvalMode(.fullAccess) == "yolo")
    }

    @Test func sessionArgumentsOmitTheModelForOmpsDefault() {
        let fresh = OmpProtocol.sessionArguments(cwd: "/tmp/demo", approvalMode: "always-ask", model: nil, thinking: nil, resume: nil)
        let resumed = OmpProtocol.sessionArguments(cwd: "/tmp/demo", approvalMode: "yolo", model: "anthropic/claude-haiku-5-5", thinking: "low", resume: "/tmp/s.jsonl")

        #expect(fresh == ["--mode", "rpc-ui", "--cwd", "/tmp/demo", "--approval-mode", "always-ask"])
        #expect(resumed == ["--mode", "rpc-ui", "--cwd", "/tmp/demo", "--approval-mode", "yolo", "--model", "anthropic/claude-haiku-5-5", "--thinking", "low", "--resume", "/tmp/s.jsonl"])
    }

    @Test func generationArgumentsPassTheModelUnlessDefault() {
        #expect(OmpProtocol.generationArguments(model: "default") == ["-p", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--no-context-files", "--no-lsp", "--thinking", "low"])
        #expect(OmpProtocol.generationArguments(model: "openai-codex/gpt-6.1-sol").contains("openai-codex/gpt-6.1-sol"))
    }

    @Test func modelSlugsSplitAtTheFirstSlash() {
        let spec = OmpProtocol.modelSpec("openrouter/anthropic/claude")
        #expect(spec?.provider == "openrouter" && spec?.id == "anthropic/claude")
        #expect(OmpProtocol.modelSpec("default") == nil)
        #expect(OmpProtocol.modelSpec("no-slash") == nil)
    }

    @Test func theVersionComesFromTheVersionLine() {
        #expect(OmpProtocol.version(fromVersionOutput: "omp/18.14.0\n") == "18.14.0")
    }

    @Test func theFirstJSONObjectIsFoundInsideFencesAndProse() throws {
        #expect(try OmpProtocol.firstJSONObject(in: "```json\n{\"title\": \"Fix {it}\"}\n```") == ["title": "Fix {it}"])
        #expect(try OmpProtocol.firstJSONObject(in: "Sure: {\"a\": {\"b\": 1}} done") == ["a": ["b": 1]])
        #expect(throws: ProviderError.self) { try OmpProtocol.firstJSONObject(in: "no json") }
    }

    // MARK: - Rollback

    private static let entries: JSONValue = [
        "leafId": "a3",
        "entries": [
            ["type": "model_change", "id": "m", "parentId": nil],
            ["type": "message", "id": "u1", "parentId": "m", "message": ["role": "user", "attribution": "user"]],
            ["type": "message", "id": "a1", "parentId": "u1", "message": ["role": "assistant"]],
            ["type": "message", "id": "s1", "parentId": "a1", "message": ["role": "user", "attribution": "user", "steering": true]],
            ["type": "message", "id": "x1", "parentId": "s1", "message": ["role": "user", "attribution": "agent"]],
            ["type": "message", "id": "u2", "parentId": "x1", "message": ["role": "user", "attribution": "user"]],
            ["type": "message", "id": "a2", "parentId": "u2", "message": ["role": "assistant"]],
            // An abandoned branch from an earlier rollback.
            ["type": "message", "id": "old", "parentId": "a2", "message": ["role": "user", "attribution": "user"]],
            ["type": "message", "id": "u3", "parentId": "a2", "message": ["role": "user", "attribution": "user"]],
            ["type": "message", "id": "a3", "parentId": "u3", "message": ["role": "assistant"]],
        ],
    ]

    @Test func rollbackTargetsTheUserMessageOfThatTurnOnTheCurrentBranch() {
        #expect(OmpProtocol.rollbackEntryID(entries: Self.entries, beforeTurn: 1) == "u1")
        #expect(OmpProtocol.rollbackEntryID(entries: Self.entries, beforeTurn: 2) == "u2")
        #expect(OmpProtocol.rollbackEntryID(entries: Self.entries, beforeTurn: 3) == "u3")
        #expect(OmpProtocol.rollbackEntryID(entries: Self.entries, beforeTurn: 4) == nil)
    }

    @Test func rollbackFindsTheSecondTurnInTheRecordedTrace() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/omp-ask-write-edit-bash.jsonl")
        let frames = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
        let entries = try #require(frames.first { $0["command"]?.stringValue == "get_entries" }?["data"])

        #expect(OmpProtocol.rollbackEntryID(entries: entries, beforeTurn: 1) == "01cade6f")
        #expect(OmpProtocol.rollbackEntryID(entries: entries, beforeTurn: 2) == nil)
    }

    @Test func aTurnStartsAtTheFirstEntryAfterThePreviousTipWhateverItsText() {
        // Position on the current branch only: no text matching, abandoned branches ("old")
        // never count, and a tip that left the branch is unresolved rather than guessed.
        #expect(OmpProtocol.turnAnchor(entries: Self.entries, after: "a1") == .entry("s1"))
        #expect(OmpProtocol.turnAnchor(entries: Self.entries, after: "a2") == .entry("u3"))
        #expect(OmpProtocol.turnAnchor(entries: Self.entries, after: nil) == .entry("m"))
        #expect(OmpProtocol.turnAnchor(entries: Self.entries, after: "a3") == .nothing)
        #expect(OmpProtocol.turnAnchor(entries: Self.entries, after: "old") == .unresolved)
    }

    @Test func aRewindForksAtTheLastMessageBeforeTheCutOrStartsOver() {
        #expect(OmpProtocol.rewind(entries: Self.entries, before: "u3") == .fork(entryID: "a2"))
        #expect(OmpProtocol.rewind(entries: Self.entries, before: "u1") == .fresh)
        #expect(OmpProtocol.rewind(entries: Self.entries, before: "m") == .fresh)
        #expect(OmpProtocol.rewind(entries: Self.entries, before: "old") == nil)
    }

    // MARK: - Models

    private static let state: JSONValue = [
        "model": ["provider": "anthropic", "id": "claude-opus-5-5", "name": "Claude Opus 5.5", "reasoning": true,
                  "thinking": ["efforts": ["low", "medium", "high", "xhigh", "max"]]],
        "thinkingLevel": "high",
    ]
    private static let available: JSONValue = ["models": [
        ["provider": "anthropic", "id": "claude-haiku-5-5", "name": "Claude Haiku 5.5", "reasoning": true,
         "thinking": ["efforts": ["low", "medium", "high"]]],
        ["provider": "openai-codex", "id": "gpt-6.1-sol", "name": "GPT-6.1 Sol", "reasoning": true,
         "thinking": ["efforts": ["minimal", "low"]]],
        ["provider": "groq", "id": "llama-4", "name": "Llama 4", "reasoning": false, "thinking": nil],
    ]]

    @Test func theCatalogStartsWithTheConfiguredModel() throws {
        let models = OmpProtocol.models(available: Self.available, state: Self.state)
        let configured = try #require(models.first)

        #expect(models.map(\.slug) == ["default", "anthropic/claude-haiku-5-5", "openai-codex/gpt-6.1-sol", "groq/llama-4"])
        #expect(configured.name == "Claude Opus 5.5 · configured")
        #expect(configured.isDefault)
        #expect(configured.option(ModelOptionID.effort)?.choices.map(\.id) == ["off", "low", "medium", "high", "xhigh", "max"])
        #expect(configured.option(ModelOptionID.effort)?.defaultValue == "high")
        #expect(models.dropFirst().allSatisfy { !$0.isDefault })
    }

    @Test func modelEffortsDefaultToTheThinkingLevelThenMedium() {
        let models = OmpProtocol.models(available: Self.available, state: Self.state)

        #expect(models[1].name == "Claude Haiku 5.5 · anthropic")
        #expect(models[1].option(ModelOptionID.effort)?.defaultValue == "high")
        #expect(models[2].option(ModelOptionID.effort)?.choices.map(\.id) == ["off", "minimal", "low"])
        #expect(models[2].option(ModelOptionID.effort)?.defaultValue == "minimal")
        #expect(models[3].options.isEmpty)
    }
}
