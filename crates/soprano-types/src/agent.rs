//! Agent profiles, the process-wide catalog, and agent runtime status
//! (`Models/AgentProfile.swift`, `Models/AgentInstance.swift`, `Models/AgentConversation.swift`,
//! `Config/DefaultAgents.swift`, `Config/AgentCatalog.swift`).

use std::collections::{BTreeMap, HashSet};
use std::sync::{LazyLock, RwLock};

use serde::{Deserialize, Serialize};

/// Static definition of an AI coding agent profile.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentProfile {
    pub id: String,
    pub name: String,
    pub icon: String,
    /// CSS hex color (`#10a37f`); see [`crate::Color::from_hex`].
    pub color: String,
    pub description: String,
    pub command: String,
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_script: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_restart: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restart_delay_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub patterns: Option<OutputPatterns>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct OutputPatterns {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completion: Option<Vec<String>>,
}

impl AgentProfile {
    pub fn color(&self) -> crate::Color {
        crate::Color::from_hex(&self.color)
    }

    fn builtin(id: &str, name: &str, icon: &str, color: &str, description: &str, command: &str) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            icon: icon.into(),
            color: color.into(),
            description: description.into(),
            command: command.into(),
            args: vec![],
            env: None,
            cwd: None,
            launch_script: None,
            auto_restart: None,
            restart_delay_ms: None,
            patterns: None,
        }
    }
}

fn patterns(ready: &[&str], error: &[&str]) -> Option<OutputPatterns> {
    let owned = |v: &[&str]| Some(v.iter().map(|s| s.to_string()).collect());
    Some(OutputPatterns { ready: owned(ready), error: owned(error), idle: None, completion: None })
}

/// Built-in agent profile definitions.
pub struct DefaultAgents;

impl DefaultAgents {
    pub const CODEX: &'static str = "codex";
    pub const CLAUDE_CODE: &'static str = "claude-code";
    pub const OPENCODE: &'static str = "opencode";
    pub const OMP: &'static str = "omp";
    pub const TERMINAL: &'static str = "terminal";

    pub fn codex() -> AgentProfile {
        AgentProfile {
            patterns: patterns(&["Codex is ready", ">"], &["Error", "error:", "FAILED"]),
            ..AgentProfile::builtin("codex", "Codex", "bot", "#10a37f", "OpenAI Codex coding agent", "codex")
        }
    }

    pub fn claude_code() -> AgentProfile {
        AgentProfile {
            patterns: patterns(&["Claude", ">", "❯"], &["Error", "error:", "FAILED"]),
            ..AgentProfile::builtin(
                "claude-code",
                "Claude Code",
                "sparkles",
                "#da7756",
                "Anthropic Claude Code CLI agent",
                "claude",
            )
        }
    }

    pub fn open_code() -> AgentProfile {
        AgentProfile {
            patterns: patterns(&[">", "Ready"], &["Error", "error:", "FAILED"]),
            ..AgentProfile::builtin("opencode", "Open Code", "zap", "#58a6ff", "OpenCode terminal agent", "opencode")
        }
    }

    pub fn omp() -> AgentProfile {
        AgentProfile::builtin("omp", "omp", "sparkles", "#b8a4ff", "Oh My Pi terminal coding agent", "omp")
    }

    /// The plain login shell: `$SHELL --login` (`/bin/zsh` when unset) on Unix; PowerShell on
    /// Windows, which has no `--login`.
    pub fn terminal() -> AgentProfile {
        let (command, args) = default_shell();
        AgentProfile {
            args,
            ..AgentProfile::builtin("terminal", "Terminal", "terminal", "#fe8019", "Plain system login shell", &command)
        }
    }

    pub fn all() -> Vec<AgentProfile> {
        vec![Self::codex(), Self::claude_code(), Self::open_code(), Self::omp(), Self::terminal()]
    }

    pub fn profile(id: &str) -> Option<AgentProfile> {
        Self::all().into_iter().find(|p| p.id == id)
    }
}

fn default_shell() -> (String, Vec<String>) {
    if cfg!(windows) {
        ("powershell.exe".into(), vec![])
    } else {
        let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into());
        (shell, vec!["--login".into()])
    }
}

/// Process-wide registry of agent profiles: the built-ins overlaid with whatever
/// `settings.json` declares. Every lookup goes through here, so a user-defined agent behaves
/// exactly like a built-in one (pane headers, launcher menus, notifications, restore).
pub struct AgentCatalog {
    profiles: RwLock<Vec<AgentProfile>>,
}

impl AgentCatalog {
    pub fn new(profiles: Vec<AgentProfile>) -> Self {
        Self { profiles: RwLock::new(profiles) }
    }

    /// The shared catalog, seeded with [`DefaultAgents::all`].
    pub fn shared() -> &'static AgentCatalog {
        static SHARED: LazyLock<AgentCatalog> = LazyLock::new(|| AgentCatalog::new(DefaultAgents::all()));
        &SHARED
    }

    pub fn all(&self) -> Vec<AgentProfile> {
        self.profiles.read().unwrap().clone()
    }

    pub fn profile(&self, id: &str) -> Option<AgentProfile> {
        self.profiles.read().unwrap().iter().find(|p| p.id == id).cloned()
    }

    pub fn replace_all(&self, profiles: Vec<AgentProfile>) {
        *self.profiles.write().unwrap() = profiles;
    }
}

/// Runtime status of an agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentStatus {
    Idle,
    Starting,
    Running,
    Waiting,
    Error,
    Stopped,
}

impl AgentStatus {
    pub fn display_label(self) -> &'static str {
        match self {
            Self::Idle => "READY",
            Self::Starting => "STARTING",
            Self::Running => "WORKING",
            Self::Waiting => "NEEDS INPUT",
            Self::Error => "ERROR",
            Self::Stopped => "STOPPED",
        }
    }
}

/// What an agent waiting on a person waits for. All three show as needing input; an
/// automation run tells a finished turn, which completes the run, from a prompt that blocks
/// the agent until someone answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AgentWaitingReason {
    /// The turn is done and the reply is in.
    #[serde(rename = "turn")]
    TurnEnded,
    /// A tool call waits for approval.
    #[serde(rename = "approval")]
    Approval,
    /// The agent asked something mid-turn and waits for the answer.
    #[serde(rename = "question")]
    Question,
}

impl AgentWaitingReason {
    /// Whether the agent can't go on until someone answers.
    pub fn blocks(self) -> bool {
        self != Self::TurnEnded
    }
}

/// What Soprano adds to an agent CLI's command line when it starts the agent for someone who
/// isn't there (automation runs).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgentLaunch {
    pub prompt: String,
    pub model: Option<String>,
    /// Skip the CLI's approval prompts: nobody is there to answer them.
    pub skips_approvals: bool,
    /// OpenCode 2 only: start a private server (`--standalone`), the only kind that reads the
    /// run's model from the pane. OpenCode 1.x rejects the flag.
    pub starts_private_server: bool,
    /// OpenCode agents the model is pinned on: OpenCode 2 lets an agent's own model win over
    /// the top-level one.
    pub model_agents: Vec<String>,
}

/// The agent's own conversation identity, independent of Soprano's pane and session ids.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentConversation {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// The file the agent writes this conversation to, as its hooks report it: JSON Lines, or
    /// OpenCode's SQLite database. Optional so workspaces saved before it existed still open.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
}

impl AgentConversation {
    pub fn new(id: impl Into<String>) -> Self {
        Self { id: id.into(), cwd: None, transcript_path: None }
    }

    pub fn supports(profile_id: &str) -> bool {
        matches!(profile_id, "codex" | "claude-code" | "opencode" | "omp")
    }

    pub fn valid_id(value: &str) -> bool {
        !value.is_empty()
            && !value.starts_with('-')
            && value.len() <= 256
            && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    }

    /// The conversation a lifecycle-hook payload names. Codex notify uses `thread-id`,
    /// lifecycle hooks `session_id`, OpenCode's plugin `sessionID`; a generic event id is
    /// never used.
    pub fn from_payload(payload: &str) -> Option<Self> {
        let object: serde_json::Map<String, serde_json::Value> = serde_json::from_str(payload).ok()?;
        let id = ["session_id", "thread-id", "thread_id", "sessionID"]
            .iter()
            .filter_map(|k| object.get(*k).and_then(|v| v.as_str()))
            .find(|v| Self::valid_id(v))?
            .to_owned();
        let cwd = object.get("cwd").and_then(|v| v.as_str()).filter(|s| s.starts_with('/')).map(str::to_owned);
        let transcript_path = object
            .get("transcript_path")
            .and_then(|v| v.as_str())
            .filter(|p| p.starts_with('/') && (p.ends_with(".jsonl") || p.ends_with(".db")))
            .map(str::to_owned);
        Some(Self { id, cwd, transcript_path })
    }

    /// Replaces launch-time conversation selectors so `--continue`/`--last` cannot send two
    /// panes in the same directory to the same conversation.
    pub fn resume_arguments(&self, profile_id: &str, arguments: &[String]) -> Vec<String> {
        let (valued, switches): (&[&str], &[&str]) = match profile_id {
            "codex" => (&["resume", "fork"], &["--last", "--all", "--include-non-interactive"]),
            "claude-code" => (&["--resume", "-r", "--session-id"], &["--continue", "-c", "--fork-session"]),
            "opencode" => (&["--session", "-s"], &["--continue", "-c", "--fork"]),
            "omp" => (&["--resume", "-r"], &["--continue", "-c"]),
            _ => return arguments.to_vec(),
        };
        let valued: HashSet<&str> = valued.iter().copied().collect();
        let switches: HashSet<&str> = switches.iter().copied().collect();

        let mut remaining = Vec::new();
        let mut index = 0;
        while index < arguments.len() {
            let argument = arguments[index].as_str();
            if valued.contains(argument) {
                index += 1;
                if index < arguments.len() && !arguments[index].starts_with('-') {
                    index += 1;
                }
            } else if switches.contains(argument) || valued.iter().any(|v| argument.starts_with(&format!("{v}="))) {
                index += 1;
            } else {
                remaining.push(arguments[index].clone());
                index += 1;
            }
        }
        let head: [&str; 2] = match profile_id {
            "codex" => ["resume", &self.id],
            "claude-code" => ["--resume", &self.id],
            "opencode" => ["--session", &self.id],
            "omp" => ["--resume", &self.id],
            _ => return remaining,
        };
        head.iter().map(|s| s.to_string()).chain(remaining).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_and_unrelated_event_ids_cannot_become_conversation_selectors() {
        assert!(AgentConversation::from_payload(r#"{"id":"abc"}"#).is_none());
        assert!(AgentConversation::from_payload(r#"{"session_id":"--continue"}"#).is_none());
        assert!(AgentConversation::from_payload(r#"{"session_id":"a b"}"#).is_none());
        let c = AgentConversation::from_payload(r#"{"session_id":"bad id","thread-id":"good-1"}"#).unwrap();
        assert_eq!(c.id, "good-1");
    }

    #[test]
    fn transcript_paths_must_be_absolute_json_lines_files_or_opencodes_database() {
        let parse = |path: &str| {
            AgentConversation::from_payload(&format!(r#"{{"session_id":"s1","transcript_path":"{path}"}}"#))
                .unwrap()
                .transcript_path
        };
        assert_eq!(parse("/tmp/a.jsonl").as_deref(), Some("/tmp/a.jsonl"));
        assert_eq!(parse("/tmp/opencode.db").as_deref(), Some("/tmp/opencode.db"));
        assert_eq!(parse("tmp/a.jsonl"), None);
        assert_eq!(parse("/tmp/a.json"), None);
    }

    #[test]
    fn resume_commands_target_the_saved_id_and_keep_other_options() {
        let c = AgentConversation::new("abc");
        let args: Vec<String> = ["--continue", "--model", "opus", "--resume", "old"].map(String::from).to_vec();
        assert_eq!(c.resume_arguments("claude-code", &args), ["--resume", "abc", "--model", "opus"]);
        let args: Vec<String> = ["resume", "--last", "-m", "o3"].map(String::from).to_vec();
        assert_eq!(c.resume_arguments("codex", &args), ["resume", "abc", "-m", "o3"]);
        let args: Vec<String> = ["--session=old", "-c"].map(String::from).to_vec();
        assert_eq!(c.resume_arguments("opencode", &args), ["--session", "abc"]);
        assert_eq!(c.resume_arguments("aider", &["--x".into()]), ["--x"]);
    }

    #[test]
    fn statuses_and_waiting_reasons_keep_their_swift_raw_values() {
        assert_eq!(serde_json::to_string(&AgentStatus::Running).unwrap(), "\"running\"");
        assert_eq!(serde_json::to_string(&AgentWaitingReason::TurnEnded).unwrap(), "\"turn\"");
        assert!(!AgentWaitingReason::TurnEnded.blocks());
        assert!(AgentWaitingReason::Approval.blocks());
    }

    #[test]
    fn the_catalog_resolves_replaced_profiles() {
        let catalog = AgentCatalog::new(DefaultAgents::all());
        assert_eq!(catalog.profile("claude-code").unwrap().command, "claude");
        catalog.replace_all(vec![DefaultAgents::omp()]);
        assert!(catalog.profile("codex").is_none());
        assert_eq!(catalog.all().len(), 1);
    }
}
