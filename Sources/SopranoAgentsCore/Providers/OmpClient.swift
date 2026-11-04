import Foundation

/// omp's RPC JSONL over a line transport: reassembles `rpc_chunk` sequences, remembers the
/// `ready` frame, matches `{"type":"response","id",…}` frames to `request`s and hands every
/// other frame (events, `prompt_result`, `extension_ui_request`, unmatched responses) to
/// `incoming` in arrival order. Successful `prompt` responses go to `incoming` as well, after
/// resuming their request: a prompt omp finished locally (`agentInvoked:false`, slash commands)
/// ends there, behind the `command_output` frames written before it.
///
/// Requests suspend until their response; `success:false` throws `ProviderError.rpc(method:
/// <type>, code: 0, message: <error>)`. When the transport closes, waiting requests fail with
/// `ProviderError.processExited` and `incoming` ends with `.closed`.
public actor OmpClient {
    public enum Incoming: Sendable, Hashable {
        case frame(JSONValue)
        case closed(status: Int32, stderr: String)
    }

    public nonisolated let incoming: AsyncStream<Incoming>

    private let transport: any JSONLineTransport
    private let incomingContinuation: AsyncStream<Incoming>.Continuation
    private var decoder = OmpFrameDecoder()
    private var nextID = 1
    private var pending: [String: (type: String, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var readyFrame: JSONValue?
    private var readyWaiters: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextReadyWaiter = 0
    private var closedError: ProviderError?

    public init(transport: any JSONLineTransport) {
        self.transport = transport
        (incoming, incomingContinuation) = AsyncStream.makeStream(of: Incoming.self, bufferingPolicy: .unbounded)
        Task { await self.readLoop() }
    }

    /// The `ready` frame (waits for it). Throws when the process exits first, or
    /// `CancellationError` when the waiting task is cancelled (a startup timeout).
    public func ready() async throws -> JSONValue {
        if let readyFrame { return readyFrame }
        if let closedError { throw closedError }
        let waiter = nextReadyWaiter
        nextReadyWaiter += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                readyWaiters[waiter] = continuation
            }
        } onCancel: {
            Task { await self.abandonReady(waiter) }
        }
    }

    /// Sends `{"type": type, "id": id ?? "soprano-<n>", …fields}` and returns the response's
    /// `data` (`null` when absent).
    public func request(_ type: String, _ fields: [String: JSONValue] = [:], id explicitID: String? = nil) async throws -> JSONValue {
        let id = explicitID ?? nextRequestID()
        let line = OmpProtocol.command(type, id: id, fields).jsonString()
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
                pending[id] = (type, continuation)
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

    /// A fresh command id ("soprano-<n>").
    public func nextRequestID() -> String {
        defer { nextID += 1 }
        return "soprano-\(nextID)"
    }

    /// Writes a frame without waiting (`extension_ui_response`).
    public func send(_ frame: JSONValue) throws {
        try transport.send(frame.jsonString())
    }

    public func close() {
        transport.close()
    }

    // MARK: - Reading

    private func readLoop() async {
        for await event in transport.incoming {
            switch event {
            case let .line(line):
                for output in decoder.decode(line) {
                    if case let .frame(frame) = output { handle(frame) }
                }
            case let .exited(status, stderr):
                let error = ProviderError.processExited(.omp, status: status, stderr: stderr)
                closedError = error
                let waiting = pending.values
                pending.removeAll()
                for entry in waiting { entry.continuation.resume(throwing: error) }
                let readers = readyWaiters
                readyWaiters.removeAll()
                for waiter in readers.values { waiter.resume(throwing: error) }
                incomingContinuation.yield(.closed(status: status, stderr: stderr))
                incomingContinuation.finish()
                return
            }
        }
    }

    private func handle(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "ready":
            readyFrame = frame
            if let limit = frame["maxReassembledFrameBytes"]?.intValue, limit > 0 { decoder.maxBytes = limit }
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(returning: frame) }
        case "response":
            guard let id = frame["id"]?.stringValue, let entry = pending.removeValue(forKey: id) else {
                incomingContinuation.yield(.frame(frame))
                return
            }
            if frame["success"]?.boolValue == false {
                let message = frame["error"]?.stringValue ?? frame["error"]?["message"]?.stringValue ?? "omp rejected \(entry.type)."
                entry.continuation.resume(throwing: ProviderError.rpc(method: entry.type, code: 0, message: message))
            } else {
                entry.continuation.resume(returning: frame["data"] ?? .null)
                if entry.type == "prompt" { incomingContinuation.yield(.frame(frame)) }
            }
        default:
            incomingContinuation.yield(.frame(frame))
        }
    }

    private func abandon(_ id: String) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func abandonReady(_ waiter: Int) {
        readyWaiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }
}
