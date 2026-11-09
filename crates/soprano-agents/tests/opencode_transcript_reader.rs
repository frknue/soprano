use std::collections::HashMap;
use std::path::{Path, PathBuf};

use soprano_agents::*;
use soprano_types::AgentConversation;

const SESSION_ID: &str = "ses_test1";

/// The columns of OpenCode 2.x's tables the reader uses.
const CURRENT_SCHEMA: &str = "
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT NOT NULL, revert TEXT, time_updated INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE session_message (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
    );
    CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
    CREATE TABLE session_part (
        message_id TEXT NOT NULL, session_id TEXT NOT NULL, ordinal INTEGER NOT NULL, type TEXT NOT NULL,
        call_id TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL,
        PRIMARY KEY (message_id, ordinal)
    );
";

/// The columns of OpenCode 1.x's tables the reader uses.
const LEGACY_SCHEMA: &str = "
    CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL, revert TEXT);
    CREATE TABLE message (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
    );
    CREATE TABLE part (
        id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
    );
";

fn message(id: &str, seq: i64, kind: &str, updated: i64, data: &str) -> String {
    format!(
        "INSERT INTO session_message VALUES ('{id}', '{SESSION_ID}', '{kind}', {seq}, {updated}, {updated}, '{data}');"
    )
}

/// A temporary home holding the database the plugin reports.
struct Fixture {
    home: tempfile::TempDir,
    path: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let home = tempfile::tempdir().expect("temp dir");
        let path = home.path().join("reported.db");
        Self { home, path }
    }

    fn reader(&self) -> OpenCodeTranscriptReader {
        let conversation = AgentConversation {
            id: SESSION_ID.into(),
            cwd: None,
            transcript_path: Some(self.path.to_string_lossy().into_owned()),
        };
        let source = AgentTranscriptSource::new("opencode", Some(&conversation)).expect("source");
        OpenCodeTranscriptReader::with_environment(source, self.home.path(), HashMap::new())
    }

    fn exec(&self, sql: &str) {
        exec_at(&self.path, sql);
    }
}

fn exec_at(path: &Path, sql: &str) {
    let connection = rusqlite::Connection::open(path).expect("open");
    connection.execute_batch(sql).expect("sql");
}

fn kinds(timeline: Option<AgentTimeline>) -> Option<Vec<TimelineItemKind>> {
    timeline.map(|t| t.items.into_iter().map(|i| i.kind).collect())
}

fn prompt(text: &str) -> TimelineItemKind {
    TimelineItemKind::Prompt(text.into())
}

fn reply(text: &str) -> TimelineItemKind {
    TimelineItemKind::Reply(text.into())
}

#[test]
fn a_streaming_assistant_message_updates_its_items_in_place() {
    let fixture = Fixture::new();
    fixture.exec(&format!(
        "{CURRENT_SCHEMA}
        INSERT INTO session_v2 (id, directory) VALUES ('{SESSION_ID}', '/work/repo');
        {}
        {}",
        message("msg_1", 1, "user", 100, r#"{"text":"Run the tests","time":{"created":100}}"#),
        message(
            "msg_2",
            2,
            "assistant",
            101,
            r#"{"time":{"created":101},"content":[{"type":"tool","id":"call_1","name":"shell","state":{"status":"running","input":{"command":"swift test"},"metadata":{}},"time":{"created":101}}]}"#
        ),
    ));
    let mut reader = fixture.reader();

    let first = reader.read_appended().expect("first read");
    assert_eq!(first.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["msg_1", "call_1"]);
    assert_eq!(first.items.last().and_then(|i| i.tool_call()).map(|c| c.state), Some(ToolCallState::Running));

    fixture.exec(
        r#"UPDATE session_message SET time_updated = 105, data = '{"time":{"created":101},"content":[{"type":"tool","id":"call_1","name":"shell","state":{"status":"completed","input":{"command":"swift test"},"content":[{"type":"text","text":"All passed"}],"metadata":{"exit":0}},"time":{"created":101,"completed":105}},{"type":"text","text":"Green."}]}'
        WHERE id = 'msg_2';"#,
    );
    let second = reader.read_appended().expect("second read");
    assert_eq!(
        second.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
        vec!["msg_1", "call_1", "msg_2#1"]
    );
    assert_eq!(second.items[1].tool_call().map(|c| c.state), Some(ToolCallState::Succeeded));
    assert_eq!(second.items[1].tool_call().and_then(|c| c.output.as_deref()), Some("All passed"));
    assert_eq!(second.items[2].kind, reply("Green."));
}

#[test]
fn a_rewrite_in_the_same_millisecond_as_the_last_read_still_shows() {
    let fixture = Fixture::new();
    fixture.exec(&format!(
        "{CURRENT_SCHEMA}
        INSERT INTO session_v2 (id, directory) VALUES ('{SESSION_ID}', '/work/repo');
        {}",
        message(
            "msg_1",
            1,
            "assistant",
            100,
            r#"{"time":{"created":100},"content":[{"type":"text","text":"Half a"}]}"#
        ),
    ));
    let mut reader = fixture.reader();
    assert_eq!(kinds(reader.read_appended()), Some(vec![reply("Half a")]));

    fixture.exec(
        r#"UPDATE session_message SET data = '{"time":{"created":100},"content":[{"type":"text","text":"Half a reply."}]}' WHERE id = 'msg_1';"#,
    );
    assert_eq!(kinds(reader.read_appended()), Some(vec![reply("Half a reply.")]));
}

#[test]
fn an_unchanged_database_reads_as_nothing_new() {
    let fixture = Fixture::new();
    fixture.exec(&format!(
        "{CURRENT_SCHEMA}
        INSERT INTO session_v2 (id, directory) VALUES ('{SESSION_ID}', '/work/repo');
        {}",
        message("msg_1", 1, "user", 100, r#"{"text":"Hello","time":{"created":100}}"#),
    ));
    let mut reader = fixture.reader();
    assert_eq!(kinds(reader.read_appended()), Some(vec![prompt("Hello")]));
    assert_eq!(reader.read_appended(), None);

    fixture.exec(&message("msg_2", 3, "user", 200, r#"{"text":"Again","time":{"created":200}}"#));
    assert_eq!(kinds(reader.read_appended()), Some(vec![prompt("Hello"), prompt("Again")]));
    assert_eq!(reader.read_appended(), None);
}

#[test]
fn rewinding_hides_the_message_it_returned_to_and_everything_after() {
    let fixture = Fixture::new();
    fixture.exec(&format!(
        "{CURRENT_SCHEMA}
        INSERT INTO session_v2 (id, directory) VALUES ('{SESSION_ID}', '/work/repo');
        {}
        {}
        {}
        {}",
        message("msg_1", 1, "user", 100, r#"{"text":"Plan it","time":{"created":100}}"#),
        message(
            "msg_2",
            2,
            "assistant",
            101,
            r#"{"time":{"created":101},"content":[{"type":"text","text":"Here is a plan."}]}"#
        ),
        message("msg_3", 4, "user", 102, r#"{"text":"Old direction","time":{"created":102}}"#),
        message(
            "msg_4",
            5,
            "assistant",
            103,
            r#"{"time":{"created":103},"content":[{"type":"text","text":"Going the old way."}]}"#
        ),
    ));
    let mut reader = fixture.reader();
    assert_eq!(reader.read_appended().map(|t| t.items.len()), Some(4));

    fixture.exec(&format!(
        r#"UPDATE session_v2 SET revert = '{{"messageID":"msg_3"}}' WHERE id = '{SESSION_ID}';"#
    ));
    assert_eq!(kinds(reader.read_appended()), Some(vec![prompt("Plan it"), reply("Here is a plan.")]));

    // Committing the rewind deletes the hidden rows and clears it.
    fixture.exec(&format!(
        "DELETE FROM session_message WHERE seq >= 4;
        UPDATE session_v2 SET revert = NULL WHERE id = '{SESSION_ID}';
        {}",
        message("msg_5", 6, "user", 300, r#"{"text":"New direction","time":{"created":300}}"#),
    ));
    assert_eq!(
        kinds(reader.read_appended()),
        Some(vec![prompt("Plan it"), reply("Here is a plan."), prompt("New direction")])
    );
}

#[test]
fn part_rows_override_an_assistant_messages_inline_content_and_their_updates_show() {
    let fixture = Fixture::new();
    fixture.exec(&format!(
        r#"{CURRENT_SCHEMA}
        INSERT INTO session_v2 (id, directory) VALUES ('{SESSION_ID}', '/work/repo');
        {}
        INSERT INTO session_part VALUES ('msg_1', '{SESSION_ID}', 0, 'reasoning', NULL, 100, 100, '{{"text":"Plan first."}}');
        INSERT INTO session_part VALUES ('msg_1', '{SESSION_ID}', 1, 'tool', 'call_1', 100, 100, '{{"id":"call_1","name":"read","state":{{"status":"running","input":{{"path":"/work/repo/App.swift"}},"metadata":{{}}}},"time":{{"created":100}}}}');"#,
        message("msg_1", 1, "assistant", 100, r#"{"time":{"created":100},"content":[]}"#),
    ));
    let mut reader = fixture.reader();
    assert_eq!(
        kinds(reader.read_appended()),
        Some(vec![
            TimelineItemKind::Thinking("Plan first.".into()),
            TimelineItemKind::Tool(AgentToolCall::new("Read", "App.swift")),
        ])
    );

    // Only the part changes; its message row keeps its old time.
    fixture.exec(
        r#"UPDATE session_part SET time_updated = 150, data = '{"id":"call_1","name":"read","state":{"status":"completed","input":{"path":"/work/repo/App.swift"},"content":[{"type":"text","text":"1: import AppKit"}]},"time":{"created":100,"completed":150}}'
        WHERE message_id = 'msg_1' AND ordinal = 1;"#,
    );
    let second = reader.read_appended().expect("second read");
    let call = second.items.last().and_then(|i| i.tool_call()).expect("call");
    assert_eq!(call.state, ToolCallState::Succeeded);
    assert_eq!(call.output.as_deref(), Some("1: import AppKit"));
}

#[test]
fn the_database_is_found_in_open_codes_data_directory_when_the_reported_one_lacks_the_session() {
    let fixture = Fixture::new();
    fixture.exec(&format!(
        "{CURRENT_SCHEMA}\nINSERT INTO session_v2 (id, directory) VALUES ('ses_other', '/elsewhere');"
    ));
    let data_directory = fixture.home.path().join(".local/share/opencode");
    std::fs::create_dir_all(&data_directory).expect("data dir");
    let found = data_directory.join("opencode-beta.db");
    exec_at(
        &found,
        &format!(
            "{CURRENT_SCHEMA}
            INSERT INTO session_v2 (id, directory) VALUES ('{SESSION_ID}', '/work/repo');
            {}",
            message("msg_1", 1, "user", 100, r#"{"text":"Found me","time":{"created":100}}"#),
        ),
    );

    let mut reader = fixture.reader();
    assert_eq!(kinds(reader.read_appended()), Some(vec![prompt("Found me")]));
}

#[test]
fn sessions_still_in_open_code_1_tables_read_from_messages_and_parts() {
    let fixture = Fixture::new();
    fixture.exec(&format!(
        r#"{LEGACY_SCHEMA}
        INSERT INTO session (id, directory) VALUES ('{SESSION_ID}', '/work/repo');
        INSERT INTO message VALUES ('msg_1', '{SESSION_ID}', 100, 100, '{{"role":"user","time":{{"created":100}}}}');
        INSERT INTO part VALUES ('prt_1', 'msg_1', '{SESSION_ID}', 100, 100, '{{"type":"text","text":"Fix the build"}}');
        INSERT INTO message VALUES ('msg_2', '{SESSION_ID}', 101, 101, '{{"role":"assistant","time":{{"created":101}}}}');
        INSERT INTO part VALUES ('prt_2', 'msg_2', '{SESSION_ID}', 101, 101, '{{"type":"tool","tool":"bash","callID":"call_1","state":{{"status":"running","input":{{"command":"swift build"}},"time":{{"start":101}}}}}}');"#
    ));
    let mut reader = fixture.reader();
    assert_eq!(
        kinds(reader.read_appended()),
        Some(vec![
            prompt("Fix the build"),
            TimelineItemKind::Tool(AgentToolCall::new("Bash", "swift build"))
        ])
    );

    // 1.x streams into part rows and leaves the message row alone.
    fixture.exec(&format!(
        r#"UPDATE part SET time_updated = 200, data = '{{"type":"tool","tool":"bash","callID":"call_1","state":{{"status":"completed","input":{{"command":"swift build"}},"output":"Build complete!","metadata":{{"exit":0}},"time":{{"start":101,"end":200}}}}}}' WHERE id = 'prt_2';
        INSERT INTO part VALUES ('prt_3', 'msg_2', '{SESSION_ID}', 200, 200, '{{"type":"text","text":"Fixed."}}');"#
    ));
    let second = reader.read_appended().expect("second read");
    assert_eq!(
        second.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
        vec!["msg_1", "call_1", "msg_2#1"]
    );
    assert_eq!(second.items[1].tool_call().and_then(|c| c.output.as_deref()), Some("Build complete!"));
    assert_eq!(second.items[2].kind, reply("Fixed."));
}
