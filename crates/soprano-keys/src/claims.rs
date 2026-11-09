//! Navigation passthrough claims: while a terminal program (Neovim, tmux, …) has announced
//! `soprano navigation-passthrough enable <source>` for a pane tab, Ctrl+H/J/K/L in that exact
//! tab go to the terminal; the program bubbles a navigation request back to Soprano when its
//! own layout reaches an edge.

use std::collections::{HashMap, HashSet};

use soprano_types::{NavigationDirection, TerminalTarget};

/// Whether a terminal program claims the navigation keys of a target. Implemented by
/// [`PaneNavigationClaimRegistry`]; a host that keeps its claims elsewhere implements it there.
pub trait PassthroughClaims {
    fn has_claims(&self, target: &TerminalTarget) -> bool;
}

/// No claims anywhere.
impl PassthroughClaims for () {
    fn has_claims(&self, _target: &TerminalTarget) -> bool {
        false
    }
}

/// Counted claims per target and source: every `enable` needs its own `disable`.
#[derive(Clone, Debug, Default)]
pub struct PaneNavigationClaimRegistry {
    counts_by_target: HashMap<TerminalTarget, HashMap<String, u32>>,
    workspace_restore_generation: Option<i64>,
}

impl PaneNavigationClaimRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn enable(&mut self, source: &str, target: &TerminalTarget) {
        *self.counts_by_target.entry(target.clone()).or_default().entry(source.to_owned()).or_insert(0) += 1;
    }

    /// Drops one claim of `source`; a disable with no matching enable changes nothing.
    pub fn disable(&mut self, source: &str, target: &TerminalTarget) {
        let Some(sources) = self.counts_by_target.get_mut(target) else { return };
        let Some(count) = sources.get_mut(source) else { return };
        if *count > 1 {
            *count -= 1;
            return;
        }
        sources.remove(source);
        if sources.is_empty() {
            self.counts_by_target.remove(target);
        }
    }

    /// Prunes claims of tabs that no longer exist. A changed `workspace_restore_generation`
    /// means the workspace was replaced (restored or switched): even targets with the same ids
    /// belong to new terminals, so every claim goes.
    pub fn synchronize(
        &mut self,
        valid_targets: &HashSet<TerminalTarget>,
        workspace_restore_generation: i64,
    ) {
        match self.workspace_restore_generation {
            Some(previous) if previous != workspace_restore_generation => self.counts_by_target.clear(),
            _ => self.counts_by_target.retain(|target, _| valid_targets.contains(target)),
        }
        self.workspace_restore_generation = Some(workspace_restore_generation);
    }

    /// Applies one `soprano pane-navigation` request for `target` (the pane and tab the CLI ran
    /// in). A request with both `passthrough` (`enable`/`disable`) and `source` updates the
    /// claims and navigates nowhere; otherwise a known `direction` navigates when `target` is
    /// the active tab. Returns the direction to navigate.
    pub fn handle_request(
        &mut self,
        target: &TerminalTarget,
        passthrough: Option<&str>,
        source: Option<&str>,
        direction: Option<&str>,
        active_target: Option<&TerminalTarget>,
    ) -> Option<NavigationDirection> {
        if let (Some(mode), Some(source)) = (passthrough, source) {
            match mode {
                "enable" => self.enable(source, target),
                "disable" => self.disable(source, target),
                _ => {}
            }
            return None;
        }
        if active_target != Some(target) {
            return None;
        }
        NavigationDirection::from_raw(direction?)
    }
}

impl PassthroughClaims for PaneNavigationClaimRegistry {
    fn has_claims(&self, target: &TerminalTarget) -> bool {
        self.counts_by_target.get(target).is_some_and(|sources| !sources.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claims_are_scoped_to_the_exact_pane_and_tab() {
        let first_tab = TerminalTarget::new("pane-1", "tab-1");
        let second_tab = TerminalTarget::new("pane-1", "tab-2");
        let mut registry = PaneNavigationClaimRegistry::new();

        registry.enable("nvim", &first_tab);

        assert!(registry.has_claims(&first_tab));
        assert!(!registry.has_claims(&second_tab));
    }

    #[test]
    fn duplicate_same_source_claims_require_matching_disables() {
        let target = TerminalTarget::new("pane-1", "tab-1");
        let mut registry = PaneNavigationClaimRegistry::new();

        registry.enable("nvim", &target);
        registry.enable("nvim", &target);
        registry.disable("nvim", &target);
        assert!(registry.has_claims(&target));

        registry.disable("nvim", &target);
        assert!(!registry.has_claims(&target));
    }

    #[test]
    fn unmatched_disable_does_not_remove_another_source_claim() {
        let target = TerminalTarget::new("pane-1", "tab-1");
        let mut registry = PaneNavigationClaimRegistry::new();

        registry.enable("nvim", &target);
        registry.disable("tmux", &target);

        assert!(registry.has_claims(&target));
    }

    #[test]
    fn synchronization_prunes_claims_for_removed_tabs() {
        let removed = TerminalTarget::new("pane-1", "tab-1");
        let surviving = TerminalTarget::new("pane-1", "tab-2");
        let mut registry = PaneNavigationClaimRegistry::new();
        registry.enable("nvim", &removed);
        registry.enable("tmux", &surviving);

        registry.synchronize(&HashSet::from([surviving.clone()]), 0);

        assert!(!registry.has_claims(&removed));
        assert!(registry.has_claims(&surviving));
    }

    #[test]
    fn synchronization_clears_same_target_claims_after_workspace_replacement() {
        let target = TerminalTarget::new("pane-1", "tab-1");
        let mut registry = PaneNavigationClaimRegistry::new();
        registry.synchronize(&HashSet::from([target.clone()]), 0);
        registry.enable("nvim", &target);

        registry.synchronize(&HashSet::from([target.clone()]), 1);

        assert!(!registry.has_claims(&target));
    }

    #[test]
    fn a_passthrough_request_updates_claims_and_navigates_nowhere() {
        let target = TerminalTarget::new("pane-1", "tab-1");
        let mut registry = PaneNavigationClaimRegistry::new();

        let direction =
            registry.handle_request(&target, Some("enable"), Some("nvim"), Some("left"), Some(&target));
        assert_eq!(direction, None);
        assert!(registry.has_claims(&target));

        registry.handle_request(&target, Some("disable"), Some("nvim"), None, Some(&target));
        assert!(!registry.has_claims(&target));
    }

    #[test]
    fn a_navigation_request_moves_only_from_the_active_tab() {
        let target = TerminalTarget::new("pane-1", "tab-1");
        let other = TerminalTarget::new("pane-2", "tab-1");
        let mut registry = PaneNavigationClaimRegistry::new();

        assert_eq!(
            registry.handle_request(&target, None, None, Some("down"), Some(&target)),
            Some(NavigationDirection::Down)
        );
        assert_eq!(registry.handle_request(&target, None, None, Some("down"), Some(&other)), None);
        assert_eq!(registry.handle_request(&target, None, None, Some("diagonal"), Some(&target)), None);
        assert_eq!(registry.handle_request(&target, None, None, Some("down"), None), None);
    }
}
