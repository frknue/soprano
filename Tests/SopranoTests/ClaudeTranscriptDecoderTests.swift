import AppKit
import Testing
@testable import Soprano

struct ClaudeTranscriptDecoderTests {
    @Test func typedPromptsSlashCommandsAndBashModeShowAsWhatThePersonEntered() {
        let timeline = timeline([
            #"{"type":"user","uuid":"u1","parentUuid":null,"cwd":"/tmp/repo","timestamp":"2026-10-12T09:00:00.000Z","message":{"role":"user","content":"  Fix the login bug\n"}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"u1","timestamp":"2026-10-12T09:01:00.000Z","message":{"role":"user","content":"<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>src/app tests</command-args>"}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"u2","timestamp":"2026-10-12T09:02:00.000Z","message":{"role":"user","content":"<local-command-stdout>Reviewed</local-command-stdout>"}}"#,
            #"{"type":"user","uuid":"u4","parentUuid":"u3","timestamp":"2026-10-12T09:03:00.000Z","message":{"role":"user","content":"<bash-input>git status</bash-input>"}}"#,
            #"{"type":"user","uuid":"u5","parentUuid":"u4","timestamp":"2026-10-12T09:03:01.000Z","message":{"role":"user","content":"<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>"}}"#,
        ])

        #expect(timeline.items.map(\.kind) == [
            .prompt("Fix the login bug"),
            .prompt("/review src/app tests"),
            .prompt("! git status"),
        ])
        #expect(timeline.items.first?.timestamp == AgentTimeline.date(from: "2026-10-12T09:00:00.000Z"))
    }

    @Test func metaRecordsStayHiddenButKeepTheBranchConnected() {
        let timeline = timeline([
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Hello"}}"#,
            #"{"type":"user","uuid":"m1","parentUuid":"u1","isMeta":true,"message":{"role":"user","content":"Injected skill instructions"}}"#,
            #"{"type":"attachment","uuid":"a1","parentUuid":"m1","attachment":{"type":"todo"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Hi there"}]}}"#,
        ])

        #expect(timeline.items.map(\.kind) == [.prompt("Hello"), .reply("Hi there")])
    }

    @Test func sidechainAndSessionBookkeepingRecordsAreNotPartOfTheTimeline() {
        var decoder = ClaudeTranscriptDecoder()
        let sidechain = #"{"type":"assistant","uuid":"s1","parentUuid":"u1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"Subagent says hi"}]}}"#
        let title = #"{"type":"ai-title","sessionId":"abc","aiTitle":"Fix login"}"#
        let summary = #"{"type":"summary","summary":"Earlier work","leafUuid":"u1"}"#

        #expect(decoder.entry(forLine: Data(sidechain.utf8)) == nil)
        #expect(decoder.entry(forLine: Data(title.utf8)) == nil)
        #expect(decoder.entry(forLine: Data(summary.utf8)) == nil)
        #expect(decoder.entry(forLine: Data("not json".utf8)) == nil)
    }

    @Test func thinkingAndRepliesShowInOrderWithEmptyTextSkipped() {
        let timeline = timeline([
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Why?"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Considering the cause","signature":"x"}]}}"#,
            #"{"type":"assistant","uuid":"r2","parentUuid":"r1","message":{"role":"assistant","content":[{"type":"redacted_thinking","data":"opaque"}]}}"#,
            #"{"type":"assistant","uuid":"r3","parentUuid":"r2","message":{"role":"assistant","content":[{"type":"text","text":"\n\n"},{"type":"text","text":"Because **cache**."}]}}"#,
        ])

        #expect(timeline.items.map(\.kind) == [
            .prompt("Why?"),
            .thinking("Considering the cause"),
            .thinking(""),
            .reply("Because **cache**."),
        ])
    }

    @Test func toolCallsShowTheirSubjectAndFinishWithTheirResult() throws {
        let timeline = timeline([
            #"{"type":"user","uuid":"u1","parentUuid":null,"cwd":"/tmp/repo","message":{"role":"user","content":"Look around"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/repo/Sources/App.swift"}}]}}"#,
            #"{"type":"assistant","uuid":"r2","parentUuid":"r1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"TODO","path":"/tmp/repo/Sources"}}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"r2","timestamp":"2026-10-12T09:05:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"1\tlet app = App()"}]}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"Path does not exist"}]}]}}"#,
        ])

        let read = try #require(timeline.items[1].toolCall)
        #expect(read.name == "Read")
        #expect(read.summary == "Sources/App.swift")
        #expect(read.state == .succeeded)
        #expect(read.output == "1\tlet app = App()")
        #expect(read.finishedAt == AgentTimeline.date(from: "2026-10-12T09:05:00.000Z"))

        let grep = try #require(timeline.items[2].toolCall)
        #expect(grep.summary == "TODO in Sources")
        #expect(grep.state == .failed)
        #expect(grep.output == "Path does not exist")
        #expect(timeline.items.count == 3)
    }

    @Test func mcpToolsShowServerAndToolAndTheirMostTellingArgument() throws {
        let timeline = timeline([
            #"{"type":"assistant","uuid":"r1","parentUuid":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__chrome-devtools__navigate_page","input":{"type":"url","url":"https://example.com"}}]}}"#,
        ])

        let call = try #require(timeline.items.first?.toolCall)
        #expect(call.name == "chrome-devtools · navigate_page")
        #expect(call.summary == "https://example.com")
        #expect(call.state == .running)
    }

    @Test func editResultsShowTheirStructuredPatchAsADiff() throws {
        let timeline = timeline([
            #"{"type":"assistant","uuid":"r1","parentUuid":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/repo/a.swift","old_string":"old","new_string":"new"}}]}}"#,
            #"{"type":"user","uuid":"u1","parentUuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"The file /tmp/repo/a.swift has been updated."}]},"toolUseResult":{"filePath":"/tmp/repo/a.swift","oldString":"old","newString":"new","structuredPatch":[{"oldStart":3,"oldLines":2,"newStart":3,"newLines":2,"lines":[" let x = 1","-old","+new"]}]}}"#,
        ])

        let call = try #require(timeline.items.first?.toolCall)
        #expect(call.state == .succeeded)
        #expect(call.diff == "@@ -3,2 +3,2 @@\n let x = 1\n-old\n+new")
        #expect(call.output == nil)
    }

    @Test func createdFilesShowEveryLineAsAnAddition() throws {
        let timeline = timeline([
            #"{"type":"assistant","uuid":"r1","parentUuid":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/repo/notes.txt","content":"one\ntwo\n"}}]}}"#,
            #"{"type":"user","uuid":"u1","parentUuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"File created successfully"}]},"toolUseResult":{"type":"create","filePath":"/tmp/repo/notes.txt","content":"one\ntwo\n","structuredPatch":[],"originalFile":null}}"#,
        ])

        let call = try #require(timeline.items.first?.toolCall)
        #expect(call.summary == "/tmp/repo/notes.txt")
        #expect(call.diff == "+one\n+two")
        #expect(call.output == nil)
    }

    @Test func bashResultsShowBothStreamsAndAnInterruptedCommandSaysSo() throws {
        let timeline = timeline([
            #"{"type":"user","uuid":"u0","parentUuid":null,"cwd":"/tmp/repo","message":{"role":"user","content":"Run checks"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"u0","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make test","description":"Run the test suite"}}]}}"#,
            #"{"type":"user","uuid":"u1","parentUuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ignored"}]},"toolUseResult":{"stdout":"3 passed","stderr":"1 warning","interrupted":false,"isImage":false}}"#,
            #"{"type":"assistant","uuid":"r2","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"sleep 100"}}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"r2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ignored"}]},"toolUseResult":{"stdout":"","stderr":"","interrupted":true,"isImage":false}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"u2","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        ])

        let tests = try #require(timeline.items[1].toolCall)
        #expect(tests.summary == "Run the test suite")
        #expect(tests.detail == "make test")
        #expect(tests.output == "3 passed\n1 warning")
        #expect(tests.state == .succeeded)

        let sleep = try #require(timeline.items[2].toolCall)
        #expect(sleep.summary == "sleep 100")
        #expect(sleep.detail == nil)
        #expect(sleep.state == .interrupted)
        #expect(timeline.items.last?.kind == .notice("Interrupted", isError: false))
    }

    @Test func compactionShowsANoticeAndKeepsTheHistoryBeforeIt() {
        let timeline = timeline([
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Long task"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"Working on it"}]}}"#,
            #"{"type":"system","subtype":"compact_boundary","uuid":"c1","parentUuid":null,"logicalParentUuid":"r1","content":"Conversation compacted","level":"info","compactMetadata":{"trigger":"auto"}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"c1","isMeta":true,"message":{"role":"user","content":"Summary of the earlier conversation"}}"#,
            #"{"type":"assistant","uuid":"r2","parentUuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"Continuing"}]}}"#,
        ])

        #expect(timeline.items.map(\.kind) == [
            .prompt("Long task"),
            .reply("Working on it"),
            .notice("Conversation compacted", isError: false),
            .reply("Continuing"),
        ])
    }

    @Test func apiErrorsAndLocalCommandsShowAsNotices() {
        let timeline = timeline([
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Hi"}}"#,
            #"{"type":"assistant","uuid":"e1","parentUuid":"u1","isApiErrorMessage":true,"error":"server_error","message":{"role":"assistant","content":[{"type":"text","text":"API Error: overloaded"}]}}"#,
            #"{"type":"system","subtype":"local_command","uuid":"s1","parentUuid":"e1","level":"info","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"}"#,
            #"{"type":"system","subtype":"turn_duration","uuid":"s2","parentUuid":"s1","durationMs":1200}"#,
        ])

        #expect(timeline.items.map(\.kind) == [
            .prompt("Hi"),
            .notice("API Error: overloaded", isError: true),
            .notice("/model", isError: false),
        ])
    }

    @Test func rewindingShowsOnlyTheNewerBranch() {
        let timeline = timeline([
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Start"}}"#,
            #"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"Ready"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"r1","message":{"role":"user","content":"Try plan A"}}"#,
            #"{"type":"assistant","uuid":"r2","parentUuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"Plan A done"}]}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"r1","message":{"role":"user","content":"Try plan B instead"}}"#,
            #"{"type":"assistant","uuid":"r3","parentUuid":"u3","message":{"role":"assistant","content":[{"type":"text","text":"Plan B done"}]}}"#,
            #"{"type":"last-prompt","lastPrompt":"Try plan B instead"}"#,
        ])

        #expect(timeline.items.map(\.kind) == [
            .prompt("Start"),
            .reply("Ready"),
            .prompt("Try plan B instead"),
            .reply("Plan B done"),
        ])
    }

    private func timeline(_ lines: [String]) -> AgentTimeline {
        var decoder = ClaudeTranscriptDecoder()
        return AgentTimeline(entries: lines.compactMap { decoder.entry(forLine: Data($0.utf8)) })
    }
}
