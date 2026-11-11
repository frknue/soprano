//! Default keybinding configuration (`Config/DefaultKeybindings.swift`) and the migration of
//! keybindings customized before `settings.json` existed.

use soprano_platform::StateStore;
use soprano_types::{KeyBinding, KeyBindingCategory, KeyBindingConfig, KeyBindingMode};

use crate::key_chord::{KeyChord, KeyPlatform};

use KeyBindingCategory::{Agents, General, Layout, Navigation};
use KeyBindingMode::{Direct, Prefix};

/// Modifier flags of a table row: ctrl, meta (cmd), shift.
const NONE: (bool, bool, bool) = (false, false, false);
const CTRL: (bool, bool, bool) = (true, false, false);
const CTRL_SHIFT: (bool, bool, bool) = (true, false, true);
const SHIFT: (bool, bool, bool) = (false, false, true);
const CMD: (bool, bool, bool) = (false, true, false);
const CMD_SHIFT: (bool, bool, bool) = (false, true, true);
const CTRL_CMD: (bool, bool, bool) = (true, true, false);

type Row = (
    &'static str,
    &'static str,
    &'static str,
    KeyBindingCategory,
    &'static str,
    KeyBindingMode,
    &'static str,
    (bool, bool, bool),
);

/// Every built-in binding: id, label, description, category, macOS `defaultKeys`, mode, key,
/// modifiers. Order matters: on a chord collision the first binding wins.
#[rustfmt::skip]
const TABLE: &[Row] = &[
    // Navigation (direct: Ctrl+H/J/K/L)
    ("nav-left", "Focus Left", "Move focus to the pane on the left", Navigation, "Ctrl+H", Direct, "h", CTRL),
    ("nav-down", "Focus Down", "Move focus to the pane below", Navigation, "Ctrl+J", Direct, "j", CTRL),
    ("nav-up", "Focus Up", "Move focus to the pane above", Navigation, "Ctrl+K", Direct, "k", CTRL),
    ("nav-right", "Focus Right", "Move focus to the pane on the right", Navigation, "Ctrl+L", Direct, "l", CTRL),
    ("previous-window", "Previous Window", "Switch to the previous logical window", Navigation, "Prefix → P", Prefix, "p", NONE),
    ("next-window", "Next Window", "Switch to the next logical window", Navigation, "Prefix → N", Prefix, "n", NONE),
    ("last-window", "Last Window", "Switch to the most recently active logical window", Navigation, "Prefix → Shift+L", Prefix, "l", SHIFT),
    ("previous-window-direct", "Previous Window (Direct)", "Switch to the previous logical window without the prefix", Navigation, "Ctrl+Shift+H", Direct, "h", CTRL_SHIFT),
    ("next-window-direct", "Next Window (Direct)", "Switch to the next logical window without the prefix", Navigation, "Ctrl+Shift+L", Direct, "l", CTRL_SHIFT),
    ("select-window-1", "Select Window 1", "Switch to logical window 1", Navigation, "Ctrl+1", Direct, "1", CTRL),
    ("select-window-2", "Select Window 2", "Switch to logical window 2", Navigation, "Ctrl+2", Direct, "2", CTRL),
    ("select-window-3", "Select Window 3", "Switch to logical window 3", Navigation, "Ctrl+3", Direct, "3", CTRL),
    ("select-window-4", "Select Window 4", "Switch to logical window 4", Navigation, "Ctrl+4", Direct, "4", CTRL),
    ("select-window-5", "Select Window 5", "Switch to logical window 5", Navigation, "Ctrl+5", Direct, "5", CTRL),
    ("select-window-6", "Select Window 6", "Switch to logical window 6", Navigation, "Ctrl+6", Direct, "6", CTRL),
    ("select-window-7", "Select Window 7", "Switch to logical window 7", Navigation, "Ctrl+7", Direct, "7", CTRL),
    ("select-window-8", "Select Window 8", "Switch to logical window 8", Navigation, "Ctrl+8", Direct, "8", CTRL),
    ("select-window-9", "Select Window 9", "Switch to logical window 9", Navigation, "Ctrl+9", Direct, "9", CTRL),

    // Resize (prefix: Ctrl+A → H/J/K/L)
    ("resize-left", "Shrink Left", "Shrink the active pane to the left", Layout, "Prefix → H", Prefix, "h", NONE),
    ("resize-down", "Grow Down", "Grow the active pane downward", Layout, "Prefix → J", Prefix, "j", NONE),
    ("resize-up", "Shrink Up", "Shrink the active pane upward", Layout, "Prefix → K", Prefix, "k", NONE),
    ("resize-right", "Grow Right", "Grow the active pane to the right", Layout, "Prefix → L", Prefix, "l", NONE),

    // Layout (prefix)
    ("new-session", "New Session…", "Create a named session with its own windows", General, "Prefix → Shift+C", Prefix, "c", SHIFT),
    ("find-session", "Switch Session…", "Switch between running sessions", Navigation, "Prefix → S", Prefix, "s", NONE),
    ("machine-terminal", "Terminal on Machine…", "Open a terminal on a machine from settings beside the active pane", Layout, "Prefix → Shift+M", Prefix, "m", SHIFT),
    ("split-horizontal", "Split Horizontal", "Split the active pane horizontally", Layout, "Prefix → -", Prefix, "-", NONE),
    ("split-vertical", "Split Vertical", "Split the active pane vertically", Layout, "Prefix → |", Prefix, "|", SHIFT),
    ("close-pane", "Close Pane", "Close the active pane", Layout, "Prefix → Q", Prefix, "q", NONE),
    ("kill-pane", "Close Tab or Pane", "Close the active pane tab, or the pane when it has only one", Layout, "Prefix → X", Prefix, "x", NONE),
    ("maximize-pane", "Maximize", "Toggle maximize for the active pane", Layout, "Prefix → M", Prefix, "m", NONE),
    ("copy-mode", "Copy Mode", "Browse scrollback and select text with Vim keys", Layout, "Prefix → [", Prefix, "[", NONE),
    ("copy-mode-right-bracket", "Copy Mode", "Browse scrollback and select text with Vim keys", Layout, "Prefix → ]", Prefix, "]", NONE),
    ("new-window-current-directory", "New Window Here", "Create a logical window in the active terminal directory", Layout, "Prefix → C", Prefix, "c", NONE),

    // Tabs: each holds its own split layout (direct: ⌘T, Ctrl+Tab; prefix: T/W)
    ("new-tab", "New Tab", "Open a tab with a new terminal in the active terminal's directory", Layout, "Prefix → T", Prefix, "t", NONE),
    ("new-tab-direct", "New Tab (Direct)", "Open a tab with a new terminal without the prefix", Layout, "⌘T", Direct, "t", CMD),
    ("close-tab", "Close Tab", "Close the active tab and every pane in it", Layout, "Prefix → W", Prefix, "w", NONE),
    ("next-tab", "Next Tab", "Switch to the next tab of the active window", Navigation, "Ctrl+Tab", Direct, "\t", CTRL),
    ("previous-tab", "Previous Tab", "Switch to the previous tab of the active window", Navigation, "Ctrl+Shift+Tab", Direct, "\t", CTRL_SHIFT),

    // Pane tabs: tabs inside one pane (split), such as open files (prefix: Shift+T / > / < /
    // Shift+W; direct: ⌃⌘ with T / → / ← / W, which neither the shell nor macOS uses)
    ("new-pane-tab", "New Pane Tab", "Open a terminal tab inside the active pane", Layout, "Prefix → Shift+T", Prefix, "t", SHIFT),
    ("new-pane-tab-direct", "New Pane Tab (Direct)", "Open a terminal tab inside the active pane without the prefix", Layout, "⌃⌘T", Direct, "t", CTRL_CMD),
    ("next-pane-tab", "Next Pane Tab", "Switch to the next tab inside the active pane", Layout, "Prefix → >", Prefix, ">", SHIFT),
    ("next-pane-tab-direct", "Next Pane Tab (Direct)", "Switch to the next tab inside the active pane without the prefix", Navigation, "⌃⌘→", Direct, "\u{F703}", CTRL_CMD),
    ("prev-pane-tab", "Previous Pane Tab", "Switch to the previous tab inside the active pane", Layout, "Prefix → <", Prefix, "<", SHIFT),
    ("prev-pane-tab-direct", "Previous Pane Tab (Direct)", "Switch to the previous tab inside the active pane without the prefix", Navigation, "⌃⌘←", Direct, "\u{F702}", CTRL_CMD),
    ("close-pane-tab", "Close Pane Tab", "Close the active tab inside the active pane", Layout, "Prefix → Shift+W", Prefix, "w", SHIFT),
    ("close-pane-tab-direct", "Close Pane Tab (Direct)", "Close the active tab inside the active pane without the prefix", Layout, "⌃⌘W", Direct, "w", CTRL_CMD),

    // Agents (direct: Cmd+1/2/3/4)
    ("launch-codex", "Launch Codex", "Launch Codex agent", Agents, "⌘1", Direct, "1", CMD),
    ("launch-claude-code", "Launch Claude", "Launch Claude Code agent", Agents, "⌘2", Direct, "2", CMD),
    ("launch-opencode", "Launch OpenCode", "Launch OpenCode agent", Agents, "⌘3", Direct, "3", CMD),
    ("launch-omp", "Launch omp", "Launch Oh My Pi agent", Agents, "⌘4", Direct, "4", CMD),
    ("new-chat", "New Chat", "Open a chat with an agent beside the focused pane", Agents, "⌘I", Direct, "i", CMD),
    ("agent-dashboard", "Agent Dashboard", "Monitor and control agents across all windows", Agents, "⇧⌘D", Direct, "d", CMD_SHIFT),
    ("statistics", "Statistics", "Show omp's tokens and estimated cost over time", Agents, "⇧⌘U", Direct, "u", CMD_SHIFT),

    // General (direct)
    ("command-palette", "Commands", "Open the command palette", General, "⌘P", Direct, "p", CMD),
    ("find-window", "Find Window", "Search and switch to a logical window", General, "⌘F", Direct, "f", CMD),
    ("open-project", "Open Project", "Open a project directory", General, "⇧⌘P", Direct, "p", CMD_SHIFT),
    ("new-window", "New Window", "Create a new logical window", General, "⌘N", Direct, "n", CMD),
    ("rename-window", "Rename Window", "Rename the active logical window", General, "⇧⌘R", Direct, "r", CMD_SHIFT),
    ("close-window", "Close Window", "Close the active logical window", General, "⇧⌘W", Direct, "w", CMD_SHIFT),
    ("new-terminal", "New Terminal", "Open a new terminal pane beside the focused pane", General, "⌘D", Direct, "d", CMD),
    ("new-browser", "New Browser", "Split a browser pane to the right", General, "⌘B", Direct, "b", CMD),
    ("close-active", "Close Tab or Pane", "Close the active pane tab, or the pane when it has only one", General, "⌘W", Direct, "w", CMD),
    ("save-session", "Save Workspace As…", "Save all sessions and their layouts as a workspace snapshot", General, "⇧⌘S", Direct, "s", CMD_SHIFT),
    ("toggle-sidebar", "Toggle Sidebar", "Show or hide the sidebar", General, "⌘E", Direct, "e", CMD),
    ("toggle-right-sidebar", "Toggle Right Sidebar", "Show or hide the right sidebar (a focused browser pane keeps ⌘L for its address bar)", General, "⌘L", Direct, "l", CMD),
    ("toggle-explorer", "Toggle Explorer", "Show and focus the file explorer sidebar, or hide it while it has focus", General, "⇧⌘E", Direct, "e", CMD_SHIFT),
    ("toggle-source-control", "Toggle Source Control", "Show and focus the Source Control sidebar, or hide it while it has focus", General, "⇧⌘G", Direct, "g", CMD_SHIFT),
    ("open-settings", "Settings", "Open the settings page", General, "⌘,", Direct, ",", CMD),
    ("zoom-in", "Zoom In", "Increase font size", General, "⌘+ / ⌘=", Direct, "=", CMD),
    ("zoom-out", "Zoom Out", "Decrease font size", General, "⌘-", Direct, "-", CMD),
    ("zoom-reset", "Reset Zoom", "Reset font size to default", General, "⌘0", Direct, "0", CMD),

    // General (prefix)
    ("open-in-soprano-git", "Open in Soprano Git", "Open the active tab's Git repository in Soprano Git", General, "Prefix → G", Prefix, "g", NONE),
];

/// Default keybinding configuration.
pub struct DefaultKeybindings;

impl DefaultKeybindings {
    /// The legacy persistence key (`UserDefaults` → `StateStore`).
    pub const STATE_KEY: &'static str = "soprano-keybindings";

    /// The built-in configuration on the running OS.
    pub fn config() -> KeyBindingConfig {
        Self::config_for(KeyPlatform::current())
    }

    /// The built-in configuration with `default_keys` rendered for `platform`: the shipped
    /// macOS strings verbatim, or the worded Linux/Windows form (`Ctrl+Shift+P`).
    pub fn config_for(platform: KeyPlatform) -> KeyBindingConfig {
        let bindings = TABLE
            .iter()
            .map(|&(id, label, description, category, default_keys, mode, key, (ctrl, meta, shift))| {
                let mut binding = KeyBinding {
                    id: id.into(),
                    label: label.into(),
                    description: description.into(),
                    category,
                    default_keys: default_keys.into(),
                    mode,
                    key: key.into(),
                    ctrl: ctrl.then_some(true),
                    meta: meta.then_some(true),
                    shift: shift.then_some(true),
                };
                if platform != KeyPlatform::Mac {
                    binding.default_keys = platform_default_keys(&binding, platform);
                }
                binding
            })
            .collect();
        KeyBindingConfig {
            prefix_key: "a".into(),
            prefix_timeout_ms: 1500,
            resize_tick_percent: 5.0,
            bindings,
        }
    }

    // MARK: - Legacy persistence

    /// Reads keybindings customized before `settings.json` existed, so the config store can
    /// carry them into the new file on first launch. Current customizations live in that file;
    /// nothing writes here any more.
    pub fn load(store: &StateStore) -> KeyBindingConfig {
        match store.get::<KeyBindingConfig>(Self::STATE_KEY) {
            Some(saved) => Self::merged_config(&saved),
            None => Self::config(),
        }
    }

    pub fn merged_config(saved: &KeyBindingConfig) -> KeyBindingConfig {
        let bindings = Self::config()
            .bindings
            .into_iter()
            .map(|default_binding| match saved.bindings.iter().find(|b| b.id == default_binding.id) {
                Some(saved_binding) => migrate_legacy_binding(saved_binding, default_binding),
                None => default_binding,
            })
            .collect();
        KeyBindingConfig {
            prefix_key: saved.prefix_key.clone(),
            prefix_timeout_ms: saved.prefix_timeout_ms,
            resize_tick_percent: saved.resize_tick_percent,
            bindings,
        }
    }
}

/// `zoom-in` advertises both of its spellings, as the macOS table does (`⌘+ / ⌘=`).
fn platform_default_keys(binding: &KeyBinding, platform: KeyPlatform) -> String {
    let chord = KeyChord::from_binding(binding);
    if binding.id == "zoom-in" {
        let plus = KeyChord { key: "+".into(), ..chord.clone() };
        return format!("{} / {}", plus.display_string_for(platform), chord.display_string_for(platform));
    }
    chord.display_string_for(platform)
}

fn is(flag: Option<bool>) -> bool {
    flag == Some(true)
}

fn migrate_legacy_binding(saved: &KeyBinding, default_binding: KeyBinding) -> KeyBinding {
    if saved.id.starts_with("select-window-")
        && saved.mode == Direct
        && saved.id.ends_with(saved.key.as_str())
        && saved.key.chars().count() == 1
        && is(saved.ctrl)
        && !is(saved.meta)
        && is(saved.shift)
    {
        return default_binding;
    }

    let plain_prefix = saved.mode == Prefix && !is(saved.ctrl) && !is(saved.meta);
    let uses_legacy_window_tab_or_resize_default = match saved.id.as_str() {
        "previous-window" => {
            saved.mode == Direct && saved.key == "h" && is(saved.ctrl) && !is(saved.meta) && is(saved.shift)
        }
        "next-window" => {
            saved.mode == Direct && saved.key == "l" && is(saved.ctrl) && !is(saved.meta) && is(saved.shift)
        }
        "last-window" => {
            plain_prefix && ((saved.key == "l" && !is(saved.shift)) || (saved.key == "p" && is(saved.shift)))
        }
        "prev-pane-tab" => plain_prefix && saved.key == "p",
        "next-pane-tab" => plain_prefix && saved.key == "n",
        // Prefix → T and W now open and close tabs; pane tabs took their Shift variants.
        "new-pane-tab" => plain_prefix && saved.key == "t" && !is(saved.shift),
        "close-pane-tab" => plain_prefix && saved.key == "w" && !is(saved.shift),
        // ⌘T now opens a tab; a new terminal pane moved to ⌘D.
        "new-terminal" => {
            saved.mode == Direct && saved.key == "t" && is(saved.meta) && !is(saved.ctrl) && !is(saved.shift)
        }
        "resize-left" => plain_prefix && saved.key == "h" && is(saved.shift),
        "resize-down" => plain_prefix && saved.key == "j" && is(saved.shift),
        "resize-up" => plain_prefix && saved.key == "k" && is(saved.shift),
        "resize-right" => plain_prefix && saved.key == "l" && is(saved.shift),
        _ => false,
    };
    if uses_legacy_window_tab_or_resize_default {
        return default_binding;
    }

    let legacy_key = match saved.id.as_str() {
        "split-horizontal" => "s",
        "split-vertical" => "v",
        _ => return saved.clone(),
    };
    let uses_legacy_default = plain_prefix && saved.key == legacy_key && !is(saved.shift);
    if uses_legacy_default { default_binding } else { saved.clone() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    fn mac_config() -> KeyBindingConfig {
        DefaultKeybindings::config_for(KeyPlatform::Mac)
    }

    fn binding(id: &str) -> KeyBinding {
        mac_config().bindings.into_iter().find(|b| b.id == id).expect("built-in binding")
    }

    fn by_id(config: &KeyBindingConfig) -> HashMap<String, KeyBinding> {
        config.bindings.iter().map(|b| (b.id.clone(), b.clone())).collect()
    }

    fn legacy_binding(
        based_on: &KeyBinding,
        display: &str,
        mode: KeyBindingMode,
        key: &str,
        (ctrl, meta, shift): (Option<bool>, Option<bool>, Option<bool>),
    ) -> KeyBinding {
        KeyBinding {
            default_keys: display.into(),
            mode,
            key: key.into(),
            ctrl,
            meta,
            shift,
            ..based_on.clone()
        }
    }

    fn legacy_split_binding(id: &str, key: &str, display: &str) -> KeyBinding {
        KeyBinding {
            id: id.into(),
            label: if id == "split-horizontal" { "Split Horizontal" } else { "Split Vertical" }.into(),
            description: "Split the active pane".into(),
            category: Layout,
            default_keys: display.into(),
            mode: Prefix,
            key: key.into(),
            ctrl: None,
            meta: None,
            shift: None,
        }
    }

    const NO: (Option<bool>, Option<bool>, Option<bool>) = (None, None, None);
    const C_S: (Option<bool>, Option<bool>, Option<bool>) = (Some(true), None, Some(true));
    const S: (Option<bool>, Option<bool>, Option<bool>) = (None, None, Some(true));

    fn chord(text: &str) -> Option<KeyChord> {
        KeyChord::parse(text)
    }

    #[test]
    fn numbered_window_bindings_remain_control_number() {
        for number in 1..=9 {
            let window = binding(&format!("select-window-{number}"));
            assert_eq!(window.key, number.to_string());
            assert_eq!(window.ctrl, Some(true));
            assert_ne!(window.shift, Some(true));
            assert_eq!(window.default_keys, format!("Ctrl+{number}"));
        }
    }

    #[test]
    fn find_window_uses_command_f() {
        let find_window = binding("find-window");
        assert_eq!(find_window.mode, Direct);
        assert_eq!(find_window.key, "f");
        assert_eq!(find_window.meta, Some(true));
        assert_ne!(find_window.shift, Some(true));
        assert_eq!(find_window.default_keys, "⌘F");
    }

    #[test]
    fn agent_dashboard_uses_its_own_shift_command_d_shortcut() {
        let dashboard = binding("agent-dashboard");
        assert_eq!(dashboard.mode, Direct);
        assert_eq!(dashboard.key, "d");
        assert_eq!(dashboard.meta, Some(true));
        assert_eq!(dashboard.shift, Some(true));
        assert_eq!(dashboard.default_keys, "⇧⌘D");
    }

    #[test]
    fn saved_configurations_gain_bindings_added_since() {
        for added in [
            vec!["agent-dashboard"],
            vec!["find-window"],
            vec!["last-window"],
            vec!["rename-window", "close-window"],
            vec!["new-window-current-directory"],
        ] {
            let mut saved = DefaultKeybindings::config();
            saved.bindings.retain(|b| !added.contains(&b.id.as_str()));
            let merged = DefaultKeybindings::merged_config(&saved);
            for id in added {
                assert!(merged.bindings.iter().any(|b| b.id == id), "{id}");
            }
        }
    }

    #[test]
    fn temporary_shifted_window_bindings_migrate_back_to_control_number() {
        let mut saved = DefaultKeybindings::config();
        saved.bindings = saved
            .bindings
            .into_iter()
            .map(|b| {
                if !b.id.starts_with("select-window-") {
                    return b;
                }
                let number = b.id[b.id.len() - 1..].to_string();
                legacy_binding(&b, &format!("Ctrl+Shift+{number}"), Direct, &number, C_S)
            })
            .collect();
        let merged = DefaultKeybindings::merged_config(&saved);
        for number in 1..=9 {
            let window =
                merged.bindings.iter().find(|b| b.id == format!("select-window-{number}")).expect("window");
            assert_eq!(window.ctrl, Some(true));
            assert_ne!(window.shift, Some(true));
            assert_eq!(
                KeyChord::from_binding(window),
                KeyChord::new(Direct, &number.to_string(), true, false, false)
            );
        }
    }

    #[test]
    fn tmux_window_cycling_uses_prefix_p_and_n() {
        let previous = binding("previous-window");
        let next = binding("next-window");
        let previous_direct = binding("previous-window-direct");
        let next_direct = binding("next-window-direct");

        assert_eq!(
            (previous.mode, previous.key.as_str(), previous.default_keys.as_str()),
            (Prefix, "p", "Prefix → P")
        );
        assert_ne!(previous.shift, Some(true));
        assert_eq!((next.mode, next.key.as_str(), next.default_keys.as_str()), (Prefix, "n", "Prefix → N"));
        assert_ne!(next.shift, Some(true));

        assert_eq!((previous_direct.mode, previous_direct.key.as_str()), (Direct, "h"));
        assert_eq!((previous_direct.ctrl, previous_direct.shift), (Some(true), Some(true)));
        assert_eq!((next_direct.mode, next_direct.key.as_str()), (Direct, "l"));
        assert_eq!((next_direct.ctrl, next_direct.shift), (Some(true), Some(true)));
    }

    #[test]
    fn last_window_uses_prefix_shift_l() {
        let last = binding("last-window");
        assert_eq!(last.mode, Prefix);
        assert_eq!(last.key, "l");
        assert_eq!(last.shift, Some(true));
        assert_eq!(last.default_keys, "Prefix → Shift+L");
    }

    #[test]
    fn previous_prefix_shift_p_last_window_default_migrates_to_prefix_shift_l() {
        let mut saved = DefaultKeybindings::config();
        for b in &mut saved.bindings {
            if b.id == "last-window" {
                *b = legacy_binding(b, "Prefix → Shift+P", Prefix, "p", S);
            }
        }
        let merged = by_id(&DefaultKeybindings::merged_config(&saved));
        let last = &merged["last-window"];
        assert_eq!(last.key, "l");
        assert_eq!(last.shift, Some(true));
        assert_eq!(KeyChord::from_binding(last), chord("prefix+shift+l").expect("chord"));
    }

    #[test]
    fn pane_tab_cycling_uses_prefix_angle_brackets() {
        let previous = binding("prev-pane-tab");
        let next = binding("next-pane-tab");
        assert_eq!((previous.mode, previous.key.as_str(), previous.shift), (Prefix, "<", Some(true)));
        assert_eq!(previous.default_keys, "Prefix → <");
        assert_eq!((next.mode, next.key.as_str(), next.shift), (Prefix, ">", Some(true)));
        assert_eq!(next.default_keys, "Prefix → >");
    }

    #[test]
    fn pane_resizing_matches_tmux_prefix_hjkl_without_shift() {
        for (id, key) in
            [("resize-left", "h"), ("resize-down", "j"), ("resize-up", "k"), ("resize-right", "l")]
        {
            let resize = binding(id);
            assert_eq!(resize.mode, Prefix);
            assert_eq!(resize.key, key);
            assert_ne!(resize.shift, Some(true));
            assert_eq!(resize.default_keys, format!("Prefix → {}", key.to_uppercase()));
        }
    }

    #[test]
    fn legacy_window_and_tab_defaults_migrate_to_current_bindings() {
        let mut saved = DefaultKeybindings::config();
        saved.bindings.retain(|b| b.id != "previous-window-direct" && b.id != "next-window-direct");
        for b in &mut saved.bindings {
            *b = match b.id.as_str() {
                "previous-window" => legacy_binding(b, "Ctrl+Shift+H", Direct, "h", C_S),
                "next-window" => legacy_binding(b, "Ctrl+Shift+L", Direct, "l", C_S),
                "prev-pane-tab" => legacy_binding(b, "Prefix → P", Prefix, "p", NO),
                "next-pane-tab" => legacy_binding(b, "Prefix → N", Prefix, "n", NO),
                _ => continue,
            };
        }
        let merged = by_id(&DefaultKeybindings::merged_config(&saved));
        assert_eq!((merged["previous-window"].mode, merged["previous-window"].key.as_str()), (Prefix, "p"));
        assert_eq!((merged["next-window"].mode, merged["next-window"].key.as_str()), (Prefix, "n"));
        assert_eq!((merged["prev-pane-tab"].key.as_str(), merged["prev-pane-tab"].shift), ("<", Some(true)));
        assert_eq!((merged["next-pane-tab"].key.as_str(), merged["next-pane-tab"].shift), (">", Some(true)));
        assert!(merged.contains_key("previous-window-direct"));
        assert!(merged.contains_key("next-window-direct"));
    }

    #[test]
    fn previous_last_window_resize_and_pane_tab_defaults_migrate_to_current_bindings() {
        let old_resize_keys = HashMap::from([
            ("resize-left", "h"),
            ("resize-down", "j"),
            ("resize-up", "k"),
            ("resize-right", "l"),
        ]);
        let mut saved = DefaultKeybindings::config();
        for b in &mut saved.bindings {
            if b.id == "last-window" {
                *b = legacy_binding(b, "Prefix → L", Prefix, "l", NO);
            } else if let Some(key) = old_resize_keys.get(b.id.as_str()) {
                *b = legacy_binding(b, &format!("Prefix → Shift+{}", key.to_uppercase()), Prefix, key, S);
            } else if b.id == "prev-pane-tab" {
                *b = legacy_binding(b, "Prefix → Shift+P", Prefix, "p", S);
            } else if b.id == "next-pane-tab" {
                *b = legacy_binding(b, "Prefix → Shift+N", Prefix, "n", S);
            }
        }
        let merged = by_id(&DefaultKeybindings::merged_config(&saved));
        assert_eq!((merged["last-window"].key.as_str(), merged["last-window"].shift), ("l", Some(true)));
        for (id, key) in old_resize_keys {
            assert_eq!(merged[id].key, key);
            assert_ne!(merged[id].shift, Some(true));
        }
        assert_eq!(merged["prev-pane-tab"].key, "<");
        assert_eq!(merged["next-pane-tab"].key, ">");
    }

    #[test]
    fn customized_window_cycling_binding_is_preserved() {
        let mut saved = DefaultKeybindings::config();
        for b in &mut saved.bindings {
            if b.id == "previous-window" {
                *b = legacy_binding(b, "Ctrl+Shift+B", Direct, "b", C_S);
            }
        }
        let merged = by_id(&DefaultKeybindings::merged_config(&saved));
        let previous = &merged["previous-window"];
        assert_eq!((previous.mode, previous.key.as_str()), (Direct, "b"));
        assert_eq!((previous.ctrl, previous.shift), (Some(true), Some(true)));
    }

    #[test]
    fn default_bindings_do_not_contain_shortcut_collisions() {
        let config = DefaultKeybindings::config();
        let chords: Vec<String> = config
            .bindings
            .iter()
            .map(|b| {
                format!(
                    "{:?}:{}:{}:{}:{}",
                    b.mode,
                    b.key,
                    if is(b.ctrl) { "ctrl" } else { "" },
                    if is(b.meta) { "meta" } else { "" },
                    if is(b.shift) { "shift" } else { "" }
                )
            })
            .collect();
        let unique: HashSet<&String> = chords.iter().collect();
        assert_eq!(unique.len(), chords.len());
    }

    #[test]
    fn split_defaults_use_dash_and_pipe() {
        let horizontal = binding("split-horizontal");
        let vertical = binding("split-vertical");
        assert_eq!(horizontal.default_keys, "Prefix → -");
        assert_eq!(horizontal.key, "-");
        assert_ne!(horizontal.shift, Some(true));
        assert_eq!(vertical.default_keys, "Prefix → |");
        assert_eq!(vertical.key, "|");
        assert_eq!(vertical.shift, Some(true));
    }

    #[test]
    fn copy_mode_supports_both_tmux_bracket_shortcuts() {
        let left = binding("copy-mode");
        let right = binding("copy-mode-right-bracket");
        assert_eq!((left.mode, left.key.as_str()), (Prefix, "["));
        assert_eq!((right.mode, right.key.as_str()), (Prefix, "]"));
    }

    #[test]
    fn new_window_current_directory_uses_tmux_prefix_c() {
        let new_window = binding("new-window-current-directory");
        assert_eq!((new_window.mode, new_window.key.as_str()), (Prefix, "c"));
        assert_ne!(new_window.shift, Some(true));
        assert_eq!(new_window.default_keys, "Prefix → C");
    }

    #[test]
    fn command_t_opens_a_tab_and_control_tab_cycles_them() {
        assert_eq!(Some(KeyChord::from_binding(&binding("new-tab-direct"))), chord("cmd+t"));
        assert_eq!(Some(KeyChord::from_binding(&binding("new-tab"))), chord("prefix+t"));
        assert_eq!(Some(KeyChord::from_binding(&binding("next-tab"))), chord("ctrl+tab"));
        assert_eq!(Some(KeyChord::from_binding(&binding("previous-tab"))), chord("ctrl+shift+tab"));
    }

    #[test]
    fn saved_defaults_that_now_belong_to_tabs_move_aside() {
        let mut saved = DefaultKeybindings::config();
        saved.bindings.retain(|b| b.id != "new-tab-direct");
        for b in &mut saved.bindings {
            *b = match b.id.as_str() {
                "new-pane-tab" => legacy_binding(b, "Prefix → T", Prefix, "t", NO),
                "close-pane-tab" => legacy_binding(b, "Prefix → W", Prefix, "w", NO),
                "new-terminal" => legacy_binding(b, "⌘T", Direct, "t", (None, Some(true), None)),
                _ => continue,
            };
        }
        let merged = DefaultKeybindings::merged_config(&saved);
        let chords: HashMap<&str, KeyChord> =
            merged.bindings.iter().map(|b| (b.id.as_str(), KeyChord::from_binding(b))).collect();
        assert_eq!(chords.get("new-pane-tab").cloned(), chord("prefix+shift+t"));
        assert_eq!(chords.get("close-pane-tab").cloned(), chord("prefix+shift+w"));
        assert_eq!(chords.get("new-terminal").cloned(), chord("cmd+d"));
        assert_eq!(chords.get("new-tab").cloned(), chord("prefix+t"));
        assert_eq!(chords.get("new-tab-direct").cloned(), chord("cmd+t"));
        assert_eq!(chords.get("close-tab").cloned(), chord("prefix+w"));
    }

    #[test]
    fn window_management_uses_shifted_command_shortcuts() {
        for (id, key, display) in [("rename-window", "r", "⇧⌘R"), ("close-window", "w", "⇧⌘W")] {
            let b = binding(id);
            assert_eq!((b.mode, b.key.as_str()), (Direct, key));
            assert_eq!((b.meta, b.shift), (Some(true), Some(true)));
            assert_eq!(b.default_keys, display);
        }
    }

    #[test]
    fn saved_legacy_split_defaults_migrate_to_current_defaults() {
        let mut saved = DefaultKeybindings::config();
        for b in &mut saved.bindings {
            match b.id.as_str() {
                "split-horizontal" => *b = legacy_split_binding(&b.id, "s", "Prefix → S"),
                "split-vertical" => *b = legacy_split_binding(&b.id, "v", "Prefix → V"),
                _ => {}
            }
        }
        let merged = by_id(&DefaultKeybindings::merged_config(&saved));
        assert_eq!(merged["split-horizontal"].key, "-");
        assert_eq!(merged["split-vertical"].key, "|");
        assert_eq!(merged["split-vertical"].shift, Some(true));
    }

    #[test]
    fn customized_split_bindings_are_preserved() {
        let mut saved = DefaultKeybindings::config();
        for b in &mut saved.bindings {
            if b.id == "split-horizontal" {
                *b = legacy_split_binding(&b.id, "d", "Prefix → D");
            }
        }
        let merged = by_id(&DefaultKeybindings::merged_config(&saved));
        assert_eq!(merged["split-horizontal"].key, "d");
        assert_eq!(merged["split-horizontal"].default_keys, "Prefix → D");
    }

    #[test]
    fn legacy_keybindings_are_read_from_the_state_store_and_merged() {
        let store = StateStore::in_memory();
        assert_eq!(DefaultKeybindings::load(&store), DefaultKeybindings::config());

        let mut saved = DefaultKeybindings::config();
        saved.prefix_key = "b".into();
        saved.bindings.retain(|b| b.id != "find-window");
        store.set(DefaultKeybindings::STATE_KEY, &saved);
        let loaded = DefaultKeybindings::load(&store);
        assert_eq!(loaded.prefix_key, "b");
        assert!(loaded.bindings.iter().any(|b| b.id == "find-window"));
    }
}
