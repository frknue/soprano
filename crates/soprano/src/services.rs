//! The app-lifetime services the views share: persisted state, settings.json, accounts, git
//! branches, saved workspaces and the IPC endpoint exported to panes.

use std::sync::Arc;

use gpui::Entity;
use soprano_accounts::AccountsController;
use soprano_config::ConfigStore;
use soprano_git::branch::GitBranchMonitor;
use soprano_model::SessionManager;
use soprano_platform::StateStore;

#[derive(Clone)]
pub struct Services {
    pub state: StateStore,
    pub config: ConfigStore,
    pub accounts: AccountsController,
    pub branches: Arc<GitBranchMonitor>,
    /// Saved named workspaces (`SessionManager`).
    pub sessions: Entity<SessionManager>,
}
