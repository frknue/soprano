use soprano_agents::*;

const META: &str = r#"{"timestamp":"2026-10-12T09:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/work/app"}}"#;

fn items(lines: &[String]) -> Vec<AgentTimelineItem> {
    let mut decoder = CodexRolloutDecoder::new();
    let mut entries = Vec::new();
    for line in std::iter::once(META).chain(lines.iter().map(String::as_str)) {
        if let Some(entry) = decoder.entry_for_line(line.as_bytes()) {
            entries.push(entry);
        }
    }
    AgentTimeline::from_entries(&entries).items
}

fn completed(item: &str) -> String {
    format!(
        r#"{{"timestamp":"2026-10-12T09:00:05.000Z","type":"event_msg","payload":{{"type":"item_completed","item":{item}}}}}"#
    )
}

fn kinds(items: &[AgentTimelineItem]) -> Vec<TimelineItemKind> {
    items.iter().map(|i| i.kind.clone()).collect()
}

fn call(items: &[AgentTimelineItem]) -> AgentToolCall {
    items.first().and_then(|i| i.tool_call()).cloned().expect("a tool call")
}

#[test]
fn user_messages_become_prompts_with_images_shown_as_placeholders() {
    let result = items(&[completed(
        r#"{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Fix the login bug"},{"type":"image","image_url":"data:x"}]}"#,
    )]);
    assert_eq!(kinds(&result), vec![TimelineItemKind::Prompt("Fix the login bug\n[image]".into())]);
    assert_eq!(result[0].id, "u1");
    assert!(result[0].timestamp.is_some());
}

#[test]
fn agent_messages_of_every_phase_become_replies() {
    let result = items(&[
        completed(
            r#"{"type":"AgentMessage","id":"a1","phase":"commentary","content":[{"type":"Text","text":"Looking around."}]}"#,
        ),
        completed(
            r#"{"type":"AgentMessage","id":"a2","phase":"final_answer","content":[{"type":"Text","text":"**Done.**"}]}"#,
        ),
    ]);
    assert_eq!(
        kinds(&result),
        vec![TimelineItemKind::Reply("Looking around.".into()), TimelineItemKind::Reply("**Done.**".into())]
    );
}

#[test]
fn reasoning_shows_its_summary_and_is_hidden_when_there_is_none() {
    let result = items(&[
        completed(
            r#"{"type":"Reasoning","id":"r1","summary_text":["Checking the router"],"raw_content":[]}"#,
        ),
        completed(r#"{"type":"Reasoning","id":"r2","summary_text":[],"raw_content":[]}"#),
    ]);
    assert_eq!(kinds(&result), vec![TimelineItemKind::Thinking("Checking the router".into())]);
}

#[test]
fn a_command_that_exits_with_zero_succeeds_and_shows_its_output() {
    let result = items(&[completed(
        r#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","swift build"],"parsed_cmd":[{"type":"unknown","cmd":"swift build"}],"status":"completed","exit_code":0,"aggregated_output":"Build complete!\n","duration":{"secs":3,"nanos":0}}"#,
    )]);
    let call = call(&result);
    assert_eq!(call.name, "Run");
    assert_eq!(call.summary, "swift build");
    assert_eq!(call.detail, None);
    assert_eq!(call.state, ToolCallState::Succeeded);
    assert_eq!(call.output.as_deref(), Some("Build complete!"));
}

#[test]
fn a_command_with_a_non_zero_exit_code_is_shown_as_failed() {
    let result = items(&[completed(
        r#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","make test"],"parsed_cmd":[{"type":"unknown","cmd":"make test"}],"status":"failed","exit_code":2,"aggregated_output":"error: boom"}"#,
    )]);
    let call = call(&result);
    assert_eq!(call.state, ToolCallState::Failed);
    assert_eq!(call.output.as_deref(), Some("error: boom"));
}

#[test]
fn reading_a_file_is_named_read_with_the_path_relative_to_the_session() {
    let result = items(&[completed(
        r#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","sed -n '1,80p' Sources/main.swift"],"parsed_cmd":[{"type":"read","cmd":"sed -n '1,80p' Sources/main.swift","name":"main.swift","path":"/work/app/Sources/main.swift"}],"status":"completed","exit_code":0,"aggregated_output":"import AppKit"}"#,
    )]);
    let call = call(&result);
    assert_eq!(call.name, "Read");
    assert_eq!(call.summary, "Sources/main.swift");
    assert_eq!(call.detail.as_deref(), Some("sed -n '1,80p' Sources/main.swift"));
}

#[test]
fn file_changes_show_their_diffs_with_added_files_as_plus_lines() {
    let single = call(&items(&[completed(
        r#"{"type":"FileChange","id":"f1","status":"completed","changes":{"/work/app/a.swift":{"type":"update","unified_diff":"@@ -1 +1 @@\n-old\n+new\n","move_path":null}}}"#,
    )]));
    assert_eq!(single.name, "Edit");
    assert_eq!(single.summary, "a.swift");
    assert_eq!(single.diff.as_deref(), Some("@@ -1 +1 @@\n-old\n+new"));

    let several = call(&items(&[completed(
        r#"{"type":"FileChange","id":"f2","status":"completed","changes":{"/work/app/a.swift":{"type":"update","unified_diff":"@@ -1 +1 @@\n-x\n+y"},"/work/app/b.swift":{"type":"add","content":"one\ntwo\n"}}}"#,
    )]));
    assert_eq!(several.name, "Edit");
    assert_eq!(several.summary, "a.swift +1 more");
    assert_eq!(several.diff.as_deref(), Some("diff a.swift\n@@ -1 +1 @@\n-x\n+y\ndiff b.swift\n+one\n+two"));

    let added = call(&items(&[completed(
        r#"{"type":"FileChange","id":"f3","status":"completed","changes":{"/work/app/new.swift":{"type":"add","content":"hello\n"}}}"#,
    )]));
    assert_eq!(added.name, "Add");
    assert_eq!(added.diff.as_deref(), Some("+hello"));
}

#[test]
fn mcp_calls_are_named_by_server_and_tool_and_show_their_text_result() {
    let call = call(&items(&[completed(
        r#"{"type":"McpToolCall","id":"m1","server":"github","tool":"search_issues","arguments":{"query":"crash on launch","limit":5},"status":"completed","result":{"content":[{"type":"text","text":"3 issues"}],"isError":false}}"#,
    )]));
    assert_eq!(call.name, "github.search_issues");
    assert_eq!(call.summary, "crash on launch");
    assert_eq!(call.state, ToolCallState::Succeeded);
    assert_eq!(call.output.as_deref(), Some("3 issues"));
}

#[test]
fn web_searches_show_their_query() {
    let call = call(&items(&[completed(
        r#"{"type":"Extension","id":"w1","kind":"web.search","query":"swift testing traits","action":{"type":"search","query":"swift testing traits"},"results":[]}"#,
    )]));
    assert_eq!(call.name, "WebSearch");
    assert_eq!(call.summary, "swift testing traits");
    assert_eq!(call.state, ToolCallState::Succeeded);
}

#[test]
fn compaction_and_aborted_turns_become_notices() {
    let result = items(&[
        completed(r#"{"type":"ContextCompaction","id":"k1"}"#),
        r#"{"timestamp":"2026-10-12T09:00:06.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t9","reason":"interrupted"}}"#.into(),
    ]);
    assert_eq!(
        kinds(&result),
        vec![
            TimelineItemKind::notice("Context compacted", false),
            TimelineItemKind::notice("Interrupted", false)
        ]
    );
    assert_eq!(result.last().map(|i| i.id.as_str()), Some("aborted-t9"));
}

#[test]
fn response_item_messages_never_show_because_they_carry_injected_instructions() {
    let result = items(&[
        r#"{"timestamp":"2026-10-12T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are a coding agent"}]}}"#.into(),
        r##"{"timestamp":"2026-10-12T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##.into(),
        r#"{"timestamp":"2026-10-12T09:00:01.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"x"}}"#.into(),
    ]);
    assert!(result.is_empty());
}

#[test]
fn malformed_lines_are_ignored() {
    let mut decoder = CodexRolloutDecoder::new();
    assert_eq!(decoder.entry_for_line(b"{not json"), None);
    assert_eq!(decoder.entry_for_line(br#"{"type":"event_msg"}"#), None);
}

#[test]
fn a_running_exec_call_shows_its_command_until_the_finished_command_replaces_it() {
    let exec = r#"{"timestamp":"2026-10-12T09:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call_1","input":"const r = await tools.exec_command({cmd: \"git status\\n\", workdir: \"/work/app\"});\ntext(r);"}}"#.to_owned();
    let running = items(std::slice::from_ref(&exec));
    assert_eq!(running.len(), 1);
    let call = call(&running);
    assert_eq!(call.name, "Run");
    assert_eq!(call.summary, "git status");
    assert_eq!(call.state, ToolCallState::Running);

    let finished = items(&[
        exec,
        r#"{"timestamp":"2026-10-12T09:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_1","output":"ok"}}"#.into(),
        completed(r#"{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","git status"],"parsed_cmd":[{"type":"unknown","cmd":"git status"}],"status":"completed","exit_code":0,"aggregated_output":"clean"}"#),
    ]);
    assert_eq!(finished.len(), 1);
    assert_eq!(finished[0].id, "c1");
    assert_eq!(finished[0].tool_call().map(|c| c.state), Some(ToolCallState::Succeeded));
}

#[test]
fn a_finished_command_sharing_its_call_id_with_the_provisional_call_survives_the_call_output() {
    let result = items(&[
        r#"{"timestamp":"2026-10-12T09:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"git status\"}","call_id":"call_1"}}"#.into(),
        completed(r#"{"type":"CommandExecution","id":"call_1","command":["/bin/zsh","-lc","git status"],"parsed_cmd":[{"type":"unknown","cmd":"git status"}],"status":"completed","exit_code":0,"aggregated_output":"clean"}"#),
        r#"{"timestamp":"2026-10-12T09:00:06.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"clean"}}"#.into(),
    ]);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].id, "call_1");
    let call = call(&result);
    assert_eq!(call.state, ToolCallState::Succeeded);
    assert_eq!(call.output.as_deref(), Some("clean"));
}
