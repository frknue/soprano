//! Command-line bridge used by nested terminal multiplexers and editors to bubble pane navigation
//! out to the Soprano instance that owns the terminal (`navigate-pane`, `navigation-passthrough`).
//! The app-side registry of passthrough claims lives in `soprano-keys`.

use std::collections::HashMap;
use std::process::{Command, Stdio};

use crate::protocol::{PassthroughMode, Request};
use soprano_types::NavigationDirection;

pub const NAVIGATE_COMMAND: &str = "navigate-pane";
pub const PASSTHROUGH_COMMAND: &str = "navigation-passthrough";

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
}
