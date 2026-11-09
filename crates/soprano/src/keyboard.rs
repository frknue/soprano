//! Keyboard routing (`KeybindingManager`'s event monitor): every key goes through the
//! [`KeybindingResolver`] before any content view sees it, with the focused content, the
//! navigation passthrough claims and the pane hints of the session. The resolver's timers
//! (prefix and pane-hint timeouts) run here.

use std::time::Instant;

use gpui::Keystroke;
use soprano_keys::{KeyEvent, Modifiers};

/// The resolver's view of a GPUI keystroke: `key` with Shift applied (AppKit's
/// `charactersIgnoringModifiers`), `base_key` without it.
pub fn key_event(keystroke: &Keystroke) -> KeyEvent {
    let modifiers = &keystroke.modifiers;
    let base = keystroke.key.as_str();
    let key = if base.chars().count() == 1 {
        let typed = keystroke
            .key_char
            .as_deref()
            .filter(|c| c.chars().count() == 1 && !c.chars().any(char::is_control))
            .filter(|_| !modifiers.control && !modifiers.platform);
        match typed {
            Some(typed) => typed.to_owned(),
            None if modifiers.shift => shifted(base),
            None => base.to_owned(),
        }
    } else {
        base.to_owned()
    };
    KeyEvent {
        key,
        base_key: Some(base.to_owned()),
        ctrl: modifiers.control,
        alt: modifiers.alt,
        shift: modifiers.shift,
        cmd: modifiers.platform,
        is_repeat: false,
    }
}

pub fn modifiers(modifiers: &gpui::Modifiers) -> Modifiers {
    Modifiers { ctrl: modifiers.control, alt: modifiers.alt, shift: modifiers.shift, cmd: modifiers.platform }
}

/// The character Shift makes of `key` on a US layout.
fn shifted(key: &str) -> String {
    let shifted = match key {
        "1" => "!",
        "2" => "@",
        "3" => "#",
        "4" => "$",
        "5" => "%",
        "6" => "^",
        "7" => "&",
        "8" => "*",
        "9" => "(",
        "0" => ")",
        "-" => "_",
        "=" => "+",
        "[" => "{",
        "]" => "}",
        "\\" => "|",
        ";" => ":",
        "'" => "\"",
        "," => "<",
        "." => ">",
        "/" => "?",
        "`" => "~",
        other => return other.to_uppercase(),
    };
    shifted.to_owned()
}

/// When the resolver next needs a tick, as a delay from now.
pub fn delay_until(deadline: Instant, now: Instant) -> std::time::Duration {
    deadline.saturating_duration_since(now)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stroke(source: &'static str) -> Keystroke {
        Keystroke::parse(source).unwrap_or_else(|_| panic!("keystroke {source}"))
    }

    #[test]
    fn shifted_letters_and_symbols_read_as_typed_with_the_base_key_kept() {
        let event = key_event(&stroke("cmd-shift-p"));
        assert_eq!(event.key, "P");
        assert_eq!(event.base_key.as_deref(), Some("p"));
        assert!(event.cmd && event.shift && !event.ctrl);

        let event = key_event(&stroke("cmd-shift-["));
        assert_eq!(event.key, "{");
        assert_eq!(event.base_key.as_deref(), Some("["));
    }

    #[test]
    fn named_keys_keep_their_names() {
        assert_eq!(key_event(&stroke("ctrl-shift-tab")).key, "tab");
        assert_eq!(key_event(&stroke("escape")).key, "escape");
        assert_eq!(key_event(&stroke("pageup")).key, "pageup");
    }

    #[test]
    fn control_chords_use_the_key_not_its_control_character() {
        let event = key_event(&stroke("ctrl-a"));
        assert_eq!(event.key, "a");
        assert!(event.ctrl);
    }
}
