import Foundation

// Provider-backed engine API. The signatures and doc comments here are the contract the UI
// codes against; the engine slice implements the bodies (every `ENGINE-SLICE` marker goes).

extension AgentEngine {
    /// Probes every provider CLI (version, auth, models) and emits `providersChanged`.
    public func refreshProviders() async {
        preconditionFailure("ENGINE-SLICE: refreshProviders")
    }

    /// Copies a file the user attached into app storage. Images get `.image`, everything else `.file`.
    public func importAttachment(from url: URL) throws -> Attachment {
        preconditionFailure("ENGINE-SLICE: importAttachment")
    }

    /// Creates a thread from a draft (new worktree if asked), sends `text` as its first message,
    /// and starts title generation. Returns the new thread id as soon as the thread exists;
    /// worktree setup and the provider start continue in the background (the thread shows
    /// "Setting up worktree…" / Working meanwhile; failures land as a failed turn).
    public func launchThread(_ draft: ThreadDraft, text: String, attachments: [Attachment]) async throws -> String {
        preconditionFailure("ENGINE-SLICE: launchThread")
    }

    /// Sends a message on an existing thread. Idle → starts a turn. Running → steers (`.automatic`,
    /// `.steer`) or queues (`.queue`). Captures the pre-turn checkpoint when missing.
    public func send(_ threadID: String, text: String, attachments: [Attachment], mode: SendMode = .automatic) async throws {
        preconditionFailure("ENGINE-SLICE: send")
    }

    /// Stops the running turn (and holds the queue).
    public func interrupt(_ threadID: String) async {
        preconditionFailure("ENGINE-SLICE: interrupt")
    }

    /// Answers a pending approval. `feedback` accompanies a decline when the provider supports it.
    public func respond(_ threadID: String, approvalID: String, decision: ApprovalDecision, feedback: String? = nil) async {
        preconditionFailure("ENGINE-SLICE: respond")
    }

    /// Answers pending agent questions: question id → selected option labels or free text.
    public func answer(_ threadID: String, requestID: String, answers: [String: [String]]) async {
        preconditionFailure("ENGINE-SLICE: answer")
    }

    /// Dismisses agent questions without answering.
    public func dismissUserInput(_ threadID: String, requestID: String) async {
        preconditionFailure("ENGINE-SLICE: dismissUserInput")
    }

    /// Starts the first queued message now (as a steer when a turn runs), or removes it.
    public func sendQueuedNow(_ threadID: String, messageID: String) async {
        preconditionFailure("ENGINE-SLICE: sendQueuedNow")
    }

    public func cancelQueued(_ threadID: String, messageID: String) {
        preconditionFailure("ENGINE-SLICE: cancelQueued")
    }

    /// "Edit from here": rewinds the conversation to before turn `turnID` (provider rollback),
    /// optionally restores files to that turn's starting checkpoint, deletes later checkpoints,
    /// and returns the turn's user message so the composer can take it back.
    public func revert(_ threadID: String, toBeforeTurn turnID: String, restoreFiles: Bool) async throws -> UserMessage {
        preconditionFailure("ENGINE-SLICE: revert")
    }

    /// Unified diff of one turn (`turnOrdinal`), or of the whole thread so far (nil).
    public func turnDiff(_ threadID: String, turnOrdinal: Int?, ignoreWhitespace: Bool = true) async throws -> String {
        preconditionFailure("ENGINE-SLICE: turnDiff")
    }

    /// Asks the text-generation model for a better title.
    public func regenerateTitle(_ threadID: String) async {
        preconditionFailure("ENGINE-SLICE: regenerateTitle")
    }

    /// Closes the provider session and deletes the thread and its checkpoint refs.
    /// A worktree the thread created is kept (it may hold work).
    public func deleteThread(_ threadID: String) async {
        preconditionFailure("ENGINE-SLICE: deleteThread")
    }

    /// Git status of the thread's working directory (worktree or project root).
    public func gitStatus(_ threadID: String) async -> GitStatusSummary {
        preconditionFailure("ENGINE-SLICE: gitStatus")
    }

    /// Runs commit / push / PR for the thread's working directory. Commit messages and PR text
    /// come from the text-generation model when `request.commitMessage` is nil.
    public func runGitAction(
        _ threadID: String,
        action: GitStackedAction,
        commitMessage: String?,
        filePaths: [String]?,
        featureBranch: Bool,
        progress: @escaping @Sendable (GitActionProgress) -> Void
    ) async throws -> GitActionResult {
        preconditionFailure("ENGINE-SLICE: runGitAction")
    }

    /// Ends every provider session (app quit). Running turns are interrupted.
    public func shutdown() async {
        preconditionFailure("ENGINE-SLICE: shutdown")
    }
}
