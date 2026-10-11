import Foundation

/// The account choices an agent pane needs when it starts.
///
/// Lock-protected rather than main-actor isolated, like `AgentCatalog`:
/// `TerminalConfig.forAgent` builds launch configs outside the main actor's
/// isolation. `AccountsController` publishes into it after every change.
final class AccountLaunchState: @unchecked Sendable {
    static let shared = AccountLaunchState()

    struct Adjustments: Equatable {
        /// Exported for the agent after the login shell's rc files ran.
        var environment: [String: String] = [:]
        var arguments: [String] = []
    }

    private let lock = NSLock()
    private var codexHome: URL?
    private var codexSource: URL?
    private var ompOverlay: URL?

    func update(codexHome: URL?, codexSource: URL, ompOverlay: URL?) {
        lock.lock()
        defer { lock.unlock() }
        self.codexHome = codexHome
        self.codexSource = codexSource
        self.ompOverlay = ompOverlay
    }

    func adjustments(forProfile profileId: String) -> Adjustments {
        lock.lock()
        let codexHome = codexHome
        let codexSource = codexSource
        let ompOverlay = ompOverlay
        lock.unlock()

        switch profileId {
        case "codex":
            guard let codexHome, let codexSource else { return Adjustments() }
            // Link whatever ~/.codex gained since the account was added, and
            // fold back any shared file Codex replaced while running here.
            try? CodexHomeLinker.sync(home: codexHome, source: codexSource)
            return Adjustments(environment: ["CODEX_HOME": codexHome.path])
        case "omp":
            // omp treats a missing --config file as an error, so pass it only
            // once it exists.
            guard let ompOverlay, FileManager.default.fileExists(atPath: ompOverlay.path) else {
                return Adjustments()
            }
            return Adjustments(arguments: ["--config", ompOverlay.path])
        default:
            return Adjustments()
        }
    }
}

/// Runs async operations one after another, so two account actions never
/// interleave at their suspension points (a switch racing a token read-back).
@MainActor
final class AsyncSerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
