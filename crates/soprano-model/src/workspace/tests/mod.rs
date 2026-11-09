//! Ports of the Swift tests whose subject is `AgentManager` model logic.

mod agents;
mod chat;
mod files;
mod layout_tabs;
mod panes;
mod persistence;
mod presentation;
mod sessions;

use std::collections::HashSet;

use super::{CloseOutcome, TerminalTarget, Workspace};

/// The id of `pane_id`'s active tab.
fn active_tab_id(workspace: &Workspace, pane_id: &str) -> String {
    workspace
        .pane(pane_id)
        .and_then(|pane| pane.active_tab())
        .map(|tab| tab.id.clone())
        .expect("pane has an active tab")
}

/// Every tab of every pane in `pane_ids` as targets.
fn targets(workspace: &Workspace, pane_ids: &[&str]) -> HashSet<TerminalTarget> {
    pane_ids
        .iter()
        .flat_map(|pane_id| {
            workspace
                .pane(pane_id)
                .into_iter()
                .flat_map(|pane| pane.tabs.iter().map(|tab| TerminalTarget::new(&pane.id, &tab.id)))
        })
        .collect()
}

/// The tabs a close asked about, as a set; panics when it did not ask.
fn asked_about(outcome: &CloseOutcome) -> HashSet<TerminalTarget> {
    match outcome {
        CloseOutcome::NeedsConfirmation { targets, .. } => targets.iter().cloned().collect(),
        other => panic!("expected a confirmation request, got {other:?}"),
    }
}

/// A predicate that always asks.
fn always_ask(workspace: &mut Workspace) {
    workspace.set_close_confirmation(Some(Box::new(|_| true)));
}
