//! The user-facing configuration decoded from `settings.json` and its resolution over the
//! built-in defaults (`Config/SopranoConfig.swift`).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use soprano_types::{
    AgentCatalog, AgentProfile, DefaultAgents, KeyBinding, KeyBindingCategory, KeyBindingConfig,
    KeyBindingMode,
};

use crate::app_settings::{AppSettings, AppearancePreference, KNOWN_THEME_IDS, is_known_theme_id};
use crate::automation::{Automation, AutomationEntry, resolve_automations};
use crate::default_keybindings::DefaultKeybindings;
use crate::key_chord::KeyChord;

/// The user-facing configuration decoded from `~/.config/soprano/settings.json`.
///
/// Every field is optional on purpose: an absent key means "keep the built-in default", the
/// same partial-override model VS Code's `settings.json` uses. A user should never have to
/// paste a complete document to change one value.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SopranoConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appearance: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hide_window_bar: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hide_window_tabs: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_bar: Option<StatusBarConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore_last_session: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_directories: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notifications: Option<NotificationsConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keybindings: Option<KeybindingsConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agents: Option<Vec<AgentConfig>>,
    /// Scheduled prompts, keyed by a stable id. See [`AutomationEntry`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automations: Option<BTreeMap<String, AutomationEntry>>,
}

/// Whether the OS may deliver a banner is the system's decision, not ours, so the only thing
/// configured here is what Soprano controls about it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotificationsConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sound: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusBarConfig {
    /// Opt-in `Up 2:14:07` uptime readout.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uptime: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeybindingsConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefix_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefix_timeout_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resize_tick_percent: Option<f64>,
    /// Binding id → chord, where JSON `null` disables the binding.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bindings: Option<BTreeMap<String, BindingOverride>>,
}

/// A user-declared agent. `id` is the only required field: reusing a built-in id (`codex`,
/// `claude-code`, `opencode`, `omp`, `terminal`) patches that profile field by field, while a
/// new id defines a whole new agent and then requires `command`.
///
/// Deliberately narrower than `AgentProfile`: `autoRestart`, `restartDelayMs`, and `patterns`
/// are not exposed because nothing reads them at runtime, and a settings key that does
/// nothing is worse than a missing one.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentConfig {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub args: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_script: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_key: Option<String>,
}

/// A keybinding override: a chord string, or JSON `null` meaning "turn this shortcut off".
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BindingOverride {
    Chord(String),
    Disabled,
}

impl<'de> Deserialize<'de> for BindingOverride {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Option::<String>::deserialize(deserializer)? {
            Some(chord) => Self::Chord(chord),
            None => Self::Disabled,
        })
    }
}

impl Serialize for BindingOverride {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Chord(chord) => serializer.serialize_str(chord),
            Self::Disabled => serializer.serialize_none(),
        }
    }
}

// MARK: - Issues

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Severity {
    /// The document could not be read at all; defaults (or the last good values) are in force.
    Error,
    /// One key was ignored; everything else applied.
    Warning,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Warning => "warning",
        }
    }
}

/// A problem found while resolving the config file. Issues never block startup: a bad value
/// falls back to the default and is reported in **Settings**, so a typo can't leave the user
/// without a running app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigIssue {
    pub severity: Severity,
    pub message: String,
    /// 1-based line in `settings.json`, when the problem has a position.
    pub line: Option<usize>,
}

impl ConfigIssue {
    pub fn warning(message: impl Into<String>) -> Self {
        Self { severity: Severity::Warning, message: message.into(), line: None }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Self { severity: Severity::Error, message: message.into(), line: None }
    }

    /// Stable identity for list diffing in the UI.
    pub fn id(&self) -> String {
        format!("{}-{}-{}", self.severity.as_str(), self.line.unwrap_or(0), self.message)
    }
}

// MARK: - Resolution

/// The config file applied on top of the built-in defaults.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedConfig {
    pub settings: AppSettings,
    pub keybindings: KeyBindingConfig,
    /// Built-in agents (patched where the file reuses their id) followed by new ones.
    pub agents: Vec<AgentProfile>,
    pub automations: Vec<Automation>,
    pub issues: Vec<ConfigIssue>,
    /// Binding ids the file overrides — the UI badges these as customized.
    pub customized_binding_ids: BTreeSet<String>,
    /// Binding ids the file turned off with `null`.
    pub disabled_binding_ids: BTreeSet<String>,
    /// Agent ids the file declared or patched.
    pub configured_agent_ids: BTreeSet<String>,
}

impl ResolvedConfig {
    pub fn defaults() -> Self {
        Self {
            settings: AppSettings::default(),
            keybindings: DefaultKeybindings::config(),
            agents: DefaultAgents::all(),
            automations: Vec::new(),
            issues: Vec::new(),
            customized_binding_ids: BTreeSet::new(),
            disabled_binding_ids: BTreeSet::new(),
            configured_agent_ids: BTreeSet::new(),
        }
    }

    /// Makes this configuration's agents the ones the rest of the app sees
    /// ([`AgentCatalog::shared`]).
    pub fn install_agents(&self) {
        install_agents(AgentCatalog::shared(), &self.agents);
    }
}

/// Replaces `catalog`'s profiles with `agents`, the merged built-in + user list.
pub fn install_agents(catalog: &AgentCatalog, agents: &[AgentProfile]) {
    catalog.replace_all(agents.to_vec());
}

/// Bounds that keep a hand-edited file from producing an unusable app. They mirror the clamps
/// the settings UI applies to the same fields, so both entry points behave identically.
pub struct Limits;

impl Limits {
    pub const PREFIX_TIMEOUT_MS: std::ops::RangeInclusive<i64> = 300..=5000;
    pub const RESIZE_TICK_PERCENT: std::ops::RangeInclusive<i64> = 1..=25;
}

impl SopranoConfig {
    /// Apply this config on top of the built-in defaults.
    ///
    /// Resolution never fails: every rejected value becomes a [`ConfigIssue`] and leaves the
    /// default in place.
    pub fn resolved(&self) -> ResolvedConfig {
        self.resolved_with(&AppSettings::default(), &DefaultKeybindings::config(), &DefaultAgents::all())
    }

    pub fn resolved_with(
        &self,
        base_settings: &AppSettings,
        base_keybindings: &KeyBindingConfig,
        base_agents: &[AgentProfile],
    ) -> ResolvedConfig {
        let mut issues = Vec::new();
        let mut settings = base_settings.clone();

        if let Some(theme) = &self.theme {
            if is_known_theme_id(theme) {
                settings.theme_id = theme.clone();
            } else {
                issues.push(ConfigIssue::warning(format!(
                    "Unknown theme \"{theme}\". Known themes: {}.",
                    KNOWN_THEME_IDS.join(", ")
                )));
            }
        }

        if let Some(appearance) = &self.appearance {
            match AppearancePreference::from_raw(appearance) {
                Some(preference) => settings.appearance = preference,
                None => {
                    let known: Vec<&str> = AppearancePreference::ALL.iter().map(|p| p.raw_value()).collect();
                    issues.push(ConfigIssue::warning(format!(
                        "Unknown appearance \"{appearance}\". Use one of: {}.",
                        known.join(", ")
                    )));
                }
            }
        }

        if let Some(restore) = self.restore_last_session {
            settings.restore_last_session = restore;
        }
        if let Some(hide) = self.hide_window_bar {
            settings.hide_window_bar = hide;
        }
        if let Some(hide) = self.hide_window_tabs {
            settings.hide_window_tabs = hide;
        }
        if let Some(uptime) = self.status_bar.as_ref().and_then(|s| s.uptime) {
            settings.status_bar_uptime = uptime;
        }
        if let Some(sound) = self.notifications.as_ref().and_then(|n| n.sound) {
            settings.notification_sound = sound;
        }

        if let Some(project_directories) = &self.project_directories {
            let mut resolved_directories: Vec<String> = Vec::new();
            for raw_path in project_directories {
                let path = expand_path(raw_path);
                if path.is_empty() || resolved_directories.contains(&path) {
                    continue;
                }
                if !std::path::Path::new(&path).is_dir() {
                    issues.push(ConfigIssue::warning(format!(
                        "projectDirectories: \"{raw_path}\" is not a directory."
                    )));
                    continue;
                }
                resolved_directories.push(path);
            }
            settings.project_directories = resolved_directories;
        }

        let agents = resolve_agents(self.agents.as_deref().unwrap_or_default(), base_agents, &mut issues);
        let agent_ids: BTreeSet<String> = agents.profiles.iter().map(|p| p.id.clone()).collect();

        let automations =
            resolve_automations(&self.automations.clone().unwrap_or_default(), &agent_ids, &mut issues);

        let keybindings = resolve_keybindings(
            self.keybindings.as_ref(),
            base_keybindings,
            &agents.launch_keys,
            &agent_ids,
            &mut issues,
        );

        ResolvedConfig {
            settings,
            keybindings: keybindings.config,
            agents: agents.profiles,
            automations,
            issues,
            customized_binding_ids: keybindings.customized,
            disabled_binding_ids: keybindings.disabled,
            configured_agent_ids: agents.configured_ids,
        }
    }
}

/// Trims, expands a leading `~`, makes the path absolute (relative to the working directory)
/// and removes `.`/`..` components. Empty input stays empty.
pub fn expand_path(raw_path: &str) -> String {
    let trimmed = raw_path.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let mut path = soprano_platform::paths::expand_tilde(trimmed);
    if path.is_relative() {
        path = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")).join(path);
    }
    let normalized = soprano_platform::paths::normalize(&path).display().to_string();
    // `normalize` keeps a trailing separator only for the root itself.
    if normalized.len() > 1 { normalized.trim_end_matches(['/', '\\']).to_owned() } else { normalized }
}

// MARK: - Agents

struct AgentResolution {
    profiles: Vec<AgentProfile>,
    configured_ids: BTreeSet<String>,
    /// Agent id → chord for agents that declared a `launchKey`.
    launch_keys: BTreeMap<String, String>,
}

fn resolve_agents(
    configured: &[AgentConfig],
    base_agents: &[AgentProfile],
    issues: &mut Vec<ConfigIssue>,
) -> AgentResolution {
    let mut profiles = base_agents.to_vec();
    let mut configured_ids = BTreeSet::new();
    let mut launch_keys = BTreeMap::new();

    for entry in configured {
        let id = entry.id.trim().to_owned();
        if id.is_empty() {
            issues.push(ConfigIssue::warning("agents: an entry is missing \"id\" and was ignored."));
            continue;
        }
        if configured_ids.contains(&id) {
            issues.push(ConfigIssue::warning(format!(
                "agents: duplicate id \"{id}\"; the later entry was ignored."
            )));
            continue;
        }

        if let Some(existing) = profiles.iter_mut().find(|p| p.id == id) {
            *existing = patched(existing, entry);
        } else {
            let command = entry.command.as_deref().map(str::trim).unwrap_or_default();
            if command.is_empty() {
                issues.push(ConfigIssue::warning(format!(
                    "agents: \"{id}\" defines a new agent but has no \"command\"; it was ignored."
                )));
                continue;
            }
            profiles.push(new_profile(&id, command, entry));
        }

        if let Some(launch_key) = &entry.launch_key {
            launch_keys.insert(id.clone(), launch_key.clone());
        }
        configured_ids.insert(id);
    }

    AgentResolution { profiles, configured_ids, launch_keys }
}

/// Field-wise patch of a built-in profile: unset keys keep the built-in value, so
/// `{"id": "codex", "args": ["--model", "o3"]}` is a legal, minimal override.
fn patched(profile: &AgentProfile, entry: &AgentConfig) -> AgentProfile {
    AgentProfile {
        id: profile.id.clone(),
        name: entry.name.clone().unwrap_or_else(|| profile.name.clone()),
        icon: entry.icon.clone().unwrap_or_else(|| profile.icon.clone()),
        color: entry.color.clone().unwrap_or_else(|| profile.color.clone()),
        description: entry.description.clone().unwrap_or_else(|| profile.description.clone()),
        command: entry.command.clone().unwrap_or_else(|| profile.command.clone()),
        args: entry.args.clone().unwrap_or_else(|| profile.args.clone()),
        env: entry.env.clone().or_else(|| profile.env.clone()),
        cwd: entry.cwd.as_deref().map(expand_path).or_else(|| profile.cwd.clone()),
        launch_script: entry.launch_script.clone().or_else(|| profile.launch_script.clone()),
        auto_restart: profile.auto_restart,
        restart_delay_ms: profile.restart_delay_ms,
        patterns: profile.patterns.clone(),
    }
}

fn new_profile(id: &str, command: &str, entry: &AgentConfig) -> AgentProfile {
    AgentProfile {
        id: id.into(),
        name: entry.name.clone().unwrap_or_else(|| default_name(id)),
        icon: entry.icon.clone().unwrap_or_else(|| "bot".into()),
        color: entry.color.clone().unwrap_or_else(|| default_color(id).into()),
        description: entry.description.clone().unwrap_or_else(|| "Configured in settings.json".into()),
        command: command.into(),
        args: entry.args.clone().unwrap_or_default(),
        env: entry.env.clone(),
        cwd: entry.cwd.as_deref().map(expand_path),
        launch_script: entry.launch_script.clone(),
        auto_restart: None,
        restart_delay_ms: None,
        patterns: None,
    }
}

/// `"my-agent"` → `"My Agent"`.
pub fn default_name(id: &str) -> String {
    id.split('-')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().chain(chars).collect(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Custom agents get a stable color derived from their id so several of them stay
/// distinguishable in pane headers without anyone picking hexes.
pub fn default_color(id: &str) -> &'static str {
    const PALETTE: [&str; 8] =
        ["#83a598", "#b16286", "#8ec07c", "#d3869b", "#458588", "#d79921", "#689d6a", "#a89984"];
    let hash =
        id.chars().fold(0i64, |hash, scalar| (hash.wrapping_mul(31).wrapping_add(scalar as i64)) & 0xffff);
    PALETTE[(hash as usize) % PALETTE.len()]
}

// MARK: - Keybindings

struct KeybindingResolution {
    config: KeyBindingConfig,
    customized: BTreeSet<String>,
    disabled: BTreeSet<String>,
}

fn resolve_keybindings(
    configured: Option<&KeybindingsConfig>,
    base: &KeyBindingConfig,
    agent_launch_keys: &BTreeMap<String, String>,
    agent_ids: &BTreeSet<String>,
    issues: &mut Vec<ConfigIssue>,
) -> KeybindingResolution {
    let mut config = base.clone();
    let mut customized = BTreeSet::new();
    let mut disabled = BTreeSet::new();

    if let Some(prefix_key) = configured.and_then(|c| c.prefix_key.as_deref()) {
        let trimmed = prefix_key.trim();
        if trimmed.chars().count() == 1 {
            config.prefix_key = trimmed.to_lowercase();
        } else {
            issues.push(ConfigIssue::warning(format!(
                "keybindings.prefixKey must be a single character; kept \"{}\".",
                config.prefix_key
            )));
        }
    }

    if let Some(timeout) = configured.and_then(|c| c.prefix_timeout_ms) {
        let (low, high) = (*Limits::PREFIX_TIMEOUT_MS.start(), *Limits::PREFIX_TIMEOUT_MS.end());
        let clamped = timeout.clamp(low, high);
        if clamped != timeout {
            issues.push(ConfigIssue::warning(format!(
                "keybindings.prefixTimeoutMs must be {low}–{high}; clamped to {clamped}."
            )));
        }
        config.prefix_timeout_ms = clamped;
    }

    if let Some(resize) = configured.and_then(|c| c.resize_tick_percent) {
        let (low, high) = (*Limits::RESIZE_TICK_PERCENT.start(), *Limits::RESIZE_TICK_PERCENT.end());
        let clamped = resize.clamp(low as f64, high as f64);
        if clamped != resize {
            issues.push(ConfigIssue::warning(format!(
                "keybindings.resizeTickPercent must be {low}–{high}; clamped to {}.",
                clamped as i64
            )));
        }
        config.resize_tick_percent = clamped;
    }

    // An agent's `launchKey` synthesizes (or retargets) its `launch-<id>` binding. An explicit
    // `keybindings.bindings` entry for the same id wins, so there is exactly one place to look
    // when both are set.
    let mut overrides: BTreeMap<String, BindingOverride> = BTreeMap::new();
    // Where each override came from, so a complaint points at the key the user actually typed
    // rather than at a `keybindings.bindings` entry they never wrote.
    let mut origins: HashMap<String, String> = HashMap::new();
    for (agent_id, chord) in agent_launch_keys {
        let id = format!("launch-{agent_id}");
        overrides.insert(id.clone(), BindingOverride::Chord(chord.clone()));
        origins.insert(id, format!("agents[{agent_id}].launchKey"));
    }
    if let Some(explicit) = configured.and_then(|c| c.bindings.as_ref()) {
        for (id, binding_override) in explicit {
            overrides.insert(id.clone(), binding_override.clone());
            origins.insert(id.clone(), format!("keybindings.bindings.{id}"));
        }
    }

    let mut bindings_by_id: HashMap<String, KeyBinding> =
        config.bindings.iter().map(|b| (b.id.clone(), b.clone())).collect();
    let mut appended: Vec<KeyBinding> = Vec::new();

    for (id, binding_override) in &overrides {
        let origin = origins.get(id).cloned().unwrap_or_else(|| format!("keybindings.bindings.{id}"));
        // A `launch-<agent>` action exists for every agent in the catalog, whether the agent
        // declared a launchKey or not — otherwise binding a launcher purely from
        // `keybindings.bindings` would be rejected as unknown.
        let is_synthesizable = id.strip_prefix("launch-").is_some_and(|agent| agent_ids.contains(agent));

        let Some(existing) =
            bindings_by_id.get(id).cloned().or_else(|| synthesized_launch_binding(id, is_synthesizable))
        else {
            issues.push(ConfigIssue::warning(format!("keybindings.bindings: unknown action \"{id}\".")));
            continue;
        };

        match binding_override {
            BindingOverride::Disabled => {
                disabled.insert(id.clone());
                bindings_by_id.remove(id);
                appended.retain(|b| &b.id != id);
            }
            BindingOverride::Chord(text) => {
                let Some(chord) = KeyChord::parse(text) else {
                    issues.push(ConfigIssue::warning(format!("{origin}: \"{text}\" is not a valid chord.")));
                    continue;
                };
                let updated = chord.applied(&existing);
                if !bindings_by_id.contains_key(id) {
                    appended.push(updated.clone());
                }
                bindings_by_id.insert(id.clone(), updated);
                customized.insert(id.clone());
            }
        }
    }

    let mut bindings: Vec<KeyBinding> =
        config.bindings.iter().filter_map(|b| bindings_by_id.get(&b.id).cloned()).collect();
    bindings.extend(appended.into_iter().filter(|b| bindings_by_id.contains_key(&b.id)));
    config.bindings = bindings;

    issues.extend(conflict_issues(&config.bindings));
    issues.extend(prefix_key_conflict_issues(&config.bindings, &config.prefix_key));
    issues.extend(zoom_alias_conflict_issues(&config.bindings));
    KeybindingResolution { config, customized, disabled }
}

/// A `launch-<agent>` binding for an agent the built-ins never knew about.
fn synthesized_launch_binding(id: &str, enabled: bool) -> Option<KeyBinding> {
    if !enabled {
        return None;
    }
    let agent_id = id.strip_prefix("launch-")?;
    Some(KeyBinding {
        id: id.into(),
        label: format!("Launch {}", default_name(agent_id)),
        description: format!("Launch the {agent_id} agent"),
        category: KeyBindingCategory::Agents,
        default_keys: String::new(),
        mode: KeyBindingMode::Direct,
        key: String::new(),
        ctrl: None,
        meta: None,
        shift: None,
    })
}

/// `zoom-in` deliberately answers to both `=` and `+`, since the character depends on the
/// keyboard layout. That alias is invisible to the chord comparison, so a binding on the other
/// spelling would be shadowed with no warning at all.
fn zoom_alias_conflict_issues(bindings: &[KeyBinding]) -> Vec<ConfigIssue> {
    let Some(zoom_in) = bindings.iter().find(|b| b.id == "zoom-in") else { return Vec::new() };
    if zoom_in.mode != KeyBindingMode::Direct || zoom_in.key != "=" {
        return Vec::new();
    }
    bindings
        .iter()
        .filter(|b| {
            b.id != "zoom-in" && b.mode == KeyBindingMode::Direct && b.key == "+" && b.meta == zoom_in.meta
        })
        .map(|b| {
            ConfigIssue::warning(format!(
                "\"{}\" is bound to {}, which \"zoom-in\" also answers to; only \"zoom-in\" will fire.",
                b.id,
                KeyChord::from_binding(b).display_string()
            ))
        })
        .collect()
}

/// The prefix is matched before any direct binding, so choosing a prefix key that some Ctrl
/// chord already uses takes that shortcut away — which looks like a broken keyboard rather
/// than a settings choice.
fn prefix_key_conflict_issues(bindings: &[KeyBinding], prefix_key: &str) -> Vec<ConfigIssue> {
    bindings
        .iter()
        .filter(|b| {
            b.mode == KeyBindingMode::Direct
                && b.key == prefix_key
                && b.ctrl == Some(true)
                && b.meta != Some(true)
                && b.shift != Some(true)
        })
        .map(|b| {
            ConfigIssue::warning(format!(
                "keybindings.prefixKey \"{prefix_key}\" takes over Ctrl+{}, so \"{}\" will never fire.",
                prefix_key.to_uppercase(),
                b.id
            ))
        })
        .collect()
}

/// Two shortcuts on the same chord means one of them silently never fires (the first match
/// wins in the keybinding manager), so say so out loud.
fn conflict_issues(bindings: &[KeyBinding]) -> Vec<ConfigIssue> {
    let mut seen: HashMap<KeyChord, &str> = HashMap::new();
    let mut issues = Vec::new();
    for binding in bindings {
        let chord = KeyChord::from_binding(binding);
        if let Some(owner) = seen.get(&chord) {
            issues.push(ConfigIssue::warning(format!(
                "\"{}\" and \"{owner}\" are both bound to {}; only \"{owner}\" will fire.",
                binding.id,
                chord.display_string()
            )));
        } else {
            seen.insert(chord, &binding.id);
        }
    }
    issues
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app_settings::FOLIO_THEME_ID;
    use crate::automation::{AutomationSession, AutomationWorkspace};
    use crate::cron::AutomationCadence;
    use crate::jsonc;
    use crate::key_chord::KeyPlatform;

    fn resolve(json: &str) -> ResolvedConfig {
        jsonc::decode::<SopranoConfig>(json).expect("decodes").resolved()
    }

    fn find<'a>(resolved: &'a ResolvedConfig, id: &str) -> Option<&'a KeyBinding> {
        resolved.keybindings.bindings.iter().find(|b| b.id == id)
    }

    fn default_binding(id: &str) -> KeyBinding {
        DefaultKeybindings::config().bindings.into_iter().find(|b| b.id == id).expect("built-in")
    }

    fn has_issue(resolved: &ResolvedConfig, predicate: impl Fn(&str) -> bool) -> bool {
        resolved.issues.iter().any(|i| predicate(&i.message))
    }

    fn home() -> String {
        expand_path("~")
    }

    // MARK: - SopranoConfigTests

    #[test]
    fn an_empty_document_leaves_every_built_in_default_in_place() {
        let resolved = resolve("{}");
        assert_eq!(resolved.settings, AppSettings::default());
        assert_eq!(resolved.keybindings, DefaultKeybindings::config());
        assert_eq!(resolved.agents, DefaultAgents::all());
        assert!(resolved.issues.is_empty());
        assert_eq!(resolved, ResolvedConfig::defaults());
    }

    #[test]
    fn the_built_in_bindings_contain_no_chord_collisions() {
        // The conflict detector must not cry wolf on a stock configuration.
        assert!(resolve("{}").issues.is_empty());
    }

    #[test]
    fn setting_one_key_leaves_the_others_at_their_defaults() {
        let resolved = resolve(r#"{ "theme": "catppuccin-mocha" }"#);
        assert_eq!(resolved.settings.theme_id, "catppuccin-mocha");
        assert_eq!(resolved.settings.restore_last_session, AppSettings::default().restore_last_session);
        assert!(resolved.settings.project_directories.is_empty());
        assert!(resolved.issues.is_empty());
    }

    #[test]
    fn an_unknown_theme_is_reported_and_the_current_theme_survives() {
        let resolved = resolve(r#"{ "theme": "solarized-light" }"#);
        assert_eq!(resolved.settings.theme_id, AppSettings::default().theme_id);
        assert_eq!(resolved.issues.len(), 1);
        assert_eq!(resolved.issues[0].severity, Severity::Warning);
        assert!(resolved.issues[0].message.contains("solarized-light"));
    }

    #[test]
    fn the_retired_mission_control_theme_falls_back_to_folio_with_a_warning() {
        let resolved = resolve(r#"{ "theme": "mission-control" }"#);
        assert_eq!(resolved.settings.theme_id, FOLIO_THEME_ID);
        assert_eq!(resolved.issues.len(), 1);
        assert!(resolved.issues[0].message.contains("mission-control"));
    }

    #[test]
    fn folio_and_its_pinned_variants_are_accepted_theme_ids() {
        for id in ["folio", "folio-paper", "folio-ink"] {
            let resolved = resolve(&format!(r#"{{ "theme": "{id}" }}"#));
            assert_eq!(resolved.settings.theme_id, id);
            assert!(resolved.issues.is_empty());
        }
    }

    #[test]
    fn the_appearance_key_defaults_to_system_and_accepts_light_and_dark() {
        assert_eq!(resolve("{}").settings.appearance, AppearancePreference::System);
        assert_eq!(resolve(r#"{ "appearance": "light" }"#).settings.appearance, AppearancePreference::Light);
        assert_eq!(resolve(r#"{ "appearance": "dark" }"#).settings.appearance, AppearancePreference::Dark);
    }

    #[test]
    fn an_unknown_appearance_is_reported_and_system_stays() {
        let resolved = resolve(r#"{ "appearance": "sepia" }"#);
        assert_eq!(resolved.settings.appearance, AppearancePreference::System);
        assert_eq!(resolved.issues.len(), 1);
        assert_eq!(resolved.issues[0].severity, Severity::Warning);
        assert!(resolved.issues[0].message.contains("sepia"));
    }

    #[test]
    fn the_status_bar_uptime_is_opt_in() {
        assert!(!resolve("{}").settings.status_bar_uptime);
        assert!(resolve(r#"{ "statusBar": { "uptime": true } }"#).settings.status_bar_uptime);
    }

    #[test]
    fn project_directories_expand_tildes_and_reject_paths_that_are_not_directories() {
        let missing = format!("/tmp/soprano-tests-does-not-exist-{}", std::process::id());
        let resolved = resolve(&format!(r#"{{ "projectDirectories": ["~", "{missing}"] }}"#));
        assert_eq!(resolved.settings.project_directories, [home()]);
        assert!(has_issue(&resolved, |m| m.contains(&missing)));
    }

    // MARK: Keybindings

    #[test]
    fn a_chord_override_retargets_the_binding_and_marks_it_customized() {
        let resolved = resolve(r#"{ "keybindings": { "bindings": { "new-browser": "cmd+shift+b" } } }"#);
        let binding = find(&resolved, "new-browser").expect("binding");
        assert_eq!(binding.key, "b");
        assert_eq!(binding.meta, Some(true));
        assert_eq!(binding.shift, Some(true));
        assert_eq!(binding.default_keys, KeyChord::from_binding(binding).display_string());
        if KeyPlatform::current() == KeyPlatform::Mac {
            assert_eq!(binding.default_keys, "⇧⌘B");
        }
        assert_eq!(resolved.customized_binding_ids, BTreeSet::from(["new-browser".to_string()]));
        assert!(resolved.issues.is_empty());
    }

    #[test]
    fn a_binding_set_to_null_is_removed_from_the_active_set_and_listed_as_disabled() {
        let resolved = resolve(r#"{ "keybindings": { "bindings": { "zoom-reset": null } } }"#);
        assert!(find(&resolved, "zoom-reset").is_none());
        assert_eq!(resolved.disabled_binding_ids, BTreeSet::from(["zoom-reset".to_string()]));
        assert!(resolved.issues.is_empty());
    }

    #[test]
    fn a_shifted_symbol_binds_without_having_to_spell_out_shift() {
        // "|" cannot be typed without Shift, so both spellings must land on the chord the key
        // actually produces — otherwise the binding is written, accepted, and never fires.
        let terse = resolve(r#"{ "keybindings": { "bindings": { "split-vertical": "prefix+|" } } }"#);
        let explicit =
            resolve(r#"{ "keybindings": { "bindings": { "split-vertical": "prefix+shift+|" } } }"#);
        let binding = find(&terse, "split-vertical").expect("binding");
        assert_eq!(binding.key, "|");
        assert_eq!(binding.shift, Some(true));
        assert_eq!(Some(binding), find(&explicit, "split-vertical"));
        assert_eq!(binding, &default_binding("split-vertical"));
    }

    #[test]
    fn an_unknown_action_id_is_reported_without_disturbing_the_other_bindings() {
        let resolved = resolve(r#"{ "keybindings": { "bindings": { "summon-a-pony": "cmd+9" } } }"#);
        assert_eq!(resolved.keybindings.bindings.len(), DefaultKeybindings::config().bindings.len());
        assert!(has_issue(&resolved, |m| m.contains("summon-a-pony")));
    }

    #[test]
    fn an_unparseable_chord_is_reported_and_the_default_chord_stays() {
        let resolved = resolve(r#"{ "keybindings": { "bindings": { "new-terminal": "alt+t" } } }"#);
        assert_eq!(find(&resolved, "new-terminal"), Some(&default_binding("new-terminal")));
        assert!(resolved.customized_binding_ids.is_empty());
        assert!(has_issue(&resolved, |m| m.contains("alt+t")));
    }

    #[test]
    fn out_of_range_numbers_are_clamped_and_reported() {
        let resolved = resolve(r#"{ "keybindings": { "prefixTimeoutMs": 99999, "resizeTickPercent": 0 } }"#);
        assert_eq!(resolved.keybindings.prefix_timeout_ms, 5000);
        assert_eq!(resolved.keybindings.resize_tick_percent, 1.0);
        assert_eq!(resolved.issues.len(), 2);
        assert!(resolved.issues.iter().all(|i| i.severity == Severity::Warning));
    }

    #[test]
    fn a_multi_character_prefix_key_is_rejected() {
        let resolved = resolve(r#"{ "keybindings": { "prefixKey": "esc" } }"#);
        assert_eq!(resolved.keybindings.prefix_key, DefaultKeybindings::config().prefix_key);
        assert!(has_issue(&resolved, |m| m.contains("prefixKey")));
    }

    #[test]
    fn two_bindings_on_the_same_chord_are_reported_as_a_conflict() {
        // ⌘T already belongs to new-tab-direct.
        let resolved = resolve(r#"{ "keybindings": { "bindings": { "new-browser": "cmd+t" } } }"#);
        assert!(has_issue(&resolved, |m| m.contains("new-browser") && m.contains("new-tab-direct")));
    }

    #[test]
    fn a_first_run_template_seeded_with_a_backslash_prefix_and_a_quote_chord_still_parses() {
        let mut keybindings = DefaultKeybindings::config();
        keybindings.prefix_key = "\\".into();
        let index = keybindings.bindings.iter().position(|b| b.id == "split-vertical").expect("binding");
        let old = keybindings.bindings[index].clone();
        keybindings.bindings[index] =
            KeyBinding { mode: KeyBindingMode::Prefix, key: "\"".into(), shift: Some(true), ..old };

        let template = crate::config_file::template(&AppSettings::default(), &keybindings);
        let resolved = jsonc::decode::<SopranoConfig>(&template).expect("template decodes").resolved();

        assert_eq!(resolved.keybindings.prefix_key, "\\");
        let binding = find(&resolved, "split-vertical").expect("binding");
        assert_eq!(KeyChord::from_binding(binding), KeyChord::from_binding(&keybindings.bindings[index]));
    }

    // MARK: Agents

    #[test]
    fn a_new_agent_joins_the_catalog_with_defaults_filled_in() {
        let resolved = resolve(
            r#"{ "agents": [ { "id": "aider", "command": "aider", "args": ["--no-auto-commits"] } ] }"#,
        );
        let agent = resolved.agents.iter().find(|a| a.id == "aider").expect("agent");
        assert_eq!(agent.name, "Aider");
        assert_eq!(agent.command, "aider");
        assert_eq!(agent.args, ["--no-auto-commits"]);
        assert!(agent.color.starts_with('#'));
        assert_eq!(resolved.configured_agent_ids, BTreeSet::from(["aider".to_string()]));
        assert_eq!(resolved.agents.len(), DefaultAgents::all().len() + 1);
        assert!(resolved.issues.is_empty());
    }

    /// Config side of "a configured agent reaches the terminal as the command it declared":
    /// arguments, env and cwd arrive in the profile untouched (the terminal crate quotes them).
    #[test]
    fn a_configured_agent_keeps_its_arguments_env_and_expanded_cwd() {
        let resolved = resolve(
            r#"{ "agents": [ { "id": "aider", "command": "aider",
                 "args": ["--no-auto-commits", "a file.py", "$(echo smuggled)"],
                 "env": { "AIDER_DARK_MODE": "1" }, "cwd": "~" } ] }"#,
        );
        let profile = resolved.agents.iter().find(|a| a.id == "aider").expect("agent");
        assert_eq!(profile.args, ["--no-auto-commits", "a file.py", "$(echo smuggled)"]);
        assert_eq!(
            profile.env.as_ref().and_then(|e| e.get("AIDER_DARK_MODE")).map(String::as_str),
            Some("1")
        );
        assert_eq!(profile.cwd.as_deref(), Some(home().as_str()));
    }

    #[test]
    fn a_configured_launch_script_is_kept_on_the_profile() {
        let resolved = resolve(
            r#"{ "agents": [ { "id": "aider", "command": "aider", "launchScript": "nvm use 22 && aider" } ] }"#,
        );
        let profile = resolved.agents.iter().find(|a| a.id == "aider").expect("agent");
        assert_eq!(profile.launch_script.as_deref(), Some("nvm use 22 && aider"));
    }

    #[test]
    fn a_new_agent_without_a_command_is_rejected() {
        let resolved = resolve(r#"{ "agents": [ { "id": "ghost", "name": "Ghost" } ] }"#);
        assert!(!resolved.agents.iter().any(|a| a.id == "ghost"));
        assert!(has_issue(&resolved, |m| m.contains("ghost")));
    }

    #[test]
    fn reusing_a_built_in_id_patches_only_the_fields_it_names() {
        let resolved = resolve(r#"{ "agents": [ { "id": "codex", "args": ["--model", "o3"] } ] }"#);
        let codex = resolved.agents.iter().find(|a| a.id == "codex").expect("codex");
        let builtin = DefaultAgents::codex();
        assert_eq!(codex.args, ["--model", "o3"]);
        assert_eq!(codex.name, builtin.name);
        assert_eq!(codex.command, builtin.command);
        assert_eq!(codex.color, builtin.color);
        assert_eq!(codex.patterns, builtin.patterns);
        assert_eq!(resolved.agents.len(), DefaultAgents::all().len());
    }

    #[test]
    fn a_launch_key_synthesizes_a_shortcut_for_a_new_agent() {
        let resolved =
            resolve(r#"{ "agents": [ { "id": "aider", "command": "aider", "launchKey": "cmd+5" } ] }"#);
        let binding = find(&resolved, "launch-aider").expect("binding");
        assert_eq!(binding.key, "5");
        assert_eq!(binding.meta, Some(true));
        assert_eq!(binding.category, KeyBindingCategory::Agents);
        assert_eq!(binding.default_keys, KeyChord::from_binding(binding).display_string());
        if KeyPlatform::current() == KeyPlatform::Mac {
            assert_eq!(binding.default_keys, "⌘5");
        }
    }

    #[test]
    fn a_launch_key_retargets_a_built_in_agent_shortcut() {
        let resolved = resolve(r#"{ "agents": [ { "id": "codex", "launchKey": "cmd+7" } ] }"#);
        let launchers: Vec<_> =
            resolved.keybindings.bindings.iter().filter(|b| b.id == "launch-codex").collect();
        assert_eq!(launchers.len(), 1);
        assert_eq!(launchers[0].key, "7");
    }

    #[test]
    fn an_explicit_binding_wins_over_an_agent_launch_key_for_the_same_action() {
        let resolved = resolve(
            r#"{ "keybindings": { "bindings": { "launch-aider": "cmd+8" } },
                 "agents": [ { "id": "aider", "command": "aider", "launchKey": "cmd+5" } ] }"#,
        );
        assert_eq!(find(&resolved, "launch-aider").map(|b| b.key.as_str()), Some("8"));
    }

    #[test]
    fn a_launcher_can_be_bound_from_the_bindings_table_alone_without_a_launch_key() {
        let resolved = resolve(
            r#"{ "keybindings": { "bindings": { "launch-aider": "cmd+8" } },
                 "agents": [ { "id": "aider", "command": "aider" } ] }"#,
        );
        let binding = find(&resolved, "launch-aider").expect("binding");
        assert_eq!(binding.key, "8");
        assert_eq!(binding.meta, Some(true));
        assert!(!has_issue(&resolved, |m| m.contains("unknown action")));
    }

    #[test]
    fn a_bad_launch_key_is_reported_against_the_key_the_user_actually_wrote() {
        let resolved =
            resolve(r#"{ "agents": [ { "id": "aider", "command": "aider", "launchKey": "alt+z" } ] }"#);
        assert!(has_issue(&resolved, |m| m.contains("agents[aider].launchKey")));
        assert!(!has_issue(&resolved, |m| m.contains("keybindings.bindings")));
    }

    #[test]
    fn a_chord_shadowed_by_zoom_ins_plus_alias_is_reported() {
        let resolved = resolve(r#"{ "keybindings": { "bindings": { "new-browser": "cmd+plus" } } }"#);
        assert!(has_issue(&resolved, |m| m.contains("new-browser") && m.contains("zoom-in")));
    }

    #[test]
    fn a_prefix_key_that_steals_a_direct_ctrl_shortcut_is_reported() {
        // Ctrl+H is "Focus Left"; making "h" the prefix silently consumes it.
        let resolved = resolve(r#"{ "keybindings": { "prefixKey": "h" } }"#);
        assert!(has_issue(&resolved, |m| m.contains("nav-left") && m.contains("prefixKey")));
    }

    #[test]
    fn a_launch_shortcut_for_an_agent_that_does_not_exist_is_reported() {
        let resolved = resolve(r#"{ "keybindings": { "bindings": { "launch-nothing": "cmd+9" } } }"#);
        assert!(find(&resolved, "launch-nothing").is_none());
        assert!(has_issue(&resolved, |m| m.contains("launch-nothing")));
    }

    #[test]
    fn a_duplicate_agent_id_is_reported_and_the_first_entry_wins() {
        let resolved = resolve(
            r#"{ "agents": [ { "id": "aider", "command": "aider" }, { "id": "aider", "command": "somethingelse" } ] }"#,
        );
        assert_eq!(
            resolved.agents.iter().find(|a| a.id == "aider").map(|a| a.command.as_str()),
            Some("aider")
        );
        assert!(has_issue(&resolved, |m| m.contains("duplicate")));
    }

    #[test]
    fn installing_agents_replaces_a_catalogs_profiles_with_the_merged_list() {
        let resolved = resolve(r#"{ "agents": [ { "id": "aider", "command": "aider" } ] }"#);
        let catalog = AgentCatalog::new(DefaultAgents::all());
        install_agents(&catalog, &resolved.agents);
        assert_eq!(catalog.profile("aider").map(|p| p.command), Some("aider".into()));
        assert_eq!(catalog.all().len(), DefaultAgents::all().len() + 1);
    }

    #[test]
    fn custom_agent_names_and_colors_are_derived_from_the_id() {
        assert_eq!(default_name("my-cool-agent"), "My Cool Agent");
        assert_eq!(default_color("aider"), default_color("aider"));
        assert!(default_color("x").starts_with('#'));
    }

    // MARK: - NotificationSettingsTests / WindowBarSettingsTests

    #[test]
    fn notification_sound_is_off_in_the_resolved_defaults() {
        assert!(!ResolvedConfig::defaults().settings.notification_sound);
    }

    #[test]
    fn the_file_can_turn_the_sound_on() {
        let config = SopranoConfig {
            notifications: Some(NotificationsConfig { sound: Some(true) }),
            ..SopranoConfig::default()
        };
        let resolved = config.resolved();
        assert!(resolved.settings.notification_sound);
        assert!(resolved.issues.is_empty());
    }

    #[test]
    fn the_file_can_turn_the_sound_back_off_against_a_non_default_base() {
        let base = AppSettings { notification_sound: true, ..AppSettings::default() };
        let config = SopranoConfig {
            notifications: Some(NotificationsConfig { sound: Some(false) }),
            ..SopranoConfig::default()
        };
        let resolved = config.resolved_with(&base, &DefaultKeybindings::config(), &DefaultAgents::all());
        assert!(!resolved.settings.notification_sound);
    }

    #[test]
    fn omitting_the_section_leaves_whatever_the_base_said() {
        let base = AppSettings { notification_sound: true, ..AppSettings::default() };
        let empty = SopranoConfig::default();
        assert!(
            empty
                .resolved_with(&base, &DefaultKeybindings::config(), &DefaultAgents::all())
                .settings
                .notification_sound
        );
        assert!(!empty.resolved().settings.notification_sound);
    }

    #[test]
    fn an_empty_notifications_section_is_not_an_error() {
        let config = SopranoConfig {
            notifications: Some(NotificationsConfig { sound: None }),
            ..SopranoConfig::default()
        };
        let resolved = config.resolved();
        assert!(!resolved.settings.notification_sound);
        assert!(resolved.issues.is_empty());
    }

    #[test]
    fn toggling_the_sound_writes_into_a_file_that_has_no_notifications_section_yet() {
        let existing = "{\n  // A file written before notifications were configurable.\n  \"theme\": \"gruvbox-dark\",\n  \"restoreLastSession\": true\n}";
        let updated =
            jsonc::setting(&serde_json::json!(true), &["notifications", "sound"], existing).expect("writes");
        assert!(updated.contains("\"notifications\""));
        assert!(updated.contains("\"sound\""));
        assert!(updated.contains("// A file written before notifications were configurable."));
        assert!(updated.contains("\"theme\": \"gruvbox-dark\""));
        let decoded: SopranoConfig = jsonc::decode(&updated).expect("decodes");
        assert_eq!(decoded.notifications.and_then(|n| n.sound), Some(true));
        assert_eq!(decoded.theme.as_deref(), Some("gruvbox-dark"));
    }

    #[test]
    fn the_window_bar_is_visible_in_the_resolved_defaults() {
        assert!(!ResolvedConfig::defaults().settings.hide_window_bar);
    }

    #[test]
    fn the_file_can_hide_and_restore_the_window_bar() {
        let mut config = SopranoConfig { hide_window_bar: Some(true), ..SopranoConfig::default() };
        assert!(config.resolved().settings.hide_window_bar);
        let base = AppSettings { hide_window_bar: true, ..AppSettings::default() };
        config.hide_window_bar = Some(false);
        assert!(
            !config
                .resolved_with(&base, &DefaultKeybindings::config(), &DefaultAgents::all())
                .settings
                .hide_window_bar
        );
    }

    // MARK: - AutomationConfigTests

    #[test]
    fn a_complete_entry_resolves_with_the_defaults_it_left_out() {
        let resolved = resolve(
            r#"{ "automations": { "weekday-audit": {
                "name": "Weekday repo audit", "agent": "omp", "folder": "~/",
                "prompt": "  Review the repository.  ", "schedule": "0 9 * * 1-5" } } }"#,
        );
        assert!(resolved.issues.is_empty(), "{:?}", resolved.issues);
        let automation = resolved.automations.first().expect("automation");
        assert_eq!(automation.id, "weekday-audit");
        assert_eq!(automation.folder, home());
        assert_eq!(automation.prompt, "Review the repository.");
        assert_eq!(automation.cadence(), AutomationCadence::Weekdays { hour: 9, minute: 0 });
        assert!(automation.enabled);
        assert_eq!(automation.workspace, AutomationWorkspace::Folder);
        assert_eq!(automation.session, AutomationSession::Fresh);
        assert_eq!(automation.grace_minutes, Automation::DEFAULT_GRACE_MINUTES);
        assert_eq!(automation.precheck_timeout_seconds, Automation::DEFAULT_PRECHECK_TIMEOUT_SECONDS);
        assert_eq!(automation.model, None);
    }

    #[test]
    fn entries_missing_what_a_run_needs_are_left_out_and_named_in_the_issues() {
        let resolved = resolve(
            r#"{ "automations": {
                "no-prompt": { "agent": "omp", "folder": "/tmp", "schedule": "0 9 * * *" },
                "no-folder": { "agent": "omp", "prompt": "x", "schedule": "0 9 * * *" },
                "no-agent": { "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" },
                "bad-cron": { "agent": "omp", "folder": "/tmp", "prompt": "x", "schedule": "0 25 * * *" },
                "shell": { "agent": "terminal", "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" } } }"#,
        );
        assert!(resolved.automations.is_empty());
        assert_eq!(resolved.issues.len(), 5);
        for id in ["no-prompt", "no-folder", "no-agent", "bad-cron", "shell"] {
            assert!(has_issue(&resolved, |m| m.starts_with(&format!("automations.{id}:"))), "{id}");
        }
        assert!(has_issue(&resolved, |m| m.contains("25 is outside the hour range")));
    }

    #[test]
    fn reusing_the_last_agent_cannot_be_combined_with_a_worktree_and_falls_back_to_fresh() {
        let resolved = resolve(
            r#"{ "automations": { "nightly": {
                "agent": "claude-code", "folder": "/tmp", "prompt": "x", "schedule": "0 2 * * *",
                "worktree": true, "session": "reuse" } } }"#,
        );
        let automation = resolved.automations.first().expect("automation");
        assert_eq!(automation.session, AutomationSession::Fresh);
        assert_eq!(automation.workspace, AutomationWorkspace::Worktree { base_branch: None });
        assert_eq!(resolved.issues.len(), 1);
    }

    #[test]
    fn an_out_of_range_grace_period_falls_back_to_the_default_with_a_warning() {
        let resolved = resolve(
            r#"{ "automations": { "audit": { "agent": "omp", "folder": "/tmp", "prompt": "x",
                "schedule": "0 9 * * *", "graceMinutes": -5 } } }"#,
        );
        assert_eq!(
            resolved.automations.first().map(|a| a.grace_minutes),
            Some(Automation::DEFAULT_GRACE_MINUTES)
        );
        assert_eq!(resolved.issues.len(), 1);
    }

    #[test]
    fn automations_are_listed_by_name() {
        let resolved = resolve(
            r#"{ "automations": {
                "a": { "name": "Zebra", "agent": "omp", "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" },
                "b": { "name": "apple", "agent": "omp", "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" } } }"#,
        );
        let names: Vec<&str> = resolved.automations.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, ["apple", "Zebra"]);
    }
}
