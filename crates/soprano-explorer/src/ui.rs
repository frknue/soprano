//! Pieces both cards draw the same way (HERDR-UI.md §9): the card, its 42 px header, the
//! icon buttons in it, the empty-state text, and the git letter colors.
use gpui::{
    App, ClickEvent, ElementId, FontWeight, Hsla, IntoElement, ParentElement, SharedString, Styled, Window,
    div,
};
use soprano_git::GitFileStatus;
use soprano_ui::button::IconButton;
use soprano_ui::fonts::size;
use soprano_ui::{IconName, SopranoTheme};

/// The Files / Changes card: radius 10, background, 1 px border, 13 px foreground text.
pub(crate) fn card(t: &SopranoTheme) -> gpui::Div {
    div()
        .size_full()
        .flex()
        .flex_col()
        .overflow_hidden()
        .rounded(t.z(10.))
        .bg(t.background)
        .border_1()
        .border_color(t.border)
        .text_size(t.z(size::UI))
        .text_color(t.foreground)
}

/// The card header: h 42, px 14, gap 8, border below; the title semibold 13.
pub(crate) fn header(t: &SopranoTheme, title: &'static str) -> gpui::Div {
    div()
        .flex()
        .flex_none()
        .items_center()
        .h(t.z(42.))
        .px(t.z(14.))
        .gap(t.z(8.))
        .border_b_1()
        .border_color(t.border)
        .child(
            div()
                .flex_none()
                .text_size(t.z(size::PANEL_TITLE))
                .font_weight(FontWeight::SEMIBOLD)
                .child(title),
        )
}

/// A header icon button (Herdr's 26 px chrome button, 14 px glyph).
pub(crate) fn icon_button(
    id: impl Into<ElementId>,
    name: IconName,
    label: impl Into<SharedString>,
    enabled: bool,
    on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    IconButton::new(id, name).icon_size(14.).disabled(!enabled).tooltip(label).on_click(on_click)
}

/// Sidebar empty and error states: the first line muted 12, any further line dimmer.
pub(crate) fn empty_state(t: &SopranoTheme, message: &str) -> gpui::Div {
    let mut lines = message.splitn(2, '\n');
    let first = lines.next().unwrap_or_default().to_owned();
    div()
        .flex()
        .flex_col()
        .items_center()
        .gap(t.z(4.))
        .pt(t.z(24.))
        .px(t.z(24.))
        .text_size(t.z(size::META))
        .text_center()
        .child(div().text_color(t.muted).child(first))
        .children(lines.next().map(|second| div().text_color(t.dim).child(second.to_owned())))
}

/// The color of a git letter: A/? green, D red, M the "blocked" status color, R/C cyan;
/// conflicts red.
pub(crate) fn status_color(t: &SopranoTheme, status: GitFileStatus, is_conflict: bool) -> Hsla {
    if is_conflict {
        return t.ansi[1];
    }
    match status {
        GitFileStatus::Added | GitFileStatus::Untracked => t.ansi[2],
        GitFileStatus::Deleted => t.ansi[1],
        GitFileStatus::Modified => t.approval,
        GitFileStatus::Renamed | GitFileStatus::Copied => t.ansi[6],
    }
}
