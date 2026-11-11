//! The board's keyboard (`StatisticsViewController.handleKey`): plain keys while the keyboard
//! is anywhere on the board.

use gpui::Keystroke;
use soprano_agents::usage::{UsageMetric, UsagePeriod};

/// What a key does on the board.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyAction {
    /// Esc: back to the workspace.
    Dismiss,
    /// C / T: Cost / Tokens.
    Metric(UsageMetric),
    /// 1–5: 24h, 7d, 30d, 90d, All.
    Period(UsagePeriod),
}

/// The board shortcut `keystroke` stands for; `None` lets it through. ⌘, ⌃ and ⌥ make a chord,
/// which is never the board's.
pub fn key_action(keystroke: &Keystroke) -> Option<KeyAction> {
    let modifiers = &keystroke.modifiers;
    if modifiers.platform || modifiers.control || modifiers.alt {
        return None;
    }
    match keystroke.key.to_lowercase().as_str() {
        "escape" => Some(KeyAction::Dismiss),
        "c" => Some(KeyAction::Metric(UsageMetric::Cost)),
        "t" => Some(KeyAction::Metric(UsageMetric::Tokens)),
        key => {
            let index = key.parse::<usize>().ok()?.checked_sub(1)?;
            UsagePeriod::ALL.get(index).copied().map(KeyAction::Period)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(keystroke: &'static str) -> Option<KeyAction> {
        key_action(&Keystroke::parse(keystroke).expect("keystroke"))
    }

    #[test]
    fn c_and_t_switch_between_cost_and_tokens() {
        assert_eq!(action("c"), Some(KeyAction::Metric(UsageMetric::Cost)));
        assert_eq!(action("t"), Some(KeyAction::Metric(UsageMetric::Tokens)));
        assert_eq!(action("shift-t"), Some(KeyAction::Metric(UsageMetric::Tokens)));
    }

    #[test]
    fn one_to_five_pick_the_period() {
        assert_eq!(action("1"), Some(KeyAction::Period(UsagePeriod::Day)));
        assert_eq!(action("2"), Some(KeyAction::Period(UsagePeriod::Week)));
        assert_eq!(action("5"), Some(KeyAction::Period(UsagePeriod::All)));
        assert_eq!(action("0"), None);
        assert_eq!(action("6"), None);
    }

    #[test]
    fn escape_closes_and_chords_pass_through() {
        assert_eq!(action("escape"), Some(KeyAction::Dismiss));
        assert_eq!(action("cmd-c"), None);
        assert_eq!(action("ctrl-1"), None);
        assert_eq!(action("alt-t"), None);
        assert_eq!(action("x"), None);
    }
}
