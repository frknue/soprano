import Foundation

/// A workspace root the user added. Threads usually belong to one; scratch threads have none.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// Absolute path of the workspace root.
    public var path: String
    public var createdAt: Date
    /// Model new threads in this project start with; nil = the app default.
    public var defaultModel: ModelSelection?
    public var scripts: [ProjectScript]

    public init(
        id: String = UUID().uuidString,
        title: String,
        path: String,
        createdAt: Date = Date(),
        defaultModel: ModelSelection? = nil,
        scripts: [ProjectScript] = []
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.createdAt = createdAt
        self.defaultModel = defaultModel
        self.scripts = scripts
    }
}

/// A named command run in the terminal drawer ("Test" → `swift test`).
public struct ProjectScript: Codable, Sendable, Hashable, Identifiable {
    public enum Icon: String, Codable, Sendable, CaseIterable {
        case play, test, lint, configure, build, debug
    }

    public var id: String
    public var name: String
    public var command: String
    public var icon: Icon
    public var runOnWorktreeCreate: Bool

    public init(id: String, name: String, command: String, icon: Icon = .play, runOnWorktreeCreate: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.runOnWorktreeCreate = runOnWorktreeCreate
    }
}

/// A file the user attached to a message. The engine copies it into app storage.
public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case image
        case file
    }

    public var id: String
    public var kind: Kind
    public var name: String
    /// Absolute path of the stored copy.
    public var path: String
    public var mimeType: String
    public var byteSize: Int

    public init(id: String = UUID().uuidString, kind: Kind, name: String, path: String, mimeType: String, byteSize: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.mimeType = mimeType
        self.byteSize = byteSize
    }
}

/// What the user sent to start (or steer) a turn.
public struct UserMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var attachments: [Attachment]
    public var createdAt: Date
    /// Sent while a turn was running and delivered into it ("↪ Steer").
    public var isSteer: Bool

    public init(id: String = UUID().uuidString, text: String, attachments: [Attachment] = [], createdAt: Date = Date(), isSteer: Bool = false) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.isSteer = isSteer
    }
}

/// A message waiting for the running turn to finish (shown dashed at the end of the thread).
public struct QueuedMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String { message.id }
    public var message: UserMessage
    public var modelSelection: ModelSelection

    public init(message: UserMessage, modelSelection: ModelSelection) {
        self.message = message
        self.modelSelection = modelSelection
    }
}

/// One agent conversation.
public struct AgentThread: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// nil = scratch thread without a project.
    public var projectID: String?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public var modelSelection: ModelSelection
    public var runtimeMode: RuntimeMode

    /// Branch the thread works on (worktree branch or the checkout's branch at creation).
    public var branch: String?
    /// Own git worktree; nil = works in the project root.
    public var worktreePath: String?

    // Inbox lifecycle (Pinned / Active / Settled / Archive).
    public var pinnedAt: Date?
    public var settledAt: Date?
    public var archivedAt: Date?
    /// Last time the user looked at the thread; drives "Done"/"Failed" unread pills.
    public var lastVisitedAt: Date?

    /// omp's conversation: the absolute path of its session file (`get_state` `sessionFile`).
    /// Used to resume.
    public var providerThreadID: String?

    public var turns: [Turn]
    public var queue: [QueuedMessage]
    /// Background title generation is running.
    public var isGeneratingTitle: Bool
    /// Latest known context fill of the thread's provider conversation (every token update,
    /// the exact reading after a turn or compaction); nil = unknown. Older files lack it.
    public var contextUsage: TokenUsage?

    public init(
        id: String = UUID().uuidString,
        projectID: String?,
        title: String = "New thread",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        modelSelection: ModelSelection,
        runtimeMode: RuntimeMode = .fullAccess,
        branch: String? = nil,
        worktreePath: String? = nil,
        pinnedAt: Date? = nil,
        settledAt: Date? = nil,
        archivedAt: Date? = nil,
        lastVisitedAt: Date? = nil,
        providerThreadID: String? = nil,
        turns: [Turn] = [],
        queue: [QueuedMessage] = [],
        isGeneratingTitle: Bool = false,
        contextUsage: TokenUsage? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.branch = branch
        self.worktreePath = worktreePath
        self.pinnedAt = pinnedAt
        self.settledAt = settledAt
        self.archivedAt = archivedAt
        self.lastVisitedAt = lastVisitedAt
        self.providerThreadID = providerThreadID
        self.turns = turns
        self.queue = queue
        self.isGeneratingTitle = isGeneratingTitle
        self.contextUsage = contextUsage
    }

    /// The last turn while it has not ended, working or yielded (`Turn.isYielded`): provider
    /// events fold into it.
    public var openTurn: Turn? {
        guard let last = turns.last, last.status == .running else { return nil }
        return last
    }

    /// The turn the agent is working on: the open turn unless it yielded.
    public var activeTurn: Turn? {
        guard let turn = openTurn, turn.yieldedAt == nil else { return nil }
        return turn
    }

    /// The agent is working (a yielded turn does not count: its answer is final).
    public var isRunning: Bool { activeTurn != nil }

    /// Timestamp the sidebar shows: the latest user message, else the last update.
    public var activityDate: Date {
        turns.last?.userMessage.createdAt ?? updatedAt
    }
}

public enum TurnStatus: String, Codable, Sendable, Hashable {
    case running
    case completed
    case interrupted
    case failed
}

/// Per-turn workspace snapshot (hidden git ref) and the files the turn changed.
public struct TurnCheckpoint: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case ready
        /// Workspace is not a git repository.
        case missing
        case error
    }

    /// Git ref of the state after the turn (`refs/soprano-agents/checkpoints/<thread>/<ordinal>`).
    public var ref: String
    public var status: Status
    public var files: [ChangedFileStat]

    public init(ref: String, status: Status, files: [ChangedFileStat] = []) {
        self.ref = ref
        self.status = status
        self.files = files
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public struct ChangedFileStat: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var additions: Int
    public var deletions: Int

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

/// One agent execution triggered by a user message.
public struct Turn: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// 1-based position in the thread; also the checkpoint ordinal.
    public var ordinal: Int
    public var userMessage: UserMessage
    public var modelSelection: ModelSelection
    public var status: TurnStatus
    public var failureMessage: String?
    public var startedAt: Date
    public var completedAt: Date?
    /// Activity log: messages, reasoning, tool calls, approvals, in arrival order.
    public var items: [TurnItem]
    /// Messages steered into this turn while it ran, in order.
    public var steers: [UserMessage]
    public var checkpoint: TurnCheckpoint?
    public var providerTurnID: String?
    public var tokenUsage: TokenUsage?
    /// When the provider's prompt yielded while background work it started still runs (omp
    /// `sessionSettled:false`): the answer is final and the thread is idle, but the turn stays
    /// open (status `.running`) so the runs that work wakes stream into it. A run clears it, the
    /// run's end sets it again. Held outcome: failed when `failureMessage` is set, else
    /// completed. Older files lack it.
    public var yieldedAt: Date?

    public init(
        id: String = UUID().uuidString,
        ordinal: Int,
        userMessage: UserMessage,
        modelSelection: ModelSelection,
        status: TurnStatus = .running,
        failureMessage: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        items: [TurnItem] = [],
        steers: [UserMessage] = [],
        checkpoint: TurnCheckpoint? = nil,
        providerTurnID: String? = nil,
        tokenUsage: TokenUsage? = nil,
        yieldedAt: Date? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.userMessage = userMessage
        self.modelSelection = modelSelection
        self.status = status
        self.failureMessage = failureMessage
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.items = items
        self.steers = steers
        self.checkpoint = checkpoint
        self.providerTurnID = providerTurnID
        self.tokenUsage = tokenUsage
        self.yieldedAt = yieldedAt
    }

    /// Open but yielded (`yieldedAt`): done for the user while background work runs.
    public var isYielded: Bool { status == .running && yieldedAt != nil }

    /// The status a yielded turn ends with when it is settled, released or recovered.
    public var yieldedStatus: TurnStatus { failureMessage == nil ? .completed : .failed }

    /// When the work ended: the completion, or the yield of a yielded turn; nil while working.
    public var endedAt: Date? { completedAt ?? (isYielded ? yieldedAt : nil) }

    /// Wall time of the turn ("Worked for 3m 12s").
    public func duration(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }

    public var pendingApproval: ApprovalRequest? {
        for item in items.reversed() {
            if case let .approval(request) = item.kind, request.decision == nil { return request }
        }
        return nil
    }

    public var pendingUserInput: UserInputRequest? {
        for item in items.reversed() {
            if case let .userInput(request) = item.kind, request.answers == nil, !request.dismissed { return request }
        }
        return nil
    }
}

public struct TokenUsage: Codable, Sendable, Hashable {
    public var usedTokens: Int
    public var contextWindow: Int?

    public init(usedTokens: Int, contextWindow: Int?) {
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
    }

    /// `usedTokens / contextWindow` (not clamped; a provider may report more than its
    /// window); nil without a positive window.
    public var fraction: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return Double(usedTokens) / Double(contextWindow)
    }
}
