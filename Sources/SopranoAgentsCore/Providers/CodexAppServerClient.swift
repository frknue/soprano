import Foundation

/// A JSON-RPC id. The Codex app-server uses numbers for its own requests but may use strings;
/// answers must echo the id exactly.
public enum JSONRPCID: Sendable, Hashable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public init?(_ value: JSONValue?) {
        switch value {
        case let .number(number)?: self = .number(Int(number))
        case let .string(text)?: self = .string(text)
        default: return nil
        }
    }

    public var json: JSONValue {
        switch self {
        case let .number(number): .number(Double(number))
        case let .string(text): .string(text)
        }
    }

    public var description: String {
        switch self {
        case let .number(number): String(number)
        case let .string(text): text
        }
    }
}

/// The `codex app-server` dialect of JSON-RPC 2.0 over newline-delimited JSON: no `jsonrpc`
/// field. Client requests `{id, method, params}` are answered by `{id, result}` or
/// `{id, error:{code, message}}`; the server sends notifications `{method, params}` and its own
/// requests `{id, method, params}`, which the owner answers with `respond(to:…)`.
///
/// Requests suspend until their response arrives; cancelling the calling task abandons the
/// request (`CancellationError`). When the transport closes, every pending request fails with
/// `ProviderError.processExited` and `incoming` ends with `.closed`.
public actor CodexAppServerClient {
    public enum Incoming: Sendable, Hashable {
        case notification(method: String, params: JSONValue)
        case request(id: JSONRPCID, method: String, params: JSONValue)
        case closed(status: Int32, stderr: String)
    }

    /// Notifications and server requests in arrival order.
    public nonisolated let incoming: AsyncStream<Incoming>

    private let transport: any JSONLineTransport
    private let incomingContinuation: AsyncStream<Incoming>.Continuation
    private var nextID = 1
    private var pending: [JSONRPCID: (method: String, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var closedError: ProviderError?

    public init(transport: any JSONLineTransport) {
        self.transport = transport
        (incoming, incomingContinuation) = AsyncStream.makeStream(of: Incoming.self, bufferingPolicy: .unbounded)
        Task { await self.readLoop() }
    }

    /// Sends a request and returns its `result`. Throws `ProviderError.rpc` for error responses.
    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = JSONRPCID.number(nextID)
        nextID += 1
        let line = JSONValue.object(["id": id.json, "method": .string(method), "params": params]).jsonString()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if let closedError {
                    continuation.resume(throwing: closedError)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = (method, continuation)
                do {
                    try transport.send(line)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: ProviderError.notStarted)
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Sends a notification (`initialized`).
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        try transport.send(JSONValue.object(message).jsonString())
    }

    /// Answers a server request.
    public func respond(to id: JSONRPCID, result: JSONValue) {
        try? transport.send(JSONValue.object(["id": id.json, "result": result]).jsonString())
    }

    /// Rejects a server request (unsupported method).
    public func respond(to id: JSONRPCID, errorCode: Int, message: String) {
        let error: JSONValue = ["code": .number(Double(errorCode)), "message": .string(message)]
        try? transport.send(JSONValue.object(["id": id.json, "error": error]).jsonString())
    }

    public func close() {
        transport.close()
    }

    // MARK: - Reading

    private func readLoop() async {
        for await event in transport.incoming {
            switch event {
            case let .line(line):
                handle(line)
            case let .exited(status, stderr):
                let error = ProviderError.processExited(.codex, status: status, stderr: stderr)
                closedError = error
                let waiting = pending.values
                pending.removeAll()
                for entry in waiting { entry.continuation.resume(throwing: error) }
                incomingContinuation.yield(.closed(status: status, stderr: stderr))
                incomingContinuation.finish()
                return
            }
        }
    }

    private func handle(_ line: String) {
        guard !line.isEmpty, let message = try? JSONValue.parse(line), message.objectValue != nil else { return }
        if let method = message["method"]?.stringValue {
            let params = message["params"] ?? .null
            if let id = JSONRPCID(message["id"]) {
                incomingContinuation.yield(.request(id: id, method: method, params: params))
            } else {
                incomingContinuation.yield(.notification(method: method, params: params))
            }
            return
        }
        guard let id = JSONRPCID(message["id"]), let entry = pending.removeValue(forKey: id) else { return }
        if let error = message["error"], !error.isNull {
            entry.continuation.resume(throwing: ProviderError.rpc(
                method: entry.method,
                code: error["code"]?.intValue ?? 0,
                message: error["message"]?.stringValue ?? error.jsonString()
            ))
        } else {
            entry.continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func abandon(_ id: JSONRPCID) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
