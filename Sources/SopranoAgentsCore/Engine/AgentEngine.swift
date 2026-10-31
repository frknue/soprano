import Foundation

/// The single owner of projects, threads and provider sessions. Views read its state and
/// observe `EngineEvent`s; every mutation goes through a method here.
///
/// Contract:
/// - Main actor. Provider events arrive on background tasks and are folded in on the main actor.
/// - Every state change is persisted through `environment.store` and announced with the narrowest event.
/// - `threads` contains archived threads too (`InboxSection.of` returns nil for them); deleted
///   threads are gone.
@MainActor
public final class AgentEngine {
    public let environment: EngineEnvironment
    public var settings: EngineSettings

    public private(set) var projects: [Project] = []
    public private(set) var threads: [AgentThread] = []
    public private(set) var providers: [ProviderKind: ProviderStatus] = [:]

    private var observers: [(owner: () -> AnyObject?, handler: @MainActor (EngineEvent) -> Void)] = []
    /// Provider sessions, background work and git serialization (AgentEngine+Turns.swift).
    let runtime = EngineRuntime()

    public init(environment: EngineEnvironment, settings: EngineSettings = EngineSettings()) {
        self.environment = environment
        self.settings = settings
        if let snapshot = try? environment.store.load() {
            projects = snapshot.projects
            threads = snapshot.threads
        }
        for kind in ProviderKind.allCases {
            providers[kind] = ProviderStatus(kind: kind)
        }
    }

    // MARK: Observation

    /// `handler` runs on the main actor for every event while `owner` is alive.
    public func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (EngineEvent) -> Void) {
        observers.append((owner: { [weak owner] in owner }, handler: handler))
    }

    public func emit(_ event: EngineEvent) {
        observers.removeAll { $0.owner() == nil }
        for observer in observers {
            observer.handler(event)
        }
    }

    // MARK: Reading

    public func project(_ id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func thread(_ id: String?) -> AgentThread? {
        guard let id else { return nil }
        return threads.first { $0.id == id }
    }

    /// Working directory of a thread: worktree, else project root, else its scratch directory.
    public func workingDirectory(for thread: AgentThread) -> String {
        if let worktree = thread.worktreePath { return worktree }
        if let project = project(thread.projectID) { return project.path }
        return environment.dataDirectory.appendingPathComponent("scratch/\(thread.id)").path
    }

    public func status(of provider: ProviderKind) -> ProviderStatus {
        providers[provider] ?? ProviderStatus(kind: provider)
    }

    // MARK: Mutation helpers (shared with the engine's provider plumbing)

    /// Replaces a thread in place, persists it and emits `threadChanged` (+ `threadListChanged`
    /// when list-visible fields changed).
    public func updateThread(_ id: String, _ change: (inout AgentThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let before = threads[index]
        var thread = before
        change(&thread)
        guard thread != before else { return }
        threads[index] = thread
        environment.store.save(thread: thread)
        emit(.threadChanged(threadID: id))
        if Self.listFieldsDiffer(before, thread) {
            emit(.threadListChanged)
        }
    }

    static func listFieldsDiffer(_ lhs: AgentThread, _ rhs: AgentThread) -> Bool {
        lhs.title != rhs.title
            || lhs.projectID != rhs.projectID
            || lhs.pinnedAt != rhs.pinnedAt
            || lhs.settledAt != rhs.settledAt
            || lhs.archivedAt != rhs.archivedAt
            || lhs.lastVisitedAt != rhs.lastVisitedAt
            || lhs.branch != rhs.branch
            || lhs.worktreePath != rhs.worktreePath
            || lhs.modelSelection != rhs.modelSelection
            || lhs.isGeneratingTitle != rhs.isGeneratingTitle
            || lhs.turns.count != rhs.turns.count
            || ThreadStatus.of(lhs) != ThreadStatus.of(rhs)
            || lhs.turns.last?.checkpoint != rhs.turns.last?.checkpoint
    }

    /// Inserts a new thread, persists it and emits `threadListChanged`.
    public func insertThread(_ thread: AgentThread) {
        threads.append(thread)
        environment.store.save(thread: thread)
        emit(.threadListChanged)
    }

    /// Replaces a thread in place and persists it without announcing anything; the caller emits
    /// the narrowest event (streaming deltas → `.itemChanged`). Returns the thread before and after.
    @discardableResult
    func mutateThreadQuietly(_ id: String, _ change: (inout AgentThread) -> Void) -> (before: AgentThread, after: AgentThread)? {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return nil }
        let before = threads[index]
        var thread = before
        change(&thread)
        guard thread != before else { return nil }
        threads[index] = thread
        environment.store.save(thread: thread)
        return (before, thread)
    }

    /// Removes a thread from memory and the store and emits `threadListChanged`.
    func removeThreadRecord(_ id: String) {
        guard threads.contains(where: { $0.id == id }) else { return }
        threads.removeAll { $0.id == id }
        environment.store.deleteThread(id: id)
        emit(.threadListChanged)
    }

    public func setProviderStatus(_ status: ProviderStatus) {
        providers[status.kind] = status
        emit(.providersChanged)
    }

    // MARK: Projects

    /// Adds a workspace root. Adding the same path twice returns the existing project.
    @discardableResult
    public func addProject(path: String) -> Project {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == standardized }) { return existing }
        let project = Project(title: URL(fileURLWithPath: standardized).lastPathComponent, path: standardized, createdAt: environment.now())
        projects.append(project)
        environment.store.save(project: project)
        emit(.projectsChanged)
        return project
    }

    public func updateProject(_ id: String, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        change(&project)
        guard project != projects[index] else { return }
        projects[index] = project
        environment.store.save(project: project)
        emit(.projectsChanged)
    }

    /// Removes the project from the app. Its threads stay, detached as scratch threads keep their history.
    public func removeProject(_ id: String) {
        guard projects.contains(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        environment.store.deleteProject(id: id)
        emit(.projectsChanged)
    }

    // MARK: Thread lifecycle (inbox)

    public func rename(_ threadID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateThread(threadID) { $0.title = trimmed }
    }

    public func setPinned(_ threadID: String, _ pinned: Bool) {
        let now = environment.now()
        updateThread(threadID) { $0.pinnedAt = pinned ? ($0.pinnedAt ?? now) : nil }
    }

    public func setSettled(_ threadID: String, _ settled: Bool) {
        let now = environment.now()
        updateThread(threadID) { $0.settledAt = settled ? ($0.settledAt ?? now) : nil }
    }

    public func setArchived(_ threadID: String, _ archived: Bool) {
        let now = environment.now()
        updateThread(threadID) { $0.archivedAt = archived ? ($0.archivedAt ?? now) : nil }
    }

    /// The user looked at the thread: clears its Done/Failed pill.
    public func markVisited(_ threadID: String) {
        let now = environment.now()
        updateThread(threadID) { $0.lastVisitedAt = now }
    }

    public func markUnread(_ threadID: String) {
        updateThread(threadID) { $0.lastVisitedAt = nil }
    }

    public func setModelSelection(_ threadID: String, _ selection: ModelSelection) {
        updateThread(threadID) { $0.modelSelection = selection }
    }

    public func setRuntimeMode(_ threadID: String, _ mode: RuntimeMode) {
        updateThread(threadID) { $0.runtimeMode = mode }
    }
}
