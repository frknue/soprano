//! `AutomationsPageTests`, headless: the editor's save failure, a run's report as Markdown, Esc
//! stepping back, the page's keyboard, and writing settings.json from the page.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use chrono::{DateTime, Utc};
use gpui::{AppContext as _, Entity, Focusable as _, TestAppContext, VisualTestContext};
use soprano_automations::{
    AutomationController, AutomationEnvironment, AutomationHost, AutomationRun, AutomationStore, FixedClock,
    RunStatus, RunTrigger,
};
use soprano_config::{AppSettings, ConfigStore, DefaultKeybindings};
use soprano_model::Workspace;
use soprano_types::TerminalTarget;

use crate::editor::{AutomationEditor, EditorClosed, EditorSetup};
use crate::page::{AutomationsPage, AutomationsPageEvent, Page};

const ONE_AUTOMATION: &str = r#"{ "audit": { "name": "Weekday repo audit", "agent": "omp", "folder": "$FOLDER",
  "prompt": "Review the repository health and summarize what needs attention.",
  "schedule": "0 9 * * 1-5", "precheck": "gh pr list --json number -q '.[0].number'" } }"#;

const TWO_AUTOMATIONS: &str = r#"{
  "audit": { "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "Audit.", "schedule": "0 9 * * *" },
  "review": { "name": "Review", "agent": "omp", "folder": "$FOLDER", "prompt": "Review.", "schedule": "0 10 * * *" } }"#;

#[derive(Default)]
struct Host {
    workspace: Workspace,
}

impl AutomationHost for Host {
    fn workspace(&self) -> &Workspace {
        &self.workspace
    }
    fn workspace_mut(&mut self) -> &mut Workspace {
        &mut self.workspace
    }
    fn start_terminal(&mut self, _: &TerminalTarget) -> bool {
        true
    }
    fn send_prompt_to(&mut self, _: &TerminalTarget, _: &str) -> bool {
        false
    }
    fn visible_text(&self, _: &TerminalTarget) -> Option<String> {
        None
    }
    fn display_is_awake(&self) -> bool {
        true
    }
    fn notify(&mut self, _: &str, _: &str, _: &str) {}
}

fn now() -> DateTime<Utc> {
    DateTime::from_timestamp(1_793_260_800, 0).expect("date")
}

struct Harness {
    page: Entity<AutomationsPage>,
    controller: Entity<AutomationController>,
    config: ConfigStore,
    events: Rc<RefCell<Vec<AutomationsPageEvent>>>,
    directory: tempfile::TempDir,
}

fn make_controller(automations: &str) -> (AutomationController, ConfigStore, tempfile::TempDir) {
    let directory = tempfile::tempdir().expect("temp dir");
    let settings = directory.path().join("settings.json");
    let entries = automations.replace("$FOLDER", &directory.path().to_string_lossy());
    soprano_config::config_file::write(&format!(r#"{{ "automations": {entries} }}"#), &settings)
        .expect("settings");
    let config = ConfigStore::new(&settings);
    config.start(false, &AppSettings::default_settings(), &DefaultKeybindings::config());
    let environment = AutomationEnvironment {
        clock: Arc::new(FixedClock::new(now(), chrono_tz::Europe::Berlin)),
        worktree_directory: directory.path().join("worktrees"),
        claude_config: None,
        home: directory.path().to_path_buf(),
        shell: "/bin/sh".into(),
        wake: Arc::new(|| {}),
    };
    let controller = AutomationController::new(
        AutomationStore::new(None),
        config.clone(),
        environment,
        &mut Host::default(),
    );
    (controller, config, directory)
}

fn open<'a>(cx: &'a mut TestAppContext, automations: &str) -> (Harness, &'a mut VisualTestContext) {
    cx.update(soprano_ui::init_for_tests);
    let (controller, config, directory) = make_controller(automations);
    let controller = cx.update(|cx| cx.new(|_| controller));
    let workspace = cx.update(|cx| cx.new(|_| Workspace::new()));
    let (page, cx) = cx.add_window_view({
        let controller = controller.clone();
        move |window, cx| AutomationsPage::new(controller, workspace, window, cx)
    });
    let events = Rc::new(RefCell::new(Vec::new()));
    cx.update({
        let events = events.clone();
        let page = page.clone();
        move |_, cx| {
            cx.subscribe(&page, move |_, event: &AutomationsPageEvent, _| {
                events.borrow_mut().push(event.clone())
            })
            .detach();
        }
    });
    cx.run_until_parked();
    (Harness { page, controller, config, events, directory }, cx)
}

fn insert_run(harness: &Harness, cx: &mut VisualTestContext, output: Option<&str>) -> String {
    let mut run = AutomationRun::new(
        "run-1",
        "audit",
        3,
        RunTrigger::Manual,
        now() - chrono::Duration::seconds(60),
        RunStatus::Completed,
        "omp",
        harness.directory.path().to_string_lossy(),
    );
    run.finished_at = Some(now());
    run.output = output.map(str::to_owned);
    cx.update(|_, cx| {
        harness.controller.update(cx, |controller, cx| {
            controller.store_mut().insert(run);
            cx.notify();
        })
    });
    cx.run_until_parked();
    "run-1".into()
}

fn page_state(harness: &Harness, cx: &mut VisualTestContext) -> Page {
    cx.update(|_, cx| harness.page.read(cx).page().clone())
}

#[gpui::test]
fn the_editor_stays_open_and_says_why_when_the_automation_cannot_be_saved(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    let (automation, setup) = cx.update(|_, cx| {
        let controller = harness.controller.read(cx);
        let automation = controller.automations().first().cloned().expect("automation");
        let setup = EditorSetup {
            automation: Some(automation.clone()),
            template: None,
            automations: controller.automations().to_vec(),
            taken_ids: controller.taken_ids(),
            project_directories: Vec::new(),
            settings_path: harness.config.display_path(),
            clock: controller.clock().clone(),
        };
        (automation, setup)
    });
    let editor = cx.update(|window, cx| cx.new(|cx| AutomationEditor::new(setup, window, cx)));
    let saved = Rc::new(RefCell::new(Vec::new()));
    let closed = Rc::new(RefCell::new(0));
    cx.update(|_, cx| {
        let closed = closed.clone();
        cx.subscribe(&editor, move |_, _: &EditorClosed, _| *closed.borrow_mut() += 1).detach();
    });
    cx.update(|_, cx| {
        let saved = saved.clone();
        editor.update(cx, |editor, _| {
            editor.set_on_save(move |automation, _, _| {
                saved.borrow_mut().push(automation.clone());
                false
            })
        });
    });
    assert!(cx.update(|_, cx| editor.read(cx).can_save(cx)));

    cx.update(|window, cx| editor.update(cx, |editor, cx| editor.submit(window, cx)));
    cx.run_until_parked();
    assert_eq!(
        saved.borrow().iter().map(|a| a.id.clone()).collect::<Vec<_>>(),
        std::slice::from_ref(&automation.id)
    );
    assert_eq!(saved.borrow()[0].prompt, automation.prompt);
    assert_eq!(*closed.borrow(), 0);
    assert!(cx.update(|_, cx| editor.read(cx).shown_error().is_some_and(|e| e.contains("couldn't save"))));

    cx.update(|_, cx| editor.update(cx, |editor, _| editor.set_on_save(|_, _, _| true)));
    cx.update(|window, cx| editor.update(cx, |editor, cx| editor.submit(window, cx)));
    cx.run_until_parked();
    assert_eq!(*closed.borrow(), 1);
}

#[gpui::test]
fn saving_from_the_editor_writes_settings_json_and_selects_the_new_automation(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    cx.update(|window, cx| harness.page.update(cx, |page, cx| page.new_automation(window, cx)));
    let editor = cx.update(|_, cx| harness.page.read(cx).editor().cloned()).expect("editor open");
    let folder = harness.directory.path().to_string_lossy().into_owned();
    cx.update(|window, cx| {
        editor.update(cx, |editor, cx| {
            let values = editor.values(cx);
            assert_eq!(values.cadence, crate::form::Cadence::Weekdays);
            // The automation's folder is first in the folder list; the fields fill like typing.
            editor.set_test_values("Nightly", "Check the nightly build.", &folder, window, cx);
            assert!(editor.can_save(cx));
            editor.submit(window, cx);
        })
    });
    cx.run_until_parked();
    assert!(cx.update(|_, cx| harness.page.read(cx).editor().is_none()));
    let text = std::fs::read_to_string(harness.config.file_path()).expect("settings");
    assert!(text.contains("\"nightly\""), "{text}");
    assert!(text.contains("Check the nightly build."));
    assert_eq!(
        cx.update(|_, cx| harness.page.read(cx).selected_automation().map(str::to_owned)),
        Some("nightly".into())
    );
}

#[gpui::test]
fn a_runs_report_is_rendered_by_the_chats_markdown_renderer(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    let run_id = insert_run(&harness, cx, Some("Dependencies are **mostly current**."));

    cx.update(|window, cx| harness.page.update(cx, |page, cx| page.show_run(&run_id, window, cx)));
    cx.run_until_parked();

    assert_eq!(page_state(&harness, cx), Page::Run(run_id.clone()));
    let output = cx.update(|_, cx| harness.controller.read(cx).run(&run_id).and_then(|r| r.output.clone()));
    let blocks = soprano_text::markdown::parse(&output.expect("report"), false);
    assert_eq!(soprano_editor::rich::markdown::document_text(&blocks), "Dependencies are mostly current.");
}

#[gpui::test]
fn esc_steps_back_from_a_runs_report_to_its_automation_then_the_list_then_closes_the_page(
    cx: &mut TestAppContext,
) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    let run_id = insert_run(&harness, cx, None);
    cx.update(|window, cx| harness.page.update(cx, |page, cx| page.show_run(&run_id, window, cx)));
    cx.run_until_parked();

    cx.simulate_keystrokes("escape");
    assert_eq!(page_state(&harness, cx), Page::Automation("audit".into()));
    assert_eq!(cx.update(|_, cx| harness.page.read(cx).selected_run().map(str::to_owned)), Some(run_id));

    cx.simulate_keystrokes("escape");
    assert_eq!(page_state(&harness, cx), Page::List);
    assert_eq!(
        cx.update(|_, cx| harness.page.read(cx).selected_automation().map(str::to_owned)),
        Some("audit".into())
    );
    assert!(harness.events.borrow().is_empty());

    cx.simulate_keystrokes("escape");
    assert_eq!(*harness.events.borrow(), [AutomationsPageEvent::Dismiss]);
}

#[gpui::test]
fn j_k_and_return_drive_the_list_and_an_automations_runs(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, TWO_AUTOMATIONS);
    let selected = |cx: &mut VisualTestContext| {
        cx.update(|_, cx| harness.page.read(cx).selected_automation().map(str::to_owned))
    };
    assert_eq!(selected(cx), Some("audit".into()));
    cx.simulate_keystrokes("j");
    assert_eq!(selected(cx), Some("review".into()));
    cx.simulate_keystrokes("down");
    assert_eq!(selected(cx), Some("review".into()));
    cx.simulate_keystrokes("k enter");
    assert_eq!(page_state(&harness, cx), Page::Automation("audit".into()));

    let run_id = insert_run(&harness, cx, None);
    cx.simulate_keystrokes("enter");
    assert_eq!(page_state(&harness, cx), Page::Run(run_id));
}

#[gpui::test]
fn the_new_automation_shortcut_opens_the_editor_and_esc_cancels_it(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, "{}");
    let shortcut = if cfg!(target_os = "macos") { "cmd-n" } else { "ctrl-shift-n" };
    cx.simulate_keystrokes(shortcut);
    let editor = cx.update(|_, cx| harness.page.read(cx).editor().cloned()).expect("editor open");
    assert!(cx.update(|_, cx| editor.read(cx).is_new()));

    cx.update(|window, cx| editor.update(cx, |editor, cx| editor.focus_handle(cx).focus(window, cx)));
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();
    assert!(cx.update(|_, cx| harness.page.read(cx).editor().is_none()));
    assert!(harness.events.borrow().is_empty());
}

#[gpui::test]
fn pausing_from_the_page_writes_settings_json_and_run_now_asks_the_shell(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    cx.update(|window, cx| {
        harness.page.update(cx, |page, cx| {
            page.perform(crate::page::AutomationAction::ToggleEnabled, "audit", window, cx);
            page.perform(crate::page::AutomationAction::RunNow, "audit", window, cx);
        })
    });
    cx.run_until_parked();
    let enabled = cx.update(|_, cx| harness.controller.read(cx).automation("audit").map(|a| a.enabled));
    assert_eq!(enabled, Some(false));
    assert_eq!(*harness.events.borrow(), [AutomationsPageEvent::RunNow { automation_id: "audit".into() }]);
}

#[gpui::test]
fn deleting_asks_first_and_then_asks_the_shell(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    cx.update(|window, cx| {
        harness
            .page
            .update(cx, |page, cx| page.perform(crate::page::AutomationAction::Delete, "audit", window, cx))
    });
    let dialog = cx.update(|_, cx| harness.page.read(cx).dialog().cloned()).expect("confirmation");
    assert_eq!(cx.update(|_, cx| dialog.read(cx).content().title.to_string()), "Delete Weekday repo audit?");
    cx.update(|window, cx| dialog.update(cx, |dialog, cx| dialog.finish(Some(1), window, cx)));
    cx.run_until_parked();
    assert_eq!(*harness.events.borrow(), [AutomationsPageEvent::Delete { automation_id: "audit".into() }]);
    assert!(cx.update(|_, cx| harness.page.read(cx).dialog().is_none()));
}

fn command_return() -> &'static str {
    if cfg!(target_os = "macos") { "cmd-enter" } else { "ctrl-enter" }
}

fn open_editor_for_audit(
    harness: &Harness,
    cx: &mut VisualTestContext,
) -> (Entity<AutomationEditor>, Rc<RefCell<Vec<String>>>) {
    cx.update(|window, cx| {
        harness
            .page
            .update(cx, |page, cx| page.perform(crate::page::AutomationAction::Edit, "audit", window, cx))
    });
    let editor = cx.update(|_, cx| harness.page.read(cx).editor().cloned()).expect("editor open");
    let saved = Rc::new(RefCell::new(Vec::new()));
    cx.update(|_, cx| {
        let saved = saved.clone();
        editor.update(cx, |editor, _| {
            editor.set_on_save(move |automation, _, _| {
                saved.borrow_mut().push(automation.prompt.clone());
                true
            })
        })
    });
    (editor, saved)
}

#[gpui::test]
fn command_return_in_the_prompt_saves_instead_of_adding_a_line(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    let (editor, saved) = open_editor_for_audit(&harness, cx);
    cx.update(|window, cx| editor.update(cx, |editor, cx| editor.focus_prompt(window, cx)));
    cx.run_until_parked();

    cx.simulate_keystrokes(command_return());
    cx.run_until_parked();

    assert_eq!(*saved.borrow(), ["Review the repository health and summarize what needs attention."]);
    assert!(cx.update(|_, cx| harness.page.read(cx).editor().is_none()));
}

#[gpui::test]
fn tab_in_the_prompt_moves_on_instead_of_typing_a_tab(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    let (editor, _) = open_editor_for_audit(&harness, cx);
    cx.update(|window, cx| editor.update(cx, |editor, cx| editor.focus_prompt(window, cx)));
    cx.run_until_parked();

    cx.simulate_keystrokes("tab");
    cx.run_until_parked();

    let (prompt, focused) = cx.update(|window, cx| {
        (editor.read(cx).values(cx).prompt, editor.read(cx).prompt_is_focused(window, cx))
    });
    assert_eq!(prompt, "Review the repository health and summarize what needs attention.");
    assert!(!focused);
}

#[gpui::test]
fn esc_in_a_field_of_the_editor_cancels_it(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    let (_, saved) = open_editor_for_audit(&harness, cx);
    cx.run_until_parked();
    // The editor opens with the keyboard in its name field.
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();
    assert!(cx.update(|_, cx| harness.page.read(cx).editor().is_none()));
    assert!(saved.borrow().is_empty());
    assert!(harness.events.borrow().is_empty());
}

#[gpui::test]
fn the_arrows_and_esc_drive_the_list_from_the_search_field(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, TWO_AUTOMATIONS);
    let selected = |cx: &mut VisualTestContext| {
        cx.update(|_, cx| harness.page.read(cx).selected_automation().map(str::to_owned))
    };
    cx.update(|window, cx| harness.page.update(cx, |page, cx| page.focus_search(window, cx)));
    cx.run_until_parked();

    cx.simulate_keystrokes("down");
    assert_eq!(selected(cx), Some("review".into()));
    cx.simulate_keystrokes("up");
    assert_eq!(selected(cx), Some("audit".into()));

    cx.simulate_input("rev");
    cx.run_until_parked();
    assert_eq!(selected(cx), Some("review".into()));
    cx.simulate_keystrokes("enter");
    assert_eq!(page_state(&harness, cx), Page::Automation("review".into()));

    cx.simulate_keystrokes("escape");
    assert_eq!(page_state(&harness, cx), Page::List);
    cx.update(|window, cx| harness.page.update(cx, |page, cx| page.focus_search(window, cx)));
    // Esc empties the search first, then closes the page.
    cx.simulate_keystrokes("escape");
    assert!(harness.events.borrow().is_empty());
    assert_eq!(selected(cx), Some("review".into()));
    cx.simulate_keystrokes("escape");
    assert_eq!(*harness.events.borrow(), [AutomationsPageEvent::Dismiss]);
}

#[gpui::test]
fn moving_through_a_long_run_history_scrolls_the_selected_run_into_view(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, ONE_AUTOMATION);
    cx.update(|_, cx| {
        harness.controller.update(cx, |controller, cx| {
            for number in 1..=60 {
                let mut run = AutomationRun::new(
                    format!("run-{number}"),
                    "audit",
                    number,
                    RunTrigger::Scheduled,
                    now(),
                    RunStatus::Completed,
                    "omp",
                    "/tmp",
                );
                run.finished_at = Some(now());
                controller.store_mut().insert(run);
            }
            cx.notify();
        })
    });
    cx.update(|window, cx| harness.page.update(cx, |page, cx| page.show_automation("audit", window, cx)));
    cx.run_until_parked();
    let offset = |cx: &mut VisualTestContext| cx.update(|_, cx| harness.page.read(cx).scroll_offset().y);
    assert_eq!(offset(cx), gpui::px(0.));

    for _ in 0..59 {
        cx.simulate_keystrokes("j");
    }
    cx.run_until_parked();
    assert_eq!(
        cx.update(|_, cx| harness.page.read(cx).selected_run().map(str::to_owned)),
        Some("run-1".into())
    );
    let scrolled = offset(cx);
    assert!(scrolled < gpui::px(0.), "{scrolled:?}");

    for _ in 0..59 {
        cx.simulate_keystrokes("k");
    }
    cx.run_until_parked();
    assert!(offset(cx) > scrolled);
}
