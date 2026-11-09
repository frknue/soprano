//! The Agent Profiles page: every agent in the catalog (built-in, patched, or declared in
//! `settings.json`) with its launch details, edited field by field into the file's `agents`
//! list. Each edit rewrites that one key, `agents`, with the one entry changed.

use soprano_config::{AgentConfig, ConfigStore, SopranoConfig};
use soprano_types::{AgentProfile, DefaultAgents};

pub const AGENTS_KEY: &[&str] = &["agents"];

pub const INTRO_TITLE: &str = "Agent profiles";
pub const INTRO: &str = "The agents Soprano can launch. Edit a profile below, or add your own under \"agents\" in settings.json — for example { \"id\": \"aider\", \"name\": \"Aider\", \"command\": \"aider\", \"launchKey\": \"cmd+4\" }. Reusing a built-in id patches that profile instead of creating a new one.";
pub const CONFIGURED_BADGE: &str = "settings.json";

/// A profile field the page edits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AgentField {
    Name,
    Description,
    Command,
    Arguments,
    WorkingDirectory,
    LaunchKey,
    Color,
}

impl AgentField {
    pub const ALL: [AgentField; 7] = [
        AgentField::Name,
        AgentField::Description,
        AgentField::Command,
        AgentField::Arguments,
        AgentField::WorkingDirectory,
        AgentField::LaunchKey,
        AgentField::Color,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Name => "Name",
            Self::Description => "Description",
            Self::Command => "Command",
            Self::Arguments => "Arguments",
            Self::WorkingDirectory => "Working directory",
            Self::LaunchKey => "Launch shortcut",
            Self::Color => "Color",
        }
    }

    /// The `settings.json` key of the field inside an `agents` entry.
    pub fn json_key(self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::Description => "description",
            Self::Command => "command",
            Self::Arguments => "args",
            Self::WorkingDirectory => "cwd",
            Self::LaunchKey => "launchKey",
            Self::Color => "color",
        }
    }

    pub fn is_mono(self) -> bool {
        matches!(
            self,
            Self::Command | Self::Arguments | Self::WorkingDirectory | Self::LaunchKey | Self::Color
        )
    }

    /// What the field shows: the value in force for the profile, or for the launch shortcut the
    /// file's chord (it has no profile counterpart).
    pub fn displayed(self, profile: &AgentProfile, entry: Option<&AgentConfig>) -> String {
        match self {
            Self::Name => profile.name.clone(),
            Self::Description => profile.description.clone(),
            Self::Command => profile.command.clone(),
            Self::Arguments => join_arguments(&profile.args),
            Self::WorkingDirectory => {
                entry.and_then(|e| e.cwd.clone()).or_else(|| profile.cwd.clone()).unwrap_or_default()
            }
            Self::LaunchKey => entry.and_then(|e| e.launch_key.clone()).unwrap_or_default(),
            Self::Color => profile.color.clone(),
        }
    }

    /// Placeholder text for an empty field.
    pub fn placeholder(self) -> &'static str {
        match self {
            Self::Name => "Name",
            Self::Description => "What it does",
            Self::Command => "Executable",
            Self::Arguments => "--flag value",
            Self::WorkingDirectory => "Pane's directory",
            Self::LaunchKey => "cmd+4",
            Self::Color => "#83a598",
        }
    }

    /// Sets the field on `entry`; empty text removes the key so the built-in value (or the
    /// default) applies again.
    fn apply(self, entry: &mut AgentConfig, text: &str) {
        let trimmed = text.trim();
        let value = (!trimmed.is_empty()).then(|| trimmed.to_owned());
        match self {
            Self::Name => entry.name = value,
            Self::Description => entry.description = value,
            Self::Command => entry.command = value,
            Self::Arguments => entry.args = value.map(|text| split_arguments(&text)),
            Self::WorkingDirectory => entry.cwd = value,
            Self::LaunchKey => entry.launch_key = value,
            Self::Color => entry.color = value,
        }
    }
}

/// Whether `id` is one of Soprano's own agents (its entry patches it; removing the entry
/// restores the built-in profile).
pub fn is_built_in(id: &str) -> bool {
    DefaultAgents::profile(id).is_some()
}

/// The file's entry for `id`, if it has one.
pub fn configured_entry(config: &SopranoConfig, id: &str) -> Option<AgentConfig> {
    config.agents.as_ref()?.iter().find(|entry| entry.id.trim() == id).cloned()
}

/// Writes `field` of agent `id` from `text`, creating the entry when the file has none, and
/// dropping it when nothing is left to patch on a built-in. Unchanged text writes nothing.
pub fn set_agent_field(store: &ConfigStore, id: &str, field: AgentField, text: &str) -> bool {
    let config = store.config();
    let mut entries = config.agents.clone().unwrap_or_default();
    let index = entries.iter().position(|entry| entry.id.trim() == id);
    let mut entry = index
        .map_or_else(|| AgentConfig { id: id.to_owned(), ..AgentConfig::default() }, |i| entries[i].clone());
    let before = entry.clone();
    field.apply(&mut entry, text);

    // Typing the built-in value back is not a customization.
    if is_built_in(id)
        && let Some(builtin) = DefaultAgents::profile(id)
        && field != AgentField::LaunchKey
        && field != AgentField::WorkingDirectory
        && field.displayed(&builtin, None) == text.trim()
    {
        field.apply(&mut entry, "");
    }
    if entry == before {
        return true;
    }
    let is_empty_patch =
        is_built_in(id) && entry == AgentConfig { id: entry.id.clone(), ..AgentConfig::default() };
    match (index, is_empty_patch) {
        (Some(i), true) => {
            entries.remove(i);
        }
        (Some(i), false) => entries[i] = entry,
        (None, true) => return true,
        (None, false) => entries.push(entry),
    }
    write_entries(store, &entries)
}

/// Removes the file's entry for `id`: a built-in goes back to its defaults, a declared agent
/// disappears.
pub fn remove_agent_entry(store: &ConfigStore, id: &str) -> bool {
    let mut entries = store.config().agents.unwrap_or_default();
    let before = entries.len();
    entries.retain(|entry| entry.id.trim() != id);
    if entries.len() == before {
        return true;
    }
    write_entries(store, &entries)
}

/// Why a new agent could not be added.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AddAgentError {
    MissingId,
    InvalidId,
    DuplicateId,
    MissingCommand,
    WriteFailed,
}

impl AddAgentError {
    pub fn message(self) -> &'static str {
        match self {
            Self::MissingId => "Give the agent an id.",
            Self::InvalidId => "Use lowercase letters, digits and dashes for the id.",
            Self::DuplicateId => "An agent with this id already exists.",
            Self::MissingCommand => "Give the agent a command to run.",
            Self::WriteFailed => "settings.json could not be written.",
        }
    }
}

/// Declares a new agent `{ "id", "command" }` (plus a name when given).
pub fn add_agent(
    store: &ConfigStore,
    id: &str,
    name: &str,
    command: &str,
    existing: &[AgentProfile],
) -> Result<(), AddAgentError> {
    let id = id.trim();
    if id.is_empty() {
        return Err(AddAgentError::MissingId);
    }
    if !id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') || id.starts_with('-') {
        return Err(AddAgentError::InvalidId);
    }
    let mut entries = store.config().agents.unwrap_or_default();
    if existing.iter().any(|profile| profile.id == id) || entries.iter().any(|entry| entry.id.trim() == id) {
        return Err(AddAgentError::DuplicateId);
    }
    let command = command.trim();
    if command.is_empty() {
        return Err(AddAgentError::MissingCommand);
    }
    let name = name.trim();
    entries.push(AgentConfig {
        id: id.to_owned(),
        name: (!name.is_empty()).then(|| name.to_owned()),
        command: Some(command.to_owned()),
        ..AgentConfig::default()
    });
    if write_entries(store, &entries) { Ok(()) } else { Err(AddAgentError::WriteFailed) }
}

fn write_entries(store: &ConfigStore, entries: &[AgentConfig]) -> bool {
    if entries.is_empty() {
        return store.remove(AGENTS_KEY);
    }
    match serde_json::to_value(entries) {
        Ok(value) => store.write(value, AGENTS_KEY),
        Err(_) => false,
    }
}

/// `$ claude --model opus`
pub fn command_line(profile: &AgentProfile) -> String {
    let mut parts = vec![quoted(&profile.command)];
    parts.extend(profile.args.iter().map(|arg| quoted(arg)));
    format!("$ {}", parts.join(" "))
}

/// `Ready: Claude, >, ❯  ·  Error: Error, error:, FAILED`
pub fn patterns_line(profile: &AgentProfile) -> String {
    let join = |list: Option<&Vec<String>>| list.map_or_else(|| "–".to_owned(), |l| l.join(", "));
    let patterns = profile.patterns.as_ref();
    format!(
        "Ready: {}  ·  Error: {}",
        join(patterns.and_then(|p| p.ready.as_ref())),
        join(patterns.and_then(|p| p.error.as_ref()))
    )
}

/// Arguments as one editable line: space-separated, quoting the ones that need it.
pub fn join_arguments(args: &[String]) -> String {
    args.iter().map(|arg| quoted(arg)).collect::<Vec<_>>().join(" ")
}

fn quoted(arg: &str) -> String {
    if !arg.is_empty() && !arg.chars().any(|c| c.is_whitespace() || c == '"' || c == '\'') {
        return arg.to_owned();
    }
    format!("\"{}\"", arg.replace('\\', "\\\\").replace('"', "\\\""))
}

/// The line back into arguments: whitespace separates, single or double quotes group, and a
/// backslash escapes the next character (outside single quotes).
pub fn split_arguments(text: &str) -> Vec<String> {
    let mut arguments = Vec::new();
    let mut current = String::new();
    let mut in_argument = false;
    let mut quote: Option<char> = None;
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some('\''), '\'') | (Some('"'), '"') => quote = None,
            (Some('\''), _) => current.push(c),
            (_, '\\') => {
                if let Some(next) = chars.next() {
                    current.push(next);
                }
                in_argument = true;
            }
            (Some(_), _) => current.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_argument = true;
            }
            (None, c) if c.is_whitespace() => {
                if in_argument {
                    arguments.push(std::mem::take(&mut current));
                    in_argument = false;
                }
            }
            (None, c) => {
                current.push(c);
                in_argument = true;
            }
        }
    }
    if in_argument {
        arguments.push(current);
    }
    arguments
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::{AppSettings, DefaultKeybindings};
    use std::sync::Arc;

    fn store() -> (ConfigStore, tempfile::TempDir) {
        let directory = tempfile::tempdir().expect("temp dir");
        let store = ConfigStore::with_catalog(
            directory.path().join("settings.json"),
            Arc::new(soprano_types::AgentCatalog::new(DefaultAgents::all())),
        );
        store.start(false, &AppSettings::default(), &DefaultKeybindings::config());
        (store, directory)
    }

    fn agent(store: &ConfigStore, id: &str) -> AgentProfile {
        store.resolved().agents.into_iter().find(|p| p.id == id).expect("agent")
    }

    #[test]
    fn editing_a_built_in_patches_only_that_field_under_agents() {
        let (store, _dir) = store();
        assert!(set_agent_field(&store, "codex", AgentField::Arguments, "--model o3"));
        let entry = configured_entry(&store.config(), "codex").expect("entry");
        assert_eq!(entry.args, Some(vec!["--model".to_owned(), "o3".to_owned()]));
        assert_eq!(entry.command, None);
        assert_eq!(agent(&store, "codex").args, ["--model", "o3"]);
        assert!(store.resolved().configured_agent_ids.contains("codex"));
        let text = std::fs::read_to_string(store.file_path()).expect("file");
        assert!(text.contains("\"agents\""));
        assert!(text.contains("\"--model\""));
    }

    #[test]
    fn clearing_the_last_patched_field_of_a_built_in_drops_its_entry() {
        let (store, _dir) = store();
        assert!(set_agent_field(&store, "codex", AgentField::Name, "Codex Pro"));
        assert_eq!(agent(&store, "codex").name, "Codex Pro");
        assert!(set_agent_field(&store, "codex", AgentField::Name, ""));
        assert_eq!(configured_entry(&store.config(), "codex"), None);
        assert_eq!(agent(&store, "codex").name, "Codex");
        assert!(!store.resolved().configured_agent_ids.contains("codex"));
    }

    #[test]
    fn typing_the_built_in_value_back_is_not_a_customization() {
        let (store, _dir) = store();
        assert!(set_agent_field(&store, "omp", AgentField::Command, "omp"));
        assert_eq!(configured_entry(&store.config(), "omp"), None);
    }

    #[test]
    fn adding_a_new_agent_declares_it_and_validates_the_entry() {
        let (store, _dir) = store();
        let existing = store.resolved().agents;
        assert_eq!(add_agent(&store, "", "", "aider", &existing), Err(AddAgentError::MissingId));
        assert_eq!(add_agent(&store, "Aider X", "", "aider", &existing), Err(AddAgentError::InvalidId));
        assert_eq!(add_agent(&store, "codex", "", "codex", &existing), Err(AddAgentError::DuplicateId));
        assert_eq!(add_agent(&store, "aider", "", " ", &existing), Err(AddAgentError::MissingCommand));
        assert_eq!(add_agent(&store, "aider", "Aider", "aider", &existing), Ok(()));
        let aider = agent(&store, "aider");
        assert_eq!(aider.name, "Aider");
        assert_eq!(aider.command, "aider");
        assert!(set_agent_field(&store, "aider", AgentField::LaunchKey, "cmd+4"));
        assert!(store.resolved().keybindings.bindings.iter().any(|b| b.id == "launch-aider"));
    }

    #[test]
    fn removing_an_entry_restores_the_built_in_or_drops_the_declared_agent() {
        let (store, _dir) = store();
        let existing = store.resolved().agents;
        add_agent(&store, "aider", "", "aider", &existing).expect("added");
        assert!(set_agent_field(&store, "codex", AgentField::Command, "codex-beta"));
        assert!(remove_agent_entry(&store, "codex"));
        assert_eq!(agent(&store, "codex").command, "codex");
        assert!(remove_agent_entry(&store, "aider"));
        assert!(!store.resolved().agents.iter().any(|p| p.id == "aider"));
        assert!(!std::fs::read_to_string(store.file_path()).expect("file").contains("\"agents\""));
    }

    #[test]
    fn arguments_round_trip_through_one_line() {
        let args = vec!["--model".to_owned(), "o3 mini".to_owned(), "say \"hi\"".to_owned()];
        assert_eq!(split_arguments(&join_arguments(&args)), args);
        assert_eq!(split_arguments("  a  'b c'  d\\ e "), ["a", "b c", "d e"]);
        assert_eq!(split_arguments(""), Vec::<String>::new());
        assert_eq!(split_arguments("\"\""), [""]);
    }

    #[test]
    fn the_profile_lines_match_the_swift_rows() {
        let claude = DefaultAgents::claude_code();
        assert_eq!(command_line(&claude), "$ claude");
        assert_eq!(patterns_line(&claude), "Ready: Claude, >, ❯  ·  Error: Error, error:, FAILED");
        assert_eq!(patterns_line(&DefaultAgents::omp()), "Ready: –  ·  Error: –");
    }
}
