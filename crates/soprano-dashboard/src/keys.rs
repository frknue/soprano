//! The dashboard's keyboard (`AgentDashboardRootView.keyboardAction`): plain keys drive the
//! agent list and the detail view from anywhere inside the dashboard, so a click into the
//! conversation or terminal text to copy something never captures J/K.

use gpui::Keystroke;

/// How far one scrolling key moves the detail text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollAmount {
    Lines(i32),
    Pages(i32),
}

/// What a key does on the dashboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyAction {
    /// Esc: close without changing the active agent.
    Dismiss,
    /// J/K, ↓/↑: the next or previous agent.
    Move(i32),
    /// Return or Space: open the selected agent.
    Activate,
    /// Tab or R: into the reply field.
    FocusReply,
    /// ⇧Tab in the reply field: back to the agent list, keeping the draft.
    LeaveReply,
    /// ⇧J/⇧K, PgDn/PgUp.
    Scroll(ScrollAmount),
    /// ] and [: the next or previous prompt.
    JumpTurn(i32),
    /// O: the detailed work log.
    ToggleDetails,
    /// G: jump to the newest entry and follow it.
    FollowLatest,
    /// T: timeline ↔ terminal.
    ToggleTerminal,
}

/// The dashboard shortcut `keystroke` stands for; `None` lets it through. While the reply
/// field has the keyboard only Esc (close) and ⇧Tab (leave the field) are the dashboard's.
pub fn key_action(keystroke: &Keystroke, reply_focused: bool) -> Option<KeyAction> {
    let modifiers = &keystroke.modifiers;
    let key = keystroke.key.as_str();
    if reply_focused {
        return match key {
            "escape" => Some(KeyAction::Dismiss),
            "tab" if modifiers.shift && !modifiers.control && !modifiers.alt && !modifiers.platform => {
                Some(KeyAction::LeaveReply)
            }
            _ => None,
        };
    }
    // As Swift: only ⌘, ⌃ and ⌥ make a chord. Fn stays allowed, which keypad Enter and fn+Return
    // carry.
    if modifiers.platform || modifiers.control || modifiers.alt {
        return None;
    }
    let shifted = modifiers.shift;
    match key {
        "escape" => return Some(KeyAction::Dismiss),
        "down" => return Some(KeyAction::Move(1)),
        "up" => return Some(KeyAction::Move(-1)),
        "enter" => return Some(KeyAction::Activate),
        // ⇧Tab leaves the reply field instead; on the list it does nothing.
        "tab" => return (!shifted).then_some(KeyAction::FocusReply),
        "pagedown" => return Some(KeyAction::Scroll(ScrollAmount::Pages(1))),
        "pageup" => return Some(KeyAction::Scroll(ScrollAmount::Pages(-1))),
        _ => {}
    }
    // Shift turns J/K from moving between agents into scrolling the text.
    match key.to_lowercase().as_str() {
        "j" => Some(if shifted { KeyAction::Scroll(ScrollAmount::Lines(1)) } else { KeyAction::Move(1) }),
        "k" => Some(if shifted { KeyAction::Scroll(ScrollAmount::Lines(-1)) } else { KeyAction::Move(-1) }),
        "r" => Some(KeyAction::FocusReply),
        "space" | " " => Some(KeyAction::Activate),
        "]" => Some(KeyAction::JumpTurn(1)),
        "[" => Some(KeyAction::JumpTurn(-1)),
        "o" => Some(KeyAction::ToggleDetails),
        "g" => Some(KeyAction::FollowLatest),
        "t" => Some(KeyAction::ToggleTerminal),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(keystroke: &'static str, reply_focused: bool) -> Option<KeyAction> {
        key_action(&Keystroke::parse(keystroke).expect("keystroke"), reply_focused)
    }

    #[test]
    fn j_and_k_and_the_arrows_move_between_agents() {
        assert_eq!(action("j", false), Some(KeyAction::Move(1)));
        assert_eq!(action("k", false), Some(KeyAction::Move(-1)));
        assert_eq!(action("down", false), Some(KeyAction::Move(1)));
        assert_eq!(action("up", false), Some(KeyAction::Move(-1)));
    }

    #[test]
    fn shift_turns_j_and_k_into_scrolling_and_the_page_keys_scroll_a_page() {
        assert_eq!(action("shift-j", false), Some(KeyAction::Scroll(ScrollAmount::Lines(1))));
        assert_eq!(action("shift-k", false), Some(KeyAction::Scroll(ScrollAmount::Lines(-1))));
        assert_eq!(action("pagedown", false), Some(KeyAction::Scroll(ScrollAmount::Pages(1))));
        assert_eq!(action("pageup", false), Some(KeyAction::Scroll(ScrollAmount::Pages(-1))));
    }

    #[test]
    fn return_and_space_open_the_agent_and_escape_closes_the_dashboard() {
        assert_eq!(action("enter", false), Some(KeyAction::Activate));
        assert_eq!(action("space", false), Some(KeyAction::Activate));
        assert_eq!(action("escape", false), Some(KeyAction::Dismiss));
    }

    #[test]
    fn tab_and_r_focus_the_reply_and_shift_tab_leaves_it() {
        assert_eq!(action("tab", false), Some(KeyAction::FocusReply));
        assert_eq!(action("r", false), Some(KeyAction::FocusReply));
        assert_eq!(action("shift-tab", false), None);
        assert_eq!(action("shift-tab", true), Some(KeyAction::LeaveReply));
    }

    #[test]
    fn keypad_enter_and_fn_return_open_the_agent() {
        assert_eq!(action("fn-enter", false), Some(KeyAction::Activate));
        assert_eq!(action("fn-j", false), Some(KeyAction::Move(1)));
    }

    #[test]
    fn the_detail_keys_jump_prompts_toggle_details_follow_and_switch_to_the_terminal() {
        assert_eq!(action("]", false), Some(KeyAction::JumpTurn(1)));
        assert_eq!(action("[", false), Some(KeyAction::JumpTurn(-1)));
        assert_eq!(action("o", false), Some(KeyAction::ToggleDetails));
        assert_eq!(action("g", false), Some(KeyAction::FollowLatest));
        assert_eq!(action("t", false), Some(KeyAction::ToggleTerminal));
    }

    #[test]
    fn typing_in_the_reply_field_keeps_every_key_but_escape_and_shift_tab() {
        for key in ["j", "k", "r", "t", "enter", "space", "tab", "down", "]"] {
            assert_eq!(action(key, true), None, "{key}");
        }
        assert_eq!(action("escape", true), Some(KeyAction::Dismiss));
    }

    #[test]
    fn chords_with_command_control_or_option_are_left_to_the_app() {
        for key in ["cmd-j", "ctrl-k", "alt-t", "cmd-escape", "ctrl-enter"] {
            assert_eq!(action(key, false), None, "{key}");
        }
    }
}
