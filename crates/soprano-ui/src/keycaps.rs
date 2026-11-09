//! K1 keycaps: one cap per chord step (`⌘1`, `⇧⌘P`, then `⌃A` and `P` for a prefix binding),
//! `esc` lowercase, Shift left off symbols that need it to type (`MainWindowController.keycaps`).
//!
//! On Linux and Windows the keybinding layer maps `cmd` to Ctrl+Shift and `cmd+shift` to
//! Ctrl+Shift+Alt; plain Ctrl chords stay Ctrl, and caps spell the modifiers out
//! (`Ctrl+Shift+D`).

use gpui::{App, IntoElement, ParentElement, RenderOnce, SharedString, Styled, Window, div};
use soprano_types::{KeyBinding, KeyBindingMode};

use crate::fonts::size;
use crate::theme::ActiveSopranoTheme;

/// Which keycap convention to render.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyPlatform {
    /// ⌃⇧⌘ symbols.
    Mac,
    /// Spelled-out modifiers, `cmd` taken by Ctrl+Shift.
    Other,
}

impl KeyPlatform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") { Self::Mac } else { Self::Other }
    }
}

/// US-layout characters that already require Shift to type (`KeyChord.shiftedSymbols`).
const SHIFTED_SYMBOLS: &str = "~!@#$%^&*()_+{}|:\"<>?";

fn shift_is_implied(key: &str) -> bool {
    let mut chars = key.chars();
    matches!((chars.next(), chars.next()), (Some(c), None) if SHIFTED_SYMBOLS.contains(c))
}

/// The legend of a key: named keys get their glyph or word, letters are uppercased.
pub fn key_legend(key: &str, platform: KeyPlatform) -> String {
    let mac = platform == KeyPlatform::Mac;
    match key {
        " " | "space" => "Space".into(),
        "\t" | "tab" => (if mac { "⇥" } else { "Tab" }).into(),
        "\r" | "enter" | "return" => (if mac { "↵" } else { "Enter" }).into(),
        "\u{1b}" | "escape" | "esc" => "esc".into(),
        "\u{7f}" | "backspace" => (if mac { "⌫" } else { "Backspace" }).into(),
        "\u{f700}" | "up" => "↑".into(),
        "\u{f701}" | "down" => "↓".into(),
        "\u{f702}" | "left" => "←".into(),
        "\u{f703}" | "right" => "→".into(),
        other => other.to_uppercase(),
    }
}

/// One direct chord as a cap. `shift` is the binding's Shift flag; it is shown only when the
/// key does not imply it.
pub fn chord_cap(ctrl: bool, meta: bool, shift: bool, key: &str, platform: KeyPlatform) -> String {
    let key = key.to_lowercase();
    let shift = shift || shift_is_implied(&key);
    let shows_shift = shift && !shift_is_implied(&key);
    let legend = key_legend(&key, platform);
    match platform {
        KeyPlatform::Mac => {
            format!(
                "{}{}{}{legend}",
                if ctrl { "⌃" } else { "" },
                if shows_shift { "⇧" } else { "" },
                if meta { "⌘" } else { "" }
            )
        }
        KeyPlatform::Other => {
            let mut parts: Vec<&str> = Vec::new();
            if ctrl || meta {
                parts.push("Ctrl");
            }
            if meta || shows_shift {
                parts.push("Shift");
            }
            if meta && shift {
                parts.push("Alt");
            }
            parts.push(&legend);
            parts.join("+")
        }
    }
}

/// A binding as K1 keycaps for the current platform; unbound → none.
pub fn keycaps(binding: &KeyBinding, prefix_key: &str) -> Vec<String> {
    keycaps_for(binding, prefix_key, KeyPlatform::current())
}

/// A binding as K1 keycaps for `platform`.
pub fn keycaps_for(binding: &KeyBinding, prefix_key: &str, platform: KeyPlatform) -> Vec<String> {
    let key = binding.key.to_lowercase();
    if key.is_empty() {
        return Vec::new();
    }
    let shift = binding.shift == Some(true);
    match binding.mode {
        KeyBindingMode::Prefix => {
            let shows_shift = shift && !shift_is_implied(&key);
            let shift_mark = match (shows_shift, platform) {
                (false, _) => "",
                (true, KeyPlatform::Mac) => "⇧",
                (true, KeyPlatform::Other) => "Shift+",
            };
            vec![
                chord_cap(true, false, false, prefix_key, platform),
                format!("{shift_mark}{}", key_legend(&key, platform)),
            ]
        }
        KeyBindingMode::Direct => {
            vec![chord_cap(binding.ctrl == Some(true), binding.meta == Some(true), shift, &key, platform)]
        }
    }
}

/// Keycap size: Herdr's palette keycap (11 px) or a smaller hint cap.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum KeycapSize {
    #[default]
    Regular,
    Small,
}

/// A row of keycaps, one box per cap: px 5, r 4, 1 px border, `raised` fill, 11 px `dim`
/// text, 3 px apart. Caps joined by `or` when given alternatives ([`Keycaps::alternatives`]).
#[derive(IntoElement)]
pub struct Keycaps {
    groups: Vec<Vec<SharedString>>,
    size: KeycapSize,
    color: Option<gpui::Hsla>,
}

impl Keycaps {
    /// One binding's caps (`["⌃A", "G"]`).
    pub fn new(caps: impl IntoIterator<Item = impl Into<SharedString>>) -> Self {
        Self {
            groups: vec![caps.into_iter().map(Into::into).collect()],
            size: KeycapSize::Regular,
            color: None,
        }
    }

    /// Several bindings for one command, shown `⌘D or ⌃A |`.
    pub fn alternatives(groups: Vec<Vec<String>>) -> Self {
        Self {
            groups: groups.into_iter().map(|caps| caps.into_iter().map(Into::into).collect()).collect(),
            size: KeycapSize::Regular,
            color: None,
        }
    }

    pub fn small(mut self) -> Self {
        self.size = KeycapSize::Small;
        self
    }

    /// Text color (default `dim`).
    pub fn color(mut self, color: gpui::Hsla) -> Self {
        self.color = Some(color);
        self
    }
}

impl RenderOnce for Keycaps {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let text = self.color.unwrap_or(theme.dim);
        let (font, height) = match self.size {
            KeycapSize::Regular => (size::SMALL, 18.0),
            KeycapSize::Small => (10.0, 16.0),
        };
        let cap = |legend: SharedString| {
            div()
                .flex()
                .flex_none()
                .items_center()
                .justify_center()
                .h(theme.z(height))
                .min_w(theme.z(height))
                .px(theme.z(5.))
                .rounded(theme.z(4.))
                .border_1()
                .border_color(theme.border)
                .bg(theme.raised)
                .text_size(theme.z(font))
                .text_color(text)
                .whitespace_nowrap()
                .child(legend)
        };
        let group_count = self.groups.len();
        div().flex().flex_row().flex_none().items_center().gap(theme.z(3.)).children(
            self.groups.into_iter().enumerate().flat_map(|(index, caps)| {
                let separator = (index + 1 < group_count).then(|| {
                    div()
                        .px(theme.z(2.))
                        .text_size(theme.z(font))
                        .text_color(theme.dim)
                        .child("or")
                        .into_any_element()
                });
                caps.into_iter()
                    .map(|legend| cap(legend).into_any_element())
                    .chain(separator)
                    .collect::<Vec<_>>()
            }),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_types::KeyBindingCategory;

    fn binding(mode: KeyBindingMode, key: &str, ctrl: bool, meta: bool, shift: bool) -> KeyBinding {
        KeyBinding {
            id: "test".into(),
            label: "Test".into(),
            description: String::new(),
            category: KeyBindingCategory::General,
            default_keys: String::new(),
            mode,
            key: key.into(),
            ctrl: ctrl.then_some(true),
            meta: meta.then_some(true),
            shift: shift.then_some(true),
        }
    }

    fn mac(binding: &KeyBinding, prefix: &str) -> Vec<String> {
        keycaps_for(binding, prefix, KeyPlatform::Mac)
    }

    #[test]
    fn a_prefix_binding_is_the_prefix_cap_then_its_key() {
        // open-in-soprano-git
        assert_eq!(mac(&binding(KeyBindingMode::Prefix, "g", false, false, false), "a"), ["⌃A", "G"]);
    }

    #[test]
    fn a_prefix_binding_follows_the_configured_prefix_key() {
        // previous-window
        assert_eq!(mac(&binding(KeyBindingMode::Prefix, "p", false, false, false), "b"), ["⌃B", "P"]);
    }

    #[test]
    fn a_shifted_prefix_key_carries_shift_in_its_cap() {
        // new-session
        assert_eq!(mac(&binding(KeyBindingMode::Prefix, "c", false, false, true), "a"), ["⌃A", "⇧C"]);
    }

    #[test]
    fn a_symbol_that_needs_shift_to_type_shows_no_shift() {
        // split-vertical
        assert_eq!(mac(&binding(KeyBindingMode::Prefix, "|", false, false, true), "a"), ["⌃A", "|"]);
    }

    #[test]
    fn a_direct_chord_is_one_cap_with_modifiers_in_mac_order() {
        assert_eq!(mac(&binding(KeyBindingMode::Direct, "d", false, true, false), "a"), ["⌘D"]);
        assert_eq!(mac(&binding(KeyBindingMode::Direct, "p", false, true, true), "a"), ["⇧⌘P"]);
        assert_eq!(mac(&binding(KeyBindingMode::Direct, "l", true, false, true), "a"), ["⌃⇧L"]);
        assert_eq!(mac(&binding(KeyBindingMode::Direct, "\t", true, false, true), "a"), ["⌃⇧⇥"]);
    }

    #[test]
    fn an_overridden_escape_chord_renders_esc_in_lowercase() {
        assert_eq!(mac(&binding(KeyBindingMode::Direct, "\u{1b}", false, true, false), "a"), ["⌘esc"]);
    }

    #[test]
    fn a_binding_without_a_key_has_no_caps() {
        assert!(mac(&binding(KeyBindingMode::Direct, "", false, false, false), "a").is_empty());
    }

    #[test]
    fn other_platforms_spell_modifiers_and_map_cmd_to_ctrl_shift() {
        let other = |b: &KeyBinding| keycaps_for(b, "a", KeyPlatform::Other);
        assert_eq!(other(&binding(KeyBindingMode::Direct, "d", false, true, false)), ["Ctrl+Shift+D"]);
        assert_eq!(other(&binding(KeyBindingMode::Direct, "p", false, true, true)), ["Ctrl+Shift+Alt+P"]);
        assert_eq!(other(&binding(KeyBindingMode::Direct, "h", true, false, false)), ["Ctrl+H"]);
        assert_eq!(other(&binding(KeyBindingMode::Direct, "l", true, false, true)), ["Ctrl+Shift+L"]);
        assert_eq!(other(&binding(KeyBindingMode::Prefix, "c", false, false, true)), ["Ctrl+A", "Shift+C"]);
        assert_eq!(other(&binding(KeyBindingMode::Direct, "\u{1b}", false, true, false)), ["Ctrl+Shift+esc"]);
    }
}
