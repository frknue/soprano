import AppKit
import Testing
@testable import SopranoAgentsCore

struct CodexProtocolTests {
    private static func traceMessage(id: Int) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-turn.jsonl")
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let message = try JSONValue.parse(String(line))
            if message["id"]?.intValue == id, message["method"] == nil { return message }
        }
        throw ProviderError.invalidOutput("no response \(id) in trace")
    }

    private static func input(
        _ text: String = "hi",
        attachments: [SopranoAgentsCore.Attachment] = [],
        options: [String: String] = [:],
        runtime: RuntimeMode = .fullAccess,
        interaction: InteractionMode = .build
    ) -> TurnInput {
        TurnInput(text: text, attachments: attachments, modelSelection: ModelSelection(provider: .codex, model: "gpt-6.1-sol", options: options), runtimeMode: runtime, interactionMode: interaction)
    }

    @Test func runtimeModesMapToTheDocumentedApprovalAndSandboxPolicies() {
        let workspaceWrite: JSONValue = ["type": "workspaceWrite", "writableRoots": [], "networkAccess": false, "excludeTmpdirEnvVar": false, "excludeSlashTmp": false]
        let table: [(RuntimeMode, String, String, JSONValue)] = [
            (.approvalRequired, "untrusted", "user", ["type": "readOnly", "networkAccess": false]),
            (.autoAcceptEdits, "on-request", "user", workspaceWrite),
            (.auto, "on-request", "auto_review", workspaceWrite),
            (.fullAccess, "never", "user", ["type": "dangerFullAccess"]),
        ]
        for (mode, approval, reviewer, sandbox) in table {
            let params = CodexProtocol.turnStartParams(threadID: "th", cwd: "/repo", input: Self.input(runtime: mode))
            #expect(params["approvalPolicy"] == .string(approval), "\(mode)")
            #expect(params["approvalsReviewer"] == .string(reviewer), "\(mode)")
            #expect(params["sandboxPolicy"] == sandbox, "\(mode)")
        }
    }

    @Test func turnStartCarriesEffortFastTierAndPlanCollaborationMode() {
        let params = CodexProtocol.turnStartParams(threadID: "th", cwd: "/repo", input: Self.input(options: ["effort": "high", "fastMode": "true"], interaction: .plan))
        #expect(params["threadId"] == "th")
        #expect(params["model"] == "gpt-6.1-sol")
        #expect(params["summary"] == "detailed")
        #expect(params["effort"] == "high")
        #expect(params["serviceTier"] == "priority")
        #expect(params["collaborationMode"] == ["mode": "plan", "settings": ["model": "gpt-6.1-sol", "reasoning_effort": "high"]])
    }

    @Test func turnStartOmitsEffortByDefaultButStillSendsTheDefaultMode() {
        let params = CodexProtocol.turnStartParams(threadID: "th", cwd: "/repo", input: Self.input())
        #expect(params["effort"] == nil)
        #expect(params["collaborationMode"] == ["mode": "default", "settings": ["model": "gpt-6.1-sol"]])
    }

    /// `serviceTier` persists for later turns (`Option<Option<String>>`): leaving it out after a
    /// Fast turn would keep the priority tier, so Fast off must clear it with an explicit null.
    @Test func turnStartClearsTheServiceTierWhenFastModeIsOff() {
        let params = CodexProtocol.turnStartParams(threadID: "th", cwd: "/repo", input: Self.input(options: ["effort": "high"]))
        #expect(params.objectValue?.keys.contains("serviceTier") == true)
        #expect(params["serviceTier"] == .null)
    }

    @Test func imagesBecomeLocalImagesAndEveryAttachmentPathIsAppendedToTheText() {
        let image = SopranoAgentsCore.Attachment(kind: .image, name: "shot.png", path: "/data/a/shot.png", mimeType: "image/png", byteSize: 10)
        let file = SopranoAgentsCore.Attachment(kind: .file, name: "notes.txt", path: "/data/a/notes.txt", mimeType: "text/plain", byteSize: 5)
        let items = CodexProtocol.userInput(Self.input("Look", attachments: [image, file])).arrayValue ?? []
        #expect(items.count == 2)
        #expect(items[0]["type"] == "text")
        #expect(items[0]["text"] == .string("Look\n\n[Attached image \"shot.png\" is saved at: /data/a/shot.png]\n\n[Attached file \"notes.txt\" is saved at: /data/a/notes.txt]"))
        #expect(items[0]["text_elements"] == [])
        #expect(items[1] == ["type": "localImage", "path": "/data/a/shot.png"])
    }

    @Test func steeringTargetsTheRunningTurn() {
        let params = CodexProtocol.turnSteerParams(threadID: "th", turnID: "turn-9", input: Self.input("also tests"))
        #expect(params["expectedTurnId"] == "turn-9")
        #expect(params["input"]?.arrayValue?.first?["text"] == "also tests")
    }

    // MARK: - Skills

    /// `codex-skills-compact.jsonl` line 1: a recorded `skills/list` response (Codex 0.166).
    private static func skillsList() throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-skills-compact.jsonl")
        let first = try #require(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first)
        return try JSONValue.parse(String(first))["result"] ?? .null
    }

    @Test func enabledSkillsBecomeDollarCommandsWithTheirSkillFiles() throws {
        let skills = CodexProtocol.skills(fromSkillsList: try Self.skillsList())

        #expect(skills.map(\.command.insertText) == ["$ask-matt ", "$code-review ", "$skill-creator ", "$documents:documents ", "$tdd "])
        #expect(skills.allSatisfy { $0.command.kind == .skill && $0.command.source == "Skill" && $0.path.hasSuffix("/SKILL.md") })
        // The short description (interface first) when the skill has one.
        #expect(skills[0].command.description == "Find the right skill or workflow")
        #expect(skills[2].command.description == "Create or update a skill")
        #expect(skills[3].command.description == "Create and edit Word and Google Docs files")
        #expect(skills[4].command.description == "Test-driven red-green-refactor")
        #expect(skills[4].path == "/tmp/demo/home/.agents/skills/tdd/SKILL.md")
    }

    @Test func disabledAndNamelessSkillsAreLeftOutAndTheFirstOfANameWins() {
        let list: JSONValue = ["data": [
            ["cwd": "/repo", "errors": [], "skills": [
                ["name": "on", "description": "d", "path": "/s/on/SKILL.md", "scope": "user", "enabled": true],
                ["name": "off", "description": "d", "path": "/s/off/SKILL.md", "scope": "user", "enabled": false],
                ["name": "", "description": "d", "path": "/s/x/SKILL.md", "scope": "user", "enabled": true],
            ]],
            ["cwd": "/repo/sub", "errors": [], "skills": [
                ["name": "on", "description": "again", "path": "/s/on2/SKILL.md", "scope": "repo", "enabled": true],
            ]],
        ]]

        let skills = CodexProtocol.skills(fromSkillsList: list)
        #expect(skills.map(\.command.name) == ["on"])
        #expect(skills.first?.path == "/s/on/SKILL.md")
        #expect(skills.first?.command.description == "d")
    }

    @Test func aMessageMentioningKnownSkillsCarriesTheirSkillItems() {
        let skills = ["tdd": "/s/tdd/SKILL.md", "documents:documents": "/s/documents/SKILL.md", "tdd-extra": "/s/tdd-extra/SKILL.md"]
        let text = "$documents:documents first, then $tdd. Again $tdd, not $unknown or $TDD; $tdd-extra too"
        let params = CodexProtocol.turnStartParams(threadID: "th", cwd: "/repo", input: Self.input(text), skills: skills)
        let items = params["input"]?.arrayValue ?? []

        #expect(items.first?["text"] == .string(text))
        #expect(Array(items.dropFirst()) == [
            ["type": "skill", "name": "documents:documents", "path": "/s/documents/SKILL.md"],
            ["type": "skill", "name": "tdd", "path": "/s/tdd/SKILL.md"],
            ["type": "skill", "name": "tdd-extra", "path": "/s/tdd-extra/SKILL.md"],
        ])
        #expect(CodexProtocol.userInput(Self.input("no skills here $"), skills: skills).arrayValue?.count == 1)
        #expect(CodexProtocol.turnSteerParams(threadID: "th", turnID: "t", input: Self.input("$tdd now"), skills: skills)["input"]?.arrayValue?.count == 2)
    }

    @Test func modelListEntriesBecomeModelsWithEffortAndFastModeOptions() throws {
        let models = CodexProtocol.models(fromModelList: try Self.traceMessage(id: 3)["result"] ?? .null)
        let sol = try #require(models.first)
        #expect(sol.slug == "gpt-6.1-sol")
        #expect(sol.name == "GPT-6.1 Sol")
        #expect(sol.isDefault)
        let effort = try #require(sol.option(ModelOptionID.effort))
        #expect(effort.choices.map(\.id) == ["low", "medium", "high", "xhigh", "max", "ultra"])
        #expect(effort.choices.last?.label == "Ultra")
        #expect(effort.defaultValue == "low")
        #expect(sol.option(ModelOptionID.fastMode) != nil)
        #expect(models.contains { $0.slug == "gpt-6.1-terra" && $0.name == "GPT-6.1 Terra" && !$0.isDefault })
        #expect(models.filter(\.isDefault).count == 1)
    }

    @Test func hiddenModelsAndModelsWithoutFastTiersAreHandled() {
        let models = CodexProtocol.models(fromModelList: ["data": [
            ["model": "gpt-secret", "displayName": "Secret", "hidden": true, "supportedReasoningEfforts": []],
            ["model": "gpt-6-luna", "displayName": "GPT-6-Luna", "hidden": false, "defaultReasoningEffort": "medium",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"]], "additionalSpeedTiers": []],
        ]])
        #expect(models.map(\.slug) == ["gpt-6-luna"])
        #expect(models.first?.name == "GPT-6 Luna")
        #expect(models.first?.option(ModelOptionID.fastMode) == nil)
        #expect(models.first?.option(ModelOptionID.effort)?.defaultValue == "medium")
    }

    @Test func probeResponsesYieldVersionAndSubscriptionLabel() throws {
        let initialize = try Self.traceMessage(id: 1)["result"]
        #expect(CodexProtocol.version(fromUserAgent: initialize?["userAgent"]?.stringValue ?? "") == "0.166.0")
        let account = CodexProtocol.account(from: try Self.traceMessage(id: 2)["result"] ?? .null)
        #expect(account.authenticated)
        #expect(account.label == "ChatGPT Pro 100 Subscription")
    }

    @Test func aMissingAccountIsOnlyUnauthenticatedWhenOpenAIAuthIsRequired() {
        #expect(CodexProtocol.account(from: ["account": nil, "requiresOpenaiAuth": true]).authenticated == false)
        #expect(CodexProtocol.account(from: ["account": nil, "requiresOpenaiAuth": false]).authenticated)
        #expect(CodexProtocol.account(from: ["account": ["type": "apiKey"], "requiresOpenaiAuth": true]).label == "OpenAI API Key")
        #expect(CodexProtocol.planLabel("plus") == "ChatGPT Plus Subscription")
        #expect(CodexProtocol.planLabel("business") == "ChatGPT Business Subscription")
    }

    @Test func permissionApprovalsGrantTheRequestedProfileForTheChosenScope() {
        let params: JSONValue = ["permissions": ["fileSystem": ["write": ["/repo/out"]], "network": nil]]
        #expect(CodexProtocol.approvalResult(method: "item/permissions/requestApproval", params: params, decision: .acceptForSession)
            == ["permissions": ["fileSystem": ["write": ["/repo/out"]], "network": nil], "scope": "session"])
        #expect(CodexProtocol.approvalResult(method: "item/permissions/requestApproval", params: params, decision: .decline)
            == ["permissions": [:], "scope": "turn"])
        #expect(CodexProtocol.approvalResult(method: "item/commandExecution/requestApproval", params: [:], decision: .acceptForSession)
            == ["decision": "acceptForSession"])
    }

    @Test func userInputAnswersAreRestrictedToTheAskedQuestions() {
        let result = CodexProtocol.userInputResult(answers: ["db": ["Postgres"], "stray": ["x"]], questionIDs: ["db", "orm"])
        #expect(result == ["answers": ["db": ["answers": ["Postgres"]]]])
        #expect(CodexProtocol.userInputResult(answers: [:], questionIDs: ["db"]) == ["answers": [:]])
    }

    @Test func archivedThreadErrorsAreRecognizedForTheUnarchiveRetry() {
        #expect(CodexProtocol.isArchivedThreadError(ProviderError.rpc(method: "thread/resume", code: -32600, message: "session 01ab is archived")))
        #expect(CodexProtocol.isArchivedThreadError(ProviderError.rpc(method: "thread/resume", code: -32600, message: "run `codex unarchive` first")))
        #expect(!CodexProtocol.isArchivedThreadError(ProviderError.rpc(method: "thread/resume", code: -32600, message: "no rollout found")))
    }
}
