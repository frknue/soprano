use std::fs;

use gpui::{Entity, TestAppContext, VisualTestContext};
use soprano_platform::StateStore;

use super::*;
use crate::test_support::{git, has_git, init, record, wait_until};

fn panel(cx: &mut TestAppContext) -> (Entity<FilesPanel>, &mut VisualTestContext) {
    init(cx);
    cx.add_window_view(|window, cx| FilesPanel::new(StateStore::in_memory(), window, cx))
}

fn shown(panel: &Entity<FilesPanel>, cx: &mut VisualTestContext) -> Vec<String> {
    panel.read_with(cx, |panel, _| panel.visible_paths())
}

#[gpui::test]
fn the_explorer_shows_the_active_panes_project_and_follows_the_disk(cx: &mut TestAppContext) {
    if !has_git() {
        return;
    }
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path();
    fs::create_dir_all(root.join("Sources")).expect("mkdir");
    git(&["init", "-q"], root);
    fs::write(root.join("Sources/app.swift"), "").expect("write");
    fs::write(root.join("README.md"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = root.join("Sources").to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    let expected_root = soprano_git::branch::repository_root(&cwd).expect("repository");
    assert_eq!(panel.read_with(cx, |panel, _| panel.root().map(Path::to_path_buf)), Some(expected_root));

    wait_until(cx, |cx| {
        panel.read_with(cx, |panel, _| {
            panel.visible_paths().len() == 2 && *panel.git_status() != GitStatusSnapshot::empty()
        })
    });
    assert_eq!(shown(&panel, cx), ["Sources", "README.md"]);
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.git_status().status("Sources", true)),
        Some(soprano_git::GitFileStatus::Untracked)
    );

    panel.update(cx, |panel, cx| panel.toggle_folder("Sources", cx));
    wait_until(cx, |cx| shown(&panel, cx).len() == 3);
    assert_eq!(shown(&panel, cx)[1], "Sources/app.swift");

    // Files created by other programs (an agent, git) appear on their own.
    fs::write(root.join("Sources/generated.swift"), "").expect("write");
    wait_until(cx, |cx| shown(&panel, cx).len() == 4);
    assert_eq!(shown(&panel, cx)[2], "Sources/generated.swift");
}

#[gpui::test]
fn an_open_folder_stays_open_through_rename_undo_and_redo(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::create_dir_all(root.join("Sources")).expect("mkdir");
    fs::write(root.join("Sources/app.swift"), "").expect("write");

    let (panel, cx) = panel(cx);
    let events = record(&panel, cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["Sources"]);
    panel.update(cx, |panel, cx| panel.toggle_folder("Sources", cx));
    wait_until(cx, |cx| shown(&panel, cx) == ["Sources", "Sources/app.swift"]);

    let shown_root = panel.read_with(cx, |panel, _| panel.root().map(Path::to_path_buf)).expect("root");
    panel.update(cx, |panel, cx| panel.rename(&shown_root.join("Sources"), "Lib", cx)).expect("renamed");
    wait_until(cx, |cx| shown(&panel, cx) == ["Lib", "Lib/app.swift"]);
    assert!(events.borrow().iter().any(|event| matches!(event,
        SidebarEvent::ItemMoved { from, to } if from.ends_with("Sources") && to.ends_with("Lib"))));

    panel.update(cx, |panel, cx| panel.undo(cx));
    wait_until(cx, |cx| shown(&panel, cx) == ["Sources", "Sources/app.swift"]);

    panel.update(cx, |panel, cx| panel.redo(cx));
    wait_until(cx, |cx| shown(&panel, cx) == ["Lib", "Lib/app.swift"]);
}

#[gpui::test]
fn the_filter_shows_every_match_in_an_expanded_tree_ignoring_case(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::create_dir_all(root.join("src/views")).expect("mkdir");
    fs::write(root.join("src/views/FileTree.rs"), "").expect("write");
    fs::write(root.join("src/main.rs"), "").expect("write");
    fs::write(root.join("README.md"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["src", "README.md"]);

    panel.update(cx, |panel, cx| panel.set_filter_query("VIEWS tree", cx));
    wait_until(cx, |cx| !shown(&panel, cx).is_empty() && shown(&panel, cx) != ["src", "README.md"]);
    assert_eq!(shown(&panel, cx), ["src", "src/views", "src/views/FileTree.rs"]);

    panel.update(cx, |panel, cx| panel.set_filter_query("nothing-matches", cx));
    wait_until(cx, |cx| shown(&panel, cx).is_empty());
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.status()),
        Some(Status::Message("No files match this filter".to_owned()))
    );

    // Clearing the filter brings the real tree back as it was.
    panel.update(cx, |panel, cx| panel.set_filter_query("", cx));
    assert_eq!(shown(&panel, cx), ["src", "README.md"]);
}

#[gpui::test]
fn keyboard_navigation_opens_folders_selects_children_and_returns_to_parents(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::create_dir_all(root.join("a")).expect("mkdir");
    fs::write(root.join("a/one.txt"), "").expect("write");
    fs::write(root.join("b.txt"), "").expect("write");

    let (panel, cx) = panel(cx);
    let events = record(&panel, cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["a", "b.txt"]);
    panel.update_in(cx, |panel, window, cx| panel.focus_tree(window, cx));
    assert_eq!(panel.read_with(cx, |panel, _| panel.selected_paths()), ["a"]);

    cx.simulate_keystrokes("right");
    wait_until(cx, |cx| shown(&panel, cx) == ["a", "a/one.txt", "b.txt"]);
    cx.simulate_keystrokes("right");
    assert_eq!(panel.read_with(cx, |panel, _| panel.selected_paths()), ["a/one.txt"]);
    cx.simulate_keystrokes("left");
    assert_eq!(panel.read_with(cx, |panel, _| panel.selected_paths()), ["a"]);
    cx.simulate_keystrokes("left");
    assert_eq!(shown(&panel, cx), ["a", "b.txt"]);

    cx.simulate_keystrokes("end");
    assert_eq!(panel.read_with(cx, |panel, _| panel.selected_paths()), ["b.txt"]);
    cx.simulate_keystrokes("space");
    assert!(events.borrow().iter().any(|event| matches!(event,
        SidebarEvent::OpenFile { path, preview: true, .. } if path.ends_with("b.txt"))));

    cx.simulate_keystrokes("shift-home");
    assert_eq!(panel.read_with(cx, |panel, _| panel.selected_paths()), ["a", "b.txt"]);

    cx.simulate_keystrokes("escape");
    assert_eq!(events.borrow().last(), Some(&SidebarEvent::FocusPane));
}

#[gpui::test]
fn a_new_file_typed_inline_is_created_selected_and_opened_in_the_editor(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::create_dir_all(root.join("docs")).expect("mkdir");

    let (panel, cx) = panel(cx);
    let events = record(&panel, cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["docs"]);

    panel.update_in(cx, |panel, window, cx| {
        panel.begin_create(EntryKind::File, "docs".to_owned(), window, cx)
    });
    wait_until(cx, |cx| panel.read_with(cx, |panel, _| panel.editing.is_some()));
    assert!(
        panel.read_with(cx, |panel, _| panel.rows.iter().any(|row| row.placeholder == Some(EntryKind::File)))
    );

    let input = panel
        .read_with(cx, |panel, _| panel.editing.as_ref().map(|editing| editing.input.clone()))
        .expect("input");
    input.update_in(cx, |input, window, cx| input.set_value("notes.md", window, cx));
    panel.update(cx, |panel, cx| panel.finish_editing(true, cx));
    wait_until(cx, |cx| shown(&panel, cx) == ["docs", "docs/notes.md"]);

    assert!(root.join("docs/notes.md").is_file());
    assert_eq!(panel.read_with(cx, |panel, _| panel.selected_paths()), ["docs/notes.md"]);
    assert!(events.borrow().iter().any(|event| matches!(event,
        SidebarEvent::OpenFile { path, preview: false, focus: false } if path.ends_with("docs/notes.md"))));
}

#[gpui::test]
fn escape_cancels_an_inline_rename_and_return_commits_it(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::write(root.join("draft.txt"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["draft.txt"]);

    panel.update_in(cx, |panel, window, cx| panel.begin_rename("draft.txt", window, cx));
    // The stem before the extension is preselected.
    let input = panel
        .read_with(cx, |panel, _| panel.editing.as_ref().map(|editing| editing.input.clone()))
        .expect("input");
    assert_eq!(input.read_with(cx, |input, _| input.selected_range()), 0..5);
    panel.update(cx, |panel, cx| panel.finish_editing(false, cx));
    assert!(root.join("draft.txt").is_file());

    panel.update_in(cx, |panel, window, cx| panel.begin_rename("draft.txt", window, cx));
    let input = panel
        .read_with(cx, |panel, _| panel.editing.as_ref().map(|editing| editing.input.clone()))
        .expect("input");
    input.update_in(cx, |input, window, cx| input.set_value("final.txt", window, cx));
    panel.update(cx, |panel, cx| panel.finish_editing(true, cx));
    wait_until(cx, |cx| shown(&panel, cx) == ["final.txt"]);
    assert_eq!(panel.read_with(cx, |panel, _| panel.selected_paths()), ["final.txt"]);
}

#[gpui::test]
fn files_dropped_from_outside_are_copied_and_internal_drops_move(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let outside = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::create_dir_all(root.join("dest")).expect("mkdir");
    fs::write(root.join("inside.txt"), "").expect("write");
    fs::write(outside.path().join("photo.png"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["dest", "inside.txt"]);
    let shown_root = panel.read_with(cx, |panel, _| panel.root().map(Path::to_path_buf)).expect("root");

    panel.update(cx, |panel, cx| {
        panel.drop_paths("dest".to_owned(), vec![outside.path().join("photo.png")], false, false, cx)
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["dest", "dest/photo.png", "inside.txt"]);
    assert!(outside.path().join("photo.png").is_file());

    panel.update(cx, |panel, cx| {
        panel.drop_paths("dest".to_owned(), vec![shown_root.join("inside.txt")], true, false, cx)
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["dest", "dest/inside.txt", "dest/photo.png"]);
    assert!(!root.join("inside.txt").exists());
}

#[gpui::test]
fn nothing_is_read_while_the_panel_is_inactive(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    fs::write(directory.path().join("a.txt"), "").expect("write");
    let (panel, cx) = panel(cx);
    let cwd = directory.path().to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| panel.set_working_directory(Some(&cwd), cx));
    cx.run_until_parked();
    assert_eq!(panel.read_with(cx, |panel, _| panel.root().map(Path::to_path_buf)), None);
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.status()),
        Some(Status::Message("Focus a terminal pane to browse its files".to_owned()))
    );

    panel.update(cx, |panel, cx| panel.set_active(true, cx));
    wait_until(cx, |cx| shown(&panel, cx) == ["a.txt"]);
}
