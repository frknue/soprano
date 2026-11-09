//! Soprano's chords as GPUI keystrokes. On macOS `cmd` is ⌘; on Linux and Windows a ⌘ chord
//! is Ctrl+Shift, ⇧⌘ is Ctrl+Shift+Alt and ⌃⌘ is Ctrl+Alt (`soprano_keys::Platform`). Plain
//! text editing (copy, paste, undo, select all) uses each platform's own convention, GPUI's
//! `secondary` modifier: ⌘ on macOS, Ctrl elsewhere.

use std::rc::Rc;

use gpui::{Action, App, KeyBinding, KeyBindingContextPredicate};
use soprano_keys::Platform;

/// A binding of `keystrokes` (GPUI syntax; `secondary-` is ⌘ on macOS, Ctrl elsewhere) to
/// `action` in key context `context`; `None` when the keystrokes do not parse.
pub fn bind(keystrokes: &str, action: Box<dyn Action>, context: &str, cx: &App) -> Option<KeyBinding> {
    let predicate = KeyBindingContextPredicate::parse(context).ok().map(Rc::new);
    KeyBinding::load(keystrokes, action, predicate, false, None, cx).ok()
}

/// The GPUI keystroke for a Soprano binding of `key` with ⌃ (`ctrl`), ⌘ (`meta`) and ⇧.
pub fn chord(key: &str, ctrl: bool, meta: bool, shift: bool) -> String {
    let modifiers = Platform::current().binding_modifiers(ctrl, meta, shift);
    let mut parts: Vec<&str> = Vec::new();
    if modifiers.ctrl {
        parts.push("ctrl");
    }
    if modifiers.alt {
        parts.push("alt");
    }
    if modifiers.shift {
        parts.push("shift");
    }
    if modifiers.cmd {
        parts.push("cmd");
    }
    parts.push(key);
    parts.join("-")
}

/// ⌘`key`.
pub fn command(key: &str) -> String {
    chord(key, false, true, false)
}

/// ⇧⌘`key`.
pub fn shift_command(key: &str) -> String {
    chord(key, false, true, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_chords_follow_the_platform_mapping() {
        if cfg!(target_os = "macos") {
            assert_eq!(command("s"), "cmd-s");
            assert_eq!(shift_command("g"), "shift-cmd-g");
        } else {
            assert_eq!(command("s"), "ctrl-shift-s");
            assert_eq!(shift_command("g"), "ctrl-alt-shift-g");
        }
    }
}
