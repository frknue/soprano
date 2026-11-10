//! View parts of `AgentDashboardTests.swift` (`AgentDashboardViewTests`), driven headlessly.

use std::cell::RefCell;
use std::rc::Rc;

use gpui::{
    AppContext as _, Bounds, Entity, Focusable as _, Modifiers, Pixels, TestAppContext, VisualTestContext,
    point, px, size,
};
use soprano_chat_ui::TimelineRowContent;
use soprano_chat_ui::work_log::WorkLogKind;
use soprano_model::Workspace;
use soprano_text::context_line::ContextPart;
use soprano_types::TerminalTarget;
use soprano_types::{AgentConversation, AgentStatus};

use super::{AgentDashboard, DashboardEvent, DashboardHost};
use crate::state::TerminalText;

struct Harness {
    dashboard: Entity<AgentDashboard>,
    workspace: Entity<Workspace>,
    events: Rc<RefCell<Vec<DashboardEvent>>>,
    _home: tempfile::TempDir,
}

/// Opens the dashboard over `workspace` in a `width`×`height` window. The harness plays the
/// shell: Stop and Restart change the workspace, every event is recorded.
fn open(
    cx: &mut TestAppContext,
    workspace: Workspace,
    host: DashboardHost,
    width: f32,
    height: f32,
) -> (Harness, &mut VisualTestContext) {
    cx.update(soprano_ui::init_for_tests);
    let home = tempfile::tempdir().expect("home");
    let host = host.home(home.path());
    let workspace = cx.new(|_| workspace);
    let model = workspace.clone();
    let (dashboard, cx) = cx.add_window_view(move |window, cx| AgentDashboard::new(model, host, window, cx));
    cx.simulate_resize(size(px(width), px(height)));
    let events = Rc::new(RefCell::new(Vec::new()));
    let recorded = events.clone();
    let model = workspace.clone();
    cx.update(|window, cx| {
        cx.subscribe(&dashboard, move |_, event: &DashboardEvent, cx| {
            recorded.borrow_mut().push(event.clone());
            match event {
                DashboardEvent::Stop(target) => model.update(cx, |workspace, cx| {
                    workspace.stop_agent(target);
                    workspace.take_changes();
                    cx.notify();
                }),
                DashboardEvent::Restart(target) => model.update(cx, |workspace, cx| {
                    workspace.restart_agent(target);
                    workspace.take_changes();
                    cx.notify();
                }),
                _ => {}
            }
        })
        .detach();
        let focus = dashboard.focus_handle(cx);
        window.focus(&focus, cx);
    });
    cx.run_until_parked();
    (Harness { dashboard, workspace, events, _home: home }, cx)
}

fn spawn(workspace: &mut Workspace, profile: &str, cwd: &str) -> TerminalTarget {
    let pane = workspace.spawn_agent(profile, Some(cwd), false).expect("pane");
    let tab =
        workspace.pane(&pane).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone()).expect("tab");
    TerminalTarget::new(pane, tab)
}

fn set_status(workspace: &mut Workspace, target: &TerminalTarget, status: AgentStatus) {
    workspace.update_agent_status(&target.pane_id, &target.tab_id, status, None, None);
}

fn change(cx: &mut VisualTestContext, harness: &Harness, mutate: impl FnOnce(&mut Workspace)) {
    harness.workspace.update(cx, |workspace, cx| {
        mutate(workspace);
        workspace.take_changes();
        cx.notify();
    });
    cx.run_until_parked();
}

fn headings(cx: &mut VisualTestContext, harness: &Harness) -> Vec<String> {
    harness.dashboard.read_with(cx, |dashboard, _| {
        dashboard
            .list()
            .sections()
            .iter()
            .map(|(section, entries)| format!("{} {}", section.title(), entries.len()))
            .collect()
    })
}

fn selected_target(cx: &mut VisualTestContext, harness: &Harness) -> Option<TerminalTarget> {
    harness.dashboard.read_with(cx, |dashboard, _| dashboard.list().selected().map(|entry| entry.target()))
}

fn bounds(cx: &mut VisualTestContext, selector: &'static str) -> Bounds<Pixels> {
    cx.run_until_parked();
    cx.debug_bounds(selector).unwrap_or_else(|| panic!("{selector} is drawn"))
}

fn click(cx: &mut VisualTestContext, selector: &'static str) {
    let center = bounds(cx, selector).center();
    cx.simulate_click(center, Modifiers::none());
    cx.run_until_parked();
}

fn list_focused(cx: &mut VisualTestContext, harness: &Harness) -> bool {
    let dashboard = harness.dashboard.clone();
    cx.update(|window, cx| dashboard.read(cx).focus.is_focused(window))
}

fn reply_focused(cx: &mut VisualTestContext, harness: &Harness) -> bool {
    let dashboard = harness.dashboard.clone();
    cx.update(|window, cx| {
        let reply = dashboard.read(cx).reply.clone();
        reply.focus_handle(cx).contains_focused(window, cx)
    })
}

fn reply_draft(cx: &mut VisualTestContext, harness: &Harness) -> String {
    harness.dashboard.read_with(cx, |dashboard, cx| dashboard.reply.read(cx).value().to_string())
}

#[gpui::test]
fn rows_show_the_task_over_the_agent_and_folder_and_follow_renames_and_directory_changes(
    cx: &mut TestAppContext,
) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &target, AgentStatus::Waiting);
    let host = DashboardHost::new()
        .notable_branch(|cwd, _| (cwd == "/tmp/projects/payments").then(|| "feat/refunds".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 800., 700.);

    let home = harness.dashboard.read_with(cx, |dashboard, _| dashboard.host.home.clone());
    let (title, context) = harness.dashboard.read_with(cx, |dashboard, _| {
        let entry = dashboard.list().selected().expect("agent");
        (entry.title(), entry.context(&home).parts())
    });
    // Before Codex titles itself, it goes by its name over its folder.
    assert_eq!(title, "Codex");
    assert_eq!(context, [ContextPart::Text("storefront".into())]);
    let row = cx
        .debug_bounds(Box::leak(
            format!("agent-dashboard-row-{}:{}", target.pane_id, target.tab_id).into_boxed_str(),
        ))
        .expect("row");
    assert_eq!(row.size.height, px(52.));

    let window_id = harness.workspace.read_with(cx, |workspace, _| workspace.active_window_id().to_owned());
    change(cx, &harness, |workspace| {
        workspace.rename_tab(&target.pane_id, &target.tab_id, "⠙ Fix the checkout total");
        workspace.update_working_directory(&target.pane_id, &target.tab_id, "/tmp/projects/payments");
        workspace.rename_window(&window_id, "Payments App");
    });
    harness.dashboard.read_with(cx, |dashboard, _| {
        let entry = dashboard.list().selected().expect("agent");
        assert_eq!(entry.title(), "Fix the checkout total");
        assert_eq!(
            entry.context(&home).parts(),
            [
                ContextPart::Text("Codex".into()),
                ContextPart::Text("payments".into()),
                ContextPart::Branch("feat/refunds".into())
            ]
        );
        assert_eq!(entry.entry.window_title, "Payments App");
        assert!(entry.row_tooltip(&home).contains("/tmp/projects/payments"));
        assert!(entry.accessibility_label().starts_with("Fix the checkout total, Codex"));
    });
}

#[gpui::test]
fn the_dashboard_shows_live_counts_and_the_terminal_and_sends_replies_stops_restarts_and_closes(
    cx: &mut TestAppContext,
) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &target, AgentStatus::Running);
    let host = DashboardHost::new().terminal_text(|_, _| Some("Codex is ready for your reply.".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1200., 760.);

    assert_eq!(
        harness.dashboard.read_with(cx, |dashboard, _| dashboard.subtitle()),
        "Monitoring 1 agent across 1 window"
    );
    assert_eq!(headings(cx, &harness), ["Working 1"]);
    assert!(bounds(cx, "agent-dashboard-list").size.width > px(300.));
    assert!(bounds(cx, "agent-dashboard-detail").size.width > px(500.));
    harness.dashboard.read_with(cx, |dashboard, _| {
        assert!(dashboard.is_showing_terminal());
        assert_eq!(dashboard.terminal_text(), TerminalText::Output("Codex is ready for your reply.".into()));
        assert_eq!(dashboard.reply_hint(), "Press Return to send this single-line reply.");
    });
    bounds(cx, "agent-dashboard-terminal");

    cx.simulate_keystrokes("tab");
    assert!(reply_focused(cx, &harness));
    cx.simulate_input("Run the focused tests");
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert!(
        harness.events.borrow().contains(&DashboardEvent::Reply {
            target: target.clone(),
            text: "Run the focused tests".into()
        })
    );
    assert_eq!(reply_draft(cx, &harness), "");

    click(cx, "agent-dashboard-stop");
    let status = |cx: &mut VisualTestContext| {
        harness.workspace.read_with(cx, |workspace, _| {
            workspace.agent(&target.pane_id, &target.tab_id).map(|agent| agent.status)
        })
    };
    assert_eq!(status(cx), Some(AgentStatus::Stopped));
    assert_eq!(headings(cx, &harness), ["Stopped 1"]);

    click(cx, "agent-dashboard-restart");
    assert_eq!(status(cx), Some(AgentStatus::Starting));
    assert_eq!(headings(cx, &harness), ["Working 1"]);

    cx.simulate_keystrokes("escape");
    assert_eq!(harness.events.borrow().last(), Some(&DashboardEvent::Close));
}

#[gpui::test]
fn j_and_k_move_the_selection_and_return_opens_the_chosen_agent(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let codex = spawn(&mut workspace, "codex", "/tmp/projects/a");
    let claude = spawn(&mut workspace, "claude-code", "/tmp/projects/b");
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 1100., 720.);

    assert_eq!(harness.dashboard.read_with(cx, |dashboard, _| dashboard.list().len()), 2);
    assert_eq!(selected_target(cx, &harness), Some(codex.clone()));
    cx.simulate_keystrokes("j");
    assert_eq!(selected_target(cx, &harness), Some(claude.clone()));
    cx.simulate_keystrokes("k");
    assert_eq!(selected_target(cx, &harness), Some(codex));
    cx.simulate_keystrokes("down enter");
    assert_eq!(harness.events.borrow().last(), Some(&DashboardEvent::Open(claude)));
}

#[gpui::test]
fn j_from_the_terminal_text_moves_the_selection_and_gives_the_list_the_keyboard(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    spawn(&mut workspace, "codex", "/tmp/projects/a");
    let claude = spawn(&mut workspace, "claude-code", "/tmp/projects/b");
    let host = DashboardHost::new().terminal_text(|_, _| Some("Working…".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    click(cx, "agent-dashboard-terminal");
    assert!(!list_focused(cx, &harness));
    cx.simulate_keystrokes("j");
    assert_eq!(selected_target(cx, &harness), Some(claude));
    assert!(list_focused(cx, &harness));
}

#[gpui::test]
fn tab_moves_into_the_reply_field_and_shift_tab_returns_to_the_list_keeping_the_draft(
    cx: &mut TestAppContext,
) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Waiting);
    let host = DashboardHost::new().terminal_text(|_, _| Some("Codex is waiting.".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    cx.simulate_keystrokes("tab");
    assert!(reply_focused(cx, &harness));
    cx.simulate_input("Run the tests");
    // J, K and T are text while the reply field has the keyboard.
    cx.simulate_input(" jkt");
    cx.simulate_keystrokes("shift-tab");
    assert!(list_focused(cx, &harness));
    assert_eq!(reply_draft(cx, &harness), "Run the tests jkt");
    assert!(harness.events.borrow().is_empty());
}

#[gpui::test]
fn a_reply_the_shell_could_not_deliver_comes_back_with_an_error_hint(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Idle);
    let host = DashboardHost::new().terminal_text(|_, _| Some("$".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    cx.simulate_keystrokes("r");
    cx.simulate_input("  Retry  ");
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(
        harness.events.borrow().last(),
        Some(&DashboardEvent::Reply { target: target.clone(), text: "Retry".into() })
    );
    let dashboard = harness.dashboard.clone();
    cx.update(|window, cx| {
        dashboard.update(cx, |dashboard, cx| dashboard.reply_failed(&target, "Retry", window, cx))
    });
    assert_eq!(reply_draft(cx, &harness), "Retry");
    assert_eq!(
        harness.dashboard.read_with(cx, |dashboard, _| dashboard.reply_hint()),
        "Could not send to this terminal."
    );
}

#[gpui::test]
fn replies_wait_for_a_live_terminal(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Running);
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 1100., 720.);

    harness.dashboard.read_with(cx, |dashboard, _| {
        assert_eq!(
            dashboard.terminal_text(),
            TerminalText::Message("This terminal is not currently available.")
        );
        assert_eq!(dashboard.reply_hint(), "Open the agent to initialize its terminal.");
    });
    cx.simulate_keystrokes("tab");
    assert!(!reply_focused(cx, &harness));
    assert!(list_focused(cx, &harness));
}

#[gpui::test]
fn busy_agent_titles_keep_the_list_scroll_position(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let targets: Vec<TerminalTarget> = (0..12)
        .map(|index| spawn(&mut workspace, "codex", &format!("/tmp/projects/project-{index}")))
        .collect();
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 900., 600.);
    let ids = |cx: &mut VisualTestContext| {
        harness
            .dashboard
            .read_with(cx, |dashboard, _| dashboard.list().entries().map(|e| e.id()).collect::<Vec<_>>())
    };
    let before = ids(cx);
    assert_eq!(before.len(), 12);
    harness
        .dashboard
        .read_with(cx, |dashboard, _| dashboard.list_scroll.set_offset(point(px(0.), px(-150.))));
    cx.run_until_parked();

    // Busy agents retitle their tabs several times a second.
    for frame in ["✳", "✶", "✻"] {
        change(cx, &harness, |workspace| {
            workspace.rename_tab(
                &targets[5].pane_id,
                &targets[5].tab_id,
                &format!("{frame} Running the tests"),
            );
        });
    }

    assert_eq!(ids(cx), before);
    harness.dashboard.read_with(cx, |dashboard, _| {
        let busy = dashboard
            .list()
            .entry(&format!("{}:{}", targets[5].pane_id, targets[5].tab_id))
            .expect("busy agent");
        assert!(busy.row_tooltip(&dashboard.host.home).starts_with("Running the tests\n"));
        assert_eq!(dashboard.list_scroll.offset().y, px(-150.));
    });
}

#[gpui::test]
fn status_changes_move_the_rows_into_urgency_order_and_refresh_the_counts(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let targets: Vec<TerminalTarget> = (0..3)
        .map(|index| {
            let target = spawn(&mut workspace, "codex", &format!("/tmp/projects/project-{index}"));
            set_status(&mut workspace, &target, AgentStatus::Running);
            target
        })
        .collect();
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 900., 700.);
    let folders = |cx: &mut VisualTestContext| {
        harness.dashboard.read_with(cx, |dashboard, _| {
            dashboard.list().entries().filter_map(|e| e.entry.cwd.clone()).collect::<Vec<_>>()
        })
    };
    assert_eq!(
        folders(cx),
        ["/tmp/projects/project-0", "/tmp/projects/project-1", "/tmp/projects/project-2"]
    );

    change(cx, &harness, |workspace| {
        set_status(workspace, &targets[2], AgentStatus::Waiting);
        spawn(workspace, "claude-code", "/tmp/projects/project-3");
    });
    assert_eq!(
        folders(cx),
        [
            "/tmp/projects/project-2",
            "/tmp/projects/project-0",
            "/tmp/projects/project-1",
            "/tmp/projects/project-3"
        ]
    );
    assert_eq!(headings(cx, &harness), ["Needs you 1", "Working 3"]);
}

#[gpui::test]
fn stop_and_restart_stay_in_the_toolbar_and_work_in_the_narrowest_window(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &target, AgentStatus::Running);
    // `MainWindowSizing.minimumFrameSize`.
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 600., 400.);
    let window = Bounds::new(point(px(0.), px(0.)), size(px(600.), px(400.)));

    let stop = bounds(cx, "agent-dashboard-stop");
    assert!(window.contains(&stop.origin) && window.contains(&stop.bottom_right()), "{stop:?}");
    click(cx, "agent-dashboard-stop");
    let status = |cx: &mut VisualTestContext| {
        harness.workspace.read_with(cx, |workspace, _| {
            workspace.agent(&target.pane_id, &target.tab_id).map(|agent| agent.status)
        })
    };
    assert_eq!(status(cx), Some(AgentStatus::Stopped));

    let restart = bounds(cx, "agent-dashboard-restart");
    assert!(window.contains(&restart.origin) && window.contains(&restart.bottom_right()), "{restart:?}");
    click(cx, "agent-dashboard-restart");
    assert_eq!(status(cx), Some(AgentStatus::Starting));
}

#[gpui::test]
fn a_narrow_window_gives_the_list_its_share(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    let (_harness, cx) = open(cx, workspace, DashboardHost::new(), 700., 600.);
    assert_eq!(bounds(cx, "agent-dashboard-list").size.width, px(280.));
    cx.simulate_resize(size(px(1000.), px(600.)));
    assert_eq!(bounds(cx, "agent-dashboard-list").size.width, px(380.));
}

#[gpui::test]
fn an_empty_dashboard_says_so_and_offers_no_agent_actions(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, Workspace::new(), DashboardHost::new(), 900., 600.);
    harness.dashboard.read_with(cx, |dashboard, _| {
        assert!(dashboard.list().is_empty());
        assert_eq!(dashboard.subtitle(), "Monitoring 0 agents across 1 window");
    });
    cx.simulate_keystrokes("j enter t o g ] tab");
    cx.run_until_parked();
    assert!(cx.debug_bounds("agent-dashboard-stop").is_none());
    assert!(!reply_focused(cx, &harness));
    assert!(harness.events.borrow().is_empty());
}

/// A Claude Code transcript of three turns: a prompt, `swift test`, and a long answer.
fn write_transcript(directory: &std::path::Path) -> std::path::PathBuf {
    let reply = (1..=8)
        .map(|n| format!("Paragraph {n} of the answer, long enough to take a line of its own."))
        .collect::<Vec<_>>()
        .join("\\n\\n");
    let cwd = directory.display();
    let mut lines = Vec::new();
    let mut parent = "null".to_owned();
    for turn in 1..=3 {
        let minute = format!("{:02}", turn * 2);
        lines.push(format!(
            r#"{{"type":"user","uuid":"u{turn}","parentUuid":{parent},"cwd":"{cwd}","timestamp":"2026-11-08T09:{minute}:00.000Z","message":{{"role":"user","content":"Prompt {turn}"}}}}"#
        ));
        lines.push(format!(
            r#"{{"type":"assistant","uuid":"c{turn}","parentUuid":"u{turn}","timestamp":"2026-11-08T09:{minute}:05.000Z","message":{{"role":"assistant","content":[{{"type":"tool_use","id":"t{turn}","name":"Bash","input":{{"command":"swift test"}}}}]}}}}"#
        ));
        lines.push(format!(
            r#"{{"type":"user","uuid":"o{turn}","parentUuid":"c{turn}","timestamp":"2026-11-08T09:{minute}:20.000Z","message":{{"role":"user","content":[{{"type":"tool_result","tool_use_id":"t{turn}","content":"ignored"}}]}},"toolUseResult":{{"stdout":"passed","stderr":"","interrupted":false,"isImage":false}}}}"#
        ));
        lines.push(format!(
            r#"{{"type":"assistant","uuid":"r{turn}","parentUuid":"o{turn}","timestamp":"2026-11-08T09:{minute}:40.000Z","message":{{"role":"assistant","content":[{{"type":"text","text":"{reply}"}}]}}}}"#
        ));
        parent = format!("\"r{turn}\"");
    }
    let path = directory.join("session.jsonl");
    std::fs::write(&path, lines.join("\n") + "\n").expect("transcript");
    path
}

#[gpui::test]
fn an_agents_transcript_reads_as_the_chat_timeline_with_prompt_jumps_details_on_o_and_the_terminal_on_t(
    cx: &mut TestAppContext,
) {
    // The transcript store reads on its own worker thread and wakes the dashboard from there.
    cx.executor().allow_parking();
    let directory = tempfile::tempdir().expect("directory");
    let transcript = write_transcript(directory.path());
    let cwd = directory.path().to_string_lossy().into_owned();
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "claude-code", &cwd);
    set_status(&mut workspace, &target, AgentStatus::Idle);
    workspace.record_agent_conversation(
        AgentConversation {
            id: "dashboard-timeline".into(),
            cwd: Some(cwd.clone()),
            transcript_path: Some(transcript.to_string_lossy().into_owned()),
        },
        &target.pane_id,
        &target.tab_id,
        None,
    );
    let host = DashboardHost::new().terminal_text(|_, _| Some("claude ❯".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 900., 520.);
    let timeline = harness.dashboard.read_with(cx, |dashboard, _| dashboard.timeline_view().clone());
    let user_rows = |cx: &mut VisualTestContext| {
        timeline.read_with(cx, |timeline, _| {
            timeline.rows().iter().filter(|row| matches!(row.content, TimelineRowContent::User(_))).count()
        })
    };
    // The transcript is read on the store's worker thread.
    for _ in 0..300 {
        cx.run_until_parked();
        if user_rows(cx) >= 3 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    // The prompts as bubbles, each finished turn folded behind "Worked for …" in the minimal
    // work log, the answers as Markdown.
    assert!(!harness.dashboard.read_with(cx, |dashboard, _| dashboard.is_showing_terminal()));
    assert_eq!(user_rows(cx), 3);
    timeline.read_with(cx, |timeline, _| {
        let folds: Vec<&str> = timeline
            .rows()
            .iter()
            .filter_map(|row| match &row.content {
                TimelineRowContent::Fold(fold) => Some(fold.label.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(folds, ["Worked for 40s", "Worked for 40s", "Worked for 40s"]);
        assert!(timeline.rows().iter().any(|row| matches!(row.content, TimelineRowContent::Assistant(_))));
        assert!(!timeline.is_detailed());
        assert!(timeline.is_following());
    });
    assert_eq!(harness.dashboard.read_with(cx, |dashboard, _| dashboard.activity_text()), {
        "Replied · Paragraph 1 of the answer, long enough to take a line of its own."
    });

    // [ leaves the newest entry for an earlier prompt; G follows the newest again.
    cx.simulate_keystrokes("[ [");
    assert!(!timeline.read_with(cx, |timeline, _| timeline.is_following()));
    cx.simulate_keystrokes("g");
    assert!(timeline.read_with(cx, |timeline, _| timeline.is_following()));

    // O opens the detailed work log: the folds open and the commands show.
    cx.simulate_keystrokes("o");
    timeline.read_with(cx, |timeline, _| {
        assert!(timeline.is_detailed());
        assert!(timeline.rows().iter().any(|row| {
            matches!(&row.content, TimelineRowContent::WorkEntry(model) if model.entry.kind == WorkLogKind::Command)
        }));
    });

    // T shows the live terminal, and back.
    cx.simulate_keystrokes("t");
    harness.dashboard.read_with(cx, |dashboard, _| {
        assert!(dashboard.is_showing_terminal());
        assert_eq!(dashboard.terminal_text(), TerminalText::Output("claude ❯".into()));
    });
    cx.simulate_keystrokes("t");
    assert!(!harness.dashboard.read_with(cx, |dashboard, _| dashboard.is_showing_terminal()));
}

#[gpui::test]
fn a_chat_tab_takes_replies_through_the_host_and_a_failure_gives_way_to_the_status_hint(
    cx: &mut TestAppContext,
) {
    let mut workspace = Workspace::new();
    let pane = workspace.spawn_agent("omp", Some("/tmp/projects/a"), true).expect("chat pane");
    let tab =
        workspace.pane(&pane).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone()).expect("tab");
    let chat = TerminalTarget::new(pane, tab);
    set_status(&mut workspace, &chat, AgentStatus::Running);
    // The shell reports a running chat as available with no terminal text.
    let host = DashboardHost::new().terminal_text(|_, _| Some(String::new()));
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    // A chat always shows its conversation, never a terminal.
    assert!(!harness.dashboard.read_with(cx, |dashboard, _| dashboard.is_showing_terminal()));
    cx.simulate_keystrokes("r");
    assert!(reply_focused(cx, &harness));
    cx.simulate_input("Summarize the diff");
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(
        harness.events.borrow().last(),
        Some(&DashboardEvent::Reply { target: chat.clone(), text: "Summarize the diff".into() })
    );

    let dashboard = harness.dashboard.clone();
    cx.update(|window, cx| {
        dashboard.update(cx, |dashboard, cx| dashboard.reply_failed(&chat, "Summarize the diff", window, cx))
    });
    assert_eq!(
        harness.dashboard.read_with(cx, |dashboard, _| dashboard.reply_hint()),
        "Could not send to this terminal."
    );
    // A new status puts the status hint back, as Swift's `updateControls` does.
    change(cx, &harness, |workspace| set_status(workspace, &chat, AgentStatus::Waiting));
    assert_eq!(
        harness.dashboard.read_with(cx, |dashboard, _| dashboard.reply_hint()),
        "Press Return to send this single-line reply."
    );
    assert_eq!(reply_draft(cx, &harness), "Summarize the diff");
}

#[gpui::test]
fn a_failed_send_gives_way_when_the_terminal_goes_away(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Idle);
    let available = Rc::new(std::cell::Cell::new(true));
    let live = available.clone();
    let host = DashboardHost::new().terminal_text(move |_, _| live.get().then(|| "$".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    let dashboard = harness.dashboard.clone();
    cx.update(|window, cx| {
        dashboard.update(cx, |dashboard, cx| dashboard.reply_failed(&target, "x", window, cx))
    });
    assert_eq!(
        harness.dashboard.read_with(cx, |dashboard, _| dashboard.reply_hint()),
        "Could not send to this terminal."
    );
    available.set(false);
    change(cx, &harness, |_| {});
    assert_eq!(
        harness.dashboard.read_with(cx, |dashboard, _| dashboard.reply_hint()),
        "Open the agent to initialize its terminal."
    );
}

#[gpui::test]
fn selecting_another_agent_clears_the_reply_draft(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let first = spawn(&mut workspace, "codex", "/tmp/projects/a");
    let second = spawn(&mut workspace, "claude-code", "/tmp/projects/b");
    for target in [&first, &second] {
        set_status(&mut workspace, target, AgentStatus::Waiting);
    }
    let host = DashboardHost::new().terminal_text(|_, _| Some("waiting".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    cx.simulate_keystrokes("tab");
    cx.simulate_input("Half-written reply");
    cx.simulate_keystrokes("shift-tab");
    assert_eq!(reply_draft(cx, &harness), "Half-written reply");
    cx.simulate_keystrokes("j");
    assert_eq!(selected_target(cx, &harness), Some(second));
    assert_eq!(reply_draft(cx, &harness), "");
    cx.simulate_keystrokes("k");
    assert_eq!(selected_target(cx, &harness), Some(first));
    assert_eq!(reply_draft(cx, &harness), "");
}

#[gpui::test]
fn escape_in_the_reply_field_closes_the_dashboard_without_sending(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Waiting);
    let host = DashboardHost::new().terminal_text(|_, _| Some("waiting".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    cx.simulate_keystrokes("tab");
    cx.simulate_input("Never mind");
    assert!(reply_focused(cx, &harness));
    cx.simulate_keystrokes("escape");
    assert_eq!(*harness.events.borrow(), [DashboardEvent::Close]);
}
