use soprano_agents::*;

const HEADER: &str = r#"{"type":"session","version":3,"id":"sess-1","timestamp":"2026-10-12T09:00:00.000Z","cwd":"/work/repo"}"#;

fn timeline(lines: &[String]) -> AgentTimeline {
    let mut decoder = OmpSessionDecoder::new(None);
    let entries: Vec<_> = lines.iter().filter_map(|l| decoder.entry_for_line(l.as_bytes())).collect();
    AgentTimeline::from_entries(&entries)
}

fn kinds(timeline: &AgentTimeline) -> Vec<TimelineItemKind> {
    timeline.items.iter().map(|i| i.kind.clone()).collect()
}

fn assistant(id: &str, parent: Option<&str>, content: &str, stop_reason: &str, extra: &str) -> String {
    let parent_id = parent.map_or("null".to_owned(), |p| format!("\"{p}\""));
    format!(
        r#"{{"type":"message","id":"{id}","parentId":{parent_id},"timestamp":"2026-10-12T09:00:02.000Z","message":{{"role":"assistant","content":{content},"stopReason":"{stop_reason}"{extra}}}}}"#
    )
}

fn tool_result(id: &str, parent: &str, call_id: &str, tool: &str, text: &str, details: &str) -> String {
    format!(
        r#"{{"type":"message","id":"{id}","parentId":"{parent}","timestamp":"2026-10-12T09:00:05.000Z","message":{{"role":"toolResult","toolCallId":"{call_id}","toolName":"{tool}","content":[{{"type":"text","text":"{text}"}}],"details":{details},"isError":false}}}}"#
    )
}

#[test]
fn the_session_header_and_records_outside_the_tree_show_nothing() {
    let mut decoder = OmpSessionDecoder::new(None);
    assert_eq!(decoder.entry_for_line(HEADER.as_bytes()), None);
    assert_eq!(
        decoder.entry_for_line(br#"{"type":"title","v":1,"title":"Fix the build","source":"auto"}"#),
        None
    );
    assert_eq!(decoder.entry_for_line(br#"{"type":"message","id":"#), None);
}

#[test]
fn tool_paths_inside_the_session_directory_are_shown_relative_to_it() {
    let timeline = timeline(&[
        HEADER.into(),
        assistant(
            "a1",
            None,
            r#"[{"type":"toolCall","id":"call-r","name":"read","arguments":{"path":"/work/repo/Sources/App.swift","i":"Reading app"},"intent":"Reading app"}]"#,
            "toolUse",
            "",
        ),
    ]);
    let call = timeline.items[0].tool_call().expect("call");
    assert_eq!(call.name, "Read");
    assert_eq!(call.summary, "Sources/App.swift");
    assert_eq!(call.state, ToolCallState::Running);
}

#[test]
fn typed_user_messages_become_prompts_with_images_as_placeholders() {
    let timeline = timeline(&[
        HEADER.into(),
        r#"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"What is on this screen?"},{"type":"image","mimeType":"image/png","data":"AAAA"}]}}"#.into(),
    ]);
    assert_eq!(kinds(&timeline), vec![TimelineItemKind::Prompt("What is on this screen?\n[image]".into())]);
    assert_eq!(timeline.items[0].id, "u1");
}

#[test]
fn system_reminders_and_agent_injected_messages_never_show_but_stay_in_the_tree() {
    let mut decoder = OmpSessionDecoder::new(None);
    let _ = decoder.entry_for_line(HEADER.as_bytes());
    let reminder = decoder
        .entry_for_line(br#"{"type":"message","id":"d1","parentId":"u0","timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"developer","attribution":"agent","content":[{"type":"text","text":"<system-reminder>secret</system-reminder>"}]}}"#)
        .expect("reminder entry");
    assert_eq!(reminder.id.as_deref(), Some("d1"));
    assert_eq!(reminder.parent_id.as_deref(), Some("u0"));
    assert!(reminder.items.is_empty());

    let injected = decoder
        .entry_for_line(br#"{"type":"message","id":"u2","parentId":"d1","timestamp":"2026-10-12T09:00:02.000Z","message":{"role":"user","attribution":"agent","content":[{"type":"text","text":"Continue the plan."}]}}"#)
        .expect("injected entry");
    assert!(injected.items.is_empty());

    let model_change = decoder
        .entry_for_line(br#"{"type":"model_change","id":"m1","parentId":"u2","timestamp":"2026-10-12T09:00:03.000Z","model":"some/model"}"#)
        .expect("model change entry");
    assert_eq!(model_change.id.as_deref(), Some("m1"));
    assert!(model_change.items.is_empty());
}

#[test]
fn assistant_thinking_and_prose_show_in_order_without_blank_replies() {
    let timeline = timeline(&[
        HEADER.into(),
        assistant(
            "a1",
            None,
            r#"[{"type":"thinking","thinking":"Check the tests first."},{"type":"text","text":"  \n"},{"type":"text","text":"All **green**."}]"#,
            "stop",
            "",
        ),
    ]);
    assert_eq!(
        kinds(&timeline),
        vec![
            TimelineItemKind::Thinking("Check the tests first.".into()),
            TimelineItemKind::Reply("All **green**.".into())
        ]
    );
    assert_eq!(timeline.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["a1#0", "a1#2"]);
}

#[test]
fn bash_calls_show_the_intent_and_finish_with_their_output() {
    let timeline = timeline(&[
        HEADER.into(),
        assistant(
            "a1",
            None,
            r#"[{"type":"toolCall","id":"call-b","name":"bash","arguments":{"command":"swift build\nswift test","i":"Building package"},"intent":"Building package"}]"#,
            "toolUse",
            "",
        ),
        tool_result("r1", "a1", "call-b", "bash", "Build complete!", r#"{"wallTimeMs":1200}"#),
    ]);
    let call = timeline.items[0].tool_call().expect("call");
    assert_eq!(call.name, "Bash");
    assert_eq!(call.summary, "Building package");
    assert_eq!(call.detail.as_deref(), Some("swift build\nswift test"));
    assert_eq!(call.state, ToolCallState::Succeeded);
    assert_eq!(call.output.as_deref(), Some("Build complete!"));
    assert_eq!(call.finished_at, parse_date("2026-10-12T09:00:05.000Z"));
}

#[test]
fn bash_calls_with_a_non_zero_exit_code_show_as_failed() {
    let timeline = timeline(&[
        HEADER.into(),
        assistant(
            "a1",
            None,
            r#"[{"type":"toolCall","id":"call-b","name":"bash","arguments":{"command":"false"}}]"#,
            "toolUse",
            "",
        ),
        tool_result("r1", "a1", "call-b", "bash", "exit 1", r#"{"exitCode":1}"#),
    ]);
    let call = timeline.items[0].tool_call().expect("call");
    assert_eq!(call.summary, "false");
    assert_eq!(call.detail, None);
    assert_eq!(call.state, ToolCallState::Failed);
    assert_eq!(call.output.as_deref(), Some("exit 1"));
}

#[test]
fn edit_results_show_their_numbered_diff_as_a_unified_diff_named_after_the_file() {
    let diff = r#" 11|let a = 1\n-12|let b = 2\n+12|let b = 3\n\n 40|}\n+41|// done"#;
    let details =
        format!(r#"{{"diff":"{diff}","path":"/work/repo/Sources/App.swift","firstChangedLine":12}}"#);
    let timeline = timeline(&[
        HEADER.into(),
        assistant(
            "a1",
            None,
            r#"[{"type":"toolCall","id":"call-e","name":"edit","arguments":{"input":"…","i":"Bumping b"},"intent":"Bumping b"}]"#,
            "toolUse",
            "",
        ),
        tool_result("r1", "a1", "call-e", "edit", "Updated Sources/App.swift", &details),
    ]);
    let call = timeline.items[0].tool_call().expect("call");
    assert_eq!(call.name, "Edit");
    assert_eq!(call.summary, "Sources/App.swift");
    assert_eq!(call.diff.as_deref(), Some(" let a = 1\n-let b = 2\n+let b = 3\n@@\n }\n+// done"));
    assert_eq!(call.output, None);
    assert_eq!(call.state, ToolCallState::Succeeded);
}

#[test]
fn compaction_shows_as_a_notice() {
    let timeline = timeline(&[
        HEADER.into(),
        r#"{"type":"compaction","id":"c1","parentId":null,"timestamp":"2026-10-12T09:10:00.000Z","summary":"long summary","tokensBefore":100000}"#.into(),
    ]);
    assert_eq!(kinds(&timeline), vec![TimelineItemKind::notice("Context compacted", false)]);
}

#[test]
fn aborted_and_failed_turns_end_with_a_notice() {
    let timeline = timeline(&[
        HEADER.into(),
        assistant("a1", None, r#"[{"type":"text","text":"Starting"}]"#, "aborted", ""),
        assistant("a2", Some("a1"), "[]", "error", r#","errorMessage":"Overloaded""#),
    ]);
    assert_eq!(
        kinds(&timeline),
        vec![
            TimelineItemKind::Reply("Starting".into()),
            TimelineItemKind::notice("Interrupted", false),
            TimelineItemKind::notice("Overloaded", true),
        ]
    );
}

#[test]
fn rewinding_keeps_only_the_newer_branch_visible() {
    let timeline = timeline(&[
        HEADER.into(),
        r#"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Plan the change"}]}}"#.into(),
        assistant("a1", Some("u1"), r#"[{"type":"text","text":"Here is a plan."}]"#, "stop", ""),
        r#"{"type":"message","id":"u2","parentId":"a1","timestamp":"2026-10-12T09:00:06.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Old direction"}]}}"#.into(),
        assistant("a2", Some("u2"), r#"[{"type":"text","text":"Going the old way."}]"#, "stop", ""),
        r#"{"type":"message","id":"u3","parentId":"a1","timestamp":"2026-10-12T09:01:00.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"New direction"}]}}"#.into(),
        r#"{"type":"title_change","id":"t1","parentId":"u3","timestamp":"2026-10-12T09:01:01.000Z","title":"New"}"#.into(),
    ]);
    assert_eq!(
        kinds(&timeline),
        vec![
            TimelineItemKind::Prompt("Plan the change".into()),
            TimelineItemKind::Reply("Here is a plan.".into()),
            TimelineItemKind::Prompt("New direction".into()),
        ]
    );
}
