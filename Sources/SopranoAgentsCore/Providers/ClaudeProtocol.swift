import Foundation

/// Command lines and stdin messages for Claude Code's stream-json mode (Claude Code 2.1.314).
/// Pure functions, so the wire format is testable without a process.
public enum ClaudeProtocol {
    /// Denial text for `ExitPlanMode` (T3 Code's): the plan is shown as a plan item instead.
    public static let exitPlanModeDenial = "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn."
    /// Effort values `--effort` accepts; `ultrathink` is a prompt prefix instead.
    static let cliEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// plan → `plan`; approval-required → `default`; auto-accept-edits → `acceptEdits`;
    /// auto → `auto`; full-access → `bypassPermissions`.
    public static func permissionMode(runtime: RuntimeMode, interaction: InteractionMode) -> String {
        if interaction == .plan { return "plan" }
        switch runtime {
        case .approvalRequired: return "default"
        case .autoAcceptEdits: return "acceptEdits"
        case .auto: return "auto"
        case .fullAccess: return "bypassPermissions"
        }
    }

    /// The `--effort` value, nil for the model default and for `ultrathink`.
    public static func effortArgument(_ effort: String?) -> String? {
        guard let effort, cliEfforts.contains(effort) else { return nil }
        return effort
    }

    /// Process-level settings; changing any of them restarts the process with `--resume`.
    public struct LaunchOptions: Sendable, Hashable {
        public var model: String
        public var effort: String?
        public var fastMode: Bool
        public var permissionMode: String

        public init(model: String, effort: String?, fastMode: Bool, permissionMode: String) {
            self.model = model
            self.effort = effort
            self.fastMode = fastMode
            self.permissionMode = permissionMode
        }

        public init(_ selection: ModelSelection, runtime: RuntimeMode, interaction: InteractionMode) {
            self.init(
                model: selection.model,
                effort: ClaudeProtocol.effortArgument(selection.effort),
                fastMode: selection.fastMode,
                permissionMode: ClaudeProtocol.permissionMode(runtime: runtime, interaction: interaction)
            )
        }
    }

    /// `claude -p --input-format stream-json --output-format stream-json --verbose
    /// --include-partial-messages --permission-prompt-tool stdio --permission-mode <mode>
    /// --allow-dangerously-skip-permissions --thinking-display summarized --model <id>
    /// [--effort <e>] [--fast-mode on] [--resume <id> [--resume-session-at <assistant uuid>] |
    /// --session-id <uuid>] [--add-dir <dir>…]`.
    ///
    /// `--allow-dangerously-skip-permissions` only makes `bypassPermissions` reachable through
    /// `set_permission_mode`; `--thinking-display summarized` makes thinking blocks carry text.
    public static func sessionArguments(
        options: LaunchOptions,
        sessionID: String,
        resume: Bool,
        resumeAt: String? = nil,
        additionalDirectories: [String] = []
    ) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", options.permissionMode,
            "--allow-dangerously-skip-permissions",
            "--thinking-display", "summarized",
            "--model", options.model,
        ]
        if let effort = options.effort { arguments += ["--effort", effort] }
        if options.fastMode { arguments += ["--fast-mode", "on"] }
        if resume {
            arguments += ["--resume", sessionID]
            if let resumeAt { arguments += ["--resume-session-at", resumeAt] }
        } else {
            arguments += ["--session-id", sessionID]
        }
        if !additionalDirectories.isEmpty { arguments += ["--add-dir"] + additionalDirectories }
        return arguments
    }

    /// Environment for Claude processes: the extended PATH, without the variables a parent
    /// Claude Code session sets (they would make the child behave as a nested session).
    static func environment() -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { base[key] = nil }
        return ExecutableLocator.childEnvironment(base: base)
    }

    // MARK: - stdin messages

    /// `{"type":"user","message":{"role":"user","content":[…image blocks…, {"type":"text",…}]},
    /// "parent_tool_use_id":null, "uuid":…, "priority":"now"?}`. Images (png/jpeg/gif/webp) are
    /// inlined as base64 blocks before the text; every attachment's path is listed in the text.
    /// `ultrathink` effort is a prompt prefix.
    public static func userMessage(_ input: TurnInput, uuid: String?, steer: Bool = false) -> JSONValue {
        var content: [JSONValue] = []
        for attachment in input.attachments where attachment.kind == .image {
            guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(attachment.mimeType),
                  let data = FileManager.default.contents(atPath: attachment.path) else { continue }
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": .string(attachment.mimeType), "data": .string(data.base64EncodedString())],
            ])
        }
        var text = ProviderPrompt.text(input.text, attachments: input.attachments)
        if input.modelSelection.effort == "ultrathink" { text = "ultrathink\n\n" + text }
        content.append(["type": "text", "text": .string(text)])
        var message: [String: JSONValue] = [
            "type": "user",
            "message": ["role": "user", "content": .array(content)],
            "parent_tool_use_id": .null,
        ]
        if let uuid { message["uuid"] = .string(uuid) }
        if steer { message["priority"] = "now" }
        return .object(message)
    }

    /// Host → CLI `{"type":"control_request","request_id":…,"request":{"subtype":…}}`.
    public static func controlRequest(id: String, _ request: JSONValue) -> JSONValue {
        ["type": "control_request", "request_id": .string(id), "request": request]
    }

    /// Answer to a CLI control request.
    public static func controlResponse(requestID: String, _ response: JSONValue) -> JSONValue {
        ["type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID), "response": response]]
    }

    public static func controlError(requestID: String, message: String) -> JSONValue {
        ["type": "control_response", "response": ["subtype": "error", "request_id": .string(requestID), "error": .string(message)]]
    }

    /// `can_use_tool` answer for an approval: allow with the unchanged input (plus the CLI's
    /// `permission_suggestions` retargeted to `destination:"session"` for Always allow, or an
    /// `addRules` rule for the tool when it suggested none); deny with the feedback or
    /// "User declined tool execution." (cancel: "User cancelled tool execution." + interrupt).
    public static func permissionResult(
        decision: ApprovalDecision,
        toolName: String,
        input: JSONValue,
        suggestions: [JSONValue],
        toolUseID: String?,
        feedback: String?
    ) -> JSONValue {
        var result: [String: JSONValue]
        switch decision {
        case .accept, .acceptForSession:
            result = ["behavior": "allow", "updatedInput": input]
            if decision == .acceptForSession {
                var updates = suggestions.compactMap { suggestion -> JSONValue? in
                    guard var object = suggestion.objectValue else { return nil }
                    object["destination"] = "session"
                    return .object(object)
                }
                if updates.isEmpty {
                    updates = [["type": "addRules", "rules": [["toolName": .string(toolName)]], "behavior": "allow", "destination": "session"]]
                }
                result["updatedPermissions"] = .array(updates)
            }
        case .decline, .cancel:
            let fallback = decision == .cancel ? "User cancelled tool execution." : "User declined tool execution."
            let message = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
            result = ["behavior": "deny", "message": .string(message?.isEmpty == false ? message! : fallback)]
            if decision == .cancel { result["interrupt"] = true }
        }
        if let toolUseID { result["toolUseID"] = .string(toolUseID) }
        return .object(result)
    }

    /// `AskUserQuestion` answer: allow with `{questions, answers:{<question text>: "a, b"}}`.
    public static func questionResult(input: JSONValue, answers: [String: [String]], toolUseID: String?) -> JSONValue {
        var joined: [String: JSONValue] = [:]
        for (question, values) in answers { joined[question] = .string(values.joined(separator: ", ")) }
        var result: [String: JSONValue] = [
            "behavior": "allow",
            "updatedInput": ["questions": input["questions"] ?? [], "answers": .object(joined)],
        ]
        if let toolUseID { result["toolUseID"] = .string(toolUseID) }
        return .object(result)
    }

    public static func exitPlanModeResult(toolUseID: String?) -> JSONValue {
        var result: [String: JSONValue] = ["behavior": "deny", "message": .string(exitPlanModeDenial)]
        if let toolUseID { result["toolUseID"] = .string(toolUseID) }
        return .object(result)
    }

    // MARK: - Account

    /// `claude auth status` JSON → (signed in, label). "max" → "Claude Max Subscription",
    /// API keys → "Claude API Key" (T3 Code's labels).
    public static func account(fromAuthStatus status: JSONValue) -> (authenticated: Bool, label: String?) {
        guard status["loggedIn"]?.boolValue != false else { return (false, nil) }
        let method = status["authMethod"]?.stringValue?.lowercased().filter { $0.isLetter } ?? ""
        if ["apikey", "anthropicapikey", "anthropicauthtoken"].contains(method) { return (true, "Claude API Key") }
        if status["apiProvider"]?.stringValue == "bedrock" { return (true, "Amazon Bedrock") }
        guard let subscription = status["subscriptionType"]?.nonEmptyString else { return (true, nil) }
        return (true, subscriptionLabel(subscription))
    }

    static func subscriptionLabel(_ subscription: String) -> String {
        let normalized = subscription.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        let short: String = switch normalized {
        case "max", "maxplan", "claudemaxsubscription": "Max"
        case "max5", "claudemax5xsubscription": "Max 5x"
        case "max20", "claudemax20xsubscription": "Max 20x"
        case "enterprise", "claudeenterprisesubscription": "Enterprise"
        case "team", "claudeteamsubscription": "Team"
        case "pro", "claudeprosubscription": "Pro"
        case "free", "claudefreesubscription": "Free"
        default: subscription.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
        let lowered = short.lowercased()
        if lowered.hasPrefix("claude"), lowered.hasSuffix("subscription") { return short }
        if lowered.hasPrefix("claude") { return "\(short) Subscription" }
        if lowered.hasSuffix("subscription") { return "Claude \(short)" }
        return "Claude \(short) Subscription"
    }
}
