import Foundation

/// Failures of provider processes and protocols, phrased for the UI.
public enum ProviderError: Error, LocalizedError, Sendable, Hashable {
    /// The CLI was not found (`path` = the explicit path that is not executable, if any).
    case notInstalled(ProviderKind, path: String?)
    case spawnFailed(String)
    /// The process exited while a request or turn was in flight.
    case processExited(ProviderKind, status: Int32, stderr: String)
    /// Error response to a request: omp `success:false` responses (`method` = the command
    /// type, `code` 0).
    case rpc(method: String, code: Int, message: String)
    case timedOut(String)
    case invalidOutput(String)
    case notStarted
    case noActiveTurn
    /// The thread's working directory does not exist; the agent is never started elsewhere.
    case workspaceMissing(String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(kind, path):
            if let path { return "\(kind.displayName) CLI not found at \(path)." }
            let binary = kind.executableName
            return "\(kind.displayName) CLI (`\(binary)`) not found on PATH."
        case let .spawnFailed(reason): return "Could not start the agent CLI: \(reason)"
        case let .processExited(kind, status, stderr):
            let tail = Self.lastLines(of: stderr)
            return tail.isEmpty
                ? "\(kind.displayName) exited with status \(status)."
                : "\(kind.displayName) exited with status \(status): \(tail)"
        case let .rpc(method, _, message): return "\(method) failed: \(message)"
        case let .timedOut(what): return "\(what) timed out."
        case let .invalidOutput(reason): return reason
        case .notStarted: return "The provider session is not running."
        case .noActiveTurn: return "There is no running turn to steer."
        case let .workspaceMissing(path): return EngineError.workspaceMissing(path).errorDescription
        case let .message(text): return text
        }
    }

    /// Throws `workspaceMissing` unless `path` is an existing directory.
    static func requireWorkspace(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProviderError.workspaceMissing(path)
        }
    }

    /// The last few non-empty lines of a stderr tail, for one-line error messages.
    static func lastLines(of text: String, count: Int = 3) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: " ")
    }
}

/// Runs `operation`, failing with `ProviderError.timedOut(label)` after `seconds`.
func withProviderTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    label: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ProviderError.timedOut(label)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ProviderError.timedOut(label) }
        return first
    }
}
