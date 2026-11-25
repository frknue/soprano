//! Antigravity (`agy`) transcript decoding (`AgyTranscriptDecoder`).

use soprano_agents::{
    AgentTimeline, AgentTranscriptDecoding, AgyTranscriptDecoder, TimelineItemKind, ToolCallState,
};

fn decode(lines: &[&str]) -> AgentTimeline {
    let mut decoder = AgyTranscriptDecoder::new();
    let entries: Vec<_> = lines.iter().filter_map(|line| decoder.entry_for_line(line.as_bytes())).collect();
    AgentTimeline::from_entries(&entries)
}

#[test]
fn user_requests_planner_thoughts_tool_calls_results_and_replies_decode_in_order() {
    let timeline = decode(&[
        r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-25T07:46:09Z","content":"<USER_REQUEST>\nAdd agy support\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nTime: now\n</ADDITIONAL_METADATA>"}"#,
        r#"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T07:46:10Z","model":"gemini-4-neon-high","thinking":"Inspecting the workspace.","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"git status\"","toolSummary":"\"Check status\""}},{"name":"read_file","args":{"Path":"\"/tmp/repo/src/lib.rs\""}}]}"#,
        r#"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-25T07:46:11Z","content":"On branch main"}"#,
        r#"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"ERROR","created_at":"2026-11-25T07:46:12Z","error":"Permission denied"}"#,
        r#"{"step_index":4,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-25T07:46:13Z","content":"Internal reminder"}"#,
        r#"{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T07:46:14Z","content":"All set!"}"#,
    ]);

    assert_eq!(timeline.items.len(), 5);
    assert_eq!(timeline.items[0].kind, TimelineItemKind::Prompt("Add agy support".into()));
    assert_eq!(timeline.items[1].kind, TimelineItemKind::Thinking("Inspecting the workspace.".into()));

    let run = timeline.items[2].tool_call().expect("run tool");
    assert_eq!(run.name, "Run");
    assert_eq!(run.summary, "Check status");
    assert_eq!(run.detail.as_deref(), Some("git status"));
    assert_eq!(run.state, ToolCallState::Succeeded);
    assert_eq!(run.output.as_deref(), Some("On branch main"));

    let read = timeline.items[3].tool_call().expect("read tool");
    assert_eq!(read.name, "Read");
    assert_eq!(read.summary, "/tmp/repo/src/lib.rs");
    assert_eq!(read.state, ToolCallState::Failed);
    assert_eq!(read.output.as_deref(), Some("Permission denied"));

    assert_eq!(timeline.items[4].kind, TimelineItemKind::Reply("All set!".into()));
}

#[test]
fn agy_sessions_are_indexed_with_title_model_resume_command_and_recent_messages() {
    use soprano_agents::{AgentSessionIndex, AgentTranscriptFormat, HistoryMessageRole};
    use std::collections::HashMap;

    let home = tempfile::tempdir().expect("home");
    let logs = home.path().join(".gemini/antigravity-cli/brain/agy-session-42/.system_generated/logs");
    std::fs::create_dir_all(&logs).expect("mkdir");
    std::fs::write(
        logs.join("transcript.jsonl"),
        concat!(
            r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-25T07:46:09Z","cwd":"/tmp/work/soprano","content":"<USER_REQUEST>\nImplement Antigravity support\n</USER_REQUEST>"}"#,
            "\n",
            r#"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T07:46:12Z","model":"gemini-4-neon-high","tool_calls":[{"name":"invoke_subagent","args":{"Role":"Researcher"}}],"content":"Implemented full Antigravity support."}"#,
            "\n",
        ),
    )
    .expect("write");

    let mut index = AgentSessionIndex::new(home.path().to_path_buf(), HashMap::new(), None);
    let outcome = index.refresh();
    assert_eq!(outcome.sessions.len(), 1);
    let session = &outcome.sessions[0];
    assert_eq!(session.id, "agy-session-42");
    assert_eq!(session.format, AgentTranscriptFormat::Agy);
    assert_eq!(session.profile_id, "agy");
    assert_eq!(session.title, "Implement Antigravity support");
    assert_eq!(session.cwd.as_deref(), Some("/tmp/work/soprano"));
    assert_eq!(session.model.as_deref(), Some("gemini-4-neon-high"));
    assert_eq!(session.subagent_count, 1);
    assert_eq!(session.resume_command(), "agy --resume agy-session-42");
    assert_eq!(session.short_agent_label(), "AGY");
    assert_eq!(session.last_message_role, Some(HistoryMessageRole::Assistant));
    assert_eq!(session.last_message_text.as_deref(), Some("Implemented full Antigravity support."));
}
