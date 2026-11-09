//! The default keybinding table (Swift `Config/DefaultKeybindings.swift`), copied as a fixture:
//! soprano-config owns the real table; these tests only need the chords.

use soprano_types::{KeyBinding, KeyBindingCategory, KeyBindingConfig, KeyBindingMode};

const P: KeyBindingMode = KeyBindingMode::Prefix;
const D: KeyBindingMode = KeyBindingMode::Direct;

fn binding(id: &str, mode: KeyBindingMode, key: &str, ctrl: bool, meta: bool, shift: bool) -> KeyBinding {
    KeyBinding {
        id: id.to_owned(),
        label: id.to_owned(),
        description: String::new(),
        category: KeyBindingCategory::General,
        default_keys: String::new(),
        mode,
        key: key.to_owned(),
        ctrl: ctrl.then_some(true),
        meta: meta.then_some(true),
        shift: shift.then_some(true),
    }
}

pub fn default_config() -> KeyBindingConfig {
    let mut bindings = vec![
        binding("nav-left", D, "h", true, false, false),
        binding("nav-down", D, "j", true, false, false),
        binding("nav-up", D, "k", true, false, false),
        binding("nav-right", D, "l", true, false, false),
        binding("previous-window", P, "p", false, false, false),
        binding("next-window", P, "n", false, false, false),
        binding("last-window", P, "l", false, false, true),
        binding("previous-window-direct", D, "h", true, false, true),
        binding("next-window-direct", D, "l", true, false, true),
    ];
    for number in 1..=9 {
        bindings.push(binding(
            &format!("select-window-{number}"),
            D,
            &number.to_string(),
            true,
            false,
            false,
        ));
    }
    bindings.extend([
        binding("resize-left", P, "h", false, false, false),
        binding("resize-down", P, "j", false, false, false),
        binding("resize-up", P, "k", false, false, false),
        binding("resize-right", P, "l", false, false, false),
        binding("new-session", P, "c", false, false, true),
        binding("find-session", P, "s", false, false, false),
        binding("split-horizontal", P, "-", false, false, false),
        binding("split-vertical", P, "|", false, false, true),
        binding("close-pane", P, "q", false, false, false),
        binding("kill-pane", P, "x", false, false, false),
        binding("maximize-pane", P, "m", false, false, false),
        binding("copy-mode", P, "[", false, false, false),
        binding("copy-mode-right-bracket", P, "]", false, false, false),
        binding("new-window-current-directory", P, "c", false, false, false),
        binding("new-tab", P, "t", false, false, false),
        binding("new-tab-direct", D, "t", false, true, false),
        binding("close-tab", P, "w", false, false, false),
        binding("next-tab", D, "\t", true, false, false),
        binding("previous-tab", D, "\t", true, false, true),
        binding("new-pane-tab", P, "t", false, false, true),
        binding("new-pane-tab-direct", D, "t", true, true, false),
        binding("next-pane-tab", P, ">", false, false, true),
        binding("next-pane-tab-direct", D, "\u{F703}", true, true, false),
        binding("prev-pane-tab", P, "<", false, false, true),
        binding("prev-pane-tab-direct", D, "\u{F702}", true, true, false),
        binding("close-pane-tab", P, "w", false, false, true),
        binding("close-pane-tab-direct", D, "w", true, true, false),
        binding("launch-codex", D, "1", false, true, false),
        binding("launch-claude-code", D, "2", false, true, false),
        binding("launch-opencode", D, "3", false, true, false),
        binding("launch-omp", D, "4", false, true, false),
        binding("new-chat", D, "i", false, true, false),
        binding("agent-dashboard", D, "d", false, true, true),
        binding("command-palette", D, "p", false, true, false),
        binding("find-window", D, "f", false, true, false),
        binding("open-project", D, "p", false, true, true),
        binding("new-window", D, "n", false, true, false),
        binding("rename-window", D, "r", false, true, true),
        binding("close-window", D, "w", false, true, true),
        binding("new-terminal", D, "d", false, true, false),
        binding("new-browser", D, "b", false, true, false),
        binding("close-active", D, "w", false, true, false),
        binding("save-session", D, "s", false, true, true),
        binding("toggle-sidebar", D, "e", false, true, false),
        binding("toggle-right-sidebar", D, "l", false, true, false),
        binding("toggle-explorer", D, "e", false, true, true),
        binding("toggle-source-control", D, "g", false, true, true),
        binding("open-settings", D, ",", false, true, false),
        binding("zoom-in", D, "=", false, true, false),
        binding("zoom-out", D, "-", false, true, false),
        binding("zoom-reset", D, "0", false, true, false),
        binding("open-in-soprano-git", P, "g", false, false, false),
    ]);
    KeyBindingConfig { prefix_key: "a".into(), prefix_timeout_ms: 1500, resize_tick_percent: 5.0, bindings }
}
