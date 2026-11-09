//! What floats over the composer (`ComposerMenus.swift`, `ComposerPopover.swift`,
//! `ContextMeterCardContent`): the model picker, the thinking and permission menus, the context
//! card, and the approval's "More" menu.

use gpui::{
    Anchor, AnyElement, App, Context, DismissEvent, Entity, FocusHandle, FontWeight, IntoElement,
    KeyDownEvent, ParentElement, Pixels, Point, SharedString, Styled, Subscription, Window, anchored,
    deferred, div, point, prelude::*, px,
};
use gpui_component::input::{Enter, Escape, MoveDown, MoveUp};
use soprano_chat::AgentChatConfigOption;
use soprano_ui::button::ButtonSize;
use soprano_ui::fonts::UI_FONT_FAMILY;
use soprano_ui::menu::{ContextMenu, MenuItem};
use soprano_ui::{
    ActiveSopranoTheme, Button, IconName, InputEvent, InputState, Keycaps, SopranoTheme, icon, text_input,
};

use crate::composer::ComposerView;
use crate::composer_logic::{
    ContextLevel, MODE_CATEGORY, MODEL_CATEGORY, THINKING_CATEGORY, model_provider, option_of, option_title,
    shown_models,
};
use crate::composer_parts::agent_glyph;
use crate::keys;
use crate::widgets::text_size;
use crate::work_log::timeline_icon;

/// Space between a popover and the control that opened it.
const GAP: f32 = 6.0;
const MODEL_PICKER_WIDTH: f32 = 404.0;
const OPTION_MENU_WIDTH: f32 = 296.0;
const CONTEXT_CARD_WIDTH: f32 = 272.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PopoverKind {
    Model,
    Traits,
    Permissions,
    Context,
}

/// An open popover: its kind, the keyboard highlight and, for the model picker, its search.
pub struct Popover {
    pub kind: PopoverKind,
    pub(crate) highlighted: Option<usize>,
    pub(crate) search: Option<Entity<InputState>>,
    focus: FocusHandle,
    /// The model list's scroll position (the highlight stays in view).
    pub(crate) scroll: gpui::ScrollHandle,
    _subscription: Option<Subscription>,
}

impl Popover {
    pub(crate) fn new(
        kind: PopoverKind,
        composer: &ComposerView,
        window: &mut Window,
        cx: &mut Context<ComposerView>,
    ) -> Self {
        let focus = cx.focus_handle();
        let mut popover = Self {
            kind,
            highlighted: None,
            search: None,
            focus,
            scroll: gpui::ScrollHandle::new(),
            _subscription: None,
        };
        match kind {
            PopoverKind::Model => {
                let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search models..."));
                popover._subscription = Some(cx.subscribe(&search, |this, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::Change) {
                        let query = this
                            .popover
                            .as_ref()
                            .and_then(|p| p.search.clone())
                            .map(|s| s.read(cx).value().to_string());
                        if let (Some(query), Some(option)) = (query, composer_option(this, MODEL_CATEGORY)) {
                            let (shown, _) = shown_models(&option, &query);
                            let highlighted = if query.trim().is_empty() {
                                shown.iter().position(|v| v.value == option.current_value).or(Some(0))
                            } else {
                                Some(0)
                            };
                            if let Some(popover) = this.popover.as_mut() {
                                popover.highlighted = highlighted.filter(|_| !shown.is_empty());
                                if let Some(index) = popover.highlighted {
                                    popover.scroll.scroll_to_item(index);
                                }
                            }
                        }
                        cx.notify();
                    }
                }));
                search.update(cx, |search, cx| search.focus(window, cx));
                popover.search = Some(search);
                if let Some(option) = composer_option(composer, MODEL_CATEGORY) {
                    let (shown, _) = shown_models(&option, "");
                    popover.highlighted =
                        shown.iter().position(|v| v.value == option.current_value).or(Some(0));
                }
            }
            PopoverKind::Traits | PopoverKind::Permissions => {
                let category = if kind == PopoverKind::Traits { THINKING_CATEGORY } else { MODE_CATEGORY };
                popover.highlighted = composer_option(composer, category)
                    .and_then(|o| o.values.iter().position(|v| v.value == o.current_value));
                popover.focus.focus(window, cx);
            }
            PopoverKind::Context => popover.focus.focus(window, cx),
        }
        if let Some(index) = popover.highlighted {
            popover.scroll.scroll_to_item(index);
        }
        popover
    }
}

fn composer_option(composer: &ComposerView, category: &str) -> Option<AgentChatConfigOption> {
    option_of(composer.session.borrow().config_options(), category).cloned()
}

fn category(kind: PopoverKind) -> &'static str {
    match kind {
        PopoverKind::Model => MODEL_CATEGORY,
        PopoverKind::Traits => THINKING_CATEGORY,
        PopoverKind::Permissions | PopoverKind::Context => MODE_CATEGORY,
    }
}

/// The values a list popover offers, in order.
fn values(composer: &ComposerView, kind: PopoverKind, cx: &App) -> Vec<String> {
    let Some(option) = composer_option(composer, category(kind)) else { return Vec::new() };
    if kind == PopoverKind::Model {
        let query = composer
            .popover
            .as_ref()
            .and_then(|p| p.search.as_ref())
            .map(|s| s.read(cx).value().to_string())
            .unwrap_or_default();
        return shown_models(&option, &query).0.into_iter().map(|v| v.value.clone()).collect();
    }
    option.values.iter().map(|v| v.value.clone()).collect()
}

impl ComposerView {
    /// The approval panel's "More" menu (Always allow, …).
    pub(crate) fn show_more_approvals(
        &mut self,
        position: Point<Pixels>,
        options: Vec<(String, String)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let entity = cx.weak_entity();
        let items = options
            .into_iter()
            .map(|(id, name)| {
                let entity = entity.clone();
                MenuItem::new(name).on_select(move |window, cx| {
                    if let Some(view) = entity.upgrade() {
                        view.update(cx, |view, cx| view.choose_permission(&id, window, cx));
                    }
                })
            })
            .collect();
        let menu = ContextMenu::new(position, items, window, cx);
        let subscription = cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.more_menu = None;
            cx.notify();
        });
        self.more_menu = Some((menu, subscription));
        cx.notify();
    }

    fn popover_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let Some(kind) = self.popover.as_ref().map(|p| p.kind) else { return };
        let keystroke = &event.keystroke;
        if kind == PopoverKind::Model
            && keys::is_command(&keystroke.modifiers)
            && let Ok(digit) = keystroke.key.parse::<usize>()
            && (1..=9).contains(&digit)
        {
            cx.stop_propagation();
            if let Some(value) = values(self, kind, cx).get(digit - 1).cloned() {
                self.pick(kind, &value, window, cx);
            }
            return;
        }
        if self.popover_command(&keystroke.key, window, cx) {
            cx.stop_propagation();
        }
    }

    /// Escape closes, ↑/↓ move the highlight, Return picks (compacts in the context card).
    /// Returns whether the key was the popover's. The model picker's search field sends these
    /// as its own actions, which reach here too.
    fn popover_command(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some(kind) = self.popover.as_ref().map(|p| p.kind) else { return false };
        if key == "escape" {
            self.close_popover(cx);
            self.focus_editor(window, cx);
            return true;
        }
        if kind == PopoverKind::Context {
            if key == "enter" && self.session.borrow().can_compact() {
                self.compact(window, cx);
                return true;
            }
            return false;
        }
        let options = values(self, kind, cx);
        let Some(popover) = self.popover.as_mut() else { return false };
        match key {
            "down" | "up" => {
                if !options.is_empty() {
                    let delta: isize = if key == "down" { 1 } else { -1 };
                    let current = popover
                        .highlighted
                        .map_or(if delta > 0 { -1 } else { options.len() as isize }, |h| h as isize);
                    let index = (current + delta).clamp(0, options.len() as isize - 1) as usize;
                    popover.highlighted = Some(index);
                    popover.scroll.scroll_to_item(index);
                    cx.notify();
                }
                true
            }
            "enter" => {
                if let Some(value) = popover.highlighted.and_then(|h| options.get(h)).cloned() {
                    self.pick(kind, &value, window, cx);
                }
                true
            }
            _ => false,
        }
    }

    fn pick(&mut self, kind: PopoverKind, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(option) = composer_option(self, category(kind)) {
            self.set_option(&option.id, value, window, cx);
        }
    }

    pub(crate) fn render_popover(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let mut layers: Vec<AnyElement> =
            self.more_menu.as_ref().map(|(menu, _)| menu.clone().into_any_element()).into_iter().collect();
        let Some(kind) = self.popover.as_ref().map(|p| p.kind) else { return layers };
        let t = cx.soprano_theme().clone();
        let focus = self.popover.as_ref().map(|p| p.focus.clone()).expect("popover");
        let (anchor_bounds, corner) = match kind {
            PopoverKind::Model => (self.anchors.model.get(), Anchor::BottomLeft),
            PopoverKind::Traits => (self.anchors.traits.get(), Anchor::BottomLeft),
            PopoverKind::Permissions => (self.anchors.permissions.get(), Anchor::BottomLeft),
            PopoverKind::Context => (self.anchors.meter.get(), Anchor::BottomRight),
        };
        let position = match corner {
            Anchor::BottomRight => point(anchor_bounds.right(), anchor_bounds.top() - t.z(GAP)),
            _ => point(anchor_bounds.left(), anchor_bounds.top() - t.z(GAP)),
        };
        let content = match kind {
            PopoverKind::Model => self.render_model_picker(cx),
            PopoverKind::Traits | PopoverKind::Permissions => self.render_option_menu(kind, cx),
            PopoverKind::Context => self.render_context_card(cx),
        };
        let card = div()
            .id("composer-popover")
            .track_focus(&focus)
            .on_key_down(cx.listener(Self::popover_key))
            .capture_action(cx.listener(|this, _: &Escape, window, cx| {
                if this.popover_command("escape", window, cx) {
                    cx.stop_propagation();
                }
            }))
            .capture_action(cx.listener(|this, _: &MoveUp, window, cx| {
                if this.popover_command("up", window, cx) {
                    cx.stop_propagation();
                }
            }))
            .capture_action(cx.listener(|this, _: &MoveDown, window, cx| {
                if this.popover_command("down", window, cx) {
                    cx.stop_propagation();
                }
            }))
            .capture_action(cx.listener(|this, _: &Enter, window, cx| {
                if this.popover_command("enter", window, cx) {
                    cx.stop_propagation();
                }
            }))
            // A press on the popover's own chip is the chip's: it toggles the popover closed.
            .on_mouse_down_out(cx.listener(move |this, event: &gpui::MouseDownEvent, window, cx| {
                if anchor_bounds.contains(&event.position) {
                    return;
                }
                this.close_popover(cx);
                this.focus_editor(window, cx);
            }))
            .occlude()
            .rounded(t.z(8.0))
            .border_1()
            .border_color(t.border)
            .bg(t.popover)
            .shadow_lg()
            .overflow_hidden()
            .child(content);
        layers.push(
            deferred(
                anchored().position(position).anchor(corner).snap_to_window_with_margin(t.z(8.0)).child(card),
            )
            .with_priority(1)
            .into_any_element(),
        );
        layers
    }

    /// The model picker: a 44 px column with the agent's mark and the searchable model list,
    /// the current model checked, ⌘1–9 jumps and Return to pick.
    fn render_model_picker(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let Some(option) = composer_option(self, MODEL_CATEGORY) else { return div().into_any_element() };
        let popover = self.popover.as_ref().expect("popover");
        let search = popover.search.clone().expect("model search");
        let highlighted = popover.highlighted;
        let scroll = popover.scroll.clone();
        let query = search.read(cx).value().to_string();
        let (shown, hidden) = shown_models(&option, &query);
        let rows: Vec<AnyElement> =
            shown
                .iter()
                .enumerate()
                .map(|(index, value)| {
                    let current = value.value == option.current_value;
                    let kbd = (index < 9).then(|| keys::command_digit(index + 1));
                    let picked = value.value.clone();
                    list_row(
                        SharedString::from(format!("composer-model-{index}")),
                        value.name.clone(),
                        None,
                        highlighted == Some(index),
                        current,
                        &t,
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.pick(PopoverKind::Model, &picked, window, cx)
                    }))
                    .when_some(model_provider(value).map(str::to_owned), |row, provider| {
                        row.child(
                            div()
                                .font_family(UI_FONT_FAMILY)
                                .text_size(t.z(10.0))
                                .text_color(t.muted)
                                .child(provider),
                        )
                    })
                    .when_some(kbd, |row, kbd| row.child(Keycaps::new([kbd]).small()))
                    .child(check(current, &t))
                    .into_any_element()
                })
                .collect();
        let empty = shown.is_empty();
        div()
            .w(t.z(MODEL_PICKER_WIDTH))
            .flex()
            .child(
                div()
                    .w(t.z(44.0))
                    .flex_none()
                    .bg(t.raised.opacity(0.3))
                    .p(t.z(4.0))
                    .relative()
                    .child(
                        div()
                            .size(t.z(36.0))
                            .rounded(t.z(6.0))
                            .bg(t.foreground.opacity(0.08))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(agent_glyph(20.0, t.foreground, &t)),
                    )
                    .child(
                        div()
                            .absolute()
                            .right(t.z(0.0))
                            .top(t.z(12.0))
                            .w(t.z(3.0))
                            .h(t.z(20.0))
                            .rounded(t.z(1.5))
                            .bg(t.accent),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .border_l_1()
                    .border_color(t.border.opacity(0.7))
                    .bg(t.raised.opacity(0.4))
                    .pb(t.z(4.0))
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(t.z(6.0))
                            .px(t.z(8.0))
                            .border_b_1()
                            .border_color(t.border.opacity(0.7))
                            .child(icon(IconName::Search).size(13.0).color(t.muted))
                            .child(div().flex_1().child(text_input(&search).small())),
                    )
                    .when(empty, |column| {
                        column.child(
                            div().h(t.z(40.0)).flex().items_center().justify_center().child(
                                div()
                                    .font_family(UI_FONT_FAMILY)
                                    .text_size(t.z(text_size::BODY))
                                    .text_color(t.muted)
                                    .child("No models found"),
                            ),
                        )
                    })
                    .when(!empty, |column| {
                        column.child(
                            div()
                                .id("composer-model-list")
                                .mt(t.z(4.0))
                                .px(t.z(8.0))
                                .pt(t.z(2.0))
                                .max_h(t.z(280.0))
                                .overflow_y_scroll()
                                .track_scroll(&scroll)
                                .flex()
                                .flex_col()
                                .gap(t.z(2.0))
                                .children(rows)
                                .when(hidden > 0, |list| {
                                    list.child(
                                        div().min_h(t.z(28.0)).px(t.z(8.0)).flex().items_center().child(
                                            div()
                                                .font_family(UI_FONT_FAMILY)
                                                .text_size(t.z(text_size::BODY))
                                                .text_color(t.muted.opacity(0.6))
                                                .child(format!("{hidden} more — type to search")),
                                        ),
                                    )
                                }),
                        )
                    }),
            )
            .into_any_element()
    }

    /// One setting's choices (thinking level, permission mode): a muted group label over rows
    /// with their descriptions, the current one checked; ↑/↓ and Return pick.
    fn render_option_menu(&mut self, kind: PopoverKind, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let Some(option) = composer_option(self, category(kind)) else { return div().into_any_element() };
        let highlighted = self.popover.as_ref().and_then(|p| p.highlighted);
        div()
            .w(t.z(OPTION_MENU_WIDTH))
            .p(t.z(4.0))
            .flex()
            .flex_col()
            .gap(t.z(2.0))
            .child(
                div()
                    .px(t.z(8.0))
                    .pt(t.z(6.0))
                    .pb(t.z(4.0))
                    .font_family(UI_FONT_FAMILY)
                    .text_size(t.z(text_size::SMALL))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(t.muted)
                    .child(option.name.clone()),
            )
            .children(option.values.iter().enumerate().map(|(index, value)| {
                let current = value.value == option.current_value;
                let picked = value.value.clone();
                list_row(
                    SharedString::from(format!("composer-option-value-{index}")),
                    option_title(&value.name),
                    value.detail.clone(),
                    highlighted == Some(index),
                    current,
                    &t,
                )
                .on_click(cx.listener(move |this, _, window, cx| this.pick(kind, &picked, window, cx)))
                .child(check(current, &t))
            }))
            .into_any_element()
    }

    /// The meter's card: "Context window", a bar, `62.4k of 200k tokens used · 31%`, what
    /// compacting does, and "Compact conversation".
    fn render_context_card(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let reading = self.context_reading();
        let can_compact = self.session.borrow().can_compact();
        let tint = match reading.map(|r| r.level()).unwrap_or(ContextLevel::Normal) {
            ContextLevel::Normal => t.accent,
            ContextLevel::Warning => t.approval,
            ContextLevel::Critical => t.failed,
        };
        let inner = CONTEXT_CARD_WIDTH - 24.0;
        let fraction = reading.map_or(0.0, |r| r.clamped_fraction());
        div()
            .w(t.z(CONTEXT_CARD_WIDTH))
            .p(t.z(12.0))
            .flex()
            .flex_col()
            .child(
                div()
                    .font_family(UI_FONT_FAMILY)
                    .text_size(t.z(text_size::ROW))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(t.foreground)
                    .child("Context window"),
            )
            .child(
                div()
                    .mt(t.z(10.0))
                    .h(t.z(6.0))
                    .w(t.z(inner))
                    .rounded(t.z(3.0))
                    .bg(t.foreground.opacity(0.1))
                    .child(div().h_full().w(t.z(inner * fraction)).rounded(t.z(3.0)).bg(tint)),
            )
            .child(
                div()
                    .mt(t.z(6.0))
                    .font_family(UI_FONT_FAMILY)
                    .text_size(t.z(text_size::SMALL))
                    .text_color(t.muted)
                    .child(
                        reading
                            .map(|r| r.summary())
                            .unwrap_or_else(|| "Context usage is not known yet.".into()),
                    ),
            )
            .child(
                div()
                    .mt(t.z(4.0))
                    .font_family(UI_FONT_FAMILY)
                    .text_size(t.z(text_size::SMALL))
                    .text_color(t.muted)
                    .child("Compacting summarizes earlier messages to free space."),
            )
            .child(
                div().mt(t.z(12.0)).flex().child(
                    Button::new("composer-compact", "Compact conversation")
                        .icon(timeline_icon::MINIMIZE)
                        .size(ButtonSize::Sm)
                        .disabled(!can_compact)
                        .on_click(cx.listener(|this, _, window, cx| this.compact(window, cx))),
                ),
            )
            .into_any_element()
    }
}

/// A row of a composer list (min h28, r4, px8): the current value has a 6 % fill, the
/// highlighted row 9 %.
fn list_row(
    id: SharedString,
    title: String,
    subtitle: Option<String>,
    highlighted: bool,
    current: bool,
    t: &SopranoTheme,
) -> gpui::Stateful<gpui::Div> {
    let fill = if highlighted {
        Some(t.foreground.opacity(0.09))
    } else if current {
        Some(t.foreground.opacity(0.06))
    } else {
        None
    };
    div()
        .id(id)
        .min_h(t.z(28.0))
        .px(t.z(8.0))
        .py(t.z(4.0))
        .rounded(t.z(4.0))
        .flex()
        .items_center()
        .gap(t.z(8.0))
        .cursor_pointer()
        .when_some(fill, |row, fill| row.bg(fill))
        .hover(|s| s.bg(t.foreground.opacity(0.09)))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(t.z(2.0))
                .child(
                    div()
                        .font_family(UI_FONT_FAMILY)
                        .text_size(t.z(text_size::BODY))
                        .text_color(t.foreground)
                        .truncate()
                        .child(title),
                )
                .when_some(subtitle, |texts, subtitle| {
                    texts.child(
                        div()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(t.z(text_size::SMALL))
                            .text_color(t.muted)
                            .line_clamp(3)
                            .child(subtitle),
                    )
                }),
        )
}

fn check(checked: bool, t: &SopranoTheme) -> impl IntoElement {
    div()
        .w(t.z(14.0))
        .flex_none()
        .when(checked, |slot| slot.child(icon(IconName::Check).size(13.0).color(t.foreground)))
}

#[allow(dead_code)]
fn _px(value: f32) -> Pixels {
    px(value)
}
