//! The open editor documents as a GPUI entity: soprano-text's [`EditorDocumentStore`] (one
//! [`EditorDocument`] per file, shared by every tab showing it) plus what keeps a document
//! current while it is open — a debounced watcher on its folder (`disk_did_change`) and
//! syntax highlighting off the UI thread, [`HIGHLIGHT_DELAY_MS`] after the last edit.
//!
//! Every mutation goes through this entity, which drains the document's queued changes and
//! emits them as [`DocumentsEvent::Changed`], so every view of the document hears them.
//! `T` is the app's tab target ([`EditorDocumentStore`]'s `T`); views are keyed by their
//! entity id.

use std::collections::HashMap;
use std::hash::Hash;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::time::Duration;

use gpui::{Context, EntityId, EventEmitter, Task};
use soprano_text::editor::{DocumentChange, HIGHLIGHT_DELAY_MS, WATCH_DEBOUNCE_MS};
use soprano_text::editor_store::{CloseResolution, SaveChoice, SaveOutcome};
use soprano_text::watch::FileWatcher;
use soprano_text::{DocumentId, EditorDocument, EditorDocumentStore, syntax};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DocumentsEvent {
    /// The text of `document` was edited through `source` (a view's entity id): the other
    /// views of the document move their selections with the edit, as NSTextView did over a
    /// shared text storage. Sent before the matching [`DocumentsEvent::Changed`].
    Edited { document: DocumentId, edit: TextEdit, source: EntityId },
    /// `document` changed (oldest change first); its views update.
    Changed { document: DocumentId, changes: Vec<DocumentChange> },
}

/// One replacement in a document's text: `range` (bytes of the text before the edit) now
/// holds `new_len` bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextEdit {
    pub range: Range<usize>,
    pub new_len: usize,
}

impl TextEdit {
    /// The edit that turned a text of `old_len` bytes into one of `new_len_total` bytes, where
    /// `new_range` is the replacement's range in the new text (what the document's editing
    /// calls return).
    pub fn from_result(new_range: Range<usize>, old_len: usize, new_len_total: usize) -> Self {
        let removed =
            (new_range.len() as isize - (new_len_total as isize - old_len as isize)).max(0) as usize;
        Self { range: new_range.start..new_range.start + removed, new_len: new_range.len() }
    }

    /// Where `offset` (in the text before the edit) is afterwards: unchanged before the edit,
    /// moved by the change in length after it, and at the replacement's end inside it.
    pub fn shift(&self, offset: usize) -> usize {
        if offset <= self.range.start {
            offset
        } else if offset >= self.range.end {
            offset - self.range.len() + self.new_len
        } else {
            self.range.start + self.new_len
        }
    }
}

/// Fields drop in order: the task that listens to the watcher goes before the watcher, so
/// the watcher's thread never wakes a task that is being dropped.
struct Upkeep {
    _watch_task: Task<()>,
    _watcher: Option<FileWatcher>,
    highlight: Option<Task<()>>,
}

pub struct EditorDocuments<T> {
    store: EditorDocumentStore<T, EntityId>,
    upkeep: HashMap<DocumentId, Upkeep>,
}

impl<T: Clone + Eq + Hash + 'static> EventEmitter<DocumentsEvent> for EditorDocuments<T> {}

impl<T: Clone + Eq + Hash + 'static> Default for EditorDocuments<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Clone + Eq + Hash + 'static> EditorDocuments<T> {
    pub fn new() -> Self {
        Self { store: EditorDocumentStore::new(), upkeep: HashMap::new() }
    }

    /// The store, for the questions asked before tabs close
    /// (`unsaved_when_closing`, `names`, …).
    pub fn store(&self) -> &EditorDocumentStore<T, EntityId> {
        &self.store
    }

    pub fn document(&self, id: DocumentId) -> Option<&EditorDocument> {
        self.store.get(id)
    }

    /// The open document for `path`, opened (read, watched, highlighted) now if it is not yet.
    pub fn open(&mut self, path: impl AsRef<Path>, cx: &mut Context<Self>) -> DocumentId {
        let id = self.store.open(path);
        if !self.upkeep.contains_key(&id) {
            self.watch(id, cx);
            self.highlight(id, Duration::ZERO, cx);
        }
        id
    }

    /// Records that view `view` (an entity id), the content of tab `target`, shows `document`.
    pub fn attach(&mut self, view: EntityId, target: T, document: DocumentId) {
        self.store.attach(view, target, document);
    }

    /// `view` is gone; the last view of a document closes it.
    pub fn detach(&mut self, view: EntityId) {
        self.store.detach(&view);
        self.upkeep.retain(|id, _| self.store.get(*id).is_some());
    }

    /// Runs `edit` on the document and broadcasts what changed.
    pub fn update<R>(
        &mut self,
        id: DocumentId,
        cx: &mut Context<Self>,
        edit: impl FnOnce(&mut EditorDocument) -> R,
    ) -> Option<R> {
        let result = edit(self.store.get_mut(id)?);
        self.flush(id, cx);
        Some(result)
    }

    /// Runs `edit`, an edit of the text that returns the replacement's range in the new text
    /// (`replace`, `type_text`, `undo`, …), and tells the other views of the document where
    /// the text moved.
    pub fn edit_text(
        &mut self,
        id: DocumentId,
        source: EntityId,
        cx: &mut Context<Self>,
        edit: impl FnOnce(&mut EditorDocument) -> Option<Range<usize>>,
    ) -> Option<Range<usize>> {
        let document = self.store.get_mut(id)?;
        let (before, version) = (document.len(), document.text_version());
        let result = edit(document);
        if let Some(range) = result.clone()
            && document.text_version() != version
        {
            let edit = TextEdit::from_result(range, before, document.len());
            cx.emit(DocumentsEvent::Edited { document: id, edit, source });
        }
        self.flush(id, cx);
        result
    }

    /// Saves, unless another program changed the file since it was read.
    pub fn save(&mut self, id: DocumentId, cx: &mut Context<Self>) -> SaveOutcome {
        let outcome = self.store.save(id);
        self.flush(id, cx);
        outcome
    }

    /// Saves over whatever is on disk (Save Anyway).
    pub fn save_anyway(&mut self, id: DocumentId, cx: &mut Context<Self>) -> SaveOutcome {
        let outcome = self.store.save_anyway(id);
        self.flush(id, cx);
        outcome
    }

    /// Applies the answer to the save question asked before closing `documents`.
    pub fn resolve_unsaved(
        &mut self,
        documents: &[DocumentId],
        choice: SaveChoice,
        cx: &mut Context<Self>,
    ) -> CloseResolution {
        let resolution = self.store.resolve_unsaved(documents, choice);
        self.flush_all(cx);
        resolution
    }

    /// Follows a rename or move made in the explorer (of the file or a folder above it).
    pub fn relocate(
        &mut self,
        old_path: impl AsRef<Path>,
        new_path: impl AsRef<Path>,
        cx: &mut Context<Self>,
    ) {
        self.store.relocate(old_path, new_path);
        self.flush_all(cx);
    }

    fn flush_all(&mut self, cx: &mut Context<Self>) {
        let ids: Vec<DocumentId> = self.upkeep.keys().copied().collect();
        for id in ids {
            self.flush(id, cx);
        }
    }

    /// Drains `id`'s queued changes, keeps its watcher and colors current, and tells its views.
    fn flush(&mut self, id: DocumentId, cx: &mut Context<Self>) {
        let Some(document) = self.store.get_mut(id) else { return };
        let changes = document.take_changes();
        if changes.is_empty() {
            return;
        }
        if changes.contains(&DocumentChange::Location) {
            self.watch(id, cx);
        }
        if changes.iter().any(|change| matches!(change, DocumentChange::Content | DocumentChange::Location)) {
            self.highlight(id, Duration::ZERO, cx);
        } else if changes.contains(&DocumentChange::Edited) {
            self.highlight(id, Duration::from_millis(HIGHLIGHT_DELAY_MS), cx);
        }
        cx.emit(DocumentsEvent::Changed { document: id, changes });
        cx.notify();
    }

    /// Watches the document's folder; changes reach `disk_did_change` after the debounce.
    fn watch(&mut self, id: DocumentId, cx: &mut Context<Self>) {
        let Some(path) = self.store.get(id).map(|document| document.path().to_path_buf()) else { return };
        let (sender, receiver) = async_channel::unbounded::<()>();
        let watcher = Some(FileWatcher::new(&path, Duration::from_millis(WATCH_DEBOUNCE_MS), move || {
            let _ = sender.try_send(());
        }));
        let task = cx.spawn(async move |this, cx| {
            while receiver.recv().await.is_ok() {
                let alive = this.update(cx, |this, cx| {
                    this.update(id, cx, EditorDocument::disk_did_change);
                });
                if alive.is_err() {
                    break;
                }
            }
        });
        let highlight = self.upkeep.remove(&id).and_then(|upkeep| upkeep.highlight);
        self.upkeep.insert(id, Upkeep { _watcher: watcher, _watch_task: task, highlight });
    }

    /// Colors the text after `delay`, off the UI thread; a newer request replaces this one.
    fn highlight(&mut self, id: DocumentId, delay: Duration, cx: &mut Context<Self>) {
        let task = cx.spawn(async move |this, cx| {
            if !delay.is_zero() {
                cx.background_executor().timer(delay).await;
            }
            let Ok(Some(request)) = this.update(cx, |this, cx| {
                let request = this.store.get_mut(id).and_then(EditorDocument::highlight_request);
                this.flush(id, cx);
                request
            }) else {
                return;
            };
            let version = request.version;
            let tokens = cx
                .background_executor()
                .spawn(async move { syntax::tokens(&request.text, request.language) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.update(id, cx, |document| document.apply_highlights(version, tokens));
            });
        });
        if let Some(upkeep) = self.upkeep.get_mut(&id) {
            upkeep.highlight = Some(task);
        } else {
            self.upkeep
                .insert(id, Upkeep { _watcher: None, _watch_task: Task::ready(()), highlight: Some(task) });
        }
    }

    /// The paths of the open documents (for tests and the app's window title checks).
    pub fn open_paths(&self) -> Vec<PathBuf> {
        self.upkeep.keys().filter_map(|id| self.store.get(*id)).map(|d| d.path().to_path_buf()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_edit_is_read_back_from_the_replacement_and_the_lengths() {
        // "one two" → "one 2" by replacing 4..7 ("two") with "2".
        let edit = TextEdit::from_result(4..5, 7, 5);
        assert_eq!(edit, TextEdit { range: 4..7, new_len: 1 });
        // An insertion of 4 bytes at 3.
        assert_eq!(TextEdit::from_result(3..7, 4, 8), TextEdit { range: 3..3, new_len: 4 });
        // A deletion of 2..5 returns an empty range at 2.
        assert_eq!(TextEdit::from_result(2..2, 9, 6), TextEdit { range: 2..5, new_len: 0 });
    }

    #[test]
    fn offsets_move_with_an_edit_made_in_another_tab() {
        let edit = TextEdit { range: 4..7, new_len: 1 };
        assert_eq!(edit.shift(2), 2);
        assert_eq!(edit.shift(4), 4);
        assert_eq!(edit.shift(5), 5);
        assert_eq!(edit.shift(7), 5);
        assert_eq!(edit.shift(10), 8);
        let insertion = TextEdit { range: 3..3, new_len: 4 };
        assert_eq!(insertion.shift(3), 3);
        assert_eq!(insertion.shift(6), 10);
    }
}
