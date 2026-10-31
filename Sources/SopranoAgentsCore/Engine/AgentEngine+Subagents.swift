import Foundation

/// Subagents: helper agents a thread's agent started. The provider reports them
/// (`ProviderEvent.subagent`); the engine keeps them in `AgentThread.subagents` (persisted) and
/// announces `.subagentChanged` (runs, items) and `.subagentListChanged` (added, status,
/// activity line). The user can message a running subagent or stop it.
extension AgentEngine {
    /// A subagent by its id in the thread (`Subagent.id`, not the provider's name).
    public func subagent(_ threadID: String?, _ subagentID: String?) -> Subagent? {
        thread(threadID)?.subagent(subagentID)
    }

    /// Sends `text` to a running subagent as its user. Its arrival shows up as the subagent
    /// reports it (a steer in its run, or a new run).
    public func steerSubagent(_ threadID: String, _ subagentID: String, text: String) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError.emptyMessage }
        guard let subagent = subagent(threadID, subagentID), subagent.isRunning,
              let session = runtime.existingThread(threadID)?.session else {
            let name = subagent(threadID, subagentID)?.name ?? subagentID
            throw EngineError.message("\(name) is not running, so it can’t take messages.")
        }
        try await session.steerSubagent(subagent.name, text: text)
    }

    /// Stops a running subagent; the thread's own turn keeps going.
    public func cancelSubagent(_ threadID: String, _ subagentID: String) async throws {
        guard let subagent = subagent(threadID, subagentID), subagent.isRunning,
              let session = runtime.existingThread(threadID)?.session else { return }
        try await session.cancelSubagent(subagent.name)
    }

    // MARK: Event folding

    /// Folds one provider event for the subagent the provider calls `name`: the latest one of
    /// that name, or a new one when none exists or the event's facts (transcript, starting tool
    /// call) show the name was handed out again.
    func applySubagent(_ name: String, _ event: SubagentEvent, threadID: String) {
        let now = environment.now()
        switch event {
        case let .updated(info):
            mutateSubagent(threadID, name, identity: info, create: true) { subagent in
                if let agent = info.agent { subagent.agent = agent }
                if let description = info.description { subagent.description = description }
                if let assignment = info.assignment { subagent.assignment = assignment }
                if let model = info.model { subagent.model = model }
                if let intent = info.lastIntent { subagent.lastIntent = intent }
                if let file = info.sessionFile { subagent.sessionFile = file }
                if let call = info.parentToolCallID { subagent.parentToolCallID = call }
                if let detached = info.isDetached { subagent.isDetached = detached }
                if let status = info.status, status != subagent.status {
                    subagent.status = status
                    subagent.completedAt = status == .running ? nil : now
                    if status != .running {
                        Self.endRun(&subagent, status: Self.turnStatus(status), error: status == .failed ? "The subagent failed." : nil, at: now)
                    }
                }
            }
        case let .runStarted(message):
            mutateSubagent(threadID, name, create: true) { subagent in
                Self.endRun(&subagent, status: .completed, error: nil, at: now)
                let selection = ModelSelection(
                    provider: thread(threadID)?.modelSelection.provider ?? .omp,
                    model: subagent.model ?? ModelSelection.ompDefaultModel
                )
                subagent.turns.append(Turn(
                    ordinal: subagent.turns.count + 1,
                    userMessage: UserMessage(text: message ?? subagent.assignment ?? "", createdAt: now),
                    modelSelection: selection,
                    startedAt: now
                ))
                subagent.status = .running
                subagent.completedAt = nil
            }
        case let .message(text):
            mutateSubagent(threadID, name) { subagent in
                guard let index = Self.openTurnIndex(subagent) else { return }
                subagent.turns[index].steers.append(UserMessage(text: text, createdAt: now, isSteer: true))
            }
        case let .itemUpdated(item):
            // An advisor review that arrives while the subagent is idle joins its last run.
            let isAdvisory = if case .advisory = item.kind { true } else { false }
            mutateSubagentItem(threadID, name, joinsLastRun: isAdvisory) { items in
                var item = item
                if !item.status.isActive, item.completedAt == nil { item.completedAt = now }
                if let existing = items.firstIndex(where: { $0.id == item.id }) {
                    item.startedAt = items[existing].startedAt
                    items[existing] = item
                } else {
                    items.append(item)
                }
            }
        case let .assistantDelta(itemID, delta):
            appendToSubagentItem(threadID, name, itemID, at: now, create: { .assistantMessage(text: delta, isFinal: false) }) { kind in
                guard case let .assistantMessage(text, final) = kind else { return nil }
                return .assistantMessage(text: text + delta, isFinal: final)
            }
        case let .reasoningDelta(itemID, delta):
            appendToSubagentItem(threadID, name, itemID, at: now, create: { .reasoning(text: delta) }) { kind in
                guard case let .reasoning(text) = kind else { return nil }
                return .reasoning(text: text + delta)
            }
        case let .commandOutputDelta(itemID, delta):
            appendToSubagentItem(threadID, name, itemID, at: now, create: { nil }) { kind in
                guard case var .command(execution) = kind else { return nil }
                execution.output += delta
                return .command(execution)
            }
        case let .runEnded(outcome, error):
            mutateSubagent(threadID, name) { subagent in
                let status: TurnStatus = switch outcome {
                case .completed: .completed
                case .interrupted: .interrupted
                case .failed: .failed
                }
                Self.endRun(&subagent, status: status, error: error, at: now)
            }
        }
    }

    /// The thread's session is gone: its running subagents went with it.
    func abortSubagents(_ threadID: String) {
        guard let thread = thread(threadID) else { return }
        let now = environment.now()
        for running in thread.subagents where running.isRunning {
            mutateSubagent(threadID, locate: { thread in thread.subagents.firstIndex { $0.id == running.id } }) { subagent in
                subagent.status = .aborted
                subagent.completedAt = now
                Self.endRun(&subagent, status: .interrupted, error: nil, at: now)
            }
        }
    }

    // MARK: Helpers

    private static func turnStatus(_ status: SubagentStatus) -> TurnStatus {
        switch status {
        case .running, .completed: .completed
        case .failed: .failed
        case .aborted: .interrupted
        }
    }

    private static func openTurnIndex(_ subagent: Subagent) -> Int? {
        guard let last = subagent.turns.indices.last, subagent.turns[last].status == .running else { return nil }
        return last
    }

    /// Ends the open run (and its live items) with `status`.
    private static func endRun(_ subagent: inout Subagent, status: TurnStatus, error: String?, at now: Date) {
        guard let index = openTurnIndex(subagent) else { return }
        var turn = subagent.turns[index]
        turn.status = status
        turn.completedAt = now
        if status == .failed { turn.failureMessage = error }
        for item in turn.items.indices where turn.items[item].status.isActive {
            turn.items[item].status = status == .completed ? .completed : .interrupted
            turn.items[item].completedAt = now
        }
        subagent.turns[index] = turn
    }

    /// Changes the subagent the provider calls `name` (see `applySubagent`; created when
    /// `create`), persists, and announces it.
    private func mutateSubagent(_ threadID: String, _ name: String, identity: SubagentInfo? = nil, create: Bool = false, _ change: (inout Subagent) -> Void) {
        let now = environment.now()
        mutateSubagent(threadID, locate: { thread in
            if let index = thread.subagents.lastIndex(where: { $0.name == name }),
               !(identity.map { thread.subagents[index].isOther(than: $0) } ?? false) {
                return index
            }
            guard create else { return nil }
            var id = name
            var number = 1
            while thread.subagents.contains(where: { $0.id == id }) {
                number += 1
                id = "\(name)#\(number)"
            }
            thread.subagents.append(Subagent(id: id, providerID: id == name ? nil : name, agent: "agent", startedAt: now))
            return thread.subagents.count - 1
        }, change)
    }

    /// Changes the subagent `locate` finds (it may append one), persists, and announces
    /// `.subagentChanged` plus `.subagentListChanged` when the sidebar's view of it changed.
    private func mutateSubagent(_ threadID: String, locate: (inout AgentThread) -> Int?, _ change: (inout Subagent) -> Void) {
        let now = environment.now()
        var subagentID: String?
        guard let result = mutateThreadQuietly(threadID, { thread in
            guard let index = locate(&thread) else { return }
            var subagent = thread.subagents[index]
            subagentID = subagent.id
            change(&subagent)
            guard subagent != thread.subagents[index] else { return }
            subagent.updatedAt = now
            thread.subagents[index] = subagent
        }), let subagentID else { return }
        emit(.subagentChanged(threadID: threadID, subagentID: subagentID))
        if Self.subagentListDiffers(result.before.subagent(subagentID), result.after.subagent(subagentID)) {
            emit(.subagentListChanged(threadID: threadID))
        }
    }

    private func mutateSubagentItem(_ threadID: String, _ name: String, joinsLastRun: Bool = false, _ change: (inout [TurnItem]) -> Void) {
        mutateSubagent(threadID, name) { subagent in
            guard let index = Self.openTurnIndex(subagent) ?? (joinsLastRun ? subagent.turns.indices.last : nil) else { return }
            change(&subagent.turns[index].items)
        }
    }

    private func appendToSubagentItem(
        _ threadID: String,
        _ name: String,
        _ itemID: String,
        at now: Date,
        create: () -> TurnItemKind?,
        update: (TurnItemKind) -> TurnItemKind?
    ) {
        mutateSubagentItem(threadID, name) { items in
            if let existing = items.firstIndex(where: { $0.id == itemID }) {
                if let kind = update(items[existing].kind) { items[existing].kind = kind }
            } else if let kind = create() {
                items.append(TurnItem(id: itemID, kind: kind, status: .running, startedAt: now))
            }
        }
    }

    static func subagentListDiffers(_ lhs: Subagent?, _ rhs: Subagent?) -> Bool {
        lhs?.id != rhs?.id
            || lhs?.agent != rhs?.agent
            || lhs?.description != rhs?.description
            || lhs?.assignment != rhs?.assignment
            || lhs?.status != rhs?.status
            || lhs?.lastIntent != rhs?.lastIntent
            || lhs?.turns.count != rhs?.turns.count
    }
}
