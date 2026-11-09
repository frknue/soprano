//! Which physical keys the panels' ⌘ shortcuts are on each OS. On macOS `cmd` is ⌘ and
//! ⌥ is Option; on Linux and Windows `cmd` is Ctrl+Shift and `cmd+shift` is Ctrl+Shift+Alt
//! (the app-wide table). ⌥⌘ is Ctrl+Alt there and ⇧⌥⌘ Ctrl+Shift+Alt, so Copy Path
//! (⌥⌘C) and Copy Relative Path (⇧⌥⌘C) stay apart.

use gpui::Modifiers;

/// A shortcut as the Swift app spells it: ⌘ plus optional ⇧ and ⌥.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Chord {
    pub shift: bool,
    pub option: bool,
}

impl Chord {
    pub const CMD: Self = Self { shift: false, option: false };
    pub const CMD_SHIFT: Self = Self { shift: true, option: false };
    pub const CMD_OPTION: Self = Self { shift: false, option: true };
    pub const CMD_SHIFT_OPTION: Self = Self { shift: true, option: true };

    fn modifiers_on(self, mac: bool) -> Modifiers {
        if mac {
            return Modifiers { platform: true, shift: self.shift, alt: self.option, ..Modifiers::default() };
        }
        // Ctrl+Shift is ⌘ and ⇧ adds Alt; ⌥⌘ is Ctrl+Alt.
        let shift = self.shift || !self.option;
        Modifiers { control: true, shift, alt: self.shift || self.option, ..Modifiers::default() }
    }

    /// Whether `pressed` is exactly this chord (Fn and Caps Lock aside).
    pub fn matches(self, pressed: &Modifiers) -> bool {
        Self::matches_on(self, pressed, cfg!(target_os = "macos"))
    }

    fn matches_on(self, pressed: &Modifiers, mac: bool) -> bool {
        let wanted = self.modifiers_on(mac);
        pressed.control == wanted.control
            && pressed.alt == wanted.alt
            && pressed.shift == wanted.shift
            && pressed.platform == wanted.platform
    }

    /// The label menus show next to the item.
    pub fn label(self, key: &str) -> String {
        Self::label_on(self, key, cfg!(target_os = "macos"))
    }

    fn label_on(self, key: &str, mac: bool) -> String {
        if mac {
            let mut label = String::new();
            if self.shift {
                label.push('⇧');
            }
            if self.option {
                label.push('⌥');
            }
            label.push('⌘');
            label.push_str(key);
            return label;
        }
        let key = match key {
            "⌫" => "Backspace",
            other => other,
        };
        let modifiers = self.modifiers_on(false);
        let shift = if modifiers.shift { "Shift+" } else { "" };
        let alt = if modifiers.alt { "Alt+" } else { "" };
        format!("Ctrl+{shift}{alt}{key}")
    }
}

/// No modifiers held (Fn and Caps Lock aside): plain Return, Space, arrows.
pub fn is_plain(pressed: &Modifiers) -> bool {
    !(pressed.control || pressed.alt || pressed.shift || pressed.platform)
}

/// The "add to the selection" click modifier: ⌘ on macOS, Ctrl elsewhere.
pub fn is_toggle_click(pressed: &Modifiers) -> bool {
    if cfg!(target_os = "macos") { pressed.platform } else { pressed.control }
}

/// The ⌥-drag copy modifier: Option on macOS, Alt elsewhere.
pub fn is_copy_drag(pressed: &Modifiers) -> bool {
    pressed.alt
}

#[cfg(test)]
mod tests {
    use super::*;

    fn modifiers(control: bool, alt: bool, shift: bool, platform: bool) -> Modifiers {
        Modifiers { control, alt, shift, platform, function: false }
    }

    #[test]
    fn mac_chords_use_command_and_option() {
        assert!(Chord::CMD.matches_on(&modifiers(false, false, false, true), true));
        assert!(Chord::CMD_OPTION.matches_on(&modifiers(false, true, false, true), true));
        assert!(Chord::CMD_SHIFT_OPTION.matches_on(&modifiers(false, true, true, true), true));
        assert!(!Chord::CMD.matches_on(&modifiers(false, true, false, true), true));
        assert_eq!(Chord::CMD_SHIFT_OPTION.label_on("C", true), "⇧⌥⌘C");
    }

    #[test]
    fn elsewhere_command_is_ctrl_shift_shift_adds_alt_and_option_is_ctrl_alt() {
        assert!(Chord::CMD.matches_on(&modifiers(true, false, true, false), false));
        assert!(Chord::CMD_SHIFT.matches_on(&modifiers(true, true, true, false), false));
        assert!(Chord::CMD_OPTION.matches_on(&modifiers(true, true, false, false), false));
        assert!(Chord::CMD_SHIFT_OPTION.matches_on(&modifiers(true, true, true, false), false));
        assert!(!Chord::CMD_OPTION.matches_on(&modifiers(true, true, true, false), false));
        assert_eq!(Chord::CMD_OPTION.label_on("C", false), "Ctrl+Alt+C");
        assert!(!Chord::CMD.matches_on(&modifiers(true, false, false, false), false));
        assert_eq!(Chord::CMD.label_on("⌫", false), "Ctrl+Shift+Backspace");
        assert_eq!(Chord::CMD_SHIFT.label_on("Z", false), "Ctrl+Shift+Alt+Z");
    }
}
