use std::fs;

use gpui::{Entity, TestAppContext, VisualTestContext};
use soprano_platform::StateStore;

use super::*;
use crate::test_support::{git, has_git, init, record, wait_until};

fn panel(cx: &mut TestAppContext) -> (Entity<FilesPanel>, &mut VisualTestContext) {
    init(cx);
    let (panel, cx) = cx.add_window_view(|window, cx| FilesPanel::new(StateStore::in_memory(), window, cx));
    // A real window is active while the user works in it.
    cx.update(|window, _| window.activate_window());
    cx.run_until_parked();
    (panel, cx)
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

#[gpui::test]
fn switching_to_another_app_mid_rename_keeps_editing(cx: &mut TestAppContext) {
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
    let input = panel
        .read_with(cx, |panel, _| panel.editing.as_ref().map(|editing| editing.input.clone()))
        .expect("input");
    input.update_in(cx, |input, window, cx| input.set_value("dra", window, cx));

    cx.deactivate_window();
    cx.run_until_parked();
    assert!(panel.read_with(cx, |panel, _| panel.editing.is_some()), "the half-typed name is not committed");
    assert!(root.join("draft.txt").is_file());
}

#[gpui::test]
fn committing_after_a_click_elsewhere_leaves_the_keyboard_where_it_went(cx: &mut TestAppContext) {
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
    cx.update(|window, _| assert!(window.is_window_active()));
    cx.run_until_parked();
    cx.update(|window, _| window.refresh());
    cx.run_until_parked();

    // The keyboard moves to the filter field: the edit commits and focus stays there.
    let filter = panel.read_with(cx, |panel, _| panel.filter_input.clone());
    filter.update_in(cx, |input, window, cx| input.focus(window, cx));
    cx.run_until_parked();
    cx.update(|window, _| window.refresh());
    cx.run_until_parked();
    assert!(panel.read_with(cx, |panel, _| panel.editing.is_none()));
    let filter_focused = cx.update(|window, cx| filter.read(cx).focus_handle(cx).is_focused(window));
    assert!(filter_focused);

    // Esc in the field hands the keyboard back to the tree.
    panel.update_in(cx, |panel, window, cx| panel.begin_rename("draft.txt", window, cx));
    cx.run_until_parked();
    panel.update(cx, |panel, cx| panel.finish_editing(false, cx));
    cx.run_until_parked();
    let tree_focused = cx.update(|window, cx| panel.read(cx).focus_handle.is_focused(window));
    assert!(tree_focused);
}

#[gpui::test]
fn folders_collapsed_in_filter_results_stay_collapsed_after_an_inline_edit(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::create_dir_all(root.join("a")).expect("mkdir");
    fs::create_dir_all(root.join("b")).expect("mkdir");
    fs::write(root.join("a/note.txt"), "").expect("write");
    fs::write(root.join("b/note.txt"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["a", "b"]);
    panel.update(cx, |panel, cx| panel.set_filter_query("note", cx));
    wait_until(cx, |cx| shown(&panel, cx) == ["a", "a/note.txt", "b", "b/note.txt"]);
    panel.update(cx, |panel, cx| panel.toggle_folder("a", cx));
    assert_eq!(shown(&panel, cx), ["a", "b", "b/note.txt"]);

    panel.update_in(cx, |panel, window, cx| panel.begin_rename("b/note.txt", window, cx));
    panel.update(cx, |panel, cx| panel.finish_editing(false, cx));
    assert_eq!(shown(&panel, cx), ["a", "b", "b/note.txt"]);
}

#[gpui::test]
fn refused_drops_are_not_offered_and_leaving_a_folder_cancels_its_spring_loading(cx: &mut TestAppContext) {
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::create_dir_all(root.join("a/inner")).expect("mkdir");
    fs::write(root.join("file.txt"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["a", "file.txt"]);
    let shown_root = panel.read_with(cx, |panel, _| panel.root().map(Path::to_path_buf)).expect("root");

    panel.read_with(cx, |panel, _| {
        // A folder into itself, or a file onto its own folder: nothing to do.
        assert!(!panel.accepts_drop("a/inner", &[shown_root.join("a")], true, false));
        assert!(!panel.accepts_drop("", &[shown_root.join("file.txt")], true, false));
        assert!(panel.accepts_drop("a", &[shown_root.join("file.txt")], true, false));
        // ⌥ copies next to the original.
        assert!(panel.accepts_drop("", &[shown_root.join("file.txt")], true, true));
    });

    panel.update(cx, |panel, cx| panel.drag_hovered("a".to_owned(), cx));
    panel.update(cx, |panel, _| panel.drag_left("a"));
    cx.executor().advance_clock(Duration::from_secs(1));
    cx.run_until_parked();
    assert_eq!(shown(&panel, cx), ["a", "file.txt"], "the folder the pointer left stays closed");

    panel.update(cx, |panel, cx| panel.drag_hovered("a".to_owned(), cx));
    cx.executor().advance_clock(Duration::from_secs(1));
    wait_until(cx, |cx| shown(&panel, cx) == ["a", "a/inner", "file.txt"]);
}

#[gpui::test]
fn git_init_in_the_shown_folder_turns_it_into_a_repository_and_removing_git_undoes_it(
    cx: &mut TestAppContext,
) {
    if !has_git() {
        return;
    }
    let directory = tempfile::tempdir().expect("temp dir");
    let root = directory.path().to_path_buf();
    fs::write(root.join("a.txt"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["a.txt"]);
    assert!(!panel.read_with(cx, |panel, _| panel.is_git_repository()));

    git(&["init", "-q"], &root);
    wait_until(cx, |cx| panel.read_with(cx, |panel, _| panel.is_git_repository()));
    // The new repository's files are decorated.
    wait_until(cx, |cx| {
        panel.read_with(cx, |panel, _| panel.git_status().status("a.txt", false))
            == Some(soprano_git::GitFileStatus::Untracked)
    });

    fs::remove_dir_all(root.join(".git")).expect("remove .git");
    wait_until(cx, |cx| !panel.read_with(cx, |panel, _| panel.is_git_repository()));
}

#[gpui::test]
fn coming_back_to_the_app_finds_a_repository_created_above_the_shown_folder(cx: &mut TestAppContext) {
    if !has_git() {
        return;
    }
    let directory = tempfile::tempdir().expect("temp dir");
    let parent = directory.path().to_path_buf();
    fs::create_dir_all(parent.join("sub")).expect("mkdir");
    fs::write(parent.join("sub/a.txt"), "").expect("write");

    let (panel, cx) = panel(cx);
    let cwd = parent.join("sub").to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| shown(&panel, cx) == ["a.txt"]);

    // Outside the watched folder: noticed when the window becomes active again.
    git(&["init", "-q"], &parent);
    cx.deactivate_window();
    cx.update(|window, _| window.activate_window());
    wait_until(cx, |cx| shown(&panel, cx) == ["sub"]);
    assert!(panel.read_with(cx, |panel, _| panel.is_git_repository()));
}
