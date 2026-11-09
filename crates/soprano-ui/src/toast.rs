//! Toasts (HERDR-UI.md §11.7): bottom-right (16, 16), stacked upward 8 apart, 340 wide, the
//! overlay frame; an 8 px level dot, a 13 px semibold title and a 12 px `muted` body. They go
//! away after 5 s (errors and warnings after 8 s); a click runs the toast's action.

use std::rc::Rc;
use std::time::Duration;

use gpui::{
    App, AppContext as _, Context, ElementId, Entity, FontWeight, InteractiveElement, IntoElement,
    ParentElement, Render, SharedString, StatefulInteractiveElement, Styled, Window, div, prelude::*,
};

use crate::fonts::{self, size};
use crate::menu::MenuHandler;
use crate::motion::fade_in;
use crate::theme::ActiveSopranoTheme;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ToastLevel {
    #[default]
    Info,
    Success,
    Warning,
    Error,
}

impl ToastLevel {
    /// How long a toast of this level stays.
    pub fn lifetime(self) -> Duration {
        match self {
            Self::Warning | Self::Error => Duration::from_secs(8),
            Self::Info | Self::Success => Duration::from_secs(5),
        }
    }
}

#[derive(Clone)]
pub struct Toast {
    pub level: ToastLevel,
    pub title: SharedString,
    pub body: Option<SharedString>,
    action: Option<MenuHandler>,
}

impl Toast {
    pub fn new(level: ToastLevel, title: impl Into<SharedString>) -> Self {
        Self { level, title: title.into(), body: None, action: None }
    }

    pub fn body(mut self, body: impl Into<SharedString>) -> Self {
        self.body = Some(body.into());
        self
    }

    /// Runs when the toast is clicked (which also closes it).
    pub fn on_click(mut self, action: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.action = Some(Rc::new(action));
        self
    }
}

/// The window's toasts. Keep one per window and render it in the root.
pub struct ToastStack {
    toasts: Vec<(u64, Toast)>,
    next_id: u64,
}

impl ToastStack {
    pub fn new(cx: &mut App) -> Entity<Self> {
        cx.new(|_| Self { toasts: Vec::new(), next_id: 0 })
    }

    /// Shows `toast` and schedules its removal; returns its id.
    pub fn push(&mut self, toast: Toast, cx: &mut Context<Self>) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let lifetime = toast.level.lifetime();
        self.toasts.push((id, toast));
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(lifetime).await;
            this.update(cx, |stack, cx| stack.remove(id, cx)).ok();
        })
        .detach();
        cx.notify();
        id
    }

    pub fn remove(&mut self, id: u64, cx: &mut Context<Self>) {
        let before = self.toasts.len();
        self.toasts.retain(|(toast_id, _)| *toast_id != id);
        if self.toasts.len() != before {
            cx.notify();
        }
    }

    pub fn len(&self) -> usize {
        self.toasts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.toasts.is_empty()
    }
}

impl Render for ToastStack {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        let z = |v: f32| theme.z(v);
        let toasts = self.toasts.iter().rev().map(|(id, toast)| {
            let dot = match toast.level {
                ToastLevel::Error => theme.failed,
                ToastLevel::Warning => theme.approval,
                ToastLevel::Success => theme.done,
                ToastLevel::Info => theme.accent,
            };
            let action = toast.action.clone();
            let id = *id;
            let card = div()
                .id(ElementId::NamedInteger("soprano-toast".into(), id))
                .flex()
                .flex_row()
                .items_center()
                .gap(z(12.))
                .w(z(340.))
                .min_h(z(72.))
                .px(z(18.))
                .py(z(12.))
                .bg(theme.popover)
                .border_1()
                .border_color(theme.border)
                .rounded(z(8.))
                .shadow_lg()
                .cursor_pointer()
                .hover(|s| s.bg(theme.hover))
                .child(div().flex_none().size(z(8.)).rounded(z(4.)).bg(dot))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .min_w_0()
                        .flex_1()
                        .child(
                            div()
                                .truncate()
                                .text_size(z(size::PANEL_TITLE))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(theme.foreground)
                                .child(toast.title.clone()),
                        )
                        .when_some(toast.body.clone(), |col, body| {
                            col.child(
                                div()
                                    .text_size(z(size::META))
                                    .text_color(theme.muted)
                                    .line_clamp(2)
                                    .child(body),
                            )
                        }),
                )
                .on_click(cx.listener(move |stack, _, window, cx| {
                    stack.remove(id, cx);
                    if let Some(action) = action.clone() {
                        window.defer(cx, move |window, cx| action(window, cx));
                    }
                }));
            fade_in(card, ElementId::NamedInteger("soprano-toast-fade".into(), id), cx)
        });
        div()
            .absolute()
            .bottom(z(16.))
            .right(z(16.))
            .flex()
            .flex_col()
            .gap(z(8.))
            .font_family(fonts::UI_FONT_FAMILY)
            .children(toasts.collect::<Vec<_>>().into_iter().rev())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::TestAppContext;

    #[test]
    fn errors_and_warnings_stay_longer() {
        assert_eq!(ToastLevel::Info.lifetime(), Duration::from_secs(5));
        assert_eq!(ToastLevel::Error.lifetime(), Duration::from_secs(8));
    }

    #[gpui::test]
    fn a_toast_goes_away_after_its_lifetime(cx: &mut TestAppContext) {
        cx.update(crate::init_for_tests);
        let stack = cx.update(ToastStack::new);
        stack.update(cx, |stack, cx| stack.push(Toast::new(ToastLevel::Info, "Saved"), cx));
        assert_eq!(stack.read_with(cx, |s, _| s.len()), 1);
        cx.executor().advance_clock(Duration::from_secs(6));
        cx.run_until_parked();
        assert!(stack.read_with(cx, |s, _| s.is_empty()));
    }
}
