//! The Keyboard Shortcuts page: every binding grouped by category, filtered by the search
//! field, with its keycaps, its problems, and a recorder that rebinds it under
//! `keybindings.bindings.<id>`.

use soprano_config::{
    ConfigIssue, DefaultKeybindings, KeyChord, KeyPlatform, ResolvedConfig, settings_keycap_alternatives_for,
};
use soprano_types::{KeyBinding, KeyBindingCategory, KeyBindingConfig};

/// The page's groups, in order.
pub const SHORTCUT_GROUPS: [(&str, KeyBindingCategory); 4] = [
    ("Navigation", KeyBindingCategory::Navigation),
    ("Layout & splits", KeyBindingCategory::Layout),
    ("Agent launchers", KeyBindingCategory::Agents),
    ("General", KeyBindingCategory::General),
];

pub const SEARCH_PLACEHOLDER: &str = "Search shortcuts";
pub const NO_MATCHES_TITLE: &str = "No matching shortcuts";
pub const NO_MATCHES_HINT: &str = "Try an action name, id or shortcut.";
pub const CUSTOMIZED_TOOLTIP: &str = "Customized in settings.json";

/// The key a binding is rebound under.
pub fn binding_key_path(id: &str) -> [&str; 3] {
    ["keybindings", "bindings", id]
}

/// One row: the binding in force (or the built-in one, when the file turned it off).
#[derive(Clone, Debug, PartialEq)]
pub struct ShortcutEntry {
    pub binding: KeyBinding,
    pub is_disabled: bool,
    pub is_customized: bool,
    /// One cap list per alternative (`⌘+` or `⌘=`); empty when disabled.
    pub caps: Vec<Vec<String>>,
    /// Problems `settings.json` has with this binding (conflicts, bad chords).
    pub issues: Vec<ConfigIssue>,
}

impl ShortcutEntry {
    /// Customized and disabled rows can go back to the built-in shortcut.
    pub fn is_resettable(&self) -> bool {
        self.is_customized || self.is_disabled
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShortcutGroup {
    pub title: &'static str,
    pub category: KeyBindingCategory,
    pub entries: Vec<ShortcutEntry>,
}

/// The groups that have a match for `query`, in page order. Disabled bindings still belong on
/// the list: a shortcut that is missing because the file switched it off should be visibly off,
/// not simply absent.
pub fn shortcut_groups(resolved: &ResolvedConfig, issues: &[ConfigIssue], query: &str) -> Vec<ShortcutGroup> {
    shortcut_groups_for(resolved, issues, query, KeyPlatform::current())
}

pub fn shortcut_groups_for(
    resolved: &ResolvedConfig,
    issues: &[ConfigIssue],
    query: &str,
    platform: KeyPlatform,
) -> Vec<ShortcutGroup> {
    let config = &resolved.keybindings;
    let defaults = DefaultKeybindings::config_for(platform);
    SHORTCUT_GROUPS
        .iter()
        .filter_map(|&(title, category)| {
            let active = config.bindings.iter().filter(|b| b.category == category).map(|b| (b, false));
            let disabled = defaults
                .bindings
                .iter()
                .filter(|b| b.category == category && resolved.disabled_binding_ids.contains(&b.id))
                .map(|b| (b, true));
            let entries: Vec<ShortcutEntry> = active
                .chain(disabled)
                .filter(|(binding, is_disabled)| {
                    matches_query(binding, *is_disabled, query, config, platform)
                })
                .map(|(binding, is_disabled)| ShortcutEntry {
                    binding: binding.clone(),
                    is_disabled,
                    is_customized: resolved.customized_binding_ids.contains(&binding.id),
                    caps: if is_disabled {
                        Vec::new()
                    } else {
                        settings_keycap_alternatives_for(binding, &config.prefix_key, platform)
                    },
                    issues: issues_for_binding(issues, &binding.id),
                })
                .collect();
            (!entries.is_empty()).then_some(ShortcutGroup { title, category, entries })
        })
        .collect()
}

/// Bindings matching the filter: label, id, description or keys.
fn matches_query(
    binding: &KeyBinding,
    is_disabled: bool,
    query: &str,
    config: &KeyBindingConfig,
    platform: KeyPlatform,
) -> bool {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return true;
    }
    let caps: Vec<String> = if is_disabled {
        Vec::new()
    } else {
        settings_keycap_alternatives_for(binding, &config.prefix_key, platform)
            .into_iter()
            .map(|caps| caps.join(" "))
            .collect()
    };
    [&binding.label, &binding.id, &binding.description]
        .into_iter()
        .chain(caps.iter())
        .any(|text| text.to_lowercase().contains(&needle))
}

/// The issues naming this binding: the resolver quotes ids (`"close-pane" and "kill-pane" are
/// both bound to …`, `keybindings.bindings.close-pane: "x+y" is not a valid chord.`).
pub fn issues_for_binding(issues: &[ConfigIssue], id: &str) -> Vec<ConfigIssue> {
    let quoted = format!("\"{id}\"");
    let origin = format!("keybindings.bindings.{id}:");
    issues
        .iter()
        .filter(|issue| issue.message.contains(&quoted) || issue.message.contains(&origin))
        .cloned()
        .collect()
}

/// The issues about keybindings in general, shown above the list.
pub fn keybinding_issues(issues: &[ConfigIssue]) -> Vec<ConfigIssue> {
    issues
        .iter()
        .filter(|issue| issue.message.contains("keybindings") || issue.message.contains(" bound to "))
        .cloned()
        .collect()
}

/// The page's instructions, with a real, currently-bound action as the example so it always
/// names something the reader can find in the list.
pub fn instructions(config: &KeyBindingConfig) -> String {
    let id = config
        .bindings
        .iter()
        .find(|b| b.id == "split-vertical")
        .or_else(|| config.bindings.first())
        .map_or("split-vertical", |b| b.id.as_str());
    let chord = config
        .bindings
        .iter()
        .find(|b| b.id == id)
        .map_or_else(|| "prefix+shift+|".to_owned(), |b| KeyChord::from_binding(b).canonical_string());
    format!(
        "The shortcuts in effect. Click a shortcut and press new keys to rebind it, or rebind any of them by id under \"keybindings.bindings\" in settings.json — for example \"{id}\": \"{chord}\" — or set one to null to turn it off."
    )
}

// MARK: - Recording

/// One keystroke as GPUI reports it: `key` is the key without Shift (`"b"`, `"1"`, `"escape"`,
/// `"left"`), `key_char` what it types with Shift applied (`"B"`, `"!"`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RecordedKey {
    pub key: String,
    pub key_char: Option<String>,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    /// ⌘ on macOS, the Super/Windows key elsewhere.
    pub platform: bool,
}

impl RecordedKey {
    pub fn new(key: impl Into<String>) -> Self {
        Self { key: key.into(), ..Self::default() }
    }

    fn has_modifiers(&self) -> bool {
        self.ctrl || self.alt || self.shift || self.platform
    }
}

/// What a keystroke did to a recording.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordStep {
    /// The prefix chord was pressed; the next key completes `prefix+<key>`.
    AwaitingPrefixKey,
    /// The chord to write, canonical (`"cmd+shift+p"`, `"prefix+shift+n"`).
    Bound(String),
    /// Backspace: turn the shortcut off (`null`).
    TurnOff,
    /// Esc: stop recording, keep the shortcut.
    Cancel,
    /// A key Soprano cannot bind (Option/Alt chords on macOS, function keys, bare keys);
    /// the recording continues.
    Refused,
}

/// Records one shortcut. Press the prefix chord (`⌃A`) first for a prefix binding.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChordRecorder {
    prefix_key: String,
    platform: KeyPlatform,
    awaiting_prefix_key: bool,
}

impl ChordRecorder {
    pub fn new(prefix_key: &str, platform: KeyPlatform) -> Self {
        Self { prefix_key: prefix_key.to_lowercase(), platform, awaiting_prefix_key: false }
    }

    pub fn is_awaiting_prefix_key(&self) -> bool {
        self.awaiting_prefix_key
    }

    pub fn key(&mut self, key: &RecordedKey) -> RecordStep {
        if !key.has_modifiers() {
            match key.key.as_str() {
                "escape" => return RecordStep::Cancel,
                "backspace" | "delete" if !self.awaiting_prefix_key => return RecordStep::TurnOff,
                _ => {}
            }
        }
        let Some(token) = key_token(key) else { return RecordStep::Refused };

        if self.awaiting_prefix_key {
            // Prefix matching ignores Ctrl/Cmd, so only Shift may come with the second key.
            if key.ctrl || key.alt || key.platform {
                return RecordStep::Refused;
            }
            let shift = if key.shift && !is_symbol_token(&token) { "shift+" } else { "" };
            return parsed(&format!("prefix+{shift}{token}"));
        }

        let Some((ctrl, meta, shift)) = self.chord_modifiers(key) else { return RecordStep::Refused };
        if ctrl && !meta && !shift && token == self.prefix_key {
            self.awaiting_prefix_key = true;
            return RecordStep::AwaitingPrefixKey;
        }
        // A bare (or Shift-only) key would steal ordinary typing from every terminal.
        if !ctrl && !meta {
            return RecordStep::Refused;
        }
        let mut parts = Vec::new();
        if ctrl {
            parts.push("ctrl");
        }
        if meta {
            parts.push("cmd");
        }
        if shift && !is_symbol_token(&token) {
            parts.push("shift");
        }
        parts.push(&token);
        parsed(&parts.join("+"))
    }

    /// The chord's ctrl/cmd/shift flags for the physical modifiers, inverting the platform
    /// table soprano-config renders with: on Linux/Windows `cmd` is Ctrl+Shift, `cmd+shift`
    /// Ctrl+Shift+Alt and `ctrl+cmd` Ctrl+Alt.
    fn chord_modifiers(&self, key: &RecordedKey) -> Option<(bool, bool, bool)> {
        match self.platform {
            KeyPlatform::Mac => (!key.alt).then_some((key.ctrl, key.platform, key.shift)),
            KeyPlatform::Other => {
                if key.platform {
                    return None;
                }
                match (key.ctrl, key.shift, key.alt) {
                    (true, true, true) => Some((false, true, true)),
                    (true, true, false) => Some((false, true, false)),
                    (true, false, true) => Some((true, true, false)),
                    (true, false, false) => Some((true, false, false)),
                    (false, shift, false) => Some((false, false, shift)),
                    (false, _, true) => None,
                }
            }
        }
    }
}

/// The chord token for the pressed key: a named key, the symbol Shift typed (`|`), or the
/// key itself. `None` for keys a chord cannot name (F-keys, Home, Page Up…).
fn key_token(key: &RecordedKey) -> Option<String> {
    let named = match key.key.as_str() {
        "space" => Some("space"),
        "tab" => Some("tab"),
        "enter" => Some("enter"),
        "escape" => Some("escape"),
        "backspace" => Some("backspace"),
        "delete" => Some("delete"),
        "up" => Some("up"),
        "down" => Some("down"),
        "left" => Some("left"),
        "right" => Some("right"),
        _ => None,
    };
    if let Some(named) = named {
        return Some(named.to_owned());
    }
    let mut chars = key.key.chars();
    let (Some(base), None) = (chars.next(), chars.next()) else { return None };
    // Shift turns some keys into another symbol ("\\" → "|"); bind the symbol it typed.
    let typed = key
        .key_char
        .as_deref()
        .filter(|typed| key.shift && typed.chars().count() == 1 && !base.is_alphabetic())
        .and_then(|typed| typed.chars().next())
        .unwrap_or(base);
    Some(match typed {
        '+' => "plus".to_owned(),
        other => other.to_lowercase().collect(),
    })
}

fn is_symbol_token(token: &str) -> bool {
    token == "plus" || soprano_config::key_chord::is_shifted_symbol(token)
}

fn parsed(text: &str) -> RecordStep {
    KeyChord::parse(text).map_or(RecordStep::Refused, |chord| RecordStep::Bound(chord.canonical_string()))
}

/// The recorder's hint while it waits.
pub fn recording_hint(awaiting_prefix_key: bool, prefix_key: &str, platform: KeyPlatform) -> String {
    if awaiting_prefix_key {
        format!("{} then…", soprano_config::prefix_legend_for(prefix_key, platform))
    } else {
        "Press keys · Esc cancels · ⌫ turns off".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::{BindingOverride, KeybindingsConfig, SopranoConfig};
    use std::collections::BTreeMap;

    fn resolved_with(bindings: &[(&str, Option<&str>)]) -> ResolvedConfig {
        let mut overrides = BTreeMap::new();
        for (id, chord) in bindings {
            overrides.insert(
                id.to_string(),
                chord.map_or(BindingOverride::Disabled, |c| BindingOverride::Chord(c.to_string())),
            );
        }
        SopranoConfig {
            keybindings: Some(KeybindingsConfig { bindings: Some(overrides), ..Default::default() }),
            ..Default::default()
        }
        .resolved()
    }

    fn ids(groups: &[ShortcutGroup]) -> Vec<String> {
        groups.iter().flat_map(|g| g.entries.iter().map(|e| e.binding.id.clone())).collect()
    }

    #[test]
    fn the_unfiltered_page_lists_every_binding_in_its_category_group() {
        let resolved = ResolvedConfig::defaults();
        let groups = shortcut_groups_for(&resolved, &[], "", KeyPlatform::Mac);
        let titles: Vec<&str> = groups.iter().map(|g| g.title).collect();
        assert_eq!(titles, ["Navigation", "Layout & splits", "Agent launchers", "General"]);
        assert_eq!(ids(&groups).len(), resolved.keybindings.bindings.len());
        for group in &groups {
            assert!(group.entries.iter().all(|e| e.binding.category == group.category));
        }
    }

    #[test]
    fn a_split_query_keeps_layout_and_drops_navigation() {
        let groups = shortcut_groups_for(&ResolvedConfig::defaults(), &[], "split", KeyPlatform::Mac);
        assert!(groups.iter().any(|g| g.title == "Layout & splits"));
        assert!(!groups.iter().any(|g| g.title == "Navigation"));
    }

    #[test]
    fn the_filter_matches_ids_descriptions_and_keycaps() {
        let resolved = ResolvedConfig::defaults();
        assert!(
            ids(&shortcut_groups_for(&resolved, &[], "  COMMAND-PALETTE ", KeyPlatform::Mac))
                .contains(&"command-palette".to_owned())
        );
        let by_caps = ids(&shortcut_groups_for(&resolved, &[], "⌘P", KeyPlatform::Mac));
        assert!(by_caps.contains(&"command-palette".to_owned()));
        assert!(shortcut_groups_for(&resolved, &[], "zzz-no-such", KeyPlatform::Mac).is_empty());
    }

    #[test]
    fn a_disabled_binding_stays_listed_as_off_and_resettable() {
        let resolved = resolved_with(&[("close-pane", None)]);
        let groups = shortcut_groups_for(&resolved, &[], "close-pane", KeyPlatform::Mac);
        let entry =
            groups.iter().flat_map(|g| &g.entries).find(|e| e.binding.id == "close-pane").expect("listed");
        assert!(entry.is_disabled);
        assert!(entry.caps.is_empty());
        assert!(entry.is_resettable());
    }

    #[test]
    fn a_customized_binding_is_marked_and_shows_its_new_caps() {
        let resolved = resolved_with(&[("command-palette", Some("cmd+escape"))]);
        let groups = shortcut_groups_for(&resolved, &[], "command-palette", KeyPlatform::Mac);
        let entry = &groups[0].entries[0];
        assert!(entry.is_customized);
        assert_eq!(entry.caps, vec![vec!["⌘esc".to_owned()]]);
    }

    #[test]
    fn a_conflict_is_shown_on_both_bindings_it_names() {
        let resolved = resolved_with(&[("new-tab", Some("cmd+p"))]);
        let issues = resolved.issues.clone();
        assert!(!keybinding_issues(&issues).is_empty());
        let groups = shortcut_groups_for(&resolved, &issues, "", KeyPlatform::Mac);
        let flagged: Vec<&str> = groups
            .iter()
            .flat_map(|g| &g.entries)
            .filter(|e| !e.issues.is_empty())
            .map(|e| e.binding.id.as_str())
            .collect();
        assert!(flagged.contains(&"new-tab"), "{flagged:?}");
    }

    #[test]
    fn the_instructions_name_a_real_binding_and_its_chord() {
        let text = instructions(&DefaultKeybindings::config_for(KeyPlatform::Mac));
        assert!(text.contains("\"split-vertical\": \"prefix+|\""), "{text}");
    }

    fn key(key: &str) -> RecordedKey {
        RecordedKey::new(key)
    }

    #[test]
    fn a_mac_command_chord_records_canonically() {
        let mut recorder = ChordRecorder::new("a", KeyPlatform::Mac);
        let step = recorder.key(&RecordedKey { platform: true, shift: true, ..key("p") });
        assert_eq!(step, RecordStep::Bound("cmd+shift+p".into()));
        let step = recorder.key(&RecordedKey { platform: true, ..key("escape") });
        assert_eq!(step, RecordStep::Bound("cmd+escape".into()));
        let step = recorder.key(&RecordedKey {
            platform: true,
            shift: true,
            key_char: Some("+".into()),
            ..key("=")
        });
        assert_eq!(step, RecordStep::Bound("cmd+plus".into()));
    }

    #[test]
    fn the_prefix_chord_then_a_key_records_a_prefix_binding() {
        let mut recorder = ChordRecorder::new("a", KeyPlatform::Mac);
        assert_eq!(recorder.key(&RecordedKey { ctrl: true, ..key("a") }), RecordStep::AwaitingPrefixKey);
        assert!(recorder.is_awaiting_prefix_key());
        let step = recorder.key(&RecordedKey { shift: true, key_char: Some("|".into()), ..key("\\") });
        assert_eq!(step, RecordStep::Bound("prefix+|".into()));

        let mut recorder = ChordRecorder::new("a", KeyPlatform::Mac);
        recorder.key(&RecordedKey { ctrl: true, ..key("a") });
        assert_eq!(
            recorder.key(&RecordedKey { shift: true, key_char: Some("N".into()), ..key("n") }),
            RecordStep::Bound("prefix+shift+n".into())
        );
    }

    #[test]
    fn esc_cancels_backspace_turns_off_and_unbindable_keys_are_refused() {
        let mut recorder = ChordRecorder::new("a", KeyPlatform::Mac);
        assert_eq!(recorder.key(&key("escape")), RecordStep::Cancel);
        assert_eq!(recorder.key(&key("backspace")), RecordStep::TurnOff);
        assert_eq!(recorder.key(&key("p")), RecordStep::Refused);
        assert_eq!(recorder.key(&RecordedKey { alt: true, platform: true, ..key("p") }), RecordStep::Refused);
        assert_eq!(recorder.key(&RecordedKey { platform: true, ..key("f5") }), RecordStep::Refused);
    }

    #[test]
    fn linux_and_windows_chords_map_back_to_cmd() {
        let mut recorder = ChordRecorder::new("a", KeyPlatform::Other);
        let ctrl_shift = RecordedKey { ctrl: true, shift: true, key_char: Some("P".into()), ..key("p") };
        assert_eq!(recorder.key(&ctrl_shift), RecordStep::Bound("cmd+p".into()));
        let ctrl_shift_alt = RecordedKey { ctrl: true, shift: true, alt: true, ..key("s") };
        assert_eq!(recorder.key(&ctrl_shift_alt), RecordStep::Bound("cmd+shift+s".into()));
        assert_eq!(
            recorder.key(&RecordedKey { ctrl: true, alt: true, ..key("k") }),
            RecordStep::Bound("ctrl+cmd+k".into())
        );
        assert_eq!(recorder.key(&RecordedKey { ctrl: true, ..key("h") }), RecordStep::Bound("ctrl+h".into()));
        assert_eq!(recorder.key(&RecordedKey { platform: true, ..key("h") }), RecordStep::Refused);
    }

    #[test]
    fn recorded_chords_render_like_the_built_in_ones() {
        let mut recorder = ChordRecorder::new("a", KeyPlatform::Other);
        let RecordStep::Bound(text) = recorder.key(&RecordedKey { ctrl: true, shift: true, ..key("p") })
        else {
            panic!("bound")
        };
        let chord = KeyChord::parse(&text).expect("parses");
        assert_eq!(chord.display_string_for(KeyPlatform::Other), "Ctrl+Shift+P");
    }
}
