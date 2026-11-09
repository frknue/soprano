//! The status bar's usage popover (`AccountUsagePopover.swift`): per provider a header, each
//! list's caption ("omp · automatic") and its logins with one bar per usage window, then
//! Refresh and Manage Accounts…. It follows the accounts while it is open, so a refresh or a
//! selection made elsewhere shows up live.
//!
//! ```text
//! Claude
//! omp · automatic
//! ○ ada@example.com
//!   5h      ▬▭▭▭▭    9%  3h 54m
//!   7d      ▬▭▭▭▭    6%  5d 17h
//! ──────────────────────────────
//! [Refresh]  [Manage Accounts…]
//! ```

use std::rc::Rc;

use gpui::{
    AnyElement, App, ClickEvent, Context, DismissEvent, EventEmitter, FocusHandle, Focusable, FontWeight,
    Hsla, IntoElement, KeyDownEvent, ParentElement, Render, Styled, Task, Window, div, prelude::*,
};
use soprano_accounts::AccountsSource;
use soprano_accounts::models::{AccountsSnapshot, UsageSeverity};
use soprano_accounts::presentation::{
    PageAction, USAGE_CARD_NO_USAGE, USAGE_CARD_SYSTEM_DEFAULT_PREFIX, UsageCard, UsageCardLine, UsageCardRow,
};
use soprano_ui::button::{Button, ButtonSize};
use soprano_ui::fonts::{self, size};
use soprano_ui::{ActiveSopranoTheme, SopranoTheme};

use crate::pages::account_mark;

/// The card's width.
pub const USAGE_POPOVER_WIDTH: f32 = 340.0;
const INSET: f32 = 14.0;
const WINDOW_LABEL_WIDTH: f32 = 52.0;
const PERCENT_WIDTH: f32 = 36.0;
const BAR_WIDTH: f32 = 64.0;

/// What the host does for the popover.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsagePopoverEvent {
    /// "Manage Accounts…": close the popover and open Settings ▸ Accounts.
    ManageAccounts,
}

/// A usage figure's color in the card: muted while there is room, warning from 70 %, error
/// from 90 % (`UsageSeverity.percentColor`).
pub fn usage_percent_color(severity: UsageSeverity, t: &SopranoTheme) -> Hsla {
    match severity {
        UsageSeverity::Normal => t.muted,
        UsageSeverity::Warning => t.approval,
        UsageSeverity::Danger => t.failed,
    }
}

/// The fill of a usage bar (`UsageSeverity.barColor`).
pub fn usage_bar_color(severity: UsageSeverity, t: &SopranoTheme) -> Hsla {
    usage_percent_color(severity, t)
}

pub struct AccountUsagePopover {
    accounts: Rc<dyn AccountsSource>,
    snapshot: AccountsSnapshot,
    focus_handle: FocusHandle,
    observer_id: String,
    _task: Task<()>,
}

impl EventEmitter<UsagePopoverEvent> for AccountUsagePopover {}
impl EventEmitter<DismissEvent> for AccountUsagePopover {}

impl Focusable for AccountUsagePopover {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl AccountUsagePopover {
    /// A card over `accounts`, following it until the popover is released. Esc and a click
    /// outside emit [`DismissEvent`].
    pub fn new(accounts: Rc<dyn AccountsSource>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let observer_id = format!("soprano-usage-popover-{}", cx.entity_id());
        let (tx, rx) = async_channel::unbounded::<()>();
        accounts.add_observer(
            &observer_id,
            std::sync::Arc::new(move |_: &AccountsSnapshot| {
                let _ = tx.try_send(());
            }),
        );
        let task = cx.spawn_in(window, async move |this, cx| {
            while rx.recv().await.is_ok() {
                while rx.try_recv().is_ok() {}
                let updated = this.update(cx, |this, cx| {
                    this.snapshot = this.accounts.snapshot();
                    cx.notify();
                });
                if updated.is_err() {
                    break;
                }
            }
        });
        let release_accounts = accounts.clone();
        let release_id = observer_id.clone();
        cx.on_release(move |_, _| release_accounts.remove_observer(&release_id)).detach();
        let focus_handle = cx.focus_handle();
        focus_handle.focus(window, cx);
        Self { snapshot: accounts.snapshot(), accounts, focus_handle, observer_id, _task: task }
    }

    /// The snapshot on screen.
    pub fn snapshot(&self) -> &AccountsSnapshot {
        &self.snapshot
    }

    /// The observer id this popover registered with the accounts source.
    pub fn observer_id(&self) -> &str {
        &self.observer_id
    }

    pub(crate) fn perform(&mut self, action: PageAction, cx: &mut Context<Self>) {
        if action == PageAction::ManageAccounts {
            cx.emit(UsagePopoverEvent::ManageAccounts);
            return;
        }
        action.perform(&*self.accounts);
        self.snapshot = self.accounts.snapshot();
        cx.notify();
    }

    fn row(row: &UsageCardRow, t: &SopranoTheme) -> AnyElement {
        let windows: Vec<AnyElement> = if row.windows.is_empty() {
            vec![
                div()
                    .text_size(t.z(size::META))
                    .text_color(t.muted)
                    .child(USAGE_CARD_NO_USAGE)
                    .into_any_element(),
            ]
        } else {
            row.windows.iter().map(|line| Self::usage_line(line, t)).collect()
        };
        let mark_column = t.z(8. + 8.);
        div()
            .id(gpui::SharedString::from(format!("usage-row-{}-{}", row.name, row.is_system_default)))
            .flex()
            .flex_col()
            .w_full()
            .gap(t.z(4.))
            .tooltip(soprano_ui::tooltip::tooltip(row.tooltip.clone()))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(t.z(8.))
                    .min_w_0()
                    .child(account_mark(row.is_selected, row.has_problem, t))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .min_w_0()
                            .truncate()
                            .text_size(t.z(size::ROW))
                            .when(row.is_system_default, |d| {
                                d.child(div().text_color(t.muted).child(USAGE_CARD_SYSTEM_DEFAULT_PREFIX))
                            })
                            .child(
                                div()
                                    .truncate()
                                    .text_color(t.foreground)
                                    .when(row.is_selected, |d| d.font_weight(FontWeight::SEMIBOLD))
                                    .child(row.name.clone()),
                            ),
                    ),
            )
            .child(div().flex().flex_col().gap(t.z(3.)).pl(mark_column).children(windows))
            .into_any_element()
    }

    /// One window: its label, a bar filled to the share used, the percentage in the severity
    /// color, and the time until it resets.
    fn usage_line(line: &UsageCardLine, t: &SopranoTheme) -> AnyElement {
        let share = line.fraction.clamp(0.0, 1.0) as f32;
        let filled = if share > 0.0 { (BAR_WIDTH * share).round().max(4.0) } else { 0.0 };
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(8.))
            .text_size(t.z(size::META))
            .child(div().min_w(t.z(WINDOW_LABEL_WIDTH)).text_color(t.muted).child(line.label.clone()))
            .child(
                div()
                    .relative()
                    .w(t.z(BAR_WIDTH))
                    .h(t.z(4.))
                    .rounded(t.z(2.))
                    .bg(t.foreground.opacity(if t.is_dark() { 0.12 } else { 0.08 }))
                    .when(filled > 0.0, |bar| {
                        bar.child(
                            div()
                                .absolute()
                                .left_0()
                                .top_0()
                                .h_full()
                                .w(t.z(filled))
                                .rounded(t.z(2.))
                                .bg(usage_bar_color(line.severity, t)),
                        )
                    }),
            )
            .child(
                div()
                    .w(t.z(PERCENT_WIDTH))
                    .flex()
                    .justify_end()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(usage_percent_color(line.severity, t))
                    .child(line.percent.clone()),
            )
            .when_some(line.reset.clone(), |row, reset| {
                row.child(div().ml(t.z(2.)).text_color(t.muted).child(reset))
            })
            .into_any_element()
    }
}

impl Render for AccountUsagePopover {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let now = soprano_accounts::chrono::Utc::now();
        let card = UsageCard::build(&self.snapshot, &now);

        let mut content: Vec<AnyElement> = Vec::new();
        for (index, provider) in card.providers.iter().enumerate() {
            if index > 0 {
                content.push(div().h(t.z(1.)).w_full().my(t.z(4.)).bg(t.border).into_any_element());
            }
            // Soprano shows no uppercase eyebrows: the provider reads "Claude", not "CLAUDE".
            content.push(
                div()
                    .text_size(t.z(size::SECTION))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(t.dim)
                    .child(provider.provider.display_name())
                    .into_any_element(),
            );
            for list in &provider.lists {
                let rows: Vec<AnyElement> = list.rows.iter().map(|row| Self::row(row, &t)).collect();
                content.push(
                    div()
                        .flex()
                        .flex_col()
                        .gap(t.z(8.))
                        .child(
                            div().text_size(t.z(size::META)).text_color(t.muted).child(list.caption.clone()),
                        )
                        .children(rows)
                        .into_any_element(),
                );
            }
        }
        if let Some(empty) = card.empty_text {
            content.push(div().text_size(t.z(size::ROW)).text_color(t.muted).child(empty).into_any_element());
        }

        let refresh_action = card.refresh.action.clone();
        let manage_action = card.manage_accounts.action.clone();
        div()
            .id("account-usage-popover")
            .track_focus(&self.focus_handle)
            .key_context("SopranoUsagePopover")
            .flex()
            .flex_col()
            .w(t.z(USAGE_POPOVER_WIDTH))
            .rounded(t.z(8.))
            .border_1()
            .border_color(t.border)
            .bg(t.popover)
            .shadow_lg()
            .overflow_hidden()
            .font_family(fonts::UI_FONT_FAMILY)
            .text_color(t.foreground)
            .on_key_down(cx.listener(|_, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    cx.stop_propagation();
                    cx.emit(DismissEvent);
                }
            }))
            .on_mouse_down_out(cx.listener(|_, _, _, cx| cx.emit(DismissEvent)))
            .child(div().flex().flex_col().gap(t.z(12.)).p(t.z(INSET)).children(content))
            .child(div().h(t.z(1.)).w_full().bg(t.border))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap(t.z(8.))
                    .px(t.z(INSET))
                    .pt(t.z(10.))
                    .pb(t.z(10.))
                    .child(
                        Button::new("usage-refresh", card.refresh.title)
                            .size(ButtonSize::Xs)
                            .disabled(!card.refresh.is_enabled)
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.perform(refresh_action.clone(), cx)
                            })),
                    )
                    .child(
                        Button::new("usage-manage", card.manage_accounts.title)
                            .primary()
                            .size(ButtonSize::Xs)
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.perform(manage_action.clone(), cx)
                            })),
                    ),
            )
    }
}
