import Foundation

/// One Claude Code conversation on a long-lived `claude -p` stream-json process.
///
/// Spawn: `ClaudeProtocol.sessionArguments` (new: `--session-id <uuid>`, later
/// `--resume <id>`), extended PATH, cwd = the thread's workspace. A `control_request`
/// `initialize` goes first and is awaited. Each turn writes one user message carrying a fresh
/// `uuid`, which is also the turn's native id. Steering writes another user message with
/// `"priority":"now"`; interrupt is the `interrupt` control request. Model and permission-mode
/// changes apply in place (`set_model`, `set_permission_mode`); effort and fast-mode changes
/// restart the process with `--resume`.
///
/// `can_use_tool` control requests become approvals or questions, answered with
/// `control_response`; `ExitPlanMode` is denied at once (its plan item comes from the
/// `tool_use` block).
///
/// Rollback: Claude Code has no in-process rewind, but `--resume <id> --resume-session-at
/// <assistant message uuid>` (hidden flag, verified with 2.1.314) resumes the transcript cut
/// after that message; the next message branches off there and later `--resume`s follow the
/// new branch. Before turn N the process restarts at the last assistant message before turn
/// N's prompt (remembered per prompt, or read from `~/.claude/projects/*/<session>.jsonl`
/// after a relaunch). Rolling back to before the first turn starts a fresh session id.
public actor ClaudeSession: ProviderSession {
    public nonisolated let kind = ProviderKind.claude
    public nonisolated let events: AsyncStream<ProviderEvent>

    /// Where the conversation stood before a prompt was sent.
    private enum Anchor: Sendable, Hashable {
        case start
        case message(String)
    }

    private struct PendingPermission {
        var toolName: String
        var input: JSONValue
        var suggestions: [JSONValue]
        var toolUseID: String?
    }

    static let controlTimeout: TimeInterval = 60

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let executablePath: @Sendable () -> String?
    private var config: SessionConfig?
    private var options: ClaudeProtocol.LaunchOptions?
    private var sessionID = ""
    /// A transcript exists, so respawns use `--resume`.
    private var hasConversation = false
    /// Set by rollback; applies to every respawn until the next prompt is written.
    private var resumeAt: String?
    private var process: LineProcess?
    private var generation = 0
    private var mapper = ClaudeEventMapper()
    private var pending: [String: PendingPermission] = [:]
    private var anchors: [String: Anchor] = [:]
    private var controlWaiters: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextControlID = 1
    private var isTurnRunning = false
    private var interruptRequested = false
    private var isClosing = false
    private var hasEnded = false

    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        self.executablePath = executablePath
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .unbounded)
    }

    public func start(_ config: SessionConfig) async throws -> String {
        guard self.config == nil, !hasEnded else { throw ProviderError.message("The Claude session was already started.") }
        self.config = config
        options = ClaudeProtocol.LaunchOptions(config.modelSelection, runtime: config.runtimeMode, interaction: config.interactionMode)
        sessionID = config.resumeID ?? UUID().uuidString.lowercased()
        hasConversation = config.resumeID != nil
        mapper = ClaudeEventMapper(cwd: config.cwd, sessionID: sessionID)
        do {
            try await spawn()
        } catch {
            isClosing = true
            retire()
            finish(error: nil)
            throw error
        }
        continuation.yield(.conversationID(sessionID))
        return sessionID
    }

    public func startTurn(_ input: TurnInput) async throws -> String? {
        guard var options, process != nil else { throw ProviderError.notStarted }
        let wanted = ClaudeProtocol.LaunchOptions(input.modelSelection, runtime: input.runtimeMode, interaction: input.interactionMode)
        if wanted.effort != options.effort || wanted.fastMode != options.fastMode {
            self.options = wanted
            try await restart()
        } else {
            if wanted.model != options.model {
                _ = try await control(["subtype": "set_model", "model": .string(wanted.model)])
                options.model = wanted.model
            }
            if wanted.permissionMode != options.permissionMode {
                _ = try await control(["subtype": "set_permission_mode", "mode": .string(wanted.permissionMode)])
                options.permissionMode = wanted.permissionMode
            }
            self.options = options
        }

        let uuid = UUID().uuidString.lowercased()
        if let last = mapper.lastAssistantUUID {
            anchors[uuid] = .message(last)
        } else if !hasConversation {
            anchors[uuid] = .start
        }
        try write(ClaudeProtocol.userMessage(input, uuid: uuid))
        hasConversation = true
        resumeAt = nil
        isTurnRunning = true
        interruptRequested = false
        return uuid
    }

    public func steer(_ input: TurnInput) async throws {
        guard process != nil else { throw ProviderError.notStarted }
        guard isTurnRunning else { throw ProviderError.noActiveTurn }
        try write(ClaudeProtocol.userMessage(input, uuid: UUID().uuidString.lowercased(), steer: true))
    }

    public func interrupt() async {
        guard process != nil, isTurnRunning else { return }
        interruptRequested = true
        _ = try? await control(["subtype": "interrupt"])
    }

    public func respond(toApproval id: String, decision: ApprovalDecision, feedback: String?) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        if decision == .decline || decision == .cancel, let toolUseID = request.toolUseID {
            mapper.markDeclined(toolUseID: toolUseID)
        }
        let result = ClaudeProtocol.permissionResult(
            decision: decision, toolName: request.toolName, input: request.input,
            suggestions: request.suggestions, toolUseID: request.toolUseID, feedback: feedback
        )
        try? write(ClaudeProtocol.controlResponse(requestID: id, result))
    }

    /// Empty `answers` = the user dismissed the question: the tool call is denied.
    public func answer(userInput id: String, answers: [String: [String]]) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        let result: JSONValue
        if answers.isEmpty {
            var deny: [String: JSONValue] = ["behavior": "deny", "message": "User dismissed the question without answering."]
            if let toolUseID = request.toolUseID { deny["toolUseID"] = .string(toolUseID) }
            result = .object(deny)
        } else {
            result = ClaudeProtocol.questionResult(input: request.input, answers: answers, toolUseID: request.toolUseID)
        }
        try? write(ClaudeProtocol.controlResponse(requestID: id, result))
    }

    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        guard config != nil else { throw ProviderError.notStarted }
        let anchor: Anchor
        if let providerTurnID, let known = anchors[providerTurnID] {
            anchor = known
        } else if let providerTurnID, let found = ClaudeTranscript.anchor(beforePrompt: providerTurnID, sessionID: sessionID) {
            anchor = found.map(Anchor.message) ?? .start
        } else if ordinal <= 1 {
            anchor = .start
        } else {
            throw ProviderError.message("Claude Code's transcript has no record of turn \(ordinal), so the conversation cannot be rewound.")
        }
        switch anchor {
        case .start:
            sessionID = UUID().uuidString.lowercased()
            hasConversation = false
            resumeAt = nil
            mapper = ClaudeEventMapper(cwd: mapper.cwd ?? config?.cwd, sessionID: sessionID)
            continuation.yield(.conversationID(sessionID))
        case let .message(uuid):
            resumeAt = uuid
            mapper.rewound(to: uuid)
        }
        try await restart()
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

    private func spawn() async throws {
        guard let config, let options else { throw ProviderError.notStarted }
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("claude", explicitPath: explicit) else {
            throw ProviderError.notInstalled(.claude, path: explicit)
        }
        let arguments = ClaudeProtocol.sessionArguments(
            options: options,
            sessionID: sessionID,
            resume: hasConversation,
            resumeAt: hasConversation ? resumeAt : nil,
            additionalDirectories: config.additionalDirectories
        )
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: arguments,
            environment: ClaudeProtocol.environment(),
            directory: FileManager.default.fileExists(atPath: config.cwd) ? config.cwd : nil
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        generation += 1
        let current = generation
        self.process = process
        Task { await self.consume(process.events, generation: current) }
        _ = try await control(["subtype": "initialize"])
    }

    /// Stops the current process without ending the session (its exit is ignored).
    private func retire() {
        generation += 1
        failControlWaiters(ProviderError.notStarted)
        if let process {
            process.terminate()
        }
        process = nil
        isTurnRunning = false
    }

    private func restart() async throws {
        let old = process
        retire()
        // Let the old process flush its transcript before the new one resumes it.
        for _ in 0..<40 where old?.isRunning == true {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        pending.removeAll()
        do {
            try await spawn()
        } catch {
            retire()
            finish(error: error.localizedDescription)
            throw error
        }
    }

    private func write(_ message: JSONValue) throws {
        guard let process else { throw ProviderError.notStarted }
        try process.send(message.jsonString())
    }

    /// Sends a control request and waits for its `control_response`.
    private func control(_ request: JSONValue) async throws -> JSONValue {
        let id = "soprano_\(nextControlID)"
        nextControlID += 1
        try write(ClaudeProtocol.controlRequest(id: id, request))
        let subtype = request["subtype"]?.stringValue ?? "control"
        let timeout = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(Self.controlTimeout * 1_000_000_000))
            await self?.resolveControl(id: id, with: .failure(ProviderError.timedOut("Claude Code \(subtype)")))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            controlWaiters[id] = continuation
        }
    }

    private func resolveControl(id: String, with result: Result<JSONValue, Error>) {
        controlWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func failControlWaiters(_ error: Error) {
        let waiters = controlWaiters.values
        controlWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    // MARK: - Incoming

    private func consume(_ stream: AsyncStream<LineProcessEvent>, generation owner: Int) async {
        for await event in stream {
            guard owner == generation else { continue }
            switch event {
            case let .line(line):
                handle(line)
            case let .exited(status, stderr):
                let error = ProviderError.processExited(.claude, status: status, stderr: stderr)
                failControlWaiters(error)
                process = nil
                finish(error: isClosing ? nil : error.localizedDescription)
            }
        }
    }

    private func handle(_ line: String) {
        guard !line.isEmpty, let message = try? JSONValue.parse(line) else { return }
        switch message["type"]?.stringValue {
        case "control_response":
            let response = message["response"]
            guard let id = response?["request_id"]?.stringValue else { return }
            if response?["subtype"]?.stringValue == "error" {
                resolveControl(id: id, with: .failure(ProviderError.message(response?["error"]?.stringValue ?? "Claude Code rejected the request.")))
            } else {
                resolveControl(id: id, with: .success(response?["response"] ?? .null))
            }
        case "control_request":
            handleControlRequest(message)
        case "control_cancel_request":
            if let id = message["request_id"]?.stringValue, pending.removeValue(forKey: id) != nil {
                continuation.yield(.requestResolved(id: id))
            }
        default:
            var events = mapper.map(message)
            if message["type"]?.stringValue == "result" {
                isTurnRunning = false
                if interruptRequested {
                    interruptRequested = false
                    events = events.map { event in
                        if case .turnCompleted = event { return .turnCompleted(outcome: .interrupted, error: nil) }
                        return event
                    }
                }
            }
            for event in events { continuation.yield(event) }
        }
    }

    private func handleControlRequest(_ message: JSONValue) {
        guard let requestID = message["request_id"]?.stringValue, let request = message["request"] else { return }
        guard request["subtype"]?.stringValue == "can_use_tool" else {
            try? write(ClaudeProtocol.controlError(requestID: requestID, message: "Soprano Agents does not support \(request["subtype"]?.stringValue ?? "this request")."))
            return
        }
        let toolUseID = request["tool_use_id"]?.stringValue
        switch ClaudeEventMapper.permissionPrompt(requestID: requestID, request: request, cwd: mapper.cwd ?? config?.cwd) {
        case .exitPlan:
            try? write(ClaudeProtocol.controlResponse(requestID: requestID, ClaudeProtocol.exitPlanModeResult(toolUseID: toolUseID)))
        case let .approval(approval):
            pending[requestID] = PendingPermission(
                toolName: request["tool_name"]?.stringValue ?? "",
                input: request["input"] ?? [:],
                suggestions: request["permission_suggestions"]?.arrayValue ?? [],
                toolUseID: toolUseID
            )
            continuation.yield(.approvalRequested(approval))
        case let .question(question):
            pending[requestID] = PendingPermission(toolName: "AskUserQuestion", input: request["input"] ?? [:], suggestions: [], toolUseID: toolUseID)
            continuation.yield(.userInputRequested(question))
        }
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        isTurnRunning = false
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}

/// Reads Claude Code's own transcript (`<config>/projects/<cwd slug>/<session>.jsonl`, config =
/// `$CLAUDE_CONFIG_DIR` or `~/.claude`) to recover rollback anchors after a relaunch.
enum ClaudeTranscript {
    /// The nearest `assistant` ancestor of the user message `promptUUID`: `.some(uuid)`;
    /// `.some(nil)` when the prompt opened the conversation; nil when the prompt is not found.
    static func anchor(beforePrompt promptUUID: String, sessionID: String, configDirectory: String? = nil) -> String?? {
        guard let url = transcriptURL(sessionID: sessionID, configDirectory: configDirectory),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return anchor(beforePrompt: promptUUID, transcript: text)
    }

    static func anchor(beforePrompt promptUUID: String, transcript: String) -> String?? {
        var entries: [String: (type: String, parent: String?)] = [:]
        for line in transcript.split(separator: "\n") {
            guard let entry = try? JSONValue.parse(String(line)), let uuid = entry["uuid"]?.stringValue else { continue }
            entries[uuid] = (entry["type"]?.stringValue ?? "", entry["parentUuid"]?.stringValue)
        }
        guard let prompt = entries[promptUUID] else { return nil }
        var cursor = prompt.parent
        var visited = Set<String>()
        while let id = cursor, visited.insert(id).inserted, let entry = entries[id] {
            if entry.type == "assistant" { return .some(id) }
            cursor = entry.parent
        }
        return .some(nil)
    }

    static func transcriptURL(sessionID: String, configDirectory: String?) -> URL? {
        let config = configDirectory
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let projects = URL(fileURLWithPath: config).appendingPathComponent("projects", isDirectory: true)
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for directory in directories {
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
