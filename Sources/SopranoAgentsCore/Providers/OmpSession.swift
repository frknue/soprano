import Foundation

/// One omp conversation on a long-lived `omp --mode rpc-ui` process.
///
/// Spawn: `OmpProtocol.sessionArguments` (`--cwd`, `--approval-mode` from the runtime mode,
/// `--model` unless "default", `--thinking` for an explicit effort, `--resume <session file>`
/// when the saved file still exists), extended PATH, cwd = the thread's workspace. Handshake:
/// wait for `ready`, `negotiate_protocol {protocolVersion:2}`, `set_ask_dialog {enabled:true}`
/// (the `ask` tool arrives as one `extension_ui_request` `ask`), `set_event_filter
/// {events:null, messageUpdates:"delta"}`, then `get_state`, whose `sessionFile` (absolute
/// `.jsonl` path) is the conversation id.
///
/// Turns: model/effort/fast changes apply in place (`set_model {provider, modelId}`,
/// `set_thinking_level {level}`, `set_fast_mode {enabled}`); a runtime-mode change restarts the
/// process with `--resume` and the new approval mode. `prompt {id, message, images?}` is acked by
/// a `response` and ended by `prompt_result` with the same id (or by an ack with
/// `data.agentInvoked:false`); the prompt id is the turn's native id. Steering is `steer
/// {message, images?}`, interrupt `abort`. Dialogs are answered with `extension_ui_response`
/// (approvals with the exact option label, see `OmpProtocol.approvalLabel`); dialogs arriving
/// while no prompt runs are cancelled at once.
///
/// Rollback: `get_entries` → the n-th user-authored user message on the current branch →
/// `navigate_tree {entryId}` (omp moves the leaf to that message's parent).
///
/// Not supported: plan mode (omp has no host-driven plan mode over RPC; turns run as Build) and
/// decline feedback (omp's approval select has no text field).
public actor OmpSession: ProviderSession {
    public nonisolated let kind = ProviderKind.omp
    public nonisolated let events: AsyncStream<ProviderEvent>

    /// Handshake and state requests.
    static let requestTimeout: TimeInterval = 60

    private struct ModelID: Hashable {
        var provider: String
        var id: String
    }

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let executablePath: @Sendable () -> String?
    private var config: SessionConfig?
    private var executable = ""
    private var process: LineProcess?
    private var client: OmpClient?
    private var generation = 0
    private var mapper = OmpEventMapper()
    private var sessionFile: String?
    /// omp's configured model, for switching back to "default".
    private var configuredModel: ModelID?
    private var currentModel: ModelID?
    /// The selection slug the live process runs (launch `--model`/resume, or the last `set_model`).
    private var appliedModel: String?
    private var currentThinking: String?
    private var currentFast = false
    private var approvalMode = ""
    private var pending: [String: OmpUIRequest] = [:]
    private var activePromptID: String?
    private var nextPrompt = 1
    private var isClosing = false
    private var hasEnded = false

    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        self.executablePath = executablePath
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .unbounded)
    }

    public func start(_ config: SessionConfig) async throws -> String {
        guard self.config == nil, !hasEnded else { throw ProviderError.message("The omp session was already started.") }
        try ProviderError.requireWorkspace(config.cwd)
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("omp", explicitPath: explicit) else {
            throw ProviderError.notInstalled(.omp, path: explicit)
        }
        self.executable = executable
        self.config = config
        mapper = OmpEventMapper(cwd: config.cwd)
        // A saved session whose file is gone (deleted, never written) starts fresh.
        let resume = config.resumeID.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        do {
            try await spawn(resume: resume, selection: config.modelSelection, runtime: config.runtimeMode)
            try await apply(config.modelSelection)
        } catch {
            isClosing = true
            retire()
            finish(error: nil)
            throw error
        }
        guard let sessionFile else {
            isClosing = true
            retire()
            finish(error: nil)
            throw ProviderError.invalidOutput("omp did not report a session file.")
        }
        continuation.yield(.conversationID(sessionFile))
        return sessionFile
    }

    public func startTurn(_ input: TurnInput) async throws -> String? {
        guard var config, client != nil, process != nil else { throw ProviderError.notStarted }
        if OmpProtocol.approvalMode(input.runtimeMode) != approvalMode {
            try await restart(runtime: input.runtimeMode, selection: input.modelSelection)
        }
        config.modelSelection = input.modelSelection
        config.runtimeMode = input.runtimeMode
        config.interactionMode = input.interactionMode
        self.config = config
        try await apply(input.modelSelection)
        guard let live = client else { throw ProviderError.notStarted }

        let id = "prompt-\(nextPrompt)"
        nextPrompt += 1
        mapper.resetTurn()
        activePromptID = id
        let ack: JSONValue
        do {
            ack = try await live.request("prompt", OmpProtocol.messageFields(input), id: id)
        } catch {
            if activePromptID == id { activePromptID = nil }
            throw error
        }
        if ack["agentInvoked"]?.boolValue == false, activePromptID == id {
            activePromptID = nil
            for event in mapper.finishLocally() { continuation.yield(event) }
        }
        return id
    }

    public func steer(_ input: TurnInput) async throws {
        guard let client else { throw ProviderError.notStarted }
        guard activePromptID != nil else { throw ProviderError.noActiveTurn }
        _ = try await client.request("steer", OmpProtocol.messageFields(input))
    }

    public func interrupt() async {
        guard let client, activePromptID != nil else { return }
        _ = try? await client.request("abort")
        // Yielded but unsettled: nothing of the prompt is left to stop, so end the turn here
        // instead of waiting for background jobs to finish.
        if mapper.isAwaitingSettlement, activePromptID != nil {
            endPrompt()
            for event in mapper.interruptAwaitingSettlement() { continuation.yield(event) }
        }
    }

    public func respond(toApproval id: String, decision: ApprovalDecision, feedback: String?) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        if decision == .decline || decision == .cancel { mapper.markDeclined(requestID: id) }
        let frame = OmpProtocol.approvalLabel(for: decision, options: request.options)
            .map { OmpProtocol.uiResponse(id: id, ["value": .string($0)]) } ?? OmpProtocol.uiCancel(id: id)
        try? await client?.send(frame)
    }

    /// Empty `answers` = the user dismissed the dialog (`cancelled:true`).
    public func answer(userInput id: String, answers: [String: [String]]) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        try? await client?.send(Self.response(to: request, answers: answers))
    }

    /// The `extension_ui_response` for a dialog: `ask` → `answers`; `select` → `value` (first
    /// answer); `confirm` → `confirmed` ("Yes"); `input`/`editor` → `value` (answers joined).
    static func response(to request: OmpUIRequest, answers: [String: [String]]) -> JSONValue {
        let values = answers[OmpUIRequest.singleQuestionID] ?? answers.values.first ?? []
        guard !answers.isEmpty, request.method == .ask || !values.isEmpty else { return OmpProtocol.uiCancel(id: request.id) }
        switch request.method {
        case .ask:
            return OmpProtocol.uiResponse(id: request.id, ["answers": .array(OmpProtocol.askAnswers(questions: request.questions, answers: answers))])
        case .select:
            return OmpProtocol.uiResponse(id: request.id, ["value": .string(values[0])])
        case .confirm:
            return OmpProtocol.uiResponse(id: request.id, ["confirmed": .bool(values[0].caseInsensitiveCompare("Yes") == .orderedSame)])
        case .input, .editor:
            return OmpProtocol.uiResponse(id: request.id, ["value": .string(values.joined(separator: "\n"))])
        }
    }

    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        guard let client else { throw ProviderError.notStarted }
        let entries = try await withProviderTimeout(Self.requestTimeout, label: "omp get_entries") {
            try await client.request("get_entries")
        }
        guard let entryID = OmpProtocol.rollbackEntryID(entries: entries, beforeTurn: ordinal) else {
            throw ProviderError.message("omp's session has no record of turn \(ordinal), so the conversation cannot be rewound.")
        }
        let result = try await withProviderTimeout(Self.requestTimeout, label: "omp navigate_tree") {
            try await client.request("navigate_tree", ["entryId": .string(entryID)])
        }
        if result["cancelled"]?.boolValue == true {
            throw ProviderError.message("omp refused to rewind the conversation.")
        }
        mapper.resetTurn()
    }

    public func close() async {
        guard !isClosing else { return }
        isClosing = true
        if process != nil {
            retire()
        }
        finish(error: nil)
    }

    // MARK: - Process

    private func spawn(resume: String?, selection: ModelSelection, runtime: RuntimeMode) async throws {
        guard let config else { throw ProviderError.notStarted }
        let mode = OmpProtocol.approvalMode(runtime)
        let model = OmpProtocol.modelSpec(selection.model) != nil ? selection.model : nil
        let arguments = OmpProtocol.sessionArguments(cwd: config.cwd, approvalMode: mode, model: model, thinking: selection.effort, resume: resume)
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: arguments,
            environment: OmpProtocol.environment(),
            directory: config.cwd
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        generation += 1
        let current = generation
        let client = OmpClient(transport: process)
        self.process = process
        self.client = client
        approvalMode = mode
        mapper.itemPrefix = current > 1 ? "r\(current)/" : ""
        Task { await self.consume(client.incoming, generation: current) }

        let state = try await withProviderTimeout(Self.requestTimeout, label: "omp startup") {
            let ready = try await client.ready()
            if ready["supportedProtocolVersions"]?.arrayValue?.contains(2) == true {
                _ = try await client.request("negotiate_protocol", ["protocolVersion": 2])
            }
            _ = try await client.request("set_ask_dialog", ["enabled": true])
            _ = try await client.request("set_event_filter", ["events": .null, "messageUpdates": "delta"])
            return try await client.request("get_state")
        }
        sessionFile = state["sessionFile"]?.nonEmptyString ?? sessionFile
        appliedModel = selection.model
        if let provider = state["model"]?["provider"]?.stringValue, let id = state["model"]?["id"]?.stringValue {
            currentModel = ModelID(provider: provider, id: id)
            if model == nil, resume == nil, configuredModel == nil { configuredModel = currentModel }
        }
        currentThinking = state["thinkingLevel"]?.stringValue
        currentFast = state["fastModeEnabled"]?.boolValue ?? false
        mapper.contextWindow = state["model"]?["contextWindow"]?.intValue
    }

    /// Brings the live process to `selection`: `set_model` when the selected slug changed
    /// (resolving "default" to omp's configured model, asked from a throwaway process when this
    /// one was not launched on it), `set_thinking_level` for an explicit effort, `set_fast_mode`.
    private func apply(_ selection: ModelSelection) async throws {
        guard let client else { throw ProviderError.notStarted }
        if selection.model != appliedModel {
            var target: ModelID?
            if let spec = OmpProtocol.modelSpec(selection.model) {
                target = ModelID(provider: spec.provider, id: spec.id)
            } else {
                if configuredModel == nil, let model = try await OmpDriver.configuredModel(executable: executable) {
                    configuredModel = ModelID(provider: model.provider, id: model.id)
                }
                target = configuredModel
            }
            if let target, target != currentModel {
                let model = try await client.request("set_model", ["provider": .string(target.provider), "modelId": .string(target.id)])
                currentModel = target
                if let window = model["contextWindow"]?.intValue { mapper.contextWindow = window }
            }
            appliedModel = selection.model
        }
        if let level = OmpProtocol.thinkingArgument(selection.effort), level != currentThinking {
            _ = try await client.request("set_thinking_level", ["level": .string(level)])
            currentThinking = level
        }
        if selection.fastMode != currentFast {
            currentFast = selection.fastMode
            do {
                _ = try await client.request("set_fast_mode", ["enabled": .bool(selection.fastMode)])
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                continuation.yield(.itemUpdated(TurnItem(id: "fast-mode:\(UUID().uuidString)", kind: .notice(text: text), status: .completed)))
            }
        }
    }

    /// Stops the current process without ending the session (its exit is ignored).
    private func retire() {
        generation += 1
        client = nil
        if let process {
            process.terminate()
        }
        process = nil
        activePromptID = nil
        pending.removeAll()
    }

    /// Restarts on the same session file with a new approval mode.
    private func restart(runtime: RuntimeMode, selection: ModelSelection) async throws {
        let old = process
        let resume = sessionFile.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        // Its exit is not the session's end. EOF first so omp flushes the session file, then
        // terminate.
        generation += 1
        old?.closeInput()
        for _ in 0..<60 where old?.isRunning == true {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        retire()
        do {
            try await spawn(resume: resume, selection: selection, runtime: runtime)
        } catch {
            retire()
            finish(error: error.localizedDescription)
            throw error
        }
        if let sessionFile, sessionFile != resume { continuation.yield(.conversationID(sessionFile)) }
    }

    // MARK: - Incoming

    private func consume(_ stream: AsyncStream<OmpClient.Incoming>, generation owner: Int) async {
        for await event in stream {
            guard owner == generation else { continue }
            switch event {
            case let .frame(frame):
                await handle(frame)
            case let .closed(status, stderr):
                let error = ProviderError.processExited(.omp, status: status, stderr: stderr)
                process = nil
                client = nil
                finish(error: isClosing ? nil : error.localizedDescription)
            }
        }
    }

    private func handle(_ frame: JSONValue) async {
        switch frame["type"]?.stringValue {
        case "extension_ui_request":
            if frame["method"]?.stringValue == "cancel" {
                guard let target = frame["targetId"]?.stringValue, pending.removeValue(forKey: target) != nil else { return }
            } else if let request = OmpUIRequest(frame) {
                guard activePromptID != nil else {
                    // Nobody would see it: background runs after the turn ended.
                    try? await client?.send(OmpProtocol.uiCancel(id: request.id))
                    return
                }
                pending[request.id] = request
            }
        case "prompt_result":
            guard let id = frame["id"]?.stringValue, id == activePromptID else { return }
            // `sessionSettled:false`: background work can still wake the agent; the prompt
            // (dialogs, steer, interrupt) stays live until `session_settled`.
            if frame["sessionSettled"]?.boolValue != false { endPrompt() }
        case "session_settled":
            guard activePromptID != nil, mapper.isAwaitingSettlement else { return }
            endPrompt()
        default:
            break
        }
        for event in mapper.map(frame) { continuation.yield(event) }
    }

    /// The prompt's turn is over: withdraw dialogs nobody can answer any more.
    private func endPrompt() {
        activePromptID = nil
        for (id, _) in pending { continuation.yield(.requestResolved(id: id)) }
        pending.removeAll()
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        activePromptID = nil
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}
