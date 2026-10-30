import Foundation

/// Settings a provider session starts or resumes with.
public struct SessionConfig: Sendable, Hashable {
    /// Working directory: the thread's worktree, else the project root, else a scratch dir.
    public var cwd: String
    public var modelSelection: ModelSelection
    public var runtimeMode: RuntimeMode
    public var interactionMode: InteractionMode
    /// Provider-native conversation to resume (Codex thread id, Claude session id); nil = new.
    public var resumeID: String?
    /// Extra directories the agent may read (attachments).
    public var additionalDirectories: [String]

    public init(
        cwd: String,
        modelSelection: ModelSelection,
        runtimeMode: RuntimeMode,
        interactionMode: InteractionMode,
        resumeID: String? = nil,
        additionalDirectories: [String] = []
    ) {
        self.cwd = cwd
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
        self.resumeID = resumeID
        self.additionalDirectories = additionalDirectories
    }
}

/// Input for one turn (or a steer into the running turn).
public struct TurnInput: Sendable, Hashable {
    public var text: String
    public var attachments: [Attachment]
    /// Applies from this turn on; the session switches model/effort/mode in place when it can.
    public var modelSelection: ModelSelection
    public var runtimeMode: RuntimeMode
    public var interactionMode: InteractionMode

    public init(text: String, attachments: [Attachment], modelSelection: ModelSelection, runtimeMode: RuntimeMode, interactionMode: InteractionMode) {
        self.text = text
        self.attachments = attachments
        self.modelSelection = modelSelection
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
    }
}

public enum ProviderTurnOutcome: String, Sendable, Hashable {
    case completed
    case interrupted
    case failed
}

/// Normalized events every provider session emits. The engine folds them into the active turn.
public enum ProviderEvent: Sendable, Hashable {
    /// Native conversation id became known (Claude `system/init` session_id, Codex `thread/start`).
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
    /// Append streamed plan markdown to `.plan` item `itemID` (created if missing).
    case planDelta(itemID: String, delta: String)
    /// The agent needs an approval; becomes an `.approval` item and blocks until answered.
    case approvalRequested(ApprovalRequest)
    /// The agent asks questions; becomes a `.userInput` item and blocks until answered.
    case userInputRequested(UserInputRequest)
    /// The provider resolved or withdrew a pending request on its own.
    case requestResolved(id: String)
    case tokenUsage(TokenUsage)
    case turnCompleted(outcome: ProviderTurnOutcome, error: String?)
    /// The process exited or the session broke; a running turn fails with `error`.
    case sessionEnded(error: String?)
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

    func respond(toApproval id: String, decision: ApprovalDecision, feedback: String?) async

    func answer(userInput id: String, answers: [String: [String]]) async

    /// Truncates the native conversation to before turn `ordinal` (1-based, as the engine counts).
    /// `providerTurnID` is that turn's native id when known.
    func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws

    /// Terminates the process. Safe to call twice.
    func close() async
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
}
