use std::fs;

use gpui::{Entity, TestAppContext, VisualTestContext};

use super::*;
use crate::test_support::{git, has_git, init, record, repository, wait_until};

fn panel(cx: &mut TestAppContext) -> (Entity<ChangesPanel>, &mut VisualTestContext) {
    init(cx);
    cx.add_window_view(ChangesPanel::new)
}

fn areas(panel: &Entity<ChangesPanel>, cx: &mut VisualTestContext) -> Vec<GitChangeArea> {
    panel.read_with(cx, |panel, _| panel.change_list().changes.iter().map(|change| change.area).collect())
}

#[gpui::test]
fn the_list_shows_the_active_panes_changes_and_follows_the_working_tree_and_index(cx: &mut TestAppContext) {
    if !has_git() {
        return;
    }
    let directory = repository();
    let root = directory.path();
    let (panel, cx) = panel(cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    let expected = repository_root(&cwd).expect("repository");
    assert_eq!(panel.read_with(cx, |panel, _| panel.root().map(Path::to_path_buf)), Some(expected));
    wait_until(cx, |cx| panel.read_with(cx, |panel, _| panel.change_list().branch.is_some()));
    assert!(areas(&panel, cx).is_empty());
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.status()),
        Some("No changes\nThe working tree is clean.")
    );

    // Edits by other programs show up on their own, and so does staging.
    fs::write(root.join("app.txt"), "one\nTWO\n").expect("write");
    wait_until(cx, |cx| areas(&panel, cx) == [GitChangeArea::Unstaged]);
    git(&["add", "app.txt"], root);
    wait_until(cx, |cx| areas(&panel, cx) == [GitChangeArea::Staged]);
    let change = panel.read_with(cx, |panel, _| panel.change_list().changes[0].clone());
    assert_eq!(change.lines_added, Some(1));
    assert_eq!(change.lines_deleted, Some(2));

    // Edited again after staging: in both sections.
    fs::write(root.join("app.txt"), "one\nTWO\nthree\n").expect("write");
    wait_until(cx, |cx| areas(&panel, cx) == [GitChangeArea::Unstaged, GitChangeArea::Staged]);
}

#[gpui::test]
fn clicks_and_keys_open_diffs_as_previews_or_kept_tabs_and_headers_collapse(cx: &mut TestAppContext) {
    if !has_git() {
        return;
    }
    let directory = repository();
    let root = directory.path();
    fs::write(root.join("app.txt"), "changed\n").expect("write");
    fs::write(root.join("new.txt"), "new\n").expect("write");
    let (panel, cx) = panel(cx);
    let events = record(&panel, cx);
    let cwd = root.to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    wait_until(cx, |cx| areas(&panel, cx) == [GitChangeArea::Unstaged, GitChangeArea::Untracked]);

    panel.update_in(cx, |panel, window, cx| panel.focus_list(window, cx));
    // The keyboard lands on the first change, under the "Changes" header.
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.selected.clone()),
        Some(Entry::Change(GitChangeArea::Unstaged, "app.txt".to_owned()))
    );
    cx.simulate_keystrokes("space");
    assert!(matches!(events.borrow().last(),
        Some(SidebarEvent::OpenDiff { path, staged: false, preview: true, focus: false }) if path.ends_with("app.txt")));
    cx.simulate_keystrokes("enter");
    assert!(matches!(
        events.borrow().last(),
        Some(SidebarEvent::OpenDiff { preview: false, focus: true, .. })
    ));

    cx.simulate_keystrokes("up");
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.selected.clone()),
        Some(Entry::Section(GitChangeArea::Unstaged))
    );
    cx.simulate_keystrokes("left");
    let rows = panel.read_with(cx, |panel, _| panel.rows.len());
    assert_eq!(rows, 3, "the collapsed section hides its file");
    cx.simulate_keystrokes("right");
    assert_eq!(panel.read_with(cx, |panel, _| panel.rows.len()), 4);

    cx.simulate_keystrokes("escape");
    assert_eq!(events.borrow().last(), Some(&SidebarEvent::FocusPane));
}

#[gpui::test]
fn a_folder_outside_git_says_source_control_needs_a_repository(cx: &mut TestAppContext) {
    if !has_git() {
        return;
    }
    let directory = tempfile::tempdir().expect("temp dir");
    let (panel, cx) = panel(cx);
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.status()),
        Some("Focus a terminal inside a Git repository to see its changes.")
    );
    let cwd = directory.path().to_string_lossy().into_owned();
    panel.update(cx, |panel, cx| {
        panel.set_working_directory(Some(&cwd), cx);
        panel.set_active(true, cx);
    });
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.status()),
        Some("Source Control is only available for Git repositories")
    );
}
