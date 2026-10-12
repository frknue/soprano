import AppKit
import Testing
@testable import Soprano

struct OmpSessionDecoderTests {
    private let header = #"{"type":"session","version":3,"id":"sess-1","timestamp":"2026-10-12T09:00:00.000Z","cwd":"/work/repo"}"#

    @Test func theSessionHeaderAndRecordsOutsideTheTreeShowNothing() {
        var decoder = OmpSessionDecoder()
        #expect(decoder.entry(forLine: Data(header.utf8)) == nil)
        #expect(decoder.entry(forLine: Data(#"{"type":"title","v":1,"title":"Fix the build","source":"auto"}"#.utf8)) == nil)
        #expect(decoder.entry(forLine: Data(#"{"type":"message","id":"#.utf8)) == nil)
    }

    @Test func toolPathsInsideTheSessionDirectoryAreShownRelativeToIt() throws {
        let timeline = timeline([
            header,
            assistant("a1", parent: nil, content: #"[{"type":"toolCall","id":"call-r","name":"read","arguments":{"path":"/work/repo/Sources/App.swift","i":"Reading app"},"intent":"Reading app"}]"#),
        ])
        let call = try #require(timeline.items.first?.toolCall)
        #expect(call.name == "Read")
        #expect(call.summary == "Sources/App.swift")
        #expect(call.state == .running)
    }

    @Test func typedUserMessagesBecomePromptsWithImagesAsPlaceholders() {
        let timeline = timeline([
            header,
            #"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"What is on this screen?"},{"type":"image","mimeType":"image/png","data":"AAAA"}]}}"#,
        ])
        #expect(timeline.items.map(\.kind) == [.prompt("What is on this screen?\n[image]")])
        #expect(timeline.items.first?.id == "u1")
    }

    @Test func systemRemindersAndAgentInjectedMessagesNeverShowButStayInTheTree() throws {
        var decoder = OmpSessionDecoder()
        _ = decoder.entry(forLine: Data(header.utf8))
        let reminderEntry = decoder.entry(forLine: Data(
            #"{"type":"message","id":"d1","parentId":"u0","timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"developer","attribution":"agent","content":[{"type":"text","text":"<system-reminder>secret</system-reminder>"}]}}"#.utf8
        ))
        let reminder = try #require(reminderEntry)
        #expect(reminder.id == "d1")
        #expect(reminder.parentId == "u0")
        #expect(reminder.items.isEmpty)

        let injectedEntry = decoder.entry(forLine: Data(
            #"{"type":"message","id":"u2","parentId":"d1","timestamp":"2026-10-12T09:00:02.000Z","message":{"role":"user","attribution":"agent","content":[{"type":"text","text":"Continue the plan."}]}}"#.utf8
        ))
        let injected = try #require(injectedEntry)
        #expect(injected.items.isEmpty)

        let modelChangeEntry = decoder.entry(forLine: Data(
            #"{"type":"model_change","id":"m1","parentId":"u2","timestamp":"2026-10-12T09:00:03.000Z","model":"some/model"}"#.utf8
        ))
        let modelChange = try #require(modelChangeEntry)
        #expect(modelChange.id == "m1")
        #expect(modelChange.items.isEmpty)
    }

    @Test func assistantThinkingAndProseShowInOrderWithoutBlankReplies() {
        let timeline = timeline([
            header,
            assistant("a1", parent: nil, content: #"[{"type":"thinking","thinking":"Check the tests first."},{"type":"text","text":"  \n"},{"type":"text","text":"All **green**."}]"#, stopReason: "stop"),
        ])
        #expect(timeline.items.map(\.kind) == [.thinking("Check the tests first."), .reply("All **green**.")])
        #expect(timeline.items.map(\.id) == ["a1#0", "a1#2"])
    }

    @Test func bashCallsShowTheIntentAndFinishWithTheirOutput() throws {
        let timeline = timeline([
            header,
            assistant("a1", parent: nil, content: #"[{"type":"toolCall","id":"call-b","name":"bash","arguments":{"command":"swift build\nswift test","i":"Building package"},"intent":"Building package"}]"#),
            toolResult("r1", parent: "a1", callId: "call-b", tool: "bash", text: "Build complete!", details: #"{"wallTimeMs":1200}"#),
        ])
        let call = try #require(timeline.items.first?.toolCall)
        #expect(call.name == "Bash")
        #expect(call.summary == "Building package")
        #expect(call.detail == "swift build\nswift test")
        #expect(call.state == .succeeded)
        #expect(call.output == "Build complete!")
        #expect(call.finishedAt == AgentTimeline.date(from: "2026-10-12T09:00:05.000Z"))
    }

    @Test func bashCallsWithANonZeroExitCodeShowAsFailed() throws {
        let timeline = timeline([
            header,
            assistant("a1", parent: nil, content: #"[{"type":"toolCall","id":"call-b","name":"bash","arguments":{"command":"false"}}]"#),
            toolResult("r1", parent: "a1", callId: "call-b", tool: "bash", text: "exit 1", details: #"{"exitCode":1}"#),
        ])
        let call = try #require(timeline.items.first?.toolCall)
        #expect(call.summary == "false")
        #expect(call.detail == nil)
        #expect(call.state == .failed)
        #expect(call.output == "exit 1")
    }

    @Test func editResultsShowTheirNumberedDiffAsAUnifiedDiffNamedAfterTheFile() throws {
        let diff = #" 11|let a = 1\n-12|let b = 2\n+12|let b = 3\n\n 40|}\n+41|// done"#
        let timeline = timeline([
            header,
            assistant("a1", parent: nil, content: #"[{"type":"toolCall","id":"call-e","name":"edit","arguments":{"input":"…","i":"Bumping b"},"intent":"Bumping b"}]"#),
            toolResult("r1", parent: "a1", callId: "call-e", tool: "edit", text: "Updated Sources/App.swift", details: #"{"diff":"\#(diff)","path":"/work/repo/Sources/App.swift","firstChangedLine":12}"#),
        ])
        let call = try #require(timeline.items.first?.toolCall)
        #expect(call.name == "Edit")
        #expect(call.summary == "Sources/App.swift")
        #expect(call.diff == " let a = 1\n-let b = 2\n+let b = 3\n@@\n }\n+// done")
        #expect(call.output == nil)
        #expect(call.state == .succeeded)
    }

    @Test func compactionShowsAsANotice() {
        let timeline = timeline([
            header,
            #"{"type":"compaction","id":"c1","parentId":null,"timestamp":"2026-10-12T09:10:00.000Z","summary":"long summary","tokensBefore":100000}"#,
        ])
        #expect(timeline.items.map(\.kind) == [.notice("Context compacted", isError: false)])
    }

    @Test func abortedAndFailedTurnsEndWithANotice() {
        let timeline = timeline([
            header,
            assistant("a1", parent: nil, content: #"[{"type":"text","text":"Starting"}]"#, stopReason: "aborted"),
            assistant("a2", parent: "a1", content: #"[]"#, stopReason: "error", extra: #","errorMessage":"Overloaded""#),
        ])
        #expect(timeline.items.map(\.kind) == [
            .reply("Starting"),
            .notice("Interrupted", isError: false),
            .notice("Overloaded", isError: true),
        ])
    }

    @Test func rewindingKeepsOnlyTheNewerBranchVisible() {
        let timeline = timeline([
            header,
            #"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Plan the change"}]}}"#,
            assistant("a1", parent: "u1", content: #"[{"type":"text","text":"Here is a plan."}]"#, stopReason: "stop"),
            #"{"type":"message","id":"u2","parentId":"a1","timestamp":"2026-10-12T09:00:06.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Old direction"}]}}"#,
            assistant("a2", parent: "u2", content: #"[{"type":"text","text":"Going the old way."}]"#, stopReason: "stop"),
            #"{"type":"message","id":"u3","parentId":"a1","timestamp":"2026-10-12T09:01:00.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"New direction"}]}}"#,
            #"{"type":"title_change","id":"t1","parentId":"u3","timestamp":"2026-10-12T09:01:01.000Z","title":"New"}"#,
        ])
        #expect(timeline.items.map(\.kind) == [
            .prompt("Plan the change"),
            .reply("Here is a plan."),
            .prompt("New direction"),
        ])
    }

    private func timeline(_ lines: [String]) -> AgentTimeline {
        var decoder = OmpSessionDecoder()
        return AgentTimeline(entries: lines.compactMap { decoder.entry(forLine: Data($0.utf8)) })
    }

    private func assistant(
        _ id: String, parent: String?, content: String, stopReason: String = "toolUse", extra: String = ""
    ) -> String {
        let parentId = parent.map { #""\#($0)""# } ?? "null"
        return #"{"type":"message","id":"\#(id)","parentId":\#(parentId),"timestamp":"2026-10-12T09:00:02.000Z","message":{"role":"assistant","content":\#(content),"stopReason":"\#(stopReason)"\#(extra)}}"#
    }

    private func toolResult(
        _ id: String, parent: String, callId: String, tool: String, text: String, details: String
    ) -> String {
        #"{"type":"message","id":"\#(id)","parentId":"\#(parent)","timestamp":"2026-10-12T09:00:05.000Z","message":{"role":"toolResult","toolCallId":"\#(callId)","toolName":"\#(tool)","content":[{"type":"text","text":"\#(text)"}],"details":\#(details),"isError":false}}"#
    }
}
