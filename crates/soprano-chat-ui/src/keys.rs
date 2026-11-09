//! The chat's ⌘ chords across platforms: ⌘ on macOS, Ctrl+Shift on Linux and Windows
//! (`soprano_keys::Platform::binding_modifiers`), with their legends.

use gpui::Modifiers;
use soprano_keys::Platform;
use soprano_ui::keycaps::{KeyPlatform, chord_cap};

/// The physical modifiers of a binding's ⌘ (with optional Shift) on this platform.
fn command_modifiers(shift: bool) -> soprano_keys::Modifiers {
    Platform::current().binding_modifiers(false, true, shift)
}

/// Whether `modifiers` are exactly ⌘ (Ctrl+Shift off the Mac).
pub fn is_command(modifiers: &Modifiers) -> bool {
    let wanted = command_modifiers(false);
    modifiers.control == wanted.ctrl
        && modifiers.alt == wanted.alt
        && modifiers.shift == wanted.shift
        && modifiers.platform == wanted.cmd
}

/// Whether ⌘ is held, whatever else is (the composer's alternate send while the button shows).
pub fn holds_command(modifiers: &Modifiers) -> bool {
    let wanted = command_modifiers(false);
    (!wanted.cmd || modifiers.platform)
        && (!wanted.ctrl || modifiers.control)
        && (!wanted.shift || modifiers.shift)
}

/// Plain typing: no modifier but Shift.
pub fn is_plain(modifiers: &Modifiers) -> bool {
    !modifiers.control && !modifiers.alt && !modifiers.platform && !modifiers.function
}

/// "⌘-click" (Ctrl+Shift-click).
pub fn command_click() -> String {
    match KeyPlatform::current() {
        KeyPlatform::Mac => "⌘-click".into(),
        KeyPlatform::Other => "Ctrl+Shift-click".into(),
    }
}

/// "⌘↩" (Ctrl+Shift+Enter).
pub fn command_return() -> String {
    match KeyPlatform::current() {
        KeyPlatform::Mac => "⌘↩".into(),
        KeyPlatform::Other => chord_cap(false, true, false, "enter", KeyPlatform::Other),
    }
}

/// "⌘1" … "⌘9" in the model picker.
pub fn command_digit(digit: usize) -> String {
    chord_cap(false, true, false, &digit.to_string(), KeyPlatform::current())
}
