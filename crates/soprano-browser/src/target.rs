//! App-side routing of `soprano browser` requests (`BrowserAutomationController`): which browser
//! tab a request drives, and the messages the app answers with when it cannot.

use soprano_types::TerminalTarget;

/// What target resolution needs to know about one pane's tabs.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PaneTabs {
    pub active_tab_id: Option<String>,
    /// Every tab in order: its id and whether it is a web browser.
    pub tabs: Vec<(String, bool)>,
}

impl PaneTabs {
    fn active_browser(&self) -> Option<&str> {
        let active = self.active_tab_id.as_deref()?;
        self.tabs.iter().find(|(id, is_browser)| id == active && *is_browser).map(|(id, _)| id.as_str())
    }

    fn first_browser(&self) -> Option<&str> {
        self.tabs.iter().find(|(_, is_browser)| *is_browser).map(|(id, _)| id.as_str())
    }
}

/// Commands the app answers by spawning a browser pane instead of driving an existing one.
pub fn is_open_command(command: &str) -> bool {
    matches!(command, "open" | "open-split" | "new")
}

/// Picks the browser tab a request drives. With `--pane`, that pane's active tab when it is a
/// browser, else its first browser tab. Otherwise the active pane's active tab when it is a
/// browser, else the first browser tab of the first pane (in layout order) that has one.
pub fn resolve_target(
    requested_pane_id: Option<&str>,
    active_pane_id: &str,
    ordered_leaf_ids: &[String],
    pane: impl Fn(&str) -> Option<PaneTabs>,
) -> Option<TerminalTarget> {
    if let Some(requested) = requested_pane_id {
        let tabs = pane(requested)?;
        let tab = tabs.active_browser().or_else(|| tabs.first_browser())?;
        return Some(TerminalTarget::new(requested, tab));
    }

    if let Some(tab) = pane(active_pane_id).as_ref().and_then(PaneTabs::active_browser) {
        return Some(TerminalTarget::new(active_pane_id, tab));
    }

    ordered_leaf_ids.iter().find_map(|pane_id| {
        let tabs = pane(pane_id)?;
        tabs.first_browser().map(|tab| TerminalTarget::new(pane_id.as_str(), tab))
    })
}

/// The answer when `resolve_target` finds nothing.
pub fn no_target_message(requested_pane_id: Option<&str>) -> String {
    match requested_pane_id {
        Some(pane_id) => format!("No browser tab exists in {pane_id}."),
        None => "No browser pane exists. Run `soprano browser open [url]` first.".to_string(),
    }
}

/// The answer when the target's view is not registered (not built yet, or already gone).
pub fn unavailable_message(target: &TerminalTarget) -> String {
    format!("Browser {} is not currently available.", target.pane_id)
}

/// The answer to `open` when no pane could be created.
pub const PANE_LIMIT_MESSAGE: &str = "Could not create a browser pane (pane limit reached).";

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn panes() -> HashMap<String, PaneTabs> {
        HashMap::from([
            (
                "pane-1".to_string(),
                PaneTabs { active_tab_id: Some("t1".into()), tabs: vec![("t1".into(), false)] },
            ),
            (
                "pane-2".to_string(),
                PaneTabs {
                    active_tab_id: Some("t2".into()),
                    tabs: vec![("t2".into(), false), ("b2".into(), true), ("b3".into(), true)],
                },
            ),
            (
                "pane-3".to_string(),
                PaneTabs {
                    active_tab_id: Some("b4".into()),
                    tabs: vec![("x".into(), true), ("b4".into(), true)],
                },
            ),
        ])
    }

    fn resolve(requested: Option<&str>, active: &str, order: &[&str]) -> Option<TerminalTarget> {
        let panes = panes();
        let order: Vec<String> = order.iter().map(|id| id.to_string()).collect();
        resolve_target(requested, active, &order, |id| panes.get(id).cloned())
    }

    #[test]
    fn a_requested_pane_prefers_its_active_browser_tab() {
        assert_eq!(resolve(Some("pane-3"), "pane-1", &[]), Some(TerminalTarget::new("pane-3", "b4")));
    }

    #[test]
    fn a_requested_pane_falls_back_to_its_first_browser_tab() {
        assert_eq!(resolve(Some("pane-2"), "pane-1", &[]), Some(TerminalTarget::new("pane-2", "b2")));
    }

    #[test]
    fn a_requested_pane_without_a_browser_or_unknown_pane_resolves_to_nothing() {
        assert_eq!(resolve(Some("pane-1"), "pane-3", &["pane-3"]), None);
        assert_eq!(resolve(Some("pane-9"), "pane-3", &["pane-3"]), None);
    }

    #[test]
    fn without_a_request_the_active_panes_active_browser_wins() {
        assert_eq!(resolve(None, "pane-3", &["pane-2", "pane-3"]), Some(TerminalTarget::new("pane-3", "b4")));
    }

    #[test]
    fn otherwise_the_first_browser_in_layout_order_is_used() {
        assert_eq!(
            resolve(None, "pane-1", &["pane-1", "pane-2", "pane-3"]),
            Some(TerminalTarget::new("pane-2", "b2"))
        );
        assert_eq!(resolve(None, "pane-2", &["pane-1"]), None);
    }

    #[test]
    fn messages_match_the_swift_app() {
        assert_eq!(no_target_message(Some("pane-8")), "No browser tab exists in pane-8.");
        assert_eq!(
            no_target_message(None),
            "No browser pane exists. Run `soprano browser open [url]` first."
        );
        assert_eq!(
            unavailable_message(&TerminalTarget::new("pane-2", "t")),
            "Browser pane-2 is not currently available."
        );
        assert!(is_open_command("open-split") && is_open_command("new") && !is_open_command("goto"));
    }
}
