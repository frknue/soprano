// Adapted from herdr-app (Apache-2.0)
//! What a key sends to the program: the key described to libghostty-vt, which encodes it
//! once, in the mode the program asked for (legacy, Kitty keyboard protocol,
//! modifyOtherKeys), as Ghostty does. Windows' win32-input-mode covers what ConPTY loses.

use crate::vt::Vt;
use ghostty_sys::*;
use gpui::{Keystroke, Modifiers};

/// Press, auto-repeat or release.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyAction {
    Press,
    Repeat,
    Release,
}

impl KeyAction {
    fn ghostty(self) -> GhosttyKeyAction {
        match self {
            KeyAction::Press => GHOSTTY_KEY_ACTION_PRESS,
            KeyAction::Repeat => GHOSTTY_KEY_ACTION_REPEAT,
            KeyAction::Release => GHOSTTY_KEY_ACTION_RELEASE,
        }
    }
}

/// The bytes `keystroke` sends, or `None` for a key libghostty doesn't know (then nothing
/// is sent; text input goes through the input handler).
/// Option counts as Alt when the terminal's `macos-option-as-alt` says so.
pub fn key_bytes(vt: &mut Vt, keystroke: &Keystroke, action: KeyAction) -> Option<Vec<u8>> {
    let option_as_alt = vt.option_as_alt().applies();
    let k = keystroke;
    let m = k.modifiers;
    if action != KeyAction::Release {
        // libghostty leaves these aliases to fixterms, but GPUI drops their control text.
        // Legacy needs explicit aliases; negotiated modes keep the chord.
        if !vt.win32.on && vt.kitty_keyboard_flags() == 0 && m.control && !m.alt && !m.platform && !m.function
        {
            let alias = match k.key.as_str() {
                "[" if !m.shift => Some((GHOSTTY_KEY_BRACKET_LEFT, GHOSTTY_KEY_ESCAPE)),
                "i" if !m.shift => Some((GHOSTTY_KEY_I, GHOSTTY_KEY_TAB)),
                "m" if !m.shift => Some((GHOSTTY_KEY_M, GHOSTTY_KEY_ENTER)),
                _ => None,
            };
            if let Some((key, alias)) = alias {
                let legacy = vt.encode_key(GHOSTTY_KEY_ACTION_PRESS, alias, 0, 0, None, None);
                return Some(control_alias_bytes(vt, key, &k.key, false, legacy));
            }
            if matches!(k.key.as_str(), "-" | "_") {
                let shifted = m.shift || k.key == "_";
                let text = if shifted { "_" } else { "-" };
                return Some(control_alias_bytes(vt, GHOSTTY_KEY_MINUS, text, shifted, vec![0x1f]));
            }
        }
        if vt.win32.on && vt.kitty_keyboard_flags() == 0 {
            if k.key == "enter" && (m.shift || m.control || m.alt) {
                return Some(crate::win32_keys::enter(m.shift, m.control, m.alt));
            }
            // ConPTY combines a bare Escape with the next key as an Alt chord.
            if k.key == "escape" {
                return Some(crate::win32_keys::escape(m.shift, m.control, m.alt));
            }
        }
    }
    let Some((key, shifted, unshifted)) = map_key(&k.key) else {
        return match action {
            KeyAction::Release => None,
            _ => k.key_char.as_ref().map(|text| text.as_bytes().to_vec()),
        };
    };
    let mut mods = ghostty_mods(m);
    if shifted {
        mods |= GHOSTTY_MODS_SHIFT as GhosttyMods;
    }
    let alt_as_meta = m.alt && option_as_alt && cfg!(target_os = "macos");
    let text = match k.key.as_str() {
        "space" => Some(" ".to_owned()),
        // Option as Alt: the key itself, not the character macOS composed with Option.
        _ if alt_as_meta => unshifted.map(|c| shifted_text(c, m.shift || shifted)),
        _ => k.key_char.clone(),
    };
    if is_altgr_text(m, text.as_deref(), Platform::current()) {
        // AltGr made the character: the program gets it plain, not Ctrl/Alt chorded.
        mods &= !(GHOSTTY_MODS_CTRL as GhosttyMods | GHOSTTY_MODS_ALT as GhosttyMods);
    }
    let consumed = consumed_mods(mods, m, text.as_deref(), alt_as_meta, Platform::current());
    Some(vt.encode_key(action.ghostty(), key, mods, consumed, text.as_deref(), unshifted))
}

/// Which OS's keyboard conventions apply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Platform {
    MacOs,
    Windows,
    Other,
}

impl Platform {
    fn current() -> Self {
        if cfg!(target_os = "macos") {
            Platform::MacOs
        } else if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Other
        }
    }
}

/// Windows reports AltGr as Control+Alt with the typed character. Both made the character,
/// so neither may turn it into a control code: AltGr+Q on a German layout types "@", not
/// ESC NUL, and AltGr+E types "€", not ^E.
fn is_altgr_text(m: Modifiers, text: Option<&str>, platform: Platform) -> bool {
    platform == Platform::Windows
        && m.control
        && m.alt
        && text.is_some_and(|t| !t.is_empty() && !t.chars().any(char::is_control))
}

/// The modifiers that went into making `text`, which the encoder must not report again.
///
/// - Shift always counts when it was held.
/// - macOS translates Option into text unless it is configured as Alt; that text can be
///   ASCII too (Slovenian Shift-Option-2 -> "@").
/// - Other platforms keep Alt shortcuts unless they produced non-ASCII text (AltGr).
fn consumed_mods(
    mods: GhosttyMods,
    m: Modifiers,
    text: Option<&str>,
    alt_as_meta: bool,
    platform: Platform,
) -> GhosttyMods {
    let mut consumed = mods & GHOSTTY_MODS_SHIFT as GhosttyMods;
    if mods & GHOSTTY_MODS_ALT as GhosttyMods != 0
        && m.alt
        && !alt_as_meta
        && text.is_some_and(|t| !t.is_empty() && (platform == Platform::MacOs || !t.is_ascii()))
    {
        consumed |= GHOSTTY_MODS_ALT as GhosttyMods;
    }
    consumed
}

fn shifted_text(c: char, shift: bool) -> String {
    if !shift {
        return c.to_string();
    }
    const SHIFTED: &[(char, char)] = &[
        ('`', '~'),
        ('1', '!'),
        ('2', '@'),
        ('3', '#'),
        ('4', '$'),
        ('5', '%'),
        ('6', '^'),
        ('7', '&'),
        ('8', '*'),
        ('9', '('),
        ('0', ')'),
        ('-', '_'),
        ('=', '+'),
        ('[', '{'),
        (']', '}'),
        ('\\', '|'),
        (';', ':'),
        ('\'', '"'),
        (',', '<'),
        ('.', '>'),
        ('/', '?'),
    ];
    SHIFTED.iter().find(|(b, _)| *b == c).map_or_else(|| c.to_uppercase().collect(), |(_, s)| s.to_string())
}

/// GPUI's modifiers in Ghostty's layout.
pub fn ghostty_mods(m: Modifiers) -> GhosttyMods {
    let mut mods: GhosttyMods = 0;
    if m.shift {
        mods |= GHOSTTY_MODS_SHIFT as GhosttyMods;
    }
    if m.control {
        mods |= GHOSTTY_MODS_CTRL as GhosttyMods;
    }
    if m.alt {
        mods |= GHOSTTY_MODS_ALT as GhosttyMods;
    }
    if m.platform {
        mods |= GHOSTTY_MODS_SUPER as GhosttyMods;
    }
    mods
}

/// The modifiers a mouse report carries (Shift, Alt, Control).
pub fn mouse_mods(m: Modifiers) -> GhosttyMods {
    let mut mods = 0;
    if m.shift {
        mods |= GHOSTTY_MODS_SHIFT as GhosttyMods;
    }
    if m.alt {
        mods |= GHOSTTY_MODS_ALT as GhosttyMods;
    }
    if m.control {
        mods |= GHOSTTY_MODS_CTRL as GhosttyMods;
    }
    mods
}

/// A modifier key going down or up, which the Kitty protocol reports when the program
/// asked for all keys (flag 8). GPUI doesn't say which side, so the left key is reported.
pub fn modifier_key_bytes(vt: &mut Vt, before: Modifiers, after: Modifiers) -> Vec<u8> {
    let mut out = Vec::new();
    for (was, is, key) in [
        (before.shift, after.shift, GHOSTTY_KEY_SHIFT_LEFT),
        (before.control, after.control, GHOSTTY_KEY_CONTROL_LEFT),
        (before.alt, after.alt, GHOSTTY_KEY_ALT_LEFT),
        (before.platform, after.platform, GHOSTTY_KEY_META_LEFT),
    ] {
        if was != is {
            let action = if is { GHOSTTY_KEY_ACTION_PRESS } else { GHOSTTY_KEY_ACTION_RELEASE };
            out.extend(vt.encode_key(action, key, ghostty_mods(after), 0, None, None));
        }
    }
    out
}

fn control_alias_bytes(vt: &mut Vt, key: GhosttyKey, text: &str, shifted: bool, legacy: Vec<u8>) -> Vec<u8> {
    // libghostty has no mode-2 getter. Probe with printable base text so its
    // encoder can preserve the chord when modifyOtherKeys requests CSI 27.
    let mods = GHOSTTY_MODS_CTRL as GhosttyMods | if shifted { GHOSTTY_MODS_SHIFT as GhosttyMods } else { 0 };
    let encoded = vt.encode_key(GHOSTTY_KEY_ACTION_PRESS, key, mods, 0, Some(text), text.chars().next());
    if encoded.starts_with(b"\x1b[27;") { encoded } else { legacy }
}

/// GPUI's key name as libghostty's key, whether it implies Shift, and its unshifted
/// character.
fn map_key(key: &str) -> Option<(GhosttyKey, bool, Option<char>)> {
    let named = match key {
        "enter" => GHOSTTY_KEY_ENTER,
        "tab" => GHOSTTY_KEY_TAB,
        "escape" => GHOSTTY_KEY_ESCAPE,
        "backspace" => GHOSTTY_KEY_BACKSPACE,
        "space" => return Some((GHOSTTY_KEY_SPACE, false, Some(' '))),
        "delete" => GHOSTTY_KEY_DELETE,
        "insert" => GHOSTTY_KEY_INSERT,
        "home" => GHOSTTY_KEY_HOME,
        "end" => GHOSTTY_KEY_END,
        "pageup" => GHOSTTY_KEY_PAGE_UP,
        "pagedown" => GHOSTTY_KEY_PAGE_DOWN,
        "up" => GHOSTTY_KEY_ARROW_UP,
        "down" => GHOSTTY_KEY_ARROW_DOWN,
        "left" => GHOSTTY_KEY_ARROW_LEFT,
        "right" => GHOSTTY_KEY_ARROW_RIGHT,
        _ => GHOSTTY_KEY_UNIDENTIFIED,
    };
    if named != GHOSTTY_KEY_UNIDENTIFIED {
        return Some((named, false, None));
    }
    if let Some(n) = key.strip_prefix('f').and_then(|n| n.parse::<u8>().ok())
        && (1..=24).contains(&n)
    {
        // F1..F25 are consecutive in libghostty's key enum.
        return Some((GHOSTTY_KEY_F1 + (n - 1) as GhosttyKey, false, None));
    }
    let mut chars = key.chars();
    let (Some(c), None) = (chars.next(), chars.next()) else { return None };
    const SHIFTED: &[(char, char)] = &[
        ('~', '`'),
        ('!', '1'),
        ('@', '2'),
        ('#', '3'),
        ('$', '4'),
        ('%', '5'),
        ('^', '6'),
        ('&', '7'),
        ('*', '8'),
        ('(', '9'),
        (')', '0'),
        ('_', '-'),
        ('+', '='),
        ('{', '['),
        ('}', ']'),
        ('|', '\\'),
        (':', ';'),
        ('"', '\''),
        ('<', ','),
        ('>', '.'),
        ('?', '/'),
    ];
    let (base, shifted) = match SHIFTED.iter().find(|(s, _)| *s == c) {
        Some((_, b)) => (*b, true),
        None => (c, false),
    };
    let code = match base {
        'a'..='z' => GHOSTTY_KEY_A + (base as u8 - b'a') as GhosttyKey,
        '0'..='9' => GHOSTTY_KEY_DIGIT_0 + (base as u8 - b'0') as GhosttyKey,
        '`' => GHOSTTY_KEY_BACKQUOTE,
        '\\' => GHOSTTY_KEY_BACKSLASH,
        '[' => GHOSTTY_KEY_BRACKET_LEFT,
        ']' => GHOSTTY_KEY_BRACKET_RIGHT,
        ',' => GHOSTTY_KEY_COMMA,
        '=' => GHOSTTY_KEY_EQUAL,
        '-' => GHOSTTY_KEY_MINUS,
        '.' => GHOSTTY_KEY_PERIOD,
        '\'' => GHOSTTY_KEY_QUOTE,
        ';' => GHOSTTY_KEY_SEMICOLON,
        '/' => GHOSTTY_KEY_SLASH,
        _ => GHOSTTY_KEY_UNIDENTIFIED,
    };
    Some((code, shifted, Some(base)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vt::VtSettings;

    /// A key as the OS hands it over: "shift-;" with what it typed (":").
    fn press(spec: &str, typed: Option<&str>) -> Keystroke {
        let mut parts: Vec<&str> = spec.split('-').collect();
        let key = parts.pop().unwrap_or_default();
        let key = if key.is_empty() { "-" } else { key };
        let has = |m: &str| parts.contains(&m);
        Keystroke {
            modifiers: Modifiers {
                control: has("ctrl"),
                alt: has("alt"),
                shift: has("shift"),
                platform: has("cmd"),
                function: false,
            },
            key: key.into(),
            key_char: typed.map(str::to_owned),
        }
    }

    fn vt() -> Vt {
        Vt::new(20, 3, &VtSettings::default())
    }

    fn send(vt: &mut Vt, spec: &str, typed: Option<&str>) -> Option<Vec<u8>> {
        key_bytes(vt, &press(spec, typed), KeyAction::Press)
    }

    /// Every row is what Ghostty sends for that key in that mode.
    #[test]
    fn keys_send_what_ghostty_sends() {
        // Native Option text on macOS (option-as-alt off); other platforms prefix an
        // unconsumed Alt.
        const ALT_B: &[u8] = if cfg!(target_os = "macos") { b"b" } else { b"\x1bb" };
        const KITTY_ALT_B: &[u8] = if cfg!(target_os = "macos") { b"b" } else { b"\x1b[98;3u" };
        type Row = (&'static str, Option<&'static str>, &'static [u8], &'static [u8], &'static [u8]);
        const KEYS: &[Row] = &[
            // key, typed, plain, kitty disambiguate (>1u), kitty report-all (>9u)
            ("a", Some("a"), b"a", b"a", b"\x1b[97u"),
            ("shift-a", Some("A"), b"A", b"A", b"\x1b[97;2u"),
            ("shift-;", Some(":"), b":", b":", b"\x1b[59;2u"),
            ("shift-1", Some("!"), b"!", b"!", b"\x1b[49;2u"),
            ("space", Some(" "), b" ", b" ", b"\x1b[32u"),
            ("ctrl-c", None, b"\x03", b"\x1b[99;5u", b"\x1b[99;5u"),
            ("ctrl-[", None, b"\x1b", b"\x1b[91;5u", b"\x1b[91;5u"),
            ("ctrl-_", None, b"\x1f", b"\x1b[45;6u", b"\x1b[45;6u"),
            ("ctrl--", None, b"\x1f", b"\x1b[45;5u", b"\x1b[45;5u"),
            ("ctrl-i", None, b"\t", b"\x1b[105;5u", b"\x1b[105;5u"),
            ("ctrl-m", None, b"\r", b"\x1b[109;5u", b"\x1b[109;5u"),
            ("ctrl-space", None, b"\x00", b"\x1b[32;5u", b"\x1b[32;5u"),
            ("alt-b", Some("b"), ALT_B, KITTY_ALT_B, b"\x1b[98;3u"),
            ("escape", None, b"\x1b", b"\x1b[27u", b"\x1b[27u"),
            ("enter", None, b"\r", b"\r", b"\x1b[13u"),
            ("shift-enter", None, b"\x1b[27;2;13~", b"\x1b[13;2u", b"\x1b[13;2u"),
            ("tab", None, b"\t", b"\t", b"\x1b[9u"),
            ("shift-tab", None, b"\x1b[Z", b"\x1b[9;2u", b"\x1b[9;2u"),
            ("backspace", None, b"\x7f", b"\x7f", b"\x1b[127u"),
            ("up", None, b"\x1b[A", b"\x1b[A", b"\x1b[A"),
            ("ctrl-left", None, b"\x1b[1;5D", b"\x1b[1;5D", b"\x1b[1;5D"),
            ("f1", None, b"\x1bOP", b"\x1b[P", b"\x1b[P"),
            ("f5", None, b"\x1b[15~", b"\x1b[15~", b"\x1b[15~"),
        ];
        let modes: [(&str, &[u8]); 3] =
            [("plain", b""), ("kitty >1u", b"\x1b[>1u"), ("kitty >9u", b"\x1b[>9u")];
        let mut wrong = Vec::new();
        for (m, (name, setup)) in modes.iter().enumerate() {
            for (spec, typed, plain, dis, all) in KEYS {
                let mut vt = vt();
                vt.write(setup);
                let want: &[u8] = [*plain, *dis, *all][m];
                let got = send(&mut vt, spec, *typed).unwrap_or_default();
                if got != want {
                    wrong.push(format!(
                        "{name:10} {spec:12} sent {:?}, Ghostty sends {:?}",
                        String::from_utf8_lossy(&got),
                        String::from_utf8_lossy(want)
                    ));
                }
            }
        }
        assert!(wrong.is_empty(), "\n{}", wrong.join("\n"));
    }

    #[test]
    fn control_aliases_respect_modify_other_keys() {
        for (setup, expected) in [
            (b"".as_slice(), [b"\x1b".as_slice(), b"\t", b"\r"]),
            (b"\x1b[>4;2m".as_slice(), [b"\x1b[27;5;91~".as_slice(), b"\x1b[27;5;105~", b"\x1b[27;5;109~"]),
            (b"\x1b[>1u".as_slice(), [b"\x1b[91;5u".as_slice(), b"\x1b[105;5u", b"\x1b[109;5u"]),
        ] {
            let mut vt = vt();
            vt.write(setup);
            for (spec, want) in ["ctrl-[", "ctrl-i", "ctrl-m"].into_iter().zip(expected) {
                assert_eq!(send(&mut vt, spec, None).as_deref(), Some(want), "{spec}, setup={setup:?}");
            }
        }
    }

    /// Without Kitty, Windows' ConPTY drops Shift+Enter as Ghostty sends it; a
    /// win32-input-mode request (even split across reads) sends it as a native key event.
    #[test]
    fn enter_with_a_modifier_goes_as_a_windows_key_event_when_the_program_asks() {
        let mut vt = vt();
        let send = |vt: &mut Vt, spec| {
            String::from_utf8(send(vt, spec, None).unwrap_or_default()).unwrap_or_default()
        };
        assert_eq!(send(&mut vt, "shift-enter"), "\x1b[27;2;13~");
        vt.write(b"\x1b[?90");
        vt.write(b"01h");
        assert_eq!(send(&mut vt, "shift-enter"), "\x1b[13;28;13;1;16;1_\x1b[13;28;13;0;16;1_");
        assert_eq!(send(&mut vt, "enter"), "\r");
        vt.write(b"\x1b[?9001l");
        assert_eq!(send(&mut vt, "shift-enter"), "\x1b[27;2;13~");
    }

    #[test]
    fn option_as_alt_sends_the_key_with_an_escape_prefix() {
        let mut vt = vt();
        vt.set_option_as_alt(crate::settings::OptionAsAlt::True);
        let bytes = key_bytes(&mut vt, &press("alt-p", Some("π")), KeyAction::Press).unwrap_or_default();
        if cfg!(target_os = "macos") {
            assert_eq!(bytes, b"\x1bp");
            vt.set_option_as_alt(crate::settings::OptionAsAlt::False);
            let native = key_bytes(&mut vt, &press("alt-p", Some("π")), KeyAction::Press).unwrap_or_default();
            assert_eq!(native, "π".as_bytes());
        } else {
            assert_eq!(bytes, "π".as_bytes());
        }
    }

    #[test]
    fn releases_and_modifier_keys_reach_only_programs_that_asked_for_them() {
        let mut vt = vt();
        assert_eq!(key_bytes(&mut vt, &press("a", Some("a")), KeyAction::Release).unwrap_or_default(), b"");
        let shift = Modifiers { shift: true, ..Modifiers::default() };
        assert!(modifier_key_bytes(&mut vt, Modifiers::default(), shift).is_empty());
        vt.write(b"\x1b[>11u");
        assert!(!modifier_key_bytes(&mut vt, Modifiers::default(), shift).is_empty());
        assert!(
            !key_bytes(&mut vt, &press("a", Some("a")), KeyAction::Release).unwrap_or_default().is_empty()
        );
    }

    #[test]
    fn altgr_characters_on_windows_are_typed_not_turned_into_control_codes() {
        let ctrl_alt = Modifiers { control: true, alt: true, ..Modifiers::default() };
        assert!(is_altgr_text(ctrl_alt, Some("@"), Platform::Windows));
        assert!(is_altgr_text(ctrl_alt, Some("€"), Platform::Windows));
        // A real Ctrl+Alt chord without a character stays a chord, and only Windows does this.
        assert!(!is_altgr_text(ctrl_alt, None, Platform::Windows));
        assert!(!is_altgr_text(ctrl_alt, Some("\u{11}"), Platform::Windows));
        assert!(!is_altgr_text(ctrl_alt, Some("@"), Platform::Other));
        assert!(!is_altgr_text(ctrl_alt, Some("@"), Platform::MacOs));
        // With the AltGr modifiers dropped the encoder types the character.
        let mut vt = vt();
        assert_eq!(vt.encode_key(GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_Q, 0, 0, Some("@"), Some('q')), b"@");
        assert_eq!(
            vt.encode_key(GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_E, 0, 0, Some("€"), Some('e')),
            "€".as_bytes()
        );
        // Kept, they would have been a control code: the bug this guards against.
        let chorded = ghostty_mods(ctrl_alt);
        assert_ne!(
            vt.encode_key(GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_Q, chorded, 0, Some("@"), Some('q')),
            b"@"
        );
    }

    #[test]
    fn function_keys_up_to_f24_are_sent() {
        let mut vt = vt();
        for n in 1..=24 {
            let bytes = send(&mut vt, &format!("f{n}"), None).unwrap_or_default();
            assert!(!bytes.is_empty(), "f{n}");
        }
        assert_eq!(map_key("f13").map(|k| k.0), Some(GHOSTTY_KEY_F13));
        assert_eq!(map_key("f24").map(|k| k.0), Some(GHOSTTY_KEY_F24));
        assert_eq!(map_key("f25"), None);
    }
}
