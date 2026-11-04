import Foundation

/// Side questions (omp's `/btw`): questions about a thread's conversation, answered beside it
/// without steering it or joining it. The provider keeps their history; the engine holds what it
/// reported this run in `ThreadRuntime.sideQuestions` (not persisted) and announces
/// `.sideQuestionsChanged`. One side question runs per thread at a time.
extension AgentEngine {
    /// The thread's side questions known this run, newest first.
    public func sideQuestions(_ threadID: String?) -> [SideQuestion] {
        guard let threadID else { return [] }
        return runtime.existingThread(threadID)?.sideQuestions ?? []
    }

    /// A side question of the thread is starting: asked, and not reported by the provider yet
    /// (`cancelSideQuestion` stops it). Changes announce `.sideQuestionsChanged`.
    public func isStartingSideQuestion(_ threadID: String?) -> Bool {
        guard let threadID else { return false }
        return runtime.existingThread(threadID)?.isAskingSideQuestion ?? false
    }

    /// Asks a side question about the thread's conversation, or a follow-up in topic `topicID`
    /// (resuming the provider session first, like `send`). Runs beside a running turn. Returns
    /// the topic's id once the provider started it; the answer streams in through
    /// `.sideQuestionsChanged`. Throws for an empty question, while another side question runs or
    /// starts, and when the thread has no conversation yet. Stopped by `cancelSideQuestion` while
    /// it starts: throws `CancellationError` when the provider never took it up, else cancels the
    /// topic the provider started (reported as cancelled) and returns it.
    @discardableResult
    public func askSideQuestion(_ threadID: String, question: String, topicID: String? = nil) async throws -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw EngineError.emptyMessage }
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let rt = runtime.thread(threadID)
        guard !rt.isAskingSideQuestion, !sideQuestions(threadID).contains(where: \.isRunning) else {
            throw EngineError.message("A side question is still being answered. Stop it or wait for its answer.")
        }
        guard hasProviderConversation(thread) else {
            throw EngineError.message("A side question asks about the conversation, so send the thread a message first.")
        }
        rt.isAskingSideQuestion = true
        rt.sideQuestionCancelRequested = false
        emit(.sideQuestionsChanged(threadID: threadID))
        defer {
            rt.isAskingSideQuestion = false
            rt.sideQuestionCancelRequested = false
            emit(.sideQuestionsChanged(threadID: threadID))
        }
        let session = try await ensureSession(threadID)
        if rt.sideQuestionCancelRequested { throw CancellationError() }
        let record: SideQuestion
        do {
            record = try await session.askSideQuestion(question, topicID: topicID)
        } catch where rt.sideQuestionCancelRequested {
            // The provider refused a question cancelled while it started.
            throw CancellationError()
        }
        if rt.sideQuestionCancelRequested {
            // Stop arrived before the provider took the question up (its cancel found nothing to
            // stop): stop the topic it started now. The topic's events report the cancellation.
            _ = await session.cancelSideQuestion()
        }
        // The provider's started event usually got here first, maybe with streamed text: the
        // answer only adds a topic (or a follow-up) not known yet.
        let known = sideQuestions(threadID).first { $0.id == record.id }
        if known.map({ record.followUps.count > $0.followUps.count }) ?? true {
            upsertSideQuestion(record, threadID: threadID)
        }
        return record.id
    }

    /// Cancels the thread's running side question (its partial answer stays), or one still
    /// starting (`askSideQuestion` then throws `CancellationError`). The thread's turn keeps
    /// going. False when none ran or started.
    @discardableResult
    public func cancelSideQuestion(_ threadID: String) async -> Bool {
        guard let rt = runtime.existingThread(threadID) else { return false }
        let starting = rt.isAskingSideQuestion
        guard starting || sideQuestions(threadID).contains(where: \.isRunning) else { return false }
        if starting { rt.sideQuestionCancelRequested = true }
        // A session still starting gets the cancel once the ask reaches it.
        guard let session = rt.session, rt.starting == nil else { return starting }
        let cancelled = await session.cancelSideQuestion()
        return cancelled || starting
    }

    /// Reads the conversation's side-question history from the provider (resuming its session
    /// when the thread has a conversation but no session this run), so topics from earlier runs
    /// and other clients (omp's TUI `/btw`) show. Without a live session a history read once
    /// stays; with one it is read again, except while a side question runs. A thread without a
    /// conversation has none.
    public func loadSideQuestions(_ threadID: String) async throws {
        guard let thread = thread(threadID) else { return }
        let rt = runtime.thread(threadID)
        if rt.sideQuestionsLoaded, rt.session == nil || rt.sideQuestions.contains(where: \.isRunning) { return }
        guard hasProviderConversation(thread) else {
            rt.sideQuestionsLoaded = true
            return
        }
        let session = try await ensureSession(threadID)
        restoreSideQuestions(try await session.sideQuestions(), threadID: threadID)
    }

    /// Merges the provider's history `records` into the thread's side questions (the snapshot
    /// harness seeds it). The history may have been read before events reported this run, so it
    /// never rolls a known topic back: a topic it lacks stays (the list holds only this
    /// conversation's topics, so the read predates it), and a known copy wins when it has more
    /// follow-ups, finished where the history's copy still runs, or streamed further.
    public func restoreSideQuestions(_ records: [SideQuestion], threadID: String) {
        let rt = runtime.thread(threadID)
        let known = Dictionary(rt.sideQuestions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let read = Set(records.map(\.id))
        let merged = records.map { record in known[record.id].map { Self.later($0, record) } ?? record }
            + rt.sideQuestions.filter { !read.contains($0.id) }
        rt.sideQuestions = Self.newestFirst(merged)
        rt.sideQuestionsLoaded = true
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    /// The more advanced of a known topic and the history's copy of it.
    private static func later(_ known: SideQuestion, _ record: SideQuestion) -> SideQuestion {
        if known.followUps.count != record.followUps.count {
            return known.followUps.count > record.followUps.count ? known : record
        }
        if record.isRunning, !known.isRunning { return known }
        if record.isRunning, known.latest.answer.count > record.latest.answer.count { return known }
        return record
    }

    // MARK: Event folding

    /// `ProviderEvent.sideQuestion`: the topic as the provider has it now.
    func upsertSideQuestion(_ record: SideQuestion, threadID: String) {
        let rt = runtime.thread(threadID)
        if let index = rt.sideQuestions.firstIndex(where: { $0.id == record.id }) {
            guard rt.sideQuestions[index] != record else { return }
            rt.sideQuestions[index] = record
        } else {
            rt.sideQuestions = Self.newestFirst(rt.sideQuestions + [record])
        }
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    /// `ProviderEvent.sideQuestionDelta`: streamed answer text of a running topic.
    func appendSideQuestionAnswer(_ id: String, delta: String, threadID: String) {
        guard let rt = runtime.existingThread(threadID),
              let index = rt.sideQuestions.firstIndex(where: { $0.id == id }),
              rt.sideQuestions[index].isRunning else { return }
        rt.sideQuestions[index].latest.answer += delta
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    /// The session ended: a side question still running went with it.
    func interruptSideQuestions(_ threadID: String) {
        guard let rt = runtime.existingThread(threadID), rt.sideQuestions.contains(where: \.isRunning) else { return }
        let now = environment.now()
        for index in rt.sideQuestions.indices where rt.sideQuestions[index].isRunning {
            rt.sideQuestions[index].latest.status = .interrupted
            rt.sideQuestions[index].latest.updatedAt = now
        }
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    /// The conversation became another one (a rewind forked or restarted it): its history is
    /// read again when asked for.
    func forgetSideQuestions(_ threadID: String) {
        guard let rt = runtime.existingThread(threadID), rt.sideQuestionsLoaded || !rt.sideQuestions.isEmpty else { return }
        rt.sideQuestions = []
        rt.sideQuestionsLoaded = false
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    private static func newestFirst(_ records: [SideQuestion]) -> [SideQuestion] {
        records.sorted { $0.first.createdAt > $1.first.createdAt }
    }
}
