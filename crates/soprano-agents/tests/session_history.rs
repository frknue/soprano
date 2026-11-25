use std::collections::HashMap;
use std::fs;
use std::path::Path;

use chrono::{Duration, Utc};
use soprano_agents::*;

fn write(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("mkdir");
    }
    fs::write(path, contents).expect("write");
}

fn init_git_repo(dir: &Path, branch: &str) {
    let git = dir.join(".git");
    fs::create_dir_all(&git).expect("mkdir .git");
    fs::write(git.join("HEAD"), format!("ref: refs/heads/{branch}\n")).expect("HEAD");
}

fn init_linked_worktree(main_repo: &Path, worktree: &Path, name: &str, branch: &str) {
    let worktree_git = main_repo.join(".git/worktrees").join(name);
    fs::create_dir_all(&worktree_git).expect("mkdir worktree git");
    fs::write(worktree_git.join("HEAD"), format!("ref: refs/heads/{branch}\n")).expect("HEAD");
    fs::write(worktree_git.join("commondir"), "../..\n").expect("commondir");
    fs::create_dir_all(worktree).expect("mkdir worktree");
    fs::write(worktree.join(".git"), format!("gitdir: {}\n", worktree_git.display())).expect(".git file");
}

#[test]
fn indexes_claude_omp_codex_and_opencode_sessions_and_reuses_cache() {
    let home = tempfile::tempdir().expect("home");
    let cache_dir = tempfile::tempdir().expect("cache");
    let cache_db = cache_dir.path().join("history.db");

    let repo_a = home.path().join("code/ab_tool");
    init_git_repo(&repo_a, "main");
    let worktree_a = home.path().join("worktrees/ab_tool-upsell");
    init_linked_worktree(&repo_a, &worktree_a, "upsell", "feat/upsell");
    let repo_b = home.path().join("code/other_app");
    init_git_repo(&repo_b, "develop");

    // 1. Claude Code session in repo_a with ai-title, model, branch, and 2 subagent files.
    let claude_dir = home.path().join(".claude/projects/-code-ab_tool");
    write(
        &claude_dir.join("claude-sess-1.jsonl"),
        &format!(
            concat!(
                r#"{{"type":"user","uuid":"u1","sessionId":"claude-sess-1","cwd":"{cwd}","gitBranch":"main","timestamp":"2026-11-24T09:00:00.000Z","message":{{"role":"user","content":"Check shipping protection test"}}}}"#,
                "\n",
                r#"{{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-11-24T09:05:00.000Z","message":{{"role":"assistant","model":"claude-opus-4-6","content":[{{"type":"text","text":"The comment is posted on the ticket under your name."}}]}}}}"#,
                "\n",
                r#"{{"type":"ai-title","sessionId":"claude-sess-1","aiTitle":"Shipping protection test"}}"#,
                "\n"
            ),
            cwd = repo_a.to_string_lossy()
        ),
    );
    write(&claude_dir.join("claude-sess-1/subagents/agent-1.jsonl"), "{}\n");
    write(&claude_dir.join("claude-sess-1/subagents/agent-2.jsonl"), "{}\n");
    // Standalone agent-* file must be ignored as a top-level session.
    write(
        &claude_dir.join("agent-side.jsonl"),
        r#"{"type":"user","uuid":"s1","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}"#,
    );

    // 2. omp session in linked worktree_a with title, task subagent call, and model.
    let omp_file =
        home.path().join(".omp/agent/sessions/-worktrees-ab_tool-upsell/2026-11-24_omp-sess-2.jsonl");
    write(
        &omp_file,
        &format!(
            concat!(
                r#"{{"type":"session","version":3,"id":"omp-sess-2","timestamp":"2026-11-24T10:00:00.000Z","cwd":"{cwd}"}}"#,
                "\n",
                r#"{{"type":"title","v":1,"title":"UPSELL: Review existing shop upsells","source":"auto"}}"#,
                "\n",
                r#"{{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-11-24T10:00:01.000Z","modelId":"anthropic/claude-sonnet-4-5"}}"#,
                "\n",
                r#"{{"type":"message","id":"u1","parentId":"m1","timestamp":"2026-11-24T10:00:02.000Z","message":{{"role":"user","attribution":"user","content":"Review free-shipping threshold PDF for Eric"}}}}"#,
                "\n",
                r#"{{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-11-24T10:02:00.000Z","message":{{"role":"assistant","content":[{{"type":"toolCall","id":"tc1","name":"task","arguments":{{}}}},{{"type":"text","text":"The PDF is ready to share with Eric."}}]}}}}"#,
                "\n"
            ),
            cwd = worktree_a.to_string_lossy()
        ),
    );

    // 3. Codex session in repo_b.
    let codex_file = home.path().join(".codex/sessions/2026/11/24/rollout-2026-11-24T11-00-00-codex-3.jsonl");
    write(
        &codex_file,
        &format!(
            concat!(
                r#"{{"timestamp":"2026-11-24T11:00:00.000Z","type":"session_meta","payload":{{"id":"codex-3","cwd":"{cwd}","git":{{"branch":"develop"}}}}}}"#,
                "\n",
                r#"{{"timestamp":"2026-11-24T11:00:01.000Z","type":"turn_context","payload":{{"cwd":"{cwd}","model":"gpt-5.4"}}}}"#,
                "\n",
                r#"{{"timestamp":"2026-11-24T11:00:05.000Z","type":"event_msg","payload":{{"type":"item_completed","item":{{"type":"UserMessage","id":"u1","content":[{{"type":"text","text":"Fix checkout race condition"}}]}} }}}}"#,
                "\n",
                r#"{{"timestamp":"2026-11-24T11:01:00.000Z","type":"event_msg","payload":{{"type":"item_completed","item":{{"type":"AgentMessage","id":"a1","content":[{{"type":"Text","text":"Added a mutex guard around checkout submission."}}]}} }}}}"#,
                "\n"
            ),
            cwd = repo_b.to_string_lossy()
        ),
    );

    // 4. OpenCode 2.x SQLite database with a main session and 1 child subagent session.
    let oc_path = home.path().join(".local/share/opencode/opencode.db");
    fs::create_dir_all(oc_path.parent().unwrap()).expect("mkdir opencode");
    {
        let db = rusqlite::Connection::open(&oc_path).expect("open db");
        db.execute_batch(&format!(
            "CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY, directory TEXT NOT NULL, title TEXT, parent_id TEXT,
                revert TEXT, time_created INTEGER NOT NULL DEFAULT 0, time_updated INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
                time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
            );
            INSERT INTO session_v2 VALUES ('ses_main', '{cwd}', 'Set INT13 live', NULL, NULL, 1795430000000, 1795434000000);
            INSERT INTO session_v2 VALUES ('ses_child', '{cwd}', 'Subtask', 'ses_main', NULL, 1795431000000, 1795432000000);
            INSERT INTO session_message VALUES ('m1', 'ses_main', 'user', 1, 1795430000000, 1795430000000, '{{\"text\":\"Launch INT13 today\"}}');
            INSERT INTO session_message VALUES ('m2', 'ses_main', 'assistant', 2, 1795434000000, 1795434000000, '{{\"modelID\":\"claude-sonnet-4\",\"content\":[{{\"type\":\"text\",\"text\":\"INT13 is live with both arms.\"}}]}}');",
            cwd = repo_a.to_string_lossy()
        ))
        .expect("seed opencode");
    }

    // First scan parses all 4 sources and populates SQLite cache.
    let mut index = AgentSessionIndex::new(home.path().to_path_buf(), HashMap::new(), Some(cache_db.clone()));
    let first = index.refresh();
    assert_eq!(first.reparsed_files, 4);
    assert_eq!(first.cached_files, 0);
    assert_eq!(first.sessions.len(), 4);

    // Second scan on a brand-new index instance loads from SQLite cache with zero re-parsing.
    let mut warm_index = AgentSessionIndex::new(home.path().to_path_buf(), HashMap::new(), Some(cache_db));
    let second = warm_index.refresh();
    assert_eq!(second.reparsed_files, 0);
    assert_eq!(second.cached_files, 4);
    assert_eq!(second.sessions.len(), 4);

    // Verify metadata extracted for each CLI.
    let claude = second.sessions.iter().find(|s| s.id == "claude-sess-1").expect("claude");
    assert_eq!(claude.title, "Shipping protection test");
    assert_eq!(claude.subagent_count, 2);
    assert_eq!(claude.model.as_deref(), Some("claude-opus-4-6"));
    assert_eq!(claude.git_branch.as_deref(), Some("main"));
    assert_eq!(claude.message_count, 2);
    assert_eq!(claude.resume_command(), "claude --resume claude-sess-1");

    let omp = second.sessions.iter().find(|s| s.id == "omp-sess-2").expect("omp");
    assert_eq!(omp.title, "UPSELL: Review existing shop upsells");
    assert_eq!(omp.subagent_count, 1);
    assert_eq!(omp.model.as_deref(), Some("claude-sonnet-4-5"));
    assert_eq!(omp.resume_command(), "omp --resume omp-sess-2");

    let codex = second.sessions.iter().find(|s| s.id == "codex-3").expect("codex");
    assert_eq!(codex.title, "Fix checkout race condition");
    assert_eq!(codex.model.as_deref(), Some("gpt-5.4"));
    assert_eq!(codex.git_branch.as_deref(), Some("develop"));

    let oc = second.sessions.iter().find(|s| s.id == "ses_main").expect("opencode");
    assert_eq!(oc.title, "Set INT13 live");
    assert_eq!(oc.subagent_count, 1);
    assert_eq!(oc.model.as_deref(), Some("claude-sonnet-4"));
    assert_eq!(oc.message_count, 2);

    // Scope: Workspace in repo_a -> claude + opencode (not linked worktree omp, not repo_b codex).
    let workspace_res = query_sessions(
        &second.sessions,
        &HistoryQuery {
            scope: HistoryScope::Workspace,
            active_cwd: Some(repo_a.to_string_lossy().into_owned()),
            ..HistoryQuery::default()
        },
    );
    assert_eq!(workspace_res.matched_count, 2);
    assert!(workspace_res.groups[0].sessions.iter().all(|s| s.is_current_worktree));

    // Scope: Project in repo_a -> claude + opencode + linked worktree omp (all under ab_tool!).
    let project_res = query_sessions(
        &second.sessions,
        &HistoryQuery {
            scope: HistoryScope::Project,
            active_cwd: Some(repo_a.to_string_lossy().into_owned()),
            ..HistoryQuery::default()
        },
    );
    assert_eq!(project_res.matched_count, 3);
    assert_eq!(project_res.groups.len(), 1);
    assert_eq!(project_res.groups[0].name, "ab_tool");
    let omp_item = project_res.groups[0].sessions.iter().find(|i| i.session.id == "omp-sess-2").unwrap();
    assert!(!omp_item.is_current_worktree);
    assert_eq!(omp_item.worktree_label.as_deref(), Some("ab_tool-upsell"));
    assert_eq!(omp_item.branch.as_deref(), Some("feat/upsell"));

    // Search inside conversation prose (not in title) returns a matching snippet!
    let search_res = query_sessions(
        &second.sessions,
        &HistoryQuery {
            scope: HistoryScope::All,
            active_cwd: Some(repo_a.to_string_lossy().into_owned()),
            search: "free-shipping eric".into(),
            ..HistoryQuery::default()
        },
    );
    assert_eq!(search_res.scoped_count, 4);
    assert_eq!(search_res.matched_count, 1);
    let hit = &search_res.groups[0].sessions[0];
    assert_eq!(hit.session.id, "omp-sess-2");
    assert!(hit.match_snippet.as_deref().is_some_and(|s| s.contains("free-shipping")));

    // Filter by agent CLI.
    let agent_res = query_sessions(
        &second.sessions,
        &HistoryQuery {
            scope: HistoryScope::All,
            agent: Some(AgentTranscriptFormat::Codex),
            ..HistoryQuery::default()
        },
    );
    assert_eq!(agent_res.matched_count, 1);
    assert_eq!(agent_res.groups[0].sessions[0].session.id, "codex-3");
}

#[test]
fn formats_relative_ages_human_readably() {
    let now = Utc::now();
    assert_eq!(format_relative_age(now - Duration::seconds(10), now), "Just now");
    assert_eq!(format_relative_age(now - Duration::minutes(4), now), "4m ago");
    assert_eq!(format_relative_age(now - Duration::hours(11), now), "11h ago");
    assert_eq!(format_relative_age(now - Duration::days(3), now), "3d ago");
    assert_eq!(format_relative_age(now - Duration::days(21), now), "3w ago");
}
