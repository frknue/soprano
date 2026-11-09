//! Agent status in the chrome: Soprano's status pill ("Working 2m", Approval, Input, Failed,
//! Done, Starting, Stopped, else a relative time — `Views/Shell/ShellKit.swift`), the tab badges
//! (`StatusCountBadgeView.swift`), and Herdr's status glyphs (spinner, needs-you pill, done
//! dot, idle ring — HERDR-UI.md §5.3.1).

use std::collections::HashMap;
use std::f32::consts::TAU;
use std::time::{Duration, SystemTime};

use gpui::{
    Animation, AnimationExt as _, App, FontWeight, Global, Hsla, IntoElement, ParentElement, RenderOnce,
    SharedString, Styled, Transformation, Window, div, prelude::*, radians, svg,
};
use soprano_types::{AgentStatus, AgentWaitingReason};

use crate::fonts::{self, size};
use crate::icons::{IconName, icon};
use crate::motion::{SPINNER_REVOLUTION, SPINNER_STEP};
use crate::theme::{ActiveSopranoTheme, StatusTone};

/// Live working duration: `Ns` under a minute, `Nm` under an hour, else `Hh Mm`.
pub fn compact_duration(interval: Duration) -> String {
    let seconds = interval.as_secs();
    if seconds < 60 {
        return format!("{seconds}s");
    }
    if seconds < 3600 {
        return format!("{}m", seconds / 60);
    }
    format!("{}h {}m", seconds / 3600, (seconds % 3600) / 60)
}

/// Relative time: "now", "Nm", "Nh", "Nd".
pub fn relative_time(date: SystemTime, now: SystemTime) -> String {
    let seconds = match now.duration_since(date) {
        Ok(elapsed) => elapsed.as_secs(),
        Err(_) => 0,
    };
    if seconds < 60 {
        "now".into()
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h", seconds / 3600)
    } else {
        format!("{}d", seconds / 86_400)
    }
}

/// Soprano Agents' status pill: Working (live duration), Approval, Input, Failed, Done, and
/// Soprano's Starting, Running (a shell running a command) and Stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StatusPillSpec {
    pub label: &'static str,
    pub icon: IconName,
    pub tone: StatusTone,
    /// The live duration counts from here ("Working 12s").
    pub since: Option<SystemTime>,
}

impl StatusPillSpec {
    /// A shell running a command.
    pub const RUNNING: StatusPillSpec =
        StatusPillSpec { label: "Running", icon: IconName::Terminal, tone: StatusTone::Working, since: None };

    /// What a badge shows for agents that are all idle (or stopped).
    pub const READY: StatusPillSpec =
        StatusPillSpec { label: "Ready", icon: IconName::STATUS_DONE, tone: StatusTone::Muted, since: None };

    /// "Working 12s", "Approval".
    pub fn text(&self, now: SystemTime) -> String {
        match self.since {
            Some(since) => format!(
                "{} {}",
                self.label,
                compact_duration(now.duration_since(since).unwrap_or(Duration::ZERO))
            ),
            None => self.label.to_owned(),
        }
    }

    /// The pill for a status: a finished turn reads Done, an approval prompt Approval, a
    /// question (or a wait of unknown kind) Input; nil for an idle agent (rows show a
    /// relative time there).
    pub fn of(
        status: AgentStatus,
        waiting_reason: Option<AgentWaitingReason>,
        working_since: Option<SystemTime>,
    ) -> Option<Self> {
        let pill = |label, icon, tone, since| Some(Self { label, icon, tone, since });
        match status {
            AgentStatus::Running => {
                pill("Working", IconName::STATUS_WORKING, StatusTone::Working, working_since)
            }
            AgentStatus::Starting => pill("Starting", IconName::STATUS_WORKING, StatusTone::Working, None),
            AgentStatus::Waiting => match waiting_reason {
                Some(AgentWaitingReason::Approval) => {
                    pill("Approval", IconName::STATUS_APPROVAL, StatusTone::Approval, None)
                }
                Some(AgentWaitingReason::Question) | None => {
                    pill("Input", IconName::STATUS_INPUT, StatusTone::Input, None)
                }
                Some(AgentWaitingReason::TurnEnded) => {
                    pill("Done", IconName::STATUS_DONE, StatusTone::Done, None)
                }
            },
            AgentStatus::Error => pill("Failed", IconName::STATUS_FAILED, StatusTone::Failed, None),
            AgentStatus::Stopped => pill("Stopped", IconName::STATUS_STOPPED, StatusTone::Muted, None),
            AgentStatus::Idle => None,
        }
    }

    /// The pill for a pane's active tab: its agent's, else Running while a command runs in
    /// any of its tabs.
    pub fn for_pane(agent: Option<Option<StatusPillSpec>>, runs_command: bool) -> Option<Self> {
        match agent {
            Some(pill) => pill,
            None => runs_command.then_some(Self::RUNNING),
        }
    }
}

/// When each agent entered the status it shows, so pills can count a live "Working 2m".
/// Soprano's model has no status timestamp, so the chrome records the first moment it sees
/// one. Keep one per app (`cx.default_global::<StatusClock>()`).
#[derive(Debug, Default)]
pub struct StatusClock {
    entries: HashMap<String, (AgentStatus, SystemTime)>,
}

impl Global for StatusClock {}

impl StatusClock {
    /// When `agent_id` entered `status` (as far as the chrome saw). A fresh agent counts from
    /// `started_at`; any later change from `now`.
    pub fn since(
        &mut self,
        agent_id: &str,
        status: AgentStatus,
        started_at: Option<SystemTime>,
        now: SystemTime,
    ) -> SystemTime {
        let previous = self.entries.get(agent_id);
        if let Some((seen, since)) = previous
            && *seen == status
        {
            return *since;
        }
        let since =
            if previous.is_none() && status != AgentStatus::Idle { started_at.unwrap_or(now) } else { now };
        self.entries.insert(agent_id.to_owned(), (status, since));
        since
    }

    /// Forgets an agent that went away.
    pub fn forget(&mut self, agent_id: &str) {
        self.entries.remove(agent_id);
    }

    /// The pill for an agent, timing a Working pill with this clock.
    pub fn pill(
        &mut self,
        agent_id: &str,
        status: AgentStatus,
        waiting_reason: Option<AgentWaitingReason>,
        started_at: Option<SystemTime>,
        now: SystemTime,
    ) -> Option<StatusPillSpec> {
        let since = (status == AgentStatus::Running).then(|| self.since(agent_id, status, started_at, now));
        StatusPillSpec::of(status, waiting_reason, since)
    }
}

/// Most urgent first; a badge takes the first status any agent has.
pub const URGENCY_ORDER: [AgentStatus; 5] = [
    AgentStatus::Error,
    AgentStatus::Waiting,
    AgentStatus::Running,
    AgentStatus::Starting,
    AgentStatus::Idle,
];

/// An unboxed tab badge: the most urgent agent's pill symbol, or the Running symbol for
/// commands, and a count, both in the pill's tone. None at zero.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TabBadge {
    pub count: usize,
    pub pill: StatusPillSpec,
}

impl TabBadge {
    /// The agent badge for `agents` (status and waiting reason of each).
    pub fn agents(agents: &[(AgentStatus, Option<AgentWaitingReason>)]) -> Option<Self> {
        if agents.is_empty() {
            return None;
        }
        let urgent = URGENCY_ORDER.iter().find_map(|status| agents.iter().find(|(s, _)| s == status));
        let pill = urgent.and_then(|(status, reason)| StatusPillSpec::of(*status, *reason, None));
        Some(Self { count: agents.len(), pill: pill.unwrap_or(StatusPillSpec::READY) })
    }

    /// The running-commands badge.
    pub fn running_commands(count: usize) -> Option<Self> {
        (count > 0).then_some(Self { count, pill: StatusPillSpec::RUNNING })
    }
}

/// "2 agents: 1 working, 1 ready" for tooltips; None without agents.
pub fn agents_summary(statuses: &[AgentStatus]) -> Option<String> {
    if statuses.is_empty() {
        return None;
    }
    let noun = if statuses.len() == 1 { "agent" } else { "agents" };
    let counts: Vec<String> = URGENCY_ORDER
        .iter()
        .filter_map(|status| {
            let count = statuses.iter().filter(|s| *s == status).count();
            (count > 0).then(|| format!("{count} {}", status.display_label().to_lowercase()))
        })
        .collect();
    Some(format!("{} {noun}: {}", statuses.len(), counts.join(", ")))
}

/// "2 commands running" for tooltips; None when none is.
pub fn running_commands_summary(count: usize) -> Option<String> {
    match count {
        0 => None,
        1 => Some("1 command running".into()),
        n => Some(format!("{n} commands running")),
    }
}

/// A tab's tooltip: `title` ("Tab 2: Claude Code", "Window 1: Work"), then " — " and each
/// summary.
pub fn tab_tooltip(title: &str, agents: &[AgentStatus], running_commands: usize) -> String {
    let mut text = title.to_owned();
    for summary in [agents_summary(agents), running_commands_summary(running_commands)].into_iter().flatten()
    {
        text.push_str(" — ");
        text.push_str(&summary);
    }
    text
}

/// The status pill element: the tone's icon and label ("Working 2m") in 12 px medium, or a
/// muted relative time when there is no pill.
#[derive(IntoElement)]
pub struct StatusPill {
    pill: Option<StatusPillSpec>,
    relative_to: Option<SystemTime>,
    now: SystemTime,
}

impl StatusPill {
    pub fn new(pill: Option<StatusPillSpec>) -> Self {
        Self { pill, relative_to: None, now: SystemTime::now() }
    }

    /// With no pill, show the time since `date` instead.
    pub fn relative_to(mut self, date: Option<SystemTime>) -> Self {
        self.relative_to = date;
        self
    }

    /// The clock the text reads (defaults to now). Re-render once a second while it shows a
    /// live duration ([`StatusPill::has_live_time`]).
    pub fn now(mut self, now: SystemTime) -> Self {
        self.now = now;
        self
    }

    pub fn has_live_time(&self) -> bool {
        self.pill.is_some_and(|pill| pill.since.is_some())
            || (self.pill.is_none() && self.relative_to.is_some())
    }
}

impl RenderOnce for StatusPill {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let (text, color, weight, glyph) = match self.pill {
            Some(pill) => (pill.text(self.now), theme.tone(pill.tone), FontWeight::MEDIUM, Some(pill.icon)),
            None => (
                self.relative_to.map(|date| relative_time(date, self.now)).unwrap_or_default(),
                theme.muted,
                FontWeight::NORMAL,
                None,
            ),
        };
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(4.))
            .h(theme.z(20.))
            .text_size(theme.z(size::META))
            .font_weight(weight)
            .text_color(color)
            .whitespace_nowrap()
            .when_some(glyph, |row, glyph| row.child(icon(glyph).size(12.5).color(color)))
            .child(SharedString::from(text))
    }
}

/// An unboxed tab badge element: pill symbol (12 px) and count in the tone, 16 px tall.
#[derive(IntoElement)]
pub struct TabBadgeView {
    badge: TabBadge,
}

impl TabBadgeView {
    pub fn new(badge: TabBadge) -> Self {
        Self { badge }
    }
}

impl RenderOnce for TabBadgeView {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let color = theme.tone(self.badge.pill.tone);
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(3.))
            .h(theme.z(16.))
            .text_size(theme.z(size::META))
            .font_weight(FontWeight::MEDIUM)
            .text_color(color)
            .child(icon(self.badge.pill.icon).size(12.).color(color))
            .child(SharedString::from(self.badge.count.to_string()))
    }
}

/// Herdr's status glyphs, shared by rows, tabs, the pane header and the picker.
#[derive(Clone, Debug, PartialEq)]
pub enum GlyphKind {
    /// 12 px ring at 24 % plus a 90° arc, 900 ms per turn stepped every 100 ms.
    Spinner,
    /// "Needs you"-style pill: h18 px6 r5, the color at 15 % behind 10.5 semibold text.
    Pill(SharedString),
    /// 14×14 r4 square with "!" (compact needs-you).
    Alert,
    /// 7 px dot.
    Dot,
    /// 6 px dot (tab row).
    SmallDot,
    /// 7 px ring, 1.5 px border.
    Ring,
}

/// A status glyph in a color. [`StatusGlyph::for_pill`] picks Herdr's glyph for a Soprano
/// pill: Working/Starting/Running spin, Approval/Input show "Needs you", Done a dot, Failed
/// the alert square, Stopped a ring.
#[derive(IntoElement)]
pub struct StatusGlyph {
    kind: GlyphKind,
    color: Option<Hsla>,
    tone: Option<StatusTone>,
}

impl StatusGlyph {
    pub fn new(kind: GlyphKind) -> Self {
        Self { kind, color: None, tone: None }
    }

    pub fn spinner() -> Self {
        Self::new(GlyphKind::Spinner)
    }

    pub fn needs_you() -> Self {
        Self::new(GlyphKind::Pill("Needs you".into()))
    }

    pub fn dot() -> Self {
        Self::new(GlyphKind::Dot)
    }

    pub fn ring() -> Self {
        Self::new(GlyphKind::Ring)
    }

    /// The glyph and tone color for a pill; `compact` uses the small forms (tab rows).
    pub fn for_pill(pill: &StatusPillSpec, compact: bool) -> Self {
        let kind = match (pill.tone, compact) {
            (StatusTone::Working, _) => GlyphKind::Spinner,
            (StatusTone::Approval | StatusTone::Input, false) => GlyphKind::Pill("Needs you".into()),
            (StatusTone::Approval | StatusTone::Input, true) => GlyphKind::Alert,
            (StatusTone::Failed, _) => GlyphKind::Alert,
            (StatusTone::Done, false) => GlyphKind::Dot,
            (StatusTone::Done, true) => GlyphKind::SmallDot,
            (StatusTone::Muted, _) => GlyphKind::Ring,
        };
        Self { kind, color: None, tone: Some(pill.tone) }
    }

    pub fn color(mut self, color: Hsla) -> Self {
        self.color = Some(color);
        self
    }
}

impl RenderOnce for StatusGlyph {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let color = self.color.or(self.tone.map(|tone| theme.tone(tone))).unwrap_or(theme.idle);
        let z = |v: f32| theme.z(v);
        match self.kind {
            GlyphKind::Spinner => div()
                .flex_none()
                .mx(z(1.))
                .child(
                    svg().path(IconName::Spinner.path()).size(z(12.)).text_color(color).with_animation(
                        "soprano-spinner",
                        Animation::new(SPINNER_REVOLUTION)
                            .repeat_synced()
                            .with_max_fps(1000.0 / SPINNER_STEP.as_millis() as f32),
                        |svg, turn| svg.with_transformation(Transformation::rotate(radians(turn * TAU))),
                    ),
                )
                .into_any_element(),
            GlyphKind::Pill(label) => div()
                .flex()
                .flex_none()
                .items_center()
                .h(z(18.))
                .px(z(6.))
                .rounded(z(5.))
                .bg(color.opacity(0.15))
                .text_size(z(size::BADGE))
                .font_weight(FontWeight::SEMIBOLD)
                .font_family(fonts::UI_FONT_FAMILY)
                .text_color(color)
                .whitespace_nowrap()
                .child(label)
                .into_any_element(),
            GlyphKind::Alert => div()
                .flex()
                .flex_none()
                .items_center()
                .justify_center()
                .size(z(14.))
                .rounded(z(4.))
                .bg(color.opacity(0.15))
                .text_size(z(size::BADGE))
                .font_weight(FontWeight::BOLD)
                .text_color(color)
                .child("!")
                .into_any_element(),
            GlyphKind::Dot => {
                div().flex_none().mx(z(3.)).size(z(7.)).rounded(z(4.)).bg(color).into_any_element()
            }
            GlyphKind::SmallDot => div().flex_none().size(z(6.)).rounded(z(3.)).bg(color).into_any_element(),
            GlyphKind::Ring => div()
                .flex_none()
                .mx(z(3.))
                .size(z(7.))
                .rounded(z(4.))
                .border(z(1.5))
                .border_color(color)
                .into_any_element(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000 + seconds)
    }

    #[test]
    fn live_durations_read_seconds_then_minutes_then_hours_and_minutes() {
        assert_eq!(compact_duration(Duration::from_secs(12)), "12s");
        assert_eq!(compact_duration(Duration::from_secs(125)), "2m");
        assert_eq!(compact_duration(Duration::from_secs(3 * 3600 + 7 * 60 + 5)), "3h 7m");
    }

    #[test]
    fn relative_times_read_now_minutes_hours_and_days() {
        assert_eq!(relative_time(at(0), at(30)), "now");
        assert_eq!(relative_time(at(30), at(0)), "now");
        assert_eq!(relative_time(at(0), at(5 * 60)), "5m");
        assert_eq!(relative_time(at(0), at(2 * 3600)), "2h");
        assert_eq!(relative_time(at(0), at(3 * 86_400)), "3d");
    }

    #[test]
    fn a_working_pill_counts_its_live_duration() {
        let pill = StatusPillSpec::of(AgentStatus::Running, None, Some(at(0))).expect("pill");
        assert_eq!(pill.text(at(120)), "Working 2m");
        assert_eq!(pill.tone, StatusTone::Working);
    }

    #[test]
    fn waiting_reads_done_approval_or_input_by_its_reason() {
        let label = |reason| StatusPillSpec::of(AgentStatus::Waiting, reason, None).map(|p| p.label);
        assert_eq!(label(Some(AgentWaitingReason::TurnEnded)), Some("Done"));
        assert_eq!(label(Some(AgentWaitingReason::Approval)), Some("Approval"));
        assert_eq!(label(Some(AgentWaitingReason::Question)), Some("Input"));
        assert_eq!(label(None), Some("Input"));
    }

    #[test]
    fn idle_agents_have_no_pill_and_the_other_statuses_have_theirs() {
        assert_eq!(StatusPillSpec::of(AgentStatus::Idle, None, None), None);
        let pill = |status| StatusPillSpec::of(status, None, None).map(|p| (p.label, p.tone));
        assert_eq!(pill(AgentStatus::Starting), Some(("Starting", StatusTone::Working)));
        assert_eq!(pill(AgentStatus::Error), Some(("Failed", StatusTone::Failed)));
        assert_eq!(pill(AgentStatus::Stopped), Some(("Stopped", StatusTone::Muted)));
        assert_eq!(StatusPillSpec::of(AgentStatus::Starting, None, Some(at(0))).and_then(|p| p.since), None);
    }

    #[test]
    fn a_pane_shows_its_agents_pill_else_running_while_a_command_runs() {
        let working = StatusPillSpec::of(AgentStatus::Running, None, None);
        assert_eq!(StatusPillSpec::for_pane(Some(working), true), working);
        assert_eq!(StatusPillSpec::for_pane(Some(None), true), None);
        assert_eq!(StatusPillSpec::for_pane(None, true), Some(StatusPillSpec::RUNNING));
        assert_eq!(StatusPillSpec::for_pane(None, false), None);
    }

    #[test]
    fn the_status_clock_counts_a_fresh_agent_from_its_start_and_later_changes_from_now() {
        let mut clock = StatusClock::default();
        assert_eq!(clock.since("a", AgentStatus::Running, Some(at(0)), at(50)), at(0));
        assert_eq!(clock.since("a", AgentStatus::Running, Some(at(0)), at(90)), at(0));
        assert_eq!(clock.since("a", AgentStatus::Waiting, Some(at(0)), at(100)), at(100));
        assert_eq!(clock.since("a", AgentStatus::Running, Some(at(0)), at(130)), at(130));
        // A fresh idle agent counts from now.
        assert_eq!(clock.since("b", AgentStatus::Idle, Some(at(0)), at(60)), at(60));
        let pill = clock.pill("a", AgentStatus::Running, None, Some(at(0)), at(190)).expect("pill");
        assert_eq!(pill.text(at(190)), "Working 1m");
    }

    #[test]
    fn badges_show_the_most_urgent_status_and_hide_at_zero() {
        let working = (AgentStatus::Running, None);
        let badge = TabBadge::agents(&[working; 12]).expect("badge");
        assert_eq!((badge.count, badge.pill.label), (12, "Working"));

        let mut agents = vec![working; 11];
        agents.push((AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded)));
        assert_eq!(TabBadge::agents(&agents).map(|b| b.pill.label), Some("Done"));
        agents.push((AgentStatus::Error, None));
        assert_eq!(TabBadge::agents(&agents).map(|b| b.pill.tone), Some(StatusTone::Failed));

        assert_eq!(TabBadge::agents(&[(AgentStatus::Idle, None)]).map(|b| b.pill.label), Some("Ready"));
        assert_eq!(
            TabBadge::agents(&[(AgentStatus::Stopped, None)]).map(|b| b.pill),
            Some(StatusPillSpec::READY)
        );
        assert_eq!(TabBadge::agents(&[]), None);
        assert_eq!(TabBadge::running_commands(0), None);
        assert_eq!(TabBadge::running_commands(2).map(|b| b.pill.label), Some("Running"));
    }

    #[test]
    fn tooltips_summarize_agents_in_urgency_order_and_running_commands() {
        use AgentStatus::*;
        assert_eq!(
            tab_tooltip("Window 1: Work", &[Running, Starting], 0),
            "Window 1: Work — 2 agents: 1 working, 1 starting"
        );
        assert_eq!(
            tab_tooltip("Window 1: Work", &[Starting, Idle], 0),
            "Window 1: Work — 2 agents: 1 starting, 1 ready"
        );
        assert_eq!(tab_tooltip("Window 1: Work", &[Idle], 0), "Window 1: Work — 1 agent: 1 ready");
        assert_eq!(tab_tooltip("Window 1: Work", &[], 0), "Window 1: Work");
        let mut many = vec![Running; 11];
        many.push(Waiting);
        assert!(tab_tooltip("Tab 1: X", &many, 0).contains("1 needs input, 11 working"));
        assert_eq!(
            tab_tooltip("Tab 2: Y", &[Waiting], 1),
            "Tab 2: Y — 1 agent: 1 needs input — 1 command running"
        );
        assert_eq!(running_commands_summary(3).as_deref(), Some("3 commands running"));
    }

    #[test]
    fn glyphs_follow_herdrs_status_forms() {
        let glyph = |status, compact| {
            StatusGlyph::for_pill(&StatusPillSpec::of(status, None, None).expect("pill"), compact).kind
        };
        assert_eq!(glyph(AgentStatus::Running, false), GlyphKind::Spinner);
        assert_eq!(glyph(AgentStatus::Waiting, false), GlyphKind::Pill("Needs you".into()));
        assert_eq!(glyph(AgentStatus::Waiting, true), GlyphKind::Alert);
        assert_eq!(glyph(AgentStatus::Stopped, false), GlyphKind::Ring);
        assert_eq!(
            StatusGlyph::for_pill(
                &StatusPillSpec::of(AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded), None)
                    .expect("pill"),
                true
            )
            .kind,
            GlyphKind::SmallDot
        );
    }
}
