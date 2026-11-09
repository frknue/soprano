use chrono::{Duration, TimeZone, Utc};
use soprano_agents::*;

fn start() -> Date {
    Utc.timestamp_opt(1_000, 0).single().expect("date")
}

fn item(id: &str, seconds: i64, kind: TimelineItemKind) -> AgentTimelineItem {
    AgentTimelineItem::new(id, Some(start() + Duration::seconds(seconds)), kind)
}

#[test]
fn each_prompt_starts_a_turn_and_a_finished_turns_last_reply_is_its_answer() {
    let bash = AgentToolCall {
        state: ToolCallState::Succeeded,
        output: Some("ok".into()),
        finished_at: Some(start() + Duration::seconds(40)),
        ..AgentToolCall::new("Bash", "swift build")
    };
    let timeline = AgentTimeline::new(vec![
        item("p1", 0, TimelineItemKind::Prompt("Fix the build".into())),
        item("r1", 5, TimelineItemKind::Reply("Looking at it.".into())),
        item("c1", 10, TimelineItemKind::Tool(bash)),
        item("r2", 72, TimelineItemKind::Reply("Fixed.".into())),
        item("p2", 100, TimelineItemKind::Prompt("Now the tests".into())),
        item("t2", 103, TimelineItemKind::Thinking("Running the suite.".into())),
    ]);

    let thread = ChatThread::from_transcript(&timeline, true);

    assert_eq!(
        thread.turns.iter().map(|t| t.user_message.text.as_str()).collect::<Vec<_>>(),
        vec!["Fix the build", "Now the tests"]
    );
    let first = &thread.turns[0];
    assert_eq!(first.status, TurnStatus::Completed);
    assert_eq!(first.started_at, Some(start()));
    assert_eq!(first.completed_at, Some(start() + Duration::seconds(72)));
    assert_eq!(first.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["r1", "c1", "r2"]);
    assert_eq!(
        first.items[0].kind,
        TurnItemKind::AssistantMessage { text: "Looking at it.".into(), is_final: false }
    );
    assert_eq!(first.items[2].kind, TurnItemKind::AssistantMessage { text: "Fixed.".into(), is_final: true });
    assert_eq!(first.items[1].kind, TurnItemKind::Command(TurnCommand::new("swift build", "ok", Some(0))));
    // The "Worked for" fold of the finished turn.
    let worked = first.duration_seconds(start()).expect("duration");
    assert_eq!(format!("Worked for {}", turn_duration_text(worked)), "Worked for 1m 12s");
    // The agent still works on the newest turn.
    assert_eq!(thread.turns[1].status, TurnStatus::Running);
    assert_eq!(thread.turns[1].completed_at, None);
    assert_eq!(
        thread.turns[1].items.iter().map(|i| i.kind.clone()).collect::<Vec<_>>(),
        vec![TurnItemKind::Reasoning { text: "Running the suite.".into() }]
    );
    assert!(thread.is_running());
}

#[test]
fn the_clis_tool_names_read_as_commands_edits_reads_searches_and_the_rest() {
    let kind = |call: AgentToolCall| ChatThread::kind_of(&call);

    assert_eq!(
        kind(AgentToolCall {
            detail: Some("cd x && cargo test".into()),
            state: ToolCallState::Failed,
            ..AgentToolCall::new("Run", "cargo test")
        }),
        TurnItemKind::Command(TurnCommand::new("cd x && cargo test", "", Some(1)))
    );
    assert_eq!(
        kind(AgentToolCall {
            diff: Some("@@ -1 +1 @@\n-a\n+b".into()),
            ..AgentToolCall::new("Edit", "Sources/App.swift")
        }),
        TurnItemKind::FileChange(vec![FileChange::with_diff(
            "Sources/App.swift",
            FileChangeKind::Update,
            Some("@@ -1 +1 @@\n-a\n+b".into())
        )])
    );
    assert_eq!(
        kind(AgentToolCall { diff: Some("+one".into()), ..AgentToolCall::new("Write", "notes.txt") }),
        TurnItemKind::FileChange(vec![FileChange {
            is_full_content: Some(true),
            ..FileChange::with_diff("notes.txt", FileChangeKind::Update, Some("+one".into()))
        }])
    );
    assert_eq!(
        kind(AgentToolCall::new("Read", "README.md")),
        TurnItemKind::ToolCall(ToolCall::new("Read", ToolCategory::Read, "Read README.md"))
    );
    assert_eq!(
        kind(AgentToolCall::new("Grep", "TODO in Sources")),
        TurnItemKind::ToolCall(ToolCall::new("Grep", ToolCategory::Search, "Searched TODO in Sources"))
    );
    assert_eq!(
        kind(AgentToolCall::new("WebSearch", "swift testing")),
        TurnItemKind::WebSearch { query: "swift testing".into() }
    );
    assert_eq!(
        kind(AgentToolCall::new("Task", "Audit the repo")),
        TurnItemKind::ToolCall(ToolCall::new("Task", ToolCategory::Subagent, "Subagent: Audit the repo"))
    );
    assert_eq!(
        kind(AgentToolCall::new("Todo", "3 todos")),
        TurnItemKind::ToolCall(ToolCall::new("Todo", ToolCategory::Other, "Todo 3 todos"))
    );
}

#[test]
fn a_codex_change_to_several_files_becomes_one_diff_per_file() {
    let call = AgentToolCall {
        diff: Some("diff a.swift\n@@ -1 +1 @@\n-a\n+b\ndiff b.swift\n@@ -2 +2 @@\n-c\n+d".into()),
        ..AgentToolCall::new("Edit", "a.swift +1 more")
    };

    assert_eq!(
        ChatThread::kind_of(&call),
        TurnItemKind::FileChange(vec![
            FileChange::with_diff("a.swift", FileChangeKind::Update, Some("@@ -1 +1 @@\n-a\n+b".into())),
            FileChange::with_diff("b.swift", FileChangeKind::Update, Some("@@ -2 +2 @@\n-c\n+d".into())),
        ])
    );
    // A git-style diff of one file is not split.
    let git = AgentToolCall {
        diff: Some("diff --git a/a.swift b/a.swift\n@@ -1 +1 @@\n-a\n+b".into()),
        ..AgentToolCall::new("Edit", "a.swift")
    };
    assert_eq!(
        ChatThread::kind_of(&git),
        TurnItemKind::FileChange(vec![FileChange::with_diff(
            "a.swift",
            FileChangeKind::Update,
            git.diff.clone()
        )])
    );
}

#[test]
fn work_before_the_first_kept_prompt_opens_a_turn_without_a_message_and_notices_stay_above() {
    let timeline = AgentTimeline::new(vec![
        item("n1", 0, TimelineItemKind::notice("Context compacted", false)),
        item("r0", 1, TimelineItemKind::Reply("…and that finishes the refactor.".into())),
        item("p1", 5, TimelineItemKind::Prompt("Ship it".into())),
    ]);

    let thread = ChatThread::from_transcript(&timeline, false);

    assert_eq!(
        thread.preamble.iter().map(|i| i.kind.clone()).collect::<Vec<_>>(),
        vec![TurnItemKind::Notice { text: "Context compacted".into() }]
    );
    assert_eq!(
        thread.turns.iter().map(|t| t.user_message.text.as_str()).collect::<Vec<_>>(),
        vec!["", "Ship it"]
    );
    assert_eq!(thread.turns[0].id, "transcript-head");
    assert_eq!(thread.turns[0].items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["r0"]);
}
