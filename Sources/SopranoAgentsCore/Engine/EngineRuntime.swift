import Foundation

/// The engine's live, non-persisted state: provider sessions per thread, tracked background
/// work (worktree setup, titles, checkpoints, branch names) and per-workspace git serialization.
@MainActor
final class EngineRuntime {
    private var threads: [String: ThreadRuntime] = [:]
    /// All checkpoint and diff git operations on one working directory run one at a time.
    let git = KeyedSerialQueue()
    private var background: [UUID: Task<Void, Never>] = [:]
    /// Delay before the first retry of a failed initial title generation (doubles per retry).
    var titleRetryDelay: Duration = .seconds(2)

    func thread(_ id: String) -> ThreadRuntime {
        if let existing = threads[id] { return existing }
        let created = ThreadRuntime()
        threads[id] = created
        return created
    }

    func existingThread(_ id: String) -> ThreadRuntime? {
        threads[id]
    }

    func removeThread(_ id: String) -> ThreadRuntime? {
        threads.removeValue(forKey: id)
    }

    var allThreads: [(id: String, runtime: ThreadRuntime)] {
        threads.map { (id: $0.key, runtime: $0.value) }
    }

    /// Runs `operation` as tracked background work.
    @discardableResult
    func track(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            await operation()
            self.background[id] = nil
        }
        background[id] = task
        return task
    }

    /// Waits until no tracked background work is left, including work started meanwhile.
    func waitForBackgroundWork() async {
        while let (id, task) = background.first {
            await task.value
            background[id] = nil
        }
    }
}

/// Live state of one thread's provider conversation.
@MainActor
final class ThreadRuntime {
    var session: (any ProviderSession)?
    /// A session that is being started; concurrent senders await it instead of starting another.
    var starting: Task<any ProviderSession, any Error>?
    var consumer: Task<Void, Never>?
    /// Worktree setup + first send of a launched thread.
    var launch: Task<Void, Never>?
    /// Engine turn id whose provider turn is live (started at the provider and not finished).
    var liveTurnID: String?
    /// Set by interrupt: the queue does not drain when the interrupted turn ends.
    var holdQueue = false
    /// Latest title request; older ones finishing later are ignored.
    var titleRequest: UUID?

    func dropSession() {
        consumer?.cancel()
        consumer = nil
        session = nil
        starting = nil
    }
}

/// Serializes async operations per key (a working directory) on the main actor.
@MainActor
final class KeyedSerialQueue {
    private var tails: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(_ key: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tails[key]
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        let tail = Task<Void, Never> { _ = await task.result }
        tails[key] = tail
        let result = await task.result
        if tails[key] == tail { tails[key] = nil }
        return try result.get()
    }
}

