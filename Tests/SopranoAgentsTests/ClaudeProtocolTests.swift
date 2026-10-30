import AppKit
import Testing
@testable import SopranoAgentsCore

struct ClaudeProtocolTests {
    @Test func permissionModesFollowRuntimeModeAndPlanWins() {
        #expect(ClaudeProtocol.permissionMode(runtime: .approvalRequired, interaction: .build) == "default")
        #expect(ClaudeProtocol.permissionMode(runtime: .autoAcceptEdits, interaction: .build) == "acceptEdits")
        #expect(ClaudeProtocol.permissionMode(runtime: .auto, interaction: .build) == "auto")
        #expect(ClaudeProtocol.permissionMode(runtime: .fullAccess, interaction: .build) == "bypassPermissions")
        #expect(ClaudeProtocol.permissionMode(runtime: .fullAccess, interaction: .plan) == "plan")
    }

    @Test func newSessionsPinTheirIdAndResumedOnesCanBeCutAtAMessage() {
        let options = ClaudeProtocol.LaunchOptions(
            ModelSelection(provider: .claude, model: "claude-haiku-5-5", options: ["effort": "high"]),
            runtime: .approvalRequired, interaction: .build
        )
        let fresh = ClaudeProtocol.sessionArguments(options: options, sessionID: "s-1", resume: false, additionalDirectories: ["/data/att"])
        #expect(fresh == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default",
            "--allow-dangerously-skip-permissions", "--thinking-display", "summarized",
            "--model", "claude-haiku-5-5", "--effort", "high", "--session-id", "s-1", "--add-dir", "/data/att",
        ])
        let resumed = ClaudeProtocol.sessionArguments(options: options, sessionID: "s-1", resume: true, resumeAt: "a-9")
        #expect(Array(resumed.suffix(4)) == ["--resume", "s-1", "--resume-session-at", "a-9"])
        #expect(!resumed.contains("--session-id"))
    }

    @Test func ultrathinkIsAPromptPrefixNotAnEffortFlag() {
        let selection = ModelSelection(provider: .claude, model: "claude-opus-5-5", options: ["effort": "ultrathink", "fastMode": "true"])
        let options = ClaudeProtocol.LaunchOptions(selection, runtime: .fullAccess, interaction: .build)
        let arguments = ClaudeProtocol.sessionArguments(options: options, sessionID: "s", resume: false)
        #expect(!arguments.contains("--effort"))
        #expect(arguments.contains("--fast-mode"))
        let message = ClaudeProtocol.userMessage(TurnInput(text: "Design it", attachments: [], modelSelection: selection, runtimeMode: .fullAccess, interactionMode: .build), uuid: "u1")
        #expect(message["message"]?["content"]?.arrayValue?.last?["text"] == "ultrathink\n\nDesign it")
    }

    @Test func userMessagesInlineImagesBeforeTheTextAndSteeringIsPriorityNow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imagePath = directory.appendingPathComponent("dot.png").path
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: imagePath))
        let input = TurnInput(
            text: "What is this?",
            attachments: [SopranoAgentsCore.Attachment(kind: .image, name: "dot.png", path: imagePath, mimeType: "image/png", byteSize: 4)],
            modelSelection: .default(for: .claude), runtimeMode: .fullAccess, interactionMode: .build
        )

        let message = ClaudeProtocol.userMessage(input, uuid: "u-1")
        #expect(message["type"] == "user")
        #expect(message["uuid"] == "u-1")
        #expect(message["parent_tool_use_id"] == .null)
        #expect(message["priority"] == nil)
        let content = message["message"]?["content"]?.arrayValue ?? []
        #expect(content.first == ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw=="]])
        #expect(content.last?["text"] == .string("What is this?\n\n[Attached image \"dot.png\" is saved at: \(imagePath)]"))

        #expect(ClaudeProtocol.userMessage(input, uuid: nil, steer: true)["priority"] == "now")
    }

    @Test func alwaysAllowRetargetsTheSuggestionsToTheSession() {
        let result = ClaudeProtocol.permissionResult(
            decision: .acceptForSession, toolName: "Write", input: ["file_path": "/tmp/demo/b.txt"],
            suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "localSettings"]],
            toolUseID: "toolu_1", feedback: nil
        )
        #expect(result == [
            "behavior": "allow", "updatedInput": ["file_path": "/tmp/demo/b.txt"], "toolUseID": "toolu_1",
            "updatedPermissions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
        ])
        let fallback = ClaudeProtocol.permissionResult(decision: .acceptForSession, toolName: "Bash", input: [:], suggestions: [], toolUseID: nil, feedback: nil)
        #expect(fallback["updatedPermissions"] == [["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "session"]])
        let once = ClaudeProtocol.permissionResult(decision: .accept, toolName: "Bash", input: ["command": "ls"], suggestions: [["type": "x"]], toolUseID: nil, feedback: nil)
        #expect(once == ["behavior": "allow", "updatedInput": ["command": "ls"]])
    }

    @Test func declinesCarryTheFeedbackAndCancelAlsoInterrupts() {
        let declined = ClaudeProtocol.permissionResult(decision: .decline, toolName: "Bash", input: [:], suggestions: [], toolUseID: nil, feedback: "  use make instead ")
        #expect(declined == ["behavior": "deny", "message": "use make instead"])
        let plain = ClaudeProtocol.permissionResult(decision: .decline, toolName: "Bash", input: [:], suggestions: [], toolUseID: nil, feedback: nil)
        #expect(plain["message"] == "User declined tool execution.")
        let cancelled = ClaudeProtocol.permissionResult(decision: .cancel, toolName: "Bash", input: [:], suggestions: [], toolUseID: nil, feedback: nil)
        #expect(cancelled == ["behavior": "deny", "message": "User cancelled tool execution.", "interrupt": true])
    }

    @Test func questionAnswersAreJoinedPerQuestionText() {
        let input: JSONValue = ["questions": [["question": "Which?", "header": "H", "options": [], "multiSelect": true]]]
        let result = ClaudeProtocol.questionResult(input: input, answers: ["Which?": ["A", "B"]], toolUseID: "t")
        #expect(result == ["behavior": "allow", "toolUseID": "t", "updatedInput": ["questions": input["questions"]!, "answers": ["Which?": "A, B"]]])
    }

    @Test func authStatusBecomesSubscriptionLabels() {
        #expect(ClaudeProtocol.account(fromAuthStatus: ["loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max"]).label == "Claude Max Subscription")
        #expect(ClaudeProtocol.account(fromAuthStatus: ["loggedIn": true, "subscriptionType": "claude_pro_subscription"]).label == "Claude Pro Subscription")
        #expect(ClaudeProtocol.account(fromAuthStatus: ["loggedIn": true, "authMethod": "api_key"]).label == "Claude API Key")
        #expect(ClaudeProtocol.account(fromAuthStatus: ["loggedIn": false]).authenticated == false)
    }

    @Test func structuredOutputPrefersTheStructuredFieldThenTheResultText() throws {
        let structured = try ClaudeDriver.structuredOutput(stdout: #"{"type":"result","is_error":false,"result":"","structured_output":{"title":"Fix login"}}"#, stderr: "", status: 0)
        #expect(structured == ["title": "Fix login"])
        let fromText = try ClaudeDriver.structuredOutput(stdout: #"{"type":"result","is_error":false,"result":"```json\n{\"title\":\"Fix\"}\n```"}"#, stderr: "", status: 0)
        #expect(fromText == ["title": "Fix"])
        #expect(throws: ProviderError.self) {
            try ClaudeDriver.structuredOutput(stdout: #"{"type":"result","is_error":true,"result":"Invalid API key"}"#, stderr: "", status: 1)
        }
    }

    @Test func rollbackAnchorsAreTheNearestAssistantMessageBeforeThePrompt() {
        let transcript = [
            #"{"type":"user","uuid":"u1","parentUuid":"sys0"}"#,
            #"{"type":"system","uuid":"sys0","parentUuid":null}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1"}"#,
            #"{"type":"attachment","uuid":"x1","parentUuid":"a1"}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"x1"}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2"}"#,
        ].joined(separator: "\n")
        #expect(ClaudeTranscript.anchor(beforePrompt: "u2", transcript: transcript) == .some("a1"))
        #expect(ClaudeTranscript.anchor(beforePrompt: "u1", transcript: transcript) == .some(nil))
        #expect(ClaudeTranscript.anchor(beforePrompt: "missing", transcript: transcript) == nil)
    }
}
