//! Remote machines: other computers reached over SSH whose sessions share the sidebar.

use serde::{Deserialize, Serialize};

/// One `machines` entry in `settings.json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    /// The name the sidebar shows and sessions refer to.
    pub name: String,
    /// What `ssh` connects to (`user@host`, or a `Host` from `~/.ssh/config`); the name when
    /// empty.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub destination: String,
    /// Extra `ssh` options placed before the destination (`-p 2222`, `-i ~/.ssh/key`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ssh_args: Vec<String>,
    /// Where new sessions on the machine start; the remote home folder when unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
}

impl Machine {
    pub fn new(name: impl Into<String>) -> Self {
        Self { name: name.into(), destination: String::new(), ssh_args: Vec::new(), directory: None }
    }

    /// The `ssh` destination.
    pub fn destination(&self) -> &str {
        if self.destination.is_empty() { &self.name } else { &self.destination }
    }

    /// A name a session can refer to and a command line can carry: non-empty, no whitespace
    /// or control characters, not starting with `-`.
    pub fn valid_name(name: &str) -> bool {
        !name.is_empty()
            && !name.starts_with('-')
            && !name.chars().any(|c| c.is_whitespace() || c.is_control())
    }
}
