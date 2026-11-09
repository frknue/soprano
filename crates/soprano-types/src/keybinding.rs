//! Keyboard shortcut types (`Models/KeyBinding.swift`). Field names serialize exactly as the
//! Swift `Codable` types did, so stored payloads keep decoding.

use serde::{Deserialize, Serialize};

/// A single keyboard shortcut binding.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyBinding {
    pub id: String,
    pub label: String,
    pub description: String,
    pub category: KeyBindingCategory,
    pub default_keys: String,
    pub mode: KeyBindingMode,
    pub key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ctrl: Option<bool>,
    /// Command on macOS; the Super/Windows key's role is taken by Ctrl on other OSes where the
    /// keybinding layer maps it (see the keybinding manager).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meta: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shift: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KeyBindingCategory {
    Navigation,
    Layout,
    Agents,
    General,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KeyBindingMode {
    /// Triggered directly (e.g. Cmd+P).
    Direct,
    /// Triggered after the prefix key (e.g. Ctrl+A → S).
    Prefix,
}

/// Full keybinding configuration.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyBindingConfig {
    pub prefix_key: String,
    pub prefix_timeout_ms: i64,
    pub resize_tick_percent: f64,
    pub bindings: Vec<KeyBinding>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum KeybindingState {
    #[default]
    Normal,
    Prefix,
    Copy,
    CopySelection,
}
