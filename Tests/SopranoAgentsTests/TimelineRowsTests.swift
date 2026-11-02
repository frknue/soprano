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
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "group:r1", "assistant:a1", "diff:f1:0", "assistant:a2"])
        guard case let .workGroup(group) = rows[2].content, case let .assistant(commentary) = rows[3].content else {
            Issue.record("unexpected rows \(rows)")
            return
        }
        #expect(group.summary == "Ran 1 command and read 1 file")
        #expect(!commentary.showMeta)

        let open = TimelineBuilder.rows(for: thread([workedTurn]), expansion: TimelineExpansion(turns: ["t1"], groups: ["group:r1"]))
        #expect(ids(open) == ["user:m-t1", "fold:t1", "group:r1", "entry:r1", "entry:c1", "entry:t1", "assistant:a1", "diff:f1:0", "assistant:a2"])
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
        #expect(spacing["diff:f1:0"] == 8)
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

    @Test func anUnansweredReviewClosesUnderTheAnswerWithItsNoteAndOpensOneRowPerNote() {
        let notes = [AdvisorNote(text: "Run the tests. Then say so.", severity: .concern, advisor: "Final reviewer"), AdvisorNote(text: "Typo in the commit.")]
        let reviewed = turn(items: [
            item("c1", .command(CommandExecution(command: "ls"))),
            item("a1", .assistantMessage(text: "Done.", isFinal: true)),
            item("v1", .advisory(notes)),
        ])
        let rows = TimelineBuilder.rows(for: thread([reviewed]))
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "assistant:a1", "checks:t1"])
        #expect(rows[3].content == .checks(ChecksRowModel(turnID: "t1", passes: [
            CheckPassModel(sources: ["Final reviewer", "Advisor"], severity: .concern, outcome: nil, note: "Run the tests. Then say so."),
        ], expanded: false)))

        let open = TimelineBuilder.rows(for: thread([reviewed]), expansion: TimelineExpansion(checks: ["t1"]))
        #expect(ids(open) == ["user:m-t1", "fold:t1", "assistant:a1", "checks:t1", "advisory:v1:0", "advisory:v1:1"])
        #expect(open[4].content == .advisory(AdvisoryRowModel(note: notes[0], date: at(1))))

        var running = reviewed
        running.status = .running
        #expect(ids(TimelineBuilder.rows(for: thread([running]))).suffix(2) == ["advisory:v1:0", "advisory:v1:1"])
    }

    @Test func checksAfterTheRecapCloseUnderItWithEachReplysOpeningProseAndKeepErrorsOut() {
        let first = AdvisorNote(text: "Check the claims.", severity: .concern, advisor: "Final reviewer")
        let second = AdvisorNote(text: "Cap is 4 s.", severity: .nit, advisor: "Final reviewer")
        let rechecked = turn(items: [
            item("c1", .command(CommandExecution(command: "rg x"))),
            item("a1", .assistantMessage(text: "Recap.", isFinal: true)),
            item("v1", .advisory([first])),
            item("n1", .notice(text: "auto-double-check: second pass before finishing")),
            item("a2", .assistantMessage(text: "Re-checking.", isFinal: false)),
            item("c2", .command(CommandExecution(command: "swift test"))),
            item("e1", .error(message: "Tool crashed.")),
            item("a3", .assistantMessage(text: "**Double-check report**\n\nThe second pass found one bug.\nIt is fixed.\n\n| # | Status |\n|---|---|", isFinal: true)),
            item("v2", .advisory([second])),
            item("c3", .command(CommandExecution(command: "swift test"))),
            // A correction in the second sentence must survive into the closed row.
            item("a4", .assistantMessage(text: "I changed [PR #47](https://x.test) after the review. **The reviewer was right**, and that changes my earlier conclusion: the audit stays red.\n\n- `a.swift`: fixed", isFinal: true)),
        ], files: [ChangedFileStat(path: "A.swift", additions: 1, deletions: 0)])

        let rows = TimelineBuilder.rows(for: thread([rechecked]))
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "assistant:a1", "checks:t1", "error:e1"])
        guard case let .assistant(recap) = rows[2].content else {
            Issue.record("unexpected rows \(rows)")
            return
        }
        #expect(recap.showMeta)
        #expect(recap.changedFiles?.files.map(\.path) == ["A.swift"])
        #expect(rows[3].content == .checks(ChecksRowModel(turnID: "t1", passes: [
            CheckPassModel(sources: ["Final reviewer", "Double-check"], severity: .concern, outcome: "The second pass found one bug. It is fixed.", note: "Check the claims."),
            CheckPassModel(sources: ["Final reviewer"], severity: .nit, outcome: "I changed PR #47 after the review. The reviewer was right, and that changes my earlier conclusion: the audit stays red. a.swift: fixed", note: "Cap is 4 s."),
        ], expanded: false)))

        let checks = TimelineBuilder.rows(for: thread([rechecked]), expansion: TimelineExpansion(checks: ["t1"]))
        #expect(ids(checks) == ["user:m-t1", "fold:t1", "assistant:a1", "checks:t1", "advisory:v1:0", "notice:n1", "error:e1", "assistant:a3", "advisory:v2:0", "assistant:a4"])
        guard case let .assistant(last) = checks[9].content else { return }
        #expect(last.showMeta)
        #expect(last.changedFiles == nil)

        let all = TimelineBuilder.rows(for: thread([rechecked]), expansion: TimelineExpansion(turns: ["t1"], checks: ["t1"]))
        #expect(ids(all) == [
            "user:m-t1", "fold:t1", "entry:c1", "assistant:a1", "checks:t1", "advisory:v1:0", "notice:n1",
            "assistant:a2", "entry:c2", "error:e1", "assistant:a3", "advisory:v2:0", "entry:c3", "assistant:a4",
        ])
    }

    @Test func onlyACheckThatWokeTheAgentWithoutTheUserCutsInClosesTheRest() {
        let compacted = turn(items: [
            item("a1", .assistantMessage(text: "Done.", isFinal: true), at: 1),
            item("n1", .notice(text: "Context compacted"), at: 3),
        ])
        #expect(ids(TimelineBuilder.rows(for: thread([compacted]))) == ["user:m-t1", "assistant:a1", "notice:n1"])

        let steered = turn(items: [
            item("a1", .assistantMessage(text: "Done.", isFinal: true), at: 1),
            item("n1", .notice(text: "auto-double-check: second pass before finishing"), at: 4),
            item("a2", .assistantMessage(text: "Docs too.", isFinal: true), at: 5),
        ], steers: [UserMessage(id: "steer", text: "Also docs", createdAt: at(3), isSteer: true)])
        #expect(ids(TimelineBuilder.rows(for: thread([steered]))) == ["user:m-t1", "assistant:a1", "user:steer", "notice:n1", "assistant:a2"])

        // Compaction and retry notices neither start a check nor name one.
        let noisy = turn(items: [
            item("a1", .assistantMessage(text: "Done.", isFinal: true)),
            item("n1", .notice(text: "Context compacted")),
            item("v1", .advisory([AdvisorNote(text: "Check it.", severity: .nit, advisor: "Final reviewer")])),
            item("n2", .notice(text: "auto-double-check: second pass before finishing")),
            item("n3", .notice(text: "Retrying (attempt 1 of 3): overloaded")),
            item("a2", .assistantMessage(text: "Checked.", isFinal: true)),
        ])
        guard case let .checks(model) = TimelineBuilder.rows(for: thread([noisy]))[2].content else {
            Issue.record("expected a checks row")
            return
        }
        #expect(model.passes.map(\.sources) == [["Final reviewer", "Double-check"]])
    }

    @Test func stoppedAndWokenTurnsKeepEveryAnswerAndFailedWorkAfterTheLastReplyStaysVisible() {
        let checkedItems = [
            item("a1", .assistantMessage(text: "Recap.", isFinal: true)),
            item("n1", .notice(text: "auto-double-check: second pass before finishing")),
            item("a2", .assistantMessage(text: "Let me re-run the tests.", isFinal: false)),
            item("c1", .command(CommandExecution(command: "swift test")), status: .interrupted),
        ]
        let stopped = turn(status: .interrupted, items: checkedItems)
        #expect(ids(TimelineBuilder.rows(for: thread([stopped]))) == ["user:m-t1", "fold:t1", "assistant:a1", "notice:n1", "assistant:a2"])

        // A background job's report after a review is no reply to it.
        var woken = turn(items: [
            item("a1", .assistantMessage(text: "Started the suite.", isFinal: true)),
            item("v1", .advisory([AdvisorNote(text: "Check it.", severity: .concern)])),
            item("c1", .command(CommandExecution(command: "cat log"))),
            item("a2", .assistantMessage(text: "The suite finished: 3 tests fail.", isFinal: true)),
        ])
        woken.wokenAt = at(5)
        #expect(ids(TimelineBuilder.rows(for: thread([woken]))) == ["user:m-t1", "fold:t1", "assistant:a1", "advisory:v1:0", "assistant:a2"])

        let failedPush = turn(items: [
            item("a1", .assistantMessage(text: "Recap.", isFinal: true)),
            item("v1", .advisory([AdvisorNote(text: "Push it.", severity: .concern)])),
            item("a2", .assistantMessage(text: "Pushing the fix.", isFinal: true)),
            item("c1", .command(CommandExecution(command: "git push", exitCode: 1)), status: .failed),
        ])
        #expect(ids(TimelineBuilder.rows(for: thread([failedPush]))) == ["user:m-t1", "assistant:a1", "checks:t1", "entry:c1"])
    }

    @Test func theWorkedForFoldStaysWhenOnlyTheClosedChecksHideWork() {
        let checked = turn(items: [
            item("a1", .assistantMessage(text: "Recap.", isFinal: true)),
            item("v1", .advisory([AdvisorNote(text: "Check it.")])),
            item("c1", .command(CommandExecution(command: "swift test"))),
            item("a2", .assistantMessage(text: "Checked.", isFinal: true)),
        ])
        #expect(ids(TimelineBuilder.rows(for: thread([checked]))) == ["user:m-t1", "fold:t1", "assistant:a1", "checks:t1"])
        let open = TimelineBuilder.rows(for: thread([checked]), expansion: TimelineExpansion(checks: ["t1"]))
        #expect(ids(open) == ["user:m-t1", "fold:t1", "assistant:a1", "checks:t1", "advisory:v1:0", "assistant:a2"])
    }

    @Test func aChecksReplyReadsAsItsProseUpToAboutFourLines() {
        let report = """
        **Double-check report**

        | # | Status |
        |---|---|
        | 1 | verified |

        Re-ran `swift test`: 214 tests pass.

        **Defects:** `testBackoffCap` still expected 8 s, so my earlier claim was wrong.
        """
        #expect(TimelineBuilder.openingProse(report) == "Re-ran swift test: 214 tests pass. Defects: testBackoffCap still expected 8 s, so my earlier claim was wrong.")
        #expect(TimelineBuilder.openingProse("#47 is merged.\n\nAll checks pass.") == "#47 is merged. All checks pass.")
        #expect(TimelineBuilder.openingProse("## Result\n\n| # | Status |\n|---|---|\n| 1 | failing |") == "# · Status / 1 · failing")
        #expect(TimelineBuilder.openingProse("```\nlog\n```\n**Done**") == "Done")
        let long = Array(repeating: "A sentence of forty characters or so.", count: 40).joined(separator: "\n\n")
        #expect((TimelineBuilder.openingProse(long)?.count ?? 0) < 560)

        // The pass's final answer is its reply, even when commentary came first.
        let pass = turn(items: [
            item("a1", .assistantMessage(text: "Recap.", isFinal: true)),
            item("n1", .notice(text: "auto-double-check: second pass before finishing")),
            item("a2", .assistantMessage(text: "Let me re-run the tests.", isFinal: false)),
            item("c1", .command(CommandExecution(command: "swift test"))),
            item("a3", .assistantMessage(text: "| Requirement | Status |\n|---|---|\n| Cap | failing |", isFinal: true)),
        ])
        guard case let .checks(model) = TimelineBuilder.rows(for: thread([pass]))[3].content else {
            Issue.record("expected a checks row")
            return
        }
        #expect(model.passes.map(\.outcome) == ["Requirement · Status / Cap · failing"])
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

    // MARK: - Detailed work log and file diffs

    private var detailed: TimelineExpansion {
        var expansion = TimelineExpansion()
        expansion.detailed = true
        return expansion
    }

    private var editingTurn: Turn {
        turn(status: .running, items: [
            item("s1", .toolCall(ToolCall(name: "Read", category: .read, title: "Read A.swift")), at: 1),
            item("f1", .fileChange([FileChange(path: "A.swift", kind: .update, diff: "@@ -1,1 +1,1 @@\n-a\n+b")]), at: 2),
            item("f2", .fileChange([FileChange(path: "B.swift", kind: .add, diff: "@@ -0,0 +1,1 @@\n+new")]), status: .running, at: 3),
        ])
    }

    @Test func theDetailedLogListsARunningTurnsStepsWithTheEditBeingWrittenOpen() {
        let rows = TimelineBuilder.rows(for: thread([editingTurn]), expansion: detailed)
        #expect(ids(rows) == ["user:m-t1", "working:t1", "group:s1", "entry:s1", "diff:f1:0", "diff:f2:0"])
        guard case let .fileDiff(done) = rows[4].content, case let .fileDiff(live) = rows[5].content else {
            Issue.record("expected diff rows, got \(rows)")
            return
        }
        #expect(done.expanded && live.expanded)
        #expect(live.isActive)
        #expect(live.label == "Writing B.swift")
        #expect(done.label == "Edited A.swift")
    }

    @Test func openInDiffUsesTheFinishedTurnsCheckpointElseTheUncommittedChanges() {
        func turnOrdinals(_ rows: [TimelineRow]) -> [Int?] {
            rows.compactMap { if case let .fileDiff(model) = $0.content { model.turnOrdinal } else { nil } }
        }
        #expect(turnOrdinals(TimelineBuilder.rows(for: thread([editingTurn]), expansion: detailed)) == [nil, nil])

        let finished = turn(items: [
            item("f1", .fileChange([FileChange(path: "A.swift", kind: .update, diff: "@@ -1,1 +1,1 @@\n-a\n+b")])),
            item("a1", .assistantMessage(text: "Done.", isFinal: true)),
        ], files: [ChangedFileStat(path: "A.swift", additions: 1, deletions: 1)])
        #expect(turnOrdinals(TimelineBuilder.rows(for: thread([finished]), expansion: detailed)) == [1])
        #expect(turnOrdinals(TimelineBuilder.rows(for: thread([finished]), expansion: detailed, editable: false)) == [nil])
    }

    @Test func theDetailedLogKeepsARunningCommandsOutputOneClickAway() {
        let running = turn(status: .running, items: [
            item("s1", .toolCall(ToolCall(name: "Read", category: .read, title: "Read A.swift")), at: 1),
            item("c1", .command(CommandExecution(command: "swift test", output: "Building…\n")), status: .running, at: 2),
        ])
        let closed = TimelineBuilder.rows(for: thread([running]), expansion: detailed)
        #expect(ids(closed) == ["user:m-t1", "working:t1", "group:s1", "entry:s1", "entry:c1"])
        guard case let .workEntry(command) = closed[4].content else { return }
        #expect(command.entry.isActive && command.entry.canExpand && !command.expanded)

        var expansion = detailed
        expansion.entries.insert("c1")
        let open = TimelineBuilder.rows(for: thread([running]), expansion: expansion)
        guard case let .workEntry(opened) = open[4].content else { return }
        #expect(opened.expanded)
        #expect(opened.entry.body == "$ swift test\nBuilding…")
        // No "Thinking": the running command is the live activity.
        #expect(!ids(open).contains("thinking:t1"))
    }

    @Test func betweenStepsTheDetailedLogSaysTheAgentIsThinking() {
        let between = turn(status: .running, items: [
            item("s1", .toolCall(ToolCall(name: "Read", category: .read, title: "Read A.swift")), at: 1),
            item("s2", .toolCall(ToolCall(name: "Read", category: .read, title: "Read B.swift")), at: 2),
        ])
        // Nothing runs, so nothing in the steps shimmers: the Thinking row shows the turn is alive.
        #expect(ids(TimelineBuilder.rows(for: thread([between]), expansion: detailed))
            == ["user:m-t1", "working:t1", "group:s1", "entry:s1", "entry:s2", "thinking:t1"])
        // The minimal live row shimmers with the last step instead.
        #expect(ids(TimelineBuilder.rows(for: thread([between]))) == ["user:m-t1", "working:t1", "live:t1"])
    }

    @Test func collapsingTheRunningGroupInTheDetailedLogGivesTheLiveRow() {
        var expansion = detailed
        expansion.set("group:s1", open: false, in: \.groups)
        let rows = TimelineBuilder.rows(for: thread([editingTurn]), expansion: expansion)
        #expect(ids(rows) == ["user:m-t1", "working:t1", "live:t1"])
    }

    @Test func theMinimalLogShowsOnlyTheLiveStepAndClosedDiffsWhenOpened() {
        #expect(ids(TimelineBuilder.rows(for: thread([editingTurn]))) == ["user:m-t1", "working:t1", "live:t1"])

        var expansion = TimelineExpansion()
        expansion.set("group:s1", open: true, in: \.groups)
        let rows = TimelineBuilder.rows(for: thread([editingTurn]), expansion: expansion)
        #expect(ids(rows) == ["user:m-t1", "working:t1", "live:t1", "entry:s1", "diff:f1:0", "diff:f2:0"])
        guard case let .fileDiff(diff) = rows[4].content else { return }
        #expect(!diff.expanded)
    }

    @Test func theDetailedLogOpensFinishedFoldsAndAClosedDiffStaysClosed() {
        let edited = turn(items: [
            item("f1", .fileChange([
                FileChange(path: "A.swift", kind: .update, diff: "@@ -1,1 +1,1 @@\n-a\n+b"),
                FileChange(path: "C.swift", kind: .delete),
            ])),
            item("a1", .assistantMessage(text: "Done.", isFinal: true)),
        ])
        var expansion = detailed
        expansion.set("f1:0", open: false, in: \.diffs)
        let rows = TimelineBuilder.rows(for: thread([edited]), expansion: expansion)
        #expect(ids(rows) == ["user:m-t1", "fold:t1", "diff:f1:0", "diff:f1:1", "assistant:a1"])
        guard case let .fold(fold) = rows[1].content, case let .fileDiff(closed) = rows[2].content,
              case let .fileDiff(deleted) = rows[3].content else { return }
        #expect(fold.expanded)
        #expect(!closed.expanded)
        #expect(!deleted.canExpand)
        #expect(deleted.label == "Deleted C.swift")

        expansion.set("t1", open: false, in: \.turns)
        #expect(ids(TimelineBuilder.rows(for: thread([edited]), expansion: expansion)) == ["user:m-t1", "fold:t1", "assistant:a1"])
    }
}
