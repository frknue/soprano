//! One file open in the editor (port of `EditorDocument.swift` and the document logic of
//! `EditorPaneView.swift`).
//!
//! Every editor tab showing the file shares one [`EditorDocument`]: one text buffer (each
//! view lays it out itself), one undo history, one saved state. Offsets are UTF-8 byte
//! offsets into the buffer. The document never calls back into the UI: changes are queued
//! as [`DocumentChange`]s for the views to drain with [`EditorDocument::take_changes`].

use std::fs;
use std::io;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use ropey::Rope;

use crate::find;
use crate::syntax::{self, CodeLanguage, SyntaxToken};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DocumentContent {
    Text,
    /// Shown, not edited; the bytes are [`EditorDocument::image_bytes`].
    Image {
        width: u32,
        height: u32,
    },
    /// Opened but not editable as text, with the reason.
    Unavailable(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiskState {
    InSync,
    /// Another program changed the file while there were unsaved edits.
    Changed,
    Deleted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentChange {
    /// The text or image is about to be replaced from disk: views note their selection and
    /// scroll position (restored with [`restore_selection`]).
    WillReplaceContent,
    Content,
    /// Dirty, disk, or read-only state changed.
    State,
    Highlights,
    /// The file was renamed or moved: re-watch it.
    Location,
    /// The text was edited in some view.
    Edited,
}

/// The toolbar's status label.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorStatus {
    pub text: String,
    pub tone: StatusTone,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusTone {
    /// `errorForeground`.
    Error,
    /// `warningForeground`.
    Warning,
    /// `mutedForeground`.
    Muted,
}

/// Larger files open with a note instead of their text.
pub const MAXIMUM_TEXT_BYTES: u64 = 8 * 1024 * 1024;
/// Images are shown, not edited, so they may be larger.
pub const MAXIMUM_IMAGE_BYTES: u64 = 64 * 1024 * 1024;
/// Larger texts (in UTF-16 code units, as the Swift app measured) stay uncolored;
/// re-highlighting them on every pause in typing would cost more than it is worth.
pub const MAXIMUM_HIGHLIGHTED_LENGTH: usize = 1_500_000;
/// The pause in typing before the text is highlighted again.
pub const HIGHLIGHT_DELAY_MS: u64 = 120;
/// The debounce of the watcher on the file's folder.
pub const WATCH_DEBOUNCE_MS: u64 = 150;
/// Height of one code line (SF Mono 13 on a 20 pt line).
pub const LINE_HEIGHT: f32 = 20.0;
/// Padding either side of the line-number gutter's numbers.
pub const GUTTER_PADDING: f32 = 10.0;

/// Width of a line-number column for numbers up to `largest` (two digits at least):
/// `ceil(digits × digit_width) + 2 × 10`. The editor's gutter passes its line count, the
/// diff views their largest line number.
pub fn number_column_width(largest: usize, digit_width: f32) -> f32 {
    let digits = largest.max(1).to_string().len().max(2);
    (digits as f32 * digit_width).ceil() + GUTTER_PADDING * 2.0
}

/// What is on disk, without reading it: comparing these costs one stat call, while the
/// watcher fires for every write in the file's folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DiskSignature {
    size: u64,
    modified: Option<SystemTime>,
    inode: u64,
}

impl DiskSignature {
    fn of(path: &Path) -> io::Result<Self> {
        let metadata = fs::metadata(path)?;
        Ok(Self { size: metadata.len(), modified: metadata.modified().ok(), inode: inode(&metadata) })
    }
}

#[cfg(unix)]
fn inode(metadata: &fs::Metadata) -> u64 {
    std::os::unix::fs::MetadataExt::ino(metadata)
}

#[cfg(not(unix))]
fn inode(_metadata: &fs::Metadata) -> u64 {
    0
}

enum DiskRead {
    Data(Vec<u8>),
    TooLarge(u64),
    Missing,
    Failed(io::Error),
}

/// One undoable edit: `removed` was replaced by `inserted` at `start`.
#[derive(Clone, Debug)]
struct Edit {
    start: usize,
    removed: String,
    inserted: String,
}

#[derive(Default)]
struct UndoHistory {
    undo: Vec<Vec<Edit>>,
    redo: Vec<Vec<Edit>>,
    /// The last group is typing that the next adjacent keystroke may join.
    typing_open: bool,
    /// An input method's marked text, not yet recorded.
    composition: Option<Composition>,
}

/// What an input method has changed so far: `region` of the current text replaced
/// `original` of the text before composing began.
struct Composition {
    region: Range<usize>,
    original: String,
}

/// A text to highlight off the main thread: hand `text` to [`syntax::tokens`] and the
/// result back to [`EditorDocument::apply_highlights`] with the same `version`.
pub struct HighlightRequest {
    pub version: u64,
    pub text: String,
    pub language: &'static CodeLanguage,
}

pub struct EditorDocument {
    path: PathBuf,
    buffer: Rope,
    saved: Rope,
    content: DocumentContent,
    is_dirty: bool,
    disk_state: DiskState,
    is_read_only: bool,
    language: Option<&'static CodeLanguage>,
    tokens: Vec<SyntaxToken>,
    /// The bytes last read from or written to the file, to tell another program's change
    /// from our own save.
    disk_data: Option<Vec<u8>>,
    disk_signature: Option<DiskSignature>,
    text_version: u64,
    history: UndoHistory,
    changes: Vec<DocumentChange>,
}

impl EditorDocument {
    /// Opens `path` (made absolute and normalized, like `standardizedFileURL`).
    pub fn open(path: impl AsRef<Path>) -> Self {
        let path = standardized(path.as_ref());
        let language = file_name(&path).and_then(CodeLanguage::for_file);
        let mut document = Self {
            path,
            buffer: Rope::new(),
            saved: Rope::new(),
            content: DocumentContent::Text,
            is_dirty: false,
            disk_state: DiskState::InSync,
            is_read_only: false,
            language,
            tokens: Vec::new(),
            disk_data: None,
            disk_signature: None,
            text_version: 0,
            history: UndoHistory::default(),
            changes: Vec::new(),
        };
        document.load();
        document
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The file name, as tab titles and dialogs show it.
    pub fn name(&self) -> String {
        file_name(&self.path).unwrap_or_default().to_string()
    }

    pub fn content(&self) -> &DocumentContent {
        &self.content
    }

    pub fn is_dirty(&self) -> bool {
        self.is_dirty
    }

    pub fn disk_state(&self) -> DiskState {
        self.disk_state
    }

    pub fn is_read_only(&self) -> bool {
        self.is_read_only
    }

    pub fn language(&self) -> Option<&'static CodeLanguage> {
        self.language
    }

    /// The syntax tokens of the current text (empty while stale or uncolored).
    pub fn tokens(&self) -> &[SyntaxToken] {
        &self.tokens
    }

    /// The image's file bytes, for an image document.
    pub fn image_bytes(&self) -> Option<&[u8]> {
        matches!(self.content, DocumentContent::Image { .. }).then_some(self.disk_data.as_deref()).flatten()
    }

    pub fn rope(&self) -> &Rope {
        &self.buffer
    }

    pub fn text(&self) -> String {
        self.buffer.to_string()
    }

    /// Length of the text in bytes.
    pub fn len(&self) -> usize {
        self.buffer.len_bytes()
    }

    pub fn is_empty(&self) -> bool {
        self.buffer.len_bytes() == 0
    }

    /// Bumped by every change of the text.
    pub fn text_version(&self) -> u64 {
        self.text_version
    }

    /// The changes since the last call, oldest first.
    pub fn take_changes(&mut self) -> Vec<DocumentChange> {
        std::mem::take(&mut self.changes)
    }

    /// The tab title: the file name, with ● while it has unsaved changes.
    pub fn tab_title(&self) -> String {
        if self.is_dirty { format!("{} ●", self.name()) } else { self.name() }
    }

    /// Text that is neither read-only nor unavailable can be edited and saved.
    pub fn is_editable(&self) -> bool {
        self.content == DocumentContent::Text && !self.is_read_only
    }

    /// The Reload button shows while the file changed on disk under unsaved edits.
    pub fn shows_reload(&self) -> bool {
        self.disk_state == DiskState::Changed
    }

    /// The Markdown preview button shows for `.md` and `.markdown` files.
    pub fn shows_markdown_preview(&self) -> bool {
        self.path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| matches!(extension.to_lowercase().as_str(), "md" | "markdown"))
    }

    /// The toolbar's status label, if any.
    pub fn status(&self) -> Option<EditorStatus> {
        let status = |text: String, tone| Some(EditorStatus { text, tone });
        match (self.disk_state, &self.content) {
            (DiskState::Changed, _) => status("Changed on disk".into(), StatusTone::Error),
            (DiskState::Deleted, _) => status("Deleted on disk".into(), StatusTone::Error),
            (_, DocumentContent::Image { width, height }) => {
                status(format!("{width} × {height}"), StatusTone::Muted)
            }
            (_, DocumentContent::Unavailable(_)) => None,
            _ if self.is_read_only => status("Read only".into(), StatusTone::Muted),
            _ if self.is_dirty => status("Modified".into(), StatusTone::Warning),
            _ => None,
        }
    }

    // MARK: - Loading

    /// Reads the file, unless it is larger than anything the editor shows: a click previews
    /// any file, and a multi-gigabyte video must not be read into memory just to say it is
    /// too large.
    fn read_disk(&self) -> (DiskRead, Option<DiskSignature>) {
        let signature = match DiskSignature::of(&self.path) {
            Ok(signature) => signature,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return (DiskRead::Missing, None),
            Err(error) => return (DiskRead::Failed(error), None),
        };
        let limit = if is_image_file(&self.path) { MAXIMUM_IMAGE_BYTES } else { MAXIMUM_TEXT_BYTES };
        if signature.size > limit {
            return (DiskRead::TooLarge(signature.size), Some(signature));
        }
        match fs::read(&self.path) {
            Ok(data) => (DiskRead::Data(data), Some(signature)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (DiskRead::Missing, None),
            Err(error) => (DiskRead::Failed(error), Some(signature)),
        }
    }

    fn load(&mut self) {
        let (read, signature) = self.read_disk();
        self.disk_signature = signature;
        match read {
            DiskRead::Data(data) => self.apply(data),
            DiskRead::TooLarge(size) => {
                self.disk_data = None;
                self.content = DocumentContent::Unavailable(format!(
                    "“{}” is {}, too large to open in Soprano.",
                    self.name(),
                    format_file_size(size)
                ));
                self.replace_text("");
            }
            DiskRead::Missing => {
                // Deleted since its tab was saved: an empty buffer that saving writes back.
                self.disk_data = None;
                self.content = DocumentContent::Text;
                self.replace_text("");
                self.saved = Rope::new();
                self.disk_state = DiskState::Deleted;
            }
            DiskRead::Failed(error) => {
                self.disk_data = None;
                self.content =
                    DocumentContent::Unavailable(format!("Soprano couldn't read “{}”: {error}", self.name()));
                self.replace_text("");
            }
        }
    }

    fn apply(&mut self, data: Vec<u8>) {
        if is_image_file(&self.path)
            && let Ok(size) = imagesize::blob_size(&data)
        {
            self.disk_data = Some(data);
            self.content = DocumentContent::Image { width: size.width as u32, height: size.height as u32 };
            self.replace_text("");
            return;
        }
        let binary = data[..data.len().min(8192)].contains(&0);
        let text = if binary { None } else { std::str::from_utf8(&data).ok().map(Rope::from_str) };
        self.disk_data = Some(data);
        let Some(text) = text else {
            self.content =
                DocumentContent::Unavailable(format!("“{}” isn't a UTF-8 text file.", self.name()));
            self.replace_text("");
            return;
        };
        self.content = DocumentContent::Text;
        self.replace_buffer(text);
        self.saved = self.buffer.clone();
        self.is_read_only = !is_writable(&self.path);
    }

    fn replace_text(&mut self, text: &str) {
        self.replace_buffer(Rope::from_str(text));
    }

    fn replace_buffer(&mut self, buffer: Rope) {
        self.buffer = buffer;
        self.text_version += 1;
        self.history = UndoHistory::default();
        self.invalidate_highlights();
    }

    // MARK: - Editing

    /// Replaces `range` (byte offsets, clamped to the text and to character boundaries) with
    /// `text` as one undo step. Returns the inserted text's range.
    pub fn replace(&mut self, range: Range<usize>, text: &str) -> Range<usize> {
        self.commit_marked_text();
        self.history.typing_open = false;
        self.edit(range, text, false)
    }

    /// Typing: like [`replace`](Self::replace), but keystrokes that continue where the last
    /// one ended join its undo step, as a text view coalesces typing. Typing inside an input
    /// method's marked text commits the composition with it (one undo step).
    pub fn type_text(&mut self, range: Range<usize>, text: &str) -> Range<usize> {
        if let Some(composition) = &self.history.composition {
            let region = composition.region.clone();
            if range.start >= region.start && range.end <= region.end {
                let inserted = self.mark_text(range, text);
                self.commit_marked_text();
                return inserted;
            }
            self.commit_marked_text();
        }
        self.edit(range, text, true)
    }

    /// An input method's marked (composing) text replaces `range`: applied to the text, but
    /// not recorded for undo until [`commit_marked_text`](Self::commit_marked_text), so a
    /// committed word is one "Undo Typing" step, never its half-typed stages. Returns the
    /// marked text's range.
    pub fn mark_text(&mut self, range: Range<usize>, text: &str) -> Range<usize> {
        let start = self.clamp_offset(range.start);
        let end = self.clamp_offset(range.end).max(start);
        let mut composition = self
            .history
            .composition
            .take()
            .unwrap_or(Composition { region: start..start, original: String::new() });
        // The composition covers everything it has replaced, in the text before it began.
        if start < composition.region.start {
            let before = self.buffer.byte_slice(start..composition.region.start).to_string();
            composition.original.insert_str(0, &before);
            composition.region.start = start;
        }
        if end > composition.region.end {
            composition.original.push_str(&self.buffer.byte_slice(composition.region.end..end).to_string());
            composition.region.end = end;
        }
        composition.region.end = composition.region.end - (end - start) + text.len();
        self.history.composition = Some(composition);
        if start < end || !text.is_empty() {
            self.splice(start, end, text);
            self.history.redo.clear();
            self.did_edit();
        }
        start..start + text.len()
    }

    /// Ends the composition (the input method unmarked its text): records what it changed
    /// as one typing step, or nothing when it changed nothing (a cancelled composition).
    pub fn commit_marked_text(&mut self) {
        let Some(composition) = self.history.composition.take() else { return };
        let inserted = self.buffer.byte_slice(composition.region.clone()).to_string();
        if inserted == composition.original {
            return;
        }
        let edit = Edit { start: composition.region.start, removed: composition.original, inserted };
        self.record(edit, true);
    }

    /// The range of the uncommitted composition, if an input method is composing.
    pub fn marked_range(&self) -> Option<Range<usize>> {
        self.history.composition.as_ref().map(|composition| composition.region.clone())
    }

    /// Ends the current typing undo step (the caret moved, the view lost focus).
    pub fn break_undo_coalescing(&mut self) {
        self.history.typing_open = false;
    }

    /// Return: a line break that keeps the current line's indentation (its leading spaces
    /// and tabs up to the caret), replacing `selection`. Returns the caret after it.
    pub fn insert_newline(&mut self, selection: Range<usize>) -> usize {
        let caret = self.clamp_offset(selection.start);
        let line_start = self.buffer.line_to_byte(self.buffer.byte_to_line(caret));
        let indentation: String = self
            .buffer
            .byte_slice(line_start..caret)
            .chars()
            .take_while(|c| *c == ' ' || *c == '\t')
            .collect();
        self.type_text(selection, &format!("\n{indentation}")).end
    }

    fn edit(&mut self, range: Range<usize>, text: &str, typing: bool) -> Range<usize> {
        let start = self.clamp_offset(range.start);
        let end = self.clamp_offset(range.end).max(start);
        let removed = self.buffer.byte_slice(start..end).to_string();
        if removed.is_empty() && text.is_empty() {
            return start..start;
        }
        self.splice(start, end, text);
        self.record(Edit { start, removed, inserted: text.to_string() }, typing);
        self.did_edit();
        start..start + text.len()
    }

    /// Adds an applied edit to the undo history.
    fn record(&mut self, edit: Edit, typing: bool) {
        self.history.redo.clear();
        let (start, end) = (edit.start, edit.start + edit.removed.len());
        // Keystrokes join the typing step while they continue at its caret: typing on,
        // backspacing from it, or deleting forward from it, as a text view groups typing.
        let joins = typing
            && self.history.typing_open
            && self.history.undo.last().and_then(|group| group.last()).is_some_and(|last| {
                let caret = last.start + last.inserted.len();
                (start == caret && edit.removed.is_empty())
                    || (edit.inserted.is_empty() && (end == caret || start == caret))
            });
        if joins && let Some(group) = self.history.undo.last_mut() {
            group.push(edit);
        } else {
            self.history.undo.push(vec![edit]);
        }
        self.history.typing_open = typing;
    }

    pub fn can_undo(&self) -> bool {
        !self.history.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.history.redo.is_empty()
    }

    /// Undoes the last step; returns the range to select (the text the step had replaced).
    pub fn undo(&mut self) -> Option<Range<usize>> {
        self.commit_marked_text();
        let group = self.history.undo.pop()?;
        self.history.typing_open = false;
        let mut selection: Option<Range<usize>> = None;
        for edit in group.iter().rev() {
            self.splice(edit.start, edit.start + edit.inserted.len(), &edit.removed);
            let restored = edit.start..edit.start + edit.removed.len();
            selection = Some(match selection {
                None => restored,
                // The later edits' restored text, moved by this one, joined with its own.
                Some(range) => {
                    let end = if range.end > edit.start {
                        range.end - edit.inserted.len() + edit.removed.len()
                    } else {
                        range.end
                    };
                    range.start.min(restored.start)..end.max(restored.end)
                }
            });
        }
        self.history.redo.push(group);
        self.did_edit();
        selection
    }

    /// Redoes the last undone step; returns the range to select (the text it inserted).
    pub fn redo(&mut self) -> Option<Range<usize>> {
        self.commit_marked_text();
        let group = self.history.redo.pop()?;
        self.history.typing_open = false;
        let mut selection: Option<Range<usize>> = None;
        for edit in &group {
            self.splice(edit.start, edit.start + edit.removed.len(), &edit.inserted);
            let inserted = edit.start..edit.start + edit.inserted.len();
            selection = Some(match selection {
                None => inserted,
                // The earlier edits' text, moved by this one, joined with its own.
                Some(range) => {
                    let end = if range.end > edit.start {
                        range.end.saturating_sub(edit.removed.len()).max(edit.start) + edit.inserted.len()
                    } else {
                        range.end
                    };
                    range.start.min(inserted.start)..end.max(inserted.end)
                }
            });
        }
        self.history.undo.push(group);
        self.did_edit();
        selection
    }

    fn splice(&mut self, start: usize, end: usize, text: &str) {
        let char_start = self.buffer.byte_to_char(start);
        let char_end = self.buffer.byte_to_char(end);
        self.buffer.remove(char_start..char_end);
        self.buffer.insert(char_start, text);
    }

    /// `offset` within the text, moved back to a character boundary: what every offset a
    /// view keeps across edits made elsewhere (another tab, a reload) must go through before
    /// slicing the rope.
    pub fn clamp_offset(&self, offset: usize) -> usize {
        floor_char_boundary(&self.buffer, offset)
    }

    fn did_edit(&mut self) {
        self.text_version += 1;
        let was_dirty = self.is_dirty;
        self.is_dirty = self.buffer != self.saved;
        if was_dirty != self.is_dirty {
            self.changes.push(DocumentChange::State);
        }
        self.changes.push(DocumentChange::Edited);
        if !self.tokens.is_empty() && !self.highlightable() {
            self.tokens.clear();
            self.changes.push(DocumentChange::Highlights);
        }
    }

    /// 1-based line containing the byte offset `offset`.
    pub fn line_number(&self, offset: usize) -> usize {
        self.buffer.byte_to_line(offset.min(self.buffer.len_bytes())) + 1
    }

    /// Lines, counting the empty line after a trailing newline.
    pub fn line_count(&self) -> usize {
        self.buffer.len_lines()
    }

    // MARK: - Find

    pub fn find_all(&self, query: &str) -> Vec<Range<usize>> {
        find::find_all(&self.text(), query)
    }

    /// ⌘G: the next match at or after `from`, wrapping.
    pub fn find_next(&self, query: &str, from: usize) -> Option<Range<usize>> {
        find::find_next(&self.text(), query, from)
    }

    /// ⇧⌘G: the previous match ending at or before `before`, wrapping.
    pub fn find_previous(&self, query: &str, before: usize) -> Option<Range<usize>> {
        find::find_previous(&self.text(), query, before)
    }

    // MARK: - Highlighting

    fn highlightable(&self) -> bool {
        self.content == DocumentContent::Text
            && self.language.is_some()
            && self.buffer.len_utf16_cu() <= MAXIMUM_HIGHLIGHTED_LENGTH
    }

    /// The text to highlight now, or `None` when it stays uncolored (not text, no language,
    /// too long) — then the tokens are already cleared. Views call this right after a load
    /// or relocation and [`HIGHLIGHT_DELAY_MS`] after the last edit.
    pub fn highlight_request(&mut self) -> Option<HighlightRequest> {
        if !self.highlightable() {
            if !self.tokens.is_empty() {
                self.tokens.clear();
                self.changes.push(DocumentChange::Highlights);
            }
            return None;
        }
        Some(HighlightRequest { version: self.text_version, text: self.text(), language: self.language? })
    }

    /// Takes the tokens computed for `version`; false (and ignored) when the text changed since.
    pub fn apply_highlights(&mut self, version: u64, tokens: Vec<SyntaxToken>) -> bool {
        if version != self.text_version || !self.highlightable() {
            return false;
        }
        self.tokens = tokens;
        self.changes.push(DocumentChange::Highlights);
        true
    }

    /// Highlights on the calling thread (small texts, tests).
    pub fn highlight_now(&mut self) {
        if let Some(request) = self.highlight_request() {
            let tokens = syntax::tokens(&request.text, request.language);
            self.apply_highlights(request.version, tokens);
        }
    }

    fn invalidate_highlights(&mut self) {
        if !self.tokens.is_empty() {
            self.tokens.clear();
            self.changes.push(DocumentChange::Highlights);
        }
    }

    // MARK: - Saving

    /// Writes the text to disk, keeping the file's permissions; a symlink keeps pointing at
    /// the file it names. Only text is written.
    pub fn save(&mut self) -> io::Result<()> {
        if self.content != DocumentContent::Text {
            return Ok(());
        }
        let text = self.text();
        let target = fs::canonicalize(&self.path).unwrap_or_else(|_| self.path.clone());
        let permissions = fs::metadata(&target).ok().map(|metadata| metadata.permissions());
        soprano_platform::state::write_atomically(&target, text.as_bytes())?;
        if let Some(permissions) = permissions {
            let _ = fs::set_permissions(&target, permissions);
        }
        self.disk_data = Some(text.into_bytes());
        self.disk_signature = DiskSignature::of(&self.path).ok();
        self.saved = self.buffer.clone();
        self.is_dirty = false;
        self.disk_state = DiskState::InSync;
        self.is_read_only = false;
        self.changes.push(DocumentChange::State);
        Ok(())
    }

    /// Whether another program wrote a different version since the file was last read or
    /// saved here. A deleted file has nothing to overwrite.
    pub fn disk_changed_since_last_sync(&self) -> bool {
        let Ok(signature) = DiskSignature::of(&self.path) else { return false };
        // The watcher already saw a different version and kept the edits.
        if self.disk_state == DiskState::Changed {
            return true;
        }
        if Some(signature) == self.disk_signature {
            return false;
        }
        // A different size is a different file; only an equal size needs the bytes.
        match (&self.disk_data, fs::read(&self.path)) {
            (Some(data), Ok(current)) if data.len() as u64 == signature.size => current != *data,
            _ => true,
        }
    }

    // MARK: - Disk Changes

    /// The watcher saw a change in the file's folder. A clean buffer follows the file; one
    /// with unsaved edits keeps them and is marked "Changed on disk".
    pub fn disk_did_change(&mut self) {
        // Another file in the same folder changed: nothing to read.
        if DiskSignature::of(&self.path).ok() == self.disk_signature {
            return;
        }
        let (read, signature) = self.read_disk();
        self.disk_signature = signature;
        match read {
            DiskRead::Missing => {
                if self.disk_state != DiskState::Deleted {
                    self.disk_state = DiskState::Deleted;
                    self.changes.push(DocumentChange::State);
                }
            }
            DiskRead::Failed(_) => {}
            DiskRead::Data(data) if Some(&data) == self.disk_data.as_ref() => {
                // Touched, or written back unchanged.
                if self.disk_state != DiskState::InSync {
                    self.disk_state = DiskState::InSync;
                    self.changes.push(DocumentChange::State);
                }
            }
            DiskRead::Data(_) | DiskRead::TooLarge(_) => {
                if self.is_dirty {
                    self.disk_state = DiskState::Changed;
                    self.changes.push(DocumentChange::State);
                } else {
                    self.reload_content();
                }
            }
        }
    }

    /// Replaces the buffer, unsaved edits included, with the file on disk.
    pub fn reload_from_disk(&mut self) {
        if DiskSignature::of(&self.path).is_err() {
            self.disk_state = DiskState::Deleted;
            self.changes.push(DocumentChange::State);
            return;
        }
        self.reload_content();
    }

    fn reload_content(&mut self) {
        self.changes.push(DocumentChange::WillReplaceContent);
        self.disk_state = DiskState::InSync;
        self.is_dirty = false;
        self.load();
        self.changes.push(DocumentChange::Content);
        self.changes.push(DocumentChange::State);
    }

    /// Drops unsaved edits ("Don't Save").
    pub fn discard_changes(&mut self) {
        if !self.is_dirty {
            return;
        }
        if self.path.exists() {
            self.reload_from_disk();
        } else {
            self.saved = self.buffer.clone();
            self.is_dirty = false;
            self.changes.push(DocumentChange::State);
        }
    }

    /// Follows a rename or move made in the explorer.
    pub fn relocate(&mut self, new_path: impl AsRef<Path>) {
        self.path = standardized(new_path.as_ref());
        self.language = file_name(&self.path).and_then(CodeLanguage::for_file);
        self.invalidate_highlights();
        self.changes.push(DocumentChange::Location);
    }
}

/// A view's selection after its document reloaded: each range kept inside the new text and
/// moved back to character boundaries (an old offset can fall inside a multi-byte
/// character of the new text), or a caret at the start when there was none.
pub fn restore_selection(selection: &[Range<usize>], text: &Rope) -> Vec<Range<usize>> {
    if selection.is_empty() {
        return vec![Range::default()];
    }
    selection
        .iter()
        .map(|range| {
            let start = floor_char_boundary(text, range.start);
            start..floor_char_boundary(text, range.end).max(start)
        })
        .collect()
}

fn floor_char_boundary(text: &Rope, offset: usize) -> usize {
    let offset = offset.min(text.len_bytes());
    text.char_to_byte(text.byte_to_char(offset))
}

/// `ByteCountFormatter` with the file count style (decimal units): "1 byte", "999 bytes",
/// "12 KB", "8.4 MB", "1.25 GB".
pub fn format_file_size(bytes: u64) -> String {
    match bytes {
        0 => "Zero KB".into(),
        1 => "1 byte".into(),
        2..1_000 => format!("{bytes} bytes"),
        1_000..1_000_000 => format!("{} KB", (bytes as f64 / 1e3).round()),
        _ => {
            let (value, unit, digits) = [(1e15, "PB", 2), (1e12, "TB", 2), (1e9, "GB", 2), (1e6, "MB", 1)]
                .into_iter()
                .find(|(scale, ..)| bytes as f64 >= *scale)
                .map(|(scale, unit, digits)| (bytes as f64 / scale, unit, digits))
                .unwrap_or((bytes as f64 / 1e6, "MB", 1));
            let text = format!("{value:.digits$}");
            let text =
                if text.contains('.') { text.trim_end_matches('0').trim_end_matches('.') } else { &text };
            format!("{text} {unit}")
        }
    }
}

/// An image the editor shows rather than edits, by extension. SVG is an image to the
/// system but text people edit.
pub fn is_image_file(path: &Path) -> bool {
    const IMAGE_EXTENSIONS: &[&str] = &[
        "png", "jpg", "jpeg", "jpe", "jfif", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif",
        "ico", "icns", "cur", "jp2", "j2k", "jpf", "jpx", "psd", "tga", "exr", "hdr", "pbm", "pgm", "ppm",
        "pnm", "dds", "ktx", "ktx2", "astc", "qoi", "jxl", "dng", "cr2", "cr3", "nef", "arw", "orf", "raf",
        "rw2",
    ];
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| IMAGE_EXTENSIONS.contains(&extension.to_lowercase().as_str()))
}

fn file_name(path: &Path) -> Option<&str> {
    path.file_name().and_then(|name| name.to_str())
}

/// An absolute, lexically normalized path (`URL.standardizedFileURL`).
pub(crate) fn standardized(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map(|directory| directory.join(path)).unwrap_or_else(|_| path.to_path_buf())
    };
    soprano_platform::paths::normalize(&absolute)
}

#[cfg(unix)]
fn is_writable(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else { return false };
    // SAFETY: `path` is a valid NUL-terminated C string for the duration of the call.
    unsafe { libc::access(path.as_ptr(), libc::W_OK) == 0 }
}

#[cfg(not(unix))]
fn is_writable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| !metadata.permissions().readonly())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, bytes: &[u8]) {
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn editing_marks_the_document_dirty_and_restoring_the_saved_text_cleans_it() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("note.txt");
        write(&path, b"hello");
        let mut document = EditorDocument::open(&path);
        assert_eq!(document.content(), &DocumentContent::Text);
        assert!(!document.is_dirty());

        document.replace(5..5, "!");
        assert!(document.is_dirty());
        assert_eq!(document.tab_title(), "note.txt ●");
        assert_eq!(
            document.status(),
            Some(EditorStatus { text: "Modified".into(), tone: StatusTone::Warning })
        );

        document.replace(5..6, "");
        assert!(!document.is_dirty());
        assert_eq!(document.tab_title(), "note.txt");
        assert_eq!(
            document.take_changes(),
            [DocumentChange::State, DocumentChange::Edited, DocumentChange::State, DocumentChange::Edited]
        );
    }

    #[cfg(unix)]
    #[test]
    fn saving_writes_through_a_symlink_and_keeps_the_files_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let root_path = fs::canonicalize(root.path()).unwrap();
        let script = root_path.join("run.sh");
        write(&script, b"echo one\n");
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let link = root_path.join("link.sh");
        std::os::unix::fs::symlink(&script, &link).unwrap();

        let mut document = EditorDocument::open(&link);
        document.replace(5..8, "two");
        document.save().unwrap();

        assert!(!document.is_dirty());
        assert_eq!(fs::read_to_string(&script).unwrap(), "echo two\n");
        assert_eq!(fs::read_link(&link).unwrap(), script);
        assert_eq!(fs::metadata(&script).unwrap().permissions().mode() & 0o777, 0o755);
    }

    #[test]
    fn a_clean_document_follows_the_file_while_unsaved_edits_are_kept() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.yml");
        write(&path, b"a: 1\n");
        let mut document = EditorDocument::open(&path);

        write(&path, b"a: 2\n");
        document.disk_did_change();
        assert_eq!(document.text(), "a: 2\n");
        assert_eq!(document.disk_state(), DiskState::InSync);

        document.replace(0..0, "# mine\n");
        write(&path, b"a: 3\n");
        document.disk_did_change();
        assert_eq!(document.text(), "# mine\na: 2\n");
        assert_eq!(document.disk_state(), DiskState::Changed);
        assert!(document.shows_reload());
        assert_eq!(document.status().map(|status| status.text), Some("Changed on disk".to_string()));

        document.reload_from_disk();
        assert_eq!(document.text(), "a: 3\n");
        assert!(!document.is_dirty());

        fs::remove_file(&path).unwrap();
        document.disk_did_change();
        assert_eq!(document.disk_state(), DiskState::Deleted);
        assert_eq!(document.status().map(|status| status.text), Some("Deleted on disk".to_string()));
    }

    #[test]
    fn only_utf8_text_opens_as_text_images_as_images_and_missing_files_as_empty() {
        let root = tempfile::tempdir().unwrap();
        let binary = root.path().join("blob.bin");
        write(&binary, &[0x7F, 0x45, 0x00, 0x01]);
        assert!(matches!(EditorDocument::open(&binary).content(), DocumentContent::Unavailable(_)));

        let latin1 = root.path().join("legacy.txt");
        write(&latin1, &[0x63, 0x61, 0x66, 0xE9]);
        assert_eq!(
            EditorDocument::open(&latin1).content(),
            &DocumentContent::Unavailable("“legacy.txt” isn't a UTF-8 text file.".into())
        );

        let image = root.path().join("dot.png");
        write(&image, &png(3, 2));
        let image_document = EditorDocument::open(&image);
        assert_eq!(image_document.content(), &DocumentContent::Image { width: 3, height: 2 });
        assert_eq!(image_document.image_bytes().map(<[u8]>::len), Some(png(3, 2).len()));
        assert_eq!(image_document.status().map(|status| status.text), Some("3 × 2".to_string()));

        let gone = root.path().join("gone.txt");
        let mut missing = EditorDocument::open(&gone);
        assert_eq!(missing.content(), &DocumentContent::Text);
        assert_eq!(missing.disk_state(), DiskState::Deleted);
        missing.replace(0..0, "back");
        missing.save().unwrap();
        assert_eq!(fs::read_to_string(&gone).unwrap(), "back");
    }

    /// A minimal PNG header (signature + IHDR) with the given size.
    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut bytes =
            vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, b'I', b'H', b'D', b'R'];
        bytes.extend(width.to_be_bytes());
        bytes.extend(height.to_be_bytes());
        bytes.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
        bytes
    }

    #[test]
    fn line_numbers_count_newlines_before_the_offset() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("lines.txt");
        write(&path, b"one\ntwo\n\nfour");
        let mut document = EditorDocument::open(&path);

        assert_eq!(document.line_count(), 4);
        assert_eq!(document.line_number(0), 1);
        assert_eq!(document.line_number(4), 2);
        assert_eq!(document.line_number(8), 3);
        assert_eq!(document.line_number(13), 4);

        document.replace(0..0, "zero\n");
        assert_eq!(document.line_count(), 5);
        assert_eq!(document.line_number(5), 2);
        // Only line feeds start lines, as the Swift gutter counted them.
        document.replace(0..0, "a\rb\u{2028}c\n");
        assert_eq!(document.line_count(), 6);
    }

    #[test]
    fn a_file_over_the_size_limit_opens_as_a_note_without_its_bytes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("huge.log");
        fs::File::create(&path).unwrap().set_len(MAXIMUM_TEXT_BYTES + 1).unwrap();

        let document = EditorDocument::open(&path);

        assert_eq!(
            document.content(),
            &DocumentContent::Unavailable("“huge.log” is 8.4 MB, too large to open in Soprano.".into())
        );
        assert!(document.is_empty());
        assert_eq!(document.status(), None);
    }

    #[test]
    fn undo_and_redo_restore_the_text_and_typing_joins_one_step() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("main.swift");
        write(&path, b"let a = 1\n");
        let mut document = EditorDocument::open(&path);
        assert!(!document.can_undo());

        document.type_text(8..9, "4");
        document.type_text(9..9, "2");
        document.break_undo_coalescing();
        document.type_text(10..10, ";");
        assert_eq!(document.text(), "let a = 42;\n");

        assert_eq!(document.undo(), Some(10..10));
        assert_eq!(document.text(), "let a = 42\n");
        assert_eq!(document.undo(), Some(8..9));
        assert_eq!(document.text(), "let a = 1\n");
        assert!(!document.is_dirty());
        assert_eq!(document.redo(), Some(8..10));
        assert_eq!(document.text(), "let a = 42\n");
        assert!(document.is_dirty());

        document.replace(0..3, "var");
        assert!(!document.can_redo());
    }

    #[test]
    fn return_keeps_the_current_lines_indentation() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("main.swift");
        write(&path, b"func a() {\n\t  let b = 1\n}");
        let mut document = EditorDocument::open(&path);
        let caret = document.insert_newline(23..23);
        assert_eq!(document.text(), "func a() {\n\t  let b = 1\n\t  \n}");
        assert_eq!(caret, 27);
        // Only the indentation before the caret is kept.
        let caret = document.insert_newline(12..12);
        assert_eq!(&document.text()[..16], "func a() {\n\t\n\t  ");
        assert_eq!(caret, 14);
    }

    #[test]
    fn find_wraps_through_the_shared_text() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("notes.md");
        write(&path, b"Todo: one\ntodo: two");
        let document = EditorDocument::open(&path);
        assert_eq!(document.find_all("TODO"), [0..4, 10..14]);
        assert_eq!(document.find_next("todo", 1), Some(10..14));
        assert_eq!(document.find_next("todo", 11), Some(0..4));
        assert_eq!(document.find_previous("todo", 0), Some(10..14));
        assert!(document.shows_markdown_preview());
    }

    #[test]
    fn highlights_apply_only_to_the_text_they_were_computed_for() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("main.swift");
        write(&path, b"let a = 1\n");
        let mut document = EditorDocument::open(&path);
        let request = document.highlight_request().unwrap();
        let tokens = syntax::tokens(&request.text, request.language);
        assert_eq!(tokens.first().map(|token| token.kind), Some(syntax::SyntaxTokenKind::Keyword));

        document.replace(8..9, "2");
        assert!(!document.apply_highlights(request.version, tokens));
        document.highlight_now();
        assert_eq!(document.tokens().first().map(|token| token.kind), Some(syntax::SyntaxTokenKind::Keyword));

        document.relocate(root.path().join("notes.txt"));
        assert!(document.tokens().is_empty());
        assert!(document.highlight_request().is_none());
        assert!(document.take_changes().contains(&DocumentChange::Location));
    }

    #[test]
    fn file_sizes_read_like_the_finder() {
        assert_eq!(format_file_size(0), "Zero KB");
        assert_eq!(format_file_size(1), "1 byte");
        assert_eq!(format_file_size(999), "999 bytes");
        assert_eq!(format_file_size(12_400), "12 KB");
        assert_eq!(format_file_size(8 * 1024 * 1024 + 1), "8.4 MB");
        assert_eq!(format_file_size(8_000_000), "8 MB");
        assert_eq!(format_file_size(1_250_000_000), "1.25 GB");
    }

    #[test]
    fn the_gutter_fits_the_largest_line_number_with_two_digits_at_least() {
        assert_eq!(number_column_width(1, 7.2), 35.0);
        assert_eq!(number_column_width(99, 7.2), 35.0);
        assert_eq!(number_column_width(100, 7.2), 42.0);
        assert_eq!(number_column_width(0, 7.0), 34.0);
    }

    #[test]
    fn a_reloaded_selection_stays_inside_the_new_text_on_character_boundaries() {
        assert_eq!(restore_selection(&[], &Rope::from_str("0123456789")), vec![Range::default()]);
        assert_eq!(restore_selection(&[4..9, 12..15], &Rope::from_str("abcdef")), [4..6, 6..6]);
        // "日本語" is three 3-byte characters: offsets 4 and 7 fall inside the second and third.
        let text = Rope::from_str("日本語");
        assert_eq!(restore_selection(&[4..7, 1..2], &text), [3..6, 0..0]);
    }

    #[test]
    fn offsets_kept_by_another_view_are_moved_to_a_character_boundary() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("cjk.txt");
        write(&path, "日本".as_bytes());
        let document = EditorDocument::open(&path);
        assert_eq!(document.clamp_offset(4), 3);
        assert_eq!(document.clamp_offset(99), 6);
    }

    #[test]
    fn a_run_of_backspaces_and_forward_deletes_is_one_typing_undo_step() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("note.txt");
        write(&path, b"hello world");
        let mut document = EditorDocument::open(&path);
        // Type "!" after "hello", backspace twice, then delete forward twice.
        document.type_text(5..5, "!");
        document.type_text(5..6, "");
        document.type_text(4..5, "");
        document.type_text(4..5, "");
        document.type_text(4..5, "");
        assert_eq!(document.text(), "hellorld");
        // One step brings back "o w", the text the run removed, selected.
        assert_eq!(document.undo(), Some(4..7));
        assert_eq!(document.text(), "hello world");
        assert!(!document.can_undo());
        assert_eq!(document.redo(), Some(4..4));
        assert_eq!(document.text(), "hellorld");
        // A keystroke elsewhere starts a new step.
        document.type_text(0..1, "");
        document.type_text(3..4, "");
        assert_eq!(document.undo(), Some(3..4));
        assert_eq!(document.text(), "ellorld");
    }

    #[test]
    fn a_committed_input_method_word_is_one_undo_step() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("note.txt");
        write(&path, b"x ");
        let mut document = EditorDocument::open(&path);
        // に → にh → にほ → にほん, then the candidate 日本 replaces the marked text.
        let mut marked = document.mark_text(2..2, "に");
        for stage in ["にh", "にほ", "にほん"] {
            marked = document.mark_text(marked, stage);
        }
        assert_eq!(document.marked_range(), Some(2..11));
        assert!(!document.can_undo());
        assert!(document.is_dirty());
        let committed = document.type_text(marked, "日本");
        assert_eq!(committed, 2..8);
        assert_eq!(document.marked_range(), None);
        assert_eq!(document.text(), "x 日本");

        assert_eq!(document.undo(), Some(2..2));
        assert_eq!(document.text(), "x ");
        assert!(!document.can_undo());
        assert_eq!(document.redo(), Some(2..8));
        assert_eq!(document.text(), "x 日本");
    }

    #[test]
    fn a_composition_replacing_a_selection_or_cancelled_records_what_changed() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("note.txt");
        write(&path, b"abc");
        let mut document = EditorDocument::open(&path);
        // Composing over the selected "b", then unmarking as is.
        let marked = document.mark_text(1..2, "ㅎ");
        document.mark_text(marked, "한");
        document.commit_marked_text();
        assert_eq!(document.text(), "a한c");
        assert_eq!(document.undo(), Some(1..2));
        assert_eq!(document.text(), "abc");

        // Escape: the input method deletes its marked text; nothing is recorded.
        let marked = document.mark_text(3..3, "に");
        document.mark_text(marked, "");
        document.commit_marked_text();
        assert_eq!(document.text(), "abc");
        assert!(!document.can_undo());

        // An edit elsewhere commits a pending composition first, as its own step.
        document.mark_text(0..0, "に");
        document.replace(4..5, "");
        assert_eq!(document.text(), "にac");
        assert_eq!(document.undo(), Some(4..5));
        assert_eq!(document.undo(), Some(0..0));
        assert_eq!(document.text(), "abc");
    }

    #[test]
    fn saving_into_a_deleted_folder_fails_and_keeps_the_edits() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("gone");
        fs::create_dir(&folder).unwrap();
        let path = folder.join("note.txt");
        write(&path, b"one");
        let mut document = EditorDocument::open(&path);
        document.replace(3..3, " two");
        fs::remove_dir_all(&folder).unwrap();

        assert!(document.save().is_err());
        assert!(document.is_dirty());
        assert_eq!(document.text(), "one two");
        assert!(!folder.exists());
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    }
}
