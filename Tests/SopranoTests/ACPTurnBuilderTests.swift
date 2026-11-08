import AppKit
import Testing
@testable import Soprano

struct ACPTurnBuilderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func update(_ json: String) throws -> JSONValue {
        try JSONValue(parsing: Data(json.utf8))
    }

    @Test func streamedChunksOfOneMessageJoinIntoOneItemAfterItsThinking() throws {
        var builder = ACPTurnBuilder(cwd: "/work/repo", toolStyle: .omp)
        builder.addPrompt("Explain the build", at: now)
        for json in [
            #"{"sessionUpdate":"agent_thought_chunk","messageId":"m1","content":{"type":"text","text":"Reading "}}"#,
            #"{"sessionUpdate":"agent_thought_chunk","messageId":"m1","content":{"type":"text","text":"Package.swift"}}"#,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"It uses "}}"#,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"SwiftPM."}}"#,
        ] {
            #expect(builder.apply(try update(json), at: now))
        }
        let turn = try #require(builder.thread.turns.first)
        #expect(turn.userMessage.text == "Explain the build")
        #expect(turn.items.map(\.kind) == [.reasoning(text: "Reading Package.swift"), .assistantMessage(text: "It uses SwiftPM.", isFinal: false)])
        // The thought ended when the reply began; the reply still streams.
        #expect(turn.items.map(\.status) == [.completed, .running])
    }

    @Test func aMessageInterruptedByAToolCallContinuesInANewItemInOrder() throws {
        var builder = ACPTurnBuilder(cwd: nil, toolStyle: .omp)
        builder.addPrompt("Go", at: now)
        builder.apply(try update(#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"First"}}"#), at: now)
        builder.apply(try update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ ls","status":"pending","rawInput":{"command":"ls"}}"#), at: now)
        builder.apply(try update(#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"Then"}}"#), at: now)
        let kinds = try #require(builder.thread.turns.first).items.map(\.kind)
        #expect(kinds.count == 3)
        #expect(kinds[0] == .assistantMessage(text: "First", isFinal: false))
        #expect(kinds[2] == .assistantMessage(text: "Then", isFinal: false))
    }

    @Test func ompToolCallsMoveFromRunningToTheirResult() throws {
        var builder = ACPTurnBuilder(cwd: "/tmp/acp-probe", toolStyle: .omp)
        builder.addPrompt("List", at: now)
        builder.apply(try update(
            #"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ ls","kind":"execute","status":"pending","rawInput":{"command":"ls"}}"#
        ), at: now)
        #expect(builder.thread.turns[0].items[0].status == .pending)
        builder.apply(try update(
            #"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"in_progress","rawOutput":{"content":[{"type":"text","text":"a.txt"}]}}"#
        ), at: now)
        #expect(builder.thread.turns[0].items[0].kind == .command(TurnCommand(command: "ls", output: "a.txt")))
        #expect(builder.thread.turns[0].items[0].status == .running)
        builder.apply(try update(
            #"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","rawOutput":{"content":[{"type":"text","text":"a.txt\nb.txt"}],"details":{}}}"#
        ), at: now.addingTimeInterval(2))
        let item = builder.thread.turns[0].items[0]
        #expect(item.kind == .command(TurnCommand(command: "ls", output: "a.txt\nb.txt", exitCode: 0)))
        #expect(item.status == .completed)
        #expect(item.completedAt == now.addingTimeInterval(2))

        builder.apply(try update(
            #"{"sessionUpdate":"tool_call","toolCallId":"t2","name":"read","title":"Reading","status":"pending","rawInput":{"path":"/tmp/acp-probe/Sources/App.swift"}}"#
        ), at: now)
        builder.apply(try update(#"{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"failed","rawOutput":{"content":[{"type":"text","text":"No such file"}]}}"#), at: now)
        let read = builder.thread.turns[0].items[1]
        #expect(read.status == .failed)
        guard case let .toolCall(call) = read.kind else { Issue.record("No tool call"); return }
        #expect(call.category == .read)
        #expect(call.title == "Read Sources/App.swift")
    }

    @Test func anOmpEditReadsItsDiffAndPathFromTheDetails() throws {
        var builder = ACPTurnBuilder(cwd: "/tmp/acp-probe", toolStyle: .omp)
        builder.addPrompt("Edit", at: now)
        builder.apply(try update(
            #"{"sessionUpdate":"tool_call","toolCallId":"t2","name":"edit","title":"Replacing hello","kind":"edit","status":"pending","rawInput":{"path":"/tmp/acp-probe/a.txt","old_string":"hello","new_string":"goodbye"}}"#
        ), at: now)
        // Running: the code the arguments carry.
        #expect(builder.thread.turns[0].items[0].kind == .fileChange([
            FileChange(path: "a.txt", kind: .update, diff: "@@ -0,1 +0,1 @@\n-hello\n+goodbye"),
        ]))
        builder.apply(try update(
            #"{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"completed","rawOutput":{"content":[{"type":"text","text":"ok"}],"details":{"diff":" 1|one\n-2|hello\n+2|goodbye","path":"/tmp/acp-probe/a.txt"}}}"#
        ), at: now)
        #expect(builder.thread.turns[0].items[0].kind == .fileChange([
            FileChange(path: "a.txt", kind: .update, diff: "@@ -1,2 +1,2 @@\n one\n-hello\n+goodbye"),
        ]))
        builder.finishTurn(stopReason: "end_turn", at: now)
        #expect(builder.thread.turns[0].changedFiles == [ChangedFileStat(path: "a.txt", additions: 1, deletions: 1)])
    }

    @Test func otherAgentsEditsComeFromTheProtocolsDiffContent() throws {
        var builder = ACPTurnBuilder(cwd: "/repo", toolStyle: .generic)
        builder.addPrompt("Edit", at: now)
        builder.apply(try update(
            #"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Update the greeting","kind":"edit","status":"in_progress"}"#
        ), at: now)
        builder.apply(try update(
            #"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"diff","path":"/repo/a.txt","oldText":"one\nhello\nthree\n","newText":"one\ngoodbye\nthree\n"}]}"#
        ), at: now)
        #expect(builder.thread.turns[0].items[0].kind == .fileChange([
            FileChange(path: "a.txt", kind: .update, diff: "@@ -1,3 +1,3 @@\n one\n-hello\n+goodbye\n three"),
        ]))
    }

    @Test func endingATurnSetsItsStatusInterruptsRunningCallsAndMarksTheAnswer() throws {
        var builder = ACPTurnBuilder(cwd: nil, toolStyle: .omp)
        builder.addPrompt("Sleep", at: now)
        builder.apply(try update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ sleep 60","status":"pending","rawInput":{"command":"sleep 60"}}"#), at: now)
        builder.markStopRequested(at: now)
        #expect(builder.thread.activeTurn?.stopRequestedAt == now)
        builder.finishTurn(stopReason: "cancelled", at: now.addingTimeInterval(12))
        let stopped = builder.thread.turns[0]
        #expect(stopped.status == .interrupted)
        #expect(stopped.items[0].status == .interrupted)
        #expect(stopped.duration() == 12)
        #expect(TimelineBuilder.foldLabel(for: stopped) == "You stopped after 12s")

        builder.addPrompt("Answer", at: now)
        builder.apply(try update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}"#), at: now)
        builder.finishTurn(stopReason: "end_turn", at: now.addingTimeInterval(72))
        let answered = builder.thread.turns[1]
        #expect(answered.status == .completed)
        #expect(answered.items[0].kind == .assistantMessage(text: "Done.", isFinal: true))
        #expect(TimelineBuilder.foldLabel(for: answered) == "Worked for 1m 12s")

        builder.addPrompt("Limit", at: now)
        builder.finishTurn(stopReason: "max_tokens", at: now)
        #expect(builder.thread.turns[2].status == .failed)
        #expect(builder.thread.turns[2].failureMessage == "The reply reached the model's output limit.")
    }

    @Test func aReplayedConversationRebuildsItsTurnsWithoutTimes() throws {
        var builder = ACPTurnBuilder(cwd: nil, toolStyle: .omp)
        builder.isReplaying = true
        for json in [
            #"{"sessionUpdate":"user_message_chunk","messageId":"u1","content":{"type":"text","text":"Hi"}}"#,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"a1","content":{"type":"text","text":"Hello"}}"#,
            #"{"sessionUpdate":"user_message_chunk","messageId":"u2","content":{"type":"text","text":"Run "}}"#,
            #"{"sessionUpdate":"user_message_chunk","messageId":"u2","content":{"type":"text","text":"it"}}"#,
            #"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ make","status":"completed","rawInput":{"command":"make"},"rawOutput":{"content":[{"type":"text","text":"ok"}],"details":{"exitCode":0}}}"#,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"a2","content":{"type":"text","text":"Built."}}"#,
        ] {
            builder.apply(try update(json), at: now)
        }
        builder.isReplaying = false
        let turns = builder.thread.turns
        #expect(turns.map(\.userMessage.text) == ["Hi", "Run it"])
        #expect(turns.map(\.status) == [.completed, .completed])
        #expect(turns.allSatisfy { $0.startedAt == nil && $0.items.allSatisfy { $0.startedAt == nil } })
        #expect(turns[1].items.map(\.status) == [.completed, .completed])
        #expect(turns[1].items.last?.kind == .assistantMessage(text: "Built.", isFinal: true))
        #expect(TimelineBuilder.foldLabel(for: turns[1]) == "Worked")

        builder.addPrompt("Again", at: now)
        #expect(builder.thread.turns.last?.startedAt == now)
    }

    @Test func noticesWithoutATurnGoBeforeTheFirstOne() {
        var builder = ACPTurnBuilder(cwd: nil, toolStyle: .omp)
        builder.addNotice("Could not reopen", isError: true)
        builder.addPrompt("Hi", at: now)
        builder.addNotice("Context compacted", isError: false, at: now)
        #expect(builder.thread.preamble.map(\.kind) == [.error(message: "Could not reopen")])
        #expect(builder.thread.turns[0].items.map(\.kind) == [.notice(text: "Context compacted")])
    }

    @Test func ompDisplayDiffsBecomeUnifiedHunks() {
        #expect(ACPTurnBuilder.unifiedDiff(" 41|keep\n-42|old\n+42|new\n...\n+90|added") ==
            "@@ -41,2 +41,2 @@\n keep\n-old\n+new\n@@ -89,0 +90,1 @@\n+added")
        #expect(ACPTurnBuilder.unifiedDiff("@@ -1 +1 @@\n-a\n+b") == "@@ -1 +1 @@\n-a\n+b")
        #expect(DiffLineCount.of("@@ -1 +1 @@\n-a\n+b\n+c") == (2, 1))
    }

    @Test func aDiffKeepsThreeLinesOfContextAroundTheChange() throws {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 6", with: "line six")
        let diff = try #require(ACPDiff.unified(old: old, new: new))
        #expect(diff.split(separator: "\n").map(String.init) == [
            "@@ -3,7 +3,7 @@",
            " line 3", " line 4", " line 5",
            "-line 6", "+line six",
            " line 7", " line 8", " line 9",
        ])
        #expect(ACPDiff.unified(old: "same", new: "same") == nil)
        #expect(ACPDiff.unified(old: "", new: "new file\n") == "@@ -1,0 +1,1 @@\n+new file")
    }

    @Test func theTimelineShowsAFinishedTurnsWorkBehindItsFoldAndTheAnswerWithItsFiles() throws {
        var builder = ACPTurnBuilder(cwd: "/r", toolStyle: .omp)
        builder.addPrompt("Fix", at: now)
        builder.apply(try update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"edit","status":"completed","rawInput":{"path":"/r/a.swift"},"rawOutput":{"details":{"diff":"+1|x","path":"/r/a.swift"}}}"#), at: now)
        builder.apply(try update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Fixed."}}"#), at: now)
        builder.finishTurn(stopReason: "end_turn", at: now.addingTimeInterval(52))
        var closed = TimelineExpansion()
        closed.detailed = false
        let rows = TimelineBuilder.rows(for: builder.thread, emptyText: "", expansion: closed)
        #expect(rows.map(\.id).first == "user:\(builder.thread.turns[0].userMessage.id)")
        guard case let .fold(fold) = rows[1].content else { Issue.record("No fold"); return }
        #expect(fold.label == "Worked for 52s")
        guard case let .assistant(answer) = rows[2].content else { Issue.record("No answer"); return }
        #expect(answer.changedFiles?.files == [ChangedFileStat(path: "a.swift", additions: 1, deletions: 0)])
        #expect(rows.count == 3)
        // Open (the detailed default), the edit shows as its file's diff row.
        let open = TimelineBuilder.rows(for: builder.thread, emptyText: "")
        #expect(open.contains { if case .fileDiff = $0.content { true } else { false } })
    }
}
