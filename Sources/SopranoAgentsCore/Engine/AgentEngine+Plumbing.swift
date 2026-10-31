import Foundation
import os

// Provider plumbing behind the public API in AgentEngine+Turns.swift: sessions, folding provider
// events into turns, the turn lifecycle, checkpoints, titles and generated branch names.

extension AgentEngine {
    static let log = Logger(subsystem: "com.soprano.agents", category: "engine")

    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return error.localizedDescription
    }

    var attachmentsDirectory: URL {
        environment.dataDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    // MARK: Turn mutation

    enum Announcement {
        /// Turns, queue or settings changed: `.threadChanged`.
        case thread
        /// One item streamed: `.itemChanged`.
        case item(turnID: String, itemID: String)
    }

    /// Mutates turn `turnID` of a thread, persists, and emits `announcement` (+ `threadListChanged`
    /// when list-visible fields changed).
    func mutateTurn(_ threadID: String, _ turnID: String, announce announcement: Announcement = .thread, _ change: (inout Turn) -> Void) {
        mutateThread(threadID, announce: announcement) { thread in
            guard let index = thread.turns.lastIndex(where: { $0.id == turnID }) else { return }
            change(&thread.turns[index])
        }
    }

    func mutateThread(_ threadID: String, announce announcement: Announcement = .thread, _ change: (inout AgentThread) -> Void) {
        guard let result = mutateThreadQuietly(threadID, change) else { return }
        announce(threadID, announcement, before: result.before, after: result.after)
    }

    func isTurnRunning(_ threadID: String, _ turnID: String) -> Bool {
        guard let last = thread(threadID)?.turns.last else { return false }
        return last.id == turnID && last.status == .running
    }

    // MARK: Turn lifecycle

    /// Appends a running turn for `message` and returns its id.
    func beginTurn(_ threadID: String, message: UserMessage, selection: ModelSelection) -> String? {
        guard let thread = thread(threadID) else { return nil }
        let now = environment.now()
        let turn = Turn(ordinal: thread.turns.count + 1, userMessage: message, modelSelection: selection, startedAt: now)
        runtime.thread(threadID).holdQueue = false
        updateThread(threadID) { thread in
            thread.turns.append(turn)
            thread.settledAt = nil
            thread.updatedAt = now
        }
        return turn.id
    }

    /// Captures the turn's baseline checkpoint when missing, starts the provider session if needed,
    /// and starts the provider turn (a `/compact` turn: the provider's compaction). Failures finish
    /// the turn as failed.
    func runTurn(_ threadID: String, _ turnID: String) async {
        guard let snapshot = thread(threadID), let turn = snapshot.turns.last(where: { $0.id == turnID }) else { return }
        do {
            try requireWorkspace(for: snapshot)
        } catch {
            finishTurn(threadID, turnID, status: .failed, error: Self.describe(error))
            return
        }
        await captureBaseline(threadID: threadID, cwd: workingDirectory(for: snapshot), ordinal: turn.ordinal - 1)
        guard isTurnRunning(threadID, turnID) else { return }
        do {
            let session = try await ensureSession(threadID)
            guard isTurnRunning(threadID, turnID), let current = self.thread(threadID) else { return }
            let providerTurnID: String?
            if Self.isCompaction(turn.userMessage) {
                try await session.compact()
                providerTurnID = nil
            } else {
                let input = TurnInput(
                    text: turn.userMessage.text,
                    attachments: turn.userMessage.attachments,
                    modelSelection: turn.modelSelection,
                    runtimeMode: current.runtimeMode
                )
                providerTurnID = try await session.startTurn(input)
            }
            guard isTurnRunning(threadID, turnID) else {
                // Interrupted (or failed) while the provider was starting the turn: stop it there too.
                if thread(threadID)?.turns.last(where: { $0.id == turnID })?.status == .interrupted {
                    await session.interrupt()
                }
                return
            }
            runtime.thread(threadID).liveTurnID = turnID
            if let providerTurnID {
                mutateTurn(threadID, turnID) { turn in
                    if turn.providerTurnID == nil { turn.providerTurnID = providerTurnID }
                }
            }
        } catch {
            finishTurn(threadID, turnID, status: .failed, error: Self.describe(error))
        }
    }

    /// Ends a running turn: settles its live items and unanswered requests, then captures the
    /// turn's checkpoint (completed/interrupted) and starts the next queued message (completed).
    /// A yielded turn's work ended at its yield.
    func finishTurn(_ threadID: String, _ turnID: String, status: TurnStatus, error: String?) {
        guard isTurnRunning(threadID, turnID) else { return }
        let now = environment.now()
        mutateThread(threadID) { thread in
            thread.updatedAt = now
            guard let index = thread.turns.lastIndex(where: { $0.id == turnID }) else { return }
            var turn = thread.turns[index]
            turn.completedAt = turn.isYielded ? turn.yieldedAt ?? now : now
            turn.yieldedAt = nil
            turn.status = status
            if status == .failed {
                turn.failureMessage = error ?? turn.failureMessage ?? "The turn failed."
            }
            for item in turn.items.indices {
                switch turn.items[item].kind {
                case var .approval(request) where request.decision == nil:
                    request.decision = .cancel
                    turn.items[item].kind = .approval(request)
                    turn.items[item].status = .declined
                case var .userInput(request) where request.answers == nil && !request.dismissed:
                    request.dismissed = true
                    turn.items[item].kind = .userInput(request)
                    turn.items[item].status = .declined
                default:
                    if turn.items[item].status.isActive {
                        turn.items[item].status = status == .completed ? .completed : .interrupted
                    }
                }
                if !turn.items[item].status.isActive, turn.items[item].completedAt == nil {
                    turn.items[item].completedAt = now
                }
            }
            thread.turns[index] = turn
        }
        let rt = runtime.thread(threadID)
        let ranAtProvider = rt.liveTurnID == turnID
        if ranAtProvider { rt.liveTurnID = nil }
        // A turn stopped before its provider turn started changed nothing worth a checkpoint.
        let capture = status == .completed || (status == .interrupted && ranAtProvider)
        let drain = status == .completed && !rt.holdQueue
        runtime.track { [self] in
            if capture { await captureTurnCheckpoint(threadID, turnID) }
            if drain { await drainQueue(threadID) }
        }
    }

    /// Starts the first queued message when the thread is idle (a yielded turn ends first).
    func drainQueue(_ threadID: String) async {
        guard let thread = thread(threadID), !thread.isRunning, !thread.queue.isEmpty else { return }
        await releaseYieldedTurn(threadID)
        guard let thread = self.thread(threadID), thread.openTurn == nil, let next = thread.queue.first else { return }
        updateThread(threadID) { $0.queue.removeAll { $0.id == next.id } }
        guard let turnID = beginTurn(threadID, message: next.message, selection: next.modelSelection) else { return }
        await runTurn(threadID, turnID)
    }

    /// The provider's prompt yielded with background work pending (`turnYielded`): the answer
    /// is final and the thread idle, but the turn stays open for the runs that work wakes. Its
    /// live items settle, its checkpoint is captured (the changed-files card; again when it
    /// ends), and after a completed yield a queued message starts (which ends the turn first).
    func yieldTurn(_ threadID: String, outcome: ProviderTurnOutcome, error: String?) {
        guard let thread = thread(threadID), let turnID = thread.openTurn?.id else { return }
        let now = environment.now()
        mutateTurn(threadID, turnID) { turn in
            turn.yieldedAt = now
            turn.failureMessage = outcome == .failed ? error ?? "The turn failed." : nil
            for index in turn.items.indices where turn.items[index].status.isActive {
                switch turn.items[index].kind {
                case .approval, .userInput:
                    continue
                default:
                    turn.items[index].status = .completed
                    turn.items[index].completedAt = turn.items[index].completedAt ?? now
                }
            }
        }
        let drain = outcome == .completed && !runtime.thread(threadID).holdQueue && !thread.queue.isEmpty
        runtime.track { [self] in
            await captureTurnCheckpoint(threadID, turnID)
            if drain { await drainQueue(threadID) }
        }
    }

    /// Ends the thread's yielded turn before anything else starts (a new message, a queued one,
    /// a compaction, a rewind): the session reports it like its settlement (native id, context
    /// fill, `turnCompleted` with the yielded outcome, never interrupted) and forgets the held
    /// prompt without stopping the background work. Without a live session, or when that report
    /// does not arrive in time, the turn ends here with its yielded outcome.
    func releaseYieldedTurn(_ threadID: String) async {
        guard let turn = thread(threadID)?.openTurn, turn.isYielded else { return }
        let rt = runtime.thread(threadID)
        if let session = rt.session, rt.starting == nil, rt.liveTurnID == turn.id {
            await session.releaseYieldedTurn()
            let deadline = ContinuousClock.now + runtime.yieldReleaseTimeout
            while isTurnRunning(threadID, turn.id), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        guard let open = thread(threadID)?.openTurn, open.id == turn.id else { return }
        finishTurn(threadID, open.id, status: open.isYielded ? open.yieldedStatus : .completed, error: open.failureMessage)
    }

    /// Delivers `message` into the running turn, or queues it when the provider turn is not live
    /// yet or is a compaction (nothing to steer).
    func steer(_ threadID: String, message: UserMessage) async throws {
        guard let thread = thread(threadID), let turn = thread.activeTurn else { return }
        let rt = runtime.thread(threadID)
        guard let session = rt.session, rt.starting == nil, rt.liveTurnID == turn.id, !Self.isCompaction(turn.userMessage) else {
            enqueue(threadID, message: message, selection: thread.modelSelection)
            return
        }
        try await session.steer(TurnInput(
            text: message.text,
            attachments: message.attachments,
            modelSelection: thread.modelSelection,
            runtimeMode: thread.runtimeMode
        ))
        var steered = message
        steered.isSteer = true
        mutateTurn(threadID, turn.id) { $0.steers.append(steered) }
    }

    func enqueue(_ threadID: String, message: UserMessage, selection: ModelSelection) {
        updateThread(threadID) { $0.queue.append(QueuedMessage(message: message, modelSelection: selection)) }
    }

    // MARK: Sessions

    /// The thread's live session, started (or resumed from `providerThreadID`) on first use.
    /// The agent only ever runs in the thread's own working directory: a projectless thread gets
    /// its scratch folder created, any other missing folder (deleted worktree, moved or removed
    /// project, worktree still being set up or failed) refuses with `workspaceMissing`.
    func requireWorkspace(for thread: AgentThread) throws {
        let path = workingDirectory(for: thread)
        if thread.projectID == nil, thread.worktreePath == nil {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.workspaceMissing(path)
        }
    }

    func ensureSession(_ threadID: String) async throws -> any ProviderSession {
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let rt = runtime.thread(threadID)
        if let starting = rt.starting { return try await starting.value }
        if let session = rt.session { return session }
        try requireWorkspace(for: thread)
        let kind = thread.modelSelection.provider
        guard let driver = environment.drivers[kind] else {
            throw EngineError.providerUnavailable(kind, "No driver is configured.")
        }
        let session = driver.makeSession()
        let config = SessionConfig(
            cwd: workingDirectory(for: thread),
            modelSelection: thread.modelSelection,
            runtimeMode: thread.runtimeMode,
            resumeID: thread.providerThreadID
        )
        rt.session = session
        rt.consumer = consume(session, threadID: threadID)
        let task = Task<any ProviderSession, any Error> { @MainActor [self] in
            let conversationID = try await session.start(config)
            updateThread(threadID) { $0.providerThreadID = conversationID }
            return session
        }
        rt.starting = task
        do {
            let started = try await task.value
            if rt.starting == task { rt.starting = nil }
            return started
        } catch {
            if rt.starting == task { rt.dropSession() }
            await session.close()
            throw error
        }
    }

    private func consume(_ session: any ProviderSession, threadID: String) -> Task<Void, Never> {
        let events = session.events
        return Task { @MainActor [weak self] in
            for await event in events {
                guard let self, self.runtime.existingThread(threadID)?.session === session else { return }
                self.apply(event, threadID: threadID)
            }
            guard let self, self.runtime.existingThread(threadID)?.session === session else { return }
            self.sessionEnded(threadID, error: nil)
        }
    }

    /// The session broke: a running turn fails (a yielded one ends with its yielded outcome: its
    /// answer stands) and the next send starts a new session (resuming).
    func sessionEnded(_ threadID: String, error: String?) {
        let rt = runtime.thread(threadID)
        let session = rt.session
        rt.dropSession()
        rt.liveTurnID = nil
        if let turn = thread(threadID)?.openTurn {
            if turn.isYielded {
                finishTurn(threadID, turn.id, status: turn.yieldedStatus, error: turn.failureMessage)
            } else {
                finishTurn(threadID, turn.id, status: .failed, error: error ?? "The provider session ended unexpectedly.")
            }
        }
        if let session {
            Task { await session.close() }
        }
    }

    // MARK: Event folding

    func apply(_ event: ProviderEvent, threadID: String) {
        switch event {
        case let .conversationID(id):
            updateThread(threadID) { $0.providerThreadID = id }
        case let .turnStarted(providerTurnID):
            guard let turnID = thread(threadID)?.openTurn?.id else { return }
            runtime.thread(threadID).liveTurnID = turnID
            if let providerTurnID {
                mutateTurn(threadID, turnID) { turn in
                    if turn.providerTurnID == nil { turn.providerTurnID = providerTurnID }
                }
            }
        case let .itemUpdated(item):
            upsertItem(threadID, item)
        case let .assistantDelta(itemID, delta, isFinal):
            appendToItem(threadID, itemID, create: { .assistantMessage(text: delta, isFinal: isFinal) }) { kind in
                guard case let .assistantMessage(text, final) = kind else { return nil }
                return .assistantMessage(text: text + delta, isFinal: final || isFinal)
            }
        case let .reasoningDelta(itemID, delta):
            appendToItem(threadID, itemID, create: { .reasoning(text: delta) }) { kind in
                guard case let .reasoning(text) = kind else { return nil }
                return .reasoning(text: text + delta)
            }
        case let .commandOutputDelta(itemID, delta):
            appendToItem(threadID, itemID, create: { nil }) { kind in
                guard case var .command(execution) = kind else { return nil }
                execution.output += delta
                return .command(execution)
            }
        case let .approvalRequested(request):
            upsertItem(threadID, TurnItem(id: request.id, kind: .approval(request), status: .pending, startedAt: environment.now()))
        case let .userInputRequested(request):
            upsertItem(threadID, TurnItem(id: request.id, kind: .userInput(request), status: .pending, startedAt: environment.now()))
        case let .requestResolved(id):
            resolveRequest(threadID, id)
        case let .tokenUsage(usage):
            // The latest turn's usage, and the thread's context fill (also when a reading
            // arrives after the turn ended).
            mutateThread(threadID) { thread in
                thread.contextUsage = usage
                if !thread.turns.isEmpty { thread.turns[thread.turns.count - 1].tokenUsage = usage }
            }
        case let .commands(commands):
            receiveCommands(commands, threadID: threadID)
        case let .turnCompleted(outcome, error):
            guard let turnID = thread(threadID)?.openTurn?.id else { return }
            let status: TurnStatus = switch outcome {
            case .completed: .completed
            case .interrupted: .interrupted
            case .failed: .failed
            }
            finishTurn(threadID, turnID, status: status, error: error)
        case let .turnYielded(outcome, error):
            yieldTurn(threadID, outcome: outcome, error: error)
        case .turnResumed:
            guard let turn = thread(threadID)?.openTurn, turn.yieldedAt != nil else { return }
            mutateTurn(threadID, turn.id) { $0.yieldedAt = nil }
        case let .sessionEnded(error):
            sessionEnded(threadID, error: error)
        }
    }

    /// Inserts or replaces an item of the running turn (keeping its original start time).
    private func upsertItem(_ threadID: String, _ item: TurnItem) {
        guard let turnID = thread(threadID)?.openTurn?.id else { return }
        let now = environment.now()
        var created = false
        var item = item
        if !item.status.isActive, item.completedAt == nil { item.completedAt = now }
        let announcement = Announcement.item(turnID: turnID, itemID: item.id)
        guard let change = mutateThreadQuietly(threadID, { thread in
            guard let index = thread.turns.lastIndex(where: { $0.id == turnID }) else { return }
            if let existing = thread.turns[index].items.firstIndex(where: { $0.id == item.id }) {
                item.startedAt = thread.turns[index].items[existing].startedAt
                thread.turns[index].items[existing] = item
            } else {
                thread.turns[index].items.append(item)
                created = true
            }
        }) else { return }
        announce(threadID, created ? .thread : announcement, before: change.before, after: change.after)
    }

    /// Appends streamed content to an item of the running turn, creating it when missing.
    private func appendToItem(
        _ threadID: String,
        _ itemID: String,
        create: () -> TurnItemKind?,
        update: (TurnItemKind) -> TurnItemKind?
    ) {
        guard let turnID = thread(threadID)?.openTurn?.id else { return }
        let now = environment.now()
        var created = false
        guard let change = mutateThreadQuietly(threadID, { thread in
            guard let index = thread.turns.lastIndex(where: { $0.id == turnID }) else { return }
            if let existing = thread.turns[index].items.firstIndex(where: { $0.id == itemID }) {
                if let kind = update(thread.turns[index].items[existing].kind) {
                    thread.turns[index].items[existing].kind = kind
                }
            } else if let kind = create() {
                thread.turns[index].items.append(TurnItem(id: itemID, kind: kind, status: .running, startedAt: now))
                created = true
            }
        }) else { return }
        announce(threadID, created ? .thread : .item(turnID: turnID, itemID: itemID), before: change.before, after: change.after)
    }

    private func announce(_ threadID: String, _ announcement: Announcement, before: AgentThread, after: AgentThread) {
        switch announcement {
        case .thread:
            emit(.threadChanged(threadID: threadID))
        case let .item(turnID, itemID):
            emit(.itemChanged(threadID: threadID, turnID: turnID, itemID: itemID))
        }
        if Self.listFieldsDiffer(before, after) {
            emit(.threadListChanged)
        }
    }

    /// The provider settled a pending approval or question itself (answered elsewhere or withdrawn).
    private func resolveRequest(_ threadID: String, _ requestID: String) {
        guard let turnID = thread(threadID)?.turns.last(where: { turn in turn.items.contains { $0.id == requestID } })?.id else { return }
        let now = environment.now()
        mutateTurn(threadID, turnID) { turn in
            guard let index = turn.items.firstIndex(where: { $0.id == requestID }) else { return }
            switch turn.items[index].kind {
            case var .approval(request):
                let decision = request.decision ?? .cancel
                request.decision = decision
                turn.items[index].kind = .approval(request)
                turn.items[index].status = decision == .accept || decision == .acceptForSession ? .completed : .declined
            case var .userInput(request):
                if request.answers == nil { request.dismissed = true }
                turn.items[index].kind = .userInput(request)
                turn.items[index].status = request.answers == nil ? .declined : .completed
            default:
                return
            }
            if turn.items[index].completedAt == nil { turn.items[index].completedAt = now }
        }
    }

    // MARK: Checkpoints

    /// Captures `ref(ordinal)` before a turn when it does not exist yet. Failures are logged; the turn
    /// starts without a baseline.
    func captureBaseline(threadID: String, cwd: String, ordinal: Int) async {
        let git = environment.git
        let ref = CheckpointRef.ref(threadID: threadID, ordinal: ordinal)
        do {
            try await runtime.git.run(cwd) {
                guard await git.isRepository(cwd) else { return }
                if await git.checkpointExists(cwd: cwd, ref: ref) { return }
                try await git.captureCheckpoint(cwd: cwd, ref: ref)
            }
        } catch {
            Self.log.error("Checkpoint baseline capture failed; starting provider without a baseline: \(Self.describe(error), privacy: .public)")
        }
    }

    /// Captures `ref(N)` after turn N and records the files it changed since `ref(N-1)`.
    func captureTurnCheckpoint(_ threadID: String, _ turnID: String) async {
        guard let thread = thread(threadID), let turn = thread.turns.last(where: { $0.id == turnID }) else { return }
        let git = environment.git
        let cwd = workingDirectory(for: thread)
        let ref = CheckpointRef.ref(threadID: threadID, ordinal: turn.ordinal)
        let previous = CheckpointRef.ref(threadID: threadID, ordinal: turn.ordinal - 1)
        let checkpoint: TurnCheckpoint
        do {
            checkpoint = try await runtime.git.run(cwd) {
                guard await git.isRepository(cwd) else { return TurnCheckpoint(ref: ref, status: .missing) }
                try await git.captureCheckpoint(cwd: cwd, ref: ref)
                let files = try await git.changedFiles(cwd: cwd, fromRef: previous, toRef: ref)
                return TurnCheckpoint(ref: ref, status: .ready, files: files)
            }
        } catch {
            Self.log.error("Checkpoint capture failed: \(Self.describe(error), privacy: .public)")
            checkpoint = TurnCheckpoint(ref: ref, status: .error)
        }
        mutateTurn(threadID, turnID) { $0.checkpoint = checkpoint }
    }

    // MARK: Titles

    /// Asks the text-generation model for a title: the first message (`regenerate == false`, up to
    /// three attempts, keeps the seed on failure or when the user renamed meanwhile) or the whole
    /// USER/ASSISTANT transcript (`regenerate == true`).
    func generateTitle(_ threadID: String, regenerate: Bool) async {
        guard let thread = thread(threadID) else { return }
        let selection = settings.textGenerationModel
        guard let driver = environment.drivers[selection.provider] else { return }
        let prompt: String
        if regenerate {
            prompt = TextGeneration.regenerateTitlePrompt(previousTitle: thread.title, transcript: TextGeneration.titleTranscript(thread))
        } else {
            guard let first = thread.turns.first?.userMessage else { return }
            prompt = TextGeneration.initialTitlePrompt(message: first.text, attachments: first.attachments)
        }
        let request = UUID()
        let rt = runtime.thread(threadID)
        rt.titleRequest = request
        let titleBefore = thread.title
        let cwd = workingDirectory(for: thread)
        updateThread(threadID) { $0.isGeneratingTitle = true }

        var generated: String?
        var delay = runtime.titleRetryDelay
        for attempt in 0..<(regenerate ? 1 : 3) {
            if attempt > 0 {
                try? await Task.sleep(for: delay)
                delay = delay * 2
            }
            do {
                let result = try await driver.generateJSON(prompt: prompt, schema: TextGeneration.titleSchema, model: selection.model, cwd: cwd)
                generated = TextGeneration.sanitizeTitle(result["title"]?.stringValue ?? result.stringValue ?? "")
                break
            } catch {
                Self.log.error("Title generation failed: \(Self.describe(error), privacy: .public)")
            }
        }
        guard rt.titleRequest == request else { return }
        rt.titleRequest = nil
        updateThread(threadID) { thread in
            thread.isGeneratingTitle = false
            guard let generated, generated != TextGeneration.defaultTitle else { return }
            if regenerate || thread.title == titleBefore { thread.title = generated }
        }
    }

    // MARK: Worktree branch names

    /// Renames a temporary worktree branch to `<branchPrefix>/<generated fragment>` and updates
    /// every thread on it. Failures keep the temporary name.
    func renameTemporaryBranch(_ temporaryBranch: String, worktreePath: String, message: UserMessage) async {
        let selection = settings.textGenerationModel
        guard let driver = environment.drivers[selection.provider] else { return }
        let git = environment.git
        do {
            let prompt = TextGeneration.branchNamePrompt(message: message.text, attachments: message.attachments)
            let result = try await driver.generateJSON(prompt: prompt, schema: TextGeneration.branchSchema, model: selection.model, cwd: worktreePath)
            guard let raw = result["branch"]?.stringValue else { return }
            let preferred = TextGeneration.formatGeneratedBranchName(raw, prefix: settings.branchPrefix)
            let existing = Set(((try? await git.branches(cwd: worktreePath)) ?? []).filter { !$0.isRemote }.map(\.name))
            var name = preferred
            var suffix = 2
            while existing.contains(name), name != temporaryBranch {
                name = "\(preferred)-\(suffix)"
                suffix += 1
            }
            guard name != temporaryBranch else { return }
            try await git.renameBranch(cwd: worktreePath, from: temporaryBranch, to: name)
            for thread in threads where thread.branch == temporaryBranch && thread.worktreePath == worktreePath {
                updateThread(thread.id) { $0.branch = name }
            }
        } catch {
            Self.log.error("Worktree branch rename failed: \(Self.describe(error), privacy: .public)")
        }
    }
}
