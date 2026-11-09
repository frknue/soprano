//! Command-line bridge used by nested terminal multiplexers and editors to bubble pane navigation
//! out to the Soprano instance that owns the terminal (`navigate-pane`, `navigation-passthrough`),
//! plus the app-side registry of passthrough claims.

use std::collections::{HashMap, HashSet};
use std::process::{Command, Stdio};

use crate::protocol::{NavigationDirection, PassthroughMode, Request};

pub const NAVIGATE_COMMAND: &str = "navigate-pane";
pub const PASSTHROUGH_COMMAND: &str = "navigation-passthrough";

/// A terminal tab in a pane: the exact target a CLI call came from.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TerminalTarget {
    pub pane_id: String,
    pub tab_id: String,
}

impl TerminalTarget {
    pub fn new(pane_id: impl Into<String>, tab_id: impl Into<String>) -> Self {
        Self { pane_id: pane_id.into(), tab_id: tab_id.into() }
    }
}

/// Builds the request for `navigate-pane <direction>` or `navigation-passthrough enable|disable
/// <source>` (Swift `notificationEnvelope`). `None` without the terminal identity
/// (`SOPRANO_APP_PID`, `SOPRANO_PANE_ID`, `SOPRANO_TAB_ID`) or with invalid arguments.
pub fn navigation_request(arguments: &[String], environment: &HashMap<String, String>) -> Option<Request> {
    let command = arguments.get(1)?;
    environment.get("SOPRANO_APP_PID").filter(|v| !v.is_empty())?;
    let pane_id = environment.get("SOPRANO_PANE_ID").filter(|v| !v.is_empty())?.clone();
    let tab_id = environment.get("SOPRANO_TAB_ID").filter(|v| !v.is_empty())?.clone();
    match command.as_str() {
        NAVIGATE_COMMAND => {
            let direction = NavigationDirection::from_raw(arguments.get(2)?)?;
            Some(Request::NavigatePane { pane_id, tab_id, direction })
        }
        PASSTHROUGH_COMMAND => {
            let mode = match arguments.get(2)?.as_str() {
                "enable" => PassthroughMode::Enable,
                "disable" => PassthroughMode::Disable,
                _ => return None,
            };
            let source = arguments.get(3).filter(|s| !s.is_empty())?.clone();
            Some(Request::NavigationPassthrough { pane_id, tab_id, mode, source })
        }
        _ => None,
    }
}

/// Handles `navigate-pane`/`navigation-passthrough`; `false` when `arguments` name neither.
/// Invalid or out-of-terminal calls are still claimed (and do nothing). A navigation inside tmux
/// moves between tmux panes first (`tmux_navigator`), reaching Soprano only at a tmux boundary.
pub fn handle(
    arguments: &[String],
    environment: &HashMap<String, String>,
    tmux_navigator: impl FnOnce(NavigationDirection, &HashMap<String, String>) -> bool,
    post: impl FnOnce(&Request),
) -> bool {
    let Some(command) = arguments.get(1) else { return false };
    match command.as_str() {
        NAVIGATE_COMMAND => {
            let Some(direction) = arguments.get(2).and_then(|raw| NavigationDirection::from_raw(raw)) else {
                return true;
            };
            let Some(request) = navigation_request(arguments, environment) else { return true };
            if tmux_navigator(direction, environment) {
                return true;
            }
            post(&request);
            true
        }
        PASSTHROUGH_COMMAND => {
            if let Some(request) = navigation_request(arguments, environment) {
                post(&request);
            }
            true
        }
        _ => false,
    }
}

/// If the command originated inside tmux, navigate an adjacent tmux pane first. Returning false
/// at a tmux boundary lets the request continue to the outer Soprano layout.
pub fn navigate_within_tmux(direction: NavigationDirection, environment: &HashMap<String, String>) -> bool {
    if environment.get("TMUX").is_none_or(|v| v.is_empty()) {
        return false;
    }
    let pane_id = match environment.get("TMUX_PANE") {
        Some(pane) => pane.clone(),
        None => run_tmux(&["display-message", "-p", "#{pane_id}"], environment).1,
    };
    if pane_id.is_empty() {
        return false;
    }
    let format = format!("#{{pane_at_{}}}", tmux_boundary_name(direction));
    let (succeeded, output) = run_tmux(&["display-message", "-p", "-t", &pane_id, &format], environment);
    if !succeeded || output != "0" {
        return false;
    }
    run_tmux(&["select-pane", "-t", &pane_id, tmux_select_flag(direction)], environment).0
}

fn tmux_boundary_name(direction: NavigationDirection) -> &'static str {
    match direction {
        NavigationDirection::Left => "left",
        NavigationDirection::Right => "right",
        NavigationDirection::Up => "top",
        NavigationDirection::Down => "bottom",
    }
}

fn tmux_select_flag(direction: NavigationDirection) -> &'static str {
    match direction {
        NavigationDirection::Left => "-L",
        NavigationDirection::Right => "-R",
        NavigationDirection::Up => "-U",
        NavigationDirection::Down => "-D",
    }
}

/// Runs `tmux` (looked up on the caller's `PATH`) with exactly the caller's environment.
fn run_tmux(arguments: &[&str], environment: &HashMap<String, String>) -> (bool, String) {
    let output = Command::new("tmux")
        .args(arguments)
        .env_clear()
        .envs(environment)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    match output {
        Ok(output) => (output.status.success(), String::from_utf8_lossy(&output.stdout).trim().to_string()),
        Err(_) => (false, String::new()),
    }
}

/// Which terminals asked (through `navigation-passthrough enable <source>`) to receive the pane
/// navigation chords themselves. Claims count per source, so nested enables need matching
/// disables.
#[derive(Clone, Debug, Default)]
pub struct PaneNavigationClaimRegistry {
    counts_by_target: HashMap<TerminalTarget, HashMap<String, usize>>,
    workspace_restore_generation: Option<u64>,
}

impl PaneNavigationClaimRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn enable(&mut self, source: &str, target: &TerminalTarget) {
        *self.counts_by_target.entry(target.clone()).or_default().entry(source.to_string()).or_default() += 1;
    }

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

    pub fn has_claims(&self, target: &TerminalTarget) -> bool {
        self.counts_by_target.get(target).is_some_and(|sources| !sources.is_empty())
    }

    /// Drops claims of tabs that no longer exist; a restored (replaced) workspace may reuse the
    /// same ids, so a new restore generation drops every claim.
    pub fn synchronize(
        &mut self,
        valid_targets: &HashSet<TerminalTarget>,
        workspace_restore_generation: u64,
    ) {
        if self.workspace_restore_generation.is_some_and(|previous| previous != workspace_restore_generation)
        {
            self.counts_by_target.clear();
        } else {
            self.counts_by_target.retain(|target, _| valid_targets.contains(target));
        }
        self.workspace_restore_generation = Some(workspace_restore_generation);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn navigation_and_passthrough_requests_carry_the_exact_terminal_target() {
        let environment =
            env(&[("SOPRANO_APP_PID", "4242"), ("SOPRANO_PANE_ID", "pane-1"), ("SOPRANO_TAB_ID", "tab-2")]);
        assert_eq!(
            navigation_request(&strings(&["soprano", "navigate-pane", "left"]), &environment),
            Some(Request::NavigatePane {
                pane_id: "pane-1".into(),
                tab_id: "tab-2".into(),
                direction: NavigationDirection::Left
            })
        );
        assert_eq!(
            navigation_request(
                &strings(&["soprano", "navigation-passthrough", "enable", "nvim"]),
                &environment
            ),
            Some(Request::NavigationPassthrough {
                pane_id: "pane-1".into(),
                tab_id: "tab-2".into(),
                mode: PassthroughMode::Enable,
                source: "nvim".into()
            })
        );
    }

    #[test]
    fn navigation_without_a_process_or_terminal_identity_builds_no_request() {
        assert_eq!(
            navigation_request(
                &strings(&["soprano", "navigate-pane", "left"]),
                &env(&[("SOPRANO_APP_PID", "4242"), ("SOPRANO_PANE_ID", "pane-1")])
            ),
            None
        );
        assert_eq!(
            navigation_request(
                &strings(&["soprano", "navigation-passthrough", "enable", "nvim"]),
                &env(&[("SOPRANO_PANE_ID", "pane-1"), ("SOPRANO_TAB_ID", "tab-2")])
            ),
            None
        );
    }

    #[test]
    fn navigation_with_missing_identity_does_not_invoke_tmux() {
        let mut tmux_calls = 0;
        let mut posts = 0;
        let handled = handle(
            &strings(&["soprano", "navigate-pane", "left"]),
            &env(&[("TMUX", "/tmp/tmux-123/default,1,0")]),
            |_, _| {
                tmux_calls += 1;
                false
            },
            |_| posts += 1,
        );
        assert!(handled);
        assert_eq!(tmux_calls, 0);
        assert_eq!(posts, 0);
    }

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
}
