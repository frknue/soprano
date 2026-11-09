//! A file open in Soprano (port of `Views/EditorPaneView.swift`): an editable, syntax-colored
//! text with line numbers, find (⌘F, ⌘G, ⇧⌘G), undo and ⌘S; images are shown at their size,
//! other files get a note and a way out to their default app. The toolbar shows the
//! breadcrumbs, the status ("Modified", "Changed on disk" + Reload, …) and the Markdown
//! preview, save, open-externally and reveal buttons.
//!
//! Every tab showing the same file shares one `EditorDocument` through [`EditorDocuments`],
//! so edits, undo and the saved state are the same in each.
//!
//! The editor is drawn on GPUI primitives rather than gpui-component's code editor: that
//! editor owns its own rope and undo stack per instance, so two tabs of one file could not
//! share one buffer and one undo history, and its highlighter seam re-parses per instance
//! instead of taking the document's shared soprano-text tokens.

mod element;
pub mod layout;

use std::hash::Hash;
use std::ops::Range;
use std::path::PathBuf;
use std::sync::Arc;

use gpui::{
    App, AppContext as _, ClipboardItem, Context, Entity, EntityInputHandler, EventEmitter, FocusHandle,
    Focusable, Image, ImageFormat, InteractiveElement, IntoElement, KeyBinding, MouseButton, MouseDownEvent,
    MouseMoveEvent, ObjectFit, ParentElement, Pixels, Point, Render, ScrollEvent, SharedString, Styled,
    StyledImage, Subscription, Task, UTF16Selection, Window, actions, anchored, deferred, div, img,
    prelude::FluentBuilder, px,
};
use soprano_text::editor::{DocumentChange, DocumentContent, StatusTone, restore_selection};
use soprano_text::editor_store::{OVERWRITE_MESSAGE, SaveOutcome, overwrite_question};
use soprano_text::{DocumentId, EditorDocument};
use soprano_ui::button::{Button, ButtonSize, ButtonVariant};
use soprano_ui::dialog::{Dialog, DialogButton, DialogContent};
use soprano_ui::fonts::size;
use soprano_ui::{ActiveSopranoTheme, IconName};
use soprano_ui::{InputEvent, InputState, TextInput};

use crate::colors::SurfaceColors;
use crate::documents::{DocumentsEvent, EditorDocuments, TextEdit};
use crate::keys;
use crate::surface::{SurfaceMessage, SurfaceToolbar, breadcrumbs, display_path, toolbar_button};
use element::{EditorElement, EditorLayout};
use layout::{DisplayLine, next_boundary, previous_boundary, word_end, word_range, word_start};

/// The key context of a focused editor.
pub const EDITOR_CONTEXT: &str = "SopranoEditor";
/// How far around the caret word and character motion look (a word longer than this stops
/// at its edge).
const MOTION_CONTEXT: usize = 4096;

/// How often a drag selection past the edge scrolls.
const DRAG_SCROLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(50);

/// The key context of the editor's find field.
pub const FIND_CONTEXT: &str = "SopranoEditorFind";

actions!(
    soprano_editor,
    [
        /// ⌘S: save (asks first over a newer version on disk).
        Save,
        /// ⌘F: show the find bar.
        Find,
        /// ⌘G: the next match.
        FindNext,
        /// ⇧⌘G: the previous match.
        FindPrevious,
        /// Esc in the find bar: hide it.
        CloseFind,
        Undo,
        Redo,
        Copy,
        Cut,
        Paste,
        SelectAll,
        MoveLeft,
        MoveRight,
        MoveUp,
        MoveDown,
        MoveWordLeft,
        MoveWordRight,
        MoveLineStart,
        MoveLineEnd,
        MoveDocumentStart,
        MoveDocumentEnd,
        MovePageUp,
        MovePageDown,
        SelectLeft,
        SelectRight,
        SelectUp,
        SelectDown,
        SelectWordLeft,
        SelectWordRight,
        SelectLineStart,
        SelectLineEnd,
        SelectDocumentStart,
        SelectDocumentEnd,
        SelectPageUp,
        SelectPageDown,
        Backspace,
        Delete,
        DeleteWordLeft,
        DeleteWordRight,
        DeleteToLineStart,
        /// Return: a line break keeping the line's indentation.
        Newline,
        InsertTab,
    ]
);

/// The editor's key bindings; the app binds them once (`cx.bind_keys(key_bindings(cx))`).
/// ⌘S, ⌘F, ⌘G and ⇧⌘G follow Soprano's chord mapping; text editing follows each platform.
pub fn key_bindings(cx: &App) -> Vec<KeyBinding> {
    let (editor, find) = (EDITOR_CONTEXT, FIND_CONTEXT);
    let mut table: Vec<(String, Box<dyn gpui::Action>, &str)> = vec![
        (keys::command("s"), Box::new(Save), editor),
        (keys::command("f"), Box::new(Find), editor),
        (keys::command("g"), Box::new(FindNext), editor),
        (keys::shift_command("g"), Box::new(FindPrevious), editor),
        (keys::command("s"), Box::new(Save), find),
        (keys::command("g"), Box::new(FindNext), find),
        (keys::shift_command("g"), Box::new(FindPrevious), find),
        ("escape".into(), Box::new(CloseFind), find),
    ];
    let plain: Vec<(&str, Box<dyn gpui::Action>)> = vec![
        ("secondary-z", Box::new(Undo)),
        ("secondary-shift-z", Box::new(Redo)),
        ("secondary-c", Box::new(Copy)),
        ("secondary-x", Box::new(Cut)),
        ("secondary-v", Box::new(Paste)),
        ("secondary-a", Box::new(SelectAll)),
        ("left", Box::new(MoveLeft)),
        ("right", Box::new(MoveRight)),
        ("up", Box::new(MoveUp)),
        ("down", Box::new(MoveDown)),
        ("home", Box::new(MoveLineStart)),
        ("end", Box::new(MoveLineEnd)),
        ("pageup", Box::new(MovePageUp)),
        ("pagedown", Box::new(MovePageDown)),
        ("shift-left", Box::new(SelectLeft)),
        ("shift-right", Box::new(SelectRight)),
        ("shift-up", Box::new(SelectUp)),
        ("shift-down", Box::new(SelectDown)),
        ("shift-home", Box::new(SelectLineStart)),
        ("shift-end", Box::new(SelectLineEnd)),
        ("shift-pageup", Box::new(SelectPageUp)),
        ("shift-pagedown", Box::new(SelectPageDown)),
        ("backspace", Box::new(Backspace)),
        ("shift-backspace", Box::new(Backspace)),
        ("delete", Box::new(Delete)),
        ("enter", Box::new(Newline)),
        ("tab", Box::new(InsertTab)),
    ];
    let platform: Vec<(&str, Box<dyn gpui::Action>)> = if cfg!(target_os = "macos") {
        vec![
            ("cmd-left", Box::new(MoveLineStart)),
            ("cmd-right", Box::new(MoveLineEnd)),
            ("alt-left", Box::new(MoveWordLeft)),
            ("alt-right", Box::new(MoveWordRight)),
            ("cmd-up", Box::new(MoveDocumentStart)),
            ("cmd-down", Box::new(MoveDocumentEnd)),
            ("cmd-shift-left", Box::new(SelectLineStart)),
            ("cmd-shift-right", Box::new(SelectLineEnd)),
            ("alt-shift-left", Box::new(SelectWordLeft)),
            ("alt-shift-right", Box::new(SelectWordRight)),
            ("cmd-shift-up", Box::new(SelectDocumentStart)),
            ("cmd-shift-down", Box::new(SelectDocumentEnd)),
            ("alt-backspace", Box::new(DeleteWordLeft)),
            ("alt-delete", Box::new(DeleteWordRight)),
            ("cmd-backspace", Box::new(DeleteToLineStart)),
            ("ctrl-a", Box::new(MoveLineStart)),
            ("ctrl-e", Box::new(MoveLineEnd)),
        ]
    } else {
        vec![
            ("ctrl-y", Box::new(Redo)),
            ("ctrl-left", Box::new(MoveWordLeft)),
            ("ctrl-right", Box::new(MoveWordRight)),
            ("ctrl-home", Box::new(MoveDocumentStart)),
            ("ctrl-end", Box::new(MoveDocumentEnd)),
            ("ctrl-shift-left", Box::new(SelectWordLeft)),
            ("ctrl-shift-right", Box::new(SelectWordRight)),
            ("ctrl-shift-home", Box::new(SelectDocumentStart)),
            ("ctrl-shift-end", Box::new(SelectDocumentEnd)),
            ("ctrl-backspace", Box::new(DeleteWordLeft)),
            ("ctrl-delete", Box::new(DeleteWordRight)),
        ]
    };
    table.extend(plain.into_iter().chain(platform).map(|(keys, action)| (keys.to_string(), action, editor)));
    table
        .into_iter()
        .filter_map(|(keystrokes, action, context)| keys::bind(&keystrokes, action, context, cx))
        .collect()
}

/// What an editor tells the app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditorEvent {
    /// The tab title: the file name, with ● while it has unsaved changes.
    TitleChanged(SharedString),
    /// Unsaved changes appeared (`true`) or went (`false`).
    ModifiedChanged(bool),
    /// The document gained unsaved changes: its tab stops being a preview.
    KeepTab,
    /// The document was written to disk.
    Saved,
    /// Open Markdown Preview: show the file in the reader.
    OpenMarkdownPreview(PathBuf),
    /// The editor was clicked or took the keyboard: focus its pane.
    FocusRequested,
}

struct FindBar {
    visible: bool,
    input: Entity<InputState>,
    matches: Vec<Range<usize>>,
    current: Option<usize>,
}

pub struct EditorView<T: Clone + Eq + Hash + 'static> {
    documents: Entity<EditorDocuments<T>>,
    document: DocumentId,
    target: T,
    focus: FocusHandle,
    anchor: usize,
    head: usize,
    goal_column: Option<usize>,
    marked: Option<Range<usize>>,
    scroll: Point<Pixels>,
    widest_columns: usize,
    autoscroll: bool,
    selecting: bool,
    /// Grabbing the scroll bar's thumb: the grab's distance below the thumb's top.
    thumb_grab: Option<f32>,
    /// Where a drag selection's pointer is, and the loop scrolling while it is past an edge.
    drag_point: Option<Point<Pixels>>,
    drag_scrolling: bool,
    drag_scroll: Option<Task<()>>,
    layout: Option<EditorLayout>,
    find: FindBar,
    pending_restore: Option<(Vec<Range<usize>>, Point<Pixels>)>,
    dialog: Option<Entity<Dialog>>,
    image: Option<(u64, Arc<Image>)>,
    was_dirty: bool,
    _subscriptions: Vec<Subscription>,
}

impl<T: Clone + Eq + Hash + 'static> EventEmitter<EditorEvent> for EditorView<T> {}

impl<T: Clone + Eq + Hash + 'static> Focusable for EditorView<T> {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl<T: Clone + Eq + Hash + 'static> EditorView<T> {
    /// Shows `path` in tab `target`, sharing the document any other tab of it has open.
    pub fn new(
        documents: Entity<EditorDocuments<T>>,
        target: T,
        path: impl Into<PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let path = path.into();
        let view = cx.entity_id();
        let document = documents.update(cx, |documents, cx| {
            let id = documents.open(&path, cx);
            documents.attach(view, target.clone(), id);
            id
        });
        let input = cx.new(|cx| InputState::new(window, cx).placeholder("Find"));
        let subscriptions =
            vec![
                cx.subscribe(&documents, move |this: &mut Self, _, event: &DocumentsEvent, cx| match event {
                    DocumentsEvent::Changed { document: changed, changes } if *changed == this.document => {
                        this.document_did_change(changes, cx);
                    }
                    DocumentsEvent::Edited { document: edited, edit, source }
                        if *edited == this.document && *source != view =>
                    {
                        this.text_edited_elsewhere(edit, cx);
                    }
                    DocumentsEvent::Changed { .. } | DocumentsEvent::Edited { .. } => {}
                }),
                cx.subscribe_in(&input, window, |this: &mut Self, _, event: &InputEvent, window, cx| {
                    match event {
                        InputEvent::Change => {
                            this.update_matches(true, cx);
                        }
                        InputEvent::PressEnter { shift, .. } => {
                            if *shift {
                                this.find_previous(&FindPrevious, window, cx);
                            } else {
                                this.find_next(&FindNext, window, cx);
                            }
                        }
                        InputEvent::Focus | InputEvent::Blur => {}
                    }
                }),
                cx.on_release(move |this: &mut Self, cx| {
                    this.documents.update(cx, |documents, _| documents.detach(view));
                }),
            ];
        let was_dirty = documents.read(cx).document(document).is_some_and(EditorDocument::is_dirty);
        Self {
            documents,
            document,
            target,
            focus: cx.focus_handle(),
            anchor: 0,
            head: 0,
            goal_column: None,
            marked: None,
            scroll: Point::default(),
            widest_columns: 0,
            autoscroll: false,
            selecting: false,
            thumb_grab: None,
            drag_point: None,
            drag_scrolling: false,
            drag_scroll: None,
            layout: None,
            find: FindBar { visible: false, input, matches: Vec::new(), current: None },
            pending_restore: None,
            dialog: None,
            image: None,
            was_dirty,
            _subscriptions: subscriptions,
        }
    }

    pub fn target(&self) -> &T {
        &self.target
    }

    pub fn document_id(&self) -> DocumentId {
        self.document
    }

    pub fn documents(&self) -> &Entity<EditorDocuments<T>> {
        &self.documents
    }

    /// The tab title: the file name, with ● while it has unsaved changes.
    pub fn title(&self, cx: &App) -> SharedString {
        self.with_document(cx, EditorDocument::tab_title).unwrap_or_default().into()
    }

    /// The file's path (it follows renames).
    pub fn path(&self, cx: &App) -> Option<PathBuf> {
        self.with_document(cx, |document| document.path().to_path_buf())
    }

    /// The document's text.
    pub fn text(&self, cx: &App) -> String {
        self.with_document(cx, EditorDocument::text).unwrap_or_default()
    }

    /// The selected byte range.
    pub fn selected_range(&self) -> Range<usize> {
        self.anchor.min(self.head)..self.anchor.max(self.head)
    }

    /// Selects `range` (byte offsets, clamped to the text and its character boundaries).
    pub fn select(&mut self, range: Range<usize>, cx: &mut Context<Self>) {
        let clamped = self.with_document(cx, |document| {
            (document.clamp_offset(range.start), document.clamp_offset(range.end))
        });
        let (anchor, head) = clamped.unwrap_or_default();
        self.anchor = anchor;
        self.head = head;
        self.goal_column = None;
        self.autoscroll = true;
        self.break_coalescing(cx);
        cx.notify();
    }

    fn with_document<R>(&self, cx: &App, read: impl FnOnce(&EditorDocument) -> R) -> Option<R> {
        self.documents.read(cx).document(self.document).map(read)
    }

    fn edit<R>(&mut self, cx: &mut Context<Self>, edit: impl FnOnce(&mut EditorDocument) -> R) -> Option<R> {
        let id = self.document;
        self.documents.update(cx, |documents, cx| documents.update(id, cx, edit))
    }

    /// An edit of the text: the other tabs of the document move their selections with it.
    fn edit_text(
        &mut self,
        cx: &mut Context<Self>,
        edit: impl FnOnce(&mut EditorDocument) -> Option<Range<usize>>,
    ) -> Option<Range<usize>> {
        let (id, source) = (self.document, cx.entity_id());
        self.documents.update(cx, |documents, cx| documents.edit_text(id, source, cx, edit))
    }

    /// Another tab of the document edited its text: the selection moves with the edit.
    fn text_edited_elsewhere(&mut self, edit: &TextEdit, cx: &mut Context<Self>) {
        self.anchor = edit.shift(self.anchor);
        self.head = edit.shift(self.head);
        self.marked = None;
        self.goal_column = None;
        cx.notify();
    }

    fn is_editable(&self, cx: &App) -> bool {
        self.with_document(cx, EditorDocument::is_editable).unwrap_or(false)
    }

    fn break_coalescing(&mut self, cx: &mut Context<Self>) {
        self.edit(cx, EditorDocument::break_undo_coalescing);
    }

    // MARK: - Document changes

    fn document_did_change(&mut self, changes: &[DocumentChange], cx: &mut Context<Self>) {
        for change in changes {
            match change {
                DocumentChange::WillReplaceContent => {
                    self.pending_restore = Some((vec![self.selected_range()], self.scroll));
                }
                DocumentChange::Content => {
                    self.image = None;
                    self.widest_columns = 0;
                    if let Some((selection, scroll)) = self.pending_restore.take() {
                        let restored = self
                            .with_document(cx, |document| restore_selection(&selection, document.rope()))
                            .unwrap_or_default();
                        let range = restored.first().cloned().unwrap_or_default();
                        self.anchor = range.start;
                        self.head = range.end;
                        self.scroll = scroll;
                    }
                }
                DocumentChange::State => {
                    let dirty = self.with_document(cx, EditorDocument::is_dirty).unwrap_or(false);
                    if dirty {
                        cx.emit(EditorEvent::KeepTab);
                    }
                    if dirty != self.was_dirty {
                        self.was_dirty = dirty;
                        cx.emit(EditorEvent::ModifiedChanged(dirty));
                    }
                    cx.emit(EditorEvent::TitleChanged(self.title(cx)));
                }
                DocumentChange::Location => cx.emit(EditorEvent::TitleChanged(self.title(cx))),
                DocumentChange::Highlights | DocumentChange::Edited => {}
            }
        }
        // Edits in another tab of the document can leave an offset past the text or inside
        // a character.
        let (anchor, head) = (self.anchor, self.head);
        if let Some((anchor, head)) =
            self.with_document(cx, |document| (document.clamp_offset(anchor), document.clamp_offset(head)))
        {
            self.anchor = anchor;
            self.head = head;
        }
        if self.find.visible {
            self.update_matches(false, cx);
        }
        cx.notify();
    }

    // MARK: - Saving

    /// ⌘S: saves through the store, which asks before overwriting another program's version.
    pub fn save(&mut self, _: &Save, window: &mut Window, cx: &mut Context<Self>) {
        let is_text = self.with_document(cx, |document| *document.content() == DocumentContent::Text);
        if is_text != Some(true) {
            return;
        }
        let id = self.document;
        let outcome = self.documents.update(cx, |documents, cx| documents.save(id, cx));
        self.handle_save(outcome, window, cx);
    }

    fn handle_save(&mut self, outcome: SaveOutcome, window: &mut Window, cx: &mut Context<Self>) {
        match outcome {
            SaveOutcome::Saved => cx.emit(EditorEvent::Saved),
            SaveOutcome::NeedsOverwriteConfirmation => {
                let name = self.with_document(cx, EditorDocument::name).unwrap_or_default();
                let content = DialogContent::new(
                    overwrite_question(&name),
                    OVERWRITE_MESSAGE,
                    vec![DialogButton::new("Cancel"), DialogButton::new("Save Anyway").primary()],
                );
                self.present(content, window, cx, |this, index, window, cx| {
                    if index == Some(1) {
                        let id = this.document;
                        let outcome =
                            this.documents.update(cx, |documents, cx| documents.save_anyway(id, cx));
                        this.handle_save(outcome, window, cx);
                    }
                });
            }
            SaveOutcome::Failed(error) => {
                self.present(DialogContent::alert(error.to_string(), ""), window, cx, |_, _, _, _| {});
            }
        }
    }

    /// Shows `content` over the window; `answer` gets the chosen button.
    fn present(
        &mut self,
        content: DialogContent,
        window: &mut Window,
        cx: &mut Context<Self>,
        answer: impl FnOnce(&mut Self, Option<usize>, &mut Window, &mut Context<Self>) + 'static,
    ) {
        let dialog = Dialog::new(content, window, cx);
        let this = cx.entity().downgrade();
        dialog.update(cx, |dialog, _| {
            dialog.on_finish(move |result, window, cx| {
                let _ = this.update(cx, |this, cx| {
                    this.dialog = None;
                    answer(this, result.index, window, cx);
                    this.focus.focus(window, cx);
                    cx.notify();
                });
            });
        });
        self.dialog = Some(dialog);
        cx.notify();
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        self.edit(cx, EditorDocument::reload_from_disk);
    }

    fn open_externally(&self, cx: &App) {
        if let Some(path) = self.path(cx)
            && let Err(error) = soprano_platform::system::open_default(&path.to_string_lossy())
        {
            tracing::warn!("{error:#}");
        }
    }

    fn reveal(&self, cx: &App) {
        if let Some(path) = self.path(cx)
            && let Err(error) = soprano_platform::system::reveal_in_file_manager(&path)
        {
            tracing::warn!("{error:#}");
        }
    }

    // MARK: - Find

    fn find(&mut self, _: &Find, window: &mut Window, cx: &mut Context<Self>) {
        if !self.is_text(cx) {
            return;
        }
        self.find.visible = true;
        let selection = self.selected_range();
        if !selection.is_empty() {
            let selected =
                self.with_document(cx, |document| document.rope().byte_slice(selection.clone()).to_string());
            if let Some(text) = selected.filter(|text| !text.contains('\n')) {
                self.find.input.update(cx, |input, cx| input.set_value(text, window, cx));
            }
        }
        self.find.input.update(cx, |input, cx| {
            input.focus(window, cx);
            input.select_all(window, cx);
        });
        self.update_matches(false, cx);
        cx.notify();
    }

    fn close_find(&mut self, _: &CloseFind, window: &mut Window, cx: &mut Context<Self>) {
        self.find.visible = false;
        self.find.matches.clear();
        self.find.current = None;
        self.focus.focus(window, cx);
        cx.notify();
    }

    fn query(&self, cx: &App) -> String {
        self.find.input.read(cx).value().to_string()
    }

    /// Recomputes the matches; `select_first` (typing in the field) jumps to the first one at
    /// or after the selection, as incremental search does.
    fn update_matches(&mut self, select_first: bool, cx: &mut Context<Self>) {
        let query = self.query(cx);
        self.find.matches = self.with_document(cx, |document| document.find_all(&query)).unwrap_or_default();
        let from = self.selected_range().start;
        self.find.current = self.find.matches.iter().position(|found| found.start >= from).or((!self
            .find
            .matches
            .is_empty())
        .then_some(0));
        if select_first && let Some(found) = self.find.current.map(|index| self.find.matches[index].clone()) {
            self.anchor = found.start;
            self.head = found.end;
            self.autoscroll = true;
        }
        cx.notify();
    }

    fn find_next(&mut self, _: &FindNext, _: &mut Window, cx: &mut Context<Self>) {
        let query = self.query(cx);
        let from = self.selected_range().end;
        if let Some(found) = self.with_document(cx, |document| document.find_next(&query, from)).flatten() {
            self.select_match(found, cx);
        }
    }

    fn find_previous(&mut self, _: &FindPrevious, _: &mut Window, cx: &mut Context<Self>) {
        let query = self.query(cx);
        let before = self.selected_range().start;
        if let Some(found) =
            self.with_document(cx, |document| document.find_previous(&query, before)).flatten()
        {
            self.select_match(found, cx);
        }
    }

    fn select_match(&mut self, found: Range<usize>, cx: &mut Context<Self>) {
        self.find.current = self.find.matches.iter().position(|candidate| *candidate == found);
        self.select(found, cx);
    }

    /// The find bar's count: "3 of 12", "No results".
    fn match_label(&self, cx: &App) -> String {
        if self.query(cx).is_empty() {
            return String::new();
        }
        match (self.find.current, self.find.matches.len()) {
            (_, 0) => "No results".into(),
            (Some(current), total) => format!("{} of {total}", current + 1),
            (None, total) => format!("{total} found"),
        }
    }

    fn is_text(&self, cx: &App) -> bool {
        self.with_document(cx, |document| *document.content() == DocumentContent::Text).unwrap_or(false)
    }

    // MARK: - Editing

    fn replace_selection(&mut self, text: &str, typing: bool, cx: &mut Context<Self>) {
        if !self.is_editable(cx) {
            return;
        }
        let range = self.marked.take().unwrap_or_else(|| self.selected_range());
        let inserted = self.edit_text(cx, |document| {
            Some(if typing { document.type_text(range, text) } else { document.replace(range, text) })
        });
        if let Some(inserted) = inserted {
            self.anchor = inserted.end;
            self.head = inserted.end;
            self.goal_column = None;
            self.autoscroll = true;
            cx.notify();
        }
    }

    fn newline(&mut self, _: &Newline, _: &mut Window, cx: &mut Context<Self>) {
        if !self.is_editable(cx) {
            return;
        }
        let selection = self.selected_range();
        let inserted = self.edit_text(cx, |document| {
            let start = document.clamp_offset(selection.start);
            Some(start..document.insert_newline(selection))
        });
        if let Some(caret) = inserted.map(|range| range.end) {
            self.anchor = caret;
            self.head = caret;
            self.goal_column = None;
            self.autoscroll = true;
            cx.notify();
        }
    }

    fn insert_tab(&mut self, _: &InsertTab, _: &mut Window, cx: &mut Context<Self>) {
        self.replace_selection("\t", true, cx);
    }

    /// Deletes the selection, or from the caret to where `target` (a motion over the text
    /// around the caret) leads.
    fn delete_to(&mut self, target: impl FnOnce(&str, usize) -> usize, cx: &mut Context<Self>) {
        let other = self.around(self.head, cx, target);
        self.delete_toward(other, cx);
    }

    /// Deletes the selection, or the text between the caret and `other`.
    fn delete_toward(&mut self, other: usize, cx: &mut Context<Self>) {
        if !self.is_editable(cx) {
            return;
        }
        let selection = self.selected_range();
        let range = if selection.is_empty() {
            self.head.min(other)..self.head.max(other)
        } else {
            selection
        };
        if range.is_empty() {
            return;
        }
        if let Some(inserted) = self.edit_text(cx, |document| Some(document.type_text(range, ""))) {
            self.anchor = inserted.start;
            self.head = inserted.start;
            self.goal_column = None;
            self.autoscroll = true;
            cx.notify();
        }
    }

    fn backspace(&mut self, _: &Backspace, _: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(previous_boundary, cx);
    }

    fn delete(&mut self, _: &Delete, _: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(next_boundary, cx);
    }

    fn delete_word_left(&mut self, _: &DeleteWordLeft, _: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(word_start, cx);
    }

    fn delete_word_right(&mut self, _: &DeleteWordRight, _: &mut Window, cx: &mut Context<Self>) {
        self.delete_to(word_end, cx);
    }

    fn delete_to_line_start(&mut self, _: &DeleteToLineStart, _: &mut Window, cx: &mut Context<Self>) {
        let start = self.line_start_of(self.head, cx);
        self.delete_toward(start, cx);
    }

    fn undo(&mut self, _: &Undo, _: &mut Window, cx: &mut Context<Self>) {
        if let Some(range) = self.edit_text(cx, EditorDocument::undo) {
            self.anchor = range.start;
            self.head = range.end;
            self.autoscroll = true;
            cx.notify();
        }
    }

    fn redo(&mut self, _: &Redo, _: &mut Window, cx: &mut Context<Self>) {
        if let Some(range) = self.edit_text(cx, EditorDocument::redo) {
            self.anchor = range.start;
            self.head = range.end;
            self.autoscroll = true;
            cx.notify();
        }
    }

    fn copy(&mut self, _: &Copy, _: &mut Window, cx: &mut Context<Self>) {
        let range = self.selected_range();
        if range.is_empty() {
            return;
        }
        if let Some(text) = self.with_document(cx, |document| document.rope().byte_slice(range).to_string()) {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn cut(&mut self, action: &Cut, window: &mut Window, cx: &mut Context<Self>) {
        let _ = action;
        if !self.is_editable(cx) || self.selected_range().is_empty() {
            return;
        }
        self.copy(&Copy, window, cx);
        self.replace_selection("", false, cx);
    }

    fn paste(&mut self, _: &Paste, _: &mut Window, cx: &mut Context<Self>) {
        if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
            self.replace_selection(&text, false, cx);
        }
    }

    fn select_all(&mut self, _: &SelectAll, _: &mut Window, cx: &mut Context<Self>) {
        let length = self.with_document(cx, EditorDocument::len).unwrap_or(0);
        self.anchor = 0;
        self.head = length;
        cx.notify();
    }

    // MARK: - Motion

    /// The text within [`MOTION_CONTEXT`] bytes of `offset` (on character boundaries) and
    /// where it starts: caret motion reads this rather than copying the whole document.
    fn text_around(&self, offset: usize, cx: &App) -> (usize, String) {
        self.with_document(cx, |document| {
            let start = document.clamp_offset(offset.saturating_sub(MOTION_CONTEXT));
            let end = document.clamp_offset(offset.saturating_add(MOTION_CONTEXT));
            (start, document.rope().byte_slice(start..end).to_string())
        })
        .unwrap_or_default()
    }

    /// `motion` (on text and an offset in it) applied to the text around `offset`.
    fn around(&self, offset: usize, cx: &App, motion: impl FnOnce(&str, usize) -> usize) -> usize {
        let (start, text) = self.text_around(offset, cx);
        start + motion(&text, offset - start)
    }

    fn line_start_of(&self, offset: usize, cx: &App) -> usize {
        self.with_document(cx, |document| {
            let rope = document.rope();
            rope.line_to_byte(rope.byte_to_line(offset.min(rope.len_bytes())))
        })
        .unwrap_or(0)
    }

    fn line_end_of(&self, offset: usize, cx: &App) -> usize {
        self.with_document(cx, |document| {
            let row = document.rope().byte_to_line(offset.min(document.len()));
            layout::line(document, row).0.end
        })
        .unwrap_or(0)
    }

    /// The offset `rows` lines up (negative) or down from `offset`, keeping the goal column.
    fn vertical(&mut self, offset: usize, rows: isize, cx: &App) -> usize {
        let Some((target, column)) = self.with_document(cx, |document| {
            let rope = document.rope();
            let row = rope.byte_to_line(offset.min(rope.len_bytes()));
            let (range, text) = layout::line(document, row);
            let line = DisplayLine::new(&text);
            let column = line.column_of(line.display_offset(offset - range.start));
            let target = row as isize + rows;
            if target < 0 {
                return (Err(0), column);
            }
            if target as usize >= rope.len_lines() {
                return (Err(rope.len_bytes()), column);
            }
            (Ok(target as usize), column)
        }) else {
            return offset;
        };
        let goal = *self.goal_column.get_or_insert(column);
        match target {
            Err(edge) => edge,
            Ok(row) => self
                .with_document(cx, |document| {
                    let (range, text) = layout::line(document, row);
                    let line = DisplayLine::new(&text);
                    range.start + line.buffer_offset(line.offset_of_column(goal))
                })
                .unwrap_or(offset),
        }
    }

    fn page_rows(&self) -> isize {
        self.layout.as_ref().map_or(20, |layout| layout.page_rows() as isize)
    }

    fn motion(
        &mut self,
        select: bool,
        target: impl FnOnce(&mut Self, &App) -> usize,
        cx: &mut Context<Self>,
    ) {
        let head = target(self, cx);
        self.head = head;
        if !select {
            self.anchor = head;
        }
        self.autoscroll = true;
        self.break_coalescing(cx);
        cx.notify();
    }

    fn horizontal(&mut self, select: bool, forward: bool, cx: &mut Context<Self>) {
        self.goal_column = None;
        let selection = self.selected_range();
        if !select && !selection.is_empty() {
            let edge = if forward { selection.end } else { selection.start };
            self.motion(false, |_, _| edge, cx);
            return;
        }
        self.motion(
            select,
            |this, cx| {
                let head = this.head;
                if forward {
                    this.around(head, cx, next_boundary)
                } else {
                    this.around(head, cx, previous_boundary)
                }
            },
            cx,
        );
    }

    fn word(&mut self, select: bool, forward: bool, cx: &mut Context<Self>) {
        self.goal_column = None;
        self.motion(
            select,
            |this, cx| {
                let head = this.head;
                if forward { this.around(head, cx, word_end) } else { this.around(head, cx, word_start) }
            },
            cx,
        );
    }

    fn line_edge(&mut self, select: bool, end: bool, cx: &mut Context<Self>) {
        self.goal_column = None;
        self.motion(
            select,
            |this, cx| if end { this.line_end_of(this.head, cx) } else { this.line_start_of(this.head, cx) },
            cx,
        );
    }

    fn document_edge(&mut self, select: bool, end: bool, cx: &mut Context<Self>) {
        self.goal_column = None;
        self.motion(
            select,
            |this, cx| if end { this.with_document(cx, EditorDocument::len).unwrap_or(0) } else { 0 },
            cx,
        );
    }

    fn rows(&mut self, select: bool, rows: isize, cx: &mut Context<Self>) {
        self.motion(select, |this, cx| this.vertical(this.head, rows, cx), cx);
    }

    // MARK: - Mouse

    fn mouse_down(&mut self, event: &MouseDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        cx.emit(EditorEvent::FocusRequested);
        self.focus.focus(window, cx);
        if self.scrollbar_down(event.position, cx) {
            return;
        }
        let Some(offset) = self.layout.as_ref().and_then(|layout| layout.offset_for_point(event.position))
        else {
            return;
        };
        self.goal_column = None;
        self.break_coalescing(cx);
        match event.click_count {
            2 => {
                let (start, text) = self.text_around(offset, cx);
                let local = word_range(&text, offset - start);
                let range = start + local.start..start + local.end;
                self.anchor = range.start;
                self.head = range.end;
            }
            3.. => {
                let start = self.line_start_of(offset, cx);
                let next = self
                    .with_document(cx, |document| {
                        let rope = document.rope();
                        let row = rope.byte_to_line(offset.min(rope.len_bytes()));
                        if row + 1 < rope.len_lines() { rope.line_to_byte(row + 1) } else { rope.len_bytes() }
                    })
                    .unwrap_or(offset);
                self.anchor = start;
                self.head = next;
            }
            _ if event.modifiers.shift => self.head = offset,
            _ => {
                self.anchor = offset;
                self.head = offset;
            }
        }
        self.selecting = true;
        cx.notify();
    }

    /// A press in the scroll bar's lane: on the thumb it starts dragging it, elsewhere in the
    /// track it pages toward the press. False when the press is not on the scroll bar.
    fn scrollbar_down(&mut self, position: Point<Pixels>, cx: &mut Context<Self>) -> bool {
        let Some(layout) = self.layout.as_ref() else { return false };
        let max = layout.max_scroll(self.widest_columns);
        let Some(bar) = layout.scrollbar(max.y).filter(|_| layout.in_scrollbar_lane(position)) else {
            return false;
        };
        let (scroll, y) = (f32::from(self.scroll.y), f32::from(position.y));
        if bar.thumb_contains(scroll, y) {
            self.thumb_grab = Some(y - bar.thumb_top(scroll));
        } else {
            self.scroll.y = px(bar.page_toward(scroll, y));
        }
        cx.notify();
        true
    }

    /// The pointer moved with the button down, anywhere in the window: drags the thumb, or
    /// extends the selection and scrolls while the pointer is past the text's edges.
    pub(crate) fn drag_move(&mut self, event: &MouseMoveEvent, _: &mut Window, cx: &mut Context<Self>) {
        if event.pressed_button != Some(MouseButton::Left) {
            return;
        }
        if let Some(grab) = self.thumb_grab {
            let Some(layout) = self.layout.as_ref() else { return };
            if let Some(bar) = layout.scrollbar(layout.max_scroll(self.widest_columns).y) {
                self.scroll.y = px(bar.scroll_for_thumb_top(f32::from(event.position.y) - grab));
                cx.notify();
            }
            return;
        }
        if !self.selecting {
            return;
        }
        self.drag_point = Some(event.position);
        if let Some(offset) = self.layout.as_ref().and_then(|layout| layout.offset_for_point(event.position))
        {
            self.head = offset;
            cx.notify();
        }
        if !self.drag_scrolling && self.edge_distance().is_some() {
            self.drag_scrolling = true;
            self.drag_scroll = Some(cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor().timer(DRAG_SCROLL_INTERVAL).await;
                    let keep = this.update(cx, |this, cx| this.drag_scroll_tick(cx)).unwrap_or(false);
                    if !keep {
                        break;
                    }
                }
            }));
        }
    }

    /// How far the pointer of a drag selection is past the text area's edges, if it is.
    fn edge_distance(&self) -> Option<Point<Pixels>> {
        let (layout, point) = (self.layout.as_ref()?, self.drag_point?);
        let area = layout.text_area();
        let dx = layout::edge_scroll(point.x.into(), area.left().into(), area.right().into());
        let dy = layout::edge_scroll(point.y.into(), area.top().into(), area.bottom().into());
        (dx != 0.0 || dy != 0.0).then(|| Point::new(px(dx), px(dy)))
    }

    /// One step of scrolling while a drag selection is past the edge: scrolls by the distance
    /// past it and extends the selection to the line now at that edge. False ends the loop.
    fn drag_scroll_tick(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(distance) = self.edge_distance().filter(|_| self.selecting) else {
            self.drag_scrolling = false;
            return false;
        };
        let Some(layout) = self.layout.as_ref() else { return false };
        let max = layout.max_scroll(self.widest_columns);
        self.scroll = Point::new(
            (self.scroll.x + distance.x).clamp(px(0.0), max.x),
            (self.scroll.y + distance.y).clamp(px(0.0), max.y),
        );
        if let Some(offset) = self.drag_point.and_then(|point| layout.offset_for_point(point)) {
            self.head = offset;
        }
        cx.notify();
        true
    }

    /// The button came up: drags end.
    pub(crate) fn drag_end(&mut self) {
        self.selecting = false;
        self.thumb_grab = None;
        self.drag_point = None;
        self.drag_scrolling = false;
        self.drag_scroll = None;
    }

    fn scroll_wheel(&mut self, event: &ScrollEvent, _: &mut Window, cx: &mut Context<Self>) {
        let Some(layout) = self.layout.as_ref() else { return };
        let delta = event.delta.pixel_delta(layout.line_height);
        let max = layout.max_scroll(self.widest_columns);
        let next = Point::new(
            (self.scroll.x - delta.x).clamp(px(0.0), max.x),
            (self.scroll.y - delta.y).clamp(px(0.0), max.y),
        );
        if next != self.scroll {
            self.scroll = next;
            cx.notify();
        }
    }

    // MARK: - Rendering helpers

    fn status(&self, cx: &App) -> Option<(String, StatusTone)> {
        self.with_document(cx, |document| document.status().map(|status| (status.text, status.tone)))
            .flatten()
    }

    fn image_element(&mut self, cx: &App) -> Option<Arc<Image>> {
        let (version, bytes, path) = self.with_document(cx, |document| {
            (
                document.text_version(),
                document.image_bytes().map(<[u8]>::to_vec),
                document.path().to_path_buf(),
            )
        })?;
        if let Some((cached, image)) = &self.image
            && *cached == version
        {
            return Some(image.clone());
        }
        let format = image_format(&path)?;
        let image = Arc::new(Image::from_bytes(format, bytes?));
        self.image = Some((version, image.clone()));
        Some(image)
    }
}

/// The image formats GPUI draws, by extension.
fn image_format(path: &std::path::Path) -> Option<ImageFormat> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match extension.as_str() {
        "png" => ImageFormat::Png,
        "jpg" | "jpeg" | "jpe" | "jfif" => ImageFormat::Jpeg,
        "gif" => ImageFormat::Gif,
        "webp" => ImageFormat::Webp,
        "bmp" => ImageFormat::Bmp,
        "tif" | "tiff" => ImageFormat::Tiff,
        "ico" => ImageFormat::Ico,
        "pbm" | "pgm" | "ppm" | "pnm" => ImageFormat::Pnm,
        _ => return None,
    })
}

impl<T: Clone + Eq + Hash + 'static> EntityInputHandler for EditorView<T> {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<String> {
        self.with_document(cx, |document| {
            let bytes = utf16_to_bytes(document, range);
            *adjusted = Some(bytes_to_utf16(document, bytes.clone()));
            document.rope().byte_slice(bytes).to_string()
        })
    }

    fn selected_text_range(
        &mut self,
        _ignore_disabled_input: bool,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        let selection = self.selected_range();
        let reversed = self.head < self.anchor;
        self.with_document(cx, |document| UTF16Selection {
            range: bytes_to_utf16(document, selection),
            reversed,
        })
    }

    fn marked_text_range(&self, _: &mut Window, cx: &mut Context<Self>) -> Option<Range<usize>> {
        let marked = self.marked.clone()?;
        self.with_document(cx, |document| bytes_to_utf16(document, marked))
    }

    /// The input method accepted the marked text as it is: one undo step for the word.
    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.marked = None;
        self.edit(cx, EditorDocument::commit_marked_text);
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(range) =
            range.and_then(|range| self.with_document(cx, |document| utf16_to_bytes(document, range)))
        {
            self.anchor = range.start;
            self.head = range.end;
            self.marked = None;
        }
        self.replace_selection(text, true, cx);
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        selected: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.is_editable(cx) {
            return;
        }
        let range = range
            .and_then(|range| self.with_document(cx, |document| utf16_to_bytes(document, range)))
            .or_else(|| self.marked.clone())
            .unwrap_or_else(|| self.selected_range());
        // Marked text is not recorded for undo; committing it records one step.
        let Some(inserted) = self.edit_text(cx, |document| Some(document.mark_text(range, text))) else {
            return;
        };
        self.marked = self.with_document(cx, EditorDocument::marked_range).flatten();
        let caret = match selected {
            Some(selected) => {
                let start = inserted.start + utf16_prefix_bytes(text, selected.start);
                let end = inserted.start + utf16_prefix_bytes(text, selected.end);
                start..end
            }
            None => inserted.end..inserted.end,
        };
        self.anchor = caret.start;
        self.head = caret.end;
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        _: gpui::Bounds<Pixels>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::Bounds<Pixels>> {
        let start = self.with_document(cx, |document| utf16_to_bytes(document, range).start)?;
        self.layout.as_ref()?.caret_bounds(start)
    }

    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<usize> {
        let offset = self.layout.as_ref()?.offset_for_point(point)?;
        self.with_document(cx, |document| bytes_to_utf16(document, offset..offset).start)
    }

    fn accepts_text_input(&self, _: &mut Window, cx: &mut Context<Self>) -> bool {
        self.is_editable(cx)
    }
}

fn utf16_to_bytes(document: &EditorDocument, range: Range<usize>) -> Range<usize> {
    let rope = document.rope();
    let convert = |utf16: usize| rope.char_to_byte(rope.utf16_cu_to_char(utf16.min(rope.len_utf16_cu())));
    convert(range.start)..convert(range.end)
}

fn bytes_to_utf16(document: &EditorDocument, range: Range<usize>) -> Range<usize> {
    let rope = document.rope();
    let convert = |byte: usize| rope.char_to_utf16_cu(rope.byte_to_char(byte.min(rope.len_bytes())));
    convert(range.start)..convert(range.end)
}

fn utf16_prefix_bytes(text: &str, utf16: usize) -> usize {
    let mut units = 0;
    for (offset, character) in text.char_indices() {
        if units >= utf16 {
            return offset;
        }
        units += character.len_utf16();
    }
    text.len()
}

impl<T: Clone + Eq + Hash + 'static> Render for EditorView<T> {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        let theme = cx.soprano_theme().clone();
        let z = |value: f32| theme.z(value);
        let Some((path, content, editable, shows_reload, shows_preview, disk_state)) =
            self.with_document(cx, |d| {
                (
                    d.path().to_path_buf(),
                    d.content().clone(),
                    d.is_editable(),
                    d.shows_reload(),
                    d.shows_markdown_preview(),
                    d.disk_state(),
                )
            })
        else {
            return div().size_full().into_any_element();
        };
        let _ = disk_state;
        let entity = cx.entity();
        let status = self.status(cx);
        let is_text = content == DocumentContent::Text;

        let mut toolbar = SurfaceToolbar::new().leading(breadcrumbs(&display_path(&path), cx));
        if let Some((text, tone)) = status {
            let color = match tone {
                StatusTone::Error => colors.error,
                StatusTone::Warning => colors.warning,
                StatusTone::Muted => colors.muted,
            };
            toolbar = toolbar.leading(
                div()
                    .flex_shrink_0()
                    .whitespace_nowrap()
                    .text_size(z(size::SMALL))
                    .text_color(color)
                    .child(text),
            );
        }
        if shows_reload {
            toolbar = toolbar.leading(
                Button::new("editor-reload", "Reload")
                    .variant(ButtonVariant::Secondary)
                    .size(ButtonSize::Xs)
                    .tooltip("Replace your unsaved changes with the version on disk")
                    .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
            );
        }
        if shows_preview {
            let preview = path.clone();
            toolbar = toolbar.trailing(toolbar_button(
                "editor-preview",
                IconName::Eye,
                "Open Markdown Preview",
                true,
                cx.listener(move |_, _, _, cx| cx.emit(EditorEvent::OpenMarkdownPreview(preview.clone()))),
            ));
        }
        toolbar = toolbar
            .trailing(toolbar_button(
                "editor-save",
                IconName::Save,
                "Save (⌘S)",
                editable,
                cx.listener(|this, _, window, cx| this.save(&Save, window, cx)),
            ))
            .trailing(toolbar_button(
                "editor-open-externally",
                IconName::ExternalLink,
                "Open with Default App",
                true,
                cx.listener(|this, _, _, cx| this.open_externally(cx)),
            ))
            .trailing(toolbar_button(
                "editor-reveal",
                IconName::Folder,
                soprano_platform::system::reveal_label(),
                true,
                cx.listener(|this, _, _, cx| this.reveal(cx)),
            ));

        let body = match &content {
            DocumentContent::Text => div()
                .id("editor-text")
                .relative()
                .flex_1()
                .min_h_0()
                .w_full()
                .cursor_text()
                .on_mouse_down(MouseButton::Left, cx.listener(Self::mouse_down))
                .on_scroll(cx.listener(Self::scroll_wheel))
                .child(EditorElement::new(entity))
                .when(self.find.visible, |body| body.child(self.render_find_bar(cx)))
                .into_any_element(),
            DocumentContent::Image { .. } => match self.image_element(cx) {
                Some(image) => div()
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .p(z(16.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(img(image).max_w_full().max_h_full().object_fit(ObjectFit::ScaleDown))
                    .into_any_element(),
                None => {
                    let name =
                        path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
                    self.unavailable(format!("“{name}” is an image Soprano can't show."), cx)
                }
            },
            DocumentContent::Unavailable(message) => self.unavailable(message.clone(), cx),
        };

        div()
            .id("soprano-editor")
            .key_context(if is_text { EDITOR_CONTEXT } else { "SopranoEditorSurface" })
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .bg(colors.background)
            .on_action(cx.listener(Self::save))
            .on_action(cx.listener(Self::find))
            .on_action(cx.listener(Self::find_next))
            .on_action(cx.listener(Self::find_previous))
            .on_action(cx.listener(Self::close_find))
            .on_action(cx.listener(Self::undo))
            .on_action(cx.listener(Self::redo))
            .on_action(cx.listener(Self::copy))
            .on_action(cx.listener(Self::cut))
            .on_action(cx.listener(Self::paste))
            .on_action(cx.listener(Self::select_all))
            .on_action(cx.listener(Self::newline))
            .on_action(cx.listener(Self::insert_tab))
            .on_action(cx.listener(Self::backspace))
            .on_action(cx.listener(Self::delete))
            .on_action(cx.listener(Self::delete_word_left))
            .on_action(cx.listener(Self::delete_word_right))
            .on_action(cx.listener(Self::delete_to_line_start))
            .on_action(cx.listener(|this, _: &MoveLeft, _, cx| this.horizontal(false, false, cx)))
            .on_action(cx.listener(|this, _: &MoveRight, _, cx| this.horizontal(false, true, cx)))
            .on_action(cx.listener(|this, _: &SelectLeft, _, cx| this.horizontal(true, false, cx)))
            .on_action(cx.listener(|this, _: &SelectRight, _, cx| this.horizontal(true, true, cx)))
            .on_action(cx.listener(|this, _: &MoveUp, _, cx| this.rows(false, -1, cx)))
            .on_action(cx.listener(|this, _: &MoveDown, _, cx| this.rows(false, 1, cx)))
            .on_action(cx.listener(|this, _: &SelectUp, _, cx| this.rows(true, -1, cx)))
            .on_action(cx.listener(|this, _: &SelectDown, _, cx| this.rows(true, 1, cx)))
            .on_action(cx.listener(|this, _: &MovePageUp, _, cx| this.rows(false, -this.page_rows(), cx)))
            .on_action(cx.listener(|this, _: &MovePageDown, _, cx| this.rows(false, this.page_rows(), cx)))
            .on_action(cx.listener(|this, _: &SelectPageUp, _, cx| this.rows(true, -this.page_rows(), cx)))
            .on_action(cx.listener(|this, _: &SelectPageDown, _, cx| this.rows(true, this.page_rows(), cx)))
            .on_action(cx.listener(|this, _: &MoveWordLeft, _, cx| this.word(false, false, cx)))
            .on_action(cx.listener(|this, _: &MoveWordRight, _, cx| this.word(false, true, cx)))
            .on_action(cx.listener(|this, _: &SelectWordLeft, _, cx| this.word(true, false, cx)))
            .on_action(cx.listener(|this, _: &SelectWordRight, _, cx| this.word(true, true, cx)))
            .on_action(cx.listener(|this, _: &MoveLineStart, _, cx| this.line_edge(false, false, cx)))
            .on_action(cx.listener(|this, _: &MoveLineEnd, _, cx| this.line_edge(false, true, cx)))
            .on_action(cx.listener(|this, _: &SelectLineStart, _, cx| this.line_edge(true, false, cx)))
            .on_action(cx.listener(|this, _: &SelectLineEnd, _, cx| this.line_edge(true, true, cx)))
            .on_action(cx.listener(|this, _: &MoveDocumentStart, _, cx| this.document_edge(false, false, cx)))
            .on_action(cx.listener(|this, _: &MoveDocumentEnd, _, cx| this.document_edge(false, true, cx)))
            .on_action(
                cx.listener(|this, _: &SelectDocumentStart, _, cx| this.document_edge(true, false, cx)),
            )
            .on_action(cx.listener(|this, _: &SelectDocumentEnd, _, cx| this.document_edge(true, true, cx)))
            .child(toolbar)
            .child(body)
            .when_some(self.dialog.clone(), |root, dialog| {
                let viewport = window.viewport_size();
                root.child(deferred(
                    anchored()
                        .position(Point::default())
                        .child(div().w(viewport.width).h(viewport.height).relative().child(dialog)),
                ))
            })
            .into_any_element()
    }
}

impl<T: Clone + Eq + Hash + 'static> EditorView<T> {
    fn unavailable(&self, message: String, cx: &mut Context<Self>) -> gpui::AnyElement {
        div()
            .flex_1()
            .min_h_0()
            .w_full()
            .child(
                SurfaceMessage::new(message)
                    .button("Open with Default App", cx.listener(|this, _, _, cx| this.open_externally(cx))),
            )
            .into_any_element()
    }

    /// Herdr's find bar: top right, h 38, popover, the field, the count, ↑ ↓ ×.
    fn render_find_bar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        let z = |value: f32| theme.z(value);
        let label = self.match_label(cx);
        div()
            .absolute()
            .top(z(6.5))
            .right(z(6.5))
            .h(z(38.0))
            .max_w(z(460.0))
            .w(z(360.0))
            .px(z(3.25))
            .gap(z(3.25))
            .flex()
            .flex_row()
            .items_center()
            .rounded(z(4.9))
            .border_1()
            .border_color(theme.border)
            .bg(theme.popover)
            .shadow_md()
            .key_context(FIND_CONTEXT)
            .on_action(cx.listener(Self::close_find))
            .on_action(cx.listener(Self::find_next))
            .on_action(cx.listener(Self::find_previous))
            .on_action(cx.listener(Self::save))
            .child(div().flex_1().min_w_0().child(TextInput::new(&self.find.input).small()))
            .child(
                div()
                    .flex_shrink_0()
                    .w(z(58.0))
                    .text_size(z(9.75))
                    .text_color(theme.muted)
                    .whitespace_nowrap()
                    .child(label),
            )
            .child(toolbar_button(
                "find-previous",
                IconName::ChevronUp,
                "Previous Match (⇧⌘G)",
                true,
                cx.listener(|this, _, window, cx| this.find_previous(&FindPrevious, window, cx)),
            ))
            .child(toolbar_button(
                "find-next",
                IconName::ChevronDown,
                "Next Match (⌘G)",
                true,
                cx.listener(|this, _, window, cx| this.find_next(&FindNext, window, cx)),
            ))
            .child(toolbar_button(
                "find-close",
                IconName::X,
                "Done",
                true,
                cx.listener(|this, _, window, cx| this.close_find(&CloseFind, window, cx)),
            ))
    }
}

#[cfg(test)]
mod tests;
