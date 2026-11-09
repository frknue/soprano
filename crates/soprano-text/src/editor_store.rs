//! The open editor documents, shared by every tab showing the same file, and the
//! decisions needed before unsaved changes would be lost (port of `EditorDocumentStore`).
//!
//! The Swift store asked its questions through blocking alert callbacks. GPUI prompts are
//! asynchronous, so this store returns what needs asking instead: the UI shows the dialog
//! and calls back with the answer ([`EditorDocumentStore::resolve_unsaved`],
//! [`EditorDocumentStore::save_anyway`]).
//!
//! Dialog texts (unchanged from Swift):
//! - one document: "Do you want to save the changes you made to “name”?" /
//!   "Your changes will be lost if you don't save them." — buttons Don't Save (⌘D,
//!   destructive outline), Cancel, Save (primary, Return);
//! - several: "Do you want to save the changes you made to N files?" / "a, b\n\nYour
//!   changes will be lost if you don't save them." — Save All;
//! - overwrite: "“name” has changed on disk." / "Another program changed it since you
//!   opened it. Saving replaces that version with yours." — Save Anyway.
//!   See [`save_question`] and [`OVERWRITE_MESSAGE`].

use std::collections::HashMap;
use std::hash::Hash;
use std::io;
use std::path::{Path, PathBuf};

use crate::editor::{EditorDocument, standardized};

/// Identifies an open document for as long as it stays open; a reopened file gets a new id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DocumentId(u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveChoice {
    Save,
    Discard,
    Cancel,
}

#[derive(Debug)]
pub enum SaveOutcome {
    Saved,
    /// Another program wrote a different version since the file was read: ask with
    /// [`overwrite_question`], then [`EditorDocumentStore::save_anyway`] on Save Anyway.
    NeedsOverwriteConfirmation,
    /// Report the error in an alert (its description as the title).
    Failed(io::Error),
}

/// The answer to closing documents with unsaved changes.
#[derive(Debug)]
pub enum CloseResolution {
    /// Go on closing.
    Proceed,
    /// Keep them open.
    Cancel,
    /// Saving `document` did not complete; after asking (overwrite) or reporting (error),
    /// resolve the documents that are left again, or keep them open.
    SaveBlocked { document: DocumentId, outcome: SaveOutcome },
}

pub const OVERWRITE_MESSAGE: &str =
    "Another program changed it since you opened it. Saving replaces that version with yours.";

/// The save question's title, message and primary button for `names`.
pub fn save_question(names: &[String]) -> (String, String, &'static str) {
    const LOST: &str = "Your changes will be lost if you don't save them.";
    if let [name] = names {
        (format!("Do you want to save the changes you made to “{name}”?"), LOST.to_string(), "Save")
    } else {
        (
            format!("Do you want to save the changes you made to {} files?", names.len()),
            format!("{}\n\n{LOST}", names.join(", ")),
            "Save All",
        )
    }
}

/// The overwrite question's title.
pub fn overwrite_question(name: &str) -> String {
    format!("“{name}” has changed on disk.")
}

/// `T` names a tab (the app's pane/tab target); `V` identifies the view showing it: a tab's
/// view can be rebuilt while the old one is still alive, and the old one leaving must not
/// take the new one's place with it.
pub struct EditorDocumentStore<T, V> {
    next_id: u64,
    documents: HashMap<DocumentId, EditorDocument>,
    by_path: HashMap<PathBuf, DocumentId>,
    attachments: HashMap<V, (T, DocumentId)>,
}

impl<T: Clone + Eq + Hash, V: Eq + Hash> Default for EditorDocumentStore<T, V> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Clone + Eq + Hash, V: Eq + Hash> EditorDocumentStore<T, V> {
    pub fn new() -> Self {
        Self { next_id: 0, documents: HashMap::new(), by_path: HashMap::new(), attachments: HashMap::new() }
    }

    /// The open document for `path`, opened now if it is not yet.
    pub fn open(&mut self, path: impl AsRef<Path>) -> DocumentId {
        let key = standardized(path.as_ref());
        if let Some(id) = self.by_path.get(&key) {
            return *id;
        }
        self.next_id += 1;
        let id = DocumentId(self.next_id);
        self.documents.insert(id, EditorDocument::open(&key));
        self.by_path.insert(key, id);
        id
    }

    pub fn get(&self, id: DocumentId) -> Option<&EditorDocument> {
        self.documents.get(&id)
    }

    pub fn get_mut(&mut self, id: DocumentId) -> Option<&mut EditorDocument> {
        self.documents.get_mut(&id)
    }

    /// The document open for `path`, if any.
    pub fn document_at(&self, path: impl AsRef<Path>) -> Option<DocumentId> {
        self.by_path.get(&standardized(path.as_ref())).copied()
    }

    /// Records that `view`, the content of tab `target`, shows `document`.
    pub fn attach(&mut self, view: V, target: T, document: DocumentId) {
        self.attachments.insert(view, (target, document));
    }

    /// `view` is gone; the last view of a document closes it.
    pub fn detach(&mut self, view: &V) {
        let Some((_, document)) = self.attachments.remove(view) else { return };
        if !self.attachments.values().any(|(_, other)| *other == document) {
            self.close(document);
        }
    }

    fn close(&mut self, id: DocumentId) {
        if let Some(document) = self.documents.remove(&id) {
            self.by_path.remove(document.path());
        }
    }

    pub fn has_unsaved_changes(&self, path: impl AsRef<Path>) -> bool {
        self.document_at(path).and_then(|id| self.get(id)).is_some_and(EditorDocument::is_dirty)
    }

    /// Before the tabs `targets` close: the documents with unsaved changes that no remaining
    /// tab shows. Empty means close without asking; otherwise ask with [`save_question`] and
    /// pass the answer to [`resolve_unsaved`](Self::resolve_unsaved).
    pub fn unsaved_when_closing(&self, targets: &[T]) -> Vec<DocumentId> {
        let mut losing: Vec<DocumentId> = Vec::new();
        for (target, document) in self.attachments.values() {
            if !targets.contains(target) || !self.is_dirty(*document) {
                continue;
            }
            let keeps_another_tab =
                self.attachments.values().any(|(other, shown)| shown == document && !targets.contains(other));
            if !keeps_another_tab && !losing.contains(document) {
                losing.push(*document);
            }
        }
        losing
    }

    /// Before the app quits or its window closes: every document with unsaved changes, by name.
    pub fn unsaved_when_closing_all(&self) -> Vec<DocumentId> {
        let mut dirty: Vec<(&EditorDocument, DocumentId)> = self
            .documents
            .iter()
            .filter(|(_, document)| document.is_dirty())
            .map(|(id, d)| (d, *id))
            .collect();
        dirty.sort_by_key(|(document, id)| (document.name(), *id));
        dirty.into_iter().map(|(_, id)| id).collect()
    }

    /// The names the save question lists for `documents`.
    pub fn names(&self, documents: &[DocumentId]) -> Vec<String> {
        documents.iter().filter_map(|id| self.get(*id)).map(EditorDocument::name).collect()
    }

    /// Applies the answer to the save question for `documents`.
    pub fn resolve_unsaved(&mut self, documents: &[DocumentId], choice: SaveChoice) -> CloseResolution {
        if documents.is_empty() {
            return CloseResolution::Proceed;
        }
        match choice {
            SaveChoice::Cancel => CloseResolution::Cancel,
            SaveChoice::Discard => {
                for id in documents {
                    if let Some(document) = self.get_mut(*id) {
                        document.discard_changes();
                    }
                }
                CloseResolution::Proceed
            }
            SaveChoice::Save => {
                for id in documents {
                    match self.save(*id) {
                        SaveOutcome::Saved => {}
                        outcome => return CloseResolution::SaveBlocked { document: *id, outcome },
                    }
                }
                CloseResolution::Proceed
            }
        }
    }

    /// Saves, unless another program changed the file since it was read (then ask first).
    pub fn save(&mut self, id: DocumentId) -> SaveOutcome {
        match self.get(id) {
            Some(document) if document.disk_changed_since_last_sync() => {
                SaveOutcome::NeedsOverwriteConfirmation
            }
            _ => self.save_anyway(id),
        }
    }

    /// Saves over whatever is on disk (Save Anyway).
    pub fn save_anyway(&mut self, id: DocumentId) -> SaveOutcome {
        let Some(document) = self.get_mut(id) else { return SaveOutcome::Saved };
        match document.save() {
            Ok(()) => SaveOutcome::Saved,
            Err(error) => SaveOutcome::Failed(error),
        }
    }

    /// Follows a rename or move of `old_path`, or of a folder containing open documents.
    pub fn relocate(&mut self, old_path: impl AsRef<Path>, new_path: impl AsRef<Path>) {
        let old = standardized(old_path.as_ref());
        let new = standardized(new_path.as_ref());
        let moved: Vec<(PathBuf, DocumentId)> = self
            .by_path
            .iter()
            .filter_map(|(path, id)| {
                let relocated =
                    if *path == old { new.clone() } else { new.join(path.strip_prefix(&old).ok()?) };
                Some((relocated, *id))
            })
            .collect();
        for (relocated, id) in moved {
            let Some(document) = self.documents.get_mut(&id) else { continue };
            self.by_path.remove(document.path());
            document.relocate(&relocated);
            self.by_path.insert(document.path().to_path_buf(), id);
        }
    }

    fn is_dirty(&self, id: DocumentId) -> bool {
        self.get(id).is_some_and(EditorDocument::is_dirty)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    type Store = EditorDocumentStore<&'static str, u32>;

    #[test]
    fn a_rebuilt_view_keeps_its_document_when_the_old_view_for_the_same_tab_goes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("main.swift");
        fs::write(&path, "a").unwrap();
        let mut store = Store::new();
        let document = store.open(&path);
        store.attach(1, "tab-1", document);
        store.attach(2, "tab-1", document);
        store.get_mut(document).unwrap().replace(1..1, "b");

        store.detach(&1);

        assert_eq!(store.open(&path), document);
        assert!(store.has_unsaved_changes(&path));
        assert_eq!(store.unsaved_when_closing(&["tab-1"]), [document]);
        assert!(matches!(store.resolve_unsaved(&[document], SaveChoice::Cancel), CloseResolution::Cancel));
    }

    #[test]
    fn closing_one_of_two_tabs_showing_an_unsaved_file_does_not_ask() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("main.swift");
        fs::write(&path, "let a = 1\n").unwrap();
        let mut store = Store::new();
        let document = store.open(&path);
        assert_eq!(store.open(&path), document);
        store.attach(1, "tab-1", document);
        store.attach(2, "tab-2", document);
        store.get_mut(document).unwrap().replace(8..9, "2");

        assert!(store.unsaved_when_closing(&["tab-1"]).is_empty());

        let losing = store.unsaved_when_closing(&["tab-1", "tab-2"]);
        assert_eq!(store.names(&losing), ["main.swift"]);
        assert!(matches!(store.resolve_unsaved(&losing, SaveChoice::Cancel), CloseResolution::Cancel));
        assert!(store.get(document).unwrap().is_dirty());

        assert!(matches!(store.resolve_unsaved(&losing, SaveChoice::Discard), CloseResolution::Proceed));
        assert!(!store.get(document).unwrap().is_dirty());
        assert_eq!(fs::read_to_string(&path).unwrap(), "let a = 1\n");

        store.get_mut(document).unwrap().replace(8..9, "3");
        let all = store.unsaved_when_closing_all();
        assert_eq!(all, [document]);
        assert!(matches!(store.resolve_unsaved(&all, SaveChoice::Save), CloseResolution::Proceed));
        assert_eq!(fs::read_to_string(&path).unwrap(), "let a = 3\n");
    }

    #[test]
    fn saving_over_another_programs_change_asks_first() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("notes.md");
        fs::write(&path, "mine").unwrap();
        let mut store = Store::new();
        let document = store.open(&path);
        store.get_mut(document).unwrap().replace(4..4, "!");
        fs::write(&path, "theirs").unwrap();

        assert!(matches!(store.save(document), SaveOutcome::NeedsOverwriteConfirmation));
        assert_eq!(fs::read_to_string(&path).unwrap(), "theirs");

        assert!(matches!(store.save_anyway(document), SaveOutcome::Saved));
        assert_eq!(fs::read_to_string(&path).unwrap(), "mine!");
    }

    #[test]
    fn saving_after_the_watcher_noticed_another_programs_change_still_asks_first() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("notes.md");
        fs::write(&path, "mine").unwrap();
        let mut store = Store::new();
        let document = store.open(&path);
        store.get_mut(document).unwrap().replace(4..4, "!");
        fs::write(&path, "theirs").unwrap();
        store.get_mut(document).unwrap().disk_did_change();
        assert_eq!(store.get(document).unwrap().disk_state(), crate::editor::DiskState::Changed);

        let resolution = store.resolve_unsaved(&[document], SaveChoice::Save);
        assert!(matches!(
            resolution,
            CloseResolution::SaveBlocked { outcome: SaveOutcome::NeedsOverwriteConfirmation, .. }
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "theirs");
    }

    #[test]
    fn renaming_a_folder_moves_the_documents_inside_it() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("src");
        fs::create_dir(&folder).unwrap();
        let path = folder.join("app.ts");
        fs::write(&path, "const a = 1").unwrap();
        let sibling = root.path().join("srcs.ts");
        fs::write(&sibling, "x").unwrap();
        let mut store = Store::new();
        let document = store.open(&path);
        let other = store.open(&sibling);
        store.attach(1, "tab-1", document);

        let renamed = root.path().join("lib");
        fs::rename(&folder, &renamed).unwrap();
        store.relocate(&folder, &renamed);

        let new_path = renamed.join("app.ts");
        assert_eq!(store.get(document).unwrap().path(), new_path);
        assert_eq!(store.open(&new_path), document);
        assert_eq!(store.get(other).unwrap().path(), sibling);

        store.detach(&1);
        assert_ne!(store.open(&new_path), document);
    }

    #[test]
    fn the_questions_name_one_file_or_count_several() {
        let (title, message, button) = save_question(&["main.swift".into()]);
        assert_eq!(title, "Do you want to save the changes you made to “main.swift”?");
        assert_eq!(message, "Your changes will be lost if you don't save them.");
        assert_eq!(button, "Save");
        let (title, message, button) = save_question(&["a.rs".into(), "b.rs".into()]);
        assert_eq!(title, "Do you want to save the changes you made to 2 files?");
        assert_eq!(message, "a.rs, b.rs\n\nYour changes will be lost if you don't save them.");
        assert_eq!(button, "Save All");
        assert_eq!(overwrite_question("notes.md"), "“notes.md” has changed on disk.");
    }
}
