import Foundation

/// What changed. Views re-read the engine's state for the ids they show.
public enum EngineEvent: Sendable, Hashable {
    case projectsChanged
    /// Threads added, removed, renamed, re-sectioned, or their status pill changed.
    case threadListChanged
    /// A thread's turns, queue or settings changed.
    case threadChanged(threadID: String)
    /// Streaming update of one item (text delta, command output). Cheap path for the timeline.
    case itemChanged(threadID: String, turnID: String, itemID: String)
    case providersChanged
}

/// Where a new thread works.
public enum WorkspaceChoice: Sendable, Hashable {
    /// The project root as it is checked out ("Current checkout").
    case projectRoot
    /// A new git worktree on a fresh branch from `baseBranch` ("New worktree").
    case newWorktree(baseBranch: String)
    /// Reuse an existing worktree ("Previous worktree (branch)").
    case existingWorktree(path: String, branch: String)
}

/// The composer's choices for a thread that has not been sent yet.
public struct ThreadDraft: Sendable, Hashable {
    public var projectID: String?
    public var modelSelection: ModelSelection
    public var runtimeMode: RuntimeMode
    public var interactionMode: InteractionMode
    public var workspace: WorkspaceChoice

    public init(
        projectID: String?,
        modelSelection: ModelSelection,
        runtimeMode: RuntimeMode = .fullAccess,
        interactionMode: InteractionMode = .build,
        workspace: WorkspaceChoice = .projectRoot
    ) {
        self.projectID = projectID
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
        self.workspace = workspace
    }
}

/// How a message sent while a turn runs is delivered.
public enum SendMode: Sendable, Hashable {
    /// Start a turn, or steer the running one (the default follow-up behavior).
    case automatic
    case steer
    /// Wait until the running turn ends.
    case queue
}

/// Engine settings the app resolves from settings.json and pushes in.
public struct EngineSettings: Sendable, Hashable {
    public var defaultModel: ModelSelection
    public var defaultRuntimeMode: RuntimeMode
    /// Provider + model for titles, commit messages and branch names.
    public var textGenerationModel: ModelSelection
    /// Prefix of temporary and generated worktree branches ("soprano" → `soprano/fix-login`).
    public var branchPrefix: String
    /// Absolute directory new worktrees go under (`<dir>/<repo>/<branch>`).
    public var worktreesDirectory: String
    /// Generate thread titles with `textGenerationModel` after the first message.
    public var generateTitles: Bool
    /// Executable overrides; nil = find `omp` / `codex` / `claude` on PATH.
    public var ompPath: String?
    public var codexPath: String?
    public var claudePath: String?

    public init(
        defaultModel: ModelSelection = .default(for: .omp),
        defaultRuntimeMode: RuntimeMode = .fullAccess,
        textGenerationModel: ModelSelection = ModelSelection(provider: .codex, model: ProviderKind.codex.textGenerationModel, options: ["effort": "low"]),
        branchPrefix: String = "soprano",
        worktreesDirectory: String = NSString(string: "~/.soprano-agents/worktrees").expandingTildeInPath,
        generateTitles: Bool = true,
        ompPath: String? = nil,
        codexPath: String? = nil,
        claudePath: String? = nil
    ) {
        self.defaultModel = defaultModel
        self.defaultRuntimeMode = defaultRuntimeMode
        self.textGenerationModel = textGenerationModel
        self.branchPrefix = branchPrefix
        self.worktreesDirectory = worktreesDirectory
        self.generateTitles = generateTitles
        self.ompPath = ompPath
        self.codexPath = codexPath
        self.claudePath = claudePath
    }
}

public enum EngineError: Error, LocalizedError, Sendable, Hashable {
    case unknownThread(String)
    case unknownProject(String)
    case providerUnavailable(ProviderKind, String)
    case emptyMessage
    case turnRunning
    case nothingToRevert
    /// The thread's working directory (worktree or project root) is gone.
    case workspaceMissing(String)
    /// "Edit from here" rewound the conversation (`message` goes back to the composer) but the
    /// files could not be restored.
    case filesNotRestored(message: UserMessage, reason: String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownThread(id): "Unknown thread \(id)."
        case let .unknownProject(id): "Unknown project \(id)."
        case let .providerUnavailable(kind, reason): "\(kind.displayName) is unavailable: \(reason)"
        case .emptyMessage: "Turn requires non-empty text or attachments."
        case .turnRunning: "Interrupt the current turn before reverting checkpoints."
        case .nothingToRevert: "There is no checkpoint to revert to."
        case let .workspaceMissing(path): "The workspace folder \(path) doesn't exist, so the agent was not started. Restore the folder or start a new thread."
        case let .filesNotRestored(_, reason): "The conversation was rewound, but the files could not be restored: \(reason)"
        case let .message(text): text
        }
    }
}

/// Persisted state as loaded at launch.
public struct StoreSnapshot: Sendable, Hashable {
    public var projects: [Project]
    public var threads: [AgentThread]

    public init(projects: [Project] = [], threads: [AgentThread] = []) {
        self.projects = projects
        self.threads = threads
    }
}

/// Persistence for projects and threads. Writes may be coalesced; `flush()` forces them out.
public protocol ThreadStore: Sendable {
    func load() throws -> StoreSnapshot
    func save(project: Project)
    func deleteProject(id: String)
    func save(thread: AgentThread)
    func deleteThread(id: String)
    func flush()
}

/// Keeps everything in memory. Fixtures, the snapshot harness and tests use it.
public final class InMemoryThreadStore: ThreadStore, @unchecked Sendable {
    private let lock = NSLock()
    private var projects: [String: Project]
    private var threads: [String: AgentThread]

    public init(_ snapshot: StoreSnapshot = StoreSnapshot()) {
        projects = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        threads = Dictionary(snapshot.threads.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func load() throws -> StoreSnapshot {
        lock.withLock {
            StoreSnapshot(
                projects: projects.values.sorted { $0.createdAt < $1.createdAt },
                threads: threads.values.sorted { $0.createdAt < $1.createdAt }
            )
        }
    }

    public func save(project: Project) { lock.withLock { projects[project.id] = project } }
    public func deleteProject(id: String) { lock.withLock { _ = projects.removeValue(forKey: id) } }
    public func save(thread: AgentThread) { lock.withLock { threads[thread.id] = thread } }
    public func deleteThread(id: String) { lock.withLock { _ = threads.removeValue(forKey: id) } }
    public func flush() {}
}

/// Injected dependencies of the engine.
public struct EngineEnvironment: Sendable {
    public var drivers: [ProviderKind: any ProviderDriver]
    public var git: any GitService
    public var store: any ThreadStore
    /// App data root: attachments, scratch workspaces.
    public var dataDirectory: URL
    /// Lists and reads working-directory files for the right panel.
    public var files: any WorkspaceFileService
    public var now: @Sendable () -> Date

    public init(
        drivers: [ProviderKind: any ProviderDriver],
        git: any GitService,
        store: any ThreadStore,
        dataDirectory: URL,
        files: any WorkspaceFileService = LiveWorkspaceFileService(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.drivers = drivers
        self.git = git
        self.store = store
        self.dataDirectory = dataDirectory
        self.files = files
        self.now = now
    }
}

/// Checkpoint ref naming shared by engine and git: `refs/soprano-agents/checkpoints/<thread>/<ordinal>`.
/// Ordinal 0 is the baseline before the first turn; ordinal N the state after turn N.
public enum CheckpointRef {
    public static let prefix = "refs/soprano-agents/checkpoints"

    public static func ref(threadID: String, ordinal: Int) -> String {
        "\(prefix)/\(threadID)/\(ordinal)"
    }
}
