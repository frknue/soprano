import Foundation

/// Settings a provider session starts or resumes with.
public struct SessionConfig: Sendable, Hashable {
    /// Working directory: the thread's worktree, else the project root, else a scratch dir.
    public var cwd: String
    public var modelSelection: ModelSelection
    public var runtimeMode: RuntimeMode
    /// omp session file to resume (`AgentThread.providerThreadID`); nil = new.
    public var resumeID: String?

    public init(
        cwd: String,
        modelSelection: ModelSelection,
        runtimeMode: RuntimeMode,
        resumeID: String? = nil
    ) {
        self.cwd = cwd
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.resumeID = resumeID
    }
}

/// Input for one turn (or a steer into the running turn).
public struct TurnInput: Sendable, Hashable {
    public var text: String
    public var attachments: [Attachment]
    /// Applies from this turn on; the session switches model/effort in place.
    public var modelSelection: ModelSelection
    public var runtimeMode: RuntimeMode

    public init(text: String, attachments: [Attachment], modelSelection: ModelSelection, runtimeMode: RuntimeMode) {
        self.text = text
        self.attachments = attachments
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
    }
}

public enum ProviderTurnOutcome: String, Sendable, Hashable {
    case completed
    case interrupted
    case failed
}

/// Normalized events every provider session emits. The engine folds them into the active turn.
public enum ProviderEvent: Sendable, Hashable {
    /// Native conversation id became known (omp `get_state` `sessionFile`).
    case conversationID(String)
    case turnStarted(providerTurnID: String?)
    /// Insert or replace an item by id (status and content are authoritative).
    case itemUpdated(TurnItem)
    /// Append streamed assistant text to `.assistantMessage` item `itemID` (created if missing).
    case assistantDelta(itemID: String, delta: String, isFinal: Bool)
    /// Append streamed reasoning text to `.reasoning` item `itemID` (created if missing).
    case reasoningDelta(itemID: String, delta: String)
    /// Append live output to `.command` item `itemID`.
    case commandOutputDelta(itemID: String, delta: String)
    /// The agent needs an approval; becomes an `.approval` item and blocks until answered.
    case approvalRequested(ApprovalRequest)
    /// The agent asks questions; becomes a `.userInput` item and blocks until answered.
    case userInputRequested(UserInputRequest)
    /// The provider resolved or withdrew a pending request on its own.
    case requestResolved(id: String)
    /// The conversation's context fill: per-turn usage, and (omp `get_state`) the exact fill
    /// read after a turn or a compaction.
    case tokenUsage(TokenUsage)
    /// The provider's slash commands and skills (the complete list; replaces the previous one).
    case commands([ProviderCommand])
    case turnCompleted(outcome: ProviderTurnOutcome, error: String?)
    /// The prompt yielded (`completed` or `failed`) while background work it started can still
    /// wake the agent (omp `sessionSettled:false`): the answer is final and the thread idle, but
    /// the turn stays open until `turnCompleted` (with this outcome) or `releaseYieldedTurn()`.
    /// A woken run's end yields again.
    case turnYielded(outcome: ProviderTurnOutcome, error: String?)
    /// Background work woke the agent after `turnYielded`: the turn works again, its events fold
    /// into it.
    case turnResumed
    /// The process exited or the session broke; a running turn fails with `error`.
    case sessionEnded(error: String?)
    /// One of the conversation's subagents changed (omp `subagent_*` frames).
    case subagent(id: String, SubagentEvent)
}

/// What a subagent's provider reports; the engine folds it into `AgentThread.subagents`.
public enum SubagentEvent: Sendable, Hashable {
    /// Its facts changed; nil fields are unchanged. The first one creates the subagent.
    case updated(SubagentInfo)
    /// A run began, woken by `message` (its assignment, a steer, a message from the parent;
    /// nil = unknown). It becomes a new turn of the subagent.
    case runStarted(message: String?)
    /// A message reached the running run (a steer, a message from the parent).
    case message(String)
    /// Insert or replace an item of the open run (like `ProviderEvent.itemUpdated`).
    case itemUpdated(TurnItem)
    case assistantDelta(itemID: String, delta: String)
    case reasoningDelta(itemID: String, delta: String)
    case commandOutputDelta(itemID: String, delta: String)
    /// The run ended.
    case runEnded(outcome: ProviderTurnOutcome, error: String?)
}

/// Facts about a subagent; nil = not reported (unchanged).
public struct SubagentInfo: Sendable, Hashable {
    public var agent: String?
    public var description: String?
    public var assignment: String?
    public var status: SubagentStatus?
    public var model: String?
    public var lastIntent: String?
    public var sessionFile: String?
    public var parentToolCallID: String?
    public var isDetached: Bool?

    public init(
        agent: String? = nil,
        description: String? = nil,
        assignment: String? = nil,
        status: SubagentStatus? = nil,
        model: String? = nil,
        lastIntent: String? = nil,
        sessionFile: String? = nil,
        parentToolCallID: String? = nil,
        isDetached: Bool? = nil
    ) {
        self.agent = agent
        self.description = description
        self.assignment = assignment
        self.status = status
        self.model = model
        self.lastIntent = lastIntent
        self.sessionFile = sessionFile
        self.parentToolCallID = parentToolCallID
        self.isDetached = isDetached
    }
}

/// One live provider conversation, owned by one thread. Implementations are actors or
/// otherwise thread-safe; every method may be called from the engine's main actor.
public protocol ProviderSession: AnyObject, Sendable {
    var kind: ProviderKind { get }

    /// Events in arrival order. Finishes after `sessionEnded`.
    var events: AsyncStream<ProviderEvent> { get }

    /// Spawns the process and opens or resumes the conversation. Returns the native conversation id.
    func start(_ config: SessionConfig) async throws -> String

    /// Starts a turn. Returns the native turn id when the provider reports one.
    func startTurn(_ input: TurnInput) async throws -> String?

    /// Delivers a message into the running turn.
    func steer(_ input: TurnInput) async throws

    func interrupt() async

    /// The user moved on from a yielded turn (`turnYielded`): end it now, reported like its
    /// settlement (`turnStarted` with its native id, context usage, `turnCompleted` with the
    /// yielded outcome), and forget the held prompt without stopping the background work.
    /// Nothing happens when no turn is yielded.
    func releaseYieldedTurn() async

    func respond(toApproval id: String, decision: ApprovalDecision) async

    func answer(userInput id: String, answers: [String: [String]]) async

    /// Compacts the conversation as a turn of its own (the engine runs it for a `/compact`
    /// message): returns once the provider accepted it. Its progress arrives as events like a
    /// turn's (`turnStarted`, a notice or error item, `tokenUsage` with the new fill) and it
    /// ends with `turnCompleted`; `interrupt()` cancels it where the provider can.
    func compact() async throws

    /// Truncates the native conversation to before turn `ordinal` (1-based, as the engine counts).
    /// `providerTurnID` is that turn's native id when known.
    func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws

    /// Sends `text` to a running subagent as its user: a mid-run subagent gets it at its next
    /// step, an idle one starts a new run. Its arrival is reported as a `SubagentEvent`.
    func steerSubagent(_ id: String, text: String) async throws

    /// Stops a running subagent without stopping the thread's turn.
    func cancelSubagent(_ id: String) async throws

    /// Terminates the process. Safe to call twice.
    func close() async
}

extension ProviderSession {
    /// Providers that never yield an unsettled turn have nothing to release.
    public func releaseYieldedTurn() async {}
}

/// Creates sessions and probes the installed CLI for one provider.
public protocol ProviderDriver: Sendable {
    var kind: ProviderKind { get }

    /// Version, auth and model catalog. Never throws; problems land in `ProviderStatus.health`.
    func probe() async -> ProviderStatus

    func makeSession() -> any ProviderSession

    /// One-shot structured text generation (titles, commit messages, branch names).
    /// Returns the JSON object the model produced for `schema` (a JSON Schema object).
    func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue

    /// The slash commands and skills the provider offers in `directory`, read without starting a
    /// conversation (the composer's `/` menu before a thread has a live session). nil when the
    /// provider can't list them that way or the listing failed.
    func commands(directory: String) async -> [ProviderCommand]?
}

extension ProviderDriver {
    /// Codex and Claude Code report their lists from a live session only.
    public func commands(directory: String) async -> [ProviderCommand]? { nil }
}
