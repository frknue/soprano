import AppKit
import Testing
@testable import Soprano

struct CodexRolloutDecoderTests {
    private let meta = #"{"timestamp":"2026-10-12T09:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/work/app"}}"#

    private func decode(_ lines: [String]) -> [AgentTranscriptEntry] {
        var decoder = CodexRolloutDecoder()
        return lines.compactMap { decoder.entry(forLine: Data($0.utf8)) }
    }

    private func items(_ lines: [String]) -> [AgentTimelineItem] {
        AgentTimeline(entries: decode([meta] + lines)).items
    }

    private func completed(_ item: String) -> String {
        #"{"timestamp":"2026-10-12T09:00:05.000Z","type":"event_msg","payload":{"type":"item_completed","item":"# + item + "}}"
    }

    @Test func userMessagesBecomePromptsWithImagesShownAsPlaceholders() {
        let result = items([completed(#"{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Fix the login bug"},{"type":"image","image_url":"data:x"}]}"#)])
        #expect(result.map(\.kind) == [.prompt("Fix the login bug\n[image]")])
        #expect(result.first?.id == "u1")
        #expect(result.first?.timestamp != nil)
    }

    @Test func agentMessagesOfEveryPhaseBecomeReplies() {
        let result = items([
            completed(#"{"type":"AgentMessage","id":"a1","phase":"commentary","content":[{"type":"Text","text":"Looking around."}]}"#),
            completed(#"{"type":"AgentMessage","id":"a2","phase":"final_answer","content":[{"type":"Text","text":"**Done.**"}]}"#),
        ])
        #expect(result.map(\.kind) == [.reply("Looking around."), .reply("**Done.**")])
    }

    @Test func reasoningShowsItsSummaryAndIsHiddenWhenThereIsNone() {
        let result = items([
            completed(#"{"type":"Reasoning","id":"r1","summary_text":["Checking the router"],"raw_content":[]}"#),
            completed(#"{"type":"Reasoning","id":"r2","summary_text":[],"raw_content":[]}"#),
        ])
        #expect(result.map(\.kind) == [.thinking("Checking the router")])
    }

    @Test func aCommandThatExitsWithZeroSucceedsAndShowsItsOutput() {
        let result = items([completed(#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","swift build"],"parsed_cmd":[{"type":"unknown","cmd":"swift build"}],"status":"completed","exit_code":0,"aggregated_output":"Build complete!\n","duration":{"secs":3,"nanos":0}}"#)])
        let call = result.first?.toolCall
        #expect(call?.name == "Run")
        #expect(call?.summary == "swift build")
        #expect(call?.detail == nil)
        #expect(call?.state == .succeeded)
        #expect(call?.output == "Build complete!")
    }

    @Test func aCommandWithANonZeroExitCodeIsShownAsFailed() {
        let result = items([completed(#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","make test"],"parsed_cmd":[{"type":"unknown","cmd":"make test"}],"status":"failed","exit_code":2,"aggregated_output":"error: boom"}"#)])
        #expect(result.first?.toolCall?.state == .failed)
        #expect(result.first?.toolCall?.output == "error: boom")
    }

    @Test func readingAFileIsNamedReadWithThePathRelativeToTheSession() {
        let result = items([completed(#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","sed -n '1,80p' Sources/main.swift"],"parsed_cmd":[{"type":"read","cmd":"sed -n '1,80p' Sources/main.swift","name":"main.swift","path":"/work/app/Sources/main.swift"}],"status":"completed","exit_code":0,"aggregated_output":"import AppKit"}"#)])
        let call = result.first?.toolCall
        #expect(call?.name == "Read")
        #expect(call?.summary == "Sources/main.swift")
        #expect(call?.detail == "sed -n '1,80p' Sources/main.swift")
    }

    @Test func fileChangesShowTheirDiffsWithAddedFilesAsPlusLines() {
        let single = items([completed(#"{"type":"FileChange","id":"f1","status":"completed","changes":{"/work/app/a.swift":{"type":"update","unified_diff":"@@ -1 +1 @@\n-old\n+new\n","move_path":null}}}"#)])
        #expect(single.first?.toolCall?.name == "Edit")
        #expect(single.first?.toolCall?.summary == "a.swift")
        #expect(single.first?.toolCall?.diff == "@@ -1 +1 @@\n-old\n+new")

        let several = items([completed(#"{"type":"FileChange","id":"f2","status":"completed","changes":{"/work/app/a.swift":{"type":"update","unified_diff":"@@ -1 +1 @@\n-x\n+y"},"/work/app/b.swift":{"type":"add","content":"one\ntwo\n"}}}"#)])
        let call = several.first?.toolCall
        #expect(call?.name == "Edit")
        #expect(call?.summary == "a.swift +1 more")
        #expect(call?.diff == "diff a.swift\n@@ -1 +1 @@\n-x\n+y\ndiff b.swift\n+one\n+two")

        let added = items([completed(#"{"type":"FileChange","id":"f3","status":"completed","changes":{"/work/app/new.swift":{"type":"add","content":"hello\n"}}}"#)])
        #expect(added.first?.toolCall?.name == "Add")
        #expect(added.first?.toolCall?.diff == "+hello")
    }

    @Test func mcpCallsAreNamedByServerAndToolAndShowTheirTextResult() {
        let result = items([completed(#"{"type":"McpToolCall","id":"m1","server":"github","tool":"search_issues","arguments":{"query":"crash on launch","limit":5},"status":"completed","result":{"content":[{"type":"text","text":"3 issues"}],"isError":false}}"#)])
        let call = result.first?.toolCall
        #expect(call?.name == "github.search_issues")
        #expect(call?.summary == "crash on launch")
        #expect(call?.state == .succeeded)
        #expect(call?.output == "3 issues")
    }

    @Test func webSearchesShowTheirQuery() {
        let result = items([completed(#"{"type":"Extension","id":"w1","kind":"web.search","query":"swift testing traits","action":{"type":"search","query":"swift testing traits"},"results":[]}"#)])
        #expect(result.first?.toolCall?.name == "WebSearch")
        #expect(result.first?.toolCall?.summary == "swift testing traits")
        #expect(result.first?.toolCall?.state == .succeeded)
    }

    @Test func compactionAndAbortedTurnsBecomeNotices() {
        let result = items([
            completed(#"{"type":"ContextCompaction","id":"k1"}"#),
            #"{"timestamp":"2026-10-12T09:00:06.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t9","reason":"interrupted"}}"#,
        ])
        #expect(result.map(\.kind) == [.notice("Context compacted", isError: false), .notice("Interrupted", isError: false)])
        #expect(result.last?.id == "aborted-t9")
    }

    @Test func responseItemMessagesNeverShowBecauseTheyCarryInjectedInstructions() {
        let result = items([
            #"{"timestamp":"2026-10-12T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are a coding agent"}]}}"#,
            ##"{"timestamp":"2026-10-12T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
            #"{"timestamp":"2026-10-12T09:00:01.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"x"}}"#,
        ])
        #expect(result.isEmpty)
    }

    @Test func malformedLinesAreIgnored() {
        var decoder = CodexRolloutDecoder()
        #expect(decoder.entry(forLine: Data("{not json".utf8)) == nil)
        #expect(decoder.entry(forLine: Data(#"{"type":"event_msg"}"#.utf8)) == nil)
    }

    @Test func aRunningExecCallShowsItsCommandUntilTheFinishedCommandReplacesIt() {
        let call = #"{"timestamp":"2026-10-12T09:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call_1","input":"const r = await tools.exec_command({cmd: \"git status\\n\", workdir: \"/work/app\"});\ntext(r);"}}"#
        let running = items([call])
        #expect(running.count == 1)
        #expect(running.first?.toolCall?.name == "Run")
        #expect(running.first?.toolCall?.summary == "git status")
        #expect(running.first?.toolCall?.state == .running)

        let finished = items([
            call,
            #"{"timestamp":"2026-10-12T09:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_1","output":"ok"}}"#,
            completed(#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","git status"],"parsed_cmd":[{"type":"unknown","cmd":"git status"}],"status":"completed","exit_code":0,"aggregated_output":"clean"}"#),
        ])
        #expect(finished.count == 1)
        #expect(finished.first?.id == "c1")
        #expect(finished.first?.toolCall?.state == .succeeded)
    }
}
