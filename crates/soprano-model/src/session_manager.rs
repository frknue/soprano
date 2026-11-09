//! Named workspace snapshots — save, load, delete (`Controllers/SessionManager.swift`), stored
//! under `soprano-sessions` in the [`StateStore`].

use std::time::{SystemTime, UNIX_EPOCH};

use soprano_platform::StateStore;

use crate::session::{ReferenceDate, WorkspaceSession};
use crate::workspace::{CloseOutcome, Workspace};

/// The saved named workspaces, newest first.
pub struct SessionManager {
    sessions: Vec<WorkspaceSession>,
    store: StateStore,
    changed: bool,
}

impl SessionManager {
    pub fn new(store: StateStore) -> Self {
        let sessions = WorkspaceSession::load_all(&store);
        Self { sessions, store, changed: false }
    }

    pub fn sessions(&self) -> &[WorkspaceSession] {
        &self.sessions
    }

    /// Whether the list changed since the last call (replaces Swift's observers).
    pub fn take_changed(&mut self) -> bool {
        std::mem::take(&mut self.changed)
    }

    /// Saves everything open in `workspace` under `name` (trimmed; blank names are ignored).
    pub fn save_session(&mut self, name: &str, workspace: &Workspace) {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return;
        }
        let millis = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis());
        let snapshot = workspace.snapshot_workspace();
        let named = WorkspaceSession {
            id: format!("session-{millis}"),
            name: trimmed.to_owned(),
            saved_at: ReferenceDate::now(),
            ..snapshot
        };
        self.sessions.insert(0, named);
        self.persist();
        self.changed = true;
    }

    /// Restores the saved workspace `session_id` into `workspace`. Restoring replaces every
    /// open tab, so it may need confirmation first (see [`Workspace::restore_workspace`]).
    pub fn load_session(&self, session_id: &str, workspace: &mut Workspace) -> CloseOutcome {
        match self.sessions.iter().find(|session| session.id == session_id && !session.panes.is_empty()) {
            Some(session) => workspace.restore_workspace(session.clone()),
            None => CloseOutcome::Unchanged,
        }
    }

    pub fn delete_session(&mut self, session_id: &str) {
        self.sessions.retain(|session| session.id != session_id);
        self.persist();
        self.changed = true;
    }

    fn persist(&self) {
        WorkspaceSession::save_all(&self.sessions, &self.store);
    }
}
