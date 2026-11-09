//! View tests (`EditorTabTests`): editing, saving, preview tabs, the shared document.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use gpui::{Entity, TestAppContext, VisualTestContext};
use soprano_text::SyntaxTokenKind;

use super::*;
use crate::documents::EditorDocuments;

fn setup(cx: &mut TestAppContext) {
    cx.update(|cx| {
        soprano_ui::init_for_tests(cx);
        cx.bind_keys(key_bindings(cx));
    });
}

fn file(name: &str, text: &str) -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::tempdir().expect("temp dir");
    let path = root.path().join(name);
    std::fs::write(&path, text).expect("write");
    (root, path)
}

type Events = Rc<RefCell<Vec<EditorEvent>>>;

fn open(
    cx: &mut TestAppContext,
    documents: &Entity<EditorDocuments<&'static str>>,
    target: &'static str,
    path: &std::path::Path,
) -> (Entity<EditorView<&'static str>>, Events, VisualTestContext) {
    let path = path.to_path_buf();
    let documents = documents.clone();
    let (view, cx) = cx.add_window_view(move |window, cx| {
        EditorView::new(documents.clone(), target, path.clone(), window, cx)
    });
    let events: Events = Rc::default();
    let sink = events.clone();
    cx.update(|_, cx| {
        cx.subscribe(&view, move |_, event: &EditorEvent, _| sink.borrow_mut().push(event.clone())).detach();
    });
    (view, events, cx.clone())
}

#[gpui::test]
async fn an_editor_tab_edits_saves_and_stops_being_a_preview(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = file("main.swift", "let a = 1\n");
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (view, events, mut window_cx) = open(cx, &documents, "tab-1", &path);
    let cx = &mut window_cx;

    assert_eq!(view.read_with(cx, |view, cx| view.text(cx)), "let a = 1\n");
    cx.run_until_parked();
    let id = view.read_with(cx, |view, _| view.document_id());
    let first = documents.read_with(cx, |documents, _| {
        documents.document(id).and_then(|document| document.tokens().first().map(|token| token.kind))
    });
    assert_eq!(first, Some(SyntaxTokenKind::Keyword));

    view.update_in(cx, |view, window, cx| {
        view.select(8..9, cx);
        view.replace_text_in_range(None, "2", window, cx);
    });
    cx.run_until_parked();
    assert!(events.borrow().contains(&EditorEvent::KeepTab));
    assert!(events.borrow().contains(&EditorEvent::TitleChanged("main.swift ●".into())));
    assert!(events.borrow().contains(&EditorEvent::ModifiedChanged(true)));

    // Elsewhere ⌘S passes on to whatever has the keyboard.
    cx.simulate_keystrokes(&keys::command("s"));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "let a = 1\n");

    view.update_in(cx, |view, window, cx| view.focus.focus(window, cx));
    cx.simulate_keystrokes(&keys::command("s"));
    cx.run_until_parked();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "let a = 2\n");
    assert!(events.borrow().contains(&EditorEvent::Saved));
    assert_eq!(events.borrow().last(), Some(&EditorEvent::TitleChanged("main.swift".into())));
    assert_eq!(view.read_with(cx, |view, cx| view.title(cx)), "main.swift");
}

#[gpui::test]
async fn two_tabs_of_a_file_share_one_text_and_one_undo_history(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = file("notes.txt", "one\n");
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (first, _, mut first_cx) = open(cx, &documents, "tab-1", &path);
    let (second, second_events, mut second_cx) = open(cx, &documents, "tab-2", &path);
    let (cx_first, cx_second) = (&mut first_cx, &mut second_cx);

    first.update_in(cx_first, |view, window, cx| {
        view.select(3..3, cx);
        view.replace_text_in_range(None, " two", window, cx);
    });
    cx_first.run_until_parked();
    assert_eq!(second.read_with(cx_second, |view, cx| view.text(cx)), "one two\n");
    assert!(second_events.borrow().contains(&EditorEvent::TitleChanged("notes.txt ●".into())));

    second.update_in(cx_second, |view, window, cx| view.undo(&Undo, window, cx));
    assert_eq!(first.read_with(cx_first, |view, cx| view.text(cx)), "one\n");

    // Closing one tab keeps the document; closing the last one closes it.
    let id = first.read_with(cx_first, |view, _| view.document_id());
    drop(first);
    cx_first.update(|window, _| window.remove_window());
    cx_first.run_until_parked();
    assert!(documents.read_with(cx_second, |documents, _| documents.document(id).is_some()));
    drop(second);
    cx_second.update(|window, _| window.remove_window());
    cx_second.run_until_parked();
    assert!(documents.read_with(cx_second, |documents, _| documents.document(id).is_none()));
}

#[gpui::test]
async fn return_keeps_the_lines_indentation(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = file("app.rs", "fn main() {\n    let x = 1;\n}\n");
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (view, _, mut window_cx) = open(cx, &documents, "tab", &path);
    let cx = &mut window_cx;
    view.update_in(cx, |view, window, cx| {
        view.select(26..26, cx);
        view.focus.focus(window, cx);
    });
    cx.simulate_keystrokes("enter");
    cx.simulate_input("x");
    assert_eq!(view.read_with(cx, |view, cx| view.text(cx)), "fn main() {\n    let x = 1;\n    x\n}\n");
}

#[gpui::test]
async fn saving_over_a_newer_version_on_disk_asks_first(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = file("a.txt", "old\n");
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (view, events, mut window_cx) = open(cx, &documents, "tab", &path);
    let cx = &mut window_cx;
    view.update_in(cx, |view, window, cx| {
        view.select(0..3, cx);
        view.replace_text_in_range(None, "mine", window, cx);
    });
    std::fs::write(&path, "theirs, and longer\n").unwrap();

    view.update_in(cx, |view, window, cx| view.save(&Save, window, cx));
    let dialog = view.read_with(cx, |view, _| view.dialog.clone()).expect("the overwrite question");
    assert_eq!(
        dialog.read_with(cx, |dialog, _| dialog.content().title.clone()),
        "“a.txt” has changed on disk."
    );
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "theirs, and longer\n");

    dialog.update_in(cx, |dialog, window, cx| dialog.finish(Some(1), window, cx));
    cx.run_until_parked();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "mine\n");
    assert!(events.borrow().contains(&EditorEvent::Saved));
}

#[gpui::test]
async fn find_selects_the_next_and_previous_match(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = file("f.txt", "one two one two\n");
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (view, _, mut window_cx) = open(cx, &documents, "tab", &path);
    let cx = &mut window_cx;
    view.update_in(cx, |view, window, cx| {
        view.find(&Find, window, cx);
        view.find.input.update(cx, |input, cx| input.set_value("TWO", window, cx));
        view.update_matches(true, cx);
    });
    assert_eq!(view.read_with(cx, |view, _| view.selected_range()), 4..7);
    assert_eq!(view.read_with(cx, |view, cx| view.match_label(cx)), "1 of 2");
    view.update_in(cx, |view, window, cx| view.find_next(&FindNext, window, cx));
    assert_eq!(view.read_with(cx, |view, _| view.selected_range()), 12..15);
    view.update_in(cx, |view, window, cx| view.find_next(&FindNext, window, cx));
    assert_eq!(view.read_with(cx, |view, _| view.selected_range()), 4..7);
    view.update_in(cx, |view, window, cx| view.find_previous(&FindPrevious, window, cx));
    assert_eq!(view.read_with(cx, |view, _| view.selected_range()), 12..15);
}

#[gpui::test]
async fn binary_files_show_a_note_instead_of_text(cx: &mut TestAppContext) {
    setup(cx);
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("blob.bin");
    std::fs::write(&path, [0_u8, 1, 2, 3]).unwrap();
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (view, _, mut window_cx) = open(cx, &documents, "tab", &path);
    let cx = &mut window_cx;
    let content =
        view.read_with(cx, |view, cx| view.with_document(cx, |document| document.content().clone()));
    assert_eq!(content, Some(DocumentContent::Unavailable("“blob.bin” isn't a UTF-8 text file.".into())));
    assert!(!view.read_with(cx, |view, cx| view.is_editable(cx)));
}
