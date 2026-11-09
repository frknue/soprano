//! Pane hints: every pane of the session gets a Vimium-style label (one letter, or two once
//! the letters run out); ⌃⇧ plus the label focuses that pane (Alt+Shift on Linux/Windows, see
//! [`crate::Platform::is_pane_shortcut_chord`]).

/// A pane's hint label, in sidebar order (the model's `pane_shortcut_assignments`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct PaneHintAssignment {
    pub key: String,
    pub pane_id: String,
}

impl PaneHintAssignment {
    pub fn new(key: impl Into<String>, pane_id: impl Into<String>) -> Self {
        PaneHintAssignment { key: key.into(), pane_id: pane_id.into() }
    }
}

/// What a pane hint letter does, given the letters typed before it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PaneHintStep {
    /// No hint goes on with it: the key does what it would anyway.
    PassThrough,
    /// It starts or continues a longer hint, typed so far.
    Pending(String),
    /// It completes the hint of this pane.
    Focus(String),
}

/// The step `key` takes after `typed`. While a terminal program claims the control keys
/// (navigation passthrough) hints are off and the key is the terminal's.
pub fn pane_hint_step(
    typed: &str,
    key: &str,
    terminal_claims_control_keys: bool,
    assignments: &[PaneHintAssignment],
) -> PaneHintStep {
    if terminal_claims_control_keys || key.chars().count() != 1 {
        return PaneHintStep::PassThrough;
    }
    let candidate = format!("{typed}{}", key.to_lowercase());
    if let Some(assignment) = assignments.iter().find(|assignment| assignment.key == candidate) {
        return PaneHintStep::Focus(assignment.pane_id.clone());
    }
    if assignments.iter().any(|assignment| assignment.key.starts_with(&candidate)) {
        PaneHintStep::Pending(candidate)
    } else {
        PaneHintStep::PassThrough
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claimed_terminal_control_keys_bypass_pane_hints() {
        let step = pane_hint_step("", "d", true, &[PaneHintAssignment::new("d", "pane-1")]);
        assert_eq!(step, PaneHintStep::PassThrough);
    }

    #[test]
    fn unclaimed_control_shift_keys_activate_pane_hints() {
        let step = pane_hint_step("", "D", false, &[PaneHintAssignment::new("d", "pane-1")]);
        assert_eq!(step, PaneHintStep::Focus("pane-1".into()));
    }

    #[test]
    fn a_two_letter_hint_waits_for_its_second_letter_and_anything_else_falls_through() {
        let assignments = [
            PaneHintAssignment::new("b", "pane-1"),
            PaneHintAssignment::new("zb", "pane-2"),
            PaneHintAssignment::new("zd", "pane-3"),
        ];
        let step = |typed: &str, key: &str| pane_hint_step(typed, key, false, &assignments);
        assert_eq!(step("", "z"), PaneHintStep::Pending("z".into()));
        assert_eq!(step("z", "d"), PaneHintStep::Focus("pane-3".into()));
        assert_eq!(step("z", "b"), PaneHintStep::Focus("pane-2".into()));
        // A letter that continues no hint, or one no hint starts with, is the terminal's again.
        assert_eq!(step("z", "x"), PaneHintStep::PassThrough);
        assert_eq!(step("", "x"), PaneHintStep::PassThrough);
        assert_eq!(step("", "b"), PaneHintStep::Focus("pane-1".into()));
    }

    #[test]
    fn a_hint_letter_selects_its_pane_and_an_unassigned_letter_does_not() {
        let assignments = [
            PaneHintAssignment::new("b", "pane-0"),
            PaneHintAssignment::new("d", "pane-1"),
            PaneHintAssignment::new("e", "pane-2"),
        ];
        let focus = |key: &str| match pane_hint_step("", key, false, &assignments) {
            PaneHintStep::Focus(pane_id) => Some(pane_id),
            _ => None,
        };
        assert_eq!(focus("d").as_deref(), Some("pane-1"));
        assert_eq!(focus("E").as_deref(), Some("pane-2"));
        assert_eq!(focus("a"), None);
        // Named keys are more than one character and never hint.
        assert_eq!(pane_hint_step("", "tab", false, &assignments), PaneHintStep::PassThrough);
    }
}
