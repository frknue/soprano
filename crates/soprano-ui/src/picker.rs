//! The picker overlay shared by the command palette and the session/window/project pickers
//! (HERDR-UI.md §11.2/§11.3): a 620 px popup 60 px from the top with an accent search field,
//! grouped rows (group heads while the query is empty, the group name at the right while
//! typing), matched letters in `accent` semibold, keycaps, ↑ ↓ ↵ esc, and click-outside
//! dismiss. Search and ranking port `CommandPaletteSearch` (`Views/CommandPalettePanel.swift`).

use std::ops::Range;

use gpui::{
    App, AppContext as _, Context, DismissEvent, ElementId, Entity, EventEmitter, FocusHandle, Focusable,
    FontWeight, HighlightStyle, InteractiveElement, IntoElement, MouseButton, ParentElement, Render,
    ScrollHandle, SharedString, StatefulInteractiveElement, Styled, StyledText, Subscription, Window,
    anchored, deferred, div, point, prelude::*, px,
};
use gpui_component::input::{self as component_input, InputEvent, InputState};

use crate::controls::{InputSize, TextInput};
use crate::fonts::{self, size};
use crate::icons::{Icon, IconName, icon};
use crate::keycaps::{KeyPlatform, Keycaps};
use crate::motion::fade_in;
use crate::theme::ActiveSopranoTheme;

/// One row (`CommandItem`).
#[derive(Clone)]
pub struct PickerItem {
    pub id: SharedString,
    pub label: SharedString,
    pub description: SharedString,
    /// Rows with the same group sit under one head ("Recent", "Tab", "Pane", …), in the
    /// order given.
    pub group: Option<SharedString>,
    pub icon: Option<Icon>,
    /// K1 keycaps, one per chord step; empty without a shortcut.
    pub keycaps: Vec<String>,
    /// Hidden text the query also matches (a window's pane titles and paths).
    pub search_text: Option<String>,
}

impl PickerItem {
    pub fn new(id: impl Into<SharedString>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            description: SharedString::default(),
            group: None,
            icon: None,
            keycaps: Vec::new(),
            search_text: None,
        }
    }

    pub fn description(mut self, description: impl Into<SharedString>) -> Self {
        self.description = description.into();
        self
    }

    pub fn group(mut self, group: impl Into<SharedString>) -> Self {
        self.group = Some(group.into());
        self
    }

    pub fn icon(mut self, name: IconName) -> Self {
        self.icon = Some(Icon::new(name));
        self
    }

    /// Any icon (a program icon, a status glyph's SVG).
    pub fn with_icon(mut self, glyph: Icon) -> Self {
        self.icon = Some(glyph);
        self
    }

    pub fn keycaps(mut self, caps: Vec<String>) -> Self {
        self.keycaps = caps;
        self
    }

    pub fn search_text(mut self, text: impl Into<String>) -> Self {
        self.search_text = Some(text.into());
        self
    }
}

fn normalized(query: &str) -> String {
    query.trim().to_lowercase()
}

/// The indices of the items matching `query`, best first (`CommandPaletteSearch.filter`):
/// a match in the label beats the description beats the hidden search text; within a field
/// an exact match beats a prefix beats a contained match; then the earlier match; then the
/// original order. An empty query keeps every item in order.
pub fn filter(items: &[PickerItem], query: &str) -> Vec<usize> {
    let needle = normalized(query);
    if needle.is_empty() {
        return (0..items.len()).collect();
    }
    let mut matches: Vec<(usize, usize, usize, usize)> = items
        .iter()
        .enumerate()
        .filter_map(|(index, item)| {
            let fields =
                [item.label.as_ref(), item.description.as_ref(), item.search_text.as_deref().unwrap_or("")];
            fields.iter().enumerate().find_map(|(field_priority, text)| {
                let haystack = text.to_lowercase();
                let byte = haystack.find(&needle)?;
                let offset = haystack[..byte].chars().count();
                let match_priority = if haystack == needle {
                    0
                } else if offset == 0 {
                    1
                } else {
                    2
                };
                Some((field_priority, match_priority, offset, index))
            })
        })
        .collect();
    matches.sort();
    matches.into_iter().map(|(_, _, _, index)| index).collect()
}

/// The byte range of the first case-insensitive occurrence of `query` (trimmed) in `text`:
/// the characters a row draws in `accent` semibold. None for an empty query or no match.
pub fn match_range(text: &str, query: &str) -> Option<Range<usize>> {
    let needle: Vec<char> = query.trim().chars().flat_map(char::to_lowercase).collect();
    if needle.is_empty() {
        return None;
    }
    let lowered: Vec<(usize, char)> =
        text.char_indices().flat_map(|(byte, c)| c.to_lowercase().map(move |l| (byte, l))).collect();
    let start =
        lowered.windows(needle.len()).position(|w| w.iter().map(|(_, c)| *c).eq(needle.iter().copied()))?;
    let first = lowered[start].0;
    let last = lowered[start + needle.len() - 1].0;
    let end = last + text[last..].chars().next().map_or(0, char::len_utf8);
    Some(first..end)
}

/// A row of the list: a group head or an item (its index into the filtered results).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PickerRow {
    Head(SharedString),
    Item(usize),
}

/// The picker's state without a window: items, query, results and the keyboard selection.
#[derive(Clone)]
pub struct PickerState {
    items: Vec<PickerItem>,
    query: String,
    results: Vec<usize>,
    selected: usize,
}

impl PickerState {
    pub fn new(items: Vec<PickerItem>) -> Self {
        let results = (0..items.len()).collect();
        Self { items, query: String::new(), results, selected: 0 }
    }

    pub fn items(&self) -> &[PickerItem] {
        &self.items
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    /// Filters for `query` and selects the first result.
    pub fn set_query(&mut self, query: &str) {
        self.query = query.to_owned();
        self.results = filter(&self.items, query);
        self.selected = 0;
    }

    pub fn set_items(&mut self, items: Vec<PickerItem>) {
        self.items = items;
        let query = self.query.clone();
        self.set_query(&query);
    }

    /// The matching items, best first.
    pub fn results(&self) -> impl Iterator<Item = &PickerItem> {
        self.results.iter().map(|&i| &self.items[i])
    }

    pub fn result_count(&self) -> usize {
        self.results.len()
    }

    pub fn selected_index(&self) -> usize {
        self.selected
    }

    /// Moves the selection, stopping at either end.
    pub fn move_selection(&mut self, delta: isize) {
        if self.results.is_empty() {
            return;
        }
        let last = self.results.len() as isize - 1;
        self.selected = (self.selected as isize + delta).clamp(0, last) as usize;
    }

    pub fn select(&mut self, index: usize) {
        if index < self.results.len() {
            self.selected = index;
        }
    }

    pub fn selected_item(&self) -> Option<&PickerItem> {
        self.results.get(self.selected).map(|&i| &self.items[i])
    }

    /// The list rows: with an empty query, a head before each run of one group; while
    /// typing, the ranked results alone.
    pub fn rows(&self) -> Vec<PickerRow> {
        let grouped = normalized(&self.query).is_empty();
        let mut rows = Vec::with_capacity(self.results.len() + 4);
        let mut group: Option<&SharedString> = None;
        for (position, &index) in self.results.iter().enumerate() {
            if grouped
                && let Some(item_group) = &self.items[index].group
                && group != Some(item_group)
            {
                rows.push(PickerRow::Head(item_group.clone()));
                group = Some(item_group);
            }
            rows.push(PickerRow::Item(position));
        }
        rows
    }
}

/// What the picker reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PickerEvent {
    /// A row was chosen (Return or a click) under `query`.
    Confirmed { id: SharedString, query: String },
    /// Closed without a choice (Esc, a click outside).
    Dismissed,
}

/// The picker overlay. Render the entity in the window root; it emits [`PickerEvent`] and then
/// [`DismissEvent`] once.
pub struct Picker {
    state: PickerState,
    input: Entity<InputState>,
    title: Option<SharedString>,
    search_keycaps: Vec<String>,
    width: f32,
    top: f32,
    scroll: ScrollHandle,
    closed: bool,
    previous_focus: Option<FocusHandle>,
    _subscription: Subscription,
}

impl EventEmitter<PickerEvent> for Picker {}
impl EventEmitter<DismissEvent> for Picker {}

impl Focusable for Picker {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.input.read(cx).focus_handle(cx)
    }
}

/// Rows visible before the list scrolls.
pub const VISIBLE_ROWS: usize = 10;
pub const ROW_HEIGHT: f32 = 32.0;
pub const HEAD_HEIGHT: f32 = 26.0;

impl Picker {
    /// The command palette: 620 wide, 60 from the top, "Type a command…".
    pub fn new(items: Vec<PickerItem>, window: &mut Window, cx: &mut App) -> Entity<Self> {
        let previous_focus = window.focused(cx);
        cx.new(|cx| {
            let input = cx.new(|cx| InputState::new(window, cx).placeholder("Type a command…"));
            let subscription =
                cx.subscribe_in(&input, window, |this: &mut Self, input, event: &InputEvent, window, cx| {
                    match event {
                        InputEvent::Change => {
                            let query = input.read(cx).value().to_string();
                            this.state.set_query(&query);
                            this.scroll.scroll_to_item(0);
                            cx.notify();
                        }
                        InputEvent::PressEnter { .. } => this.confirm(window, cx),
                        _ => {}
                    }
                });
            input.update(cx, |state, cx| state.focus(window, cx));
            Self {
                state: PickerState::new(items),
                input,
                title: None,
                search_keycaps: Vec::new(),
                width: 620.0,
                top: 60.0,
                scroll: ScrollHandle::new(),
                closed: false,
                previous_focus,
                _subscription: subscription,
            }
        })
    }

    pub fn set_placeholder(
        &mut self,
        placeholder: impl Into<SharedString>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let placeholder = placeholder.into();
        self.input.update(cx, |state, cx| state.set_placeholder(placeholder, window, cx));
    }

    /// A title row ("Go to…") with an Esc chip, as the Go-to picker shows.
    pub fn set_title(&mut self, title: impl Into<SharedString>) {
        self.title = Some(title.into());
    }

    /// The caps of the shortcut that opened the picker, at the end of the search field.
    pub fn set_search_keycaps(&mut self, caps: Vec<String>) {
        self.search_keycaps = caps;
    }

    /// Width and top offset in designed px (palette 620/60, Go-to picker 640/40).
    pub fn set_frame(&mut self, width: f32, top: f32) {
        self.width = width;
        self.top = top;
    }

    pub fn set_items(&mut self, items: Vec<PickerItem>, cx: &mut Context<Self>) {
        self.state.set_items(items);
        cx.notify();
    }

    pub fn state(&self) -> &PickerState {
        &self.state
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        self.state.move_selection(delta);
        let selected = self.state.selected_index();
        if let Some(row) = self.state.rows().iter().position(|row| *row == PickerRow::Item(selected)) {
            self.scroll.scroll_to_item(row);
        }
        cx.notify();
    }

    /// Runs the selected row.
    pub fn confirm(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(item) = self.state.selected_item() else { return };
        let event = PickerEvent::Confirmed { id: item.id.clone(), query: self.state.query().to_owned() };
        self.close(event, window, cx);
    }

    /// Closes without a choice.
    pub fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.close(PickerEvent::Dismissed, window, cx);
    }

    fn close(&mut self, event: PickerEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.closed {
            return;
        }
        self.closed = true;
        if let Some(previous) = self.previous_focus.take() {
            previous.focus(window, cx);
        }
        cx.emit(event);
        cx.emit(DismissEvent);
        cx.notify();
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    fn render_row(&self, position: usize, cx: &mut Context<Self>) -> gpui::AnyElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let item = &self.state.items[self.state.results[position]];
        let selected = position == self.state.selected_index();
        let typing = !normalized(self.state.query()).is_empty();
        let title_color = if selected { theme.foreground } else { theme.muted };
        let highlights = match_range(&item.label, self.state.query())
            .map(|range| {
                (
                    range,
                    HighlightStyle {
                        color: Some(theme.accent),
                        font_weight: Some(FontWeight::SEMIBOLD),
                        ..Default::default()
                    },
                )
            })
            .into_iter();
        let title = StyledText::new(item.label.clone()).with_highlights(highlights);
        let hover = theme.hover;
        div()
            .id(ElementId::NamedInteger("picker-row".into(), position as u64))
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(z(10.))
            .h(z(ROW_HEIGHT))
            .mx(z(6.))
            .px(z(10.))
            .rounded(z(7.))
            .text_size(z(size::ROW))
            .text_color(title_color)
            .cursor_pointer()
            .map(|row| if selected { row.bg(theme.selected) } else { row.hover(move |s| s.bg(hover)) })
            .when_some(item.icon.clone(), |row, glyph| {
                row.child(glyph.size(14.).color(if selected { theme.foreground } else { theme.muted }))
            })
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_1()
                    .min_w_0()
                    .items_baseline()
                    .gap(z(8.))
                    .child(div().flex_none().max_w(gpui::relative(0.7)).truncate().child(title))
                    .when(!item.description.is_empty(), |text| {
                        text.child(
                            div()
                                .min_w_0()
                                .truncate()
                                .text_size(z(size::SMALL))
                                .text_color(theme.dim)
                                .child(item.description.clone()),
                        )
                    }),
            )
            .when_some(item.group.clone().filter(|_| typing), |row, group| {
                row.child(div().flex_none().text_size(z(size::SECTION)).text_color(theme.dim).child(group))
            })
            .when(!item.keycaps.is_empty(), |row| row.child(Keycaps::new(item.keycaps.clone())))
            .on_click(cx.listener(move |this, _, window, cx| {
                this.state.select(position);
                this.confirm(window, cx);
            }))
            .into_any_element()
    }
}

impl Render for Picker {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.closed {
            return div().into_any_element();
        }
        let rows: Vec<gpui::AnyElement> = self
            .state
            .rows()
            .into_iter()
            .map(|row| match row {
                PickerRow::Head(group) => {
                    let theme = cx.soprano_theme();
                    div()
                        .flex()
                        .flex_none()
                        .items_end()
                        .h(theme.z(HEAD_HEIGHT))
                        .px(theme.z(14.))
                        .pb(theme.z(4.))
                        .text_size(theme.z(size::SMALL))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(theme.dim)
                        .child(group)
                        .into_any_element()
                }
                PickerRow::Item(position) => self.render_row(position, cx),
            })
            .collect();
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let empty = rows.is_empty();
        let search_icon = if KeyPlatform::current() == KeyPlatform::Mac {
            icon(IconName::Command).size(16.).color(theme.dim)
        } else {
            icon(IconName::Search).size(15.).color(theme.dim)
        };
        let trailing = if self.search_keycaps.is_empty() {
            div().text_size(z(size::SMALL)).text_color(theme.dim).child("Esc").into_any_element()
        } else {
            Keycaps::new(self.search_keycaps.clone()).into_any_element()
        };
        let width = z(self.width);
        let viewport = window.viewport_size();
        let origin = point(((viewport.width - width) / 2.).max(px(8.)), z(self.top));
        let surface = div()
            .id("soprano-picker")
            .flex()
            .flex_col()
            .gap(z(10.))
            .w(width)
            .max_h(viewport.height * 0.85)
            .p(z(18.))
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded(z(8.))
            .shadow_lg()
            .font_family(fonts::UI_FONT_FAMILY)
            .text_size(z(size::UI))
            .text_color(theme.foreground)
            .key_context("SopranoPicker")
            .capture_action(cx.listener(|this, _: &component_input::MoveUp, _, cx| {
                cx.stop_propagation();
                this.move_selection(-1, cx);
            }))
            .capture_action(cx.listener(|this, _: &component_input::MoveDown, _, cx| {
                cx.stop_propagation();
                this.move_selection(1, cx);
            }))
            .on_action(cx.listener(|this, _: &component_input::Escape, window, cx| this.dismiss(window, cx)))
            .on_mouse_down_out(cx.listener(|this, _, window, cx| this.dismiss(window, cx)))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .when_some(self.title.clone(), |surface, title| {
                surface.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .child(
                            div()
                                .text_size(z(size::DIALOG_TITLE))
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(title),
                        )
                        .child(
                            div()
                                .id("soprano-picker-esc")
                                .px(z(6.))
                                .py(z(2.))
                                .rounded(z(5.))
                                .text_size(z(size::SMALL))
                                .text_color(theme.dim)
                                .cursor_pointer()
                                .hover(|s| s.bg(theme.hover).text_color(theme.foreground))
                                .child("Esc")
                                .on_click(cx.listener(|this, _, window, cx| this.dismiss(window, cx))),
                        ),
                )
            })
            .child(
                TextInput::new(&self.input)
                    .size(InputSize::Large)
                    .accent()
                    .prefix(search_icon)
                    .suffix(trailing),
            )
            .child(if empty {
                div()
                    .px(z(16.))
                    .py(z(14.))
                    .text_color(theme.dim)
                    .child("No matching results")
                    .into_any_element()
            } else {
                div()
                    .id("soprano-picker-rows")
                    .flex()
                    .flex_col()
                    .max_h(z(ROW_HEIGHT * VISIBLE_ROWS as f32))
                    .mx(z(-12.))
                    .mb(z(6.))
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .children(rows)
                    .into_any_element()
            });
        deferred(anchored().position(origin).child(fade_in(surface, "soprano-picker-fade", cx)))
            .with_priority(2)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, label: &str, search_text: Option<&str>) -> PickerItem {
        let item = PickerItem::new(id.to_owned(), label.to_owned());
        match search_text {
            Some(text) => item.search_text(text),
            None => item,
        }
    }

    fn ids(items: &[PickerItem], query: &str) -> Vec<String> {
        filter(items, query).into_iter().map(|i| items[i].id.to_string()).collect()
    }

    #[test]
    fn window_title_matches_rank_above_matches_inside_split_panes() {
        let items = [
            item("backend", "Backend", Some("Soprano terminal")),
            item("soprano", "Soprano", Some("Backend terminal")),
        ];
        assert_eq!(ids(&items, "soprano"), ["soprano", "backend"]);
    }

    #[test]
    fn hidden_pane_metadata_can_find_its_containing_window() {
        let items = [item("agents", "Agents", Some("Claude /Users/example/projects/soprano"))];
        assert_eq!(ids(&items, "soprano"), ["agents"]);
    }

    #[test]
    fn an_empty_query_preserves_window_order() {
        let items = [item("second", "Second", None), item("first", "First", None)];
        assert_eq!(ids(&items, "  "), ["second", "first"]);
    }

    #[test]
    fn exact_then_prefix_then_contained_then_earlier_matches_rank_first() {
        let items = [
            item("contains", "Reopen", None),
            item("prefix", "Open in Git", None),
            item("exact", "open", None),
            item("description", "Other", None).description("open the thing"),
        ];
        assert_eq!(ids(&items, "OPEN"), ["exact", "prefix", "contains", "description"]);
    }

    #[test]
    fn the_matched_title_range_ignores_case_and_surrounding_whitespace() {
        let label = "Open in Soprano Git";
        let range = match_range(label, "  OPEN ").expect("match");
        assert_eq!(&label[range], "Open");
        let range = match_range("Café Über", "über").expect("match");
        assert_eq!(&"Café Über"[range], "Über");
    }

    #[test]
    fn a_title_without_the_query_has_no_matched_range() {
        assert_eq!(match_range("omp web", "open"), None);
        assert_eq!(match_range("omp web", " "), None);
    }

    #[test]
    fn a_command_without_a_shortcut_has_no_keycaps() {
        assert!(item("plain", "Plain", None).keycaps.is_empty());
    }

    #[test]
    fn groups_show_heads_only_while_the_query_is_empty() {
        let items = vec![
            item("a", "New tab", None).group("Recent"),
            item("b", "Split right", None).group("Pane"),
            item("c", "Split down", None).group("Pane"),
        ];
        let mut state = PickerState::new(items);
        assert_eq!(
            state.rows(),
            [
                PickerRow::Head("Recent".into()),
                PickerRow::Item(0),
                PickerRow::Head("Pane".into()),
                PickerRow::Item(1),
                PickerRow::Item(2)
            ]
        );
        state.set_query("split");
        assert_eq!(state.rows(), [PickerRow::Item(0), PickerRow::Item(1)]);
    }

    #[test]
    fn the_selection_stays_within_the_results_and_resets_on_a_new_query() {
        let mut state = PickerState::new(vec![item("a", "Alpha", None), item("b", "Beta", None)]);
        state.move_selection(-1);
        assert_eq!(state.selected_index(), 0);
        state.move_selection(5);
        assert_eq!(state.selected_item().map(|i| i.id.as_ref()), Some("b"));
        state.set_query("alp");
        assert_eq!(state.selected_index(), 0);
        state.set_query("zzz");
        assert!(state.selected_item().is_none());
        state.move_selection(1);
        assert_eq!(state.selected_index(), 0);
    }

    mod window {
        use super::super::*;
        use gpui::{Modifiers, TestAppContext, VisualTestContext, point, px, size};
        use std::cell::RefCell;
        use std::rc::Rc;

        struct Host {
            picker: Entity<Picker>,
        }

        impl Render for Host {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                div().size_full().child(self.picker.clone())
            }
        }

        fn setup(
            cx: &mut TestAppContext,
        ) -> (Entity<Picker>, Rc<RefCell<Vec<PickerEvent>>>, &mut VisualTestContext) {
            cx.update(crate::init_for_tests);
            let (host, cx) = cx.add_window_view(|window, cx| Host {
                picker: Picker::new(
                    vec![
                        PickerItem::new("one", "Open Terminal").description("Open a new terminal pane"),
                        PickerItem::new("two", "Split Right"),
                    ],
                    window,
                    cx,
                ),
            });
            cx.simulate_resize(size(px(1200.), px(800.)));
            let picker = host.read_with(cx, |host, _| host.picker.clone());
            let events = Rc::new(RefCell::new(Vec::new()));
            let sink = events.clone();
            cx.update(|_, cx| {
                cx.subscribe(&picker, move |_, event: &PickerEvent, _| sink.borrow_mut().push(event.clone()))
                    .detach()
            });
            cx.run_until_parked();
            (picker, events, cx)
        }

        #[gpui::test]
        fn a_click_outside_the_surface_closes_the_picker(cx: &mut TestAppContext) {
            let (_, events, cx) = setup(cx);
            cx.simulate_click(point(px(20.), px(700.)), Modifiers::default());
            assert_eq!(*events.borrow(), [PickerEvent::Dismissed]);
        }

        #[gpui::test]
        fn a_click_on_the_surface_keeps_it_open(cx: &mut TestAppContext) {
            let (picker, events, cx) = setup(cx);
            // Just inside the surface's top padding, centered.
            cx.simulate_click(point(px(600.), px(66.)), Modifiers::default());
            assert!(events.borrow().is_empty());
            assert!(cx.update(|_, cx| !picker.read(cx).is_closed()));
        }

        #[gpui::test]
        fn arrows_move_and_return_confirms_with_the_query(cx: &mut TestAppContext) {
            let (_, events, cx) = setup(cx);
            cx.simulate_keystrokes("down");
            cx.simulate_keystrokes("enter");
            assert_eq!(*events.borrow(), [PickerEvent::Confirmed { id: "two".into(), query: String::new() }]);
        }

        #[gpui::test]
        fn escape_dismisses(cx: &mut TestAppContext) {
            let (_, events, cx) = setup(cx);
            cx.simulate_keystrokes("escape");
            assert_eq!(*events.borrow(), [PickerEvent::Dismissed]);
        }
    }
}
