//! The workspace as the app holds it: `soprano_model::Workspace` inside a GPUI entity (the lead's
//! contract for every UI crate), plus a bus that carries what each mutation changed.
//!
//! Every mutation goes through [`WorkspaceHandle::update`], which drains the model's change log
//! (`take_changes` / `take_events`), publishes it on the bus and notifies the entity, so views
//! that `observe` the model re-render and the shell can act on lifecycle events (stop/restart
//! a terminal), layout changes and document moves.

use gpui::{App, AppContext, Entity, EventEmitter};
use soprano_model::{Workspace, WorkspaceChange, WorkspaceEvent};

/// What one mutation changed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WorkspaceUpdate {
    pub changes: Vec<WorkspaceChange>,
    pub events: Vec<WorkspaceEvent>,
}

impl WorkspaceUpdate {
    pub fn is_empty(&self) -> bool {
        self.changes.is_empty() && self.events.is_empty()
    }
}

/// Emits a [`WorkspaceUpdate`] after each mutation that changed something.
pub struct WorkspaceBus;

impl EventEmitter<WorkspaceUpdate> for WorkspaceBus {}

/// The shared handle every view gets.
#[derive(Clone)]
pub struct WorkspaceHandle {
    pub model: Entity<Workspace>,
    pub bus: Entity<WorkspaceBus>,
}

impl WorkspaceHandle {
    pub fn new(workspace: Workspace, cx: &mut App) -> Self {
        Self { model: cx.new(|_| workspace), bus: cx.new(|_| WorkspaceBus) }
    }

    pub fn read<'a>(&self, cx: &'a App) -> &'a Workspace {
        self.model.read(cx)
    }

    /// Runs `f` on the model, then publishes and notifies whatever it changed.
    pub fn update<R>(&self, cx: &mut App, f: impl FnOnce(&mut Workspace) -> R) -> R {
        let (result, update) = self.model.update(cx, |workspace, cx| {
            let result = f(workspace);
            let update =
                WorkspaceUpdate { changes: workspace.take_changes(), events: workspace.take_events() };
            if !update.is_empty() {
                cx.notify();
            }
            (result, update)
        });
        if !update.is_empty() {
            self.bus.update(cx, |_, cx| cx.emit(update));
        }
        result
    }

    /// [`Self::update`] for work that also needs the app (other entities) while it holds the
    /// model: it must not read or update the workspace entity through `cx`.
    pub fn update_with<R>(&self, cx: &mut App, f: impl FnOnce(&mut Workspace, &mut App) -> R) -> R {
        let (result, update) = self.model.update(cx, |workspace, cx| {
            let result = f(workspace, cx);
            let update =
                WorkspaceUpdate { changes: workspace.take_changes(), events: workspace.take_events() };
            if !update.is_empty() {
                cx.notify();
            }
            (result, update)
        });
        if !update.is_empty() {
            self.bus.update(cx, |_, cx| cx.emit(update));
        }
        result
    }
}
