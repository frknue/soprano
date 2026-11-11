//! The dashboard driven headlessly: the inbox, the chat column, and drafting a new thread.

use std::cell::RefCell;
use std::rc::Rc;

use gpui::{
    AppContext as _, Bounds, Entity, Focusable as _, Modifiers, Pixels, TestAppContext, VisualTestContext,
    point, px, size,
};
use soprano_agents::AgentDashboardSection;
use soprano_chat_ui::TimelineRowContent;
use soprano_chat_ui::work_log::WorkLogKind;
use soprano_model::Workspace;
use soprano_platform::StateStore;
use soprano_types::TerminalTarget;
use soprano_types::{AgentConversation, AgentStatus};

use super::{AgentDashboard, DashboardEvent, DashboardHost};
use crate::state::{AgentChoice, ListRow};

struct Harness {
    dashboard: Entity<AgentDashboard>,
    workspace: Entity<Workspace>,
    events: Rc<RefCell<Vec<DashboardEvent>>>,
    _home: tempfile::TempDir,
}

/// A host whose agents all take messages.
fn replying() -> DashboardHost {
    DashboardHost::new().accepts_replies(|_, _| true)
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

fn change<R>(cx: &mut VisualTestContext, harness: &Harness, mutate: impl FnOnce(&mut Workspace) -> R) -> R {
    let result = harness.workspace.update(cx, |workspace, cx| {
        let result = mutate(workspace);
        workspace.take_changes();
        cx.notify();
        result
    });
    cx.run_until_parked();
    result
}

/// The inbox as it reads top to bottom.
fn shown(cx: &mut VisualTestContext, harness: &Harness) -> Vec<String> {
    harness.dashboard.read_with(cx, |dashboard, _| {
        dashboard
            .list()
            .rows()
            .into_iter()
            .map(|row| match row {
                ListRow::Header { section, count, folded } => {
                    format!("{} {count}{}", section.title(), if folded { " ›" } else { "" })
                }
                ListRow::Card(entry) => format!("card {}", entry.project),
                ListRow::Slim(entry) => format!("slim {}", entry.project),
            })
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

/// Where a thread's row is drawn. `debug_bounds` only takes a `'static` selector, and a row's
/// is made of its ids: the test process keeps the few it asks for.
fn row_bounds(cx: &mut VisualTestContext, target: &TerminalTarget) -> Bounds<Pixels> {
    bounds(
        cx,
        Box::leak(format!("agent-dashboard-row-{}:{}", target.pane_id, target.tab_id).into_boxed_str()),
    )
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

fn composer_focused(cx: &mut VisualTestContext, harness: &Harness) -> bool {
    let dashboard = harness.dashboard.clone();
    cx.update(|window, cx| {
        let editor = dashboard.read(cx).editor.clone();
        editor.focus_handle(cx).contains_focused(window, cx)
    })
}

fn composer_text(cx: &mut VisualTestContext, harness: &Harness) -> String {
    harness.dashboard.read_with(cx, |dashboard, cx| dashboard.composer_text(cx))
}

fn hint(cx: &mut VisualTestContext, harness: &Harness) -> (String, bool) {
    harness.dashboard.read_with(cx, |dashboard, _| dashboard.composer_hint())
}

#[gpui::test]
fn cards_show_the_project_over_the_task_and_follow_renames_and_directory_changes(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &target, AgentStatus::Waiting);
    let host = DashboardHost::new()
        .notable_branch(|cwd, _| (cwd == "/tmp/projects/payments").then(|| "feat/refunds".to_owned()));
    let (harness, cx) = open(cx, workspace, host, 1000., 700.);

    // Before Codex titles itself, it goes by its name under its project; without a branch
    // the card has two lines.
    harness.dashboard.read_with(cx, |dashboard, _| {
        let entry = dashboard.list().selected().expect("thread");
        assert_eq!((entry.title().as_str(), entry.project.as_str()), ("Codex", "storefront"));
        // A wait without a stated reason reads as a finished turn.
        assert_eq!(entry.pill().map(|pill| pill.label), Some("Done"));
    });
    assert_eq!(row_bounds(cx, &target).size.height, px(63.));

    let window_id = harness.workspace.read_with(cx, |workspace, _| workspace.active_window_id().to_owned());
    change(cx, &harness, |workspace| {
        workspace.rename_tab(&target.pane_id, &target.tab_id, "⠙ Fix the checkout total");
        workspace.update_working_directory(&target.pane_id, &target.tab_id, "/tmp/projects/payments");
        workspace.rename_window(&window_id, "Payments App");
    });
    harness.dashboard.read_with(cx, |dashboard, _| {
        let entry = dashboard.list().selected().expect("thread");
        assert_eq!((entry.title().as_str(), entry.project.as_str()), ("Fix the checkout total", "payments"));
        assert_eq!(entry.entry.branch.as_deref(), Some("feat/refunds"));
        assert_eq!(entry.entry.window_title, "Payments App");
        assert!(entry.row_tooltip(&dashboard.host.home).contains("/tmp/projects/payments"));
    });
    // The branch takes a third line.
    assert_eq!(row_bounds(cx, &target).size.height, px(83.));
}

#[gpui::test]
fn the_chat_sends_messages_stops_and_restarts_the_agent_and_escape_closes_the_dashboard(
    cx: &mut TestAppContext,
) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &target, AgentStatus::Running);
    let (harness, cx) = open(cx, workspace, replying(), 1200., 760.);

    assert_eq!(shown(cx, &harness), ["Working 1", "card storefront"]);
    assert_eq!(bounds(cx, "agent-dashboard-list").size.width, px(256.));
    assert!(bounds(cx, "agent-dashboard-detail").size.width > px(900.));
    assert_eq!(hint(cx, &harness), (String::new(), false));

    cx.simulate_keystrokes("tab");
    assert!(composer_focused(cx, &harness));
    cx.simulate_input("Run the focused tests");
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert!(
        harness.events.borrow().contains(&DashboardEvent::Reply {
            target: target.clone(),
            text: "Run the focused tests".into()
        })
    );
    assert_eq!(composer_text(cx, &harness), "");

    click(cx, "agent-dashboard-stop");
    let status = |cx: &mut VisualTestContext| {
        harness.workspace.read_with(cx, |workspace, _| {
            workspace.agent(&target.pane_id, &target.tab_id).map(|agent| agent.status)
        })
    };
    assert_eq!(status(cx), Some(AgentStatus::Stopped));
    // The open thread stays listed in the folded Stopped shelf.
    assert_eq!(shown(cx, &harness), ["Stopped 1 ›", "slim storefront"]);
    assert_eq!(hint(cx, &harness), ("Restart the agent to message it.".to_owned(), false));

    click(cx, "agent-dashboard-restart");
    assert_eq!(status(cx), Some(AgentStatus::Starting));
    assert_eq!(shown(cx, &harness), ["Working 1", "card storefront"]);

    // Out of the composer first, then out of the dashboard.
    cx.simulate_keystrokes("escape");
    assert!(list_focused(cx, &harness));
    assert!(!harness.events.borrow().contains(&DashboardEvent::Close));
    cx.simulate_keystrokes("escape");
    assert_eq!(harness.events.borrow().last(), Some(&DashboardEvent::Close));
}

#[gpui::test]
fn a_message_keeps_the_lines_shift_return_adds(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &target, AgentStatus::Idle);
    let (harness, cx) = open(cx, workspace, replying(), 1100., 720.);

    cx.simulate_keystrokes("r");
    cx.simulate_input("Run the tests");
    cx.simulate_keystrokes("shift-enter");
    cx.simulate_input("Then commit");
    assert!(harness.events.borrow().is_empty());
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(
        harness.events.borrow().last(),
        Some(&DashboardEvent::Reply { target, text: "Run the tests\nThen commit".into() })
    );
}

#[gpui::test]
fn j_and_k_move_the_selection_and_return_opens_the_chosen_thread(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let codex = spawn(&mut workspace, "codex", "/tmp/projects/a");
    let claude = spawn(&mut workspace, "claude-code", "/tmp/projects/b");
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 1100., 720.);

    assert_eq!(harness.dashboard.read_with(cx, |dashboard, _| dashboard.list().len()), 2);
    assert_eq!(selected_target(cx, &harness), Some(codex.clone()));
    cx.simulate_keystrokes("j");
    assert_eq!(selected_target(cx, &harness), Some(claude.clone()));
    cx.simulate_keystrokes("k");
    assert_eq!(selected_target(cx, &harness), Some(codex.clone()));
    cx.simulate_keystrokes("down enter");
    assert_eq!(harness.events.borrow().last(), Some(&DashboardEvent::Open(claude.clone())));

    // A click opens a thread here, a double-click in its window.
    let first = row_bounds(cx, &codex).center();
    cx.simulate_click(first, Modifiers::none());
    assert_eq!(selected_target(cx, &harness), Some(codex.clone()));
    assert_eq!(harness.events.borrow().len(), 1);
    cx.simulate_event(gpui::MouseDownEvent {
        position: first,
        modifiers: Modifiers::none(),
        button: gpui::MouseButton::Left,
        click_count: 2,
        first_mouse: false,
    });
    cx.simulate_event(gpui::MouseUpEvent {
        position: first,
        modifiers: Modifiers::none(),
        button: gpui::MouseButton::Left,
        click_count: 2,
    });
    cx.run_until_parked();
    assert_eq!(harness.events.borrow().last(), Some(&DashboardEvent::Open(codex)));
}

#[gpui::test]
fn tab_moves_into_the_composer_and_shift_tab_returns_to_the_list_keeping_the_text(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Waiting);
    let (harness, cx) = open(cx, workspace, replying(), 1100., 720.);

    cx.simulate_keystrokes("tab");
    assert!(composer_focused(cx, &harness));
    cx.simulate_input("Run the tests");
    // J, K, N and O are text while the composer has the keyboard.
    cx.simulate_input(" jkno");
    cx.simulate_keystrokes("shift-tab");
    assert!(list_focused(cx, &harness));
    assert_eq!(composer_text(cx, &harness), "Run the tests jkno");
    assert!(harness.events.borrow().is_empty());
    assert!(!harness.dashboard.read_with(cx, |dashboard, _| dashboard.is_drafting()));
}

#[gpui::test]
fn a_message_the_shell_could_not_deliver_comes_back_with_an_error_hint(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Idle);
    let (harness, cx) = open(cx, workspace, replying(), 1100., 720.);

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
    cx.run_until_parked();
    assert_eq!(composer_text(cx, &harness), "Retry");
    assert_eq!(hint(cx, &harness), ("Could not send to this agent.".to_owned(), true));

    // A new status puts the status hint back; the text stays.
    change(cx, &harness, |workspace| set_status(workspace, &target, AgentStatus::Waiting));
    assert_eq!(hint(cx, &harness), (String::new(), false));
    assert_eq!(composer_text(cx, &harness), "Retry");
}

#[gpui::test]
fn messages_wait_for_an_agent_that_takes_them(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/a");
    set_status(&mut workspace, &target, AgentStatus::Running);
    let available = Rc::new(std::cell::Cell::new(false));
    let live = available.clone();
    let host = DashboardHost::new().accepts_replies(move |_, _| live.get());
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    assert_eq!(hint(cx, &harness), ("Open the agent in its window to start it.".to_owned(), false));
    cx.simulate_keystrokes("tab");
    assert!(!composer_focused(cx, &harness));
    assert!(list_focused(cx, &harness));

    available.set(true);
    change(cx, &harness, |_| {});
    assert_eq!(hint(cx, &harness), (String::new(), false));
    cx.simulate_keystrokes("tab");
    assert!(composer_focused(cx, &harness));
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
        assert_eq!(busy.title(), "Running the tests");
        assert_eq!(dashboard.list_scroll.offset().y, px(-150.));
    });
}

#[gpui::test]
fn status_changes_move_the_cards_into_urgency_order_and_refresh_the_counts(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let targets: Vec<TerminalTarget> = (0..3)
        .map(|index| {
            let target = spawn(&mut workspace, "codex", &format!("/tmp/projects/project-{index}"));
            set_status(&mut workspace, &target, AgentStatus::Running);
            target
        })
        .collect();
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 900., 700.);
    assert_eq!(shown(cx, &harness), ["Working 3", "card project-0", "card project-1", "card project-2"]);

    change(cx, &harness, |workspace| {
        set_status(workspace, &targets[2], AgentStatus::Waiting);
        spawn(workspace, "claude-code", "/tmp/projects/project-3");
    });
    assert_eq!(
        shown(cx, &harness),
        ["Needs you 1", "card project-2", "Working 3", "card project-0", "card project-1", "card project-3"]
    );
}

#[gpui::test]
fn the_stopped_shelf_unfolds_into_one_line_rows_and_a_search_narrows_the_inbox(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let running = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &running, AgentStatus::Running);
    let stopped = spawn(&mut workspace, "claude-code", "/tmp/projects/payments");
    workspace.stop_agent(&stopped);
    let (harness, cx) = open(cx, workspace, DashboardHost::new(), 1000., 700.);

    assert_eq!(shown(cx, &harness), ["Working 1", "card storefront", "Stopped 1 ›"]);
    let dashboard = harness.dashboard.clone();
    cx.update(|_, cx| {
        dashboard.update(cx, |dashboard, cx| dashboard.toggle_fold(AgentDashboardSection::Stopped, cx))
    });
    assert_eq!(shown(cx, &harness), ["Working 1", "card storefront", "Stopped 1", "slim payments"]);
    assert_eq!(row_bounds(cx, &stopped).size.height, px(37.));
    cx.simulate_keystrokes("j");
    assert_eq!(selected_target(cx, &harness), Some(stopped.clone()));

    // `/` searches; the arrows keep moving the selection, Escape drops the search.
    cx.simulate_keystrokes("/");
    cx.simulate_input("store");
    assert_eq!(shown(cx, &harness), ["card storefront"]);
    assert_eq!(selected_target(cx, &harness), Some(stopped));
    cx.simulate_keystrokes("down");
    assert_eq!(selected_target(cx, &harness), Some(running));
    cx.simulate_keystrokes("escape");
    assert!(list_focused(cx, &harness));
    assert_eq!(shown(cx, &harness), ["Working 1", "card storefront", "Stopped 1", "slim payments"]);
    assert!(harness.events.borrow().is_empty());
}

#[gpui::test]
fn stop_and_restart_stay_in_the_header_and_work_in_a_narrow_window(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let target = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &target, AgentStatus::Running);
    workspace.rename_tab(
        &target.pane_id,
        &target.tab_id,
        "Upgrade the Terraform providers and fix what breaks",
    );
    let host = DashboardHost::new().notable_branch(|_, _| Some("chore/terraform-provider-upgrades".into()));
    let (harness, cx) = open(cx, workspace, host, 600., 400.);
    let window = Bounds::new(point(px(0.), px(0.)), size(px(600.), px(400.)));

    // The list takes its 40 % at most.
    assert_eq!(bounds(cx, "agent-dashboard-list").size.width, px(240.));
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
    let composer = bounds(cx, "agent-dashboard-composer");
    assert!(window.contains(&composer.origin) && window.contains(&composer.bottom_right()), "{composer:?}");
}

#[gpui::test]
fn a_dashboard_without_threads_opens_on_a_new_one_and_escape_closes_it(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, Workspace::new(), DashboardHost::new(), 900., 600.);
    harness.dashboard.read_with(cx, |dashboard, _| {
        assert!(dashboard.list().is_empty());
        assert!(dashboard.is_drafting());
    });
    bounds(cx, "agent-dashboard-draft");
    // The thread keys have nothing to act on, and an empty draft sends nothing.
    cx.simulate_keystrokes("j enter o g ] tab enter");
    cx.run_until_parked();
    assert!(cx.debug_bounds("agent-dashboard-stop").is_none());
    assert!(harness.events.borrow().is_empty());
    assert!(harness.dashboard.read_with(cx, |dashboard, _| dashboard.is_drafting()));

    cx.simulate_keystrokes("escape escape");
    assert_eq!(*harness.events.borrow(), [DashboardEvent::Close]);
}

#[gpui::test]
fn a_new_thread_starts_in_the_open_threads_project_and_gives_way_to_the_thread_the_shell_opens(
    cx: &mut TestAppContext,
) {
    let mut workspace = Workspace::new();
    let first = spawn(&mut workspace, "codex", "/tmp/projects/storefront");
    set_status(&mut workspace, &first, AgentStatus::Idle);
    let window_title = workspace.active_window().map(|window| window.title.clone());
    let state = StateStore::in_memory();
    let (harness, cx) = open(cx, workspace, replying().state(state.clone()), 1100., 720.);

    cx.simulate_keystrokes("n");
    assert!(composer_focused(cx, &harness));
    let cwd = harness.dashboard.read_with(cx, |dashboard, _| {
        let (project, agent) = dashboard.draft_choice().expect("draft");
        assert_eq!(project.name, "storefront");
        assert_eq!(agent, &AgentChoice { profile_id: "omp".into(), chat: false });
        // Its tab joins the window that already works there.
        assert_eq!(dashboard.draft.as_ref().and_then(|draft| draft.window_title.clone()), window_title);
        project.path.clone()
    });

    // A chat instead, in another folder no window works in.
    let dashboard = harness.dashboard.clone();
    cx.update(|window, cx| {
        dashboard.update(cx, |dashboard, cx| {
            dashboard.set_draft_agent(AgentChoice { profile_id: "omp".into(), chat: true }, cx);
            dashboard.set_draft_project("/tmp/projects/elsewhere", window, cx);
            assert_eq!(dashboard.draft.as_ref().and_then(|draft| draft.window_title.clone()), None);
            dashboard.set_draft_project(&cwd, window, cx);
        })
    });
    cx.simulate_input("Fix the totals");
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(
        harness.events.borrow().last(),
        Some(&DashboardEvent::NewThread {
            profile_id: "omp".into(),
            chat: true,
            cwd: cwd.clone(),
            prompt: "Fix the totals".into()
        })
    );
    // Until the shell answers, the draft waits as written.
    assert_eq!(hint(cx, &harness), ("Starting omp…".to_owned(), false));
    assert_eq!(composer_text(cx, &harness), "Fix the totals");
    cx.simulate_keystrokes("enter");
    assert_eq!(harness.events.borrow().len(), 1);

    // The shell could not: the draft says why and can be sent again.
    cx.update(|window, cx| {
        dashboard.update(cx, |dashboard, cx| dashboard.thread_failed("omp is not installed.", window, cx))
    });
    assert_eq!(hint(cx, &harness), ("omp is not installed.".to_owned(), true));
    assert_eq!(composer_text(cx, &harness), "Fix the totals");
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(harness.events.borrow().len(), 2);

    // The shell opened it: the thread takes the draft's place.
    let opened =
        change(cx, &harness, |workspace| workspace.open_thread("omp", true, &cwd, None)).expect("thread");
    cx.update(|window, cx| {
        dashboard.update(cx, |dashboard, cx| dashboard.thread_opened(&opened, window, cx))
    });
    cx.run_until_parked();
    assert!(!harness.dashboard.read_with(cx, |dashboard, _| dashboard.is_drafting()));
    assert_eq!(selected_target(cx, &harness), Some(opened));
    assert_eq!(composer_text(cx, &harness), "");

    // The next draft starts with the agent the last thread started with.
    assert_eq!(AgentChoice::initial(&state), Some(AgentChoice { profile_id: "omp".into(), chat: true }));
}

#[gpui::test]
fn escape_gives_a_draft_up_for_the_open_thread_and_so_does_choosing_a_thread(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let first = spawn(&mut workspace, "codex", "/tmp/projects/a");
    let second = spawn(&mut workspace, "claude-code", "/tmp/projects/b");
    let (harness, cx) = open(cx, workspace, replying(), 1100., 720.);
    let drafting =
        |cx: &mut VisualTestContext| harness.dashboard.read_with(cx, |dashboard, _| dashboard.is_drafting());

    click(cx, "agent-dashboard-new-thread");
    assert!(drafting(cx));
    cx.simulate_input("Half an idea");
    // Out of the composer, then out of the draft; the thread that was open shows again.
    cx.simulate_keystrokes("escape escape");
    assert!(!drafting(cx));
    assert_eq!(selected_target(cx, &harness), Some(first.clone()));
    assert_eq!(composer_text(cx, &harness), "");
    assert!(harness.events.borrow().is_empty());

    cx.simulate_keystrokes("n escape j");
    assert!(!drafting(cx));
    assert_eq!(selected_target(cx, &harness), Some(first));
    cx.simulate_keystrokes("n");
    let other = row_bounds(cx, &second).center();
    cx.simulate_click(other, Modifiers::none());
    assert!(!drafting(cx));
    assert_eq!(selected_target(cx, &harness), Some(second));
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
fn an_agents_transcript_reads_as_the_chat_timeline_with_prompt_jumps_and_details_on_o(
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
    let (harness, cx) = open(cx, workspace, replying(), 900., 520.);
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
    // The thread's card says what the agent last said, which takes its third line.
    harness.dashboard.read_with(cx, |dashboard, _| {
        let entry = dashboard.list().selected().expect("thread");
        assert_eq!(
            dashboard.current_activity(entry).map(|activity| activity.text()).as_deref(),
            Some("Replied · Paragraph 1 of the answer, long enough to take a line of its own.")
        );
    });
    assert_eq!(row_bounds(cx, &target).size.height, px(83.));

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
    click(cx, "agent-dashboard-details");
    assert!(!timeline.read_with(cx, |timeline, _| timeline.is_detailed()));
}

#[gpui::test]
fn a_chat_tab_takes_messages_through_the_host(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let pane = workspace.spawn_agent("omp", Some("/tmp/projects/a"), true).expect("chat pane");
    let tab =
        workspace.pane(&pane).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone()).expect("tab");
    let chat = TerminalTarget::new(pane, tab);
    set_status(&mut workspace, &chat, AgentStatus::Running);
    let available = Rc::new(std::cell::Cell::new(true));
    let live = available.clone();
    let host = DashboardHost::new().accepts_replies(move |_, _| live.get());
    let (harness, cx) = open(cx, workspace, host, 1100., 720.);

    cx.simulate_keystrokes("r");
    assert!(composer_focused(cx, &harness));
    cx.simulate_input("Summarize the diff");
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(
        harness.events.borrow().last(),
        Some(&DashboardEvent::Reply { target: chat.clone(), text: "Summarize the diff".into() })
    );

    // A chat whose session ended says to restart it, where a terminal agent says to open it.
    available.set(false);
    change(cx, &harness, |_| {});
    assert_eq!(hint(cx, &harness), ("Restart the agent to message it.".to_owned(), false));
}

#[gpui::test]
fn selecting_another_thread_clears_the_composer(cx: &mut TestAppContext) {
    let mut workspace = Workspace::new();
    let first = spawn(&mut workspace, "codex", "/tmp/projects/a");
    let second = spawn(&mut workspace, "claude-code", "/tmp/projects/b");
    for target in [&first, &second] {
        set_status(&mut workspace, target, AgentStatus::Waiting);
    }
    let (harness, cx) = open(cx, workspace, replying(), 1100., 720.);

    cx.simulate_keystrokes("tab");
    cx.simulate_input("Half-written message");
    cx.simulate_keystrokes("shift-tab");
    assert_eq!(composer_text(cx, &harness), "Half-written message");
    cx.simulate_keystrokes("j");
    assert_eq!(selected_target(cx, &harness), Some(second));
    assert_eq!(composer_text(cx, &harness), "");
    cx.simulate_keystrokes("k");
    assert_eq!(selected_target(cx, &harness), Some(first));
    assert_eq!(composer_text(cx, &harness), "");
}
