use soprano_agents::*;

fn timeline(lines: &[&str]) -> AgentTimeline {
    let mut decoder = ClaudeTranscriptDecoder::new();
    let entries: Vec<_> = lines.iter().filter_map(|l| decoder.entry_for_line(l.as_bytes())).collect();
    AgentTimeline::from_entries(&entries)
}

fn kinds(timeline: &AgentTimeline) -> Vec<TimelineItemKind> {
    timeline.items.iter().map(|i| i.kind.clone()).collect()
}

fn prompt(text: &str) -> TimelineItemKind {
    TimelineItemKind::Prompt(text.into())
}

fn reply(text: &str) -> TimelineItemKind {
    TimelineItemKind::Reply(text.into())
}

#[test]
fn typed_prompts_slash_commands_and_bash_mode_show_as_what_the_person_entered() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u1","parentUuid":null,"cwd":"/tmp/repo","timestamp":"2026-10-12T09:00:00.000Z","message":{"role":"user","content":"  Fix the login bug\n"}}"#,
        r#"{"type":"user","uuid":"u2","parentUuid":"u1","timestamp":"2026-10-12T09:01:00.000Z","message":{"role":"user","content":"<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>src/app tests</command-args>"}}"#,
        r#"{"type":"user","uuid":"u3","parentUuid":"u2","timestamp":"2026-10-12T09:02:00.000Z","message":{"role":"user","content":"<local-command-stdout>Reviewed</local-command-stdout>"}}"#,
        r#"{"type":"user","uuid":"u4","parentUuid":"u3","timestamp":"2026-10-12T09:03:00.000Z","message":{"role":"user","content":"<bash-input>git status</bash-input>"}}"#,
        r#"{"type":"user","uuid":"u5","parentUuid":"u4","timestamp":"2026-10-12T09:03:01.000Z","message":{"role":"user","content":"<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>"}}"#,
    ]);

    assert_eq!(
        kinds(&timeline),
        vec![prompt("Fix the login bug"), prompt("/review src/app tests"), prompt("! git status")]
    );
    assert_eq!(timeline.items[0].timestamp, parse_date("2026-10-12T09:00:00.000Z"));
}

#[test]
fn meta_records_stay_hidden_but_keep_the_branch_connected() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Hello"}}"#,
        r#"{"type":"user","uuid":"m1","parentUuid":"u1","isMeta":true,"message":{"role":"user","content":"Injected skill instructions"}}"#,
        r#"{"type":"attachment","uuid":"a1","parentUuid":"m1","attachment":{"type":"todo"}}"#,
        r#"{"type":"assistant","uuid":"r1","parentUuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Hi there"}]}}"#,
    ]);

    assert_eq!(kinds(&timeline), vec![prompt("Hello"), reply("Hi there")]);
}

#[test]
fn sidechain_and_session_bookkeeping_records_are_not_part_of_the_timeline() {
    let mut decoder = ClaudeTranscriptDecoder::new();
    let sidechain = r#"{"type":"assistant","uuid":"s1","parentUuid":"u1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"Subagent says hi"}]}}"#;
    let title = r#"{"type":"ai-title","sessionId":"abc","aiTitle":"Fix login"}"#;
    let summary = r#"{"type":"summary","summary":"Earlier work","leafUuid":"u1"}"#;

    assert_eq!(decoder.entry_for_line(sidechain.as_bytes()), None);
    assert_eq!(decoder.entry_for_line(title.as_bytes()), None);
    assert_eq!(decoder.entry_for_line(summary.as_bytes()), None);
    assert_eq!(decoder.entry_for_line(b"not json"), None);
}

#[test]
fn thinking_and_replies_show_in_order_with_empty_text_skipped() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Why?"}}"#,
        r#"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Considering the cause","signature":"x"}]}}"#,
        r#"{"type":"assistant","uuid":"r2","parentUuid":"r1","message":{"role":"assistant","content":[{"type":"redacted_thinking","data":"opaque"}]}}"#,
        r#"{"type":"assistant","uuid":"r3","parentUuid":"r2","message":{"role":"assistant","content":[{"type":"text","text":"\n\n"},{"type":"text","text":"Because **cache**."}]}}"#,
    ]);

    assert_eq!(
        kinds(&timeline),
        vec![
            prompt("Why?"),
            TimelineItemKind::Thinking("Considering the cause".into()),
            TimelineItemKind::Thinking(String::new()),
            reply("Because **cache**."),
        ]
    );
}

#[test]
fn tool_calls_show_their_subject_and_finish_with_their_result() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u1","parentUuid":null,"cwd":"/tmp/repo","message":{"role":"user","content":"Look around"}}"#,
        r#"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/repo/Sources/App.swift"}}]}}"#,
        r#"{"type":"assistant","uuid":"r2","parentUuid":"r1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"TODO","path":"/tmp/repo/Sources"}}]}}"#,
        r#"{"type":"user","uuid":"u2","parentUuid":"r2","timestamp":"2026-10-12T09:05:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"1\tlet app = App()"}]}}"#,
        r#"{"type":"user","uuid":"u3","parentUuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"Path does not exist"}]}]}}"#,
    ]);

    let read = timeline.items[1].tool_call().expect("read call");
    assert_eq!(read.name, "Read");
    assert_eq!(read.summary, "Sources/App.swift");
    assert_eq!(read.state, ToolCallState::Succeeded);
    assert_eq!(read.output.as_deref(), Some("1\tlet app = App()"));
    assert_eq!(read.finished_at, parse_date("2026-10-12T09:05:00.000Z"));

    let grep = timeline.items[2].tool_call().expect("grep call");
    assert_eq!(grep.summary, "TODO in Sources");
    assert_eq!(grep.state, ToolCallState::Failed);
    assert_eq!(grep.output.as_deref(), Some("Path does not exist"));
    assert_eq!(timeline.items.len(), 3);
}

#[test]
fn mcp_tools_show_server_and_tool_and_their_most_telling_argument() {
    let timeline = timeline(&[
        r#"{"type":"assistant","uuid":"r1","parentUuid":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__chrome-devtools__navigate_page","input":{"type":"url","url":"https://example.com"}}]}}"#,
    ]);

    let call = timeline.items[0].tool_call().expect("call");
    assert_eq!(call.name, "chrome-devtools · navigate_page");
    assert_eq!(call.summary, "https://example.com");
    assert_eq!(call.state, ToolCallState::Running);
}

#[test]
fn edit_results_show_their_structured_patch_as_a_diff() {
    let timeline = timeline(&[
        r#"{"type":"assistant","uuid":"r1","parentUuid":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/tmp/repo/a.swift","old_string":"old","new_string":"new"}}]}}"#,
        r#"{"type":"user","uuid":"u1","parentUuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"The file /tmp/repo/a.swift has been updated."}]},"toolUseResult":{"filePath":"/tmp/repo/a.swift","oldString":"old","newString":"new","structuredPatch":[{"oldStart":3,"oldLines":2,"newStart":3,"newLines":2,"lines":[" let x = 1","-old","+new"]}]}}"#,
    ]);

    let call = timeline.items[0].tool_call().expect("call");
    assert_eq!(call.state, ToolCallState::Succeeded);
    assert_eq!(call.diff.as_deref(), Some("@@ -3,2 +3,2 @@\n let x = 1\n-old\n+new"));
    assert_eq!(call.output, None);
}

#[test]
fn created_files_show_every_line_as_an_addition() {
    let timeline = timeline(&[
        r#"{"type":"assistant","uuid":"r1","parentUuid":null,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/repo/notes.txt","content":"one\ntwo\n"}}]}}"#,
        r#"{"type":"user","uuid":"u1","parentUuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"File created successfully"}]},"toolUseResult":{"type":"create","filePath":"/tmp/repo/notes.txt","content":"one\ntwo\n","structuredPatch":[],"originalFile":null}}"#,
    ]);

    let call = timeline.items[0].tool_call().expect("call");
    assert_eq!(call.summary, "/tmp/repo/notes.txt");
    assert_eq!(call.diff.as_deref(), Some("+one\n+two"));
    assert_eq!(call.output, None);
}

#[test]
fn bash_results_show_both_streams_and_an_interrupted_command_says_so() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u0","parentUuid":null,"cwd":"/tmp/repo","message":{"role":"user","content":"Run checks"}}"#,
        r#"{"type":"assistant","uuid":"r1","parentUuid":"u0","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make test","description":"Run the test suite"}}]}}"#,
        r#"{"type":"user","uuid":"u1","parentUuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ignored"}]},"toolUseResult":{"stdout":"3 passed","stderr":"1 warning","interrupted":false,"isImage":false}}"#,
        r#"{"type":"assistant","uuid":"r2","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"sleep 100"}}]}}"#,
        r#"{"type":"user","uuid":"u2","parentUuid":"r2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ignored"}]},"toolUseResult":{"stdout":"","stderr":"","interrupted":true,"isImage":false}}"#,
        r#"{"type":"user","uuid":"u3","parentUuid":"u2","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
    ]);

    let tests = timeline.items[1].tool_call().expect("tests");
    assert_eq!(tests.summary, "Run the test suite");
    assert_eq!(tests.detail.as_deref(), Some("make test"));
    assert_eq!(tests.output.as_deref(), Some("3 passed\n1 warning"));
    assert_eq!(tests.state, ToolCallState::Succeeded);

    let sleep = timeline.items[2].tool_call().expect("sleep");
    assert_eq!(sleep.summary, "sleep 100");
    assert_eq!(sleep.detail, None);
    assert_eq!(sleep.state, ToolCallState::Interrupted);
    assert_eq!(
        timeline.items.last().map(|i| i.kind.clone()),
        Some(TimelineItemKind::notice("Interrupted", false))
    );
}

#[test]
fn compaction_shows_a_notice_and_keeps_the_history_before_it() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Long task"}}"#,
        r#"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"Working on it"}]}}"#,
        r#"{"type":"system","subtype":"compact_boundary","uuid":"c1","parentUuid":null,"logicalParentUuid":"r1","content":"Conversation compacted","level":"info","compactMetadata":{"trigger":"auto"}}"#,
        r#"{"type":"user","uuid":"u2","parentUuid":"c1","isMeta":true,"message":{"role":"user","content":"Summary of the earlier conversation"}}"#,
        r#"{"type":"assistant","uuid":"r2","parentUuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"Continuing"}]}}"#,
    ]);

    assert_eq!(
        kinds(&timeline),
        vec![
            prompt("Long task"),
            reply("Working on it"),
            TimelineItemKind::notice("Conversation compacted", false),
            reply("Continuing"),
        ]
    );
}

#[test]
fn api_errors_and_local_commands_show_as_notices() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Hi"}}"#,
        r#"{"type":"assistant","uuid":"e1","parentUuid":"u1","isApiErrorMessage":true,"error":"server_error","message":{"role":"assistant","content":[{"type":"text","text":"API Error: overloaded"}]}}"#,
        r#"{"type":"system","subtype":"local_command","uuid":"s1","parentUuid":"e1","level":"info","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"}"#,
        r#"{"type":"system","subtype":"turn_duration","uuid":"s2","parentUuid":"s1","durationMs":1200}"#,
    ]);

    assert_eq!(
        kinds(&timeline),
        vec![
            prompt("Hi"),
            TimelineItemKind::notice("API Error: overloaded", true),
            TimelineItemKind::notice("/model", false),
        ]
    );
}

#[test]
fn rewinding_shows_only_the_newer_branch() {
    let timeline = timeline(&[
        r#"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Start"}}"#,
        r#"{"type":"assistant","uuid":"r1","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"Ready"}]}}"#,
        r#"{"type":"user","uuid":"u2","parentUuid":"r1","message":{"role":"user","content":"Try plan A"}}"#,
        r#"{"type":"assistant","uuid":"r2","parentUuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"Plan A done"}]}}"#,
        r#"{"type":"user","uuid":"u3","parentUuid":"r1","message":{"role":"user","content":"Try plan B instead"}}"#,
        r#"{"type":"assistant","uuid":"r3","parentUuid":"u3","message":{"role":"assistant","content":[{"type":"text","text":"Plan B done"}]}}"#,
        r#"{"type":"last-prompt","lastPrompt":"Try plan B instead"}"#,
    ]);

    assert_eq!(
        kinds(&timeline),
        vec![prompt("Start"), reply("Ready"), prompt("Try plan B instead"), reply("Plan B done")]
    );
}
