use std::collections::BTreeMap;

use chrono::{Duration, TimeZone, Utc};
use soprano_agents::*;
use soprano_types::AgentStatus;

fn entry(id: &str, parent: Option<&str>, items: Vec<AgentTimelineItem>) -> AgentTranscriptEntry {
    AgentTranscriptEntry { items, ..AgentTranscriptEntry::node(id, parent.map(str::to_owned)) }
}

fn results(id: &str, parent: &str, call: &str, state: ToolCallState) -> AgentTranscriptEntry {
    let mut results = BTreeMap::new();
    results.insert(call.to_owned(), AgentToolResult::new(state));
    AgentTranscriptEntry { results, ..AgentTranscriptEntry::node(id, Some(parent.to_owned())) }
}

fn prompt(id: &str, text: &str) -> AgentTimelineItem {
    AgentTimelineItem::new(id, None, TimelineItemKind::Prompt(text.into()))
}

fn reply(id: &str, text: &str) -> AgentTimelineItem {
    AgentTimelineItem::new(id, None, TimelineItemKind::Reply(text.into()))
}

fn tool(id: &str, name: &str) -> AgentTimelineItem {
    AgentTimelineItem::new(id, None, TimelineItemKind::Tool(AgentToolCall::new(name, "")))
}

fn states(timeline: &AgentTimeline) -> Vec<ToolCallState> {
    timeline.items.iter().filter_map(|i| i.tool_call()).map(|c| c.state).collect()
}

#[test]
fn parallel_tool_calls_hanging_off_each_other_stay_visible_while_a_rewound_turn_stays_hidden() {
    // Claude Code chains the second parallel call to the first and hangs each result off its
    // own call; the rewind replaced the prompt "p1" with "p2".
    let timeline = AgentTimeline::from_entries(&[
        entry("p0", None, vec![prompt("p0", "First question")]),
        entry("r0", Some("p0"), vec![reply("r0", "First answer")]),
        entry("p1", Some("r0"), vec![prompt("p1", "Old wording")]),
        entry("x1", Some("p1"), vec![reply("x1", "Abandoned answer")]),
        entry("p2", Some("r0"), vec![prompt("p2", "New wording")]),
        entry("c1", Some("p2"), vec![tool("call-1", "Read")]),
        entry("c2", Some("c1"), vec![tool("call-2", "Grep")]),
        results("res2", "c2", "call-2", ToolCallState::Succeeded),
        results("res1", "c1", "call-1", ToolCallState::Failed),
        entry("r2", Some("res1"), vec![reply("r2", "Done")]),
    ]);

    assert_eq!(
        timeline.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
        vec!["p0", "r0", "p2", "call-1", "call-2", "r2"]
    );
    assert_eq!(states(&timeline), vec![ToolCallState::Failed, ToolCallState::Succeeded]);
}

#[test]
fn calls_without_a_result_before_the_next_prompt_read_as_interrupted_unless_the_result_still_arrives() {
    let mut late = BTreeMap::new();
    late.insert("call-2".to_owned(), AgentToolResult::new(ToolCallState::Succeeded));
    let timeline = AgentTimeline::from_entries(&[
        AgentTranscriptEntry::with_items(vec![prompt("p1", "Build it")]),
        AgentTranscriptEntry::with_items(vec![tool("call-1", "Bash"), tool("call-2", "Bash")]),
        AgentTranscriptEntry::with_items(vec![prompt("p2", "Stop, run the tests instead")]),
        AgentTranscriptEntry { results: late, ..AgentTranscriptEntry::default() },
        AgentTranscriptEntry::with_items(vec![tool("call-3", "Bash")]),
    ]);

    assert_eq!(
        states(&timeline),
        vec![ToolCallState::Interrupted, ToolCallState::Succeeded, ToolCallState::Running]
    );
    assert_eq!(timeline.running_tool().map(|i| i.id.as_str()), Some("call-3"));
}

// AgentTimelineActivityTests (the attributed-string font checks are AppKit rendering details and
// are left to the UI).

#[test]
fn a_running_call_is_the_activity_with_its_command_and_elapsed_time() {
    let start = Utc.timestamp_opt(1_000, 0).single().expect("date");
    let call = AgentToolCall::new("Bash", "swift test");
    let timeline = AgentTimeline::from_entries(&[
        AgentTranscriptEntry::with_items(vec![prompt("p1", "Test it")]),
        AgentTranscriptEntry::with_items(vec![AgentTimelineItem::new(
            "c1",
            Some(start),
            TimelineItemKind::Tool(call),
        )]),
    ]);

    let activity =
        AgentTimelineActivity::current(Some(&timeline), AgentStatus::Running, start + Duration::seconds(38))
            .expect("activity");

    assert_eq!(activity.text(), "▶ Bash · swift test · 38s");
    assert_eq!(activity.tone, ActivityTone::Working);
    assert_eq!(activity.title, "Bash");
    assert_eq!(activity.code.as_deref(), Some("swift test"));
}

#[test]
fn a_long_activity_keeps_its_whole_detail_for_the_ui_to_truncate_on_one_line() {
    let detail = "I deployed dbeb77e to abtool: your #33 plus my #32. The selftest passes on the server, \
                  the dashboard API answers 200, and the server's main matches origin.";
    let activity = AgentTimelineActivity {
        detail: Some(detail.into()),
        ..AgentTimelineActivity::new("Asks", ActivityTone::Waiting)
    };

    assert_eq!(activity.text(), format!("Asks · {detail}"));
    assert!(!activity.text().contains('\n'));
}

#[test]
fn activity_durations_read_as_tenths_seconds_minutes_and_hours() {
    assert_eq!(activity_duration(2.4), "2.4s");
    assert_eq!(activity_duration(38.0), "38s");
    assert_eq!(activity_duration(185.0), "3m 05s");
    assert_eq!(activity_duration(3_720.0), "1h 02m");
}
