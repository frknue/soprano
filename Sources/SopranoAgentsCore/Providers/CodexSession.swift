import Foundation

/// One Codex conversation on its own `codex app-server` process.
///
/// Spawn: `codex app-server` (env `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Soprano Agents`, extended
/// PATH, cwd = the thread's workspace). Handshake `initialize` + `initialized`, then
/// `thread/start {cwd, model, config}` or `thread/resume {threadId, excludeTurns:true, cwd, model,
/// config}` (an "archived" error is fixed with `thread/unarchive {threadId}` and one retry).
/// Turns: `turn/start` (see `CodexProtocol.turnStartParams`), `turn/steer {threadId,
/// expectedTurnId, input}`, `turn/interrupt {threadId, turnId}`, `thread/revert {threadId,
/// beforeTurnId}`. Approvals and questions are server requests answered with the same JSON-RPC
/// id; `serverRequest/resolved` withdraws them. Notifications of other threads (subagents) are
/// ignored.
public actor CodexSession: ProviderSession {
    public nonisolated let kind = ProviderKind.codex
    public nonisolated let events: AsyncStream<ProviderEvent>

    private struct PendingRequest {
        var rpcID: JSONRPCID
        var method: String
        var params: JSONValue
        var questionIDs: [String]
    }

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let executablePath: @Sendable () -> String?
    private var process: LineProcess?
    private var client: CodexAppServerClient?
    private var threadID: String?
    private var cwd = ""
    private var activeTurnID: String?
    private var mapper = CodexEventMapper()
    private var pending: [String: PendingRequest] = [:]
    private var requestIDs: [JSONRPCID: String] = [:]
    private var isClosing = false
    private var hasEnded = false

    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        self.executablePath = executablePath
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .unbounded)
    }

    public func start(_ config: SessionConfig) async throws -> String {
        guard process == nil, !hasEnded else { throw ProviderError.message("The Codex session was already started.") }
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("codex", explicitPath: explicit) else {
            throw ProviderError.notInstalled(.codex, path: explicit)
        }
        cwd = config.cwd
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: ["app-server"],
            environment: ExecutableLocator.childEnvironment(overrides: CodexProtocol.originatorEnvironment),
            directory: FileManager.default.fileExists(atPath: config.cwd) ? config.cwd : nil
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        let client = CodexAppServerClient(transport: process)
        self.process = process
        self.client = client
        Task { await self.consume(client.incoming) }

        do {
            _ = try await client.request("initialize", params: CodexProtocol.initializeParams(version: ProviderPrompt.clientVersion))
            try await client.notify("initialized")
            let model = config.modelSelection.model
            let result: JSONValue
            if let resumeID = config.resumeID {
                let params = CodexProtocol.threadResumeParams(threadID: resumeID, cwd: config.cwd, model: model)
                do {
                    result = try await client.request("thread/resume", params: params)
                } catch where CodexProtocol.isArchivedThreadError(error) {
                    _ = try await client.request("thread/unarchive", params: ["threadId": .string(resumeID)])
                    result = try await client.request("thread/resume", params: params)
                }
            } else {
                result = try await client.request("thread/start", params: CodexProtocol.threadStartParams(cwd: config.cwd, model: model))
            }
            guard let id = result["thread"]?["id"]?.stringValue else {
                throw ProviderError.invalidOutput("Codex did not return a thread id.")
            }
            threadID = id
            continuation.yield(.conversationID(id))
            return id
        } catch {
            isClosing = true
            process.terminate()
            throw error
        }
    }

    public func startTurn(_ input: TurnInput) async throws -> String? {
        guard let client, let threadID else { throw ProviderError.notStarted }
        let result = try await client.request("turn/start", params: CodexProtocol.turnStartParams(threadID: threadID, cwd: cwd, input: input))
        let turnID = result["turn"]?["id"]?.stringValue
        if let turnID { activeTurnID = turnID }
        return turnID
    }

    public func steer(_ input: TurnInput) async throws {
        guard let client, let threadID else { throw ProviderError.notStarted }
        guard let activeTurnID else { throw ProviderError.noActiveTurn }
        _ = try await client.request("turn/steer", params: CodexProtocol.turnSteerParams(threadID: threadID, turnID: activeTurnID, input: input))
    }

    public func interrupt() async {
        guard let client, let threadID, let activeTurnID else { return }
        _ = try? await client.request("turn/interrupt", params: ["threadId": .string(threadID), "turnId": .string(activeTurnID)])
    }

    public func respond(toApproval id: String, decision: ApprovalDecision, feedback: String?) async {
        guard let request = take(id) else { return }
        await client?.respond(to: request.rpcID, result: CodexProtocol.approvalResult(method: request.method, params: request.params, decision: decision))
    }

    public func answer(userInput id: String, answers: [String: [String]]) async {
        guard let request = take(id) else { return }
        await client?.respond(to: request.rpcID, result: CodexProtocol.userInputResult(answers: answers, questionIDs: request.questionIDs))
    }

    /// `thread/revert {threadId, beforeTurnId}`. Without a known turn id, the ordinal-th turn
    /// is looked up with `thread/turns/list` (ascending). Reverting only rewrites the history;
    /// files are restored by the engine's checkpoints.
    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        guard let client, let threadID else { throw ProviderError.notStarted }
        var target = providerTurnID
        if target == nil { target = try await turnID(atOrdinal: ordinal, client: client, threadID: threadID) }
        guard let target else { return }
        _ = try await client.request("thread/revert", params: ["threadId": .string(threadID), "beforeTurnId": .string(target)])
        activeTurnID = nil
    }

    public func close() async {
        guard !isClosing else { return }
        isClosing = true
        if let process {
            process.terminate()
        } else {
            finish(error: nil)
        }
    }

    // MARK: - Incoming

    private func consume(_ stream: AsyncStream<CodexAppServerClient.Incoming>) async {
        for await message in stream {
            switch message {
            case let .notification(method, params):
                handleNotification(method: method, params: params)
            case let .request(id, method, params):
                await handleServerRequest(id: id, method: method, params: params)
            case let .closed(status, stderr):
                let error = isClosing ? nil : ProviderError.processExited(.codex, status: status, stderr: stderr).localizedDescription
                finish(error: error)
            }
        }
    }

    private func handleNotification(method: String, params: JSONValue) {
        if let threadID, let other = params["threadId"]?.stringValue, other != threadID { return }
        switch method {
        case "serverRequest/resolved":
            if let rpcID = JSONRPCID(params["requestId"]), let id = requestIDs.removeValue(forKey: rpcID) {
                pending[id] = nil
                continuation.yield(.requestResolved(id: id))
            }
            return
        case "turn/started":
            activeTurnID = params["turn"]?["id"]?.stringValue ?? activeTurnID
        case "turn/completed":
            activeTurnID = nil
        default:
            break
        }
        for event in mapper.map(method: method, params: params) {
            continuation.yield(event)
        }
    }

    private func handleServerRequest(id: JSONRPCID, method: String, params: JSONValue) async {
        if method == "mcpServer/elicitation/request" {
            await client?.respond(to: id, result: ["action": "decline"])
            return
        }
        guard let event = mapper.serverRequest(method: method, params: params, rpcID: id) else {
            await client?.respond(to: id, errorCode: -32601, message: "Soprano Agents does not support \(method).")
            return
        }
        let requestID: String
        var questionIDs: [String] = []
        switch event {
        case let .approvalRequested(request): requestID = request.id
        case let .userInputRequested(request):
            requestID = request.id
            questionIDs = request.questions.map(\.id)
        default: return
        }
        pending[requestID] = PendingRequest(rpcID: id, method: method, params: params, questionIDs: questionIDs)
        requestIDs[id] = requestID
        continuation.yield(event)
    }

    private func take(_ id: String) -> PendingRequest? {
        guard let request = pending.removeValue(forKey: id) else { return nil }
        requestIDs[request.rpcID] = nil
        return request
    }

    private func turnID(atOrdinal ordinal: Int, client: CodexAppServerClient, threadID: String) async throws -> String? {
        var seen = 0
        var cursor: JSONValue = .null
        var visited = Set<String>()
        while true {
            let page = try await client.request("thread/turns/list", params: [
                "threadId": .string(threadID), "cursor": cursor, "limit": 100, "sortDirection": "asc", "itemsView": "notLoaded",
            ])
            for turn in page["data"]?.arrayValue ?? [] {
                seen += 1
                if seen == ordinal { return turn["id"]?.stringValue }
            }
            guard let next = page["nextCursor"]?.stringValue, visited.insert(next).inserted else { return nil }
            cursor = .string(next)
        }
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        process = nil
        client = nil
        activeTurnID = nil
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}
