//! `EditorTabTests`, `MarkdownIntegrationTests` and `BrowserIntegrationTests` (model parts).

use std::path::{Path, PathBuf};

use super::*;
use crate::file_url;
use crate::pane::{PaneState, PaneTab, PaneType};
use crate::session::SavedTab;
use crate::split_node::SplitNode;
use crate::workspace::WorkspaceChange;
use soprano_types::SplitDirection;

/// An absolute path under the temporary directory (`/tmp/…` on Unix).
fn tmp(relative: &str) -> PathBuf {
    let base = if cfg!(unix) { PathBuf::from("/tmp") } else { std::env::temp_dir() };
    soprano_platform::paths::normalize(&base.join(relative))
}

fn url_of(relative: &str) -> String {
    file_url::file_url_string(&tmp(relative))
}

fn editor_tabs(workspace: &Workspace, pane_id: &str) -> Vec<PaneTab> {
    workspace
        .pane(pane_id)
        .map(|p| p.tabs.iter().filter(|t| t.is_editor()).cloned().collect())
        .unwrap_or_default()
}

fn titles(tabs: &[PaneTab]) -> Vec<&str> {
    tabs.iter().map(|t| t.title.as_str()).collect()
}

// MARK: - Opening

#[test]
fn files_open_in_a_split_beside_the_focused_pane_and_never_cover_it() {
    let mut workspace = Workspace::new();
    let terminal_pane = workspace.active_pane_id().to_owned();
    let terminal_tab = active_tab_id(&workspace, &terminal_pane);

    let first = workspace.open_editor(&tmp("a.swift"), true, None).expect("opened");

    assert_ne!(first.pane_id, terminal_pane);
    assert_eq!(workspace.pane(&terminal_pane).map(|p| p.tabs.len()), Some(1));
    assert_eq!(active_tab_id(&workspace, &terminal_pane), terminal_tab);
    assert_eq!(
        workspace.layout().map(SplitNode::ordered_leaf_ids),
        Some(vec![terminal_pane.clone(), first.pane_id.clone()])
    );
    assert_eq!(workspace.active_pane_id(), first.pane_id);

    // Back in the terminal, the next file joins the existing split.
    workspace.focus_pane(&terminal_pane);
    let second = workspace.open_editor(&tmp("b.swift"), false, None).expect("opened");
    assert_eq!(second.pane_id, first.pane_id);
    assert_eq!(workspace.pane(&terminal_pane).map(|p| p.tabs.len()), Some(1));
    assert_eq!(workspace.layout().map(SplitNode::leaf_count), Some(2));
}

#[test]
fn preview_tabs_are_reused_while_kept_tabs_stay() {
    let mut workspace = Workspace::new();
    let (a, b, c) = (tmp("project/a.swift"), tmp("project/b.swift"), tmp("project/c.swift"));

    let first = workspace.open_editor(&a, true, None).expect("opened");
    let pane = first.pane_id.clone();
    assert_eq!(titles(&editor_tabs(&workspace, &pane)), ["a.swift"]);
    assert!(editor_tabs(&workspace, &pane)[0].is_file_preview());

    let second = workspace.open_editor(&b, true, None).expect("opened");
    assert_eq!(second.pane_id, pane);
    assert_eq!(titles(&editor_tabs(&workspace, &pane)), ["b.swift"]);
    assert_ne!(second.tab_id, first.tab_id);

    let kept = workspace.open_editor(&b, false, None).expect("opened");
    assert_eq!(kept.tab_id, second.tab_id);
    assert!(!editor_tabs(&workspace, &pane)[0].is_file_preview());

    workspace.open_editor(&c, true, None).expect("opened");
    assert_eq!(titles(&editor_tabs(&workspace, &pane)), ["b.swift", "c.swift"]);

    let refocused = workspace.open_editor(&b, true, None).expect("opened");
    assert_eq!(refocused.tab_id, second.tab_id);
    assert_eq!(active_tab_id(&workspace, &pane), second.tab_id);
    assert_eq!(editor_tabs(&workspace, &pane).len(), 2);
}

#[test]
fn editing_keeps_a_preview_tab() {
    let mut workspace = Workspace::new();
    let target = workspace.open_editor(&tmp("x.txt"), true, None).expect("opened");
    workspace.take_changes();

    workspace.keep_editor_tab(&target.pane_id, &target.tab_id);
    assert_eq!(workspace.take_changes(), [WorkspaceChange::TabTitle(target.clone())]);
    workspace.open_editor(&tmp("y.txt"), true, None);

    assert_eq!(titles(&editor_tabs(&workspace, &target.pane_id)), ["x.txt", "y.txt"]);
}

#[test]
fn a_full_file_pane_gets_a_new_split_and_a_full_window_falls_back_to_a_tab() {
    let mut workspace = Workspace::new();
    let first = workspace.open_editor(&tmp("f0.txt"), false, None).expect("opened");
    for index in 1..PaneState::MAX_TABS_PER_PANE {
        workspace.open_editor(&tmp(&format!("f{index}.txt")), false, None);
    }
    assert_eq!(workspace.pane(&first.pane_id).map(|p| p.tabs.len()), Some(PaneState::MAX_TABS_PER_PANE));

    let overflow = workspace.open_editor(&tmp("z.txt"), true, None).expect("opened");
    assert_ne!(overflow.pane_id, first.pane_id);

    // No room for another pane: the file becomes a tab of the focused pane.
    let mut crowded = Workspace::new();
    while crowded.can_add_pane(crowded.active_window_id()) {
        crowded.spawn_terminal(None);
    }
    let focused = crowded.active_pane_id().to_owned();
    let target = crowded.open_editor(&tmp("z.txt"), true, None).expect("opened");
    assert_eq!(target.pane_id, focused);
    assert!(crowded.pane(&focused).and_then(|p| p.active_tab()).is_some_and(PaneTab::is_editor));
}

#[test]
fn diffs_open_like_files_and_a_preview_diff_and_a_preview_file_replace_each_other() {
    let mut workspace = Workspace::new();
    let file = tmp("project/a.swift");
    let editor = workspace.open_editor(&file, true, None).expect("opened");
    let diff = workspace.open_diff(&file, false, true, None).expect("opened");
    assert_eq!(diff.pane_id, editor.pane_id);
    let tabs = workspace.pane(&diff.pane_id).map(|p| p.tabs.clone()).expect("pane");
    assert_eq!(tabs.len(), 1);
    assert_eq!(tabs[0].title, "a.swift (diff)");
    assert!(tabs[0].is_diff() && tabs[0].is_file_preview());

    let staged = workspace.open_diff(&file, true, false, None).expect("opened");
    assert_ne!(staged.tab_id, diff.tab_id);
    assert_eq!(
        workspace.tab(&staged.pane_id, &staged.tab_id).map(|t| t.title.as_str()),
        Some("a.swift (staged diff)")
    );
}

#[test]
fn renaming_a_folder_repoints_the_editor_and_reader_tabs_inside_it() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let editor = workspace.open_editor(&tmp("project/src/app.swift"), false, Some(&pane)).expect("opened");
    let reader = workspace.preview_markdown(&tmp("project/src/README.md"), &pane).expect("opened");
    let other = workspace.open_editor(&tmp("project/srcs.swift"), false, Some(&pane)).expect("opened");
    workspace.take_changes();

    workspace.relocate_file_tabs(&tmp("project/src"), &tmp("project/lib"));

    let url = |tab: &str| workspace.tab(&pane, tab).and_then(|t| t.url.clone());
    assert_eq!(url(&editor.tab_id), Some(url_of("project/lib/app.swift")));
    assert_eq!(url(&reader), Some(url_of("project/lib/README.md")));
    assert_eq!(url(&other.tab_id), Some(url_of("project/srcs.swift")));
    let documents: HashSet<String> = workspace
        .take_changes()
        .into_iter()
        .filter_map(|change| match change {
            WorkspaceChange::Document(target) => Some(target.tab_id),
            _ => None,
        })
        .collect();
    assert_eq!(documents, HashSet::from([editor.tab_id, reader]));
}

/// A workspace whose only pane holds the editor tab an older Swift build saved for `url`.
#[cfg(unix)]
fn workspace_with_swift_editor_tab(url: &str) -> Workspace {
    let tab = SavedTab {
        url: Some(url.into()),
        title: Some("saved".into()),
        content_kind: Some(crate::PaneContentKind::EDITOR.into()),
        ..SavedTab::new("tab-2", PaneType::Browser)
    };
    let session = crate::WorkspaceSession::legacy(
        "swift",
        "Swift",
        None,
        vec![crate::SavedPane { id: "pane-1".into(), active_tab_index: 0, tabs: vec![tab] }],
        "pane-1",
    );
    let mut workspace = Workspace::new();
    workspace.restore_workspace(session);
    workspace
}

#[cfg(unix)]
#[test]
fn a_swift_saved_decomposed_and_escaped_url_is_the_same_file_as_a_composed_path() {
    let mut workspace =
        workspace_with_swift_editor_tab("file:///tmp/project/Pra%CC%88sentation%20%5B1%5D.md");

    let target = workspace
        .open_editor(Path::new("/tmp/project/Pr\u{e4}sentation [1].md"), false, Some("pane-1"))
        .expect("opened");

    assert_eq!(target, TerminalTarget::new("pane-1", "tab-2"));
    assert_eq!(workspace.pane("pane-1").map(|p| p.tabs.len()), Some(1));
}

#[test]
fn bracketed_paths_reuse_their_tab_and_preview() {
    let mut workspace = Workspace::new();
    let page = tmp("app/[id]/page.tsx");
    let first = workspace.open_editor(&page, true, None).expect("opened");
    let again = workspace.open_editor(&page, false, None).expect("opened");
    assert_eq!(again, first);
    assert!(!workspace.tab(&first.pane_id, &first.tab_id).is_some_and(PaneTab::is_file_preview));

    let layout = tmp("app/[id]/layout.tsx");
    let preview = workspace.open_editor(&layout, true, None).expect("opened");
    let replaced = workspace.open_editor(&tmp("app/[id]/loading.tsx"), true, None).expect("opened");
    assert_ne!(preview.tab_id, replaced.tab_id);
    assert_eq!(editor_tabs(&workspace, &first.pane_id).len(), 2);
    workspace.take_changes();
    workspace.update_file_document(&first.pane_id, &first.tab_id, &page);
    assert!(workspace.take_changes().is_empty());
}

#[cfg(unix)]
#[test]
fn renaming_a_folder_with_an_accent_relocates_tabs_swift_saved_decomposed() {
    let mut workspace = workspace_with_swift_editor_tab("file:///tmp/Pra%CC%88sentationen/%5Bid%5D.md");

    workspace.relocate_file_tabs(Path::new("/tmp/Pr\u{e4}sentationen"), Path::new("/tmp/Folien"));

    let tab = workspace.tab("pane-1", "tab-2").expect("tab");
    assert_eq!(tab.url.as_deref(), Some("file:///tmp/Folien/%5Bid%5D.md"));
    assert_eq!(tab.title, "[id].md");
    assert_eq!(tab.cwd.as_deref(), Some("/tmp/Folien"));
}

// MARK: - Close confirmation

#[test]
fn closing_asks_once_about_exactly_the_tabs_that_go() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let terminal_tab = active_tab_id(&workspace, &pane);
    let editor = workspace.open_editor(&tmp("a.txt"), false, Some(&pane)).expect("opened");
    always_ask(&mut workspace);

    let outcome = workspace.remove_tab_from_pane(&pane, &editor.tab_id);
    assert_eq!(asked_about(&outcome), HashSet::from([editor.clone()]));
    assert_eq!(workspace.pane(&pane).map(|p| p.tabs.len()), Some(2));

    let outcome = workspace.close_pane(&pane);
    assert_eq!(asked_about(&outcome), HashSet::from([editor, TerminalTarget::new(&pane, &terminal_tab)]));
    assert!(workspace.pane(&pane).is_some());

    // The window's last pane takes the window with it, without a second question.
    let window_id = workspace.active_window_id().to_owned();
    let CloseOutcome::NeedsConfirmation { request, .. } = outcome else { unreachable!() };
    assert_eq!(workspace.force_close(request), CloseOutcome::Closed);
    assert!(workspace.pane(&pane).is_none());
    assert!(workspace.window(&window_id).is_none());
}

#[test]
fn closing_a_tab_or_its_last_pane_asks_only_about_that_tabs_panes() {
    let mut workspace = Workspace::new();
    let outer = workspace.active_pane_id().to_owned();
    let outer_tab = active_tab_id(&workspace, &outer);
    let layout_tab = workspace.create_layout_tab(None, None).expect("tab");
    let inner = workspace.active_pane_id().to_owned();
    assert_ne!(inner, outer);
    let inner_tabs = targets(&workspace, &[&inner]);
    always_ask(&mut workspace);

    let questions =
        [asked_about(&workspace.close_layout_tab(&layout_tab)), asked_about(&workspace.close_pane(&inner))];

    assert_eq!(questions, [inner_tabs.clone(), inner_tabs]);
    assert!(!questions.iter().any(|q| q.contains(&TerminalTarget::new(&outer, &outer_tab))));
    assert!(workspace.pane(&inner).is_some());
    assert_eq!(workspace.active_window().map(|w| w.tabs().len()), Some(2));
}

#[test]
fn closing_a_window_or_session_asks_about_all_its_tabs() {
    let mut workspace = Workspace::new();
    let first_window = workspace.active_window_id().to_owned();
    let first_pane = workspace.active_pane_id().to_owned();
    workspace.open_editor(&tmp("a.txt"), false, Some(&first_pane));
    workspace.create_window(None, None).expect("window");
    always_ask(&mut workspace);

    let window_question = asked_about(&workspace.close_window(&first_window));
    let session_id = workspace.active_session_id().to_owned();
    let session_question = asked_about(&workspace.close_session(&session_id));

    assert_eq!([window_question.len(), session_question.len()], [2, 3]);
    assert!(workspace.window(&first_window).is_some());
    assert_eq!(workspace.pane(&first_pane).map(|p| p.tabs.len()), Some(2));
}

#[test]
fn the_predicate_decides_which_closes_need_confirmation() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let editor = workspace.open_editor(&tmp("dirty.txt"), false, Some(&pane)).expect("opened");
    let dirty = editor.clone();
    workspace.set_close_confirmation(Some(Box::new(move |targets| targets.contains(&dirty))));
    let terminal = workspace.add_tab_to_pane(&pane, PaneType::Terminal, None, None).expect("tab");

    assert_eq!(workspace.remove_tab_from_pane(&pane, &terminal), CloseOutcome::Closed);
    assert!(matches!(
        workspace.remove_tab_from_pane(&pane, &editor.tab_id),
        CloseOutcome::NeedsConfirmation { .. }
    ));
    assert!(matches!(
        workspace.restore_workspace(workspace.snapshot_workspace()),
        CloseOutcome::NeedsConfirmation { request: crate::CloseRequest::RestoreWorkspace(_), .. }
    ));
}

// MARK: - Markdown readers

#[test]
fn markdown_previews_reuse_a_reader_tab_in_the_calling_pane_and_preserve_the_terminal() {
    let mut workspace = Workspace::new();
    let owner = workspace.active_pane_id().to_owned();
    let terminal_tab = active_tab_id(&workspace, &owner);
    let original_layout = workspace.layout().cloned();

    let reader = workspace.preview_markdown(&tmp("project/README.md"), &owner).expect("reader");
    let reader_tab = workspace.tab(&owner, &reader).cloned().expect("tab");
    assert_eq!(workspace.layout().cloned(), original_layout);
    assert_eq!(workspace.window_count(), 1);
    assert_eq!(
        workspace.pane(&owner).map(|p| p.tabs.iter().map(|t| t.id.clone()).collect::<Vec<_>>()),
        Some(vec![terminal_tab.clone(), reader.clone()])
    );
    assert!(reader_tab.is_markdown());
    assert_eq!(reader_tab.preview_owner_pane_id.as_deref(), Some(owner.as_str()));
    assert_eq!(reader_tab.url, Some(url_of("project/README.md")));
    assert_eq!(workspace.markdown_preview_target(&owner), Some(TerminalTarget::new(&owner, &reader)));

    workspace.focus_tab(&owner, &terminal_tab, false);
    workspace.preview_markdown(&tmp("project/docs/design.md"), &owner).expect("reader");
    let updated = workspace.pane(&owner).and_then(|p| p.active_tab()).cloned().expect("tab");
    assert_eq!(updated.id, reader);
    assert_eq!(workspace.pane(&owner).map(|p| p.tabs.len()), Some(2));
    assert_eq!(workspace.layout().cloned(), original_layout);
    assert_eq!(updated.url, Some(url_of("project/docs/design.md")));
    assert_eq!(updated.title, "design.md");
    assert_eq!(updated.cwd, Some(tmp("project/docs").to_string_lossy().into_owned()));

    workspace.remove_tab_from_pane(&owner, &reader);
    assert_eq!(workspace.active_pane_id(), owner);
    assert_eq!(active_tab_id(&workspace, &owner), terminal_tab);
    assert_eq!(workspace.layout().cloned(), original_layout);
}

#[test]
fn markdown_reader_metadata_round_trips_without_adding_a_new_pane_type() {
    let mut source = Workspace::new();
    let owner = source.active_pane_id().to_owned();
    let terminal_tab = active_tab_id(&source, &owner);
    let file = tmp("project/README.md");
    let reader = source.preview_markdown(&file, &owner).expect("reader");

    let mut restored = Workspace::new();
    restored.restore_workspace(source.snapshot_workspace());
    let tab = restored.pane(&owner).and_then(|p| p.active_tab()).cloned().expect("tab");

    assert_eq!(tab.id, reader);
    assert_eq!(tab.pane_type, PaneType::Browser);
    assert!(tab.is_markdown());
    assert_eq!(tab.url, Some(file_url::file_url_string(&file)));
    assert_eq!(tab.preview_owner_pane_id.as_deref(), Some(owner.as_str()));
    assert_eq!(restored.pane(&owner).map(|p| p.tabs[0].id.clone()), Some(terminal_tab));
    assert_eq!(restored.preview_markdown(&file, &owner), Some(reader));
    assert_eq!(restored.pane(&owner).map(|p| p.tabs.len()), Some(2));
    assert_eq!(restored.layout().map(SplitNode::ordered_leaf_ids), Some(vec![owner]));
}

#[test]
fn markdown_previews_show_the_callers_background_tab_even_when_another_window_is_active() {
    let mut workspace = Workspace::new();
    let owner_window = workspace.active_window_id().to_owned();
    let root = workspace.active_pane_id().to_owned();
    let sibling = workspace.split_pane(SplitDirection::Horizontal, &root).expect("split");
    workspace.create_layout_tab(None, None).expect("tab");
    let owner = workspace.active_pane_id().to_owned();
    let original_layout = workspace.layout().cloned();
    workspace.activate_previous_layout_tab();
    let other_window = workspace.create_window(None, None).expect("window");
    let other_layout = workspace.layout().cloned();

    workspace.preview_markdown(&tmp("project/README.md"), &owner).expect("reader");

    assert_eq!(workspace.active_window_id(), owner_window);
    assert_eq!(workspace.active_pane_id(), owner);
    assert_eq!(workspace.window(&owner_window).map(|w| w.active_tab_index()), Some(1));
    assert_eq!(workspace.layout().cloned(), original_layout);
    assert_eq!(workspace.pane(&sibling).map(|p| p.tabs.len()), Some(1));
    assert_eq!(workspace.window(&other_window).and_then(|w| w.layout().cloned()), other_layout);
}

#[test]
fn markdown_preview_keeps_the_calling_pane_maximized() {
    let mut workspace = Workspace::new();
    let owner = workspace.active_pane_id().to_owned();
    workspace.split_pane(SplitDirection::Horizontal, &owner).expect("split");
    workspace.focus_pane(&owner);
    workspace.toggle_maximize();
    let original_layout = workspace.layout().cloned();

    for _ in 0..2 {
        workspace.preview_markdown(&tmp("project/README.md"), &owner).expect("reader");
        assert_eq!(workspace.maximized_pane_id(), Some(owner.as_str()));
        assert_eq!(workspace.layout().cloned(), original_layout);
    }
}

#[test]
fn markdown_previews_use_tab_capacity_and_can_reuse_a_reader_when_the_pane_is_full() {
    let mut workspace = Workspace::new();
    let owner = workspace.active_pane_id().to_owned();
    let file = tmp("project/README.md");
    for _ in 1..Workspace::MAX_PANES_PER_TAB {
        workspace.spawn_terminal(None).expect("pane");
    }
    let original_layout = workspace.layout().cloned();
    let reader = workspace.preview_markdown(&file, &owner).expect("reader");
    for _ in 2..PaneState::MAX_TABS_PER_PANE {
        workspace.add_tab_to_pane(&owner, PaneType::Terminal, None, None).expect("tab");
    }
    assert_eq!(workspace.preview_markdown(&file, &owner), Some(reader.clone()));
    assert_eq!(workspace.layout().cloned(), original_layout);
    assert_eq!(workspace.pane(&owner).map(|p| p.tabs.len()), Some(PaneState::MAX_TABS_PER_PANE));

    workspace.remove_tab_from_pane(&owner, &reader);
    workspace.add_tab_to_pane(&owner, PaneType::Terminal, None, None).expect("tab");
    let active = active_tab_id(&workspace, &owner);
    assert_eq!(workspace.preview_markdown(&file, &owner), None);
    assert_eq!(active_tab_id(&workspace, &owner), active);
    assert_eq!(workspace.layout().cloned(), original_layout);
}

#[test]
fn new_markdown_readers_split_beside_the_active_pane() {
    let mut workspace = Workspace::new();
    let owner = workspace.active_pane_id().to_owned();
    let file = tmp("project/README.md");
    let preview = workspace.preview_markdown(&file, &owner).expect("reader");

    let new_pane = workspace.spawn_markdown(&file, None).expect("pane");

    assert_ne!(new_pane, owner);
    assert_eq!(
        workspace.layout().map(SplitNode::ordered_leaf_ids),
        Some(vec![owner.clone(), new_pane.clone()])
    );
    let tab = workspace.pane(&new_pane).and_then(|p| p.active_tab()).expect("tab");
    assert!(tab.is_markdown());
    assert!(tab.preview_owner_pane_id.is_none());
    assert_eq!(workspace.markdown_preview_target(&owner).map(|t| t.tab_id), Some(preview));
}

#[test]
fn restored_standalone_previews_do_not_pull_new_markdown_previews_out_of_the_calling_pane() {
    let mut source = Workspace::new();
    let owner = source.active_pane_id().to_owned();
    let file = tmp("project/README.md");
    let old_reader = source.spawn_markdown(&file, Some(&owner)).expect("pane");
    let mut restored = Workspace::new();
    restored.restore_workspace(source.snapshot_workspace());
    let original_layout = restored.layout().cloned();

    restored.preview_markdown(&file, &owner).expect("reader");

    assert_eq!(restored.active_pane_id(), owner);
    assert_eq!(restored.markdown_preview_target(&owner).map(|t| t.pane_id), Some(owner));
    assert_eq!(
        restored.pane(&old_reader).and_then(|p| p.active_tab()).and_then(|t| t.url.clone()),
        Some(file_url::file_url_string(&file))
    );
    assert_eq!(restored.layout().cloned(), original_layout);
}

#[test]
fn older_saved_browser_tabs_decode_without_markdown_metadata() {
    let tab: SavedTab =
        serde_json::from_str(r#"{"id":"tab-4","type":"browser","url":"https://example.com"}"#)
            .expect("decodes");
    assert!(tab.content_kind.is_none());
    assert!(tab.preview_owner_pane_id.is_none());
}

// MARK: - Browser panes

#[test]
fn browser_pane_spawns_to_the_right_and_preserves_its_url_when_split() {
    let mut workspace = Workspace::new();
    let browser_pane = workspace.spawn_browser(Some("http://localhost:4173")).expect("pane");
    let browser_tab = workspace.pane(&browser_pane).and_then(|p| p.active_tab()).cloned().expect("tab");

    assert_eq!(browser_tab.pane_type, PaneType::Browser);
    assert_eq!(browser_tab.url.as_deref(), Some("http://localhost:4173"));
    assert_eq!(
        workspace.layout().map(SplitNode::ordered_leaf_ids),
        Some(vec!["pane-1".to_owned(), browser_pane.clone()])
    );
    assert_eq!(workspace.active_pane_id(), browser_pane);

    let split = workspace.split_pane(SplitDirection::Vertical, &browser_pane).expect("split");
    let split_tab = workspace.pane(&split).and_then(|p| p.active_tab()).expect("tab");
    assert_eq!(split_tab.pane_type, PaneType::Browser);
    assert_eq!(split_tab.url, browser_tab.url);
}

#[test]
fn browser_url_and_type_round_trip_through_workspace_persistence() {
    let mut source = Workspace::new();
    let pane = source.spawn_browser(Some("https://example.com/first")).expect("pane");
    let tab = active_tab_id(&source, &pane);
    source.update_browser_url(&pane, &tab, "https://example.com/restored");
    source.rename_tab(&pane, &tab, "Example");

    let mut restored = Workspace::new();
    restored.restore_workspace(source.snapshot_workspace());
    let restored_tab = restored.pane(&pane).and_then(|p| p.active_tab()).expect("tab");

    assert_eq!(restored_tab.pane_type, PaneType::Browser);
    assert_eq!(restored_tab.url.as_deref(), Some("https://example.com/restored"));
    assert_eq!(restored_tab.title, "Example");
}

#[test]
fn omp_web_opens_a_terminal_that_runs_the_launcher() {
    let mut workspace = Workspace::new();
    let pane = workspace.spawn_omp_web(Path::new("/opt/omp/bin/omp")).expect("pane");
    let tab = workspace.pane(&pane).and_then(|p| p.active_tab()).expect("tab");
    assert_eq!(tab.title, "omp web");
    assert_eq!(tab.startup_command, Some(vec!["/opt/omp/bin/omp".to_owned(), "web".to_owned()]));
}
