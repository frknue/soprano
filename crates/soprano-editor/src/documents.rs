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
use std::path::{Path, PathBuf};
use std::time::Duration;

use gpui::{Context, EntityId, EventEmitter, Task};
use soprano_text::editor::{DocumentChange, HIGHLIGHT_DELAY_MS, WATCH_DEBOUNCE_MS};
use soprano_text::editor_store::{CloseResolution, SaveChoice, SaveOutcome};
use soprano_text::watch::FileWatcher;
use soprano_text::{DocumentId, EditorDocument, EditorDocumentStore, syntax};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DocumentsEvent {
    /// `document` changed (oldest change first); its views update.
    Changed { document: DocumentId, changes: Vec<DocumentChange> },
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
