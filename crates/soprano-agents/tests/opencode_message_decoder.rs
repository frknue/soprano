use serde_json::json;
use soprano_agents::*;

fn decoder() -> OpenCodeMessageDecoder {
    OpenCodeMessageDecoder::new(Some("/work/repo".into()))
}

fn object(value: serde_json::Value) -> Vec<u8> {
    serde_json::to_vec(&value).expect("json")
}

fn kinds(entry: &AgentTranscriptEntry) -> Vec<TimelineItemKind> {
    entry.items.iter().map(|i| i.kind.clone()).collect()
}

fn ids(entry: &AgentTranscriptEntry) -> Vec<&str> {
    entry.items.iter().map(|i| i.id.as_str()).collect()
}

fn ms(value: f64) -> Option<Date> {
    date_from_millis(value)
}

// MARK: - OpenCode 2.x

#[test]
fn typed_prompts_show_their_text_with_attachments_as_placeholders() {
    let entry = decoder().entry(
        "msg_u1",
        "user",
        br#"{"text":"What is on this screen?","files":[{"mime":"image/png","uri":"data:,"},{"name":"notes.txt","mime":"text/plain","uri":"file:///tmp/notes.txt"}],"time":{"created":1792367293828}}"#,
        &[],
    );
    assert_eq!(
        kinds(&entry),
        vec![TimelineItemKind::Prompt("What is on this screen?\n[image]\n[file notes.txt]".into())]
    );
    assert_eq!(entry.items[0].id, "msg_u1");
    assert_eq!(entry.items[0].timestamp, ms(1_792_367_293_828.0));
}

#[test]
fn assistant_reasoning_prose_and_tools_show_in_order_without_blank_replies() {
    let entry = decoder().entry(
        "msg_a1",
        "assistant",
        br#"{"agent":"build","model":{"providerID":"openai","id":"gpt"},"time":{"created":1000},"content":[
          {"type":"reasoning","text":""},
          {"type":"text","text":"  \n"},
          {"type":"text","text":"Checking the **build**."},
          {"type":"tool","id":"call_1","name":"read","state":{"status":"running","input":{"path":"/work/repo/Sources/App.swift"},"metadata":{}},"time":{"created":1001}}
        ]}"#,
        &[],
    );
    assert_eq!(ids(&entry), vec!["msg_a1#0", "msg_a1#2", "call_1"]);
    assert_eq!(
        kinds(&entry),
        vec![
            TimelineItemKind::Thinking(String::new()),
            TimelineItemKind::Reply("Checking the **build**.".into()),
            TimelineItemKind::Tool(AgentToolCall::new("Read", "Sources/App.swift")),
        ]
    );
}

#[test]
fn shell_tools_show_the_command_and_finish_with_their_output_or_exit_code() {
    let entry = decoder().entry(
        "msg_a1",
        "assistant",
        br#"{"time":{"created":1000},"content":[
          {"type":"tool","id":"call_ok","name":"shell","state":{"status":"completed","input":{"command":"swift build\nswift test"},"content":[{"type":"text","text":"Build complete!"}],"metadata":{"exit":0}},"time":{"created":1001,"completed":3000}},
          {"type":"tool","id":"call_exit","name":"bash","state":{"status":"completed","input":{"command":"false","description":"Fails"},"content":[{"type":"text","text":"exit 1"}],"metadata":{"exit":1}},"time":{"created":1001,"completed":3000}},
          {"type":"tool","id":"call_err","name":"shell","state":{"status":"error","input":{"command":"sleep 99"},"error":{"type":"tool.error","message":"Timed out"}},"time":{"created":1001,"completed":3000}},
          {"type":"tool","id":"call_stream","name":"shell","state":{"status":"streaming","input":"{\"comm"},"time":{"created":1001}}
        ]}"#,
        &[],
    );
    let calls: Vec<&AgentToolCall> = entry.items.iter().filter_map(|i| i.tool_call()).collect();
    assert_eq!(calls.len(), 4);
    assert_eq!(
        *calls[0],
        AgentToolCall {
            detail: Some("swift build\nswift test".into()),
            state: ToolCallState::Succeeded,
            output: Some("Build complete!".into()),
            finished_at: ms(3_000.0),
            ..AgentToolCall::new("Bash", "swift build")
        }
    );
    assert_eq!(calls[1].summary, "false");
    assert_eq!(calls[1].state, ToolCallState::Failed);
    assert_eq!(calls[2].state, ToolCallState::Failed);
    assert_eq!(calls[2].output.as_deref(), Some("Timed out"));
    assert_eq!(calls[3].state, ToolCallState::Running);
    assert_eq!(calls[3].summary, "");
}

#[test]
fn tools_are_named_and_summarized_like_the_other_agents() {
    let entry = decoder().entry(
        "msg_a1",
        "assistant",
        r#"{"time":{"created":1000},"content":[
          {"type":"tool","id":"c1","name":"glob","state":{"status":"running","input":{"pattern":"**/*.swift","path":"Sources"},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c2","name":"grep","state":{"status":"running","input":{"pattern":"TODO"},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c3","name":"webfetch","state":{"status":"running","input":{"url":"https://opencode.ai/docs"},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c4","name":"websearch","state":{"status":"running","input":{"query":"swift testing"},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c5","name":"subagent","state":{"status":"running","input":{"agent":"explore","description":"Map the store","prompt":"…"},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c6","name":"todowrite","state":{"status":"running","input":{"todos":[{},{},{}]},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c7","name":"question","state":{"status":"running","input":{"questions":[{"question":"Which branch?\nPick one."}]},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c8","name":"skill","state":{"status":"running","input":{"id":"customize-opencode"},"metadata":{}},"time":{"created":1}},
          {"type":"tool","id":"c9","name":"context7_query-docs","state":{"status":"running","input":{"libraryId":"/upstash/context7","query":"API key from env"},"metadata":{}},"time":{"created":1}}
        ]}"#
        .as_bytes(),
        &[],
    );
    let calls: Vec<String> = entry
        .items
        .iter()
        .filter_map(|i| i.tool_call())
        .map(|c| format!("{}: {}", c.name, c.summary))
        .collect();
    assert_eq!(
        calls,
        vec![
            "Glob: **/*.swift in Sources",
            "Grep: TODO",
            "WebFetch: https://opencode.ai/docs",
            "WebSearch: swift testing",
            "Task: Map the store",
            "Todo: 3 todos",
            "Ask: Which branch?",
            "Skill: customize-opencode",
            "context7_query-docs: API key from env",
        ]
    );
}

#[test]
fn edits_show_only_the_hunk_lines_of_their_diff_named_after_the_file() {
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
    ]
    .join("\n");
    let entry = decoder().entry(
        "msg_a1",
        "assistant",
        &object(json!({
            "time": {"created": 1000},
            "content": [{
                "type": "tool", "id": "call_e", "name": "edit",
                "state": {
                    "status": "completed",
                    "input": {"path": "/work/repo/Sources/App.swift", "oldString": "x", "newString": "y"},
                    "content": [{"type": "text", "text": "Edited Sources/App.swift (1 replacement)"}],
                    "metadata": {"files": [{"file": "/work/repo/Sources/App.swift", "patch": patch, "status": "modified"}]},
                },
                "time": {"created": 1001, "completed": 1002},
            }],
        })),
        &[],
    );
    let call = entry.items[0].tool_call().expect("call");
    assert_eq!(call.name, "Edit");
    assert_eq!(call.summary, "Sources/App.swift");
    assert_eq!(
        call.diff.as_deref(),
        Some("@@ -1,3 +1,3 @@\n let a = 1\n--- a comment that starts with two dashes\n+let b = 3\n }")
    );
    assert_eq!(call.output, None);
    assert_eq!(call.state, ToolCallState::Succeeded);
}

#[test]
fn patches_that_change_several_files_label_each_files_hunks() {
    let file_patch = |path: &str, line: &str| {
        format!("Index: {path}\n===\n--- {path}\n+++ {path}\n@@ -0,0 +1,1 @@\n+{line}\n")
    };
    let entry = decoder().entry(
        "msg_a1",
        "assistant",
        &object(json!({
            "time": {"created": 1000},
            "content": [{
                "type": "tool", "id": "call_p", "name": "apply_patch",
                "state": {
                    "status": "completed",
                    "input": {"patchText": "*** Begin Patch\n*** Add File: /work/repo/a.txt\n+one\n*** Add File: /work/repo/b.txt\n+two\n*** End Patch"},
                    "content": [{"type": "text", "text": "Success"}],
                    "metadata": {"files": [
                        {"filePath": "/work/repo/a.txt", "patch": file_patch("/work/repo/a.txt", "one")},
                        {"filePath": "/work/repo/b.txt", "patch": file_patch("/work/repo/b.txt", "two")},
                    ]},
                },
                "time": {"created": 1001, "completed": 1002},
            }],
        })),
        &[],
    );
    let call = entry.items[0].tool_call().expect("call");
    assert_eq!(call.summary, "a.txt, b.txt");
    assert_eq!(
        call.diff.as_deref(),
        Some("diff a.txt\n@@ -0,0 +1,1 @@\n+one\ndiff b.txt\n@@ -0,0 +1,1 @@\n+two")
    );
}

#[test]
fn a_running_patch_names_the_first_file_of_its_envelope() {
    let entry = decoder().entry(
        "msg_a1",
        "assistant",
        &object(json!({
            "time": {"created": 1000},
            "content": [{
                "type": "tool", "id": "call_p", "name": "patch",
                "state": {"status": "running", "input": {"patchText": "*** Begin Patch\n*** Update File: /work/repo/a.txt\n@@\n-one\n+two\n*** End Patch"}, "metadata": {}},
                "time": {"created": 1001},
            }],
        })),
        &[],
    );
    let call = entry.items[0].tool_call().expect("call");
    assert_eq!(call.summary, "a.txt");
    assert_eq!(call.state, ToolCallState::Running);
}

#[test]
fn part_rows_replace_an_assistant_messages_inline_content() {
    let entry = decoder().entry(
        "msg_a1",
        "assistant",
        br#"{"time":{"created":1000},"content":[{"type":"text","text":"stale inline"}]}"#,
        &[
            PartRow::new("reasoning", br#"{"text":"Plan first."}"#.to_vec()),
            PartRow::new("text", br#"{"text":"Done."}"#.to_vec()),
        ],
    );
    assert_eq!(
        kinds(&entry),
        vec![TimelineItemKind::Thinking("Plan first.".into()), TimelineItemKind::Reply("Done.".into())]
    );
}

#[test]
fn turn_endings_compaction_and_failures_show_as_notices() {
    let d = decoder();
    let interrupted = d.entry("msg_i", "idle", br#"{"outcome":"interrupted","time":{"created":1}}"#, &[]);
    let failed = d.entry(
        "msg_f",
        "idle",
        br#"{"outcome":"failed","error":{"type":"provider.error","message":"Quota exceeded"},"time":{"created":1}}"#,
        &[],
    );
    let succeeded = d.entry("msg_s", "idle", br#"{"outcome":"succeeded","time":{"created":1}}"#, &[]);
    let compaction = d.entry(
        "msg_c",
        "compaction",
        br#"{"status":"running","reason":"auto","summary":"","time":{"created":1}}"#,
        &[],
    );
    let error = d.entry(
        "msg_e",
        "assistant",
        br#"{"content":[],"error":{"type":"provider.error","message":"Overloaded"},"time":{"created":1}}"#,
        &[],
    );
    let aborted = d.entry(
        "msg_ab",
        "assistant",
        br#"{"content":[],"error":{"type":"aborted","message":"Step interrupted"},"finish":"error","time":{"created":1}}"#,
        &[],
    );

    assert_eq!(kinds(&interrupted), vec![TimelineItemKind::notice("Interrupted", false)]);
    assert_eq!(kinds(&failed), vec![TimelineItemKind::notice("Quota exceeded", true)]);
    assert!(succeeded.items.is_empty());
    assert_eq!(kinds(&compaction), vec![TimelineItemKind::notice("Context compacted", false)]);
    assert_eq!(compaction.items[0].id, "msg_c");
    assert_eq!(kinds(&error), vec![TimelineItemKind::notice("Overloaded", true)]);
    assert_eq!(kinds(&aborted), vec![TimelineItemKind::notice("Interrupted", false)]);
}

#[test]
fn injected_messages_and_switches_show_nothing() {
    for kind in ["system", "synthetic", "skill", "agent-switched", "model-switched", "location-switched"] {
        let entry = decoder().entry(
            "msg_x",
            kind,
            br#"{"text":"The available tools have changed.","time":{"created":1}}"#,
            &[],
        );
        assert!(entry.items.is_empty());
    }
}

#[test]
fn shell_commands_the_person_ran_show_as_shell_calls() {
    let entry = decoder().entry(
        "msg_sh",
        "shell",
        br#"{"shellID":"sh_1","command":"ls -la","status":"exited","exit":2,"output":"ls: nope","time":{"created":1000,"completed":2000}}"#,
        &[],
    );
    assert_eq!(entry.items[0].id, "msg_sh");
    assert_eq!(
        entry.items[0].tool_call().cloned(),
        Some(AgentToolCall {
            state: ToolCallState::Failed,
            output: Some("ls: nope".into()),
            finished_at: ms(2_000.0),
            ..AgentToolCall::new("Shell", "ls -la")
        })
    );
}

// MARK: - OpenCode 1.x

#[test]
fn legacy_user_messages_join_their_typed_text_and_skip_synthetic_parts() {
    let entry = decoder().legacy_entry(
        "msg_u1",
        br#"{"role":"user","time":{"created":1000}}"#,
        &[
            br#"{"type":"text","text":"Summarize this file"}"#.to_vec(),
            br#"{"type":"text","text":"<file contents>","synthetic":true}"#.to_vec(),
            br#"{"type":"file","mime":"text/plain","filename":"notes.txt","url":"file:///tmp/notes.txt"}"#
                .to_vec(),
        ],
    );
    assert_eq!(kinds(&entry), vec![TimelineItemKind::Prompt("Summarize this file\n[file notes.txt]".into())]);
    assert_eq!(entry.items[0].id, "msg_u1");
}

#[test]
fn legacy_assistant_parts_become_thinking_replies_and_tool_calls() {
    let entry = decoder().legacy_entry(
        "msg_a1",
        br#"{"role":"assistant","time":{"created":1000}}"#,
        &[
            br#"{"type":"step-start"}"#.to_vec(),
            br#"{"type":"reasoning","text":"Look first."}"#.to_vec(),
            br#"{"type":"text","text":"Running the tests."}"#.to_vec(),
            br#"{"type":"tool","tool":"bash","callID":"call_b","state":{"status":"completed","input":{"command":"swift test","description":"Runs tests"},"output":"All passed","metadata":{"exit":0},"time":{"start":1001,"end":4000}}}"#.to_vec(),
            br#"{"type":"tool","tool":"read","callID":"call_r","state":{"status":"error","input":{"filePath":"/work/repo/Missing.swift"},"error":"File not found","time":{"start":1001,"end":1002}}}"#.to_vec(),
            br#"{"type":"step-finish"}"#.to_vec(),
        ],
    );
    assert_eq!(ids(&entry), vec!["msg_a1#1", "msg_a1#2", "call_b", "call_r"]);
    assert_eq!(entry.items[0].kind, TimelineItemKind::Thinking("Look first.".into()));
    assert_eq!(entry.items[1].kind, TimelineItemKind::Reply("Running the tests.".into()));
    assert_eq!(
        entry.items[2].tool_call().cloned(),
        Some(AgentToolCall {
            state: ToolCallState::Succeeded,
            output: Some("All passed".into()),
            finished_at: ms(4_000.0),
            ..AgentToolCall::new("Bash", "swift test")
        })
    );
    let read = entry.items[3].tool_call().expect("read");
    assert_eq!(read.summary, "Missing.swift");
    assert_eq!(read.state, ToolCallState::Failed);
    assert_eq!(read.output.as_deref(), Some("File not found"));
}

#[test]
fn legacy_diffs_covering_several_files_are_split_per_file() {
    let diff = [
        "Index: /work/repo/a.txt",
        "===",
        "--- /work/repo/a.txt",
        "+++ /work/repo/a.txt",
        "@@ -1 +1 @@",
        "-old",
        "+new",
        "Index: /work/repo/b.txt",
        "===",
        "--- /work/repo/b.txt",
        "+++ /work/repo/b.txt",
        "@@ -1,2 +1,2 @@",
        " keep",
        "-gone",
        "+here",
    ]
    .join("\n");
    let entry = decoder().legacy_entry(
        "msg_a1",
        br#"{"role":"assistant","time":{"created":1000}}"#,
        &[object(json!({
            "type": "tool", "tool": "apply_patch", "callID": "call_p",
            "state": {
                "status": "completed", "input": {"patchText": "…"}, "output": "Success",
                "metadata": {"diff": diff}, "time": {"start": 1001, "end": 1002},
            },
        }))],
    );
    let call = entry.items[0].tool_call().expect("call");
    assert_eq!(call.summary, "a.txt, b.txt");
    assert_eq!(
        call.diff.as_deref(),
        Some("diff a.txt\n@@ -1 +1 @@\n-old\n+new\ndiff b.txt\n@@ -1,2 +1,2 @@\n keep\n-gone\n+here")
    );
    assert_eq!(call.output, None);
}

#[test]
fn legacy_aborts_and_errors_end_the_turn_with_a_notice() {
    let d = decoder();
    let aborted = d.legacy_entry(
        "msg_a1",
        br#"{"role":"assistant","time":{"created":1},"error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}"#,
        &[],
    );
    let failed = d.legacy_entry(
        "msg_a2",
        br#"{"role":"assistant","time":{"created":1},"error":{"name":"APIError","data":{"message":"Quota exceeded"}}}"#,
        &[],
    );
    let compacted = d.legacy_entry(
        "msg_u2",
        br#"{"role":"user","time":{"created":1}}"#,
        &[br#"{"type":"compaction","auto":true}"#.to_vec()],
    );
    assert_eq!(kinds(&aborted), vec![TimelineItemKind::notice("Interrupted", false)]);
    assert_eq!(kinds(&failed), vec![TimelineItemKind::notice("Quota exceeded", true)]);
    assert_eq!(kinds(&compacted), vec![TimelineItemKind::notice("Context compacted", false)]);
}
