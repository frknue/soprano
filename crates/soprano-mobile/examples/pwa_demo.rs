//! Serves the mobile PWA with fixture agents, without Soprano or Tailscale, to look at it in a
//! browser: `cargo run -p soprano-mobile --example pwa_demo [-- --light]`, then open the printed
//! pairing link. One thread keeps working, one waits for an approval, one asks questions.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use soprano_mobile::pairing::PairingStore;
use soprano_mobile::{
    MobileAction, MobileActionResponse, MobileAgentProfile, MobileApproval, MobileApprovalOption,
    MobileClients, MobileConfigOption, MobileConfigOptionValue, MobileFileChange, MobileProject,
    MobileSnapshot, MobileTheme, MobileThreadDetail, MobileThreadSummary, MobileTurn, MobileTurnItem,
    MobileUserInput, MobileUserQuestion, MobileUserQuestionOption, ServerEvent, start_server,
};
use soprano_platform::StateStore;
use tokio::sync::broadcast;

const WORKING: &str = "pane-1:tab-1";
const APPROVAL: &str = "pane-2:tab-1";
const QUESTION: &str = "pane-3:tab-1";
const DONE: &str = "pane-4:tab-1";
const TERMINAL: &str = "pane-5:tab-1";

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)
}

fn theme(light: bool) -> MobileTheme {
    let colors: [&str; 23] = if light {
        [
            "#fbfbfa",
            "#f6f6f3",
            "#fbfbfa",
            "#f2f2f1",
            "rgba(0, 0, 0, 0.047)",
            "rgba(0, 0, 0, 0.090)",
            "#1b1b1e",
            "#67676a",
            "#959597",
            "#2e7de9",
            "#1b1b1e",
            "#ffffff",
            "#2e7de9",
            "#b15c00",
            "#7847bd",
            "#d5334f",
            "#4f7a21",
            "rgba(79, 122, 33, 0.14)",
            "rgba(213, 51, 79, 0.12)",
            "rgba(79, 122, 33, 0.3)",
            "rgba(213, 51, 79, 0.26)",
            "#4f7a21",
            "#d5334f",
        ]
    } else {
        [
            "#1a1b26",
            "#161720",
            "#282933",
            "#2f303a",
            "rgba(255, 255, 255, 0.055)",
            "rgba(255, 255, 255, 0.094)",
            "#eeeeef",
            "#99999f",
            "#6b6b74",
            "#7aa2f7",
            "#eeeeef",
            "#13131b",
            "#7aa2f7",
            "#e0af68",
            "#bb9af7",
            "#f7768e",
            "#9ece6a",
            "rgba(158, 206, 106, 0.14)",
            "rgba(247, 118, 142, 0.14)",
            "rgba(158, 206, 106, 0.3)",
            "rgba(247, 118, 142, 0.3)",
            "#9ece6a",
            "#f7768e",
        ]
    };
    let [
        background,
        canvas,
        popover,
        raised,
        hover,
        border,
        foreground,
        muted,
        dim,
        accent,
        solid,
        solid_foreground,
        working,
        approval,
        input,
        failed,
        done,
        diff_add,
        diff_delete,
        diff_add_word,
        diff_delete_word,
        diff_add_foreground,
        diff_delete_foreground,
    ] = colors.map(str::to_owned);
    MobileTheme {
        dark: !light,
        background,
        canvas,
        popover,
        raised,
        hover,
        border,
        foreground,
        muted,
        dim,
        accent,
        solid,
        solid_foreground,
        working,
        approval,
        input,
        failed,
        done,
        diff_add,
        diff_delete,
        diff_add_word,
        diff_delete_word,
        diff_add_foreground,
        diff_delete_foreground,
    }
}

#[allow(clippy::too_many_arguments)]
fn summary(
    id: &str,
    title: &str,
    project: &str,
    agent: &str,
    status: &str,
    section: &str,
    waiting_reason: Option<&str>,
    is_chat: bool,
    since_ms: i64,
) -> MobileThreadSummary {
    MobileThreadSummary {
        id: id.into(),
        title: title.into(),
        project: project.into(),
        profile_id: agent.to_lowercase(),
        profile_name: agent.into(),
        status: status.into(),
        section: section.into(),
        waiting_reason: waiting_reason.map(str::to_owned),
        needs_attention: section == "needs_you",
        is_chat,
        accepts_replies: status != "stopped",
        can_stop: status != "stopped",
        can_restart: true,
        branch: (project == "soprano").then(|| "feat/mobile-pwa".to_owned()),
        since_ms,
    }
}

struct Demo {
    started_ms: i64,
    replies: BTreeMap<String, Vec<String>>,
    approved: bool,
    answered: bool,
    stopped: bool,
    model: String,
}

impl Demo {
    fn threads(&self) -> Vec<MobileThreadSummary> {
        let since = self.started_ms;
        // An answered thread waits for its next message.
        let asked = |id, title, project, reason, answered: bool| {
            if answered {
                summary(id, title, project, "omp", "idle", "ready", None, true, since)
            } else {
                summary(id, title, project, "omp", "waiting", "needs_you", Some(reason), true, since)
            }
        };
        let mut threads = vec![
            asked(APPROVAL, "Release notes for 0.9", "soprano", "approval", self.approved),
            asked(QUESTION, "Pick a cache strategy", "shop-theme", "question", self.answered),
        ];
        threads.push(if self.stopped {
            summary(
                WORKING,
                "Fix the request storm",
                "soprano",
                "omp",
                "idle",
                "ready",
                None,
                true,
                now_ms() - 5_000,
            )
        } else {
            summary(
                WORKING,
                "Fix the request storm",
                "soprano",
                "omp",
                "running",
                "working",
                None,
                true,
                since - 95_000,
            )
        });
        threads.push(summary(
            DONE,
            "Port the settings screen to the new tokens and check every row at 320 px",
            "ab_tool",
            "Claude Code",
            "idle",
            "ready",
            None,
            false,
            since - 3_600_000,
        ));
        threads.push(summary(
            TERMINAL,
            "codex",
            "dotfiles",
            "Codex",
            "stopped",
            "stopped",
            None,
            false,
            since - 86_400_000,
        ));
        threads
    }

    fn snapshot(&self, light: bool) -> MobileSnapshot {
        MobileSnapshot {
            host_name: "Soprano Dev".into(),
            theme: theme(light),
            threads: self.threads(),
            projects: ["soprano", "shop-theme", "ab_tool"]
                .map(|name| MobileProject {
                    name: name.into(),
                    path: format!("/Users/demo/git/{name}"),
                    display_path: format!("~/git/{name}"),
                })
                .into(),
            agents: [("omp", "omp"), ("claude", "Claude Code"), ("codex", "Codex")]
                .map(|(id, name)| MobileAgentProfile { id: id.into(), name: name.into() })
                .into(),
        }
    }

    fn detail(&self, thread_id: &str, turn_limit: usize) -> Option<MobileThreadDetail> {
        let summary = self.threads().into_iter().find(|thread| thread.id == thread_id)?;
        let mut turns = match thread_id {
            WORKING => self.working_turns(),
            APPROVAL => vec![turn(
                "t1",
                "Write the release notes for 0.9 and tag it",
                "running",
                vec![
                    assistant("a1", "I'll collect the changes since the last tag first.", false),
                    command(
                        "c1",
                        "git log --oneline v0.8.0..HEAD",
                        "4f586c8 feat: mobile PWA\n595faed fix: pairing",
                        Some(0),
                        "completed",
                    ),
                ],
            )],
            QUESTION => vec![turn(
                "t1",
                "Make the product page faster",
                "running",
                vec![assistant(
                    "a1",
                    "Two ways to cache the recommendations fit here. Which one do you want?",
                    false,
                )],
            )],
            DONE => (1..=34).map(|n| done_turn(n, self.started_ms)).collect(),
            TERMINAL => vec![turn(
                "terminal-preview",
                "",
                "completed",
                vec![command(
                    "terminal-screen",
                    "Codex (terminal)",
                    "$ codex\n\n  Session ended.\n",
                    None,
                    "completed",
                )],
            )],
            _ => return None,
        };
        for (index, reply) in self.replies.get(thread_id).into_iter().flatten().enumerate() {
            turns.push(turn(
                &format!("reply-{index}"),
                reply,
                "completed",
                vec![assistant(
                    &format!("reply-{index}-a"),
                    "Noted. (The demo has no agent behind it.)",
                    true,
                )],
            ));
        }
        if (thread_id == APPROVAL && self.approved) || (thread_id == QUESTION && self.answered) {
            turns[0].status = "completed".into();
        }
        let earlier_turns = if turn_limit == 0 { 0 } else { turns.len().saturating_sub(turn_limit) };
        turns.drain(..earlier_turns);
        let is_chat = summary.is_chat;
        Some(MobileThreadDetail {
            summary,
            loading: false,
            preamble: Vec::new(),
            earlier_turns,
            turns,
            options: if is_chat {
                vec![
                    MobileConfigOption {
                        id: "model".into(),
                        name: "Model".into(),
                        current_value: self.model.clone(),
                        values: ["claude-sonnet-4.5", "gpt-5.1-codex", "gemini-3-pro"]
                            .map(|name| MobileConfigOptionValue { value: name.into(), name: name.into() })
                            .into(),
                    },
                    MobileConfigOption {
                        id: "thinking".into(),
                        name: "Thinking".into(),
                        current_value: "high".into(),
                        values: ["low", "medium", "high"]
                            .map(|name| MobileConfigOptionValue { value: name.into(), name: name.into() })
                            .into(),
                    },
                ]
            } else {
                Vec::new()
            },
            pending_approval: (thread_id == APPROVAL && !self.approved).then(|| MobileApproval {
                title: "Command approval".into(),
                detail: "git tag -a v0.9.0 -m \"Soprano 0.9.0\" && git push origin v0.9.0".into(),
                is_command: true,
                reason: Some("Tag and publish the release".into()),
                options: [
                    ("allow", "Allow once", "allow_once"),
                    ("always", "Always allow", "allow_always"),
                    ("reject", "Reject", "reject_once"),
                ]
                .map(|(id, label, kind)| MobileApprovalOption {
                    id: id.into(),
                    label: label.into(),
                    kind: kind.into(),
                })
                .into(),
            }),
            pending_input: (thread_id == QUESTION && !self.answered).then(|| MobileUserInput {
                questions: vec![
                    MobileUserQuestion {
                        id: "strategy".into(),
                        header: "Cache".into(),
                        prompt: "Where should the recommendations be cached?".into(),
                        options: vec![
                            MobileUserQuestionOption {
                                label: "Section rendering API".into(),
                                description: Some("Cached by Shopify per product, no app change.".into()),
                            },
                            MobileUserQuestionOption {
                                label: "Session storage".into(),
                                description: Some("Instant on back navigation, stale for a session.".into()),
                            },
                        ],
                        allows_multiple: false,
                        allows_other: true,
                    },
                    MobileUserQuestion {
                        id: "markets".into(),
                        header: "Markets".into(),
                        prompt: "Which markets get it first?".into(),
                        options: ["DE", "AT", "CH"]
                            .map(|label| MobileUserQuestionOption { label: label.into(), description: None })
                            .into(),
                        allows_multiple: true,
                        allows_other: false,
                    },
                ],
            }),
            queued_prompts: if thread_id == WORKING && !self.stopped {
                vec!["Also add a changelog line when you are done".into()]
            } else {
                Vec::new()
            },
        })
    }

    /// The working thread gains a line of test output every second.
    fn working_turns(&self) -> Vec<MobileTurn> {
        let seconds = ((now_ms() - self.started_ms) / 1000).max(0) as usize;
        let output: String =
            (0..seconds.min(400)).map(|n| format!("test server::tests::case_{n:03} ... ok\n")).collect();
        let mut items = vec![
            MobileTurnItem::Reasoning {
                id: "r1".into(),
                status: "completed".into(),
                text: "Every thread fetch publishes a snapshot, and every snapshot makes the phone fetch the thread again.".into(),
            },
            assistant(
                "a1",
                "The phone and the app keep each other busy:\n\n1. `GET /api/threads/{id}` publishes a snapshot\n2. the snapshot makes the phone fetch the thread **again**\n\n```rust\nif changed {\n    this.publish_mobile_snapshot(cx);\n}\n```\n\n| Before | After |\n|---|---|\n| a fetch per snapshot | a fetch per change |\n\nSee <https://example.com/issue/12> for the report.",
                false,
            ),
            MobileTurnItem::ToolCall {
                id: "tool1".into(),
                status: "completed".into(),
                name: "read".into(),
                category: "read".into(),
                title: "Read crates/soprano/src/main_view.rs".into(),
                input: Some("{\n  \"path\": \"crates/soprano/src/main_view.rs:315-355\"\n}".into()),
                output: Some("tasks.push(cx.spawn_in(window, async move |this, cx| {\n    …\n}));".into()),
            },
            MobileTurnItem::WebSearch {
                id: "web1".into(),
                status: "completed".into(),
                query: "tokio broadcast lagged receiver".into(),
            },
            MobileTurnItem::FileChange {
                id: "edit1".into(),
                status: "completed".into(),
                files: vec![MobileFileChange {
                    path: "crates/soprano-mobile/src/controller.rs".into(),
                    kind: "update".into(),
                    move_path: None,
                    diff: Some(
                        "@@ -183,8 +183,11 @@\n     pub fn publish_snapshot(&self, snapshot: MobileSnapshot) {\n         {\n             let mut guard = self.inner.data_snapshot.write().unwrap_or_else(|e| e.into_inner());\n-            *guard = snapshot.clone();\n+            if *guard == snapshot {\n+                return;\n+            }\n+            *guard = snapshot.clone();\n         }\n".into(),
                    ),
                    is_full_content: false,
                }],
            },
            MobileTurnItem::Steer { id: "steer1".into(), text: "Keep the old endpoints working".into() },
        ];
        if self.stopped {
            items.push(command("c1", "cargo test -p soprano-mobile", &output, None, "interrupted"));
            return vec![MobileTurn {
                completed_at_ms: Some(now_ms() - 5_000),
                ..turn(
                    "t1",
                    "The phone says the request failed as soon as I scroll. Find out why.",
                    "interrupted",
                    items,
                )
            }];
        }
        items.push(command("c1", "cargo test -p soprano-mobile", &output, None, "running"));
        vec![
            turn(
                "t1",
                "The phone says the request failed as soon as I scroll. Find out why.",
                "running",
                items,
            )
            .started(self.started_ms - 95_000),
        ]
    }
}

trait Started {
    fn started(self, at_ms: i64) -> Self;
}

impl Started for MobileTurn {
    fn started(mut self, at_ms: i64) -> Self {
        self.started_at_ms = Some(at_ms);
        self
    }
}

fn turn(id: &str, user_text: &str, status: &str, items: Vec<MobileTurnItem>) -> MobileTurn {
    MobileTurn {
        id: id.into(),
        user_text: user_text.into(),
        status: status.into(),
        failure_message: None,
        started_at_ms: None,
        completed_at_ms: None,
        stopping: false,
        items,
    }
}

fn assistant(id: &str, text: &str, is_final: bool) -> MobileTurnItem {
    MobileTurnItem::AssistantMessage {
        id: id.into(),
        status: "completed".into(),
        text: text.into(),
        is_final,
    }
}

fn command(id: &str, command: &str, output: &str, exit_code: Option<i64>, status: &str) -> MobileTurnItem {
    MobileTurnItem::Command {
        id: id.into(),
        status: status.into(),
        command: command.into(),
        output: output.into(),
        exit_code,
    }
}

fn done_turn(n: usize, started_ms: i64) -> MobileTurn {
    let at = started_ms - 3_600_000 - ((40 - n) as i64) * 60_000;
    MobileTurn {
        started_at_ms: Some(at),
        completed_at_ms: Some(at + 42_000),
        ..turn(
            &format!("t{n}"),
            &format!("Row {n}: move it to the new tokens"),
            "completed",
            vec![
                command(
                    &format!("c{n}"),
                    &format!("rg -n \"row_{n}\" crates/soprano-settings"),
                    "",
                    Some(1),
                    "completed",
                ),
                assistant(
                    &format!("a{n}"),
                    &format!("Row {n} uses `t.raised` and `t.border` now and fits at 320 px."),
                    true,
                ),
            ],
        )
    }
}

fn main() {
    let light = std::env::args().any(|arg| arg == "--light");
    let pairing = Arc::new(PairingStore::new(StateStore::in_memory()));
    let demo = Arc::new(Mutex::new(Demo {
        started_ms: now_ms(),
        replies: BTreeMap::new(),
        approved: false,
        answered: false,
        stopped: false,
        model: "claude-sonnet-4.5".into(),
    }));
    let snapshot = Arc::new(RwLock::new(demo.lock().expect("demo").snapshot(light)));
    let (events, _) = broadcast::channel(64);
    let (commands_tx, commands) = async_channel::unbounded();
    let server = start_server(
        pairing.clone(),
        snapshot.clone(),
        events.clone(),
        commands_tx,
        Arc::new(MobileClients::default()),
        Arc::new(|| {}),
        Arc::new(|| {}),
    )
    .expect("the demo server starts");
    let base = format!("http://127.0.0.1:{}", server.local_port());
    println!("Soprano mobile demo: {}", pairing.create_offer(&base).expect("a pairing offer").url);

    let publish = {
        let (demo, snapshot, events) = (demo.clone(), snapshot.clone(), events.clone());
        move || {
            let next = demo.lock().expect("demo").snapshot(light);
            *snapshot.write().expect("snapshot") = next.clone();
            let _ = events.send(ServerEvent::Snapshot { snapshot: Box::new(next) });
        }
    };

    // The working agent's output grows: announce its thread like Soprano's once-a-second tick.
    {
        let (demo, events) = (demo.clone(), events.clone());
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(Duration::from_secs(1));
                if !demo.lock().expect("demo").stopped {
                    let _ = events.send(ServerEvent::ThreadUpdated { thread_id: WORKING.into() });
                }
            }
        });
    }

    while let Ok(command) = commands.recv_blocking() {
        let mut state = demo.lock().expect("demo");
        let (response, touched) = match command.action {
            MobileAction::GetThread { thread_id, turn_limit } => match state.detail(&thread_id, turn_limit) {
                Some(detail) => {
                    let revision = detail.revision();
                    (MobileActionResponse::Thread { detail: Box::new(detail), revision }, None)
                }
                None => {
                    (MobileActionResponse::NotFound(format!("Thread {thread_id} no longer exists.")), None)
                }
            },
            MobileAction::Reply { thread_id, text } => {
                state.replies.entry(thread_id.clone()).or_default().push(text);
                (MobileActionResponse::Ok, Some(thread_id))
            }
            MobileAction::Approve { thread_id, .. } => {
                state.approved = true;
                (MobileActionResponse::Ok, Some(thread_id))
            }
            MobileAction::AnswerUserInput { thread_id, .. }
            | MobileAction::DeclineUserInput { thread_id } => {
                state.answered = true;
                (MobileActionResponse::Ok, Some(thread_id))
            }
            MobileAction::Stop { thread_id } | MobileAction::Cancel { thread_id } => {
                state.stopped = true;
                (MobileActionResponse::Ok, Some(thread_id))
            }
            MobileAction::Restart { thread_id } => {
                state.stopped = false;
                state.started_ms = now_ms();
                (MobileActionResponse::Ok, Some(thread_id))
            }
            MobileAction::SetOption { thread_id, id, value } => {
                if id == "model" {
                    state.model = value;
                }
                (MobileActionResponse::Ok, Some(thread_id))
            }
            MobileAction::NewThread { .. } => {
                (MobileActionResponse::Error("The demo cannot start agents.".into()), None)
            }
        };
        drop(state);
        let _ = command.reply.try_send(response);
        if let Some(thread_id) = touched {
            publish();
            let _ = events.send(ServerEvent::ThreadUpdated { thread_id });
        }
    }
}
