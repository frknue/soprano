import Foundation

/// What a chat session needs from the process it talks to, so tests can
/// stand in for a real agent.
@MainActor
protocol JSONRPCPeer: AnyObject {
    /// A notification from the agent: method and params.
    var onNotification: ((String, JSONValue) -> Void)? { get set }
    /// A request from the agent; answer it exactly once through `reply`.
    var onRequest: ((String, JSONValue, @escaping @MainActor (Result<JSONValue, JSONRPCError>) -> Void) -> Void)? { get set }
    /// The agent went away: its exit status and the end of what it wrote to stderr.
    var onExit: ((Int32, String) -> Void)? { get set }

    func start() throws
    func request(_ method: String, params: JSONValue) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue)
    func terminate()
    /// Returns once the agent's process is gone, so another process can
    /// open the same conversation. Call after `terminate()`.
    func waitForExit() async
}

/// A JSON-RPC error object, from either side.
struct JSONRPCError: Error, Equatable, Sendable {
    static let methodNotFound = -32_601
    static let internalError = -32_603

    let code: Int
    let message: String

    /// Every request still waiting when the agent exits fails with this.
    static let closed = JSONRPCError(code: -32_000, message: "The agent exited.")
}

/// A child process speaking JSON-RPC 2.0 as newline-delimited JSON on its
/// stdin and stdout, the framing the Agent Client Protocol uses. Lines that
/// are not JSON-RPC messages, such as a banner a wrapper prints, are skipped.
/// Everything is delivered on the main actor, in the order the agent wrote it.
@MainActor
final class JSONRPCConnection: JSONRPCPeer {
    /// Characters of stderr kept to explain an unexpected exit.
    static let stderrLimit = 4_000

    var onNotification: ((String, JSONValue) -> Void)?
    var onRequest: ((String, JSONValue, @escaping @MainActor (Result<JSONValue, JSONRPCError>) -> Void) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let stderrTail = StderrTail(limit: JSONRPCConnection.stderrLimit)
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Seconds an agent gets to exit after SIGTERM before it is killed.
    private let exitGracePeriod: TimeInterval

    init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        exitGracePeriod: TimeInterval = 3
    ) {
        self.exitGracePeriod = exitGracePeriod
        process.executableURL = executableURL
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        if let environment {
            process.environment = environment
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    func start() throws {
        // A write after the agent exited must fail rather than kill Soprano.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let lines = LineSplitter()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let complete = lines.append(chunk)
            guard !complete.isEmpty else { return }
            // `main.async` keeps the agent's order, which a Task would not.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in complete {
                        self?.receive(line)
                    }
                }
            }
        }
        let tail = stderrTail
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(chunk)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            // After the output handler's last delivery, so no reply is lost.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.didExit(status: status)
                }
            }
        }
        try process.run()
    }

    func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard !exited else { throw JSONRPCError.closed }
        let id = nextRequestId
        nextRequestId += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    func notify(_ method: String, params: JSONValue) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func waitForExit() async {
        // A process that never started, or is already reaped, has nothing to wait for.
        guard !exited, process.isRunning else { return }
        let processId = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + exitGracePeriod) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.exited, self.process.isRunning, processId > 0 else { return }
                kill(processId, SIGKILL)
            }
        }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    private func send(_ message: JSONValue) {
        guard !exited, var data = try? message.serialized() else { return }
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            // The exit handler fails whatever is still pending.
        }
    }

    private func receive(_ line: Data) {
        guard let message = try? JSONValue(parsing: line), message.object != nil else { return }
        let method = message["method"]?.string
        let id = message["id"]

        if let method {
            let params = message["params"] ?? .null
            guard let id, !id.isNull else {
                onNotification?(method, params)
                return
            }
            guard let onRequest else {
                reply(to: id, with: .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found: \(method)")))
                return
            }
            var answered = false
            onRequest(method, params) { [weak self] result in
                guard !answered else { return }
                answered = true
                self?.reply(to: id, with: result)
            }
            return
        }

        guard let requestId = id?.int, let continuation = pending.removeValue(forKey: requestId) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: JSONRPCError(
                code: error["code"]?.int ?? JSONRPCError.internalError,
                message: error["message"]?.string ?? "Unknown error"
            ))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func reply(to id: JSONValue, with result: Result<JSONValue, JSONRPCError>) {
        switch result {
        case .success(let value):
            send(["jsonrpc": "2.0", "id": id, "result": value])
        case .failure(let error):
            send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
        }
    }

    private func didExit(status: Int32) {
        guard !exited else { return }
        exited = true
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: JSONRPCError.closed)
        }
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
        onExit?(status, stderrTail.text)
    }
}

/// Splits a byte stream into lines. Only the output pipe's handler queue uses it.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    /// The complete lines `chunk` finishes, without their newlines.
    func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}

/// The last characters an agent wrote to stderr.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit * 2 {
            data = Data(data.suffix(limit))
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        let string = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.count > limit ? String(string.suffix(limit)) : string
    }
}
