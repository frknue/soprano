//! Why an agent wants the user, as its banner says it: a short status title over one line naming
//! the conversation, like Soprano Agents' thread alerts.

use soprano_types::AgentWaitingReason;

use crate::protocol::AgentEventState;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentAlert {
    Completed,
    Failed,
    Approval,
    Input,
}

impl AgentAlert {
    /// The alert an event stands for; `None` for states that never notify. A needs-input event
    /// that does not say why reads as a question.
    pub fn new(state: AgentEventState, reason: Option<AgentWaitingReason>) -> Option<Self> {
        match state {
            AgentEventState::Ready => Some(Self::Completed),
            AgentEventState::Error => Some(Self::Failed),
            AgentEventState::NeedsInput => Some(match reason {
                Some(AgentWaitingReason::TurnEnded) => Self::Completed,
                Some(AgentWaitingReason::Approval) => Self::Approval,
                Some(AgentWaitingReason::Question) | None => Self::Input,
            }),
            AgentEventState::Running | AgentEventState::Stopped => None,
        }
    }

    pub fn title(self, agent_name: &str) -> String {
        match self {
            Self::Completed => format!("{agent_name} finished"),
            Self::Failed => format!("{agent_name} failed"),
            Self::Approval => format!("{agent_name} needs approval"),
            Self::Input => format!("{agent_name} needs input"),
        }
    }

    /// The banner's one-line body: the tab title, which agents set to their conversation's name,
    /// without the spinner or status glyph in front of it. A tab still named after the agent says
    /// nothing the title doesn't, so the window, then the session, names it instead.
    pub fn body(
        agent_name: &str,
        tab_title: Option<&str>,
        window_title: Option<&str>,
        session_name: Option<&str>,
    ) -> String {
        let tab = tab_title.map(stripping_status_glyphs).filter(|tab| tab != agent_name);
        [tab.as_deref(), window_title, session_name]
            .into_iter()
            .flatten()
            .map(str::trim)
            .find(|candidate| !candidate.is_empty())
            .unwrap_or(agent_name)
            .to_string()
    }
}

/// Drops the leading spinner (Braille), dingbat, or symbol an agent puts in its terminal title,
/// such as Claude Code's `✳` or `⠐`.
pub fn stripping_status_glyphs(title: &str) -> String {
    title
        .trim_start_matches(|c: char| {
            let value = c as u32;
            c.is_whitespace()
                || (0x2190..=0x2BFF).contains(&value)
                || is_emoji_presentation(value)
                || value == 0xFE0F
        })
        .trim()
        .to_string()
}

/// Unicode `Emoji_Presentation` outside the U+2190…U+2BFF block the caller already drops.
fn is_emoji_presentation(value: u32) -> bool {
    matches!(
        value,
        0x231A..=0x231B
            | 0x23E9..=0x23EC
            | 0x23F0
            | 0x23F3
            | 0x1F004
            | 0x1F0CF
            | 0x1F18E
            | 0x1F191..=0x1F19A
            | 0x1F1E6..=0x1F1FF
            | 0x1F201
            | 0x1F21A
            | 0x1F22F
            | 0x1F232..=0x1F236
            | 0x1F238..=0x1F23A
            | 0x1F250..=0x1F251
            | 0x1F300..=0x1F320
            | 0x1F32D..=0x1F335
            | 0x1F337..=0x1F37C
            | 0x1F37E..=0x1F393
            | 0x1F3A0..=0x1F3CA
            | 0x1F3CF..=0x1F3D3
            | 0x1F3E0..=0x1F3F0
            | 0x1F3F4
            | 0x1F3F8..=0x1F43E
            | 0x1F440
            | 0x1F442..=0x1F4FC
            | 0x1F4FF..=0x1F53D
            | 0x1F54B..=0x1F54E
            | 0x1F550..=0x1F567
            | 0x1F57A
            | 0x1F595..=0x1F596
            | 0x1F5A4
            | 0x1F5FB..=0x1F64F
            | 0x1F680..=0x1F6C5
            | 0x1F6CC
            | 0x1F6D0..=0x1F6D2
            | 0x1F6D5..=0x1F6D7
            | 0x1F6DC..=0x1F6DF
            | 0x1F6EB..=0x1F6EC
            | 0x1F6F4..=0x1F6FC
            | 0x1F7E0..=0x1F7EB
            | 0x1F7F0
            | 0x1F90C..=0x1F93A
            | 0x1F93C..=0x1F945
            | 0x1F947..=0x1F9FF
            | 0x1FA70..=0x1FAFF
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_waiting_reason_gets_its_own_short_status_title() {
        assert_eq!(
            AgentAlert::new(AgentEventState::NeedsInput, Some(AgentWaitingReason::TurnEnded))
                .map(|a| a.title("Claude Code")),
            Some("Claude Code finished".into())
        );
        assert_eq!(
            AgentAlert::new(AgentEventState::NeedsInput, Some(AgentWaitingReason::Approval))
                .map(|a| a.title("Codex")),
            Some("Codex needs approval".into())
        );
        assert_eq!(
            AgentAlert::new(AgentEventState::NeedsInput, Some(AgentWaitingReason::Question))
                .map(|a| a.title("omp")),
            Some("omp needs input".into())
        );
        assert_eq!(
            AgentAlert::new(AgentEventState::Error, None).map(|a| a.title("OpenCode")),
            Some("OpenCode failed".into())
        );
        assert_eq!(AgentAlert::new(AgentEventState::Ready, None), Some(AgentAlert::Completed));
    }

    #[test]
    fn a_needs_input_event_that_does_not_say_why_reads_as_a_question() {
        assert_eq!(AgentAlert::new(AgentEventState::NeedsInput, None), Some(AgentAlert::Input));
    }

    #[test]
    fn running_and_stopped_events_never_make_a_banner() {
        assert_eq!(AgentAlert::new(AgentEventState::Running, None), None);
        assert_eq!(AgentAlert::new(AgentEventState::Stopped, None), None);
    }

    #[test]
    fn the_body_is_the_tab_title_without_the_agents_spinner_or_status_glyph() {
        assert_eq!(
            AgentAlert::body(
                "Claude Code",
                Some("✳ Fix notification layout"),
                Some("Terminal 1"),
                Some("Default")
            ),
            "Fix notification layout"
        );
        assert_eq!(
            AgentAlert::body("Claude Code", Some("⠐ Refactor sidebar"), Some("Terminal 1"), Some("Default")),
            "Refactor sidebar"
        );
        assert_eq!(stripping_status_glyphs("~/git/soprano"), "~/git/soprano");
    }

    #[test]
    fn a_tab_still_named_after_the_agent_falls_back_to_the_window_then_the_session() {
        assert_eq!(AgentAlert::body("Codex", Some("Codex"), Some("Build"), Some("Default")), "Build");
        assert_eq!(AgentAlert::body("Codex", Some("✳"), Some(""), Some("Default")), "Default");
        assert_eq!(AgentAlert::body("Codex", None, None, None), "Codex");
    }
}
