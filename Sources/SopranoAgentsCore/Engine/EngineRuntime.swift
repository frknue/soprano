import Foundation

/// The engine's live, non-persisted state: provider sessions per thread, tracked background
/// work (worktree setup, titles, checkpoints, branch names) and per-workspace git serialization.
@MainActor
final class EngineRuntime {
    private var threads: [String: ThreadRuntime] = [:]
    /// All checkpoint and diff git operations on one working directory run one at a time.
    let git = KeyedSerialQueue()
    private var background: [UUID: Task<Void, Never>] = [:]
    /// Tracked work `shutdown` finishes before the store's final flush (turn checkpoints).
    private var quitWork: Set<UUID> = []
    /// Set by `shutdown` (app quit): queued messages stay queued.
    var isShuttingDown = false
    /// Delay before the first retry of a failed initial title generation (doubles per retry).
    var titleRetryDelay: Duration = .seconds(2)
    /// How long ending a yielded turn waits for the session's report before ending it locally.
    var yieldReleaseTimeout: Duration = .seconds(5)
    /// The last command list each provider reported per workspace (this run only), for drafts
    /// and threads without a live session (AgentEngine+Commands.swift).
    var rememberedCommands: [CommandScope: [ProviderCommand]] = [:]
    /// Scopes a driver was asked for their list this run (`loadCommands`), answered or not.
    var requestedCommands: Set<CommandScope> = []

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

    /// Runs `operation` as tracked background work; `beforeQuit` work is awaited by `shutdown`.
    @discardableResult
    func track(beforeQuit: Bool = false, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            await operation()
            self.background[id] = nil
            self.quitWork.remove(id)
        }
        background[id] = task
        if beforeQuit { quitWork.insert(id) }
        return task
    }

    /// Waits until no tracked background work is left, including work started meanwhile.
    func waitForBackgroundWork() async {
        while let (id, task) = background.first {
            await task.value
            background[id] = nil
            quitWork.remove(id)
        }
    }

    /// Waits until no `beforeQuit` work is left, including work started meanwhile.
    func waitForQuitWork() async {
        while let id = quitWork.first {
            await background[id]?.value
            background[id] = nil
            quitWork.remove(id)
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
    /// An "Edit from here" rewind in progress: new turns wait for it (AgentEngine+Turns.swift).
    var reverting: Task<Void, Never>?
    /// Latest title request; older ones finishing later are ignored.
    var titleRequest: UUID?
    /// The live session's command list.
    var commands: [ProviderCommand]?
    /// Side questions the provider reported this run, newest first (AgentEngine+SideQuestions.swift).
    var sideQuestions: [SideQuestion] = []
    /// `sideQuestions` holds the conversation's history (read from the provider, or restored),
    /// not only what was asked this run.
    var sideQuestionsLoaded = false
    /// An ask is starting (session start, or the provider has not reported the topic yet).
    var isAskingSideQuestion = false
    /// Stop was pressed while `isAskingSideQuestion`.
    var sideQuestionCancelRequested = false

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

