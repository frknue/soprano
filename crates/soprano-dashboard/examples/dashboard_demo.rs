//! The Agent Dashboard over a demo workspace with three agents and canned terminal text:
//! `cargo run -p soprano-dashboard --example dashboard_demo`.

use gpui::{App, AppContext as _, Bounds, Focusable as _, WindowBounds, WindowOptions, px, size};
use gpui_component::Root;
use soprano_dashboard::{AgentDashboard, DashboardEvent, DashboardHost};
use soprano_model::Workspace;
use soprano_types::{AgentStatus, AgentWaitingReason};
use soprano_ui::{AppearancePreference, SopranoAssets};

const TERMINAL: &str = "❯ Run swift test --filter AgentDashboard\n\
• Updated Sources/Soprano/Views/AgentDashboardViewController.swift:842\n\
warning: waiting for input\n\
error: build failed\n\
```swift\n@MainActor let count: Int = 42\nprint(\"ready\")\n```\n\
All 301 tests passed";

fn demo_workspace() -> Workspace {
    let mut workspace = Workspace::new();
    let agents = [
        ("codex", "/tmp/projects/storefront", AgentStatus::Running, None, "⠙ Fix the checkout total"),
        (
            "claude-code",
            "/tmp/projects/payments",
            AgentStatus::Waiting,
            Some(AgentWaitingReason::Approval),
            "",
        ),
        ("opencode", "/tmp/projects/docs", AgentStatus::Idle, None, ""),
    ];
    for (profile, cwd, status, reason, title) in agents {
        let Some(pane) = workspace.spawn_agent(profile, Some(cwd), false) else { continue };
        let Some(tab) = workspace.pane(&pane).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone())
        else {
            continue;
        };
        workspace.update_agent_status(&pane, &tab, status, None, reason);
        if !title.is_empty() {
            workspace.rename_tab(&pane, &tab, title);
        }
    }
    workspace.take_changes();
    workspace.take_events();
    workspace
}

fn main() {
    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(|cx: &mut App| {
        soprano_ui::init(cx, "gruvbox-dark", AppearancePreference::System);
        let bounds = Bounds::centered(None, size(px(1280.), px(820.)), cx);
        cx.open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..WindowOptions::default() },
            |window, cx| {
                let workspace = cx.new(|_| demo_workspace());
                let host = DashboardHost::new()
                    .terminal_text(|_, _| Some(TERMINAL.to_owned()))
                    .notable_branch(|cwd, _| cwd.ends_with("payments").then(|| "feat/refunds".to_owned()));
                let dashboard = cx.new(|cx| AgentDashboard::new(workspace.clone(), host, window, cx));
                let model = workspace.clone();
                cx.subscribe(&dashboard, move |_, event: &DashboardEvent, cx| {
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
                    }
                })
                .detach();
                let focus = dashboard.focus_handle(cx);
                window.focus(&focus, cx);
                cx.new(|cx| Root::new(dashboard, window, cx))
            },
        )
        .expect("the demo window opens");
        cx.activate(true);
    });
}
