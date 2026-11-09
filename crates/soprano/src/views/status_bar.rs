//! The status bar (`Views/StatusBarView.swift`) in Herdr's look (HERDR-UI §10). Left: the
//! keybinding mode as a quiet pill (`Normal`, or `Prefix` / `Copy` / `Select` in a status tone)
//! and the `session  /  window  /  pane · Tab 2` location. Right: the counts with the panes that
//! need you in the attention color, account usage (click: the usage card), the palette and
//! prefix hints as keycaps, and the opt-in `Up h:mm:ss`.

use std::cell::Cell;
use std::ops::Range;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use gpui::{
    Anchor, App, Bounds, Context, DismissEvent, Entity, EventEmitter, FocusHandle, Focusable, FontWeight,
    HighlightStyle, Hsla, InteractiveElement, IntoElement, ParentElement, Pixels, Point, Render,
    StatefulInteractiveElement, Styled, StyledText, Subscription, Task, WeakEntity, Window, anchored, canvas,
    deferred, div, point, prelude::*, px,
};
use soprano_accounts::AccountsSource;
use soprano_accounts::models::UsageSeverity;
use soprano_accounts::presentation::{
    STATUS_USAGE_SEPARATOR, STATUS_USAGE_TOOLTIP, StatusUsageSegment, status_usage,
};
use soprano_model::{ActiveLocation, Workspace};
use soprano_settings::{AccountUsagePopover, UsagePopoverEvent};
use soprano_types::KeybindingState;
use soprano_ui::keycaps::{KeyPlatform, chord_cap};
use soprano_ui::theme::Tokens;
use soprano_ui::{ActiveSopranoTheme, Keycaps, StatusBar as StatusBarFrame, StatusTone, tooltip};

use crate::services::Services;
use crate::shell::{Command, Shell, dispatch};
use crate::workspace::WorkspaceHandle;

/// A pointer press that closed the usage card also lands on the usage segment; a click this
/// soon after the card closed was that press, not a request to reopen it.
const CARD_REOPEN_GUARD: Duration = Duration::from_millis(400);

/// `Up h:mm:ss` for an elapsed interval; hours keep growing past 99.
pub fn uptime_text(elapsed: Duration) -> String {
    let total = elapsed.as_secs();
    format!("Up {}:{:02}:{:02}", total / 3600, total / 60 % 60, total % 60)
}

/// The mode pill's word and tone: `Normal` quiet, `Prefix` approval, `Copy` working, `Select`
/// input.
pub fn mode_label(mode: KeybindingState) -> (&'static str, Option<StatusTone>) {
    match mode {
        KeybindingState::Normal => ("Normal", None),
        KeybindingState::Prefix => ("Prefix", Some(StatusTone::Approval)),
        KeybindingState::Copy => ("Copy", Some(StatusTone::Working)),
        KeybindingState::CopySelection => ("Select", Some(StatusTone::Input)),
    }
}

/// The prefix hint's cap: Control plus the prefix key (`⌃A`, `Ctrl+A` off macOS).
pub fn prefix_caps(prefix_key: &str) -> Vec<String> {
    vec![chord_cap(true, false, false, prefix_key, KeyPlatform::current())]
}

/// The counts segment: `1 session · 2 windows · 3 panes · maximized`, then `N needs you` in the
/// attention color when any pane wants you.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Counts {
    pub text: String,
    pub needs_you: Option<String>,
}

impl Counts {
    pub fn of(workspace: &Workspace) -> Self {
        fn plural(count: usize, noun: &str) -> String {
            format!("{count} {noun}{}", if count == 1 { "" } else { "s" })
        }
        let mut parts = vec![
            plural(workspace.terminal_sessions().len(), "session"),
            plural(workspace.window_count(), "window"),
            plural(workspace.pane_count(), "pane"),
        ];
        if workspace.maximized_pane_id().is_some() {
            parts.push("maximized".to_owned());
        }
        let attention = workspace.attention_count();
        Self {
            text: parts.join(" · "), needs_you: (attention > 0).then(|| format!("{attention} needs you"))
        }
    }
}

/// How a piece of styled status-bar text is colored.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Run {
    Muted,
    /// The location's `  /  `: muted at 60 %.
    Separator,
    /// The innermost location part: foreground, medium.
    Strong,
    /// Usage providers' `  |  `: the border color.
    Rule,
    /// A usage percentage: foreground, warning from 70 %, error from 90 %.
    Usage(UsageSeverity),
    /// `N needs you`: the attention color, medium.
    Attention,
}

/// The location in runs: the session and window muted, the pane title strong (the window title
/// when no pane is focused), the separators faint, ` · Tab n` muted.
pub fn location_runs(location: &ActiveLocation) -> Vec<(String, Run)> {
    let separator = || ("  /  ".to_owned(), Run::Separator);
    let mut runs = vec![(location.session_name.clone(), Run::Muted), separator()];
    match &location.pane_title {
        Some(pane_title) => {
            runs.push((location.window_title.clone(), Run::Muted));
            runs.push(separator());
            runs.push((pane_title.clone(), Run::Strong));
        }
        None => runs.push((location.window_title.clone(), Run::Strong)),
    }
    if let Some(number) = location.tab_number {
        runs.push((format!(" · Tab {number}"), Run::Muted));
    }
    runs
}

/// `Claude 9% · 4h 12m  |  Codex 75% · 5d 8h`: names and resets muted, the percentage by
/// severity. Empty when no provider has usage yet.
pub fn usage_runs(segments: &[StatusUsageSegment]) -> Vec<(String, Run)> {
    let mut runs = Vec::new();
    for (index, segment) in segments.iter().enumerate() {
        if index > 0 {
            runs.push((STATUS_USAGE_SEPARATOR.to_owned(), Run::Rule));
        }
        runs.push((format!("{} ", segment.name), Run::Muted));
        runs.push((segment.percent.clone(), Run::Usage(segment.severity)));
        if let Some(reset) = &segment.reset {
            runs.push((format!(" · {reset}"), Run::Muted));
        }
    }
    runs
}

/// The counts in runs.
pub fn counts_runs(counts: &Counts) -> Vec<(String, Run)> {
    let mut runs = vec![(counts.text.clone(), Run::Muted)];
    if let Some(needs_you) = &counts.needs_you {
        runs.push((" · ".to_owned(), Run::Muted));
        runs.push((needs_you.clone(), Run::Attention));
    }
    runs
}

fn run_style(run: Run, theme: &Tokens) -> HighlightStyle {
    let (color, weight) = match run {
        Run::Muted => (theme.muted, None),
        Run::Separator => (theme.muted.opacity(0.6), None),
        Run::Strong => (theme.foreground, Some(FontWeight::MEDIUM)),
        Run::Rule => (theme.border, None),
        Run::Usage(UsageSeverity::Normal) => (theme.foreground, None),
        Run::Usage(UsageSeverity::Warning) => (theme.approval, None),
        Run::Usage(UsageSeverity::Danger) => (theme.failed, None),
        Run::Attention => (theme.attention, Some(FontWeight::MEDIUM)),
    };
    HighlightStyle { color: Some(color), font_weight: weight, ..HighlightStyle::default() }
}

fn styled(runs: Vec<(String, Run)>, theme: &Tokens) -> StyledText {
    let mut text = String::new();
    let mut highlights: Vec<(Range<usize>, HighlightStyle)> = Vec::new();
    for (piece, run) in runs {
        let start = text.len();
        text.push_str(&piece);
        highlights.push((start..text.len(), run_style(run, theme)));
    }
    StyledText::new(text).with_highlights(highlights)
}

fn minute_number(now: SystemTime) -> u64 {
    now.duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs() / 60
}

pub struct StatusBar {
    workspace: WorkspaceHandle,
    shell: Entity<Shell>,
    services: Services,
    observer_id: String,
    /// The minute the usage countdowns were last drawn in.
    usage_minute: u64,
    /// Where the usage segment was painted (the card opens above it).
    usage_bounds: Rc<Cell<Bounds<Pixels>>>,
    usage_card: Option<WeakEntity<UsagePopup>>,
    usage_card_closed_at: Option<Instant>,
    _accounts: Task<()>,
    _clock: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl StatusBar {
    pub fn new(
        workspace: WorkspaceHandle,
        shell: Entity<Shell>,
        services: Services,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let observer_id = format!("StatusBar-{}", cx.entity_id());
        // The accounts controller publishes on its own threads; hop to the UI.
        let (sender, receiver) = async_channel::unbounded::<()>();
        services.accounts.add_observer(
            &observer_id,
            Arc::new(move |_| {
                let _ = sender.try_send(());
            }),
        );
        let accounts = cx.spawn(async move |this, cx| {
            while receiver.recv().await.is_ok() {
                while receiver.try_recv().is_ok() {}
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        let clock = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                if this.update(cx, |bar, cx| bar.tick(cx)).is_err() {
                    break;
                }
            }
        });
        let subscriptions = vec![
            cx.observe(&workspace.model, |_, _, cx| cx.notify()),
            cx.observe(&shell, |_, _, cx| cx.notify()),
            cx.on_release(|bar, _| bar.services.accounts.remove_observer(&bar.observer_id)),
        ];
        services.accounts.refresh(false);
        Self {
            workspace,
            shell,
            services,
            observer_id,
            usage_minute: minute_number(SystemTime::now()),
            usage_bounds: Rc::new(Cell::new(Bounds::default())),
            usage_card: None,
            usage_card_closed_at: None,
            _accounts: accounts,
            _clock: clock,
            _subscriptions: subscriptions,
        }
    }

    /// Once a second: the uptime moves, and the usage countdowns (in minutes) on a new minute.
    fn tick(&mut self, cx: &mut Context<Self>) {
        if self.shell.read(cx).settings.status_bar_uptime
            || minute_number(SystemTime::now()) != self.usage_minute
        {
            cx.notify();
        }
    }

    /// Opens the usage card above the usage segment, or closes it when open (a second click on
    /// the segment).
    pub fn toggle_usage_card(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(card) = self.usage_card.take().and_then(|card| card.upgrade()) {
            card.update(cx, |_, cx| cx.emit(DismissEvent));
            return;
        }
        if self.usage_card_closed_at.take().is_some_and(|closed| closed.elapsed() < CARD_REOPEN_GUARD) {
            return;
        }
        let bounds = self.usage_bounds.get();
        let anchor = point(bounds.right(), bounds.top() - cx.soprano_theme().z(6.));
        let accounts: Rc<dyn AccountsSource> = Rc::new(self.services.accounts.clone());
        let shell = self.shell.clone();
        let card = cx.new(|cx| UsagePopup::new(accounts, anchor, shell, window, cx));
        cx.subscribe(&card, |bar, _, _: &DismissEvent, _| {
            bar.usage_card = None;
            bar.usage_card_closed_at = Some(Instant::now());
        })
        .detach();
        self.usage_card = Some(card.downgrade());
        self.shell.update(cx, |shell, cx| shell.show_popup(card, window, cx));
        self.services.accounts.refresh(false);
    }

    fn mode_pill(mode: KeybindingState, theme: &Tokens, z: impl Fn(f32) -> Pixels) -> impl IntoElement {
        let (label, tone) = mode_label(mode);
        let (text, fill): (Hsla, Hsla) = match tone {
            Some(tone) => {
                let color = theme.tone(tone);
                (color, color.opacity(if theme.is_dark() { 0.16 } else { 0.12 }))
            }
            None => (theme.muted, theme.foreground.opacity(0.07)),
        };
        div()
            .id("status-mode")
            .flex()
            .flex_none()
            .items_center()
            .h(z(18.))
            .px(z(6.))
            .rounded(z(4.))
            .bg(fill)
            .text_color(text)
            .font_weight(FontWeight::MEDIUM)
            .whitespace_nowrap()
            .child(label)
    }

    fn hint(
        id: &'static str,
        caps: Vec<String>,
        label: &'static str,
        z: impl Fn(f32) -> Pixels,
    ) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(z(6.))
            .whitespace_nowrap()
            .child(Keycaps::new(caps).small())
            .child(label)
    }
}

impl Render for StatusBar {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        let z = |designed: f32| theme.z(designed);
        let now = SystemTime::now();
        self.usage_minute = minute_number(now);

        let shell = self.shell.read(cx);
        let mode = shell.keybinding_mode;
        let palette_caps = shell.shortcut(&["command-palette"]);
        let prefix = prefix_caps(&shell.keybindings.prefix_key);
        let uptime = shell
            .settings
            .status_bar_uptime
            .then(|| uptime_text(now.duration_since(shell.launched_at).unwrap_or_default()));

        let workspace = self.workspace.read(cx);
        let location = workspace.active_location().map(|location| styled(location_runs(&location), &theme));
        let counts = styled(counts_runs(&Counts::of(workspace)), &theme);
        let usage_now = soprano_accounts::chrono::Utc::now();
        let usage = usage_runs(&status_usage(&self.services.accounts.snapshot(), &usage_now));

        let usage_bounds = self.usage_bounds.clone();
        let usage_segment = (!usage.is_empty()).then(|| {
            div()
                .id("status-usage")
                .relative()
                .flex_none()
                .whitespace_nowrap()
                .cursor_pointer()
                .child(styled(usage, &theme))
                .child(
                    canvas(move |bounds, _, _| usage_bounds.set(bounds), |_, _, _, _| {})
                        .absolute()
                        .size_full(),
                )
                .tooltip(tooltip(STATUS_USAGE_TOOLTIP))
                .on_click(cx.listener(|bar, _, window, cx| bar.toggle_usage_card(window, cx)))
        });
        let shell_entity = self.shell.clone();
        let palette_hint = (!palette_caps.is_empty()).then(|| {
            Self::hint("status-palette-hint", palette_caps, "Commands", z)
                .cursor_pointer()
                .on_click(move |_, _, cx| dispatch(&shell_entity, Command::OpenCommandPalette, cx))
        });

        StatusBarFrame::new()
            .child(Self::mode_pill(mode, &theme, z))
            .child(
                div()
                    .id("status-location")
                    .flex_shrink(1.)
                    .min_w_0()
                    .overflow_hidden()
                    .truncate()
                    .children(location),
            )
            .end(
                div()
                    .flex()
                    .flex_row()
                    .flex_none()
                    .items_center()
                    .gap(z(12.))
                    .child(div().id("status-counts").flex_none().whitespace_nowrap().child(counts))
                    .children(usage_segment)
                    .children(palette_hint)
                    .child(Self::hint("status-prefix-hint", prefix, "Prefix", z))
                    .children(uptime.map(|uptime| {
                        div()
                            .id("status-uptime")
                            .flex_none()
                            .whitespace_nowrap()
                            .text_color(theme.muted)
                            .child(uptime)
                    })),
            )
    }
}

/// The usage card (`AccountUsagePopover`) placed above the usage segment, trailing-aligned; it
/// closes on Escape, a click outside and a second click on the segment, and its Manage
/// Accounts… opens Settings ▸ Accounts.
pub struct UsagePopup {
    card: Entity<AccountUsagePopover>,
    anchor: Point<Pixels>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<DismissEvent> for UsagePopup {}

impl Focusable for UsagePopup {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.card.focus_handle(cx)
    }
}

impl UsagePopup {
    fn new(
        accounts: Rc<dyn AccountsSource>,
        anchor: Point<Pixels>,
        shell: Entity<Shell>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let card = cx.new(|cx| AccountUsagePopover::new(accounts, window, cx));
        let subscriptions = vec![
            cx.subscribe(&card, |_, _, _: &DismissEvent, cx| cx.emit(DismissEvent)),
            cx.subscribe(&card, move |_, _, event: &UsagePopoverEvent, cx| match event {
                UsagePopoverEvent::ManageAccounts => {
                    cx.emit(DismissEvent);
                    dispatch(&shell, Command::OpenAccountsSettings, cx);
                }
            }),
        ];
        Self { card, anchor, _subscriptions: subscriptions }
    }
}

impl Render for UsagePopup {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        deferred(
            anchored()
                .anchor(Anchor::BottomRight)
                .position(self.anchor)
                .snap_to_window_with_margin(px(8.))
                .child(self.card.clone()),
        )
    }
}

#[cfg(test)]
mod tests {
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_platform::StateStore;
    use soprano_types::{KeyBinding, KeyBindingMode};

    use super::*;

    fn text(runs: &[(String, Run)]) -> String {
        runs.iter().map(|(piece, _)| piece.as_str()).collect()
    }

    // MARK: StatusBarViewTests

    #[test]
    fn uptime_reads_hours_minutes_and_seconds() {
        assert_eq!(uptime_text(Duration::ZERO), "Up 0:00:00");
        assert_eq!(uptime_text(Duration::from_secs(2 * 3600 + 14 * 60 + 7)), "Up 2:14:07");
        assert_eq!(uptime_text(Duration::from_secs(123 * 3600)), "Up 123:00:00");
    }

    #[test]
    fn uptime_is_opt_in() {
        assert!(!AppSettings::default_settings().status_bar_uptime);
    }

    #[test]
    fn the_mode_pill_reads_in_title_case_with_a_tone_off_normal() {
        assert_eq!(mode_label(KeybindingState::Normal), ("Normal", None));
        assert_eq!(mode_label(KeybindingState::Prefix), ("Prefix", Some(StatusTone::Approval)));
        assert_eq!(mode_label(KeybindingState::Copy), ("Copy", Some(StatusTone::Working)));
        assert_eq!(mode_label(KeybindingState::CopySelection), ("Select", Some(StatusTone::Input)));
    }

    #[test]
    fn the_counts_name_sessions_windows_and_panes() {
        let mut workspace = Workspace::new();
        assert_eq!(text(&counts_runs(&Counts::of(&workspace))), "1 session · 1 window · 1 pane");
        workspace.create_window(None, None).unwrap();
        assert_eq!(text(&counts_runs(&Counts::of(&workspace))), "1 session · 2 windows · 2 panes");
        assert_eq!(Counts::of(&workspace).needs_you, None);
    }

    #[test]
    fn the_hints_follow_the_palette_binding_and_the_prefix_key() {
        let mut config = DefaultKeybindings::config();
        config.prefix_key = "b".into();
        let index = config.bindings.iter().position(|binding| binding.id == "command-palette").unwrap();
        let palette = config.bindings[index].clone();

        // A prefix binding is the prefix cap, then the key.
        config.bindings[index] =
            KeyBinding { mode: KeyBindingMode::Prefix, key: "p".into(), ..palette.clone() };
        let shell = Shell::new(StateStore::in_memory(), AppSettings::default_settings(), config.clone());
        let prefix = prefix_caps(&shell.keybindings.prefix_key);
        assert_eq!(shell.shortcut(&["command-palette"]), [prefix[0].clone(), "P".to_owned()]);
        if cfg!(target_os = "macos") {
            assert_eq!(prefix, ["⌃B"]);
        }

        // A removed palette binding drops its hint.
        config.bindings.remove(index);
        let shell = Shell::new(StateStore::in_memory(), AppSettings::default_settings(), config);
        assert!(shell.shortcut(&["command-palette"]).is_empty());
    }

    // MARK: ActiveLocationIndicatorTests (view parts)

    #[test]
    fn the_status_bar_names_the_active_window_and_pane() {
        let mut workspace = Workspace::new();
        let window = workspace.active_window_id().to_owned();
        workspace.rename_window(&window, "Soprano");
        let pane = workspace.active_pane_id().to_owned();
        let tab = workspace.panes()[&pane].active_tab().unwrap().id.clone();
        workspace.rename_tab(&pane, &tab, "Claude");

        let location = workspace.active_location().unwrap();
        let runs = location_runs(&location);
        assert_eq!(text(&runs), "Session 1  /  Soprano  /  Claude");
        assert_eq!(text(&runs), location.text());
        assert_eq!(runs.last(), Some(&("Claude".to_owned(), Run::Strong)));
    }

    #[test]
    fn the_status_bar_names_the_active_tab_only_for_windows_with_several_tabs() {
        let mut workspace = Workspace::new();
        let location = |workspace: &Workspace| text(&location_runs(&workspace.active_location().unwrap()));
        assert!(!location(&workspace).contains("· Tab"));
        workspace.create_layout_tab(None, None).unwrap();
        assert!(location(&workspace).ends_with("· Tab 2"));
        workspace.activate_previous_layout_tab();
        assert!(location(&workspace).ends_with("· Tab 1"));
        let last = workspace.active_window().unwrap().tabs().last().unwrap().id.clone();
        let _ = workspace.close_layout_tab(&last);
        assert!(!location(&workspace).contains("· Tab"));
    }

    // MARK: Usage

    #[test]
    fn usage_reads_each_providers_tightest_window_with_the_percentage_by_severity() {
        use soprano_accounts::models::AccountProvider;
        let segments = [
            StatusUsageSegment {
                provider: AccountProvider::Claude,
                name: "Claude",
                fraction: 0.09,
                percent: "9%".into(),
                severity: UsageSeverity::Normal,
                reset: Some("4h 12m".into()),
            },
            StatusUsageSegment {
                provider: AccountProvider::Codex,
                name: "Codex",
                fraction: 0.95,
                percent: "95%".into(),
                severity: UsageSeverity::Danger,
                reset: None,
            },
        ];
        let runs = usage_runs(&segments);
        assert_eq!(text(&runs), "Claude 9% · 4h 12m  |  Codex 95%");
        assert!(runs.contains(&("95%".to_owned(), Run::Usage(UsageSeverity::Danger))));
        assert!(usage_runs(&[]).is_empty());
    }

    #[test]
    fn the_needs_you_count_follows_the_counts_in_the_attention_color() {
        let counts =
            Counts { text: "1 session · 1 window · 2 panes".into(), needs_you: Some("1 needs you".into()) };
        assert_eq!(text(&counts_runs(&counts)), "1 session · 1 window · 2 panes · 1 needs you");
        assert_eq!(counts_runs(&counts).last(), Some(&("1 needs you".to_owned(), Run::Attention)));
    }
}
