//! A keyboard chord written the way a human types it — `"cmd+shift+p"`, `"ctrl+h"`,
//! `"prefix+|"` — and its translation to [`KeyBinding`]'s field representation
//! (`Config/KeyChord.swift`), plus the K1 keycap rendering the command palette and Settings
//! share (`MainWindowController.keycaps`, `SettingsKeycaps`).
//!
//! Settings files express shortcuts as text, but the keybinding manager matches live events
//! against `mode`/`key`/`ctrl`/`meta`/`shift`. `KeyChord` is the single place that converts
//! between the two, so a rebound shortcut behaves — and renders — exactly like a built-in one.
//!
//! `key` always holds the lowercased character the key reports with modifiers ignored, because
//! that is what the manager compares against. That is why a shifted symbol such as `|` is
//! stored as `"|"` with `shift == true` (matching the built-in "split-vertical" binding) rather
//! than as backslash-plus-shift. Arrow keys keep AppKit's private-use characters
//! (`\u{F700}`…`\u{F703}`) so stored bindings stay compatible on every OS.
//!
//! # Platforms
//!
//! Bindings are logical: `meta` is "the command modifier". On macOS that is ⌘. On Linux and
//! Windows `cmd` means Ctrl+Shift (the terminal-emulator convention), `cmd`+`shift` means
//! Ctrl+Shift+Alt, `ctrl`+`cmd` means Ctrl+Alt and `ctrl`+`cmd`+`shift` Ctrl+Shift+Alt. Plain
//! `ctrl` chords stay Ctrl everywhere. [`KeyChord::platform_modifiers`] is that table; the
//! display functions take a [`KeyPlatform`].

use std::collections::HashMap;
use std::sync::LazyLock;

use soprano_types::{KeyBinding, KeyBindingMode};

/// Which keyboard convention to render chords in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyPlatform {
    /// ⌘ is its own modifier; chords render as symbols (`⇧⌘P`).
    Mac,
    /// Linux and Windows: `cmd` is Ctrl+Shift; chords render as words (`Ctrl+Shift+P`).
    Other,
}

impl KeyPlatform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") { Self::Mac } else { Self::Other }
    }
}

/// The physical modifiers a chord's logical flags stand for on one platform.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct PlatformModifiers {
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    /// ⌘ (macOS only).
    pub cmd: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeyChord {
    pub mode: KeyBindingMode,
    /// Lowercased single character (or the character a named key produces).
    pub key: String,
    pub ctrl: bool,
    pub meta: bool,
    pub shift: bool,
}

impl KeyChord {
    /// Two normalizations happen here, both so that chords which behave identically at the
    /// keyboard compare equal:
    ///
    /// - Ctrl and Cmd are dropped for prefix chords: the prefix itself is Ctrl+<prefixKey>, and
    ///   prefix matching only compares the key and Shift.
    /// - Shift is *inferred* for characters that cannot be typed without it. The key reports
    ///   `|` **and** a Shift flag; a chord written `"prefix+|"` without Shift would therefore
    ///   match nothing and fail silently. Inferring it makes the obvious spelling work, and
    ///   matches how the built-in "split-vertical" binding is encoded.
    pub fn new(mode: KeyBindingMode, key: &str, ctrl: bool, meta: bool, shift: bool) -> Self {
        let key = key.to_lowercase();
        let prefix = mode == KeyBindingMode::Prefix;
        let shift = shift || is_shifted_symbol(&key);
        Self { mode, key, ctrl: !prefix && ctrl, meta: !prefix && meta, shift }
    }

    pub fn direct(key: &str) -> Self {
        Self::new(KeyBindingMode::Direct, key, false, false, false)
    }

    pub fn from_binding(binding: &KeyBinding) -> Self {
        Self::new(
            binding.mode,
            &binding.key,
            binding.ctrl == Some(true),
            binding.meta == Some(true),
            binding.shift == Some(true),
        )
    }

    // MARK: - Parsing

    /// Parse a user-written chord. Returns `None` when the text names no key or contains an
    /// unknown token.
    ///
    /// Tokens are separated by `+`, compared case-insensitively, and may be padded with
    /// whitespace. A literal `+` is written either as `plus` or by trailing the separator
    /// (`"cmd++"`, and the lenient `"cmd+"` form).
    ///
    /// Unknown tokens are rejected rather than ignored — `KeyBinding` has no Option flag, so
    /// silently dropping "alt" would install a shortcut that fires on the unmodified key.
    pub fn parse(text: &str) -> Option<Self> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return None;
        }

        // Splitting on "+" turns a literal "+" key into empty components ("cmd++" → ["cmd",
        // "", ""]). Collapse any number of them into one explicit key token so both spellings
        // land on the same chord.
        let mut tokens: Vec<String> = Vec::new();
        let mut saw_empty_component = false;
        for component in trimmed.split('+') {
            let token = component.trim().to_lowercase();
            if token.is_empty() {
                saw_empty_component = true;
            } else {
                tokens.push(token);
            }
        }
        if saw_empty_component {
            tokens.push("+".into());
        }

        let mut mode = KeyBindingMode::Direct;
        let (mut ctrl, mut meta, mut shift) = (false, false, false);
        let mut key: Option<String> = None;

        for token in &tokens {
            let token = token.as_str();
            if token == "prefix" {
                mode = KeyBindingMode::Prefix;
            } else if META_ALIASES.contains(&token) {
                meta = true;
            } else if CTRL_ALIASES.contains(&token) {
                ctrl = true;
            } else if SHIFT_ALIASES.contains(&token) {
                shift = true;
            } else if UNSUPPORTED_MODIFIER_ALIASES.contains(&token) {
                return None;
            } else {
                let resolved = resolve_key(token)?;
                if key.is_some() {
                    return None;
                }
                key = Some(resolved);
            }
        }

        let key = key?;
        // The prefix chord already consumes Ctrl, and prefix matching ignores Ctrl/Cmd
        // entirely — accepting them would silently bind something else.
        if mode == KeyBindingMode::Prefix && (ctrl || meta) {
            return None;
        }
        Some(Self::new(mode, &key, ctrl, meta, shift))
    }

    // MARK: - Rendering

    /// Round-trippable canonical form, e.g. `"cmd+shift+p"`, `"prefix+shift+n"`.
    ///
    /// Modifiers are written in a fixed order — prefix, ctrl, cmd, shift — followed by the key.
    /// Keys that cannot be written literally (invisible keys, and `+` itself) use their name:
    /// `"cmd+plus"`, `"ctrl+space"`.
    pub fn canonical_string(&self) -> String {
        let mut parts: Vec<&str> = Vec::new();
        if self.mode == KeyBindingMode::Prefix {
            parts.push("prefix");
        }
        if self.ctrl {
            parts.push("ctrl");
        }
        if self.meta {
            parts.push("cmd");
        }
        // Shift is left implicit on keys that require it to type, matching the inference in
        // `new`: "prefix+|" round-trips, and reads the way the user wrote it.
        if self.shift && !is_shifted_symbol(&self.key) {
            parts.push("shift");
        }
        parts.push(canonical_key_name(&self.key).unwrap_or(&self.key));
        parts.join("+")
    }

    /// Whether Shift is spelled out when rendering: never on a symbol that already requires it.
    fn shows_shift(&self) -> bool {
        self.shift && !is_shifted_symbol(&self.key)
    }

    /// The physical modifiers this chord's flags mean on `platform` (see the module docs).
    /// Shift on a symbol that needs it to type is still reported here; renderers drop it. On
    /// Linux/Windows a `cmd` chord gains Alt only for an explicit Shift — Shift that a symbol
    /// such as `+` implies is already part of Ctrl+Shift.
    pub fn platform_modifiers(&self, platform: KeyPlatform) -> PlatformModifiers {
        match platform {
            KeyPlatform::Mac => {
                PlatformModifiers { ctrl: self.ctrl, shift: self.shift, alt: false, cmd: self.meta }
            }
            KeyPlatform::Other if self.meta && self.ctrl => {
                PlatformModifiers { ctrl: true, shift: self.shift, alt: true, cmd: false }
            }
            KeyPlatform::Other if self.meta => {
                PlatformModifiers { ctrl: true, shift: true, alt: self.shows_shift(), cmd: false }
            }
            KeyPlatform::Other => {
                PlatformModifiers { ctrl: self.ctrl, shift: self.shift, alt: false, cmd: false }
            }
        }
    }

    /// [`Self::display_string_for`] on the running OS.
    pub fn display_string(&self) -> String {
        self.display_string_for(KeyPlatform::current())
    }

    /// Display form matching the app's existing convention, e.g. `"⇧⌘P"`, `"Ctrl+Shift+L"`,
    /// `"Prefix → Shift+N"`.
    ///
    /// The rules, derived from the built-in `defaultKeys` strings so that an overridden binding
    /// renders like a stock one:
    /// - Cmd chords use symbols in the order ⌃⇧⌘ followed by the uppercased key: `"⌘P"`,
    ///   `"⇧⌘S"`, `"⌘1"`, `"⌘,"`. On Linux/Windows they spell out their physical modifiers:
    ///   `"Ctrl+Shift+P"`, `"Ctrl+Shift+Alt+S"`.
    /// - Other direct chords spell their modifiers out: `"Ctrl+H"`, `"Ctrl+Shift+L"`, and a
    ///   bare key renders as just `"P"`.
    /// - Prefix chords read `"Prefix → N"`, `"Prefix → Shift+N"`, `"Prefix → |"`.
    /// - Shift is omitted whenever the key is a symbol that already requires Shift to type
    ///   (`|`, `?`, `:` …), which is how the built-in "split-vertical" binding renders
    ///   `"Prefix → |"`.
    /// - Invisible keys are named: Space, Tab, Enter, Esc, Backspace, and the arrows as ←→↑↓.
    pub fn display_string_for(&self, platform: KeyPlatform) -> String {
        let rendered_key =
            display_key_name(&self.key).map(str::to_owned).unwrap_or_else(|| self.key.to_uppercase());
        let shows_shift = self.shows_shift();

        if self.mode == KeyBindingMode::Prefix {
            return format!("Prefix → {}{rendered_key}", if shows_shift { "Shift+" } else { "" });
        }
        if self.meta && platform == KeyPlatform::Mac {
            let mut symbols = String::new();
            if self.ctrl {
                symbols.push('⌃');
            }
            if shows_shift {
                symbols.push('⇧');
            }
            symbols.push('⌘');
            return symbols + &rendered_key;
        }
        let mut parts = self.worded_modifiers(platform);
        parts.push(rendered_key);
        parts.join("+")
    }

    /// `Ctrl`, `Shift`, `Alt` as words, Shift left off symbols that need it.
    fn worded_modifiers(&self, platform: KeyPlatform) -> Vec<String> {
        let modifiers = self.platform_modifiers(platform);
        // Shift implied by the symbol itself is dropped, but Shift that `cmd` adds on
        // Linux/Windows is a real, separate key press and stays.
        let shift = if self.meta && platform == KeyPlatform::Other && !self.ctrl {
            true
        } else {
            modifiers.shift && self.shows_shift()
        };
        let mut parts = Vec::new();
        if modifiers.ctrl {
            parts.push("Ctrl".to_owned());
        }
        if shift {
            parts.push("Shift".to_owned());
        }
        if modifiers.alt {
            parts.push("Alt".to_owned());
        }
        parts
    }

    /// A copy of `binding` with this chord's mode/key/modifiers applied and `default_keys` set
    /// to [`Self::display_string`]. Unset modifiers become `None`, the way the built-in table
    /// encodes absence (the manager compares with `== Some(true)`, so `None` and `false` behave
    /// identically).
    pub fn applied(&self, binding: &KeyBinding) -> KeyBinding {
        KeyBinding {
            id: binding.id.clone(),
            label: binding.label.clone(),
            description: binding.description.clone(),
            category: binding.category,
            default_keys: self.display_string(),
            mode: self.mode,
            key: self.key.clone(),
            ctrl: self.ctrl.then_some(true),
            meta: self.meta.then_some(true),
            shift: self.shift.then_some(true),
        }
    }
}

// MARK: - Keycaps

/// [`keycaps_for`] on the running OS.
pub fn keycaps(binding: &KeyBinding, prefix_key: &str) -> Vec<String> {
    keycaps_for(binding, prefix_key, KeyPlatform::current())
}

/// A binding as K1 keycaps: one cap per chord with its modifiers in ⌃⇧⌘ order (`⌘D`, `⇧⌘P`,
/// `⌃⇧L`); a prefix binding is the prefix cap then the key (`⌃A`, `G`). Letters are
/// uppercase, `esc` lowercase, and Shift is left off symbols that need it to type (`|`).
/// Unbound → none. On Linux/Windows caps are worded: `Ctrl+Shift+D`, `Ctrl+A` then `G`.
pub fn keycaps_for(binding: &KeyBinding, prefix_key: &str, platform: KeyPlatform) -> Vec<String> {
    let chord = KeyChord::from_binding(binding);
    if chord.key.is_empty() {
        return Vec::new();
    }
    let key =
        keycap_legend(&chord.key, platform).map(str::to_owned).unwrap_or_else(|| chord.key.to_uppercase());
    let shows_shift = chord.shows_shift();
    match (chord.mode, platform) {
        (KeyBindingMode::Prefix, KeyPlatform::Mac) => {
            vec![
                prefix_legend_for(prefix_key, platform),
                format!("{}{key}", if shows_shift { "⇧" } else { "" }),
            ]
        }
        (KeyBindingMode::Prefix, KeyPlatform::Other) => {
            vec![
                prefix_legend_for(prefix_key, platform),
                format!("{}{key}", if shows_shift { "Shift+" } else { "" }),
            ]
        }
        (KeyBindingMode::Direct, KeyPlatform::Mac) => vec![format!(
            "{}{}{}{key}",
            if chord.ctrl { "⌃" } else { "" },
            if shows_shift { "⇧" } else { "" },
            if chord.meta { "⌘" } else { "" },
        )],
        (KeyBindingMode::Direct, KeyPlatform::Other) => {
            let mut parts = chord.worded_modifiers(platform);
            parts.push(key);
            vec![parts.join("+")]
        }
    }
}

/// Keycaps for Settings: one cap list per alternative. Only a built-in binding whose
/// `default_keys` lists several chords (`⌘+ / ⌘=`) has more than one; the bound chord keeps
/// its place among them (`SettingsKeycaps.alternatives`).
pub fn settings_keycap_alternatives(binding: &KeyBinding, prefix_key: &str) -> Vec<Vec<String>> {
    settings_keycap_alternatives_for(binding, prefix_key, KeyPlatform::current())
}

pub fn settings_keycap_alternatives_for(
    binding: &KeyBinding,
    prefix_key: &str,
    platform: KeyPlatform,
) -> Vec<Vec<String>> {
    let caps = keycaps_for(binding, prefix_key, platform);
    if caps.is_empty() {
        return Vec::new();
    }
    let listed: Vec<&str> = binding.default_keys.split(" / ").collect();
    let bound = caps.concat();
    if caps.len() != 1 || listed.len() < 2 || !listed.contains(&bound.as_str()) {
        return vec![caps];
    }
    listed
        .into_iter()
        .map(|alternative| if alternative == bound { caps.clone() } else { vec![alternative.to_owned()] })
        .collect()
}

/// [`prefix_legend_for`] on the running OS.
pub fn prefix_legend(prefix_key: &str) -> String {
    prefix_legend_for(prefix_key, KeyPlatform::current())
}

/// The prefix chord as one cap: `⌃A` (macOS), `Ctrl+A` (Linux/Windows).
pub fn prefix_legend_for(prefix_key: &str, platform: KeyPlatform) -> String {
    match platform {
        KeyPlatform::Mac => format!("⌃{}", prefix_key.to_uppercase()),
        KeyPlatform::Other => format!("Ctrl+{}", prefix_key.to_uppercase()),
    }
}

fn keycap_legend(key: &str, platform: KeyPlatform) -> Option<&'static str> {
    Some(match (key, platform) {
        (" ", _) => "Space",
        ("\t", KeyPlatform::Mac) => "⇥",
        ("\t", KeyPlatform::Other) => "Tab",
        ("\r", KeyPlatform::Mac) => "↵",
        ("\r", KeyPlatform::Other) => "Enter",
        ("\u{1B}", KeyPlatform::Mac) => "esc",
        ("\u{1B}", KeyPlatform::Other) => "Esc",
        ("\u{7F}", KeyPlatform::Mac) => "⌫",
        ("\u{7F}", KeyPlatform::Other) => "Backspace",
        ("\u{F700}", _) => "↑",
        ("\u{F701}", _) => "↓",
        ("\u{F702}", _) => "←",
        ("\u{F703}", _) => "→",
        _ => return None,
    })
}

// MARK: - Tokens

const META_ALIASES: &[&str] = &["cmd", "command", "meta", "super", "⌘"];
const CTRL_ALIASES: &[&str] = &["ctrl", "control", "^"];
const SHIFT_ALIASES: &[&str] = &["shift", "⇧"];

/// Named so they are rejected loudly: `KeyBinding` cannot express Option, and a chord that
/// quietly lost a modifier would fire unexpectedly.
const UNSUPPORTED_MODIFIER_ALIASES: &[&str] = &["alt", "opt", "option", "⌥", "fn", "function", "hyper"];

/// Named keys → the character the keyboard reports for them, since that is the value the
/// keybinding manager compares bindings against.
static NAMED_KEYS: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| {
    HashMap::from([
        ("space", " "),
        ("tab", "\t"),
        ("enter", "\r"),
        ("return", "\r"),
        ("escape", "\u{1B}"),
        ("esc", "\u{1B}"),
        ("backspace", "\u{7F}"),
        ("delete", "\u{7F}"),
        ("up", "\u{F700}"),
        ("down", "\u{F701}"),
        ("left", "\u{F702}"),
        ("right", "\u{F703}"),
        ("comma", ","),
        ("period", "."),
        ("dot", "."),
        ("slash", "/"),
        ("backslash", "\\"),
        ("minus", "-"),
        ("dash", "-"),
        ("equal", "="),
        ("equals", "="),
        ("plus", "+"),
        ("semicolon", ";"),
        ("quote", "'"),
        ("backtick", "`"),
        ("bracketleft", "["),
        ("bracketright", "]"),
    ])
});

/// An uppercase letter means the letter, not implicit Shift (VS Code semantics): "cmd+P" is
/// ⌘P, not ⇧⌘P.
fn resolve_key(token: &str) -> Option<String> {
    if let Some(named) = NAMED_KEYS.get(token) {
        return Some((*named).to_owned());
    }
    (token.chars().count() == 1).then(|| token.to_owned())
}

/// Keys that cannot survive a literal round trip — they are invisible, or they collide with
/// the `+` separator.
fn canonical_key_name(key: &str) -> Option<&'static str> {
    Some(match key {
        " " => "space",
        "\t" => "tab",
        "\r" => "enter",
        "\u{1B}" => "escape",
        "\u{7F}" => "backspace",
        "\u{F700}" => "up",
        "\u{F701}" => "down",
        "\u{F702}" => "left",
        "\u{F703}" => "right",
        "+" => "plus",
        _ => return None,
    })
}

fn display_key_name(key: &str) -> Option<&'static str> {
    Some(match key {
        " " => "Space",
        "\t" => "Tab",
        "\r" => "Enter",
        "\u{1B}" => "Esc",
        "\u{7F}" => "Backspace",
        "\u{F700}" => "↑",
        "\u{F701}" => "↓",
        "\u{F702}" => "←",
        "\u{F703}" => "→",
        _ => return None,
    })
}

/// US-layout characters that already require Shift to type, so spelling "Shift+" alongside
/// them would double-count the modifier.
pub fn is_shifted_symbol(key: &str) -> bool {
    matches!(
        key,
        "~" | "!"
            | "@"
            | "#"
            | "$"
            | "%"
            | "^"
            | "&"
            | "*"
            | "("
            | ")"
            | "_"
            | "+"
            | "{"
            | "}"
            | "|"
            | ":"
            | "\""
            | "<"
            | ">"
            | "?"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::default_keybindings::DefaultKeybindings;
    use soprano_types::KeyBindingCategory;

    use KeyBindingMode::{Direct, Prefix};

    fn chord(mode: KeyBindingMode, key: &str, ctrl: bool, meta: bool, shift: bool) -> KeyChord {
        KeyChord::new(mode, key, ctrl, meta, shift)
    }

    fn default_binding(id: &str) -> KeyBinding {
        DefaultKeybindings::config_for(KeyPlatform::Mac)
            .bindings
            .into_iter()
            .find(|b| b.id == id)
            .expect("built-in binding")
    }

    fn mac_caps(binding: &KeyBinding, prefix: &str) -> Vec<String> {
        keycaps_for(binding, prefix, KeyPlatform::Mac)
    }

    fn mac_applied(chord: &KeyChord, binding: &KeyBinding) -> KeyBinding {
        KeyBinding { default_keys: chord.display_string_for(KeyPlatform::Mac), ..chord.applied(binding) }
    }

    // MARK: - KeyChordTests

    #[test]
    fn written_chords_parse_into_binding_fields_and_round_trip_through_canonical_text() {
        let cases = [
            ("cmd+p", "cmd+p", chord(Direct, "p", false, true, false)),
            ("cmd+shift+p", "cmd+shift+p", chord(Direct, "p", false, true, true)),
            ("ctrl+h", "ctrl+h", chord(Direct, "h", true, false, false)),
            ("ctrl+shift+l", "ctrl+shift+l", chord(Direct, "l", true, false, true)),
            ("prefix+n", "prefix+n", chord(Prefix, "n", false, false, false)),
            ("prefix+shift+n", "prefix+shift+n", chord(Prefix, "n", false, false, true)),
            ("prefix+|", "prefix+|", chord(Prefix, "|", false, false, false)),
            ("prefix+-", "prefix+-", chord(Prefix, "-", false, false, false)),
            ("cmd+,", "cmd+,", chord(Direct, ",", false, true, false)),
            ("ctrl+space", "ctrl+space", chord(Direct, " ", true, false, false)),
            ("prefix+left", "prefix+left", chord(Prefix, "\u{F702}", false, false, false)),
            ("cmd+enter", "cmd+enter", chord(Direct, "\r", false, true, false)),
            ("cmd+escape", "cmd+escape", chord(Direct, "\u{1B}", false, true, false)),
            ("cmd+backspace", "cmd+backspace", chord(Direct, "\u{7F}", false, true, false)),
            ("p", "p", chord(Direct, "p", false, false, false)),
        ];
        for (text, canonical, expected) in cases {
            let parsed = KeyChord::parse(text);
            assert_eq!(parsed.as_ref(), Some(&expected), "parsing {text}");
            assert_eq!(
                parsed.map(|c| c.canonical_string()).as_deref(),
                Some(canonical),
                "canonical of {text}"
            );
            assert_eq!(KeyChord::parse(canonical), Some(expected), "re-parsing {canonical}");
        }
    }

    #[test]
    fn aliases_and_casing_and_whitespace_all_resolve_to_the_same_chord() {
        let expected = Some(chord(Direct, "p", false, true, true));
        assert_eq!(KeyChord::parse("Command+Shift+P"), expected);
        assert_eq!(KeyChord::parse("META + shift + p"), expected);
        assert_eq!(KeyChord::parse("super+⇧+P"), expected);
        assert_eq!(KeyChord::parse("⌘+shift+p"), expected);

        // An uppercase letter names the letter, it does not imply Shift.
        assert_eq!(KeyChord::parse("cmd+P"), Some(chord(Direct, "p", false, true, false)));

        assert_eq!(KeyChord::parse("control+h"), Some(chord(Direct, "h", true, false, false)));
        assert_eq!(KeyChord::parse("^+h"), Some(chord(Direct, "h", true, false, false)));
    }

    #[test]
    fn named_keys_resolve_to_the_character_the_keyboard_reports() {
        let expectations = [
            ("space", " "),
            ("tab", "\t"),
            ("enter", "\r"),
            ("return", "\r"),
            ("escape", "\u{1B}"),
            ("esc", "\u{1B}"),
            ("backspace", "\u{7F}"),
            ("delete", "\u{7F}"),
            ("up", "\u{F700}"),
            ("down", "\u{F701}"),
            ("left", "\u{F702}"),
            ("right", "\u{F703}"),
            ("comma", ","),
            ("period", "."),
            ("dot", "."),
            ("slash", "/"),
            ("backslash", "\\"),
            ("minus", "-"),
            ("dash", "-"),
            ("equal", "="),
            ("equals", "="),
            ("plus", "+"),
            ("semicolon", ";"),
            ("quote", "'"),
            ("backtick", "`"),
            ("bracketleft", "["),
            ("bracketright", "]"),
        ];
        for (name, key) in expectations {
            assert_eq!(
                KeyChord::parse(&format!("ctrl+{name}")).map(|c| c.key).as_deref(),
                Some(key),
                "named {name}"
            );
        }
        for literal in [",", ".", "/", "\\", "-", "=", ";", "'", "`", "[", "]", "|"] {
            assert_eq!(
                KeyChord::parse(&format!("ctrl+{literal}")).map(|c| c.key).as_deref(),
                Some(literal),
                "literal {literal}"
            );
        }
    }

    #[test]
    fn a_literal_plus_can_be_written_as_plus_or_as_a_trailing_separator() {
        let expected = chord(Direct, "+", false, true, false);
        assert_eq!(KeyChord::parse("cmd++").as_ref(), Some(&expected));
        assert_eq!(KeyChord::parse("cmd+plus").as_ref(), Some(&expected));
        assert_eq!(KeyChord::parse("cmd+").as_ref(), Some(&expected));
        assert_eq!(expected.canonical_string(), "cmd+plus");
        assert_eq!(KeyChord::parse(&expected.canonical_string()), Some(expected));
    }

    #[test]
    fn every_built_in_binding_survives_a_chord_round_trip() {
        let bindings = DefaultKeybindings::config().bindings;
        // Guards against a vacuously passing loop.
        assert!(bindings.len() >= 50);
        for binding in bindings {
            let chord = KeyChord::from_binding(&binding);
            assert_eq!(KeyChord::parse(&chord.canonical_string()).as_ref(), Some(&chord), "{}", binding.id);
            assert_eq!(chord.key, binding.key, "{} key", binding.id);
            assert_eq!(chord.ctrl, binding.ctrl == Some(true), "{} ctrl", binding.id);
            assert_eq!(chord.meta, binding.meta == Some(true), "{} meta", binding.id);
            assert_eq!(chord.shift, binding.shift == Some(true), "{} shift", binding.id);
        }
    }

    #[test]
    fn shifted_symbol_chords_match_the_built_in_split_vertical_binding() {
        let split_vertical = default_binding("split-vertical");
        let parsed = KeyChord::parse("prefix+shift+|").expect("parses");
        assert_eq!(parsed.mode, split_vertical.mode);
        assert_eq!(parsed.key, split_vertical.key);
        assert_eq!(parsed.shift, split_vertical.shift == Some(true));
        assert_eq!(parsed.ctrl, split_vertical.ctrl == Some(true));
        assert_eq!(parsed.meta, split_vertical.meta == Some(true));
        assert_eq!(parsed.display_string_for(KeyPlatform::Mac), split_vertical.default_keys);
    }

    #[test]
    fn prefix_chords_ignore_ctrl_and_command_because_the_prefix_already_consumes_them() {
        let chord = chord(Prefix, "n", true, true, true);
        assert!(!chord.ctrl);
        assert!(!chord.meta);
        assert!(chord.shift);
        assert_eq!(chord.canonical_string(), "prefix+shift+n");
    }

    #[test]
    fn unparseable_chords_are_rejected_instead_of_silently_losing_modifiers() {
        let rejected = [
            "alt+x",
            "opt+x",
            "option+x",
            "⌥+x",
            "fn+x",
            "prefix+cmd+x",
            "prefix+ctrl+x",
            "cmd",
            "shift",
            "prefix",
            "",
            "   ",
            "cmd+a+b",
            "nonsense+x",
            "cmd+nonsense",
        ];
        for text in rejected {
            assert_eq!(KeyChord::parse(text), None, "expected {text:?} to be rejected");
        }
    }

    #[test]
    fn applying_a_chord_rewrites_only_the_shortcut_fields() {
        let original = default_binding("command-palette");
        let chord = KeyChord::parse("ctrl+shift+k").expect("parses");
        let applied = chord.applied(&original);

        assert_eq!(applied.id, original.id);
        assert_eq!(applied.label, original.label);
        assert_eq!(applied.description, original.description);
        assert_eq!(applied.category, original.category);

        assert_eq!(applied.mode, Direct);
        assert_eq!(applied.key, "k");
        assert_eq!(applied.ctrl, Some(true));
        assert_eq!(applied.shift, Some(true));
        assert_eq!(applied.meta, None);
        assert_eq!(applied.default_keys, "Ctrl+Shift+K");

        // The rewritten binding is itself round-trippable.
        assert_eq!(KeyChord::from_binding(&applied), chord);
    }

    #[test]
    fn applying_a_chord_clears_modifiers_the_new_chord_does_not_use() {
        let original = default_binding("open-project");
        let applied = KeyChord::parse("prefix+o").expect("parses").applied(&original);
        assert_eq!(applied.mode, Prefix);
        assert_eq!(applied.key, "o");
        assert_eq!(applied.ctrl, None);
        assert_eq!(applied.meta, None);
        assert_eq!(applied.shift, None);
        assert_eq!(applied.default_keys, "Prefix → O");
    }

    #[test]
    fn display_strings_follow_the_conventions_of_the_built_in_table() {
        let expectations = [
            ("cmd+p", "⌘P"),
            ("cmd+shift+s", "⇧⌘S"),
            ("cmd+1", "⌘1"),
            ("cmd+,", "⌘,"),
            ("cmd+-", "⌘-"),
            ("ctrl+cmd+shift+p", "⌃⇧⌘P"),
            ("ctrl+h", "Ctrl+H"),
            ("ctrl+shift+l", "Ctrl+Shift+L"),
            ("ctrl+1", "Ctrl+1"),
            ("p", "P"),
            ("prefix+n", "Prefix → N"),
            ("prefix+shift+n", "Prefix → Shift+N"),
            ("prefix+|", "Prefix → |"),
            ("prefix+shift+|", "Prefix → |"),
            ("prefix+-", "Prefix → -"),
            ("prefix+[", "Prefix → ["),
            ("ctrl+space", "Ctrl+Space"),
            ("ctrl+tab", "Ctrl+Tab"),
            ("cmd+enter", "⌘Enter"),
            ("cmd+escape", "⌘Esc"),
            ("cmd+backspace", "⌘Backspace"),
            ("prefix+left", "Prefix → ←"),
            ("prefix+up", "Prefix → ↑"),
            ("ctrl+down", "Ctrl+↓"),
            ("cmd+right", "⌘→"),
        ];
        for (text, display) in expectations {
            assert_eq!(
                KeyChord::parse(text).map(|c| c.display_string_for(KeyPlatform::Mac)).as_deref(),
                Some(display),
                "display of {text}"
            );
        }
    }

    #[test]
    fn on_linux_and_windows_cmd_chords_display_as_ctrl_shift_combinations() {
        let expectations = [
            ("cmd+p", "Ctrl+Shift+P"),
            ("cmd+shift+p", "Ctrl+Shift+Alt+P"),
            ("ctrl+cmd+t", "Ctrl+Alt+T"),
            ("ctrl+cmd+shift+t", "Ctrl+Shift+Alt+T"),
            ("cmd+,", "Ctrl+Shift+,"),
            ("cmd+plus", "Ctrl+Shift++"),
            ("ctrl+h", "Ctrl+H"),
            ("ctrl+shift+l", "Ctrl+Shift+L"),
            ("ctrl+tab", "Ctrl+Tab"),
            ("prefix+shift+n", "Prefix → Shift+N"),
            ("prefix+|", "Prefix → |"),
            ("cmd+right", "Ctrl+Shift+→"),
        ];
        for (text, display) in expectations {
            assert_eq!(
                KeyChord::parse(text).map(|c| c.display_string_for(KeyPlatform::Other)).as_deref(),
                Some(display),
                "display of {text}"
            );
        }
    }

    #[test]
    fn built_in_bindings_render_the_same_display_string_they_ship_with() {
        for platform in [KeyPlatform::Mac, KeyPlatform::Other] {
            let config = DefaultKeybindings::config_for(platform);
            // Zoom-in advertises two equivalent chords in one string; every other built-in
            // must render byte-identically.
            for binding in config.bindings.iter().filter(|b| b.id != "zoom-in") {
                assert_eq!(
                    KeyChord::from_binding(binding).display_string_for(platform),
                    binding.default_keys,
                    "{} display on {platform:?}",
                    binding.id
                );
            }
        }
        assert_eq!(
            KeyChord::from_binding(&default_binding("zoom-in")).display_string_for(KeyPlatform::Mac),
            "⌘="
        );
    }

    // MARK: - CommandPaletteKeycapTests

    #[test]
    fn a_prefix_binding_is_the_prefix_cap_then_its_key() {
        assert_eq!(mac_caps(&default_binding("open-in-soprano-git"), "a"), ["⌃A", "G"]);
    }

    #[test]
    fn a_prefix_binding_follows_the_configured_prefix_key() {
        assert_eq!(mac_caps(&default_binding("previous-window"), "b"), ["⌃B", "P"]);
    }

    #[test]
    fn a_shifted_prefix_key_carries_shift_in_its_cap() {
        assert_eq!(mac_caps(&default_binding("new-session"), "a"), ["⌃A", "⇧C"]);
    }

    #[test]
    fn a_symbol_that_needs_shift_to_type_shows_no_shift() {
        assert_eq!(mac_caps(&default_binding("split-vertical"), "a"), ["⌃A", "|"]);
    }

    #[test]
    fn a_direct_chord_is_one_cap_with_modifiers_in_mac_order() {
        assert_eq!(mac_caps(&default_binding("new-terminal"), "a"), ["⌘D"]);
        assert_eq!(mac_caps(&default_binding("open-project"), "a"), ["⇧⌘P"]);
        assert_eq!(mac_caps(&default_binding("next-window-direct"), "a"), ["⌃⇧L"]);
        assert_eq!(mac_caps(&default_binding("previous-tab"), "a"), ["⌃⇧⇥"]);
    }

    #[test]
    fn an_overridden_chord_renders_like_a_stock_one() {
        let chord = KeyChord::parse("cmd+escape").expect("parses");
        let binding = chord.applied(&default_binding("command-palette"));
        assert_eq!(mac_caps(&binding, "a"), ["⌘esc"]);
    }

    #[test]
    fn a_binding_without_a_key_has_no_caps() {
        let binding = KeyBinding {
            id: "launch-custom".into(),
            label: "Launch Custom".into(),
            description: "Launch the custom agent".into(),
            category: KeyBindingCategory::Agents,
            default_keys: String::new(),
            mode: Direct,
            key: String::new(),
            ctrl: None,
            meta: None,
            shift: None,
        };
        assert!(mac_caps(&binding, "a").is_empty());
        assert!(keycaps_for(&binding, "a", KeyPlatform::Other).is_empty());
    }

    #[test]
    fn on_linux_and_windows_keycaps_are_worded() {
        assert_eq!(
            keycaps_for(&default_binding("open-in-soprano-git"), "a", KeyPlatform::Other),
            ["Ctrl+A", "G"]
        );
        assert_eq!(
            keycaps_for(&default_binding("new-session"), "a", KeyPlatform::Other),
            ["Ctrl+A", "Shift+C"]
        );
        assert_eq!(keycaps_for(&default_binding("split-vertical"), "a", KeyPlatform::Other), ["Ctrl+A", "|"]);
        assert_eq!(
            keycaps_for(&default_binding("open-project"), "a", KeyPlatform::Other),
            ["Ctrl+Shift+Alt+P"]
        );
        assert_eq!(keycaps_for(&default_binding("new-terminal"), "a", KeyPlatform::Other), ["Ctrl+Shift+D"]);
        assert_eq!(
            keycaps_for(&default_binding("previous-tab"), "a", KeyPlatform::Other),
            ["Ctrl+Shift+Tab"]
        );
        assert_eq!(keycaps_for(&default_binding("select-window-1"), "a", KeyPlatform::Other), ["Ctrl+1"]);
    }

    // MARK: - SettingsKeycapTests

    #[test]
    fn settings_shows_the_same_caps_as_the_palette() {
        for platform in [KeyPlatform::Mac, KeyPlatform::Other] {
            for binding in
                DefaultKeybindings::config_for(platform).bindings.iter().filter(|b| b.id != "zoom-in")
            {
                let palette = keycaps_for(binding, "a", platform);
                let settings = settings_keycap_alternatives_for(binding, "a", platform);
                let expected = if palette.is_empty() { vec![] } else { vec![palette] };
                assert_eq!(settings, expected, "{}", binding.id);
            }
        }
    }

    #[test]
    fn named_keys_use_their_glyphs_and_lowercase_esc() {
        assert_eq!(
            settings_keycap_alternatives_for(&default_binding("next-tab"), "a", KeyPlatform::Mac),
            [["⌃⇥"]]
        );
        let chord = KeyChord::parse("cmd+escape").expect("parses");
        let overridden = chord.applied(&default_binding("command-palette"));
        assert_eq!(settings_keycap_alternatives_for(&overridden, "a", KeyPlatform::Mac), [["⌘esc"]]);
    }

    #[test]
    fn settings_keycaps_for_a_prefix_binding_follow_the_configured_prefix() {
        assert_eq!(
            settings_keycap_alternatives_for(&default_binding("previous-window"), "b", KeyPlatform::Mac),
            [["⌃B", "P"]]
        );
    }

    #[test]
    fn listed_alternatives_keep_their_slash_split() {
        let zoom_in = default_binding("zoom-in");
        assert_eq!(settings_keycap_alternatives_for(&zoom_in, "a", KeyPlatform::Mac), [["⌘+"], ["⌘="]]);

        let chord = KeyChord::parse("cmd+shift+i").expect("parses");
        assert_eq!(
            settings_keycap_alternatives_for(&mac_applied(&chord, &zoom_in), "a", KeyPlatform::Mac),
            [["⇧⌘I"]]
        );

        let other_zoom = DefaultKeybindings::config_for(KeyPlatform::Other)
            .bindings
            .into_iter()
            .find(|b| b.id == "zoom-in")
            .expect("zoom-in");
        assert_eq!(
            settings_keycap_alternatives_for(&other_zoom, "a", KeyPlatform::Other),
            [["Ctrl+Shift++"], ["Ctrl+Shift+="]]
        );
    }

    #[test]
    fn the_prefix_legend_is_one_control_cap() {
        assert_eq!(prefix_legend_for("a", KeyPlatform::Mac), "⌃A");
        assert_eq!(prefix_legend_for("b", KeyPlatform::Other), "Ctrl+B");
    }
}
