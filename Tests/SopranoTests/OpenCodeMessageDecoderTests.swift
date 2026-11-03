import AppKit
import Testing
@testable import Soprano

struct OpenCodeMessageDecoderTests {
    private let decoder = OpenCodeMessageDecoder(cwd: "/work/repo")

    // MARK: - OpenCode 2.x

    @Test func typedPromptsShowTheirTextWithAttachmentsAsPlaceholders() {
        let entry = decoder.entry(id: "msg_u1", type: "user", data: json(#"""
            {"text":"What is on this screen?","files":[{"mime":"image/png","uri":"data:,"},{"name":"notes.txt","mime":"text/plain","uri":"file:///tmp/notes.txt"}],"time":{"created":1792367293828}}
            """#))
        #expect(entry.items.map(\.kind) == [.prompt("What is on this screen?\n[image]\n[file notes.txt]")])
        #expect(entry.items.first?.id == "msg_u1")
        #expect(entry.items.first?.timestamp == Date(timeIntervalSince1970: 1_792_367_293.828))
    }

    @Test func assistantReasoningProseAndToolsShowInOrderWithoutBlankReplies() {
        let entry = decoder.entry(id: "msg_a1", type: "assistant", data: json(#"""
            {"agent":"build","model":{"providerID":"openai","id":"gpt"},"time":{"created":1000},"content":[
              {"type":"reasoning","text":""},
              {"type":"text","text":"  \n"},
              {"type":"text","text":"Checking the **build**."},
              {"type":"tool","id":"call_1","name":"read","state":{"status":"running","input":{"path":"/work/repo/Sources/App.swift"},"metadata":{}},"time":{"created":1001}}
            ]}
            """#))
        #expect(entry.items.map(\.id) == ["msg_a1#0", "msg_a1#2", "call_1"])
        #expect(entry.items.map(\.kind) == [
            .thinking(""),
            .reply("Checking the **build**."),
            .tool(AgentToolCall(name: "Read", summary: "Sources/App.swift")),
        ])
    }

    @Test func shellToolsShowTheCommandAndFinishWithTheirOutputOrExitCode() throws {
        let entry = decoder.entry(id: "msg_a1", type: "assistant", data: json(#"""
            {"time":{"created":1000},"content":[
              {"type":"tool","id":"call_ok","name":"shell","state":{"status":"completed","input":{"command":"swift build\nswift test"},"content":[{"type":"text","text":"Build complete!"}],"metadata":{"exit":0}},"time":{"created":1001,"completed":3000}},
              {"type":"tool","id":"call_exit","name":"bash","state":{"status":"completed","input":{"command":"false","description":"Fails"},"content":[{"type":"text","text":"exit 1"}],"metadata":{"exit":1}},"time":{"created":1001,"completed":3000}},
              {"type":"tool","id":"call_err","name":"shell","state":{"status":"error","input":{"command":"sleep 99"},"error":{"type":"tool.error","message":"Timed out"}},"time":{"created":1001,"completed":3000}},
              {"type":"tool","id":"call_stream","name":"shell","state":{"status":"streaming","input":"{\"comm"},"time":{"created":1001}}
            ]}
            """#))
        let calls = entry.items.compactMap(\.toolCall)
        try #require(calls.count == 4)
        #expect(calls[0] == AgentToolCall(
            name: "Bash", summary: "swift build", detail: "swift build\nswift test", state: .succeeded,
            output: "Build complete!", finishedAt: Date(timeIntervalSince1970: 3)
        ))
        #expect(calls[1].summary == "false")
        #expect(calls[1].state == .failed)
        #expect(calls[2].state == .failed)
        #expect(calls[2].output == "Timed out")
        #expect(calls[3].state == .running)
        #expect(calls[3].summary == "")
    }

    @Test func toolsAreNamedAndSummarizedLikeTheOtherAgents() {
        let entry = decoder.entry(id: "msg_a1", type: "assistant", data: json(#"""
            {"time":{"created":1000},"content":[
              {"type":"tool","id":"c1","name":"glob","state":{"status":"running","input":{"pattern":"**/*.swift","path":"Sources"},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c2","name":"grep","state":{"status":"running","input":{"pattern":"TODO"},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c3","name":"webfetch","state":{"status":"running","input":{"url":"https://opencode.ai/docs"},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c4","name":"websearch","state":{"status":"running","input":{"query":"swift testing"},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c5","name":"subagent","state":{"status":"running","input":{"agent":"explore","description":"Map the store","prompt":"…"},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c6","name":"todowrite","state":{"status":"running","input":{"todos":[{},{},{}]},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c7","name":"question","state":{"status":"running","input":{"questions":[{"question":"Which branch?\nPick one."}]},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c8","name":"skill","state":{"status":"running","input":{"id":"customize-opencode"},"metadata":{}},"time":{"created":1}},
              {"type":"tool","id":"c9","name":"context7_query-docs","state":{"status":"running","input":{"libraryId":"/upstash/context7","query":"API key from env"},"metadata":{}},"time":{"created":1}}
            ]}
            """#))
        let calls = entry.items.compactMap(\.toolCall).map { "\($0.name): \($0.summary)" }
        #expect(calls == [
            "Glob: **/*.swift in Sources",
            "Grep: TODO",
            "WebFetch: https://opencode.ai/docs",
            "WebSearch: swift testing",
            "Task: Map the store",
            "Todo: 3 todos",
            "Ask: Which branch?",
            "Skill: customize-opencode",
            "context7_query-docs: API key from env",
        ])
    }

    @Test func editsShowOnlyTheHunkLinesOfTheirDiffNamedAfterTheFile() throws {
        let patch = [
            "Index: /work/repo/Sources/App.swift",
            "===================================================================",
            "--- /work/repo/Sources/App.swift\t",
            "+++ /work/repo/Sources/App.swift\t",
            "@@ -1,3 +1,3 @@",
            " let a = 1",
            "--- a comment that starts with two dashes",
            "+let b = 3",
            " }",
            "\\ No newline at end of file",
        ].joined(separator: "\n")
        let entry = decoder.entry(id: "msg_a1", type: "assistant", data: object([
            "time": ["created": 1000],
            "content": [[
                "type": "tool", "id": "call_e", "name": "edit",
                "state": [
                    "status": "completed",
                    "input": ["path": "/work/repo/Sources/App.swift", "oldString": "x", "newString": "y"],
                    "content": [["type": "text", "text": "Edited Sources/App.swift (1 replacement)"]],
                    "metadata": ["files": [["file": "/work/repo/Sources/App.swift", "patch": patch, "status": "modified"]]],
                ],
                "time": ["created": 1001, "completed": 1002],
            ]],
        ]))
        let call = try #require(entry.items.first?.toolCall)
        #expect(call.name == "Edit")
        #expect(call.summary == "Sources/App.swift")
        #expect(call.diff == "@@ -1,3 +1,3 @@\n let a = 1\n--- a comment that starts with two dashes\n+let b = 3\n }")
        #expect(call.output == nil)
        #expect(call.state == .succeeded)
    }

    @Test func patchesThatChangeSeveralFilesLabelEachFilesHunks() throws {
        func filePatch(_ path: String, _ line: String) -> String {
            "Index: \(path)\n===\n--- \(path)\n+++ \(path)\n@@ -0,0 +1,1 @@\n+\(line)\n"
        }
        let entry = decoder.entry(id: "msg_a1", type: "assistant", data: object([
            "time": ["created": 1000],
            "content": [[
                "type": "tool", "id": "call_p", "name": "apply_patch",
                "state": [
                    "status": "completed",
                    "input": ["patchText": "*** Begin Patch\n*** Add File: /work/repo/a.txt\n+one\n*** Add File: /work/repo/b.txt\n+two\n*** End Patch"],
                    "content": [["type": "text", "text": "Success"]],
                    "metadata": ["files": [
                        ["filePath": "/work/repo/a.txt", "patch": filePatch("/work/repo/a.txt", "one")],
                        ["filePath": "/work/repo/b.txt", "patch": filePatch("/work/repo/b.txt", "two")],
                    ]],
                ],
                "time": ["created": 1001, "completed": 1002],
            ]],
        ]))
        let call = try #require(entry.items.first?.toolCall)
        #expect(call.summary == "a.txt, b.txt")
        #expect(call.diff == "diff a.txt\n@@ -0,0 +1,1 @@\n+one\ndiff b.txt\n@@ -0,0 +1,1 @@\n+two")
    }

    @Test func aRunningPatchNamesTheFirstFileOfItsEnvelope() throws {
        let entry = decoder.entry(id: "msg_a1", type: "assistant", data: object([
            "time": ["created": 1000],
            "content": [[
                "type": "tool", "id": "call_p", "name": "patch",
                "state": ["status": "running", "input": ["patchText": "*** Begin Patch\n*** Update File: /work/repo/a.txt\n@@\n-one\n+two\n*** End Patch"], "metadata": [:]],
                "time": ["created": 1001],
            ]],
        ]))
        let call = try #require(entry.items.first?.toolCall)
        #expect(call.summary == "a.txt")
        #expect(call.state == .running)
    }

    @Test func partRowsReplaceAnAssistantMessagesInlineContent() {
        let entry = decoder.entry(
            id: "msg_a1",
            type: "assistant",
            data: json(#"{"time":{"created":1000},"content":[{"type":"text","text":"stale inline"}]}"#),
            parts: [
                .init(type: "reasoning", data: json(#"{"text":"Plan first."}"#)),
                .init(type: "text", data: json(#"{"text":"Done."}"#)),
            ]
        )
        #expect(entry.items.map(\.kind) == [.thinking("Plan first."), .reply("Done.")])
    }

    @Test func turnEndingsCompactionAndFailuresShowAsNotices() {
        let interrupted = decoder.entry(id: "msg_i", type: "idle", data: json(#"{"outcome":"interrupted","time":{"created":1}}"#))
        let failed = decoder.entry(id: "msg_f", type: "idle", data: json(#"{"outcome":"failed","error":{"type":"provider.error","message":"Quota exceeded"},"time":{"created":1}}"#))
        let succeeded = decoder.entry(id: "msg_s", type: "idle", data: json(#"{"outcome":"succeeded","time":{"created":1}}"#))
        let compaction = decoder.entry(id: "msg_c", type: "compaction", data: json(#"{"status":"running","reason":"auto","summary":"","time":{"created":1}}"#))
        let error = decoder.entry(id: "msg_e", type: "assistant", data: json(#"{"content":[],"error":{"type":"provider.error","message":"Overloaded"},"time":{"created":1}}"#))
        let aborted = decoder.entry(id: "msg_ab", type: "assistant", data: json(#"{"content":[],"error":{"type":"aborted","message":"Step interrupted"},"finish":"error","time":{"created":1}}"#))

        #expect(interrupted.items.map(\.kind) == [.notice("Interrupted", isError: false)])
        #expect(failed.items.map(\.kind) == [.notice("Quota exceeded", isError: true)])
        #expect(succeeded.items.isEmpty)
        #expect(compaction.items.map(\.kind) == [.notice("Context compacted", isError: false)])
        #expect(compaction.items.first?.id == "msg_c")
        #expect(error.items.map(\.kind) == [.notice("Overloaded", isError: true)])
        #expect(aborted.items.map(\.kind) == [.notice("Interrupted", isError: false)])
    }

    @Test func injectedMessagesAndSwitchesShowNothing() {
        for type in ["system", "synthetic", "skill", "agent-switched", "model-switched", "location-switched"] {
            let entry = decoder.entry(id: "msg_x", type: type, data: json(#"{"text":"The available tools have changed.","time":{"created":1}}"#))
            #expect(entry.items.isEmpty)
        }
    }

    @Test func shellCommandsThePersonRanShowAsShellCalls() throws {
        let entry = decoder.entry(id: "msg_sh", type: "shell", data: json(#"""
            {"shellID":"sh_1","command":"ls -la","status":"exited","exit":2,"output":"ls: nope","time":{"created":1000,"completed":2000}}
            """#))
        let call = try #require(entry.items.first?.toolCall)
        #expect(entry.items.first?.id == "msg_sh")
        #expect(call == AgentToolCall(
            name: "Shell", summary: "ls -la", state: .failed, output: "ls: nope",
            finishedAt: Date(timeIntervalSince1970: 2)
        ))
    }

    // MARK: - OpenCode 1.x

    @Test func legacyUserMessagesJoinTheirTypedTextAndSkipSyntheticParts() {
        let entry = decoder.legacyEntry(
            id: "msg_u1",
            data: json(#"{"role":"user","time":{"created":1000}}"#),
            parts: [
                json(#"{"type":"text","text":"Summarize this file"}"#),
                json(#"{"type":"text","text":"<file contents>","synthetic":true}"#),
                json(#"{"type":"file","mime":"text/plain","filename":"notes.txt","url":"file:///tmp/notes.txt"}"#),
            ]
        )
        #expect(entry.items.map(\.kind) == [.prompt("Summarize this file\n[file notes.txt]")])
        #expect(entry.items.first?.id == "msg_u1")
    }

    @Test func legacyAssistantPartsBecomeThinkingRepliesAndToolCalls() throws {
        let entry = decoder.legacyEntry(
            id: "msg_a1",
            data: json(#"{"role":"assistant","time":{"created":1000}}"#),
            parts: [
                json(#"{"type":"step-start"}"#),
                json(#"{"type":"reasoning","text":"Look first."}"#),
                json(#"{"type":"text","text":"Running the tests."}"#),
                json(#"{"type":"tool","tool":"bash","callID":"call_b","state":{"status":"completed","input":{"command":"swift test","description":"Runs tests"},"output":"All passed","metadata":{"exit":0},"time":{"start":1001,"end":4000}}}"#),
                json(#"{"type":"tool","tool":"read","callID":"call_r","state":{"status":"error","input":{"filePath":"/work/repo/Missing.swift"},"error":"File not found","time":{"start":1001,"end":1002}}}"#),
                json(#"{"type":"step-finish"}"#),
            ]
        )
        #expect(entry.items.map(\.id) == ["msg_a1#1", "msg_a1#2", "call_b", "call_r"])
        #expect(entry.items[0].kind == .thinking("Look first."))
        #expect(entry.items[1].kind == .reply("Running the tests."))
        let bash = try #require(entry.items[2].toolCall)
        #expect(bash == AgentToolCall(
            name: "Bash", summary: "swift test", state: .succeeded, output: "All passed",
            finishedAt: Date(timeIntervalSince1970: 4)
        ))
        let read = try #require(entry.items[3].toolCall)
        #expect(read.summary == "Missing.swift")
        #expect(read.state == .failed)
        #expect(read.output == "File not found")
    }

    @Test func legacyDiffsCoveringSeveralFilesAreSplitPerFile() throws {
        let diff = [
            "Index: /work/repo/a.txt", "===", "--- /work/repo/a.txt", "+++ /work/repo/a.txt",
            "@@ -1 +1 @@", "-old", "+new",
            "Index: /work/repo/b.txt", "===", "--- /work/repo/b.txt", "+++ /work/repo/b.txt",
            "@@ -1,2 +1,2 @@", " keep", "-gone", "+here",
        ].joined(separator: "\n")
        let entry = decoder.legacyEntry(
            id: "msg_a1",
            data: json(#"{"role":"assistant","time":{"created":1000}}"#),
            parts: [object([
                "type": "tool", "tool": "apply_patch", "callID": "call_p",
                "state": [
                    "status": "completed", "input": ["patchText": "…"], "output": "Success",
                    "metadata": ["diff": diff], "time": ["start": 1001, "end": 1002],
                ],
            ])]
        )
        let call = try #require(entry.items.first?.toolCall)
        #expect(call.summary == "a.txt, b.txt")
        #expect(call.diff == "diff a.txt\n@@ -1 +1 @@\n-old\n+new\ndiff b.txt\n@@ -1,2 +1,2 @@\n keep\n-gone\n+here")
        #expect(call.output == nil)
    }

    @Test func legacyAbortsAndErrorsEndTheTurnWithANotice() {
        let aborted = decoder.legacyEntry(
            id: "msg_a1",
            data: json(#"{"role":"assistant","time":{"created":1},"error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}"#),
            parts: []
        )
        let failed = decoder.legacyEntry(
            id: "msg_a2",
            data: json(#"{"role":"assistant","time":{"created":1},"error":{"name":"APIError","data":{"message":"Quota exceeded"}}}"#),
            parts: []
        )
        let compacted = decoder.legacyEntry(
            id: "msg_u2",
            data: json(#"{"role":"user","time":{"created":1}}"#),
            parts: [json(#"{"type":"compaction","auto":true}"#)]
        )
        #expect(aborted.items.map(\.kind) == [.notice("Interrupted", isError: false)])
        #expect(failed.items.map(\.kind) == [.notice("Quota exceeded", isError: true)])
        #expect(compacted.items.map(\.kind) == [.notice("Context compacted", isError: false)])
    }

    // MARK: - Helpers

    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func object(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }
}
