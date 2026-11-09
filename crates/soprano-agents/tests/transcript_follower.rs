use std::collections::HashMap;
use std::sync::mpsc;
use std::time::Duration;

use soprano_agents::*;
use soprano_types::AgentConversation;

fn conversation(id: &str, path: &std::path::Path) -> AgentConversation {
    AgentConversation { id: id.into(), cwd: None, transcript_path: Some(path.to_string_lossy().into_owned()) }
}

#[test]
fn a_transcript_read_from_its_tail_still_knows_the_session_directory_from_its_header() {
    let directory = tempfile::tempdir().expect("temp dir");
    let file = directory.path().join("session.jsonl");

    let filler = format!(r#"{{"type":"title","title":"{}"}}"#, "x".repeat(1_000));
    let mut lines = vec![
        r#"{"type":"session","version":3,"id":"sess-1","timestamp":"2026-10-12T09:00:00.000Z","cwd":"/work/repo"}"#.to_owned(),
    ];
    lines.extend(std::iter::repeat_n(filler, (TranscriptFollower::INITIAL_WINDOW / 1_000) as usize + 100));
    lines.extend([
        r#"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Read it"}]}}"#.to_owned(),
        r#"{"type":"message","id":"u2","parentId":"u1","timestamp":"2026-10-12T09:00:02.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Again"}]}}"#.to_owned(),
        r#"{"type":"message","id":"a1","parentId":"u2","timestamp":"2026-10-12T09:00:03.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-r","name":"read","arguments":{"path":"/work/repo/Sources/App.swift"}}]}}"#.to_owned(),
    ]);
    std::fs::write(&file, lines.join("\n") + "\n").expect("write");

    let source = AgentTranscriptSource::new("omp", Some(&conversation("sess-1", &file))).expect("source");
    let timeline = source.make_reader(directory.path()).read_appended().expect("timeline");

    assert_eq!(
        timeline.items.last().and_then(|i| i.tool_call()).map(|c| c.summary.as_str()),
        Some("Sources/App.swift")
    );
}

#[test]
fn appended_lines_are_read_once_and_a_partial_line_waits_for_its_end() {
    let directory = tempfile::tempdir().expect("temp dir");
    let file = directory.path().join("session.jsonl");
    std::fs::write(
        &file,
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"One\"}}\n",
    )
    .expect("write");
    let source = AgentTranscriptSource::new("omp", Some(&conversation("sess-2", &file))).expect("source");
    let mut reader = source.make_reader(directory.path());
    assert_eq!(reader.read_appended().map(|t| t.items.len()), Some(1));
    assert_eq!(reader.read_appended(), None);

    use std::io::Write;
    let mut handle = std::fs::OpenOptions::new().append(true).open(&file).expect("open");
    handle
        .write_all(b"{\"type\":\"message\",\"id\":\"u2\",\"parentId\":\"u1\",\"message\":")
        .expect("append");
    assert_eq!(reader.read_appended(), None);
    handle.write_all(b"{\"role\":\"user\",\"content\":\"Two\"}}\n").expect("append");
    let timeline = reader.read_appended().expect("timeline");
    assert_eq!(timeline.items.last().map(|i| i.kind.clone()), Some(TimelineItemKind::Prompt("Two".into())));
}

#[test]
fn transcripts_without_a_reported_path_are_located_in_the_clis_session_directories() {
    let home = tempfile::tempdir().expect("home");
    let claude = home.path().join(".claude/projects/-work-repo");
    std::fs::create_dir_all(&claude).expect("dir");
    std::fs::write(claude.join("abc-123.jsonl"), "").expect("write");
    let codex = home.path().join(".codex/sessions/2026/10/12");
    std::fs::create_dir_all(&codex).expect("dir");
    std::fs::write(codex.join("rollout-2026-10-12T09-00-00-thread-9.jsonl"), "").expect("write");
    let omp = home.path().join(".omp/agent/sessions/-work-repo");
    std::fs::create_dir_all(&omp).expect("dir");
    std::fs::write(omp.join("2026-10-12_sess-7.jsonl"), "").expect("write");

    assert_eq!(
        AgentTranscriptLocator::transcript_path(AgentTranscriptFormat::ClaudeCode, "abc-123", home.path()),
        Some(claude.join("abc-123.jsonl"))
    );
    assert_eq!(
        AgentTranscriptLocator::transcript_path(AgentTranscriptFormat::Codex, "thread-9", home.path()),
        Some(codex.join("rollout-2026-10-12T09-00-00-thread-9.jsonl"))
    );
    assert_eq!(
        AgentTranscriptLocator::transcript_path(AgentTranscriptFormat::Omp, "sess-7", home.path()),
        Some(omp.join("2026-10-12_sess-7.jsonl"))
    );
    assert_eq!(
        AgentTranscriptLocator::transcript_path(AgentTranscriptFormat::Omp, "../escape", home.path()),
        None
    );
    assert_eq!(
        AgentTranscriptLocator::transcript_path(AgentTranscriptFormat::OpenCode, "sess-7", home.path()),
        None
    );
}

#[test]
fn the_store_reports_a_tracked_transcript_and_picks_up_what_it_gains() {
    let directory = tempfile::tempdir().expect("temp dir");
    let file = directory.path().join("session.jsonl");
    std::fs::write(&file, "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"One\"}}\n")
        .expect("write");

    let store = AgentTranscriptStore::with_home(directory.path().to_path_buf());
    let (changed, changes) = mpsc::channel::<String>();
    store.set_on_change(move |id| {
        let _ = changed.send(id.to_owned());
    });
    let source = AgentTranscriptSource::new("omp", Some(&conversation("sess-3", &file))).expect("source");
    store.track(HashMap::from([("pane:tab".to_owned(), source)]));
    assert!(store.is_tracking("pane:tab"));

    assert_eq!(changes.recv_timeout(Duration::from_secs(5)).ok().as_deref(), Some("pane:tab"));
    assert_eq!(store.timeline("pane:tab").map(|t| t.items.len()), Some(1));

    use std::io::Write;
    let mut handle = std::fs::OpenOptions::new().append(true).open(&file).expect("open");
    handle
        .write_all(b"{\"type\":\"message\",\"id\":\"u2\",\"parentId\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"Two\"}}\n")
        .expect("append");
    store.refresh();
    assert_eq!(changes.recv_timeout(Duration::from_secs(5)).ok().as_deref(), Some("pane:tab"));
    assert_eq!(store.timeline("pane:tab").map(|t| t.items.len()), Some(2));

    store.track(HashMap::new());
    assert!(!store.is_tracking("pane:tab"));
    assert_eq!(store.timeline("pane:tab"), None);
}

#[test]
fn closing_the_store_does_not_wait_for_queued_reads() {
    let directory = tempfile::tempdir().expect("temp dir");
    let file = directory.path().join("session.jsonl");
    let line = "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"One\"}}\n";
    std::fs::write(&file, line.repeat(20_000)).expect("write");
    let store = AgentTranscriptStore::with_home(directory.path().to_path_buf());
    let sources: HashMap<String, AgentTranscriptSource> = (0..20)
        .map(|i| {
            let source = AgentTranscriptSource::new("omp", Some(&conversation(&format!("s{i}"), &file)))
                .expect("source");
            (format!("entry-{i}"), source)
        })
        .collect();
    store.track(sources);
    for _ in 0..1_000 {
        store.refresh();
    }
    let started = std::time::Instant::now();
    drop(store);
    assert!(started.elapsed() < Duration::from_millis(100), "drop took {:?}", started.elapsed());
}

#[test]
fn a_transcript_folder_that_appears_later_is_watched_once_it_exists() {
    let directory = tempfile::tempdir().expect("temp dir");
    let folder = directory.path().join("later");
    let file = folder.join("session.jsonl");
    let store = AgentTranscriptStore::with_home(directory.path().to_path_buf());
    let (changed, changes) = mpsc::channel::<String>();
    store.set_on_change(move |id| {
        let _ = changed.send(id.to_owned());
    });
    let source = AgentTranscriptSource::new("omp", Some(&conversation("sess-4", &file))).expect("source");
    store.track(HashMap::from([("pane:tab".to_owned(), source)]));
    // The folder is missing, so watching it fails; the next read tries again.
    std::thread::sleep(Duration::from_millis(200));

    std::fs::create_dir_all(&folder).expect("folder");
    std::fs::write(&file, "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"One\"}}\n")
        .expect("write");
    store.refresh();
    assert_eq!(changes.recv_timeout(Duration::from_secs(5)).ok().as_deref(), Some("pane:tab"));

    // No refresh from here on: only the watch can report the append.
    std::thread::sleep(Duration::from_millis(500));
    use std::io::Write;
    let mut handle = std::fs::OpenOptions::new().append(true).open(&file).expect("open");
    handle
        .write_all(b"{\"type\":\"message\",\"id\":\"u2\",\"parentId\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"Two\"}}\n")
        .expect("append");
    drop(handle);
    assert_eq!(changes.recv_timeout(Duration::from_secs(10)).ok().as_deref(), Some("pane:tab"));
    assert_eq!(store.timeline("pane:tab").map(|t| t.items.len()), Some(2));
}
