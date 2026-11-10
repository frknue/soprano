//! Ghostty `keybind` lines that write to the program, and Ghostty's macOS "natural text
//! editing" defaults (`ghostty/src/config/Config.zig`, `Keybinds.init`). The Swift app ran
//! full libghostty, which applied these before encoding a key; libghostty-vt has no keybind
//! layer, so the terminal applies them itself.
//!
//! Supported actions: `text:<Zig string literal>`, `esc:<s>` (ESC + s), `csi:<s>`
//! (ESC [ + s), `ignore` (the key is swallowed) and `unbind`. `keybind = clear` drops every
//! binding, defaults included; an empty `keybind =` restores the defaults.
//!
//! A binding to any other action (`copy_to_clipboard`, `goto_split:left`, …) belongs to the
//! app, not the terminal: it replaces a default on the same trigger here (as in Ghostty) and
//! is otherwise ignored. Skipped entirely: key sequences (`a>b`), `chain=` lines, key tables
//! (`name/…`), and the `global:` and `all:` prefixes (app-wide bindings). `performable:` is
//! honored as plain (these actions always perform); `unconsumed:` writes the bytes and then
//! lets the key through to the program as well.
//!
//! `super`/`cmd`/`command` is GPUI's platform modifier (Command on macOS, the Super/Windows key
//! elsewhere), Ghostty's own meaning for its config, not Soprano's Ctrl+Shift chord mapping.

use gpui::{Keystroke, Modifiers};

/// The modifiers of a trigger. Matched exactly; sides don't matter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
struct Mods {
    shift: bool,
    ctrl: bool,
    alt: bool,
    super_: bool,
}

/// A key and its modifiers, normalized so a GPUI keystroke and a Ghostty trigger compare.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Trigger {
    /// Ghostty's physical key name (`arrow_left`, `backspace`) or a single unshifted
    /// character (`a`, `;`).
    key: String,
    mods: Mods,
}

/// What a bound key sends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeybindOutput {
    /// Bytes for the program; empty for `ignore` (or text that doesn't parse, which Ghostty
    /// swallows too).
    pub bytes: Vec<u8>,
    /// Whether the key stops here (false with `unconsumed:`: it is also encoded as usual).
    pub consumed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Entry {
    Output(KeybindOutput),
    /// Bound to an app action: nothing for the terminal to send.
    App,
}

/// The terminal's key bindings, in the order Ghostty resolves them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalKeybinds {
    bindings: Vec<(Trigger, Entry)>,
}

impl Default for TerminalKeybinds {
    /// Ghostty's defaults for this OS.
    fn default() -> Self {
        Self::platform_defaults(cfg!(target_os = "macos"))
    }
}

impl TerminalKeybinds {
    /// No bindings at all (`keybind = clear`).
    pub fn empty() -> Self {
        Self { bindings: Vec::new() }
    }

    /// Ghostty's defaults: on macOS the "natural text editing" keys, which force legacy
    /// text instead of fixterms/kitty encoding (⌘⌫ kills the line, ⌘←/⌘→ go to its start
    /// and end, ⌥←/⌥→ move by word).
    pub fn platform_defaults(macos: bool) -> Self {
        let mut binds = Self::empty();
        if macos {
            let s = Mods { super_: true, ..Mods::default() };
            let a = Mods { alt: true, ..Mods::default() };
            for (key, mods, bytes) in [
                ("arrow_right", s, b"\x05".as_slice()),
                ("arrow_left", s, b"\x01"),
                ("backspace", s, b"\x15"),
                ("arrow_left", a, b"\x1bb"),
                ("arrow_right", a, b"\x1bf"),
            ] {
                binds.put(
                    Trigger { key: key.into(), mods },
                    Entry::Output(KeybindOutput { bytes: bytes.to_vec(), consumed: true }),
                );
            }
        }
        binds
    }

    /// The defaults with every `keybind` value applied in order.
    pub fn from_config_values<'a>(values: impl IntoIterator<Item = &'a str>, macos: bool) -> Self {
        let mut binds = Self::platform_defaults(macos);
        for value in values {
            binds.apply(value, macos);
        }
        binds
    }

    /// Applies one `keybind` value; values this layer doesn't handle are skipped.
    pub fn apply(&mut self, value: &str, macos: bool) {
        let value = value.trim();
        match value {
            "" => *self = Self::platform_defaults(macos),
            "clear" => *self = Self::empty(),
            _ => {
                if let Some((trigger, entry)) = parse_binding(value) {
                    match entry {
                        Some(entry) => self.put(trigger, entry),
                        None => self.bindings.retain(|(t, _)| *t != trigger),
                    }
                }
            }
        }
    }

    fn put(&mut self, trigger: Trigger, entry: Entry) {
        match self.bindings.iter_mut().find(|(t, _)| *t == trigger) {
            Some(slot) => slot.1 = entry,
            None => self.bindings.push((trigger, entry)),
        }
    }

    /// What `keystroke` sends when it is bound to bytes for the program.
    pub fn lookup(&self, keystroke: &Keystroke) -> Option<&KeybindOutput> {
        let trigger = trigger_for_keystroke(keystroke)?;
        match &self.bindings.iter().find(|(t, _)| *t == trigger)?.1 {
            Entry::Output(output) => Some(output),
            Entry::App => None,
        }
    }
}

/// `prefixes:trigger=action` → the trigger and what it now does (`None`: unbound).
/// `None` overall for lines this layer skips.
fn parse_binding(value: &str) -> Option<(Trigger, Option<Entry>)> {
    let mut rest = value;
    let mut consumed = true;
    while let Some((prefix, after)) = rest.split_once(':') {
        match prefix {
            "global" | "all" => return None,
            "performable" => {}
            "unconsumed" => consumed = false,
            _ => break,
        }
        rest = after;
    }
    if rest.starts_with("chain=") {
        return None;
    }
    let (trigger, action) = rest.split_once('=')?;
    if trigger.contains('>') || trigger.contains('/') {
        return None;
    }
    let trigger = parse_trigger(trigger)?;
    let (name, param) = match action.split_once(':') {
        Some((name, param)) => (name, Some(param)),
        None => (action, None),
    };
    let output = |bytes: Vec<u8>| Some(Entry::Output(KeybindOutput { bytes, consumed }));
    let entry = match (name, param) {
        ("unbind", None) => None,
        ("ignore", None) => output(Vec::new()),
        // Ghostty swallows a key whose text doesn't parse, sending nothing.
        ("text", Some(text)) => output(parse_zig_string(text).unwrap_or_default()),
        ("esc", Some(s)) => output([b"\x1b".as_slice(), s.as_bytes()].concat()),
        ("csi", Some(s)) => output([b"\x1b[".as_slice(), s.as_bytes()].concat()),
        ("", _) => return None,
        _ => Some(Entry::App),
    };
    Some((trigger, entry))
}

/// `mod+mod+key`, as Ghostty reads it: each modifier once, exactly one key, and a trailing
/// `+` (an empty part) is the `+` key.
fn parse_trigger(input: &str) -> Option<Trigger> {
    if input.is_empty() {
        return None;
    }
    let mut mods = Mods::default();
    let mut key: Option<String> = None;
    for part in input.split('+') {
        let flag = match part {
            "shift" => Some(&mut mods.shift),
            "ctrl" | "control" => Some(&mut mods.ctrl),
            "alt" | "opt" | "option" => Some(&mut mods.alt),
            "super" | "cmd" | "command" => Some(&mut mods.super_),
            _ => None,
        };
        if let Some(flag) = flag {
            if std::mem::replace(flag, true) {
                return None;
            }
            continue;
        }
        if key.is_some() {
            return None;
        }
        key = Some(if part.is_empty() { "+".into() } else { trigger_key_name(part)? });
    }
    let key = key?;
    // A shifted character (`:`) is its unshifted key with Shift.
    let (key, shifted) = unshift(&key);
    if shifted {
        mods.shift = true;
    }
    Some(Trigger { key, mods })
}

/// A trigger key in Ghostty's spelling as this layer's canonical name.
fn trigger_key_name(part: &str) -> Option<String> {
    // W3C codes (`ArrowLeft`, `KeyA`, `Digit1`) as Ghostty's snake_case names.
    let snake = if part.chars().next().is_some_and(|c| c.is_ascii_uppercase()) && part.chars().count() > 1 {
        let mut s = String::new();
        for (i, c) in part.chars().enumerate() {
            if c.is_ascii_uppercase() && i > 0 {
                s.push('_');
            }
            s.push(c.to_ascii_lowercase());
        }
        s.replace("digit", "digit_").replace("digit__", "digit_")
    } else {
        part.to_owned()
    };
    let name = match snake.as_str() {
        // Ghostty 1.1 names it still accepts.
        "up" | "down" | "left" | "right" => format!("arrow_{snake}"),
        "zero" => "0".into(),
        "one" => "1".into(),
        "two" => "2".into(),
        "three" => "3".into(),
        "four" => "4".into(),
        "five" => "5".into(),
        "six" => "6".into(),
        "seven" => "7".into(),
        "eight" => "8".into(),
        "nine" => "9".into(),
        "plus" => "+".into(),
        "apostrophe" | "quote" => "'".into(),
        "grave_accent" | "backquote" => "`".into(),
        "left_bracket" | "bracket_left" => "[".into(),
        "right_bracket" | "bracket_right" => "]".into(),
        "minus" => "-".into(),
        "equal" => "=".into(),
        "comma" => ",".into(),
        "period" => ".".into(),
        "slash" => "/".into(),
        "backslash" => "\\".into(),
        "semicolon" => ";".into(),
        "return" => "enter".into(),
        other => {
            if let Some(letter) = other.strip_prefix("key_").filter(|l| l.len() == 1) {
                letter.into()
            } else if let Some(digit) = other.strip_prefix("digit_").filter(|d| d.len() == 1) {
                digit.into()
            } else if other.chars().count() == 1 {
                other.to_lowercase()
            } else if NAMED.contains(&other) || is_function_key(other) {
                other.into()
            } else {
                return None;
            }
        }
    };
    Some(name)
}

/// Ghostty's physical key names this layer can match against GPUI's keys.
const NAMED: &[&str] = &[
    "enter",
    "tab",
    "escape",
    "backspace",
    "space",
    "delete",
    "insert",
    "home",
    "end",
    "page_up",
    "page_down",
    "arrow_up",
    "arrow_down",
    "arrow_left",
    "arrow_right",
];

fn is_function_key(name: &str) -> bool {
    name.strip_prefix('f').and_then(|n| n.parse::<u8>().ok()).is_some_and(|n| (1..=25).contains(&n))
}

/// A shifted character's unshifted key, and whether it was shifted.
fn unshift(key: &str) -> (String, bool) {
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
    let mut chars = key.chars();
    if let (Some(c), None) = (chars.next(), chars.next())
        && let Some((_, base)) = SHIFTED.iter().find(|(s, _)| *s == c)
    {
        return (base.to_string(), true);
    }
    (key.to_owned(), false)
}

/// A GPUI keystroke in the same terms as a trigger.
fn trigger_for_keystroke(k: &Keystroke) -> Option<Trigger> {
    let key = match k.key.as_str() {
        "up" | "down" | "left" | "right" => format!("arrow_{}", k.key),
        "pageup" => "page_up".into(),
        "pagedown" => "page_down".into(),
        "" => return None,
        other if other.chars().count() == 1 => other.to_lowercase(),
        other => other.to_owned(),
    };
    let (key, shifted) = unshift(&key);
    let m: Modifiers = k.modifiers;
    let mods = Mods { shift: m.shift || shifted, ctrl: m.control, alt: m.alt, super_: m.platform };
    Some(Trigger { key, mods })
}

/// A Zig string literal's bytes, as Ghostty reads `text:` (`config/string.zig`): `\xNN` is
/// one byte; `\n`, `\r`, `\t`, `\\`, `\'`, `\"` and `\u{N}` are characters. Anything else
/// (`\e` included) makes the text invalid.
pub fn parse_zig_string(input: &str) -> Option<Vec<u8>> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'\\' {
            out.push(bytes[i]);
            i += 1;
            continue;
        }
        let escape = *bytes.get(i + 1)?;
        i += 2;
        match escape {
            b'n' => out.push(b'\n'),
            b'r' => out.push(b'\r'),
            b't' => out.push(b'\t'),
            b'\\' => out.push(b'\\'),
            b'\'' => out.push(b'\''),
            b'"' => out.push(b'"'),
            b'x' => {
                let hex = input.get(i..i + 2)?;
                if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return None;
                }
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 2;
            }
            b'u' => {
                let rest = input.get(i..)?.strip_prefix('{')?;
                let end = rest.find('}')?;
                let hex = &rest[..end];
                if hex.is_empty() || hex.len() > 6 {
                    return None;
                }
                let c = char::from_u32(u32::from_str_radix(hex, 16).ok()?)?;
                let mut buf = [0u8; 4];
                out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
                i += 1 + end + 1;
            }
            _ => return None,
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(spec: &str) -> Keystroke {
        let mut parts: Vec<&str> = spec.split('-').collect();
        let key = parts.pop().unwrap_or_default();
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
            key_char: None,
        }
    }

    fn bytes(binds: &TerminalKeybinds, spec: &str) -> Option<Vec<u8>> {
        binds.lookup(&key(spec)).map(|o| o.bytes.clone())
    }

    #[test]
    fn macos_defaults_are_ghosttys_natural_text_editing_keys() {
        let binds = TerminalKeybinds::platform_defaults(true);
        assert_eq!(bytes(&binds, "cmd-backspace"), Some(b"\x15".to_vec()));
        assert_eq!(bytes(&binds, "cmd-left"), Some(b"\x01".to_vec()));
        assert_eq!(bytes(&binds, "cmd-right"), Some(b"\x05".to_vec()));
        assert_eq!(bytes(&binds, "alt-left"), Some(b"\x1bb".to_vec()));
        assert_eq!(bytes(&binds, "alt-right"), Some(b"\x1bf".to_vec()));
        // Exact modifiers only.
        assert_eq!(bytes(&binds, "cmd-shift-left"), None);
        assert_eq!(bytes(&binds, "left"), None);
        assert_eq!(bytes(&binds, "backspace"), None);
        assert!(binds.lookup(&key("cmd-backspace")).is_some_and(|o| o.consumed));
        // Other platforms have none.
        assert_eq!(bytes(&TerminalKeybinds::platform_defaults(false), "alt-left"), None);
    }

    #[test]
    fn a_user_text_binding_sends_its_parsed_bytes_on_every_os() {
        for macos in [true, false] {
            let binds = TerminalKeybinds::from_config_values(["shift+enter=text:\\x1b\\r"], macos);
            assert_eq!(bytes(&binds, "shift-enter"), Some(b"\x1b\r".to_vec()));
            assert_eq!(bytes(&binds, "enter"), None);
        }
    }

    #[test]
    fn unbind_clear_and_an_empty_keybind_follow_ghostty() {
        let mut binds = TerminalKeybinds::from_config_values(["cmd+backspace=unbind"], true);
        assert_eq!(bytes(&binds, "cmd-backspace"), None);
        assert_eq!(bytes(&binds, "cmd-left"), Some(b"\x01".to_vec()));
        binds.apply("clear", true);
        assert_eq!(bytes(&binds, "cmd-left"), None);
        binds.apply("", true);
        assert_eq!(bytes(&binds, "cmd-backspace"), Some(b"\x15".to_vec()));
    }

    #[test]
    fn esc_csi_ignore_and_aliases_parse() {
        let binds = TerminalKeybinds::from_config_values(
            [
                "opt+arrow_up=esc:p",
                "control+ArrowDown=csi:1;5B",
                "command+k=ignore",
                "super+shift+semicolon=text:hi",
                "ctrl+:=text:colon",
                "unconsumed:ctrl+a=text:x",
                "performable:ctrl+b=text:y",
            ],
            false,
        );
        assert_eq!(bytes(&binds, "alt-up"), Some(b"\x1bp".to_vec()));
        assert_eq!(bytes(&binds, "ctrl-down"), Some(b"\x1b[1;5B".to_vec()));
        assert_eq!(bytes(&binds, "cmd-k"), Some(Vec::new()));
        assert_eq!(bytes(&binds, "cmd-shift-;"), Some(b"hi".to_vec()));
        assert_eq!(bytes(&binds, "cmd-:"), Some(b"hi".to_vec()), "a shifted key reads as Shift + its key");
        assert_eq!(bytes(&binds, "ctrl-:"), Some(b"colon".to_vec()));
        assert!(binds.lookup(&key("ctrl-a")).is_some_and(|o| !o.consumed));
        assert!(binds.lookup(&key("ctrl-b")).is_some_and(|o| o.consumed));
    }

    #[test]
    fn app_actions_replace_defaults_and_unsupported_lines_are_ignored() {
        let binds = TerminalKeybinds::from_config_values(
            [
                "cmd+left=goto_split:left",
                "global:cmd+backquote=toggle_quick_terminal",
                "all:cmd+right=text:no",
                "ctrl+a>n=new_window",
                "chain=new_tab",
                "vim/j=text:no",
                "bogus+key=text:x",
                "not a keybind",
                "=text:x",
                "ctrl+x=",
            ],
            true,
        );
        assert_eq!(bytes(&binds, "cmd-left"), None, "an app action replaced the default");
        assert_eq!(bytes(&binds, "cmd-right"), Some(b"\x05".to_vec()), "all: is skipped");
        assert_eq!(bytes(&binds, "cmd-backspace"), Some(b"\x15".to_vec()));
        assert_eq!(bytes(&binds, "ctrl-a"), None);
        assert_eq!(bytes(&binds, "j"), None);
    }

    #[test]
    fn text_follows_zig_string_escapes() {
        assert_eq!(parse_zig_string("\\x1b\\r"), Some(b"\x1b\r".to_vec()));
        assert_eq!(parse_zig_string("a\\n\\t\\\\\\\"\\'"), Some(b"a\n\t\\\"'".to_vec()));
        assert_eq!(parse_zig_string("\\xff"), Some(vec![0xff]), "a byte, not a character");
        assert_eq!(parse_zig_string("\\u{1F600}"), Some("😀".as_bytes().to_vec()));
        assert_eq!(parse_zig_string("é"), Some("é".as_bytes().to_vec()));
        for invalid in ["\\e", "\\x1", "\\xzz", "\\u{}", "\\u{110000}", "trailing\\"] {
            assert_eq!(parse_zig_string(invalid), None, "{invalid}");
        }
        // Text that doesn't parse swallows the key, as in Ghostty.
        let binds = TerminalKeybinds::from_config_values(["ctrl+e=text:\\e[A"], false);
        assert_eq!(bytes(&binds, "ctrl-e"), Some(Vec::new()));
    }
}
