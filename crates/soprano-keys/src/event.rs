//! Key events as the resolver sees them, and the per-OS keyboard rule.
//!
//! The Swift app matched `NSEvent`s directly. Here the host (GPUI) translates its keystrokes into
//! [`KeyEvent`], and [`Platform`] decides which physical modifiers a binding's `ctrl`/`meta`/`shift`
//! fields stand for.

use soprano_types::KeyBinding;

/// The keyboard convention the resolver follows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Platform {
    /// `cmd` is the Command key; Option is never part of a binding and is ignored when matching,
    /// as `NSEvent` matching in the Swift app ignored it.
    MacOs,
    /// `cmd` means Ctrl+Shift (the terminal-emulator convention), `cmd`+`shift` means
    /// Ctrl+Shift+Alt, `ctrl`+`cmd` means Ctrl+Alt and `ctrl`+`cmd`+`shift` Ctrl+Shift+Alt.
    /// Plain `ctrl` chords stay Ctrl. Super is never part of a binding and is ignored.
    Linux,
    /// Same rule as [`Platform::Linux`].
    Windows,
}

impl Platform {
    /// The platform this binary was built for.
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Platform::MacOs
        } else if cfg!(target_os = "windows") {
            Platform::Windows
        } else {
            Platform::Linux
        }
    }

    /// The physical modifiers a binding with these logical flags needs on this platform.
    pub fn binding_modifiers(self, ctrl: bool, meta: bool, shift: bool) -> Modifiers {
        match self {
            Platform::MacOs => Modifiers { ctrl, alt: false, shift, cmd: meta },
            Platform::Linux | Platform::Windows => {
                if !meta {
                    return Modifiers { ctrl, alt: false, shift, cmd: false };
                }
                match (ctrl, shift) {
                    (false, false) => Modifiers { ctrl: true, alt: false, shift: true, cmd: false },
                    (false, true) | (true, true) => {
                        Modifiers { ctrl: true, alt: true, shift: true, cmd: false }
                    }
                    (true, false) => Modifiers { ctrl: true, alt: true, shift: false, cmd: false },
                }
            }
        }
    }

    /// Whether this platform presses Shift for `binding` although the binding itself has no
    /// Shift (`cmd` → Ctrl+Shift). The binding's key is then the unshifted key: ⌘1 is
    /// Ctrl+Shift+1, which reports `!` with Shift applied.
    pub fn adds_shift(self, binding: &KeyBinding) -> bool {
        self != Platform::MacOs && binding.meta == Some(true) && binding.ctrl != Some(true)
    }

    /// Whether `modifiers` are the pane-hint chord: ⌃⇧ on macOS. On Linux/Windows ⌃⇧ is how
    /// `cmd` bindings are pressed (⌘D = Ctrl+Shift+D), so pane hints use Alt+Shift there.
    pub fn is_pane_shortcut_chord(self, modifiers: Modifiers) -> bool {
        match self {
            Platform::MacOs => modifiers.ctrl && modifiers.shift && !modifiers.alt && !modifiers.cmd,
            Platform::Linux | Platform::Windows => {
                modifiers.alt && modifiers.shift && !modifiers.ctrl && !modifiers.cmd
            }
        }
    }

    /// Whether a key may continue a started pane hint: typed with or without the hint chord's
    /// modifiers, but without any other (⌘/⌥ on macOS, Ctrl/Super elsewhere).
    pub(crate) fn may_continue_pane_hint(self, modifiers: Modifiers) -> bool {
        match self {
            Platform::MacOs => !modifiers.cmd && !modifiers.alt,
            Platform::Linux | Platform::Windows => !modifiers.ctrl && !modifiers.cmd,
        }
    }

    /// Whether `modifiers` are Ctrl alone, the way the prefix key is pressed. macOS ignores
    /// Option (as the Swift app did); elsewhere Alt is part of the `cmd` encodings, so it counts.
    pub(crate) fn is_ctrl_only(self, modifiers: Modifiers) -> bool {
        match self {
            Platform::MacOs => modifiers.ctrl && !modifiers.cmd && !modifiers.shift,
            Platform::Linux | Platform::Windows => modifiers.ctrl && !modifiers.alt && !modifiers.shift,
        }
    }

    /// Whether the sidebar reveals its window-number and pane hints for these held modifiers:
    /// Control, plus on Linux/Windows the Alt+Shift pane-hint chord.
    pub(crate) fn reveals_hints(self, modifiers: Modifiers) -> bool {
        match self {
            Platform::MacOs => modifiers.ctrl,
            Platform::Linux | Platform::Windows => modifiers.ctrl || (modifiers.alt && modifiers.shift),
        }
    }

    /// Whether the event's modifiers equal `required`, ignoring the modifier this platform never
    /// binds (Option on macOS, Super elsewhere), and Shift when `ignore_shift`.
    pub(crate) fn modifiers_match(self, event: Modifiers, required: Modifiers, ignore_shift: bool) -> bool {
        let third = match self {
            Platform::MacOs => event.cmd == required.cmd,
            Platform::Linux | Platform::Windows => event.alt == required.alt,
        };
        event.ctrl == required.ctrl && third && (ignore_shift || event.shift == required.shift)
    }
}

/// Held modifier keys. `cmd` is Command on macOS and Super/Windows elsewhere; `alt` is Option on
/// macOS.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Modifiers {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub cmd: bool,
}

/// One key press.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct KeyEvent {
    /// The character the key produces with Shift applied but every other modifier ignored
    /// (AppKit's `charactersIgnoringModifiers`): Shift+\ is `|`, Shift+. is `>`. Letters may come
    /// in either case. Keys without a character are named: `tab`, `escape`, `enter`, `space`,
    /// `backspace`, `delete`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`,
    /// `pagedown`, `f1`…`f12`.
    pub key: String,
    /// The key without Shift (GPUI's `Keystroke::key`), when it differs from `key`: `1` for
    /// Shift+1 reporting `!`. Needed on Linux/Windows, where ⌘1 is pressed as Ctrl+Shift+1.
    pub base_key: Option<String>,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    /// Command on macOS, Super/Windows elsewhere.
    pub cmd: bool,
    /// Auto-repeat. Repeats resolve like first presses, as in the Swift app.
    pub is_repeat: bool,
}

impl KeyEvent {
    pub fn new(key: impl Into<String>) -> Self {
        KeyEvent { key: key.into(), ..KeyEvent::default() }
    }

    pub fn with_ctrl(mut self) -> Self {
        self.ctrl = true;
        self
    }

    pub fn with_alt(mut self) -> Self {
        self.alt = true;
        self
    }

    pub fn with_shift(mut self) -> Self {
        self.shift = true;
        self
    }

    pub fn with_cmd(mut self) -> Self {
        self.cmd = true;
        self
    }

    pub fn with_base_key(mut self, base_key: impl Into<String>) -> Self {
        self.base_key = Some(base_key.into());
        self
    }

    pub fn repeated(mut self) -> Self {
        self.is_repeat = true;
        self
    }

    pub fn modifiers(&self) -> Modifiers {
        Modifiers { ctrl: self.ctrl, alt: self.alt, shift: self.shift, cmd: self.cmd }
    }

    /// The key bindings are compared against (see [`binding_key`]).
    pub fn binding_key(&self) -> String {
        binding_key(&self.key)
    }

    /// [`KeyEvent::binding_key`] of the unshifted key.
    pub fn base_binding_key(&self) -> String {
        binding_key(self.base_key.as_deref().unwrap_or(&self.key))
    }
}

/// The escape character, the binding key of the Escape key.
pub const ESCAPE: &str = "\u{1B}";

/// The key a reported key names for binding lookups: lowercased, with named keys turned into
/// the character AppKit reports for them, which is what `settings.json` bindings store
/// (`"\t"`, `"\u{F703}"` for →).
///
/// Shift turns Tab into the back-tab character, so Tab is recognized by name and back-tab maps
/// back to `"\t"`: Ctrl+Shift+Tab still matches a "ctrl+shift+tab" binding.
pub fn binding_key(key: &str) -> String {
    let lowered = key.to_lowercase();
    if lowered == "\u{19}" {
        return "\t".to_owned();
    }
    if lowered.chars().count() > 1
        && let Some(named) = named_key(&lowered)
    {
        return named;
    }
    lowered
}

fn named_key(name: &str) -> Option<String> {
    let character = match name {
        "space" => " ",
        "tab" => "\t",
        "enter" | "return" => "\r",
        "escape" | "esc" => ESCAPE,
        "backspace" => "\u{7F}",
        // NSDeleteFunctionKey: forward delete.
        "delete" => "\u{F728}",
        "up" => "\u{F700}",
        "down" => "\u{F701}",
        "left" => "\u{F702}",
        "right" => "\u{F703}",
        "home" => "\u{F729}",
        "end" => "\u{F72B}",
        "pageup" => "\u{F72C}",
        "pagedown" => "\u{F72D}",
        _ => {
            // NSF1FunctionKey … NSF35FunctionKey.
            let number: u32 = name.strip_prefix('f')?.parse().ok()?;
            if !(1..=35).contains(&number) {
                return None;
            }
            return char::from_u32(0xF704 + number - 1).map(String::from);
        }
    };
    Some(character.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_keys_become_the_characters_bindings_store() {
        assert_eq!(binding_key("Tab"), "\t");
        assert_eq!(binding_key("left"), "\u{F702}");
        assert_eq!(binding_key("right"), "\u{F703}");
        assert_eq!(binding_key("escape"), ESCAPE);
        assert_eq!(binding_key("f1"), "\u{F704}");
        assert_eq!(binding_key("T"), "t");
        assert_eq!(binding_key("|"), "|");
        assert_eq!(binding_key("fx"), "fx");
    }

    #[test]
    fn control_shift_tab_matches_by_its_key_rather_than_the_back_tab_character() {
        assert_eq!(binding_key("\u{19}"), "\t");
        assert_eq!(KeyEvent::new("tab").with_ctrl().with_shift().binding_key(), "\t");
    }

    #[test]
    fn ordinary_control_keys_never_activate_pane_hints() {
        let mac = Platform::MacOs;
        let m = |ctrl, shift, alt, cmd| Modifiers { ctrl, alt, shift, cmd };
        assert!(!mac.is_pane_shortcut_chord(m(false, false, false, false)));
        assert!(!mac.is_pane_shortcut_chord(m(true, false, false, false)));
        assert!(!mac.is_pane_shortcut_chord(m(false, true, false, false)));
        assert!(mac.is_pane_shortcut_chord(m(true, true, false, false)));
        assert!(!mac.is_pane_shortcut_chord(m(true, true, true, false)));
        assert!(!mac.is_pane_shortcut_chord(m(true, true, false, true)));
    }

    #[test]
    fn linux_pane_hints_use_alt_shift_because_control_shift_is_command() {
        let linux = Platform::Linux;
        let m = |ctrl, shift, alt, cmd| Modifiers { ctrl, alt, shift, cmd };
        assert!(linux.is_pane_shortcut_chord(m(false, true, true, false)));
        assert!(!linux.is_pane_shortcut_chord(m(true, true, false, false)));
        assert!(!linux.is_pane_shortcut_chord(m(true, true, true, false)));
    }

    #[test]
    fn command_maps_to_control_shift_off_macos() {
        let linux = Platform::Windows;
        let m = |ctrl, shift, alt| Modifiers { ctrl, alt, shift, cmd: false };
        assert_eq!(linux.binding_modifiers(false, true, false), m(true, true, false));
        assert_eq!(linux.binding_modifiers(false, true, true), m(true, true, true));
        assert_eq!(linux.binding_modifiers(true, true, false), m(true, false, true));
        assert_eq!(linux.binding_modifiers(true, true, true), m(true, true, true));
        assert_eq!(linux.binding_modifiers(true, false, true), m(true, true, false));
        assert_eq!(
            Platform::MacOs.binding_modifiers(true, true, false),
            Modifiers { ctrl: true, alt: false, shift: false, cmd: true }
        );
    }
}
