use chrono::{Duration, TimeZone, Utc};
use serde_json::Value;
use soprano_agents::Date;
use soprano_chat::*;

fn now() -> Date {
    Utc.timestamp_opt(1_800_000_000, 0).single().expect("date")
}

fn update(json: &str) -> Value {
    serde_json::from_str(json).expect("json")
}

fn kinds(turn: &Turn) -> Vec<TurnItemKind> {
    turn.items.iter().map(|i| i.kind.clone()).collect()
}

#[test]
fn streamed_chunks_of_one_message_join_into_one_item_after_its_thinking() {
    let mut builder = AcpTurnBuilder::new(Some("/work/repo".into()), AcpToolStyle::Omp);
    builder.add_prompt("Explain the build", now());
    for json in [
        r#"{"sessionUpdate":"agent_thought_chunk","messageId":"m1","content":{"type":"text","text":"Reading "}}"#,
        r#"{"sessionUpdate":"agent_thought_chunk","messageId":"m1","content":{"type":"text","text":"Package.swift"}}"#,
        r#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"It uses "}}"#,
        r#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"SwiftPM."}}"#,
    ] {
        assert!(builder.apply(&update(json), now()));
    }
    let turn = &builder.thread().turns[0];
    assert_eq!(turn.user_message.text, "Explain the build");
    assert_eq!(
        kinds(turn),
        vec![
            TurnItemKind::Reasoning { text: "Reading Package.swift".into() },
            TurnItemKind::AssistantMessage { text: "It uses SwiftPM.".into(), is_final: false },
        ]
    );
    // The thought ended when the reply began; the reply still streams.
    assert_eq!(
        turn.items.iter().map(|i| i.status).collect::<Vec<_>>(),
        vec![TurnItemStatus::Completed, TurnItemStatus::Running]
    );
}

#[test]
fn a_message_interrupted_by_a_tool_call_continues_in_a_new_item_in_order() {
    let mut builder = AcpTurnBuilder::new(None, AcpToolStyle::Omp);
    builder.add_prompt("Go", now());
    builder.apply(&update(r#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"First"}}"#), now());
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ ls","status":"pending","rawInput":{"command":"ls"}}"#),
        now(),
    );
    builder.apply(&update(r#"{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"Then"}}"#), now());
    let kinds = kinds(&builder.thread().turns[0]);
    assert_eq!(kinds.len(), 3);
    assert_eq!(kinds[0], TurnItemKind::AssistantMessage { text: "First".into(), is_final: false });
    assert_eq!(kinds[2], TurnItemKind::AssistantMessage { text: "Then".into(), is_final: false });
}

#[test]
fn omp_tool_calls_move_from_running_to_their_result() {
    let mut builder = AcpTurnBuilder::new(Some("/tmp/acp-probe".into()), AcpToolStyle::Omp);
    builder.add_prompt("List", now());
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ ls","kind":"execute","status":"pending","rawInput":{"command":"ls"}}"#),
        now(),
    );
    assert_eq!(builder.thread().turns[0].items[0].status, TurnItemStatus::Pending);
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"in_progress","rawOutput":{"content":[{"type":"text","text":"a.txt"}]}}"#),
        now(),
    );
    assert_eq!(
        builder.thread().turns[0].items[0].kind,
        TurnItemKind::Command(TurnCommand::new("ls", "a.txt", None))
    );
    assert_eq!(builder.thread().turns[0].items[0].status, TurnItemStatus::Running);
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","rawOutput":{"content":[{"type":"text","text":"a.txt\nb.txt"}],"details":{}}}"#),
        now() + Duration::seconds(2),
    );
    let item = &builder.thread().turns[0].items[0];
    assert_eq!(item.kind, TurnItemKind::Command(TurnCommand::new("ls", "a.txt\nb.txt", Some(0))));
    assert_eq!(item.status, TurnItemStatus::Completed);
    assert_eq!(item.completed_at, Some(now() + Duration::seconds(2)));

    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call","toolCallId":"t2","name":"read","title":"Reading","status":"pending","rawInput":{"path":"/tmp/acp-probe/Sources/App.swift"}}"#),
        now(),
    );
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"failed","rawOutput":{"content":[{"type":"text","text":"No such file"}]}}"#),
        now(),
    );
    let read = &builder.thread().turns[0].items[1];
    assert_eq!(read.status, TurnItemStatus::Failed);
    let TurnItemKind::ToolCall(call) = &read.kind else { panic!("no tool call") };
    assert_eq!(call.category, ToolCategory::Read);
    assert_eq!(call.title, "Read Sources/App.swift");
}

#[test]
fn an_omp_edit_reads_its_diff_and_path_from_the_details() {
    let mut builder = AcpTurnBuilder::new(Some("/tmp/acp-probe".into()), AcpToolStyle::Omp);
    builder.add_prompt("Edit", now());
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call","toolCallId":"t2","name":"edit","title":"Replacing hello","kind":"edit","status":"pending","rawInput":{"path":"/tmp/acp-probe/a.txt","old_string":"hello","new_string":"goodbye"}}"#),
        now(),
    );
    // Running: the code the arguments carry.
    assert_eq!(
        builder.thread().turns[0].items[0].kind,
        TurnItemKind::FileChange(vec![FileChange::with_diff(
            "a.txt",
            FileChangeKind::Update,
            Some("@@ -0,1 +0,1 @@\n-hello\n+goodbye".into())
        )])
    );
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"completed","rawOutput":{"content":[{"type":"text","text":"ok"}],"details":{"diff":" 1|one\n-2|hello\n+2|goodbye","path":"/tmp/acp-probe/a.txt"}}}"#),
        now(),
    );
    assert_eq!(
        builder.thread().turns[0].items[0].kind,
        TurnItemKind::FileChange(vec![FileChange::with_diff(
            "a.txt",
            FileChangeKind::Update,
            Some("@@ -1,2 +1,2 @@\n one\n-hello\n+goodbye".into())
        )])
    );
    builder.finish_turn(Some("end_turn"), None, now());
    assert_eq!(
        builder.thread().turns[0].changed_files(),
        vec![ChangedFileStat { path: "a.txt".into(), additions: 1, deletions: 1 }]
    );
}

#[test]
fn other_agents_edits_come_from_the_protocols_diff_content() {
    let mut builder = AcpTurnBuilder::new(Some("/repo".into()), AcpToolStyle::Generic);
    builder.add_prompt("Edit", now());
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Update the greeting","kind":"edit","status":"in_progress"}"#),
        now(),
    );
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"diff","path":"/repo/a.txt","oldText":"one\nhello\nthree\n","newText":"one\ngoodbye\nthree\n"}]}"#),
        now(),
    );
    assert_eq!(
        builder.thread().turns[0].items[0].kind,
        TurnItemKind::FileChange(vec![FileChange::with_diff(
            "a.txt",
            FileChangeKind::Update,
            Some("@@ -1,3 +1,3 @@\n one\n-hello\n+goodbye\n three".into())
        )])
    );
}

#[test]
fn ending_a_turn_sets_its_status_interrupts_running_calls_and_marks_the_answer() {
    let mut builder = AcpTurnBuilder::new(None, AcpToolStyle::Omp);
    builder.add_prompt("Sleep", now());
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ sleep 60","status":"pending","rawInput":{"command":"sleep 60"}}"#),
        now(),
    );
    builder.mark_stop_requested(now());
    assert_eq!(builder.thread().active_turn().and_then(|t| t.stop_requested_at), Some(now()));
    builder.finish_turn(Some("cancelled"), None, now() + Duration::seconds(12));
    let stopped = &builder.thread().turns[0];
    assert_eq!(stopped.status, TurnStatus::Interrupted);
    assert_eq!(stopped.items[0].status, TurnItemStatus::Interrupted);
    assert_eq!(stopped.duration_seconds(now()), Some(12.0));
    assert_eq!(turn_duration_text(12.0), "12s");

    builder.add_prompt("Answer", now());
    builder.apply(
        &update(r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}"#),
        now(),
    );
    builder.finish_turn(Some("end_turn"), None, now() + Duration::seconds(72));
    let answered = &builder.thread().turns[1];
    assert_eq!(answered.status, TurnStatus::Completed);
    assert_eq!(
        answered.items[0].kind,
        TurnItemKind::AssistantMessage { text: "Done.".into(), is_final: true }
    );
    assert_eq!(turn_duration_text(answered.duration_seconds(now()).expect("duration")), "1m 12s");

    builder.add_prompt("Limit", now());
    builder.finish_turn(Some("max_tokens"), None, now());
    assert_eq!(builder.thread().turns[2].status, TurnStatus::Failed);
    assert_eq!(
        builder.thread().turns[2].failure_message.as_deref(),
        Some("The reply reached the model's output limit.")
    );
}

#[test]
fn a_replayed_conversation_rebuilds_its_turns_without_times() {
    let mut builder = AcpTurnBuilder::new(None, AcpToolStyle::Omp);
    builder.set_replaying(true);
    for json in [
        r#"{"sessionUpdate":"user_message_chunk","messageId":"u1","content":{"type":"text","text":"Hi"}}"#,
        r#"{"sessionUpdate":"agent_message_chunk","messageId":"a1","content":{"type":"text","text":"Hello"}}"#,
        r#"{"sessionUpdate":"user_message_chunk","messageId":"u2","content":{"type":"text","text":"Run "}}"#,
        r#"{"sessionUpdate":"user_message_chunk","messageId":"u2","content":{"type":"text","text":"it"}}"#,
        r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ make","status":"completed","rawInput":{"command":"make"},"rawOutput":{"content":[{"type":"text","text":"ok"}],"details":{"exitCode":0}}}"#,
        r#"{"sessionUpdate":"agent_message_chunk","messageId":"a2","content":{"type":"text","text":"Built."}}"#,
    ] {
        builder.apply(&update(json), now());
    }
    builder.set_replaying(false);
    let turns = &builder.thread().turns;
    assert_eq!(turns.iter().map(|t| t.user_message.text.as_str()).collect::<Vec<_>>(), vec!["Hi", "Run it"]);
    assert_eq!(
        turns.iter().map(|t| t.status).collect::<Vec<_>>(),
        vec![TurnStatus::Completed, TurnStatus::Completed]
    );
    assert!(turns.iter().all(|t| t.started_at.is_none() && t.items.iter().all(|i| i.started_at.is_none())));
    assert_eq!(
        turns[1].items.iter().map(|i| i.status).collect::<Vec<_>>(),
        vec![TurnItemStatus::Completed, TurnItemStatus::Completed]
    );
    assert_eq!(
        turns[1].items.last().map(|i| i.kind.clone()),
        Some(TurnItemKind::AssistantMessage { text: "Built.".into(), is_final: true })
    );
    // A replayed turn has no duration ("Worked" without a time).
    assert_eq!(turns[1].duration_seconds(now()), None);

    builder.add_prompt("Again", now());
    assert_eq!(builder.thread().turns.last().and_then(|t| t.started_at), Some(now()));
}

#[test]
fn notices_without_a_turn_go_before_the_first_one() {
    let mut builder = AcpTurnBuilder::new(None, AcpToolStyle::Omp);
    builder.add_notice("Could not reopen", true, None);
    builder.add_prompt("Hi", now());
    builder.add_notice("Context compacted", false, Some(now()));
    assert_eq!(
        builder.thread().preamble.iter().map(|i| i.kind.clone()).collect::<Vec<_>>(),
        vec![TurnItemKind::Error { message: "Could not reopen".into() }]
    );
    assert_eq!(
        kinds(&builder.thread().turns[0]),
        vec![TurnItemKind::Notice { text: "Context compacted".into() }]
    );
}

#[test]
fn omp_display_diffs_become_unified_hunks() {
    assert_eq!(
        unified_diff(" 41|keep\n-42|old\n+42|new\n...\n+90|added").as_deref(),
        Some("@@ -41,2 +41,2 @@\n keep\n-old\n+new\n@@ -89,0 +90,1 @@\n+added")
    );
    assert_eq!(unified_diff("@@ -1 +1 @@\n-a\n+b").as_deref(), Some("@@ -1 +1 @@\n-a\n+b"));
    assert_eq!(diff_line_count("@@ -1 +1 @@\n-a\n+b\n+c"), (2, 1));
}

#[test]
fn a_diff_keeps_three_lines_of_context_around_the_change() {
    let old = (1..=10).map(|i| format!("line {i}")).collect::<Vec<_>>().join("\n");
    let new = old.replace("line 6", "line six");
    let diff = acp_unified_diff(&old, &new).expect("diff");
    assert_eq!(
        diff.split('\n').collect::<Vec<_>>(),
        vec![
            "@@ -3,7 +3,7 @@",
            " line 3",
            " line 4",
            " line 5",
            "-line 6",
            "+line six",
            " line 7",
            " line 8",
            " line 9"
        ]
    );
    assert_eq!(acp_unified_diff("same", "same"), None);
    assert_eq!(acp_unified_diff("", "new file\n").as_deref(), Some("@@ -1,0 +1,1 @@\n+new file"));
}

#[test]
fn a_finished_turns_answer_carries_the_files_its_edits_changed() {
    let mut builder = AcpTurnBuilder::new(Some("/r".into()), AcpToolStyle::Omp);
    builder.add_prompt("Fix", now());
    builder.apply(
        &update(r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"edit","status":"completed","rawInput":{"path":"/r/a.swift"},"rawOutput":{"details":{"diff":"+1|x","path":"/r/a.swift"}}}"#),
        now(),
    );
    builder.apply(
        &update(r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Fixed."}}"#),
        now(),
    );
    builder.finish_turn(Some("end_turn"), None, now() + Duration::seconds(52));
    let turn = &builder.thread().turns[0];
    assert_eq!(turn_duration_text(turn.duration_seconds(now()).expect("duration")), "52s");
    assert_eq!(
        turn.items.last().map(|i| i.kind.clone()),
        Some(TurnItemKind::AssistantMessage { text: "Fixed.".into(), is_final: true })
    );
    assert_eq!(
        turn.changed_files(),
        vec![ChangedFileStat { path: "a.swift".into(), additions: 1, deletions: 0 }]
    );
}

#[test]
fn omp_write_and_hashline_edit_previews_show_their_code_before_the_result() {
    let write = serde_json::json!({"path": "/r/new.txt", "content": "one\ntwo\n"});
    assert_eq!(
        omp_edit_changes("write", &write, &|p: &str| relative_path(p, Some("/r"))),
        vec![FileChange {
            is_full_content: Some(true),
            ..FileChange::with_diff(
                "new.txt",
                FileChangeKind::Update,
                Some("@@ -0,0 +1,2 @@\n+one\n+two".into())
            )
        }]
    );
    assert!(
        omp_edit_changes(
            "write",
            &serde_json::json!({"path": "local://x.md", "content": "x"}),
            &|p: &str| p.to_owned()
        )
        .is_empty()
    );

    let hashline = serde_json::json!({"input": "[src/app.ts#1A2B]\nPUT 3.=4:\n+let a = 1\n+let b = 2\n*** Update File: b.txt\n@@ fn main\n-old\n+new"});
    assert_eq!(
        omp_edit_changes("edit", &hashline, &|p: &str| p.to_owned()),
        vec![
            FileChange::with_diff(
                "src/app.ts",
                FileChangeKind::Update,
                Some("@@ -0,0 +0,2 @@ PUT 3.=4:\n+let a = 1\n+let b = 2".into())
            ),
            FileChange::with_diff(
                "b.txt",
                FileChangeKind::Update,
                Some("@@ -0,1 +0,1 @@ fn main\n-old\n+new".into())
            ),
        ]
    );
    assert_eq!(
        argument_path(&serde_json::json!({"input": "[src/app.ts#1A2B]\nPUT 1:"})).as_deref(),
        Some("src/app.ts")
    );
    assert_eq!(relative_path("/private/tmp/x/a.txt", Some("/tmp/x")), "a.txt");
    assert_eq!(relative_path("/tmp/x", Some("/tmp/x")), ".");
}
