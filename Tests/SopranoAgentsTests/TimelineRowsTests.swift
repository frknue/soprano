import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct TimelineRowsTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let selection = ModelSelection(provider: .omp, model: "openai-codex/gpt-6.1-sol")

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func item(_ id: String, _ kind: TurnItemKind, status: TurnItemStatus = .completed, at seconds: TimeInterval = 1) -> TurnItem {
        TurnItem(id: id, kind: kind, status: status, startedAt: at(seconds), completedAt: status.isActive ? nil : at(seconds + 1))
    }

    private func turn(
        _ id: String = "t1",
        status: TurnStatus = .completed,
        duration: TimeInterval = 192,
        items: [TurnItem],
        steers: [UserMessage] = [],
        files: [ChangedFileStat] = [],
        failure: String? = nil
    ) -> Turn {
        Turn(
            id: id, ordinal: 1, userMessage: UserMessage(id: "m-\(id)", text: "Fix it", createdAt: start),
            modelSelection: selection, status: status, failureMessage: failure, startedAt: start,
            completedAt: status == .running ? nil : at(duration), items: items, steers: steers,
            checkpoint: files.isEmpty ? nil : TurnCheckpoint(ref: "refs/x", status: .ready, files: files)
        )
    }

    private func thread(_ turns: [Turn], queue: [QueuedMessage] = []) -> AgentThread {
        AgentThread(id: "thread", projectID: nil, modelSelection: selection, turns: turns, queue: queue)
    }

    private func ids(_ rows: [TimelineRow]) -> [String] { rows.map(\.id) }

    private var workedTurn: Turn {
        turn(items: [
            item("r1", .reasoning(text: "Tracing.")),
            item("c1", .command(CommandExecution(command: "rg x"))),
            item("t1", .toolCall(ToolCall(name: "Read", category: .read, title: "Read A.swift"))),
            item("a1", .assistantMessage(text: "Found it.", isFinal: false)),
            item("f1", .fileChange([FileChange(path: "A.swift", kind: .update)])),
            item("a2", .assistantMessage(text: "Fixed.", isFinal: true)),
        ], files: [ChangedFileStat(path: "A.swift", additions: 3, deletions: 1)])
    }

    @Test func aFinishedTurnFoldsItsWorkAndKeepsTheAnswerWithItsChangedFiles() {
        let rows = TimelineBuilder.rows(for: thread([workedTurn]))
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "assistant:a2"])
        guard case let .fold(fold) = rows[1].content, case let .assistant(answer) = rows[2].content else {
            Issue.record("unexpected rows \(rows)")
            return
        }
        #expect(fold.label == "Worked for 3m 12s")
        #expect(!fold.expanded)
        #expect(answer.showMeta)
        #expect(answer.changedFiles?.files.map(\.path) == ["A.swift"])
        #expect(answer.changedFiles?.turnOrdinal == 1)
    }

    @Test func openingTheFoldShowsCommentaryBetweenSummarizedWorkGroups() {
        let rows = TimelineBuilder.rows(for: thread([workedTurn]), expansion: TimelineExpansion(turns: ["t1"]))
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "group:r1", "assistant:a1", "entry:f1", "assistant:a2"])
        guard case let .workGroup(group) = rows[2].content, case let .assistant(commentary) = rows[3].content else {
            Issue.record("unexpected rows \(rows)")
            return
        }
        #expect(group.summary == "Ran 1 command and read 1 file")
        #expect(!commentary.showMeta)

        let open = TimelineBuilder.rows(for: thread([workedTurn]), expansion: TimelineExpansion(turns: ["t1"], groups: ["group:r1"]))
        #expect(ids(open) == ["user:m-t1", "fold:t1", "group:r1", "entry:r1", "entry:c1", "entry:t1", "assistant:a1", "entry:f1", "assistant:a2"])
    }

    @Test func adjacentWorkLogRowsSitFlushAndBlocksKeepTheirSpacing() {
        let rows = TimelineBuilder.rows(for: thread([workedTurn]), expansion: TimelineExpansion(turns: ["t1"], groups: ["group:r1"]))
        let spacing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.bottomSpacing) })
        #expect(spacing["user:m-t1"] == 16)
        #expect(spacing["fold:t1"] == 6)
        #expect(spacing["group:r1"] == 0)
        #expect(spacing["entry:r1"] == 0)
        #expect(spacing["entry:t1"] == 4)
        #expect(spacing["assistant:a1"] == 8)
        #expect(spacing["entry:f1"] == 8)
        #expect(spacing["assistant:a2"] == 16)
    }

    @Test func anInterruptedTurnSaysTheUserStoppedIt() {
        let stopped = turn(status: .interrupted, duration: 12, items: [item("c1", .command(CommandExecution(command: "make")))])
        let rows = TimelineBuilder.rows(for: thread([stopped]))
        guard case let .fold(fold) = rows[1].content else {
            Issue.record("expected a fold, got \(rows)")
            return
        }
        #expect(fold.label == "You stopped after 12s")
        // No answer: closing the fold leaves only the fold.
        #expect(ids(rows) == ["user:m-t1", "fold:t1"])
    }

    @Test func aFailedTurnStaysOpenAndEndsWithItsFailure() {
        let failed = turn(status: .failed, items: [item("c1", .command(CommandExecution(command: "make", exitCode: 2)), status: .failed)], failure: "Codex exited.")
        let rows = TimelineBuilder.rows(for: thread([failed]))
        #expect(ids(rows) == ["user:m-t1", "entry:c1", "failure:t1"])
        #expect(rows[2].content == .error(message: "Codex exited.", date: at(192)))
    }

    @Test func aRunningTurnShowsWorkingThenItsLiveToolWithTheLatestThought() {
        let running = turn(status: .running, items: [
            item("r1", .reasoning(text: "**Looking for settings.** More text.")),
            item("s1", .toolCall(ToolCall(name: "Grep", category: .search, title: "Searched Theme"))),
            item("c1", .command(CommandExecution(command: "swift build")), status: .running),
        ])
        let rows = TimelineBuilder.rows(for: thread([running]))
        #expect(ids(rows) == ["user:m-t1", "working:t1", "live:t1"])
        #expect(rows[1].content == .working(startedAt: start, stopping: false))
        guard case let .liveWork(live) = rows[2].content else {
            Issue.record("expected a live row, got \(rows)")
            return
        }
        #expect(live.entry.id == "c1")
        #expect(live.thought == "Looking for settings.")
        #expect(live.active)
        guard case let .user(user) = rows[0].content else { return }
        #expect(!user.canEdit)
    }

    @Test func aRunningTurnWithoutToolsEndsWithThinking() {
        let running = turn(status: .running, items: [item("a1", .assistantMessage(text: "On it.", isFinal: false), status: .running)])
        let rows = TimelineBuilder.rows(for: thread([running]))
        #expect(ids(rows) == ["user:m-t1", "working:t1", "assistant:a1", "thinking:t1"])
        guard case let .assistant(message) = rows[2].content else { return }
        #expect(message.isStreaming)
        #expect(!message.showMeta)
    }

    @Test func nobodyIsThinkingAfterTheAnswerUntilTheAgentWorksAgain() {
        let answered = turn(status: .running, items: [item("a1", .assistantMessage(text: "Done.", isFinal: true))])
        #expect(ids(TimelineBuilder.rows(for: thread([answered]))) == ["user:m-t1", "working:t1", "assistant:a1"])

        let secondPass = turn(status: .running, items: [
            item("a1", .assistantMessage(text: "Done.", isFinal: true)),
            item("n1", .notice(text: "auto-double-check: second pass before finishing")),
        ])
        #expect(ids(TimelineBuilder.rows(for: thread([secondPass]))).last == "thinking:t1")
    }

    @Test func aStoppingTurnSaysSoInsteadOfThinking() {
        var stopping = turn(status: .running, items: [item("a1", .assistantMessage(text: "On it.", isFinal: false))])
        stopping.stopRequestedAt = at(5)
        let rows = TimelineBuilder.rows(for: thread([stopping]))

        #expect(ids(rows) == ["user:m-t1", "working:t1", "assistant:a1"])
        #expect(rows[1].content == .working(startedAt: start, stopping: true))
    }

    @Test func aPendingApprovalStandsAloneAndNobodyIsThinking() {
        let waiting = turn(status: .running, items: [
            item("c1", .command(CommandExecution(command: "ls"))),
            item("p1", .approval(ApprovalRequest(id: "req", kind: .command, detail: "swift test")), status: .pending),
        ])
        let rows = TimelineBuilder.rows(for: thread([waiting]))
        #expect(ids(rows) == ["user:m-t1", "working:t1", "entry:c1", "approval:p1"])
    }

    @Test func pendingQuestionsStandAloneAndAnsweredOnesSurviveTheFold() {
        let question = UserInputQuestion(id: "q", header: "Fix", question: "How?", options: [])
        let pending = turn(status: .running, items: [item("q1", .userInput(UserInputRequest(id: "in", questions: [question])), status: .pending)])
        #expect(ids(TimelineBuilder.rows(for: thread([pending]))) == ["user:m-t1", "working:t1", "entry:q1"])

        let answered = turn(items: [
            item("c1", .command(CommandExecution(command: "ls"))),
            item("q1", .userInput(UserInputRequest(id: "in", questions: [question], answers: ["q": ["Await"]]))),
        ])
        let rows = TimelineBuilder.rows(for: thread([answered]))
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "entry:q1"])
        guard case let .workEntry(entry) = rows[2].content else { return }
        #expect(entry.entry.label == "Answered questions")
        #expect(entry.entry.note == "Await")
    }

    @Test func noticesAreNeverFolded() {
        let noted = turn(items: [
            item("c1", .command(CommandExecution(command: "ls"))),
            item("n1", .notice(text: "Context compacted")),
        ])
        #expect(ids(TimelineBuilder.rows(for: thread([noted]))) == ["user:m-t1", "fold:t1", "notice:n1"])
    }

    @Test func advisorNotesStayOutOfTheFoldOneRowPerNoteWithoutBringingBackThinking() {
        let notes = [AdvisorNote(text: "Run the tests.", severity: .concern, advisor: "Final reviewer"), AdvisorNote(text: "Typo in the commit.")]
        let reviewed = turn(items: [
            item("c1", .command(CommandExecution(command: "ls"))),
            item("a1", .assistantMessage(text: "Done.", isFinal: true)),
            item("v1", .advisory(notes)),
        ])
        let rows = TimelineBuilder.rows(for: thread([reviewed]))
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "assistant:a1", "advisory:v1:0", "advisory:v1:1"])
        #expect(rows[3].content == .advisory(AdvisoryRowModel(note: notes[0], date: at(1))))

        var running = reviewed
        running.status = .running
        #expect(ids(TimelineBuilder.rows(for: thread([running]))).last == "advisory:v1:1")
    }

    @Test func aSecondPassKeepsTheFirstAnswerOutOfTheFold() {
        let note = AdvisorNote(text: "Check the claims.", severity: .concern, advisor: "Final reviewer")
        let rechecked = turn(items: [
            item("c1", .command(CommandExecution(command: "rg x"))),
            item("a1", .assistantMessage(text: "Recap.", isFinal: true)),
            item("v1", .advisory([note])),
            item("n1", .notice(text: "auto-double-check: second pass before finishing")),
            item("a2", .assistantMessage(text: "Re-checking.", isFinal: false)),
            item("c2", .command(CommandExecution(command: "swift test"))),
            item("a3", .assistantMessage(text: "Second pass.", isFinal: true)),
        ], files: [ChangedFileStat(path: "A.swift", additions: 1, deletions: 0)])
        let rows = TimelineBuilder.rows(for: thread([rechecked]))
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "assistant:a1", "advisory:v1:0", "notice:n1", "assistant:a3"])
        guard case let .assistant(first) = rows[2].content, case let .assistant(last) = rows[5].content else {
            Issue.record("unexpected rows \(rows)")
            return
        }
        #expect(first.showMeta)
        #expect(first.changedFiles == nil)
        #expect(last.showMeta)
        #expect(last.changedFiles?.files.map(\.path) == ["A.swift"])

        let open = TimelineBuilder.rows(for: thread([rechecked]), expansion: TimelineExpansion(turns: ["t1"]))
        #expect(ids(open) == ["user:m-t1", "fold:t1", "entry:c1", "assistant:a1", "advisory:v1:0", "notice:n1", "assistant:a2", "entry:c2", "assistant:a3"])
    }

    @Test func backgroundWorkThatWakesTheTurnBringsBackThinkingAndKeepsTheYieldedAnswer() {
        var resumed = turn(status: .running, items: [
            item("c1", .command(CommandExecution(command: "sleep 8")), at: 1),
            item("a1", .assistantMessage(text: "Started.", isFinal: true), at: 2),
        ])
        #expect(ids(TimelineBuilder.rows(for: thread([resumed]))).last == "assistant:a1")
        resumed.resumedAt = at(10)
        #expect(ids(TimelineBuilder.rows(for: thread([resumed]))).last == "thinking:t1")

        resumed.items.append(item("a2", .assistantMessage(text: "The job finished.", isFinal: true), at: 12))
        #expect(ids(TimelineBuilder.rows(for: thread([resumed]))).last == "assistant:a2")

        resumed.status = .completed
        resumed.completedAt = at(20)
        resumed.resumedAt = nil
        #expect(ids(TimelineBuilder.rows(for: thread([resumed]))) == ["user:m-t1", "fold:t1", "assistant:a1", "assistant:a2"])
    }

    @Test func changedFilesWithoutAnAnswerGetTheirOwnCard() {
        let silent = turn(items: [item("f1", .fileChange([FileChange(path: "A.swift", kind: .add)]))], files: [ChangedFileStat(path: "A.swift", additions: 1, deletions: 0)])
        #expect(ids(TimelineBuilder.rows(for: thread([silent]))) == ["user:m-t1", "fold:t1", "files:t1"])
    }

    @Test func steersSitWhereTheyWereSent() {
        let steer = UserMessage(id: "steer", text: "Also docs", createdAt: at(2.5), isSteer: true)
        let steered = turn(status: .running, items: [
            item("c1", .command(CommandExecution(command: "ls")), at: 1),
            item("c2", .command(CommandExecution(command: "make")), status: .running, at: 3),
        ], steers: [steer])
        let rows = TimelineBuilder.rows(for: thread([steered]))
        #expect(ids(rows) == ["user:m-t1", "working:t1", "entry:c1", "user:steer", "live:t1"])
        guard case let .user(model) = rows[3].content else { return }
        #expect(model.turnID == nil)
    }

    @Test func queuedMessagesCloseTheThreadAndEmptyThreadsSayHowToStart() {
        let queued = QueuedMessage(message: UserMessage(id: "q", text: "Next"), modelSelection: selection)
        let rows = TimelineBuilder.rows(for: thread([workedTurn], queue: [queued]))
        #expect(rows.last?.id == "queued:q")
        #expect(ids(TimelineBuilder.rows(for: thread([]))) == ["empty"])
        #expect(TimelineBuilder.rows(for: nil).isEmpty)
    }

    @Test func aYieldedTurnShowsFinishedWithABackgroundNoteUntilItEnds() {
        var yielded = workedTurn
        yielded.status = .running
        yielded.completedAt = nil
        yielded.yieldedAt = at(60)
        let rows = TimelineBuilder.rows(for: thread([yielded]))

        #expect(ids(rows) == ["user:m-t1", "fold:t1", "assistant:a2", "background:t1"])
        guard case let .fold(fold) = rows[1].content, case let .user(user) = rows[0].content else { return }
        #expect(fold.label == "Worked for 1m")
        #expect(user.canEdit)
        #expect(rows[3].content == .backgroundWork)
    }
}
