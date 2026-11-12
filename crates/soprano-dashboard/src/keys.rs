//! The dashboard's keyboard: plain keys drive the inbox and the conversation from anywhere
//! outside its text fields, so a click into the conversation to copy something never captures
//! J/K; the composer and the search field keep every key but the few that leave them.

use gpui::Keystroke;
use soprano_chat_ui::keys::{is_command, is_command_shift};

/// How far one scrolling key moves the conversation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollAmount {
    Lines(i32),
    Pages(i32),
}

/// Where the keyboard is inside the dashboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyFocus {
    /// The inbox, the conversation, or nothing in particular.
    List,
    Composer,
    Search,
}

/// What a key does on the dashboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyAction {
    /// Esc on the list (a draft is given up first), ⌘W anywhere: close the window.
    Dismiss,
    /// J/K, ↓/↑: the next or previous thread.
    Move(i32),
    /// Return or Space: open the selected thread in its window.
    Activate,
    /// Tab or R: into the composer.
    FocusComposer,
    /// Esc or ⇧Tab in the composer, Return in the search field: back to the list, keeping
    /// what was typed.
    FocusList,
    /// `/`: into the search field.
    FocusSearch,
    /// Esc in the search field: drop the search and go back to the list.
    ClearSearch,
    /// N on the list, ⌘N anywhere: a new thread.
    NewThread,
    /// ⇧⌘M anywhere: the models the thread's agent offers.
    PickModel,
    /// ⇧⌘E anywhere: how hard its model thinks.
    PickThinking,
    /// ⇧J/⇧K, PgDn/PgUp.
    Scroll(ScrollAmount),
    /// ] and [: the next or previous prompt.
    JumpTurn(i32),
    /// O: the detailed work log.
    ToggleDetails,
    /// G: jump to the newest entry and follow it.
    FollowLatest,
}

/// The dashboard shortcut `keystroke` stands for; `None` lets it through.
pub fn key_action(keystroke: &Keystroke, focus: KeyFocus) -> Option<KeyAction> {
    let modifiers = &keystroke.modifiers;
    let key = keystroke.key.as_str();
    if is_command(modifiers) {
        return match key.to_lowercase().as_str() {
            "n" => Some(KeyAction::NewThread),
            "w" => Some(KeyAction::Dismiss),
            _ => None,
        };
    }
    if is_command_shift(modifiers) {
        return match key.to_lowercase().as_str() {
            "m" => Some(KeyAction::PickModel),
            "e" => Some(KeyAction::PickThinking),
            _ => None,
        };
    }
    // Only ⌘, ⌃ and ⌥ make a chord. Fn stays allowed, which keypad Enter and fn+Return carry.
    if modifiers.platform || modifiers.control || modifiers.alt {
        return None;
    }
    let shifted = modifiers.shift;
    match focus {
        KeyFocus::Composer => {
            return match key {
                "escape" => Some(KeyAction::FocusList),
                "tab" if shifted => Some(KeyAction::FocusList),
                _ => None,
            };
        }
        KeyFocus::Search => {
            return match key {
                "escape" => Some(KeyAction::ClearSearch),
                "enter" => Some(KeyAction::FocusList),
                "down" => Some(KeyAction::Move(1)),
                "up" => Some(KeyAction::Move(-1)),
                _ => None,
            };
        }
        KeyFocus::List => {}
    }
    match key {
        "escape" => return Some(KeyAction::Dismiss),
        "down" => return Some(KeyAction::Move(1)),
        "up" => return Some(KeyAction::Move(-1)),
        "enter" => return Some(KeyAction::Activate),
        // ⇧Tab leaves the composer instead; on the list it does nothing.
        "tab" => return (!shifted).then_some(KeyAction::FocusComposer),
        "pagedown" => return Some(KeyAction::Scroll(ScrollAmount::Pages(1))),
        "pageup" => return Some(KeyAction::Scroll(ScrollAmount::Pages(-1))),
        _ => {}
    }
    // Shift turns J/K from moving between threads into scrolling the conversation.
    match key.to_lowercase().as_str() {
        "j" => Some(if shifted { KeyAction::Scroll(ScrollAmount::Lines(1)) } else { KeyAction::Move(1) }),
        "k" => Some(if shifted { KeyAction::Scroll(ScrollAmount::Lines(-1)) } else { KeyAction::Move(-1) }),
        "r" => Some(KeyAction::FocusComposer),
        "n" => Some(KeyAction::NewThread),
        "/" => Some(KeyAction::FocusSearch),
        "space" | " " => Some(KeyAction::Activate),
        "]" => Some(KeyAction::JumpTurn(1)),
        "[" => Some(KeyAction::JumpTurn(-1)),
        "o" => Some(KeyAction::ToggleDetails),
        "g" => Some(KeyAction::FollowLatest),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(keystroke: &'static str, focus: KeyFocus) -> Option<KeyAction> {
        key_action(&Keystroke::parse(keystroke).expect("keystroke"), focus)
    }

    fn on_list(keystroke: &'static str) -> Option<KeyAction> {
        action(keystroke, KeyFocus::List)
    }

    #[test]
    fn j_and_k_and_the_arrows_move_between_threads() {
        assert_eq!(on_list("j"), Some(KeyAction::Move(1)));
        assert_eq!(on_list("k"), Some(KeyAction::Move(-1)));
        assert_eq!(on_list("down"), Some(KeyAction::Move(1)));
        assert_eq!(on_list("up"), Some(KeyAction::Move(-1)));
    }

    #[test]
    fn shift_turns_j_and_k_into_scrolling_and_the_page_keys_scroll_a_page() {
        assert_eq!(on_list("shift-j"), Some(KeyAction::Scroll(ScrollAmount::Lines(1))));
        assert_eq!(on_list("shift-k"), Some(KeyAction::Scroll(ScrollAmount::Lines(-1))));
        assert_eq!(on_list("pagedown"), Some(KeyAction::Scroll(ScrollAmount::Pages(1))));
        assert_eq!(on_list("pageup"), Some(KeyAction::Scroll(ScrollAmount::Pages(-1))));
    }

    #[test]
    fn return_and_space_open_the_thread_and_escape_closes_the_window() {
        assert_eq!(on_list("enter"), Some(KeyAction::Activate));
        assert_eq!(on_list("space"), Some(KeyAction::Activate));
        assert_eq!(on_list("fn-enter"), Some(KeyAction::Activate));
        assert_eq!(on_list("escape"), Some(KeyAction::Dismiss));
    }

    #[test]
    fn tab_and_r_focus_the_composer_and_escape_or_shift_tab_leave_it() {
        assert_eq!(on_list("tab"), Some(KeyAction::FocusComposer));
        assert_eq!(on_list("r"), Some(KeyAction::FocusComposer));
        assert_eq!(on_list("shift-tab"), None);
        assert_eq!(action("shift-tab", KeyFocus::Composer), Some(KeyAction::FocusList));
        assert_eq!(action("escape", KeyFocus::Composer), Some(KeyAction::FocusList));
    }

    #[test]
    fn the_conversation_keys_jump_prompts_toggle_details_and_follow() {
        assert_eq!(on_list("]"), Some(KeyAction::JumpTurn(1)));
        assert_eq!(on_list("["), Some(KeyAction::JumpTurn(-1)));
        assert_eq!(on_list("o"), Some(KeyAction::ToggleDetails));
        assert_eq!(on_list("g"), Some(KeyAction::FollowLatest));
        // The terminal view is gone, and T with it.
        assert_eq!(on_list("t"), None);
    }

    #[test]
    fn n_starts_a_thread_and_slash_searches() {
        assert_eq!(on_list("n"), Some(KeyAction::NewThread));
        assert_eq!(on_list("/"), Some(KeyAction::FocusSearch));
    }

    #[test]
    fn typing_in_the_composer_keeps_every_key_but_escape_and_shift_tab() {
        for key in ["j", "k", "r", "n", "/", "enter", "space", "tab", "down", "]"] {
            assert_eq!(action(key, KeyFocus::Composer), None, "{key}");
        }
    }

    #[test]
    fn the_search_field_moves_the_selection_and_returns_to_the_list() {
        for key in ["j", "k", "n", "/", "space", "tab"] {
            assert_eq!(action(key, KeyFocus::Search), None, "{key}");
        }
        assert_eq!(action("down", KeyFocus::Search), Some(KeyAction::Move(1)));
        assert_eq!(action("up", KeyFocus::Search), Some(KeyAction::Move(-1)));
        assert_eq!(action("enter", KeyFocus::Search), Some(KeyAction::FocusList));
        assert_eq!(action("escape", KeyFocus::Search), Some(KeyAction::ClearSearch));
    }

    #[test]
    fn the_command_chords_start_a_thread_and_close_the_window_from_anywhere() {
        let (new, close) = match soprano_ui::keycaps::KeyPlatform::current() {
            soprano_ui::keycaps::KeyPlatform::Mac => ("cmd-n", "cmd-w"),
            soprano_ui::keycaps::KeyPlatform::Other => ("ctrl-shift-n", "ctrl-shift-w"),
        };
        for focus in [KeyFocus::List, KeyFocus::Composer, KeyFocus::Search] {
            assert_eq!(action(new, focus), Some(KeyAction::NewThread));
            assert_eq!(action(close, focus), Some(KeyAction::Dismiss));
        }
    }

    #[test]
    fn the_shifted_command_chords_pick_the_threads_model_and_thinking_level_from_anywhere() {
        let (model, thinking) = match soprano_ui::keycaps::KeyPlatform::current() {
            soprano_ui::keycaps::KeyPlatform::Mac => ("cmd-shift-m", "cmd-shift-e"),
            soprano_ui::keycaps::KeyPlatform::Other => ("ctrl-shift-alt-m", "ctrl-shift-alt-e"),
        };
        for focus in [KeyFocus::List, KeyFocus::Composer, KeyFocus::Search] {
            assert_eq!(action(model, focus), Some(KeyAction::PickModel));
            assert_eq!(action(thinking, focus), Some(KeyAction::PickThinking));
        }
    }

    #[test]
    fn other_chords_with_command_control_or_option_are_left_to_the_app() {
        for key in ["cmd-j", "ctrl-k", "alt-o", "cmd-escape", "ctrl-enter", "cmd-shift-d"] {
            assert_eq!(on_list(key), None, "{key}");
        }
    }
}
