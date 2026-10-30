import Foundation

/// One omp conversation on a long-lived `omp --mode rpc-ui` process.
///
/// Spawn: `OmpProtocol.sessionArguments` (`--cwd`, `--approval-mode` from the runtime mode,
/// `--model` unless "default", `--thinking` for an explicit effort, `--resume <session file>`
/// when the saved file still exists), extended PATH, cwd = the thread's workspace. Handshake:
/// wait for `ready`, `negotiate_protocol {protocolVersion:2}`, `set_ask_dialog {enabled:true}`
/// (the `ask` tool arrives as one `extension_ui_request` `ask`; builds without the command keep
/// the `select`/`editor` fallback, which the mapper handles), `set_event_filter
/// {events:null, messageUpdates:"delta"}`, then `get_state`, whose `sessionFile` (absolute
/// `.jsonl` path) is the conversation id.
///
/// Turns: model/effort/fast changes apply in place (`set_model {provider, modelId}`,
/// `set_thinking_level {level}`, `set_fast_mode {enabled}`); a runtime-mode change restarts the
/// process with `--resume` and the new approval mode. `prompt {id, message, images?,
/// streamingBehavior:"steer"}` is acked by a `response` and ended by `prompt_result` with the same
/// id, or by the ack itself when it carries `data.agentInvoked:false` (a builtin slash command
/// that ran locally; its `command_output` frames come first). When the turn ends the session reads
/// `get_entries` and reports the first entry the turn added after the previous turn's branch tip
/// as the turn's native id (`turnStarted`, `OmpProtocol.turnAnchor`), which rollback cuts at; an
/// unreadable anchor is reported as `OmpProtocol.unresolvedTurnID`. Steering is `steer
/// {message, images?}`, interrupt `abort`. Dialogs are answered with `extension_ui_response`
/// (approvals with the exact option label, see `OmpProtocol.approvalLabel`); dialogs arriving
/// while no prompt runs are cancelled at once.
///
/// Rollback before a turn: its entry id (or, for turns without one, the n-th user message) →
/// `fork {entryId}` of the last message entry before it, or `new_session` when nothing comes
/// before; the new session file becomes the conversation id. (`navigate_tree` would only move
/// the leaf in memory, which the next `--resume` undoes.)
///
/// Commands: `get_available_commands` after the handshake, then every pushed
/// `available_commands_update` (`commands` events). Context: when a turn ends, `get_state`'s
/// `contextUsage` is reported as `tokenUsage`. Compaction (`compact()`): the `compact` command,
/// answered once it has ended (`manual_compaction_start|end` in between), reported as a turn:
/// its notice, the new `contextUsage`, the compaction entry as the turn's id, `turnCompleted`.
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
    private let launchAdjustments: @Sendable () -> ProviderLaunchAdjustments
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
    /// The running `compact` request's id (a compaction turn; no prompt is active meanwhile).
    private var compactionID: String?
    /// The active prompt is a slash command omp has not acked yet: omp writes a command's
    /// synchronous output before the ack, so only then is a `command_output` taken as this
    /// prompt's. Output after an ack (backgrounded builtins such as `/compact`, `/handoff`) is
    /// dropped, unless it arrives while a later slash command awaits its ack: frames carry no
    /// prompt id, so it then joins that command's output.
    private var acceptsCommandOutput = false
    /// The branch tip when the last turn ended (or at start / after a rewind): the next turn's
    /// entries come after it. Unknown when `get_entries` failed.
    private var branchTip: String?
    private var branchTipKnown = false
    /// Stop was pressed for the active prompt: its yield ends the turn even if omp is unsettled.
    private var interruptRequested = false
    private var nextPrompt = 1
    private var isClosing = false
    private var hasEnded = false

    public init(
        executablePath: @escaping @Sendable () -> String? = { nil },
        launchAdjustments: @escaping @Sendable () -> ProviderLaunchAdjustments = { .none }
    ) {
        self.executablePath = executablePath
        self.launchAdjustments = launchAdjustments
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
            await refreshBranchTip()
            await fetchCommands()
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
        interruptRequested = false
        activePromptID = id
        acceptsCommandOutput = input.text.drop { $0.isWhitespace }.hasPrefix("/")
        do {
            _ = try await live.request("prompt", OmpProtocol.promptFields(input), id: id)
        } catch {
            if activePromptID == id { activePromptID = nil }
            throw error
        }
        // A local finish (`agentInvoked:false`) arrives with the frames (`handle`), so the slash
        // command's output lands in the turn before it ends.
        // The native turn id is where the turn starts in omp's session, reported when it ends.
        return nil
    }

    public func steer(_ input: TurnInput) async throws {
        guard let client else { throw ProviderError.notStarted }
        guard activePromptID != nil else { throw ProviderError.noActiveTurn }
        _ = try await client.request("steer", OmpProtocol.messageFields(input))
    }

    public func interrupt() async {
        guard let client else { return }
        if compactionID != nil {
            // A cancelled compaction ends with `manual_compaction_end {aborted:true}`. omp 18.14
            // answers commands in order, so its `abort` only runs once the compaction is over
            // (and then stops nothing): don't wait for it.
            interruptRequested = true
            Task { _ = try? await client.request("abort") }
            return
        }
        guard activePromptID != nil else { return }
        interruptRequested = true
        _ = try? await client.request("abort")
        // Yielded but unsettled: nothing of the prompt is left to stop, so end the turn here
        // instead of waiting for background jobs to finish.
        if mapper.isAwaitingSettlement, activePromptID != nil {
            await reportTurnAnchor()
            await reportContextUsage()
            guard mapper.isAwaitingSettlement, activePromptID != nil else { return }
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

    /// `compact`, answered only once the compaction has ended. It is sent without a waiter, so
    /// its response reaches `handle` in order, after the `manual_compaction_end` before it (see
    /// `finishCompaction`).
    public func compact() async throws {
        guard let client, process != nil else { throw ProviderError.notStarted }
        guard activePromptID == nil, compactionID == nil else {
            throw ProviderError.message("omp is still working; compact the conversation once the turn has ended.")
        }
        let id = "compact-\(nextPrompt)"
        nextPrompt += 1
        mapper.resetTurn()
        interruptRequested = false
        compactionID = id
        do {
            try await client.send(OmpProtocol.command("compact", id: id))
        } catch {
            compactionID = nil
            throw error
        }
    }

    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        guard let client else { throw ProviderError.notStarted }
        let entries = try await withProviderTimeout(Self.requestTimeout, label: "omp get_entries") {
            try await client.request("get_entries")
        }
        if providerTurnID == OmpProtocol.unresolvedTurnID {
            throw ProviderError.message("omp could not tell where turn \(ordinal) starts, so the conversation cannot be rewound safely.")
        }
        // Turns recorded before entry ids ("prompt-N") fall back to counting user messages.
        let target = providerTurnID.flatMap { $0.hasPrefix("prompt-") ? nil : $0 }
            ?? OmpProtocol.rollbackEntryID(entries: entries, beforeTurn: ordinal)
        guard let target, let rewind = OmpProtocol.rewind(entries: entries, before: target) else {
            throw ProviderError.message("omp's session has no record of turn \(ordinal), so the conversation cannot be rewound.")
        }
        let result = try await withProviderTimeout(Self.requestTimeout, label: "omp rewind") {
            switch rewind {
            case let .fork(entryID): try await client.request("fork", ["entryId": .string(entryID)])
            case .fresh: try await client.request("new_session")
            }
        }
        if result["cancelled"]?.boolValue == true {
            throw ProviderError.message("omp refused to rewind the conversation.")
        }
        let state = try await withProviderTimeout(Self.requestTimeout, label: "omp get_state") {
            try await client.request("get_state")
        }
        guard let file = state["sessionFile"]?.nonEmptyString else {
            throw ProviderError.invalidOutput("omp did not report the rewound session file.")
        }
        sessionFile = file
        continuation.yield(.conversationID(file))
        mapper.resetTurn()
        await refreshBranchTip()
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
        let adjustments = launchAdjustments()
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: adjustments.arguments(before: arguments),
            environment: OmpProtocol.environment(adjustments),
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
            // Builds without `set_ask_dialog` answer with a failure; `ask` then arrives as
            // `select`/`editor` dialogs, which the mapper handles.
            _ = try? await client.request("set_ask_dialog", ["enabled": true])
            _ = try await client.request("set_event_filter", ["events": .null, "messageUpdates": "delta"])
            return try await client.request("get_state")
        }
        sessionFile = state["sessionFile"]?.nonEmptyString ?? sessionFile
        // A resumed session runs the model saved in it, whatever was asked for; `apply`
        // reconciles that against the selection (including "default").
        appliedModel = resume == nil ? selection.model : nil
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
                if configuredModel == nil, let model = try await OmpDriver.configuredModel(executable: executable, directory: config?.cwd, adjustments: launchAdjustments()) {
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
        compactionID = nil
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
        case "response":
            if let id = frame["id"]?.stringValue, id == compactionID {
                await finishCompaction(id: id, response: frame)
                return
            }
            // `OmpClient` forwards prompt acks. Command output after the ack is not this
            // prompt's; `agentInvoked:false` = finished locally.
            guard frame["command"]?.stringValue == "prompt", let id = frame["id"]?.stringValue, id == activePromptID else { return }
            acceptsCommandOutput = false
            guard frame["data"]?["agentInvoked"]?.boolValue == false else { return }
            endPrompt()
            for event in mapper.finishLocally() { continuation.yield(event) }
            return
        case "command_output":
            guard acceptsCommandOutput, activePromptID != nil else { return }
        case "prompt_result":
            guard let id = frame["id"]?.stringValue, id == activePromptID else { return }
            // `sessionSettled:false`: background work can still wake the agent; the prompt
            // (dialogs, steer, interrupt) stays live until `session_settled`, unless the user
            // already pressed Stop (the yield may have raced the abort and report "completed").
            var events = mapper.map(frame)
            if mapper.isAwaitingSettlement, interruptRequested { events += mapper.interruptAwaitingSettlement() }
            if !mapper.isAwaitingSettlement {
                await reportTurnAnchor()
                await reportContextUsage()
                endPrompt()
            }
            for event in events { continuation.yield(event) }
            return
        case "session_settled":
            guard activePromptID != nil, mapper.isAwaitingSettlement else { return }
            await reportTurnAnchor()
            await reportContextUsage()
            guard activePromptID != nil, mapper.isAwaitingSettlement else { return }
            endPrompt()
        default:
            break
        }
        for event in mapper.map(frame) { continuation.yield(event) }
    }

    /// Reports where the ending turn starts in omp's session as its native id (`turnStarted`,
    /// before `turnCompleted`), then remembers the new tip for the next turn. A turn whose start
    /// cannot be located gets `OmpProtocol.unresolvedTurnID`, so a rewind refuses instead of
    /// treating it as never sent.
    private func reportTurnAnchor() async {
        guard let entries = await fetchEntries() else {
            branchTipKnown = false
            continuation.yield(.turnStarted(providerTurnID: OmpProtocol.unresolvedTurnID))
            return
        }
        let anchor = branchTipKnown ? OmpProtocol.turnAnchor(entries: entries, after: branchTip) : .unresolved
        switch anchor {
        case let .entry(id): continuation.yield(.turnStarted(providerTurnID: id))
        case .nothing: break
        case .unresolved: continuation.yield(.turnStarted(providerTurnID: OmpProtocol.unresolvedTurnID))
        }
        branchTip = entries["leafId"]?.stringValue
        branchTipKnown = true
    }

    /// Re-reads the branch tip (start, rewind).
    private func refreshBranchTip() async {
        let entries = await fetchEntries()
        branchTip = entries?["leafId"]?.stringValue
        branchTipKnown = entries != nil
    }

    private func fetchEntries() async -> JSONValue? {
        guard let client else { return nil }
        return try? await withProviderTimeout(Self.requestTimeout, label: "omp get_entries") {
            try await client.request("get_entries")
        }
    }

    /// After a turn or a compaction: `get_state`'s exact context fill as `tokenUsage` (nothing
    /// when omp leaves it out or the request fails; the last reading stands).
    private func reportContextUsage() async {
        guard let client,
              let state = try? await withProviderTimeout(Self.requestTimeout, label: "omp get_state", { try await client.request("get_state") }),
              let usage = OmpProtocol.contextUsage(fromState: state) else { return }
        continuation.yield(.tokenUsage(usage))
    }

    /// `get_available_commands` once started (omp also pushes `available_commands_update` at
    /// startup and whenever the list changes; the mapper reports those).
    private func fetchCommands() async {
        guard let client,
              let data = try? await withProviderTimeout(Self.requestTimeout, label: "omp get_available_commands", { try await client.request("get_available_commands") }),
              data["commands"]?.arrayValue != nil else { return }
        continuation.yield(.commands(OmpProtocol.commands(data["commands"])))
    }

    /// `compact`'s response ends the compaction's turn. The progress events before it already
    /// showed the result (the mapper's notice or error item, kept as `mapper.compactionEnd`):
    /// compacted or skipped ("Already compacted", answered with a failure) → completed, cancelled
    /// → interrupted, failed → failed. Builds without progress events only answer the command;
    /// a success then gets its notice here. The new context fill and the turn's anchor (its
    /// compaction entry) are reported first.
    private func finishCompaction(id: String, response: JSONValue) async {
        var events: [ProviderEvent] = []
        var outcome = ProviderTurnOutcome.completed
        var failure: String?
        if response["success"]?.boolValue == false {
            switch mapper.compactionEnd {
            case .compacted?, .skipped?:
                break
            case .cancelled?:
                outcome = .interrupted
            case let .failed(message)?:
                outcome = .failed
                failure = "Compaction failed: \(message)"
            case nil:
                if interruptRequested {
                    outcome = .interrupted
                } else {
                    outcome = .failed
                    let message = response["error"]?.nonEmptyString ?? response["error"]?["message"]?.nonEmptyString ?? "omp rejected compact."
                    failure = "Compaction failed: \(message)"
                }
            }
        } else if mapper.compactionEnd == nil {
            events.append(.itemUpdated(TurnItem(id: "\(mapper.itemPrefix)\(id)", kind: .notice(text: "Context compacted"), status: .completed)))
        }
        await reportContextUsage()
        await reportTurnAnchor()
        guard compactionID == id else { return }
        compactionID = nil
        mapper.resetTurn()
        for event in events { continuation.yield(event) }
        continuation.yield(.turnCompleted(outcome: outcome, error: failure))
    }

    /// The prompt's turn is over: withdraw dialogs nobody can answer any more.
    private func endPrompt() {
        activePromptID = nil
        acceptsCommandOutput = false
        for (id, _) in pending { continuation.yield(.requestResolved(id: id)) }
        pending.removeAll()
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        activePromptID = nil
        compactionID = nil
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}
