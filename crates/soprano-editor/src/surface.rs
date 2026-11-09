//! The pieces the editor, diff and Markdown reader share (`Views/Surfaces/SurfaceKit.swift`):
//! the 40 px toolbar over a hairline, the folder breadcrumbs, and the muted centered message
//! with its optional outline button.

use std::path::Path;
use std::sync::Arc;

use gpui::{
    AnyElement, App, ClickEvent, ElementId, HighlightStyle, InteractiveElement, IntoElement, ParentElement,
    RenderOnce, SharedString, StatefulInteractiveElement, Styled, StyledText, Window, div,
    prelude::FluentBuilder,
};
use soprano_ui::button::{Button, ButtonSize, ButtonVariant, IconButton};
use soprano_ui::fonts::size;
use soprano_ui::{ActiveSopranoTheme, IconName};

use crate::colors::SurfaceColors;

/// Height of a surface toolbar, without its hairline.
pub const TOOLBAR_HEIGHT: f32 = 40.0;

/// The path a breadcrumb shows for a file: relative to its git working tree, else the
/// home-abbreviated absolute path (`SurfaceBreadcrumbs.displayPath`).
pub fn display_path(path: &Path) -> String {
    let folder = path.parent().unwrap_or(path);
    if let Some(root) = soprano_git::branch::repository_root(&folder.to_string_lossy())
        && let Ok(relative) = path.strip_prefix(&root)
        && !relative.as_os_str().is_empty()
    {
        return relative
            .components()
            .map(|part| part.as_os_str().to_string_lossy())
            .collect::<Vec<_>>()
            .join("/");
    }
    soprano_platform::paths::abbreviate_home(path)
}

/// "Sources / Auth / LoginController.swift": folders and separators muted, the name in the
/// foreground at medium weight, truncated from the head; the full path is the tooltip.
pub fn breadcrumbs(path: &str, full_path: &Path, cx: &App) -> AnyElement {
    let colors = SurfaceColors::of(cx);
    let parts: Vec<&str> = path.split(['/', '\\']).filter(|part| !part.is_empty()).collect();
    let mut text = String::new();
    let mut name_start = 0;
    for (index, part) in parts.iter().enumerate() {
        if index + 1 == parts.len() {
            name_start = text.len();
            text.push_str(part);
        } else {
            text.push_str(part);
            text.push_str(" / ");
        }
    }
    let highlights = vec![(
        name_start..text.len(),
        HighlightStyle {
            color: Some(colors.foreground),
            font_weight: Some(gpui::FontWeight::MEDIUM),
            ..Default::default()
        },
    )];
    let theme = cx.soprano_theme();
    div()
        .id("surface-breadcrumbs")
        .tooltip(soprano_ui::tooltip(full_path.to_string_lossy().into_owned()))
        .flex_1()
        .min_w_0()
        .overflow_hidden()
        .whitespace_nowrap()
        .text_ellipsis_start()
        .text_size(theme.z(size::META))
        .text_color(colors.muted)
        .child(StyledText::new(SharedString::from(text)).with_highlights(highlights))
        .into_any_element()
}

/// A toolbar button: Herdr's 26 px icon button with a 14 px glyph.
pub fn toolbar_button(
    id: impl Into<ElementId>,
    icon: IconName,
    label: &'static str,
    enabled: bool,
    on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> IconButton {
    IconButton::new(id, icon).icon_size(14.0).tooltip(label).disabled(!enabled).on_click(on_click)
}

/// The header of a file surface: `leading` takes the slack, `trailing` sits at the end.
#[derive(IntoElement)]
pub struct SurfaceToolbar {
    leading: Vec<AnyElement>,
    trailing: Vec<AnyElement>,
}

impl SurfaceToolbar {
    pub fn new() -> Self {
        Self { leading: Vec::new(), trailing: Vec::new() }
    }

    pub fn leading(mut self, element: impl IntoElement) -> Self {
        self.leading.push(element.into_any_element());
        self
    }

    pub fn trailing(mut self, element: impl IntoElement) -> Self {
        self.trailing.push(element.into_any_element());
        self
    }
}

impl Default for SurfaceToolbar {
    fn default() -> Self {
        Self::new()
    }
}

impl RenderOnce for SurfaceToolbar {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        div()
            .flex_shrink_0()
            .w_full()
            .h(theme.z(TOOLBAR_HEIGHT + 1.0))
            .pl(theme.z(16.0))
            .pr(theme.z(8.0))
            .flex()
            .flex_row()
            .items_center()
            .bg(theme.background)
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(theme.z(8.0))
                    .children(self.leading),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(theme.z(2.0))
                    .children(self.trailing),
            )
    }
}

type Action = Arc<dyn Fn(&ClickEvent, &mut Window, &mut App)>;

/// What a surface cannot show: a muted 12 px note (up to four lines, centered) over an
/// optional outline button.
#[derive(IntoElement)]
pub struct SurfaceMessage {
    text: SharedString,
    button: Option<(SharedString, Action)>,
}

impl SurfaceMessage {
    pub fn new(text: impl Into<SharedString>) -> Self {
        Self { text: text.into(), button: None }
    }

    pub fn button(
        mut self,
        title: impl Into<SharedString>,
        action: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.button = Some((title.into(), Arc::new(action)));
        self
    }
}

impl RenderOnce for SurfaceMessage {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        div().size_full().flex().items_center().justify_center().px(theme.z(24.0)).child(
            div()
                .mt(-theme.z(40.0))
                .flex()
                .flex_col()
                .items_center()
                .gap(theme.z(12.0))
                .max_w_full()
                .child(
                    div()
                        .text_center()
                        .text_size(theme.z(size::META))
                        .text_color(theme.muted)
                        .line_clamp(4)
                        .child(self.text),
                )
                .when_some(self.button, |stack, (title, action)| {
                    stack.child(
                        Button::new("surface-message-button", title)
                            .variant(ButtonVariant::Secondary)
                            .size(ButtonSize::Sm)
                            .on_click(move |event, window, cx| action(event, window, cx)),
                    )
                }),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_outside_any_repository_shows_with_the_home_abbreviated() {
        let home = soprano_platform::paths::home_dir();
        let path = home.join("soprano-surface-test-nowhere/notes.md");
        // No git repository sits at a path that does not exist.
        let shown = display_path(&path);
        assert!(shown.ends_with("soprano-surface-test-nowhere/notes.md"));
        assert!(shown.starts_with('~') || !path.starts_with(&home));
    }
}
