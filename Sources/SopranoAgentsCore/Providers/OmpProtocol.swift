import Foundation

/// Command lines and stdin frames for omp's `--mode rpc-ui` JSONL protocol (omp 18.14). Pure
/// functions, so the wire format is testable without a process.
///
/// omp's RPC is a custom JSONL protocol, not JSON-RPC. Host → omp commands are
/// `{"id"?, "type": <command>, …fields}`; omp answers `{"type":"response","id","command",
/// "success", "data"? | "error", "code"?}` and streams events (`agent_start`, `message_update`,
/// `tool_execution_*`, `prompt_result`, …) and `extension_ui_request`s in between. The first
/// stdout frame is `{"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1,2],
/// "maxFrameBytes","maxReassembledFrameBytes"}`; after `negotiate_protocol` v2, oversized frames
/// arrive as `rpc_chunk` sequences (`OmpFrameDecoder`).
public enum OmpProtocol {
    /// Thinking levels `--thinking` / `set_thinking_level` accept.
    static let thinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// approval-required → `always-ask`; auto-accept-edits → `write`; auto →
    /// `always-ask-cached`; full-access → `yolo`.
    public static func approvalMode(_ runtime: RuntimeMode) -> String {
        switch runtime {
        case .approvalRequired: "always-ask"
        case .autoAcceptEdits: "write"
        case .auto: "always-ask-cached"
        case .fullAccess: "yolo"
        }
    }

    /// `provider/id` → (provider, id), split at the first `/` (ids may contain more slashes).
    /// nil for `ModelSelection.ompDefaultModel` and malformed slugs.
    public static func modelSpec(_ slug: String) -> (provider: String, id: String)? {
        guard slug != ModelSelection.ompDefaultModel, let slash = slug.firstIndex(of: "/") else { return nil }
        let provider = String(slug[..<slash])
        let id = String(slug[slug.index(after: slash)...])
        guard !provider.isEmpty, !id.isEmpty else { return nil }
        return (provider, id)
    }

    /// The `--thinking` / `set_thinking_level` value for an effort selection, nil = omp's own.
    public static func thinkingArgument(_ effort: String?) -> String? {
        guard let effort, thinkingLevels.contains(effort) else { return nil }
        return effort
    }

    /// `omp --mode rpc-ui --cwd <cwd> --approval-mode <mode> [--model <provider/id>]
    /// [--thinking <level>] [--resume <session file>]`. `model` nil = omp's configured default.
    public static func sessionArguments(cwd: String, approvalMode: String, model: String?, thinking: String?, resume: String?) -> [String] {
        var arguments = ["--mode", "rpc-ui", "--cwd", cwd, "--approval-mode", approvalMode]
        if let model, modelSpec(model) != nil { arguments += ["--model", model] }
        if let thinking = thinkingArgument(thinking) { arguments += ["--thinking", thinking] }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// Short-lived catalog process: `omp --mode rpc --no-session --no-extensions --no-skills
    /// --no-rules --no-lsp` (no UI requests, nothing persisted).
    public static let probeArguments = ["--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp"]

    /// `omp -p --no-session --no-tools --no-extensions --no-skills --no-rules --no-context-files
    /// --no-lsp [--model <provider/id>] --thinking low` (prompt on stdin, answer on stdout).
    public static func generationArguments(model: String) -> [String] {
        var arguments = ["-p", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--no-context-files", "--no-lsp"]
        if modelSpec(model) != nil { arguments += ["--model", model] }
        arguments += ["--thinking", "low"]
        return arguments
    }

    /// The generation prompt: the task, then the schema the answer must match.
    public static func generationPrompt(_ prompt: String, schema: JSONValue) -> String {
        """
        \(prompt)

        Answer with only one JSON object that matches this JSON Schema. No prose, no Markdown fences.

        \(schema.jsonString(sortedKeys: true))
        """
    }

    /// Environment for omp processes: the extended PATH.
    static func environment() -> [String: String] {
        ExecutableLocator.childEnvironment()
    }

    /// `omp --version` output ("omp/18.14.0") → "18.14.0".
    public static func version(fromVersionOutput output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        let token = line.split(separator: " ").first.map(String.init) ?? line
        if let slash = token.firstIndex(of: "/") { return String(token[token.index(after: slash)...]) }
        return token
    }

    // MARK: - stdin frames

    /// `{"type": <type>, "id"?: <id>, …fields}`.
    public static func command(_ type: String, id: String? = nil, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var frame = fields
        frame["type"] = .string(type)
        if let id { frame["id"] = .string(id) }
        return .object(frame)
    }

    /// Fields of `prompt` / `steer`: `{"message": text, "images"?: [{"type":"image","data":
    /// <base64>,"mimeType"}]}`. Images (png/jpeg/gif/webp) are inlined; every attachment's path
    /// is listed in the text.
    public static func messageFields(_ input: TurnInput) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["message": .string(ProviderPrompt.text(input.text, attachments: input.attachments))]
        var images: [JSONValue] = []
        for attachment in input.attachments where attachment.kind == .image {
            guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(attachment.mimeType),
                  let data = FileManager.default.contents(atPath: attachment.path) else { continue }
            images.append(["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(attachment.mimeType)])
        }
        if !images.isEmpty { fields["images"] = .array(images) }
        return fields
    }

    /// Fields of `prompt`: `messageFields` plus `streamingBehavior:"steer"`. omp ignores it while
    /// idle; while a run is live (a background job woke the agent after the user pressed Stop)
    /// a plain `prompt` is refused ("Agent is already processing"), and "steer" delivers the
    /// message into that run instead, still answered by this prompt's own `prompt_result`.
    public static func promptFields(_ input: TurnInput) -> [String: JSONValue] {
        var fields = messageFields(input)
        fields["streamingBehavior"] = "steer"
        return fields
    }

    /// `{"type":"extension_ui_response","id",<payload>}` with `value`, `confirmed`, `answers` or
    /// `cancelled:true`.
    public static func uiResponse(id: String, _ payload: [String: JSONValue]) -> JSONValue {
        var frame = payload
        frame["type"] = "extension_ui_response"
        frame["id"] = .string(id)
        return .object(frame)
    }

    public static func uiCancel(id: String) -> JSONValue {
        uiResponse(id: id, ["cancelled": true])
    }

    // MARK: - Approvals

    /// The decisions an approval `select` offers, in `ApprovalRequest` display order. Cancel
    /// (`cancelled:true`) is always possible; the others need a matching label.
    public static func approvalDecisions(options: [String]) -> [ApprovalDecision] {
        var decisions: [ApprovalDecision] = [.cancel]
        if approvalLabel(for: .decline, options: options) != nil { decisions.append(.decline) }
        if options.contains(where: isSessionGrant) { decisions.append(.acceptForSession) }
        if approvalLabel(for: .accept, options: options) != nil { decisions.append(.accept) }
        return decisions
    }

    /// The exact option label answering an approval `select` (nil = answer `cancelled:true`).
    ///
    /// Shapes (omp 18.14): `always-ask`/`write` offer `["Approve", "Approve <tool> for this
    /// session", "Deny"]`; `always-ask-cached` offers grants first: `["Approve Directory: <dir>",
    /// "Approve File", "Always Approve Directory: <dir>", "Always Approve File", "Approve Once",
    /// "Approve <tool> for this session"?, "Deny"]`.
    /// - accept → `Approve Once` when offered, else `Approve`.
    /// - acceptForSession → the first label containing "for this session", else `Approve File`,
    ///   else the accept label.
    /// - decline → `Deny`. cancel → nil.
    public static func approvalLabel(for decision: ApprovalDecision, options: [String]) -> String? {
        switch decision {
        case .accept:
            if options.contains("Approve Once") { return "Approve Once" }
            if options.contains("Approve") { return "Approve" }
            return options.first { $0.hasPrefix("Approve") && !isSessionGrant($0) }
        case .acceptForSession:
            if let session = options.first(where: { $0.contains("for this session") }) { return session }
            if options.contains("Approve File") { return "Approve File" }
            return approvalLabel(for: .accept, options: options)
        case .decline:
            return options.first { $0 == "Deny" } ?? options.first { $0.hasPrefix("Deny") }
        case .cancel:
            return nil
        }
    }

    private static func isSessionGrant(_ label: String) -> Bool {
        label.contains("for this session") || label == "Approve File"
    }

    // MARK: - Questions

    /// `ask` answers: one `{"id", "selectedOptions":[labels], "customInput"?}` per question, in
    /// question order. Values matching an option label are selections; anything else is the
    /// question's free text (joined with newlines). A question without answers gets no
    /// selections.
    public static func askAnswers(questions: [JSONValue], answers: [String: [String]]) -> [JSONValue] {
        questions.enumerated().map { index, question in
            let id = question["id"]?.stringValue ?? "q\(index)"
            let labels = Set((question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue })
            let values = answers[id] ?? []
            let selected = values.filter { labels.contains($0) }
            let custom = values.filter { !labels.contains($0) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var answer: [String: JSONValue] = ["id": .string(id), "selectedOptions": .array(selected.map(JSONValue.string))]
            if !custom.isEmpty { answer["customInput"] = .string(custom.joined(separator: "\n")) }
            return .object(answer)
        }
    }

    // MARK: - Rollback

    /// `get_entries`' `data.entries` on the current branch, root first: the path from `leafId`
    /// to the root (every entry in file order when there is no `leafId`).
    static func branch(entries data: JSONValue) -> [JSONValue] {
        let entries = data["entries"]?.arrayValue ?? []
        guard let leaf = data["leafId"]?.stringValue else { return entries }
        var byID: [String: JSONValue] = [:]
        for entry in entries {
            if let id = entry["id"]?.stringValue { byID[id] = entry }
        }
        var path: [JSONValue] = []
        var cursor: String? = leaf
        var visited = Set<String>()
        while let id = cursor, visited.insert(id).inserted, let entry = byID[id] {
            path.append(entry)
            cursor = entry["parentId"]?.stringValue
        }
        return path.reversed()
    }

    /// A user-authored user message: `type:"message"`, `message.role:"user"`, attribution not
    /// `"agent"`, not synthetic.
    private static func isUserMessage(_ entry: JSONValue) -> Bool {
        guard entry["type"]?.stringValue == "message", let message = entry["message"] else { return false }
        return message["role"]?.stringValue == "user"
            && message["attribution"]?.stringValue != "agent"
            && message["synthetic"]?.boolValue != true
    }

    /// The `providerTurnID` of a turn omp received but whose start could not be located (the
    /// entries could not be read, or the previous tip left the branch). Rollback refuses it
    /// rather than guessing, so the app and omp never silently disagree.
    public static let unresolvedTurnID = "omp-unresolved"

    /// Where a turn starts in omp's session, independent of its text (omp rewrites skill
    /// invocations, templates and `^model` mentions before recording them).
    public enum TurnAnchor: Equatable, Sendable {
        /// The first entry the turn added: its user message, a hidden companion before it, a
        /// `model_change` from switching models, or what a background run added after the
        /// previous turn ended. Rewinding to before it drops the turn and nothing earlier.
        case entry(String)
        /// The turn added nothing (a local command): there is nothing to rewind.
        case nothing
        /// `tip` is not on the current branch.
        case unresolved
    }

    /// The first entry on the current branch after `tip`, the branch tip when the previous turn
    /// ended (nil = the branch was empty then).
    public static func turnAnchor(entries data: JSONValue, after tip: String?) -> TurnAnchor {
        let path = branch(entries: data)
        var start = 0
        if let tip {
            guard let index = path.firstIndex(where: { $0["id"]?.stringValue == tip }) else { return .unresolved }
            start = index + 1
        }
        guard start < path.count, let id = path[start]["id"]?.stringValue else { return .nothing }
        return .entry(id)
    }

    /// The `ordinal`-th user-authored, non-steering user message on the current branch. Only for
    /// turns recorded before turns carried omp entry ids (`providerTurnID` "prompt-N").
    public static func rollbackEntryID(entries data: JSONValue, beforeTurn ordinal: Int) -> String? {
        guard ordinal >= 1 else { return nil }
        let prompts = branch(entries: data).filter { isUserMessage($0) && $0["message"]?["steering"]?.boolValue != true }
        guard ordinal <= prompts.count else { return nil }
        return prompts[ordinal - 1]["id"]?.stringValue
    }

    /// How to end the conversation just before entry `entryID`, durably. `navigate_tree` only
    /// moves the leaf in memory (a `--resume` reloads the old tip), so a rewind forks a new
    /// session file instead.
    public enum Rewind: Equatable, Sendable {
        /// `fork {entryId}`: a new session file holding root…`entryId` (the last `message`
        /// entry before the cut; `fork` accepts only message entries).
        case fork(entryID: String)
        /// `new_session`: nothing worth keeping comes before the cut.
        case fresh
    }

    /// nil when `entryID` is not on the current branch.
    public static func rewind(entries data: JSONValue, before entryID: String) -> Rewind? {
        let path = branch(entries: data)
        guard let index = path.firstIndex(where: { $0["id"]?.stringValue == entryID }) else { return nil }
        guard let keep = path[..<index].last(where: { $0["type"]?.stringValue == "message" }),
              let keepID = keep["id"]?.stringValue else { return .fresh }
        return .fork(entryID: keepID)
    }

    // MARK: - Models

    /// The probe catalog. First `slug: "default"` = omp's configured model (`get_state` `model`),
    /// named "<name> · configured", with that model's effort option; then every
    /// `get_available_models` model as `provider/id`, named "<name> · <provider>".
    ///
    /// Effort option: "off" followed by `thinking.efforts`; default = the state's
    /// `thinkingLevel` when offered, else "medium", else the first effort. Models without
    /// `reasoning` or without efforts get no option.
    public static func models(available: JSONValue, state: JSONValue) -> [ProviderModel] {
        let thinkingLevel = state["thinkingLevel"]?.stringValue
        var models: [ProviderModel] = []
        if let current = state["model"], current.objectValue != nil {
            let name = current["name"]?.nonEmptyString ?? current["id"]?.stringValue ?? "omp default"
            models.append(ProviderModel(
                slug: ModelSelection.ompDefaultModel,
                name: "\(name) · configured",
                isDefault: true,
                options: effortOptions(current, thinkingLevel: thinkingLevel)
            ))
        } else {
            models.append(ProviderModel(slug: ModelSelection.ompDefaultModel, name: "omp default", isDefault: true))
        }
        for model in available["models"]?.arrayValue ?? [] {
            guard let provider = model["provider"]?.nonEmptyString, let id = model["id"]?.nonEmptyString else { continue }
            let name = model["name"]?.nonEmptyString ?? id
            models.append(ProviderModel(slug: "\(provider)/\(id)", name: "\(name) · \(provider)", options: effortOptions(model, thinkingLevel: thinkingLevel)))
        }
        return models
    }

    static func effortOptions(_ model: JSONValue, thinkingLevel: String?) -> [ModelOption] {
        guard model["reasoning"]?.boolValue != false else { return [] }
        let efforts = (model["thinking"]?["efforts"]?.arrayValue ?? []).compactMap(\.stringValue).filter { $0 != "off" }
        guard !efforts.isEmpty else { return [] }
        let choices = ["off"] + efforts
        let defaultID: String = if let thinkingLevel, choices.contains(thinkingLevel) {
            thinkingLevel
        } else if efforts.contains("medium") {
            "medium"
        } else {
            efforts[0]
        }
        return [ProviderCatalog.effortOption(choices, default: defaultID)]
    }

    // MARK: - Text generation

    /// The first JSON object in model output: Markdown fences are ignored and prose around the
    /// object is skipped (string-aware brace matching).
    public static func firstJSONObject(in text: String) throws -> JSONValue {
        let characters = Array(text)
        var start = characters.startIndex
        while let open = characters[start...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var index = open
            while index < characters.endIndex {
                let character = characters[index]
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(characters[open...index])
                        if let value = try? JSONValue.parse(candidate), value.objectValue != nil { return value }
                        break
                    }
                }
                index += 1
            }
            start = open + 1
        }
        throw ProviderError.invalidOutput("The model did not return a JSON object.")
    }
}

/// Reassembles omp's protocol-v2 `rpc_chunk` sequences (`{"type":"rpc_chunk","chunkId","index",
/// "count","byteLength","data":<base64 of a UTF-8 JSON slice>}`) into the logical frame.
///
/// A sequence must be uninterrupted: same `chunkId`, `count` and `byteLength`, indexes 0…count-1
/// in order, total decoded bytes exactly `byteLength` (≤ `maxBytes`), strict UTF-8, one JSON
/// object. Anything else rejects the partial sequence; a plain frame that interrupts a sequence
/// is still delivered after the rejection.
public struct OmpFrameDecoder: Sendable {
    public enum Output: Sendable, Hashable {
        case frame(JSONValue)
        case rejected(String)
    }

    /// `maxReassembledFrameBytes` from the ready frame (64 MiB by default).
    public var maxBytes: Int

    private struct Sequence: Sendable {
        var chunkID: String
        var count: Int
        var byteLength: Int
        var nextIndex: Int
        var data: Data
    }

    private var sequence: Sequence?

    public init(maxBytes: Int = 64 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    /// Feeds one stdout line; returns the frames (and rejections) it completes.
    public mutating func decode(_ line: String) -> [Output] {
        guard !line.isEmpty, let frame = try? JSONValue.parse(line), frame.objectValue != nil else { return [] }
        guard frame["type"]?.stringValue == "rpc_chunk" else {
            if let open = sequence {
                sequence = nil
                return [.rejected("rpc_chunk sequence \(open.chunkID) was interrupted by another frame."), .frame(frame)]
            }
            return [.frame(frame)]
        }
        guard let chunkID = frame["chunkId"]?.stringValue,
              let index = frame["index"]?.intValue,
              let count = frame["count"]?.intValue, count >= 1,
              let byteLength = frame["byteLength"]?.intValue, byteLength >= 0,
              let encoded = frame["data"]?.stringValue,
              let bytes = Data(base64Encoded: encoded) else {
            sequence = nil
            return [.rejected("Malformed rpc_chunk frame.")]
        }
        guard byteLength <= maxBytes else {
            sequence = nil
            return [.rejected("rpc_chunk sequence \(chunkID) exceeds the \(maxBytes)-byte limit.")]
        }
        var current: Sequence
        if let open = sequence {
            guard open.chunkID == chunkID, open.count == count, open.byteLength == byteLength, open.nextIndex == index else {
                sequence = nil
                return [.rejected("rpc_chunk sequence \(open.chunkID) was interleaved with \(chunkID).")]
            }
            current = open
        } else {
            guard index == 0 else { return [.rejected("rpc_chunk \(chunkID) started at index \(index).")] }
            current = Sequence(chunkID: chunkID, count: count, byteLength: byteLength, nextIndex: 0, data: Data())
        }
        current.data.append(bytes)
        current.nextIndex += 1
        guard current.data.count <= byteLength else {
            sequence = nil
            return [.rejected("rpc_chunk sequence \(chunkID) is longer than its byteLength.")]
        }
        guard current.nextIndex == count else {
            sequence = current
            return []
        }
        sequence = nil
        guard current.data.count == byteLength else {
            return [.rejected("rpc_chunk sequence \(chunkID) is shorter than its byteLength.")]
        }
        guard let text = String(data: current.data, encoding: .utf8),
              let value = try? JSONValue.parse(text), value.objectValue != nil else {
            return [.rejected("rpc_chunk sequence \(chunkID) is not one UTF-8 JSON object.")]
        }
        return [.frame(value)]
    }
}
