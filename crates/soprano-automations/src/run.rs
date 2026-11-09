//! One time an automation ran, or was due and did not (`Automations/AutomationRun.swift`).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use soprano_types::AgentConversation;
use soprano_types::TerminalTarget;

/// What started a run.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunTrigger {
    Scheduled,
    Manual,
}

/// Where a run is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunStatus {
    /// Its precheck, worktree, or terminal is being prepared.
    Starting,
    Running,
    /// The agent stopped mid-turn for an approval or an answer.
    NeedsInput,
    Completed,
    Failed,
    /// Due, but not started: the precheck said no, it was too late, its folder was gone, or
    /// the previous run was still working.
    Skipped,
}

impl RunStatus {
    pub fn is_final(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Skipped)
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Starting => "Starting",
            Self::Running => "Running",
            Self::NeedsInput => "Needs input",
            Self::Completed => "Done",
            Self::Failed => "Failed",
            Self::Skipped => "Skipped",
        }
    }
}

/// The git worktree a run worked in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunWorktree {
    pub path: String,
    pub branch: String,
    pub repository: String,
    pub base_commit: String,
    /// True once Soprano removed it because the run left nothing in it.
    #[serde(default)]
    pub removed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomationRun {
    pub id: String,
    pub automation_id: String,
    /// 1 for an automation's first run, counting up.
    pub number: i64,
    pub trigger: RunTrigger,
    /// The schedule time a scheduled run was for.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "iso8601::option")]
    pub scheduled_for: Option<DateTime<Utc>>,
    #[serde(with = "iso8601")]
    pub started_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "iso8601::option")]
    pub finished_at: Option<DateTime<Utc>>,
    pub status: RunStatus,
    /// Why it was skipped or failed, or what the agent waits for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// The agent's final reply, Markdown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    pub profile_id: String,
    /// Where the agent worked.
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<RunWorktree>,
    /// The agent's conversation, so a closed run can be resumed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<AgentConversation>,
    /// The run's tab while it is open in this Soprano.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab_id: Option<String>,
    /// Whether someone looked at the run's tab; an unseen run that finished closes its window.
    #[serde(default)]
    pub viewed: bool,
    /// Set when the agent was seen working, so a later wait ends the turn.
    #[serde(default)]
    pub saw_work: bool,
}

impl AutomationRun {
    /// Longest final reply kept with a run.
    pub const OUTPUT_LIMIT: usize = 64 * 1024;

    /// A run with nothing recorded yet beyond what started it.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        automation_id: impl Into<String>,
        number: i64,
        trigger: RunTrigger,
        started_at: DateTime<Utc>,
        status: RunStatus,
        profile_id: impl Into<String>,
        folder: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            automation_id: automation_id.into(),
            number,
            trigger,
            scheduled_for: None,
            started_at,
            finished_at: None,
            status,
            message: None,
            output: None,
            profile_id: profile_id.into(),
            folder: folder.into(),
            worktree: None,
            conversation: None,
            pane_id: None,
            tab_id: None,
            viewed: false,
            saw_work: false,
        }
    }

    pub fn target(&self) -> Option<TerminalTarget> {
        Some(TerminalTarget::new(self.pane_id.clone()?, self.tab_id.clone()?))
    }

    pub fn duration(&self) -> Option<chrono::Duration> {
        self.finished_at.map(|finished| finished - self.started_at)
    }

    /// `text` trimmed, `None` when empty, cut to [`Self::OUTPUT_LIMIT`] bytes on a character
    /// boundary with an ellipsis when longer.
    pub fn trimmed_output(text: Option<&str>) -> Option<String> {
        let text = text?.trim();
        if text.is_empty() {
            return None;
        }
        if text.len() <= Self::OUTPUT_LIMIT {
            return Some(text.to_owned());
        }
        let mut end = Self::OUTPUT_LIMIT;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        Some(format!("{}\n\n…", &text[..end]))
    }
}

/// ISO 8601 in UTC to the second (`2026-10-29T08:00:00Z`), as Foundation's `.iso8601` strategy
/// writes it, so the Swift app's `automations.json` reads back and the reverse.
pub(crate) mod iso8601 {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn format(date: &DateTime<Utc>) -> String {
        date.to_rfc3339_opts(SecondsFormat::Secs, true)
    }

    pub fn parse(text: &str) -> Option<DateTime<Utc>> {
        DateTime::parse_from_rfc3339(text).ok().map(|date| date.with_timezone(&Utc))
    }

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format(date))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(deserializer)?;
        parse(&text).ok_or_else(|| serde::de::Error::custom(format!("not an ISO 8601 date: {text}")))
    }

    pub mod option {
        use chrono::{DateTime, Utc};
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            date: &Option<DateTime<Utc>>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match date {
                Some(date) => super::serialize(date, serializer),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<DateTime<Utc>>, D::Error> {
            match Option::<String>::deserialize(deserializer)? {
                Some(text) => super::parse(&text)
                    .map(Some)
                    .ok_or_else(|| serde::de::Error::custom(format!("not an ISO 8601 date: {text}"))),
                None => Ok(None),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_reply_is_cut_on_a_character_boundary_with_an_ellipsis() {
        let text = "é".repeat(AutomationRun::OUTPUT_LIMIT);
        let trimmed = AutomationRun::trimmed_output(Some(&text)).expect("output");
        assert!(trimmed.ends_with("\n\n…"));
        assert_eq!(trimmed.len(), AutomationRun::OUTPUT_LIMIT + "\n\n…".len());
        assert_eq!(AutomationRun::trimmed_output(Some("  \n ")), None);
        assert_eq!(AutomationRun::trimmed_output(Some(" Done.\n")).as_deref(), Some("Done."));
    }

    #[test]
    fn a_run_reads_the_swift_apps_json() {
        let json = r#"{"automationId":"audit","finishedAt":"2026-10-29T08:05:00Z","folder":"/tmp",
            "id":"A1","number":3,"profileId":"omp","sawWork":true,"startedAt":"2026-10-29T08:00:00Z",
            "status":"needsInput","trigger":"scheduled","viewed":false,
            "worktree":{"baseCommit":"abc","branch":"automation/audit-20261029-0900","path":"/w","removed":false,"repository":"/r"}}"#;
        let run: AutomationRun = serde_json::from_str(json).expect("decodes");
        assert_eq!(run.status, RunStatus::NeedsInput);
        assert_eq!(run.duration(), Some(chrono::Duration::minutes(5)));
        let encoded = serde_json::to_value(&run).expect("encodes");
        assert_eq!(encoded["startedAt"], "2026-10-29T08:00:00Z");
        assert_eq!(encoded["worktree"]["baseCommit"], "abc");
        assert!(encoded.get("paneId").is_none());
    }
}
