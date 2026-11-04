import Foundation
import UniformTypeIdentifiers

// Provider-backed engine API. The signatures and doc comments here are the contract the UI
// codes against; the plumbing behind them lives in AgentEngine+Plumbing.swift.

extension AgentEngine {
    /// Probes every provider CLI (version, auth, models) and emits `providersChanged`.
    public func refreshProviders() async {
        let drivers = Array(environment.drivers.values)
        await withTaskGroup(of: ProviderStatus.self) { group in
            for driver in drivers {
                group.addTask { await driver.probe() }
            }
            for await status in group {
                setProviderStatus(status)
            }
        }
    }

    /// Copies a file the user attached into app storage. Images get `.image`, everything else `.file`.
    public func importAttachment(from url: URL) throws -> Attachment {
        let fileManager = FileManager.default
        let directory = attachmentsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        try fileManager.copyItem(at: url, to: destination)
        let type = UTType(filenameExtension: url.pathExtension)
        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        return Attachment(
            kind: type?.conforms(to: .image) == true ? .image : .file,
            name: name,
            path: destination.path,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            byteSize: size
        )
    }

    /// Creates a thread from a draft (new worktree if asked), sends `text` as its first message,
    /// and starts title generation. Returns the new thread id as soon as the thread exists;
    /// worktree setup and the provider start continue in the background (the thread shows
    /// "Setting up worktree…" / Working meanwhile; failures land as a failed turn).
    public func launchThread(_ draft: ThreadDraft, text: String, attachments: [Attachment]) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { throw EngineError.emptyMessage }
        let project = project(draft.projectID)
        if let projectID = draft.projectID, project == nil { throw EngineError.unknownProject(projectID) }

        let now = environment.now()
        var thread = AgentThread(
            projectID: project?.id,
            title: TextGeneration.titleSeed(text: text, attachments: attachments),
            createdAt: now,
            modelSelection: draft.modelSelection,
            runtimeMode: draft.runtimeMode,
            isGeneratingTitle: settings.generateTitles
        )
        var worktree: (project: Project, baseBranch: String, branch: String)?
        switch draft.workspace {
        case .projectRoot:
            if let project {
                thread.branch = (try? await environment.git.status(cwd: project.path))?.branch
            }
        case let .newWorktree(baseBranch):
            guard let project else { throw EngineError.message("A new worktree needs a project.") }
            let branch = TextGeneration.temporaryBranchName(prefix: settings.branchPrefix)
            thread.branch = branch
            // The thread owns its worktree path from the start: until setup succeeds the folder
            // doesn't exist, so the agent, terminals and scripts refuse to run instead of falling
            // back to the shared project root (during setup or after it failed).
            thread.worktreePath = LiveGitService.worktreePath(directory: settings.worktreesDirectory, projectRoot: project.path, branch: branch)
            worktree = (project, baseBranch, branch)
        case let .existingWorktree(path, branch):
            thread.worktreePath = path
            thread.branch = branch
        }
        if project == nil {
            try FileManager.default.createDirectory(atPath: workingDirectory(for: thread), withIntermediateDirectories: true)
        }

        let message = UserMessage(text: text, attachments: attachments, createdAt: now)
        let turn = Turn(ordinal: 1, userMessage: message, modelSelection: draft.modelSelection, startedAt: now)
        thread.turns = [turn]
        insertThread(thread)
        let threadID = thread.id

        if settings.generateTitles {
            runtime.track { [self] in await generateTitle(threadID, regenerate: false) }
        }
        runtime.thread(threadID).launch = runtime.track { [self] in
            guard isTurnRunning(threadID, turn.id) else { return }
            if let worktree {
                let path: String
                let git = environment.git
                let directory = settings.worktreesDirectory
                // Its own task, awaited by `shutdown`: cancelled at quit, setup removes the half
                // made worktree and branch, and the app must not exit before that is done.
                let creation = Task {
                    try await git.createWorktree(
                        projectRoot: worktree.project.path,
                        baseBranch: worktree.baseBranch,
                        newBranch: worktree.branch,
                        directory: directory
                    )
                }
                runtime.finishBeforeQuit(creation)
                do {
                    path = try await withTaskCancellationHandler {
                        try await creation.value
                    } onCancel: {
                        creation.cancel()
                    }
                } catch {
                    finishTurn(threadID, turn.id, status: .failed, error: Self.describe(error))
                    return
                }
                updateThread(threadID) { $0.worktreePath = path }
                runtime.track { [self] in
                    await renameTemporaryBranch(worktree.branch, worktreePath: path, message: message)
                }
                guard isTurnRunning(threadID, turn.id) else { return }
            }
            await runTurn(threadID, turn.id)
        }
        return threadID
    }

    /// Sends a message on an existing thread. Idle → starts a turn. Running → steers (`.automatic`,
    /// `.steer`) or queues (`.queue`). A yielded turn (its answer final, background work still
    /// running) is ended first with its yielded outcome and the message starts a new turn.
    /// Captures the pre-turn checkpoint when missing. Exactly `/compact` compacts the
    /// conversation instead (see `compact`). A rewind in progress (`revert`) finishes first.
    public func send(_ threadID: String, text: String, attachments: [Attachment], mode: SendMode = .automatic) async throws {
        if let reverting = runtime.existingThread(threadID)?.reverting {
            await reverting.value
            return try await send(threadID, text: text, attachments: attachments, mode: mode)
        }
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { throw EngineError.emptyMessage }
        let message = UserMessage(text: text, attachments: attachments, createdAt: environment.now())
        if Self.isCompaction(message) { try checkCompaction(thread, mode: mode) }
        if thread.isRunning {
            switch mode {
            case .queue:
                enqueue(threadID, message: message, selection: thread.modelSelection)
            case .automatic, .steer:
                try await steer(threadID, message: message)
            }
            return
        }
        if thread.openTurn != nil {
            await releaseYieldedTurn(threadID)
            return try await send(threadID, text: text, attachments: attachments, mode: mode)
        }
        guard let turnID = beginTurn(threadID, message: message, selection: thread.modelSelection) else { return }
        await runTurn(threadID, turnID)
    }

    /// Stops the running turn (and holds the queue). The turn shows "Stopping…"
    /// (`stopRequestedAt`) until the provider ends it.
    public func interrupt(_ threadID: String) async {
        guard let turn = thread(threadID)?.activeTurn else { return }
        let rt = runtime.thread(threadID)
        rt.holdQueue = true
        if let session = rt.session, rt.starting == nil, rt.liveTurnID == turn.id {
            if turn.stopRequestedAt == nil {
                let now = environment.now()
                mutateTurn(threadID, turn.id) { $0.stopRequestedAt = now }
            }
            await session.interrupt()
            return
        }
        // No live provider turn yet (worktree setup, session start): stop it here.
        rt.launch?.cancel()
        finishTurn(threadID, turn.id, status: .interrupted, error: nil)
    }

    /// Answers a pending approval.
    public func respond(_ threadID: String, approvalID: String, decision: ApprovalDecision) async {
        guard let turn = thread(threadID)?.turns.last(where: { turn in
            turn.items.contains { item in
                if case let .approval(request) = item.kind { return request.id == approvalID && request.decision == nil }
                return false
            }
        }) else { return }
        let now = environment.now()
        mutateTurn(threadID, turn.id) { turn in
            guard let index = turn.items.firstIndex(where: { $0.id == approvalID }),
                  case var .approval(request) = turn.items[index].kind else { return }
            request.decision = decision
            turn.items[index].kind = .approval(request)
            turn.items[index].status = decision == .accept || decision == .acceptForSession ? .completed : .declined
            turn.items[index].completedAt = now
        }
        await runtime.existingThread(threadID)?.session?.respond(toApproval: approvalID, decision: decision)
    }

    /// Answers pending agent questions: question id → selected option labels or free text.
    public func answer(_ threadID: String, requestID: String, answers: [String: [String]]) async {
        guard settleUserInput(threadID, requestID: requestID, answers: answers) else { return }
        await runtime.existingThread(threadID)?.session?.answer(userInput: requestID, answers: answers)
    }

    /// Dismisses agent questions without answering.
    public func dismissUserInput(_ threadID: String, requestID: String) async {
        guard settleUserInput(threadID, requestID: requestID, answers: nil) else { return }
        // Providers get an empty answer set: the agent continues without answers.
        await runtime.existingThread(threadID)?.session?.answer(userInput: requestID, answers: [:])
    }

    /// Starts the first queued message now (as a steer when a turn runs; after ending a yielded
    /// turn), or removes it. Nothing steers into or out of a compaction: a queued `/compact`, or
    /// any message while a compaction runs, stays queued until the running turn ends. A rewind in
    /// progress (`revert`) finishes first.
    public func sendQueuedNow(_ threadID: String, messageID: String) async {
        if let reverting = runtime.existingThread(threadID)?.reverting {
            await reverting.value
            return await sendQueuedNow(threadID, messageID: messageID)
        }
        guard let thread = thread(threadID), let queued = thread.queue.first(where: { $0.id == messageID }) else { return }
        if let active = thread.activeTurn, Self.isCompaction(queued.message) || Self.isCompaction(active.userMessage) { return }
        if !thread.isRunning, thread.openTurn != nil {
            await releaseYieldedTurn(threadID)
            return await sendQueuedNow(threadID, messageID: messageID)
        }
        updateThread(threadID) { $0.queue.removeAll { $0.id == messageID } }
        if thread.isRunning {
            do {
                try await steer(threadID, message: queued.message)
            } catch {
                Self.log.error("Steering a queued message failed: \(Self.describe(error), privacy: .public)")
                enqueue(threadID, message: queued.message, selection: queued.modelSelection)
            }
            return
        }
        guard let turnID = beginTurn(threadID, message: queued.message, selection: queued.modelSelection) else { return }
        await runTurn(threadID, turnID)
    }

    public func cancelQueued(_ threadID: String, messageID: String) {
        updateThread(threadID) { $0.queue.removeAll { $0.id == messageID } }
    }

    /// "Edit from here": rewinds the conversation to before turn `turnID` (provider rollback),
    /// optionally restores files to that turn's starting checkpoint, deletes later checkpoints,
    /// and returns the turn's user message so the composer can take it back. A yielded turn is
    /// ended first. While it rewinds, new turns wait (`send`, `sendQueuedNow`) and the queue
    /// does not drain.
    public func revert(_ threadID: String, toBeforeTurn turnID: String, restoreFiles: Bool) async throws -> UserMessage {
        if let reverting = runtime.existingThread(threadID)?.reverting {
            await reverting.value
            return try await revert(threadID, toBeforeTurn: turnID, restoreFiles: restoreFiles)
        }
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        guard let turn = thread.turns.first(where: { $0.id == turnID }) else { throw EngineError.nothingToRevert }
        guard !thread.isRunning else { throw EngineError.turnRunning }
        if thread.openTurn != nil {
            await releaseYieldedTurn(threadID)
            return try await revert(threadID, toBeforeTurn: turnID, restoreFiles: restoreFiles)
        }
        let rt = runtime.thread(threadID)
        let work = Task { @MainActor [self] in try await rewind(thread, toBefore: turn, restoreFiles: restoreFiles) }
        let reverting = Task { _ = await work.result }
        rt.reverting = reverting
        let result = await work.result
        if rt.reverting == reverting { rt.reverting = nil }
        return try result.get()
    }

    /// `revert`'s work on an idle thread that nothing else starts a turn on meanwhile.
    private func rewind(_ thread: AgentThread, toBefore turn: Turn, restoreFiles: Bool) async throws -> UserMessage {
        let threadID = thread.id
        let git = environment.git
        let cwd = workingDirectory(for: thread)
        let baseline = CheckpointRef.ref(threadID: threadID, ordinal: turn.ordinal - 1)

        if restoreFiles {
            guard isIsolatedWorkspace(thread) else {
                throw EngineError.message("File restore requires an isolated worktree. This workspace may contain changes from another thread. Rewind the conversation without restoring files instead.")
            }
            guard await git.checkpointExists(cwd: cwd, ref: baseline) else { throw EngineError.nothingToRevert }
        }

        // Rewind the provider to before the earliest turn from here on that it actually received
        // (a turn stopped during startup or failed before sending has no native id). When none
        // of them reached it, its conversation already ends here.
        let anchor = thread.turns.first { $0.ordinal >= turn.ordinal && $0.providerTurnID != nil }
        if thread.providerThreadID != nil, let anchor {
            let session: any ProviderSession
            do {
                session = try await ensureSession(threadID)
            } catch {
                throw EngineError.message("Reconnect \(thread.modelSelection.provider.displayName) before reverting checkpoints.")
            }
            do {
                try await session.rollback(beforeTurn: anchor.ordinal, providerTurnID: anchor.providerTurnID)
            } catch {
                throw EngineError.message("The provider could not roll back this conversation. Try again; if it keeps failing, check the provider and server logs.")
            }
        }

        // The provider has rolled back: from here on the thread is trimmed to match it even when
        // restoring the files fails.
        var restoreFailure: String?
        if restoreFiles {
            do {
                try await runtime.git.run(cwd) { try await git.restoreCheckpoint(cwd: cwd, ref: baseline) }
            } catch {
                restoreFailure = Self.describe(error)
            }
        }

        let lastOrdinal = thread.turns.map(\.ordinal).max() ?? turn.ordinal
        let stale = (turn.ordinal...max(turn.ordinal, lastOrdinal)).map { CheckpointRef.ref(threadID: threadID, ordinal: $0) }
        do {
            try await runtime.git.run(cwd) {
                guard await git.isRepository(cwd) else { return }
                try await git.deleteRefs(cwd: cwd, refs: stale)
            }
        } catch {
            Self.log.error("Deleting stale checkpoints failed: \(Self.describe(error), privacy: .public)")
        }

        let now = environment.now()
        updateThread(threadID) { thread in
            // Subagents the dropped turns started go with them: omp's rewound session can hand
            // out their names again, which would merge a new subagent into an old one.
            let droppedCalls = Set(thread.turns.filter { $0.ordinal >= turn.ordinal }.flatMap { $0.items.map(\.id) })
            thread.subagents.removeAll { $0.parentToolCallID.map(droppedCalls.contains) ?? false }
            thread.turns.removeAll { $0.ordinal >= turn.ordinal }
            thread.updatedAt = now
            // The conversation now ends where the kept turns ended.
            thread.contextUsage = thread.turns.last?.tokenUsage
        }
        if let restoreFailure {
            throw EngineError.filesNotRestored(message: turn.userMessage, reason: restoreFailure)
        }
        return turn.userMessage
    }

    /// Unified diff of one turn (`turnOrdinal`), or of the whole thread so far (nil).
    public func turnDiff(_ threadID: String, turnOrdinal: Int?, ignoreWhitespace: Bool = true) async throws -> String {
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let fromOrdinal: Int
        let toOrdinal: Int
        if let turnOrdinal {
            guard let turn = thread.turns.first(where: { $0.ordinal == turnOrdinal }), turn.checkpoint?.status == .ready else {
                throw EngineError.message("No checkpoint is available for turn \(turnOrdinal).")
            }
            fromOrdinal = turn.ordinal - 1
            toOrdinal = turn.ordinal
        } else {
            guard let last = thread.turns.last(where: { $0.checkpoint?.status == .ready }) else { return "" }
            fromOrdinal = 0
            toOrdinal = last.ordinal
        }
        let git = environment.git
        let cwd = workingDirectory(for: thread)
        let from = CheckpointRef.ref(threadID: threadID, ordinal: fromOrdinal)
        let to = CheckpointRef.ref(threadID: threadID, ordinal: toOrdinal)
        return try await runtime.git.run(cwd) {
            try await git.diff(cwd: cwd, fromRef: from, toRef: to, ignoreWhitespace: ignoreWhitespace)
        }
    }

    /// Asks the text-generation model for a better title.
    public func regenerateTitle(_ threadID: String) async {
        await generateTitle(threadID, regenerate: true)
    }

    /// Closes the provider session and deletes the thread and its checkpoint refs.
    /// A worktree the thread created is kept (it may hold work).
    public func deleteThread(_ threadID: String) async {
        guard let thread = thread(threadID) else { return }
        let cwd = workingDirectory(for: thread)
        if let rt = runtime.removeThread(threadID) {
            rt.launch?.cancel()
            let session = rt.session
            rt.dropSession()
            if let session {
                if thread.isRunning { await session.interrupt() }
                await session.close()
            }
        }
        removeThreadRecord(threadID)

        let git = environment.git
        let lastOrdinal = thread.turns.map(\.ordinal).max() ?? 0
        let refs = (0...lastOrdinal).map { CheckpointRef.ref(threadID: threadID, ordinal: $0) }
        do {
            try await runtime.git.run(cwd) {
                guard await git.isRepository(cwd) else { return }
                try await git.deleteRefs(cwd: cwd, refs: refs)
            }
        } catch {
            Self.log.error("Deleting checkpoints of a deleted thread failed: \(Self.describe(error), privacy: .public)")
        }
    }

    /// Git status of the thread's working directory (worktree or project root).
    public func gitStatus(_ threadID: String) async -> GitStatusSummary {
        guard let thread = thread(threadID) else { return .notARepository }
        return (try? await environment.git.status(cwd: workingDirectory(for: thread))) ?? .notARepository
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
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let cwd = workingDirectory(for: thread)
        let selection = settings.textGenerationModel
        let writer = ProviderSourceControlWriter(driver: environment.drivers[selection.provider], selection: selection, cwd: cwd)
        let trimmedMessage = commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GitActionRequest(
            action: action,
            cwd: cwd,
            commitMessage: trimmedMessage?.isEmpty == false ? trimmedMessage : nil,
            filePaths: filePaths,
            featureBranch: featureBranch
        )
        return try await environment.git.runAction(request, writer: writer, progress: progress)
    }

    /// Ends every provider session (app quit). Running turns are interrupted; yielded ones end
    /// with their yielded outcome. Queued messages stay queued, and the ended turns' checkpoints
    /// are captured before the store's final flush.
    public func shutdown() async {
        runtime.isShuttingDown = true
        for (threadID, rt) in runtime.allThreads {
            rt.launch?.cancel()
            let session = rt.session
            let live = rt.liveTurnID != nil
            rt.dropSession()
            if let turn = thread(threadID)?.openTurn {
                if live, !turn.isYielded { await session?.interrupt() }
                endAtShutdown(threadID, turn)
            }
            await session?.close()
        }
        for thread in threads {
            if let turn = thread.openTurn {
                endAtShutdown(thread.id, turn)
            }
        }
        for assistant in environment.textAssistants.values {
            await assistant.close()
        }
        await runtime.waitForQuitWork()
        environment.store.flush()
    }

    // MARK: Private

    /// App quit: a running turn is interrupted, a yielded one keeps its yielded outcome.
    private func endAtShutdown(_ threadID: String, _ turn: Turn) {
        finishTurn(threadID, turn.id, status: turn.isYielded ? turn.yieldedStatus : .interrupted, error: turn.failureMessage)
    }

    /// Records answers (or a dismissal when nil) on a pending user-input item.
    private func settleUserInput(_ threadID: String, requestID: String, answers: [String: [String]]?) -> Bool {
        guard let turn = thread(threadID)?.turns.last(where: { turn in
            turn.items.contains { item in
                if case let .userInput(request) = item.kind { return request.id == requestID && request.answers == nil && !request.dismissed }
                return false
            }
        }) else { return false }
        let now = environment.now()
        mutateTurn(threadID, turn.id) { turn in
            guard let index = turn.items.firstIndex(where: { $0.id == requestID }),
                  case var .userInput(request) = turn.items[index].kind else { return }
            if let answers {
                request.answers = answers
                turn.items[index].status = .completed
            } else {
                request.dismissed = true
                turn.items[index].status = .declined
            }
            turn.items[index].kind = .userInput(request)
            turn.items[index].completedAt = now
        }
        return true
    }

    /// The thread has its own worktree that no other thread or project root shares or nests.
    private func isIsolatedWorkspace(_ thread: AgentThread) -> Bool {
        guard let worktree = thread.worktreePath else { return false }
        func overlaps(_ lhs: String, _ rhs: String) -> Bool {
            let a = URL(fileURLWithPath: lhs).standardizedFileURL.path
            let b = URL(fileURLWithPath: rhs).standardizedFileURL.path
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        if projects.contains(where: { overlaps($0.path, worktree) }) { return false }
        return !threads.contains { $0.id != thread.id && overlaps(workingDirectory(for: $0), worktree) }
    }
}
