import Foundation

/// Request payloads and response decoding for `codex app-server` (Codex 0.166). Pure functions,
/// so the wire format is testable without a process.
public enum CodexProtocol {
    /// Env set on every Codex process so the app-server tailors its catalog refresh to us.
    public static let originatorEnvironment = ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Soprano Agents"]

    /// `initialize` params. Probes send only `experimentalApi`.
    public static func initializeParams(version: String, forProbe: Bool = false) -> JSONValue {
        var capabilities: [String: JSONValue] = ["experimentalApi": true]
        if !forProbe { capabilities["optOutNotificationMethods"] = ["turn/diff/updated"] }
        return [
            "clientInfo": ["name": "soprano_agents", "title": "Soprano Agents", "version": .string(version)],
            "capabilities": .object(capabilities),
        ]
    }

    /// Thread config sent with `thread/start` and `thread/resume`.
    static let threadConfig: JSONValue = ["tools.update_plan.enabled": true]

    /// `{cwd, model, config}` for `thread/start`.
    public static func threadStartParams(cwd: String, model: String) -> JSONValue {
        ["cwd": .string(cwd), "model": .string(model), "config": threadConfig]
    }

    /// `{threadId, excludeTurns:true, cwd, model, config}` for `thread/resume`.
    public static func threadResumeParams(threadID: String, cwd: String, model: String) -> JSONValue {
        ["threadId": .string(threadID), "excludeTurns": true, "cwd": .string(cwd), "model": .string(model), "config": threadConfig]
    }

    /// Resume errors that `thread/unarchive` + retry fixes.
    public static func isArchivedThreadError(_ error: Error) -> Bool {
        guard case let ProviderError.rpc(_, _, message) = error else { return false }
        let lowered = message.lowercased()
        return lowered.contains("codex unarchive") || (lowered.contains("session ") && lowered.contains(" is archived"))
    }

    // MARK: - Runtime mode

    public static func approvalPolicy(for mode: RuntimeMode) -> String {
        switch mode {
        case .approvalRequired: "untrusted"
        case .autoAcceptEdits, .auto: "on-request"
        case .fullAccess: "never"
        }
    }

    /// `auto_review` for Auto, else `user` (sent every turn: omitting it would keep a previous
    /// turn's Auto reviewer).
    public static func approvalsReviewer(for mode: RuntimeMode) -> String {
        mode == .auto ? "auto_review" : "user"
    }

    public static func sandboxPolicy(for mode: RuntimeMode) -> JSONValue {
        switch mode {
        case .approvalRequired:
            ["type": "readOnly", "networkAccess": false]
        case .autoAcceptEdits, .auto:
            ["type": "workspaceWrite", "writableRoots": [], "networkAccess": false, "excludeTmpdirEnvVar": false, "excludeSlashTmp": false]
        case .fullAccess:
            ["type": "dangerFullAccess"]
        }
    }

    // MARK: - Turns

    /// `[{type:"text", text, text_elements:[]}, {type:"localImage", path}…]`; attachment paths
    /// are appended to the text (`ProviderPrompt.text`).
    public static func userInput(_ input: TurnInput) -> JSONValue {
        var items: [JSONValue] = [[
            "type": "text",
            "text": .string(ProviderPrompt.text(input.text, attachments: input.attachments)),
            "text_elements": [],
        ]]
        for attachment in input.attachments where attachment.kind == .image {
            items.append(["type": "localImage", "path": .string(attachment.path)])
        }
        return .array(items)
    }

    /// `turn/start` params:
    /// `{threadId, input, cwd, model, effort?, summary:"detailed", approvalPolicy,
    /// approvalsReviewer, sandboxPolicy, serviceTier:"priority"|null, collaborationMode:{mode:
    /// "plan"|"default", settings:{model, reasoning_effort?}}}`. `collaborationMode` is sent in
    /// both modes so leaving Plan clears it; `serviceTier` persists for later turns, so Fast off
    /// sends an explicit null to clear it.
    public static func turnStartParams(threadID: String, cwd: String, input: TurnInput) -> JSONValue {
        let model = input.modelSelection.model
        var settings: [String: JSONValue] = ["model": .string(model)]
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": userInput(input),
            "cwd": .string(cwd),
            "model": .string(model),
            "summary": "detailed",
            "approvalPolicy": .string(approvalPolicy(for: input.runtimeMode)),
            "approvalsReviewer": .string(approvalsReviewer(for: input.runtimeMode)),
            "sandboxPolicy": sandboxPolicy(for: input.runtimeMode),
        ]
        if let effort = input.modelSelection.effort, !effort.isEmpty {
            params["effort"] = .string(effort)
            settings["reasoning_effort"] = .string(effort)
        }
        params["serviceTier"] = input.modelSelection.fastMode ? "priority" : .null
        params["collaborationMode"] = ["mode": .string(input.interactionMode.rawValue), "settings": .object(settings)]
        return .object(params)
    }

    /// `turn/steer {threadId, expectedTurnId, input}`.
    public static func turnSteerParams(threadID: String, turnID: String, input: TurnInput) -> JSONValue {
        ["threadId": .string(threadID), "expectedTurnId": .string(turnID), "input": userInput(input)]
    }

    // MARK: - Approvals

    /// JSON-RPC result for an approval server request. Command and file-change approvals take
    /// `{decision}`; permission approvals grant the requested profile for the turn or session.
    public static func approvalResult(method: String, params: JSONValue, decision: ApprovalDecision) -> JSONValue {
        guard method == "item/permissions/requestApproval" else {
            return ["decision": .string(decision.rawValue)]
        }
        switch decision {
        case .accept: return ["permissions": params["permissions"] ?? [:], "scope": "turn"]
        case .acceptForSession: return ["permissions": params["permissions"] ?? [:], "scope": "session"]
        case .decline, .cancel: return ["permissions": [:], "scope": "turn"]
        }
    }

    /// `{answers:{<questionId>:{answers:[…]}}}`, restricted to the asked question ids.
    public static func userInputResult(answers: [String: [String]], questionIDs: [String]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for id in questionIDs {
            if let values = answers[id] { result[id] = ["answers": .array(values.map(JSONValue.string))] }
        }
        return ["answers": .object(result)]
    }

    // MARK: - Probe

    /// "Soprano Agents/0.166.0 (Mac OS …)" → "0.166.0".
    public static func version(fromUserAgent userAgent: String) -> String? {
        guard let slash = userAgent.firstIndex(of: "/") else { return nil }
        let rest = userAgent[userAgent.index(after: slash)...]
        let version = rest.prefix { !$0.isWhitespace }
        return version.isEmpty ? nil : String(version)
    }

    /// `account/read` result → (health, label). `account == null && requiresOpenaiAuth` means
    /// signed out.
    public static func account(from result: JSONValue) -> (authenticated: Bool, label: String?) {
        let account = result["account"]
        guard let account, !account.isNull else {
            return (result["requiresOpenaiAuth"]?.boolValue != true, nil)
        }
        switch account["type"]?.stringValue {
        case "apiKey": return (true, "OpenAI API Key")
        case "amazonBedrock": return (true, "Amazon Bedrock")
        case "chatgpt": return (true, planLabel(account["planType"]?.stringValue))
        default: return (true, nil)
        }
    }

    /// T3 Code's `codexPlanLabel`.
    public static func planLabel(_ planType: String?) -> String? {
        switch planType {
        case "free": "ChatGPT Free Subscription"
        case "go": "ChatGPT Go Subscription"
        case "plus": "ChatGPT Plus Subscription"
        case "pro": "ChatGPT Pro 200 Subscription"
        case "prolite": "ChatGPT Pro 100 Subscription"
        case "promax": "ChatGPT Pro 500 Subscription"
        case "self_serve_business_prolite": "ChatGPT Business Premium Subscription"
        case "team", "self_serve_business_usage_based", "business": "ChatGPT Business Subscription"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise": "ChatGPT Enterprise Subscription"
        case "edu", "edu_plus", "edu_pro": "ChatGPT Edu Subscription"
        case "unknown": "ChatGPT Subscription"
        default: nil
        }
    }

    /// One `model/list` page → models (hidden ones skipped). Name via `codexDisplayName` of the
    /// display name; effort option from `supportedReasoningEfforts` / `defaultReasoningEffort`;
    /// fast mode when `additionalSpeedTiers` contains "fast".
    public static func models(fromModelList result: JSONValue) -> [ProviderModel] {
        (result["data"]?.arrayValue ?? []).compactMap { entry -> ProviderModel? in
            guard entry["hidden"]?.boolValue != true,
                  let slug = entry["model"]?.nonEmptyString ?? entry["id"]?.nonEmptyString else { return nil }
            var options: [ModelOption] = []
            let efforts = (entry["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0["reasoningEffort"]?.stringValue }
            if !efforts.isEmpty {
                let defaultEffort = entry["defaultReasoningEffort"]?.stringValue.flatMap { efforts.contains($0) ? $0 : nil } ?? efforts[0]
                options.append(ProviderCatalog.effortOption(efforts, default: defaultEffort))
            }
            let speedTiers = (entry["additionalSpeedTiers"]?.arrayValue ?? []).compactMap(\.stringValue)
            if speedTiers.contains("fast") { options.append(ProviderCatalog.fastModeOption) }
            return ProviderModel(
                slug: slug,
                name: ProviderCatalog.codexDisplayName(entry["displayName"]?.nonEmptyString ?? slug),
                isDefault: entry["isDefault"]?.boolValue ?? false,
                options: options
            )
        }
    }
}
