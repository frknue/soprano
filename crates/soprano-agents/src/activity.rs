//! What an agent is doing right now, in one line (the logic of `AgentTimelineActivity.swift`;
//! its AppKit attributed-string rendering is left to the UI).

use soprano_types::AgentStatus;

use crate::timeline::{AgentTimeline, Date, TimelineItemKind, ToolCallState, first_line};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivityTone {
    Working,
    Waiting,
    Idle,
    Failed,
}

/// What an agent is doing right now, in one line, for its dashboard row and the activity line
/// above the detail view's reply field: an optional call-state glyph, a lead (tool name or short
/// phrase), the tool's subject in mono, a plain detail and the time it has been going.
///
/// The UI renders it as: glyph + " " (left out when `compact`), the title in the title font,
/// then ` · ` + code in the code font, ` · ` + detail, and ` · ` + elapsed with tabular digits
/// (left out when `compact`), on one line truncated at the tail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentTimelineActivity {
    /// ▶ ✓ ✗ ⊘ for a tool call.
    pub glyph: Option<String>,
    /// A tool name or a short phrase: "Thinking", "Asks", "Replied".
    pub title: String,
    /// The tool's subject: a command, path or pattern.
    pub code: Option<String>,
    /// The first line of a reply.
    pub detail: Option<String>,
    /// How long it has been going: `38s`.
    pub elapsed: Option<String>,
    pub tone: ActivityTone,
}

impl AgentTimelineActivity {
    pub fn new(title: impl Into<String>, tone: ActivityTone) -> Self {
        Self { glyph: None, title: title.into(), code: None, detail: None, elapsed: None, tone }
    }

    /// The whole line as plain text: `▶ Bash · swift test · 38s`.
    pub fn text(&self) -> String {
        let lead = match &self.glyph {
            Some(glyph) => format!("{glyph} {}", self.title),
            None => self.title.clone(),
        };
        let mut parts = vec![lead];
        parts.extend([&self.code, &self.detail, &self.elapsed].into_iter().flatten().cloned());
        parts.join(" · ")
    }

    pub fn current(timeline: Option<&AgentTimeline>, status: AgentStatus, now: Date) -> Option<Self> {
        let timeline = timeline?;
        let last = timeline.items.last()?;
        let last_prompt = timeline.items.iter().rposition(|i| i.is_prompt());
        let running = timeline
            .items
            .iter()
            .enumerate()
            .rev()
            .find(|(index, item)| {
                last_prompt.is_none_or(|p| *index > p)
                    && item.tool_call().is_some_and(|c| c.state == ToolCallState::Running)
            })
            .map(|(_, item)| item);

        match status {
            AgentStatus::Running | AgentStatus::Starting => {
                if let Some(running) = running
                    && let Some(call) = running.tool_call()
                {
                    return Some(Self {
                        glyph: Some(glyph(ToolCallState::Running).into()),
                        code: subject(&call.summary),
                        elapsed: since(running.timestamp, now),
                        ..Self::new(call.name.clone(), ActivityTone::Working)
                    });
                }
                Some(match &last.kind {
                    TimelineItemKind::Prompt(_) | TimelineItemKind::Thinking(_) => Self {
                        elapsed: since(last.timestamp, now),
                        ..Self::new("Thinking", ActivityTone::Working)
                    },
                    TimelineItemKind::Reply(_) => Self {
                        elapsed: since(last.timestamp, now),
                        ..Self::new("Writing", ActivityTone::Working)
                    },
                    TimelineItemKind::Tool(call) => Self {
                        glyph: Some(glyph(call.state).into()),
                        code: subject(&call.summary),
                        ..Self::new(call.name.clone(), ActivityTone::Working)
                    },
                    TimelineItemKind::Notice { text, is_error } => Self::new(
                        first_line(text),
                        if *is_error { ActivityTone::Failed } else { ActivityTone::Working },
                    ),
                })
            }
            AgentStatus::Waiting => {
                if let Some(call) = running.and_then(|r| r.tool_call()) {
                    return Some(Self {
                        code: subject(&call.summary),
                        ..Self::new(format!("Approve {}?", call.name), ActivityTone::Waiting)
                    });
                }
                if let Some(reply) = last_reply(timeline) {
                    return Some(Self {
                        detail: Some(first_line(reply)),
                        ..Self::new("Asks", ActivityTone::Waiting)
                    });
                }
                Some(Self::new("Waiting for input", ActivityTone::Waiting))
            }
            AgentStatus::Error => {
                let notice = timeline.items.iter().rev().find_map(|item| match &item.kind {
                    TimelineItemKind::Notice { text, is_error: true } => Some(text),
                    _ => None,
                });
                Some(match notice {
                    Some(text) => Self::new(first_line(text), ActivityTone::Failed),
                    None => Self::new("Stopped with an error", ActivityTone::Failed),
                })
            }
            AgentStatus::Idle | AgentStatus::Stopped => last_reply(timeline).map(|reply| Self {
                detail: Some(first_line(reply)),
                ..Self::new("Replied", ActivityTone::Idle)
            }),
        }
    }
}

pub fn glyph(state: ToolCallState) -> &'static str {
    match state {
        ToolCallState::Running => "▶",
        ToolCallState::Succeeded => "✓",
        ToolCallState::Failed => "✗",
        ToolCallState::Interrupted => "⊘",
    }
}

/// `2.4s`, `38s`, `3m 05s`, `1h 02m`.
pub fn activity_duration(seconds: f64) -> String {
    if seconds < 10.0 {
        return format!("{seconds:.1}s");
    }
    let whole = seconds as i64;
    if whole < 60 {
        return format!("{whole}s");
    }
    if whole < 3_600 {
        return format!("{}m {:02}s", whole / 60, whole % 60);
    }
    format!("{}h {:02}m", whole / 3_600, (whole % 3_600) / 60)
}

fn subject(summary: &str) -> Option<String> {
    (!summary.is_empty()).then(|| summary.to_owned())
}

fn last_reply(timeline: &AgentTimeline) -> Option<&str> {
    for item in timeline.items.iter().rev() {
        if item.is_prompt() {
            return None;
        }
        if let TimelineItemKind::Reply(text) = &item.kind {
            return Some(text);
        }
    }
    None
}

fn since(start: Option<Date>, now: Date) -> Option<String> {
    let start = start?;
    let seconds = (now - start).num_microseconds().unwrap_or(0) as f64 / 1_000_000.0;
    Some(activity_duration(seconds.max(0.0)))
}
