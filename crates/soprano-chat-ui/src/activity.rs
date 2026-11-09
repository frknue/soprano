//! What an agent is doing right now, in one line (`AgentTimelineActivity.attributed`): the
//! dashboard rows and the activity line above the detail view's reply field draw
//! [`soprano_agents::AgentTimelineActivity`] with [`ActivityLine`].

use std::ops::Range;
use std::sync::Arc;

use gpui::{
    App, Font, FontFeatures, FontWeight, Hsla, IntoElement, ParentElement, RenderOnce, SharedString, Styled,
    StyledText, TextRun, Window, div,
};
use soprano_agents::AgentTimelineActivity;
use soprano_ui::ActiveSopranoTheme;
use soprano_ui::fonts::{MONO_FONT_FAMILY, UI_FONT_FAMILY};

/// Which part of the line a range shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivityPart {
    Glyph,
    Title,
    Separator,
    Code,
    Detail,
    Elapsed,
}

/// The line's text and the byte range of each part: glyph + " " (left out when `compact`), the
/// title, then ` · ` + code, ` · ` + detail and ` · ` + elapsed (left out when `compact`).
pub fn activity_parts(
    activity: &AgentTimelineActivity,
    compact: bool,
) -> (String, Vec<(Range<usize>, ActivityPart)>) {
    let mut text = String::new();
    let mut parts = Vec::new();
    let mut push = |text: &mut String, piece: &str, part: ActivityPart| {
        let start = text.len();
        text.push_str(piece);
        parts.push((start..text.len(), part));
    };
    if let Some(glyph) = activity.glyph.as_deref().filter(|_| !compact) {
        push(&mut text, &format!("{glyph} "), ActivityPart::Glyph);
    }
    push(&mut text, &activity.title, ActivityPart::Title);
    let elapsed = activity.elapsed.as_deref().filter(|_| !compact);
    for (piece, part) in [
        (activity.code.as_deref(), ActivityPart::Code),
        (activity.detail.as_deref(), ActivityPart::Detail),
        (elapsed, ActivityPart::Elapsed),
    ] {
        if let Some(piece) = piece {
            push(&mut text, " · ", ActivityPart::Separator);
            push(&mut text, piece, part);
        }
    }
    (text, parts)
}

/// The activity in UI type, on one line truncated at the tail: the lead in `title_weight`, the
/// subject in mono and `code_color`, the elapsed time with tabular digits.
#[derive(IntoElement)]
pub struct ActivityLine {
    activity: AgentTimelineActivity,
    compact: bool,
    size: f32,
    title_weight: FontWeight,
    color: Option<Hsla>,
    code_color: Option<Hsla>,
}

impl ActivityLine {
    /// The detail view's line: 13 px with the lead medium.
    pub fn new(activity: AgentTimelineActivity) -> Self {
        Self {
            activity,
            compact: false,
            size: 13.0,
            title_weight: FontWeight::MEDIUM,
            color: None,
            code_color: None,
        }
    }

    /// Agent rows show their own status and time: no glyph and no elapsed time.
    pub fn compact(mut self, compact: bool) -> Self {
        self.compact = compact;
        self
    }

    /// Text size in designed pixels and the lead's weight.
    pub fn fonts(mut self, size: f32, title_weight: FontWeight) -> Self {
        self.size = size;
        self.title_weight = title_weight;
        self
    }

    pub fn color(mut self, color: Hsla) -> Self {
        self.color = Some(color);
        self
    }

    pub fn code_color(mut self, color: Hsla) -> Self {
        self.code_color = Some(color);
        self
    }
}

impl RenderOnce for ActivityLine {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.soprano_theme();
        let color = self.color.unwrap_or(t.foreground);
        let code_color = self.code_color.unwrap_or(color);
        let (text, parts) = activity_parts(&self.activity, self.compact);
        let ui = gpui::font(UI_FONT_FAMILY);
        let runs = parts
            .into_iter()
            .map(|(range, part)| {
                let (font, run_color) = match part {
                    ActivityPart::Title => (Font { weight: self.title_weight, ..ui.clone() }, color),
                    ActivityPart::Code => (gpui::font(MONO_FONT_FAMILY), code_color),
                    ActivityPart::Elapsed => (
                        Font { features: FontFeatures(Arc::new(vec![("tnum".into(), 1)])), ..ui.clone() },
                        color,
                    ),
                    ActivityPart::Glyph | ActivityPart::Separator | ActivityPart::Detail => {
                        (ui.clone(), color)
                    }
                };
                TextRun {
                    len: range.len(),
                    font,
                    color: run_color,
                    background_color: None,
                    underline: None,
                    strikethrough: None,
                }
            })
            .collect();
        div()
            .min_w_0()
            .font_family(UI_FONT_FAMILY)
            .text_size(t.z(self.size))
            .text_color(color)
            .truncate()
            .child(StyledText::new(SharedString::from(text)).with_runs(runs))
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use soprano_agents::{ActivityTone, AgentTimeline, AgentTimelineItem, AgentToolCall, TimelineItemKind};
    use soprano_types::AgentStatus;

    use super::*;

    #[test]
    fn a_running_call_is_the_activity_with_its_command_and_elapsed_time() {
        let start = Utc.timestamp_opt(1_000, 0).single().expect("date");
        let timeline = AgentTimeline::new(vec![
            AgentTimelineItem::new("p1", None, TimelineItemKind::Prompt("Test it".into())),
            AgentTimelineItem::new(
                "c1",
                Some(start),
                TimelineItemKind::Tool(AgentToolCall::new("Bash", "swift test")),
            ),
        ]);
        let activity = AgentTimelineActivity::current(
            Some(&timeline),
            AgentStatus::Running,
            start + chrono::Duration::seconds(38),
        )
        .expect("activity");
        assert_eq!(activity.text(), "▶ Bash · swift test · 38s");
        assert_eq!(activity.tone, ActivityTone::Working);
        let (line, parts) = activity_parts(&activity, false);
        assert_eq!(line, activity.text());
        let part = |p: ActivityPart| parts.iter().find(|(_, part)| *part == p).map(|(r, _)| &line[r.clone()]);
        assert_eq!(part(ActivityPart::Title), Some("Bash"));
        assert_eq!(part(ActivityPart::Code), Some("swift test"));
        assert_eq!(part(ActivityPart::Elapsed), Some("38s"));
    }

    #[test]
    fn a_compact_line_leaves_out_the_glyph_and_the_elapsed_time() {
        let activity = AgentTimelineActivity {
            glyph: Some("▶".into()),
            code: Some("cargo test".into()),
            elapsed: Some("2.4s".into()),
            ..AgentTimelineActivity::new("Bash", ActivityTone::Working)
        };
        assert_eq!(activity_parts(&activity, true).0, "Bash · cargo test");
        let waiting = AgentTimelineActivity {
            detail: Some("I deployed it.".into()),
            ..AgentTimelineActivity::new("Asks", ActivityTone::Waiting)
        };
        assert_eq!(activity_parts(&waiting, true).0, "Asks · I deployed it.");
    }
}
