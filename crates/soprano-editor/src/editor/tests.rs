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

#[gpui::test]
async fn an_edit_in_one_tab_moves_the_other_tabs_selection(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = file("shared.txt", "alpha beta gamma\n");
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (first, _, mut first_cx) = open(cx, &documents, "tab-1", &path);
    let (second, _, mut second_cx) = open(cx, &documents, "tab-2", &path);
    let (cx_first, cx_second) = (&mut first_cx, &mut second_cx);
    // The first tab selects "gamma".
    first.update(cx_first, |view, cx| view.select(11..16, cx));

    // The second tab types before it: the selection moves with the text.
    second.update_in(cx_second, |view, window, cx| {
        view.select(0..0, cx);
        view.replace_text_in_range(None, ">> ", window, cx);
    });
    assert_eq!(first.read_with(cx_first, |view, _| view.selected_range()), 14..19);
    assert_eq!(first.read_with(cx_first, |view, cx| view.text(cx))[14..19].to_string(), "gamma");

    // An edit after it leaves it; deleting text that holds it collapses it to the edit's end.
    second.update_in(cx_second, |view, window, cx| {
        view.select(19..19, cx);
        view.replace_text_in_range(None, "!", window, cx);
    });
    assert_eq!(first.read_with(cx_first, |view, _| view.selected_range()), 14..19);
    second.update_in(cx_second, |view, window, cx| {
        view.select(9..20, cx);
        view.replace_text_in_range(None, "", window, cx);
    });
    assert_eq!(first.read_with(cx_first, |view, _| view.selected_range()), 9..9);

    // Undo in the second tab puts the text back at the caret: text inserted where a caret
    // stands goes after it.
    second.update_in(cx_second, |view, window, cx| view.undo(&Undo, window, cx));
    assert_eq!(first.read_with(cx_first, |view, _| view.selected_range()), 9..9);
    assert_eq!(first.read_with(cx_first, |view, cx| view.text(cx)), ">> alpha beta gamma!\n");
}

fn long_file(lines: usize) -> (tempfile::TempDir, PathBuf) {
    let text: String = (1..=lines).map(|n| format!("line {n}\n")).collect();
    file("long.txt", &text)
}

fn laid_out(
    view: &Entity<EditorView<&'static str>>,
    cx: &mut VisualTestContext,
) -> gpui::Bounds<gpui::Pixels> {
    cx.run_until_parked();
    view.read_with(cx, |view, _| view.layout.as_ref().map(|layout| layout.bounds))
        .expect("the editor painted")
}

#[gpui::test]
async fn the_scroll_bar_drags_and_pages_like_a_scroller(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = long_file(400);
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (view, _, mut window_cx) = open(cx, &documents, "tab", &path);
    let cx = &mut window_cx;
    let bounds = laid_out(&view, cx);
    let lane_x = bounds.right() - gpui::px(5.0);
    let scroll = |view: &Entity<EditorView<&'static str>>, cx: &mut VisualTestContext| {
        view.read_with(cx, |view, _| f32::from(view.scroll.y))
    };

    // A click in the track below the thumb pages down by the viewport's height.
    cx.simulate_mouse_down(
        gpui::point(lane_x, bounds.bottom() - gpui::px(4.0)),
        MouseButton::Left,
        Default::default(),
    );
    cx.simulate_mouse_up(
        gpui::point(lane_x, bounds.bottom() - gpui::px(4.0)),
        MouseButton::Left,
        Default::default(),
    );
    let page = f32::from(bounds.size.height);
    assert!((scroll(&view, cx) - page).abs() < 1.0, "paged to {}", scroll(&view, cx));

    // Dragging the thumb down scrolls in proportion.
    cx.run_until_parked();
    let (top, length, max) = view.read_with(cx, |view, _| {
        let layout = view.layout.as_ref().expect("laid out");
        let bar = layout.scrollbar(layout.max_scroll(view.widest_columns).y).expect("scrolls");
        (bar.thumb_top(f32::from(view.scroll.y)), bar.thumb_length(), bar.max_scroll)
    });
    let grab = gpui::point(lane_x, gpui::px(top + length / 2.0));
    cx.simulate_mouse_down(grab, MouseButton::Left, Default::default());
    let travel = f32::from(bounds.size.height) - length;
    cx.simulate_mouse_move(
        gpui::point(lane_x, grab.y + gpui::px(travel)),
        MouseButton::Left,
        Default::default(),
    );
    assert!((scroll(&view, cx) - max).abs() < 1.0, "dragged to {}", scroll(&view, cx));
    cx.simulate_mouse_up(
        gpui::point(lane_x, grab.y + gpui::px(travel)),
        MouseButton::Left,
        Default::default(),
    );
    assert!(view.read_with(cx, |view, _| view.thumb_grab.is_none()));
}

#[gpui::test]
async fn a_drag_selection_past_the_bottom_keeps_scrolling(cx: &mut TestAppContext) {
    setup(cx);
    let (_root, path) = long_file(400);
    let documents = cx.new(|_| EditorDocuments::<&'static str>::new());
    let (view, _, mut window_cx) = open(cx, &documents, "tab", &path);
    let cx = &mut window_cx;
    let bounds = laid_out(&view, cx);
    let start = gpui::point(bounds.left() + gpui::px(80.0), bounds.top() + gpui::px(15.0));
    cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
    let below = gpui::point(start.x, bounds.bottom() + gpui::px(40.0));
    cx.simulate_mouse_move(below, MouseButton::Left, Default::default());
    cx.executor().advance_clock(std::time::Duration::from_millis(500));
    cx.run_until_parked();
    let (scrolled, head) = view.read_with(cx, |view, _| (f32::from(view.scroll.y), view.head));
    assert!(scrolled >= 200.0, "scrolled {scrolled}");
    // The selection reaches past the first screen of lines.
    let rows_on_screen = (f32::from(bounds.size.height) / 20.0) as usize;
    assert!(head > rows_on_screen * "line 10\n".len(), "head {head}");
    cx.simulate_mouse_up(below, MouseButton::Left, Default::default());
    let after = view.read_with(cx, |view, _| f32::from(view.scroll.y));
    cx.executor().advance_clock(std::time::Duration::from_millis(500));
    cx.run_until_parked();
    assert_eq!(view.read_with(cx, |view, _| f32::from(view.scroll.y)), after);
}
