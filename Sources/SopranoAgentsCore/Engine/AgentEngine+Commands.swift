import Foundation

// Provider commands for the composer's `/` menu, and compacting a thread's conversation.
// Signatures and doc comments are contract, like AgentEngine+Turns.swift.

/// A provider + workspace the engine remembers a command list for.
struct CommandScope: Hashable {
    var provider: ProviderKind
    var directory: String
}

extension AgentEngine {
    /// The message that compacts the conversation instead of starting an ordinary turn.
    public nonisolated static let compactCommand = "/compact"

    // MARK: Commands

    /// Slash commands and skills of the thread's provider, in menu order: the live session's
    /// list, else the last list this provider reported this run for the thread's workspace (or
    /// its project), else [].
    public func commands(forThread threadID: String) -> [ProviderCommand] {
        guard let thread = thread(threadID) else { return [] }
        let provider = thread.modelSelection.provider
        if let live = runtime.existingThread(threadID)?.commands { return live }
        if let list = rememberedCommands(provider, directory: workingDirectory(for: thread)) { return list }
        if let project = project(thread.projectID), let list = rememberedCommands(provider, directory: project.path) { return list }
        return []
    }

    /// The last list `provider` reported this run for the project's root (a projectless draft:
    /// for any scratch workspace), else [].
    public func commands(forDraft provider: ProviderKind, projectID: String?) -> [ProviderCommand] {
        let directory: String
        if let projectID {
            guard let project = project(projectID) else { return [] }
            directory = project.path
        } else {
            directory = scratchRoot.path
        }
        return rememberedCommands(provider, directory: directory) ?? []
    }

    /// Remembers `commands` (deduplicated and sorted, see `ProviderCommand.normalized`) as the
    /// last list `provider` reported in `workingDirectory`; emits `commandsChanged` when it
    /// differs from the previous one. Scratch workspaces share one list.
    public func rememberCommands(_ commands: [ProviderCommand], provider: ProviderKind, workingDirectory: String) {
        if remember(ProviderCommand.normalized(commands), provider: provider, workingDirectory: workingDirectory) {
            emit(.commandsChanged)
        }
    }

    /// The `/` menu opened with nothing to list: asks the thread's provider driver for its list
    /// in the thread's workspace (`ProviderDriver.commands(directory:)`; scratch threads: the
    /// scratch root they share), remembers the answer there and emits `commandsChanged`. Each
    /// provider and workspace is asked once per run, answered or not; nothing happens when a list
    /// is known or the thread has a session (it reports its own list).
    public func loadCommands(forThread threadID: String) {
        guard let thread = thread(threadID), commands(forThread: threadID).isEmpty,
              runtime.existingThread(threadID)?.session == nil else { return }
        readCommands(thread.modelSelection.provider, directory: workingDirectory(for: thread))
    }

    /// `loadCommands(forThread:)` for a draft: the project's root (a projectless draft: the
    /// scratch root, where omp falls back to its global commands and skills).
    public func loadCommands(forDraft provider: ProviderKind, projectID: String?) {
        guard commands(forDraft: provider, projectID: projectID).isEmpty else { return }
        if let projectID {
            guard let project = project(projectID) else { return }
            readCommands(provider, directory: project.path)
        } else {
            readCommands(provider, directory: scratchRoot.path)
        }
    }

    // MARK: Compaction

    /// The thread has a provider conversation (a live session, or one it can resume) and no
    /// running turn, so `compact` can start.
    public func canCompact(_ threadID: String) -> Bool {
        guard let thread = thread(threadID), !thread.isRunning else { return false }
        return hasProviderConversation(thread)
    }

    /// Compacts the thread's omp conversation (omp `compact`). Runs as a turn whose user message
    /// is `/compact` (resuming the session first, like `send`), shows omp's result as a notice
    /// (or an error) and refreshes `contextUsage` when it ends. Returns once omp accepted it.
    /// Throws while a turn runs or when there is no conversation; `send` with exactly
    /// `/compact` does the same (and `.queue` queues it).
    public func compact(_ threadID: String) async throws {
        try await send(threadID, text: Self.compactCommand, attachments: [])
    }

    // MARK: Internal

    /// `/compact` alone (no attachments) compacts instead of starting an ordinary turn.
    nonisolated static func isCompaction(_ message: UserMessage) -> Bool {
        message.attachments.isEmpty && message.text == compactCommand
    }

    /// A live session, or a conversation id to resume.
    func hasProviderConversation(_ thread: AgentThread) -> Bool {
        if runtime.existingThread(thread.id)?.session != nil { return true }
        return thread.providerThreadID != nil
    }

    /// Refuses `/compact` without a conversation, or while a turn runs unless it is queued.
    func checkCompaction(_ thread: AgentThread, mode: SendMode) throws {
        guard hasProviderConversation(thread) else {
            throw EngineError.message("There is no conversation to compact yet.")
        }
        if thread.isRunning, mode != .queue {
            throw EngineError.message("The conversation can be compacted once the current turn has finished. Queue /compact to run it afterwards.")
        }
    }

    /// The session's `commands` event: the thread's list, remembered for its workspace and
    /// project root.
    func receiveCommands(_ commands: [ProviderCommand], threadID: String) {
        guard let thread = thread(threadID) else { return }
        let rt = runtime.thread(threadID)
        let provider = thread.modelSelection.provider
        let list = ProviderCommand.normalized(commands)
        var changed = false
        if rt.commands != list {
            rt.commands = list
            changed = true
        }
        let directory = workingDirectory(for: thread)
        if remember(list, provider: provider, workingDirectory: directory) { changed = true }
        if let project = project(thread.projectID), project.path != directory,
           remember(list, provider: provider, workingDirectory: project.path) {
            changed = true
        }
        if changed { emit(.commandsChanged) }
    }

    private func readCommands(_ provider: ProviderKind, directory: String) {
        let scope = CommandScope(provider: provider, directory: scopeDirectory(directory))
        guard let driver = environment.drivers[provider], runtime.requestedCommands.insert(scope).inserted else { return }
        // Scratch workspaces share the root's list, and a thread's own folder may not exist yet.
        var directory = directory
        if scope.directory == scratchRoot.standardizedFileURL.path {
            try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
            directory = scratchRoot.path
        }
        Task { @MainActor [weak self, directory] in
            guard let list = await driver.commands(directory: directory), let self else { return }
            rememberCommands(list, provider: provider, workingDirectory: directory)
        }
    }

    private var scratchRoot: URL {
        environment.dataDirectory.appendingPathComponent("scratch", isDirectory: true)
    }

    private func rememberedCommands(_ provider: ProviderKind, directory: String) -> [ProviderCommand]? {
        runtime.rememberedCommands[CommandScope(provider: provider, directory: scopeDirectory(directory))]
    }

    /// Stores `list` (already normalized); true when it changed.
    private func remember(_ list: [ProviderCommand], provider: ProviderKind, workingDirectory: String) -> Bool {
        let scope = CommandScope(provider: provider, directory: scopeDirectory(workingDirectory))
        guard runtime.rememberedCommands[scope] != list else { return false }
        runtime.rememberedCommands[scope] = list
        return true
    }

    /// Standardized path; every scratch workspace (`<data>/scratch/<thread>`) maps to the root.
    private func scopeDirectory(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = scratchRoot.standardizedFileURL.path
        return standardized.hasPrefix(root + "/") ? root : standardized
    }
}
