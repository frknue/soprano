//! The Agent Dashboard as its window shows it, over a demo workspace: threads in every
//! section, one with a Claude Code transcript.
//! `cargo run -p soprano-dashboard --example dashboard_demo`.
//!
//! `-- --snapshot /abs/dir [--size 1100x780] [--appearance dark|light] [--theme ID]
//! [--agents N]` writes the dashboard's states (every thread, the detailed work log, the
//! composer, the stopped shelf, a search, a new thread) as PNGs into the folder and quits,
//! for visual QA without looking at the screen.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use gpui::{
    App, AppContext as _, AsyncWindowContext, Bounds, Context, Entity, Focusable as _, IntoElement,
    ParentElement, Render, Styled, Window, WindowBounds, WindowOptions, div, px, size,
};
use gpui_component::Root;
use serde_json::json;
use soprano_agents::AgentDashboardSection;
use soprano_chat::{AgentChatConfigOption, ConfigOptionValue};
use soprano_dashboard::{AgentDashboard, DashboardEvent, DashboardHost, ProjectChoice, ThreadOption};
use soprano_model::Workspace;
use soprano_types::{AgentConversation, AgentStatus, AgentWaitingReason, TerminalTarget};
use soprano_ui::snapshot::{self, Args};
use soprano_ui::{ActiveSopranoTheme, SopranoAssets};

/// What omp offers a conversation in the demo, with `opening` (option id, value) applied.
fn demo_options(opening: &[(String, String)]) -> Vec<AgentChatConfigOption> {
    let value = |value: &str, name: &str| ConfigOptionValue {
        value: value.into(),
        name: name.into(),
        detail: value.contains('/').then(|| value.to_owned()),
    };
    let mut options = vec![
        AgentChatConfigOption {
            id: "model".into(),
            name: "Model".into(),
            category: Some("model".into()),
            current_value: "anthropic/claude-opus-5-5".into(),
            values: vec![
                value("anthropic/claude-opus-5-5", "Claude Opus 5.5"),
                value("anthropic/claude-sonnet-5-5", "Claude Sonnet 5.5"),
                value("anthropic/claude-haiku-5-5", "Claude Haiku 5.5"),
                value("openai-codex/gpt-5.6-sol", "GPT-5.6 Sol"),
                value("openai-codex/gpt-5.6-luna", "GPT-5.6 Luna"),
            ],
        },
        AgentChatConfigOption {
            id: "thinking".into(),
            name: "Thinking".into(),
            category: Some("thought_level".into()),
            current_value: "high".into(),
            values: vec![
                value("off", "Off"),
                value("low", "low"),
                value("medium", "medium"),
                value("high", "high"),
                value("xhigh", "xhigh"),
            ],
        },
    ];
    for (id, value) in opening {
        ThreadOption::choose(&mut options, id, value);
    }
    options
}

struct DemoAgent {
    profile: &'static str,
    folder: &'static str,
    title: &'static str,
    status: AgentStatus,
    reason: Option<AgentWaitingReason>,
    chat: bool,
    /// Its tab goes into a second window.
    second_window: bool,
}

const fn agent(
    profile: &'static str,
    folder: &'static str,
    title: &'static str,
    status: AgentStatus,
) -> DemoAgent {
    DemoAgent { profile, folder, title, status, reason: None, chat: false, second_window: false }
}

/// One agent per state a row can show; the first has the transcript.
const AGENTS: [DemoAgent; 8] = [
    DemoAgent {
        reason: Some(AgentWaitingReason::Approval),
        ..agent("claude-code", "payments", "✳ Refund partially captured orders", AgentStatus::Waiting)
    },
    agent("codex", "storefront", "⠙ Fix the checkout total", AgentStatus::Running),
    DemoAgent {
        reason: Some(AgentWaitingReason::Question),
        second_window: true,
        ..agent("omp", "soprano", "Which of the two migrations should run first?", AgentStatus::Waiting)
    },
    DemoAgent { second_window: true, ..agent("opencode", "docs", "", AgentStatus::Idle) },
    DemoAgent {
        reason: Some(AgentWaitingReason::TurnEnded),
        ..agent("claude-code", "api", "Add rate limits to the public API", AgentStatus::Waiting)
    },
    agent(
        "codex",
        "infrastructure",
        "Upgrade the Terraform providers and fix what breaks",
        AgentStatus::Error,
    ),
    DemoAgent { chat: true, ..agent("omp", "notes", "", AgentStatus::Running) },
    agent("claude-code", "legacy-importer", "Port the importer to the new queue", AgentStatus::Stopped),
];

/// A Claude Code session: a finished turn (search, read, edit, test, answer) and a second one
/// that stops at a command waiting for approval.
fn write_transcript(directory: &Path, cwd: &str) -> PathBuf {
    let start = Utc::now() - Duration::minutes(9);
    let at = |seconds: i64| -> String {
        let time: DateTime<Utc> = start + Duration::seconds(seconds);
        time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
    };
    let user = |uuid: &str, parent: Option<&str>, seconds, text: &str| {
        json!({ "type": "user", "uuid": uuid, "parentUuid": parent, "cwd": cwd, "timestamp": at(seconds),
            "message": { "role": "user", "content": text } })
    };
    let says = |uuid: &str, parent: &str, seconds, text: &str| {
        json!({ "type": "assistant", "uuid": uuid, "parentUuid": parent, "timestamp": at(seconds),
            "message": { "role": "assistant", "content": [{ "type": "text", "text": text }] } })
    };
    let calls = |uuid: &str, parent: &str, seconds, tool: &str, input: serde_json::Value| {
        json!({ "type": "assistant", "uuid": uuid, "parentUuid": parent, "timestamp": at(seconds),
            "message": { "role": "assistant",
                "content": [{ "type": "tool_use", "id": format!("tool-{uuid}"), "name": tool, "input": input }] } })
    };
    let returns = |uuid: &str, call: &str, seconds, output: &str| {
        json!({ "type": "user", "uuid": uuid, "parentUuid": call, "timestamp": at(seconds),
            "message": { "role": "user",
                "content": [{ "type": "tool_result", "tool_use_id": format!("tool-{call}"), "content": output }] },
            "toolUseResult": { "stdout": output, "stderr": "", "interrupted": false, "isImage": false } })
    };
    let service = format!("{cwd}/app/services/refunds/refundable_amount.rb");
    let test = format!("{cwd}/test/services/refunds/refundable_amount_test.rb");
    let answer = "Refunds failed because the refundable amount was taken from the **authorized** total, \
        not from what was actually captured.\n\n\
        - `Refunds::RefundableAmount` now sums the order's captures and subtracts earlier refunds.\n\
        - A partially captured order can be refunded up to its captured amount.\n\
        - Added a regression test for an order captured in two parts.\n\n\
        ```ruby\ndef call\n  captured_total - refunded_total\nend\n```\n\n\
        All 12 refund tests pass.";
    let records = [
        user(
            "u1",
            None,
            0,
            "Refunds for partially captured orders fail with `amount_too_large`. Find out why and fix it.",
        ),
        says("a1", "u1", 4, "I'll look at how the refundable amount is computed."),
        calls("c1", "a1", 6, "Grep", json!({ "pattern": "refundable_amount", "path": format!("{cwd}/app") })),
        returns("r1", "c1", 8, "app/services/refunds/refundable_amount.rb\napp/models/order.rb"),
        calls("c2", "r1", 10, "Read", json!({ "file_path": service })),
        returns("r2", "c2", 11, "class Refunds::RefundableAmount"),
        calls(
            "c3",
            "r2",
            30,
            "Edit",
            json!({ "file_path": service,
            "old_string": "order.authorized_total - refunded_total",
            "new_string": "captured_total - refunded_total" }),
        ),
        returns("r3", "c3", 31, "The file has been updated."),
        calls("c4", "r3", 40, "Write", json!({ "file_path": test, "content": "require \"test_helper\"\n" })),
        returns("r4", "c4", 41, "File created."),
        calls(
            "c5",
            "r4",
            45,
            "Bash",
            json!({ "command": "bin/rails test test/services/refunds",
            "description": "Run the refund tests" }),
        ),
        returns("r5", "c5", 78, "12 runs, 31 assertions, 0 failures, 0 errors, 0 skips"),
        says("a2", "r5", 84, answer),
        user(
            "u2",
            Some("a2"),
            300,
            "Good. Orders captured before March have no capture rows — backfill them.",
        ),
        says("a3", "u2", 305, "I'll add a migration that creates one capture per paid order without any."),
        calls(
            "c6",
            "a3",
            320,
            "Write",
            json!({ "file_path": format!("{cwd}/db/migrate/20261110_backfill_captures.rb"),
            "content": "class BackfillCaptures < ActiveRecord::Migration[8.0]\nend\n" }),
        ),
        returns("r6", "c6", 321, "File created."),
        calls(
            "c7",
            "r6",
            330,
            "Bash",
            json!({ "command": "bin/rails db:migrate", "description": "Run the backfill migration" }),
        ),
    ];
    let lines: Vec<String> = records.iter().map(|record| record.to_string()).collect();
    let path = directory.join("refunds.jsonl");
    std::fs::write(&path, lines.join("\n") + "\n").expect("the demo folder is writable");
    path
}

/// The first `count` demo agents in two windows; returns the workspace and its targets.
fn demo_workspace(directory: &Path, count: usize) -> Workspace {
    let mut workspace = Workspace::new();
    let first_window = workspace.active_window_id().to_owned();
    workspace.rename_window(&first_window, "Shop");
    let mut second_window = None;
    for (index, demo) in AGENTS.iter().take(count).enumerate() {
        let cwd = directory.join("projects").join(demo.folder);
        std::fs::create_dir_all(&cwd).expect("the demo folder is writable");
        let cwd = cwd.to_string_lossy().into_owned();
        if demo.second_window && second_window.is_none() {
            second_window = workspace.create_window(Some(&cwd), None);
            if let Some(window) = &second_window {
                workspace.rename_window(window, "Tools");
            }
        }
        let Some(pane) = workspace.spawn_agent(demo.profile, Some(&cwd), demo.chat) else { continue };
        let Some(tab) = workspace.pane(&pane).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone())
        else {
            continue;
        };
        let target = TerminalTarget::new(pane, tab);
        let attention = demo.reason.is_some_and(|reason| reason != AgentWaitingReason::TurnEnded);
        workspace.update_agent_status(
            &target.pane_id,
            &target.tab_id,
            demo.status,
            Some(attention),
            demo.reason,
        );
        if !demo.title.is_empty() {
            workspace.rename_tab(&target.pane_id, &target.tab_id, demo.title);
        }
        if index == 0 {
            let transcript = write_transcript(directory, &cwd);
            workspace.record_agent_conversation(
                AgentConversation {
                    id: "dashboard-demo".into(),
                    cwd: Some(cwd),
                    transcript_path: Some(transcript.to_string_lossy().into_owned()),
                },
                &target.pane_id,
                &target.tab_id,
                None,
            );
        }
        if demo.status == AgentStatus::Stopped {
            workspace.stop_agent(&target);
        }
    }
    workspace.take_changes();
    workspace.take_events();
    workspace
}

/// The dashboard as its window's content.
struct DemoFrame {
    dashboard: Entity<AgentDashboard>,
}

impl Render for DemoFrame {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        cx.soprano_theme().apply_to_window(window);
        div().size_full().child(self.dashboard.clone())
    }
}

/// Writes the first thread's conversation, its detailed work log and the composer, every
/// other thread, the stopped shelf, a search, and a new thread.
async fn write_snapshots(
    directory: PathBuf,
    agents: usize,
    dashboard: Entity<AgentDashboard>,
    cx: &mut AsyncWindowContext,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(&directory)?;
    let mut number = 0;
    let mut shot = async |keys: &str, name: &str, cx: &mut AsyncWindowContext| -> anyhow::Result<()> {
        cx.update(|window, cx| snapshot::press(keys, window, cx))?;
        snapshot::redraw(cx).await;
        number += 1;
        let path = directory.join(format!("{number:02}-{name}.png"));
        cx.update(|window, _| snapshot::write_png(window, &path))?
    };
    // The transcript is read on the store's own thread.
    cx.background_executor().timer(std::time::Duration::from_millis(600)).await;
    shot("", "first-thread", cx).await?;
    if agents > 0 {
        shot("o", "details", cx).await?;
        cx.update(|window, cx| {
            snapshot::press("o tab", window, cx);
            dashboard.update(cx, |dashboard, cx| {
                dashboard.set_composer_text(
                    "Yes, run it.\nThen check the totals of last week's refunds.",
                    window,
                    cx,
                )
            });
        })?;
        shot("", "composer", cx).await?;
        cx.update(|window, cx| {
            dashboard.update(cx, |dashboard, cx| dashboard.set_composer_text("", window, cx));
            snapshot::press("escape", window, cx);
        })?;
    }
    for index in 1..agents {
        shot("j", &format!("thread-{}", index + 1), cx).await?;
    }
    if agents > 0 {
        cx.update(|_, cx| {
            dashboard.update(cx, |dashboard, cx| dashboard.toggle_fold(AgentDashboardSection::Stopped, cx))
        })?;
        shot("j", "stopped-shelf", cx).await?;
        cx.update(|window, cx| {
            dashboard.update(cx, |dashboard, cx| dashboard.set_search("pay", window, cx))
        })?;
        shot("", "search", cx).await?;
        cx.update(|window, cx| dashboard.update(cx, |dashboard, cx| dashboard.set_search("", window, cx)))?;
    }
    shot("n", "new-thread", cx).await?;
    cx.update(|window, cx| {
        dashboard.update(cx, |dashboard, cx| {
            dashboard.set_composer_text("Add a CSV export to the refunds report", window, cx)
        })
    })?;
    shot("", "new-thread-written", cx).await?;
    cx.update(|window, cx| dashboard.update(cx, |dashboard, cx| dashboard.open_agent_menu(window, cx)))?;
    shot("", "new-thread-agents", cx).await?;
    cx.update(|window, cx| {
        snapshot::press("escape", window, cx);
        dashboard.update(cx, |dashboard, cx| dashboard.open_project_picker(window, cx));
    })?;
    shot("", "new-thread-projects", cx).await?;
    Ok(())
}

fn main() {
    let args = Args::parse(1100., 780.);
    let mut theme = "folio".to_owned();
    let mut agents = AGENTS.len();
    for (flag, value) in &args.rest {
        match flag.as_str() {
            "--theme" => theme = value.clone(),
            "--agents" => agents = value.parse().expect("--agents N"),
            _ => panic!("unknown option {flag}"),
        }
    }
    let directory = std::env::temp_dir().join(format!("soprano-dashboard-demo-{}", std::process::id()));

    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(move |cx: &mut App| {
        soprano_ui::init(cx, &theme, args.appearance);
        let bounds = Bounds::centered(None, size(px(args.width), px(args.height)), cx);
        let snapshot = args.directory.clone();
        let interactive = snapshot.is_none();
        cx.open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..WindowOptions::default() },
            |window, cx| {
                let workspace = cx.new(|_| demo_workspace(&directory, agents));
                let model = workspace.clone();
                let chats = workspace.clone();
                let projects = directory.join("projects");
                let host = DashboardHost::new()
                    .home(directory.clone())
                    .thread_options(move |target, cx| {
                        let is_chat =
                            chats.read(cx).agent_dashboard_entry(target).is_some_and(|entry| entry.is_chat);
                        if is_chat { demo_options(&[]) } else { Vec::new() }
                    })
                    .draft_options(|profile_id, opening, _| {
                        gpui::Task::ready(if profile_id == "omp" {
                            demo_options(&opening)
                        } else {
                            Vec::new()
                        })
                    })
                    .accepts_replies(move |target, cx| {
                        model
                            .read(cx)
                            .agent_dashboard_entry(target)
                            .is_some_and(|entry| entry.status != AgentStatus::Stopped)
                    })
                    .notable_branch(|cwd, _| {
                        cwd.ends_with("payments").then(|| "fix/partial-refunds".to_owned())
                    })
                    .projects(move |_| {
                        AGENTS
                            .iter()
                            .map(|agent| {
                                ProjectChoice::at(projects.join(agent.folder).to_string_lossy().into_owned())
                            })
                            .collect()
                    });
                let dashboard = cx.new(|cx| AgentDashboard::new(workspace.clone(), host, window, cx));
                let model = workspace.clone();
                let handle = window.window_handle();
                let elsewhere = directory.join("projects").join("elsewhere");
                cx.subscribe(&dashboard, move |dashboard, event: &DashboardEvent, cx| {
                    println!("{event:?}");
                    match event {
                        DashboardEvent::Close => cx.quit(),
                        DashboardEvent::Open(target) => {
                            model.update(cx, |workspace, cx| {
                                workspace.focus_tab(&target.pane_id, &target.tab_id, true);
                                cx.notify();
                            });
                            cx.quit();
                        }
                        DashboardEvent::Stop(target) => model.update(cx, |workspace, cx| {
                            workspace.stop_agent(target);
                            cx.notify();
                        }),
                        DashboardEvent::Restart(target) => model.update(cx, |workspace, cx| {
                            workspace.restart_agent(target);
                            cx.notify();
                        }),
                        DashboardEvent::Reply { .. } => {}
                        DashboardEvent::SetOption { .. } => {}
                        DashboardEvent::NewThread { profile_id, cwd, prompt, .. } => {
                            let opened = model.update(cx, |workspace, cx| {
                                let target = workspace.open_thread(profile_id, cwd, Some(prompt));
                                workspace.take_changes();
                                cx.notify();
                                target
                            });
                            let _ = handle.update(cx, |_, window, cx| {
                                dashboard.update(cx, |dashboard, cx| match &opened {
                                    Some(target) => dashboard.thread_opened(target, window, cx),
                                    None => dashboard.thread_failed("This agent is not set up.", window, cx),
                                })
                            });
                        }
                        DashboardEvent::ChooseProject => {
                            let path = elsewhere.to_string_lossy().into_owned();
                            let _ = handle.update(cx, |_, window, cx| {
                                dashboard.update(cx, |dashboard, cx| {
                                    dashboard.set_draft_project(&path, window, cx)
                                })
                            });
                        }
                    }
                })
                .detach();
                let focus = dashboard.focus_handle(cx);
                window.focus(&focus, cx);
                if let Some(directory) = snapshot {
                    let dashboard = dashboard.clone();
                    window
                        .spawn(cx, async move |cx| {
                            let result = write_snapshots(directory, agents, dashboard, cx).await;
                            snapshot::finish(result, cx);
                        })
                        .detach();
                }
                let frame = cx.new(|_| DemoFrame { dashboard });
                cx.new(|cx| Root::new(frame, window, cx))
            },
        )
        .expect("the demo window opens");
        if interactive {
            cx.activate(true);
        }
    });
}
