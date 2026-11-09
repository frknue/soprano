//! One file's git diff, read-only (port of `Views/DiffPaneView.swift` with the rows of
//! `Views/Surfaces/SurfaceDiffRows.swift`): a subheader with the scope ("Changes" / "Staged
//! changes"), `+N -N`, previous/next change (⇧F7 / F7), the stacked | split toggle (remembered
//! in `soprano-diff-side-by-side`), line wrapping and Open File; the file's sticky header with
//! its path, Copy path and counts; the changes with three lines of context, longer unmodified
//! runs folded behind "N unmodified lines" strips that open on a click. Lines select by
//! pressing and dragging (⇧-click extends); ⌘C copies them, ⌘A selects all, Esc clears, a
//! right click offers Copy / Copy Line / Copy File Path. The diff reloads when the file or
//! git's state changes, and when the app becomes active again.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use gpui::{
    AnyElement, App, ClipboardItem, Context, Entity, EventEmitter, FocusHandle, Focusable,
    InteractiveElement, IntoElement, KeyBinding, ListAlignment, ListOffset, ListState, MouseButton,
    MouseDownEvent, ParentElement, Pixels, Point, Render, ScrollEvent, SharedString,
    StatefulInteractiveElement, Styled, Subscription, Task, Window, actions, div, list,
    prelude::FluentBuilder, px,
};
use soprano_files::watcher::{DEFAULT_LATENCY, FileSystemWatcher};
use soprano_git::changes::GitDiffRowKind;
use soprano_platform::state::StateStore;
use soprano_text::diff::{
    DiffContent, DiffDocument, DiffFold, DiffList, DiffListLayout, DiffListRow, DiffLoadResult, DiffLocation,
    DiffSelection, DiffSide, END_HEIGHT, FileChange, HEADER_HEIGHT, LINE_HEIGHT, LOADING_MESSAGE,
    LOADING_MESSAGE_DELAY_MS, RELOAD_DELAY_MS, SIDE_BY_SIDE_STATE_KEY, SUBHEADER_HEIGHT, code_width,
    load_diff,
};
use soprano_ui::button::IconButton;
use soprano_ui::fonts::size;
use soprano_ui::menu::{ContextMenu, MenuItem};
use soprano_ui::{ActiveSopranoTheme, IconName, icon};

use crate::colors::SurfaceColors;
use crate::rich::diff::{
    DIFF_FONT_SIZE, DiffFoldRow, DiffLineRow, DiffRowLayout, DiffSplitRow, DiffStat, digit_width,
};
use crate::surface::{SurfaceMessage, toolbar_button};

/// The key context of a diff view.
pub const DIFF_CONTEXT: &str = "SopranoDiff";

/// Line wrapping, app-wide for the session (Agents' `DiffViewOptions.wrap`, on by default).
static WRAPS_LINES: AtomicBool = AtomicBool::new(true);

actions!(
    soprano_diff,
    [
        /// F7: the next change.
        NextChange,
        /// ⇧F7: the previous change.
        PreviousChange,
        /// ⌘C: the selected lines.
        CopyLines,
        /// ⌘A: every line.
        SelectAllLines,
        /// Esc: drop the selection.
        ClearSelection,
    ]
);

/// The diff view's key bindings; the app binds them once (`cx.bind_keys(key_bindings(cx))`).
pub fn key_bindings(cx: &App) -> Vec<KeyBinding> {
    let table: [(&str, Box<dyn gpui::Action>); 5] = [
        ("f7", Box::new(NextChange)),
        ("shift-f7", Box::new(PreviousChange)),
        ("secondary-c", Box::new(CopyLines)),
        ("secondary-a", Box::new(SelectAllLines)),
        ("escape", Box::new(ClearSelection)),
    ];
    table.into_iter().filter_map(|(keys, action)| crate::keys::bind(keys, action, DIFF_CONTEXT, cx)).collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiffEvent {
    /// Open File: show the working-tree file in the editor.
    OpenFile(PathBuf),
    /// The view was clicked or took the keyboard: focus its pane.
    FocusRequested,
}

/// The subheader's scope pill.
pub fn scope_title(staged: bool) -> &'static str {
    if staged { "Staged changes" } else { "Changes" }
}

pub struct DiffView {
    file: PathBuf,
    staged: bool,
    state: StateStore,
    focus: FocusHandle,
    document: Option<Box<DiffDocument>>,
    list: DiffList,
    layout: DiffListLayout,
    collapsed: bool,
    expanded: HashSet<isize>,
    selection: Option<DiffSelection>,
    message: Option<String>,
    file_exists: bool,
    location: Option<DiffLocation>,
    external_git_directory: Option<PathBuf>,
    /// The listening task drops before the watcher (tuple fields drop in order).
    watcher: Option<(Task<()>, FileSystemWatcher)>,
    shown: bool,
    was_hidden: bool,
    has_loaded: bool,
    load_generation: u64,
    load_in_flight: bool,
    reload_pending: bool,
    reload_task: Option<Task<()>>,
    list_state: ListState,
    text_offset: f32,
    number_width: f32,
    path_copied: Option<Task<()>>,
    menu: Option<(Entity<ContextMenu>, Subscription)>,
    dragging: bool,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<DiffEvent> for DiffView {}

impl Focusable for DiffView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl DiffView {
    /// The diff of `file`, staged or in the working tree. The layout starts as the last one
    /// chosen (`soprano-diff-side-by-side` in `state`).
    pub fn new(
        file: impl Into<PathBuf>,
        staged: bool,
        state: StateStore,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let file = file.into();
        let layout = if state.get::<bool>(SIDE_BY_SIDE_STATE_KEY).unwrap_or(false) {
            DiffListLayout::Split
        } else {
            DiffListLayout::Unified
        };
        let activation = cx.observe_window_activation(window, |this: &mut Self, window, cx| {
            if window.is_window_active() && this.shown && this.has_loaded {
                this.schedule_reload(true, cx);
            }
        });
        let file_exists = file.exists();
        let mut view = Self {
            file,
            staged,
            state,
            focus: cx.focus_handle(),
            document: None,
            list: DiffList::default(),
            layout,
            collapsed: false,
            expanded: HashSet::new(),
            selection: None,
            message: None,
            file_exists,
            location: None,
            external_git_directory: None,
            watcher: None,
            shown: true,
            was_hidden: false,
            has_loaded: false,
            load_generation: 0,
            load_in_flight: false,
            reload_pending: false,
            reload_task: None,
            list_state: ListState::new(0, ListAlignment::Top, px(400.0)),
            text_offset: 0.0,
            number_width: 40.0,
            path_copied: None,
            menu: None,
            dragging: false,
            _subscriptions: vec![activation],
        };
        view.load(cx);
        view
    }

    pub fn file(&self) -> &Path {
        &self.file
    }

    pub fn staged(&self) -> bool {
        self.staged
    }

    pub fn layout(&self) -> DiffListLayout {
        self.layout
    }

    pub fn document(&self) -> Option<&DiffDocument> {
        self.document.as_deref()
    }

    pub fn list(&self) -> &DiffList {
        &self.list
    }

    /// The note shown instead of lines ("No changes", "Binary file changed…", …).
    pub fn message(&self) -> Option<&str> {
        self.message.as_deref()
    }

    pub fn selection(&self) -> Option<DiffSelection> {
        self.selection
    }

    /// Inactive tabs stop watching and catch up when shown again (Swift's window moves).
    pub fn set_shown(&mut self, shown: bool, cx: &mut Context<Self>) {
        if shown == self.shown {
            return;
        }
        self.shown = shown;
        if !shown {
            self.watcher = None;
            self.was_hidden = true;
            return;
        }
        self.start_watching(cx);
        if std::mem::take(&mut self.was_hidden) {
            self.schedule_reload(true, cx);
        }
    }

    // MARK: - Loading

    /// Reloads after a quiet spell, never with two reads in flight.
    fn schedule_reload(&mut self, immediately: bool, cx: &mut Context<Self>) {
        if self.load_in_flight {
            self.reload_pending = true;
            return;
        }
        self.reload_task = Some(cx.spawn(async move |this, cx| {
            if !immediately {
                cx.background_executor().timer(Duration::from_millis(RELOAD_DELAY_MS)).await;
            }
            let _ = this.update(cx, |this, cx| {
                this.reload_task = None;
                this.load(cx);
            });
        }));
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        if self.load_in_flight {
            self.reload_pending = true;
            return;
        }
        self.load_in_flight = true;
        self.load_generation += 1;
        let generation = self.load_generation;
        let (path, staged) = (soprano_platform::paths::normalize(&self.file), self.staged);
        if !self.has_loaded {
            // A quick first read shows the diff straight away; a slow one says so.
            cx.spawn(async move |this, cx| {
                cx.background_executor().timer(Duration::from_millis(LOADING_MESSAGE_DELAY_MS)).await;
                let _ = this.update(cx, |this, cx| {
                    if !this.has_loaded && this.load_in_flight {
                        this.message = Some(LOADING_MESSAGE.into());
                        cx.notify();
                    }
                });
            })
            .detach();
        }
        cx.spawn(async move |this, cx| {
            let result = cx.background_executor().spawn(async move { load_diff(&path, staged) }).await;
            let _ = this.update(cx, |this, cx| this.finish_load(result, generation, cx));
        })
        .detach();
    }

    fn finish_load(&mut self, result: DiffLoadResult, generation: u64, cx: &mut Context<Self>) {
        self.load_in_flight = false;
        if generation != self.load_generation {
            return;
        }
        self.has_loaded = true;
        self.file_exists = result.file_exists;
        self.update_location(result.location, cx);
        match result.content {
            DiffContent::Message(text) => {
                self.document = None;
                self.list = DiffList::default();
                self.message = Some(text);
                self.list_state.reset(0);
            }
            DiffContent::Text(document) => {
                self.message = None;
                let changed = self
                    .document
                    .as_ref()
                    .is_none_or(|current| current.lines != document.lines || current.path != document.path);
                if changed {
                    let keep = self.document.is_some().then(|| self.list_state.logical_scroll_top());
                    self.document = Some(document);
                    self.rebuild_list();
                    if let Some(top) = keep {
                        self.list_state.scroll_to(top);
                    }
                }
            }
        }
        cx.notify();
        if std::mem::take(&mut self.reload_pending) {
            self.schedule_reload(false, cx);
        }
    }

    fn rebuild_list(&mut self) {
        self.list = self
            .document
            .as_deref()
            .map(|document| DiffList::build(document, self.layout, self.collapsed, &self.expanded))
            .unwrap_or_default();
        self.selection = None;
        self.list_state.reset(self.list.rows.len());
    }

    // MARK: - Watching

    fn update_location(&mut self, location: Option<DiffLocation>, cx: &mut Context<Self>) {
        if location == self.location {
            return;
        }
        self.external_git_directory = location
            .as_ref()
            .and_then(|location| soprano_files::root::external_git_directory(&location.root));
        self.location = location;
        self.watcher = None;
        if self.shown {
            self.start_watching(cx);
        }
    }

    fn start_watching(&mut self, cx: &mut Context<Self>) {
        if self.watcher.is_some() {
            return;
        }
        let Some(location) = self.location.clone() else { return };
        let external = self.external_git_directory.clone();
        let (sender, receiver) = async_channel::unbounded::<(Vec<PathBuf>, bool)>();
        let Some(watcher) = FileSystemWatcher::new(
            location.watched_paths(external.as_deref()),
            DEFAULT_LATENCY,
            move |paths, needs_rescan| {
                let _ = sender.try_send((paths, needs_rescan));
            },
        ) else {
            return;
        };
        let task = cx.spawn(async move |this, cx| {
            while let Ok((paths, needs_rescan)) = receiver.recv().await {
                // Only the file itself and git's own state can change its diff.
                let relevant = location.needs_reload(&paths, needs_rescan, external.as_deref());
                if relevant && this.update(cx, |this, cx| this.schedule_reload(false, cx)).is_err() {
                    break;
                }
            }
        });
        self.watcher = Some((task, watcher));
    }

    // MARK: - Selection

    /// Whether an x in the list falls on the old (left) side of a split row.
    fn is_old_side(&self, x: Pixels) -> bool {
        let bounds = self.list_state.viewport_bounds();
        self.layout == DiffListLayout::Split && x < bounds.left() + (bounds.size.width / 2.0).floor()
    }

    /// A press on a line: selects it, or with ⇧ extends the selection to it.
    pub fn begin_selection(&mut self, row: usize, old_side: bool, extending: bool, cx: &mut Context<Self>) {
        let next = match self.selection {
            Some(mut current) if extending => {
                current.head = row;
                current
            }
            _ => DiffSelection { anchor: row, head: row, old_side },
        };
        self.set_selection(Some(next), cx);
    }

    pub fn extend_selection(&mut self, row: usize, cx: &mut Context<Self>) {
        if let Some(mut current) = self.selection
            && row < self.list.rows.len()
        {
            current.head = row;
            self.set_selection(Some(current), cx);
        }
    }

    fn set_selection(&mut self, selection: Option<DiffSelection>, cx: &mut Context<Self>) {
        if selection != self.selection {
            self.selection = selection;
            cx.notify();
        }
    }

    /// The selected lines as the file has them, one per line.
    pub fn selected_text(&self) -> Option<String> {
        let (selection, document) = (self.selection?, self.document.as_deref()?);
        Some(self.list.text(&selection, document))
    }

    fn copy_lines(&mut self, _: &CopyLines, _: &mut Window, cx: &mut Context<Self>) {
        if let Some(text) = self.selected_text().filter(|text| !text.is_empty()) {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn select_all_lines(&mut self, _: &SelectAllLines, _: &mut Window, cx: &mut Context<Self>) {
        let old_side = self.selection.is_some_and(|selection| selection.old_side);
        let selection = self.list.select_all(old_side);
        self.set_selection(selection, cx);
    }

    fn clear_selection(&mut self, _: &ClearSelection, _: &mut Window, cx: &mut Context<Self>) {
        if self.selected_text().is_some_and(|text| !text.is_empty()) {
            self.set_selection(None, cx);
        } else {
            cx.propagate();
        }
    }

    /// Right click: Copy (with a selection), Copy Line (the clicked line, on the clicked
    /// side), Copy File Path.
    fn context_menu(
        &mut self,
        row: usize,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(document) = self.document.as_deref() else { return };
        let mut items = Vec::new();
        if let Some(text) = self.selected_text().filter(|text| !text.is_empty()) {
            items.push(
                MenuItem::new("Copy")
                    .on_select(move |_, cx| cx.write_to_clipboard(ClipboardItem::new_string(text.clone()))),
            );
        }
        let line = self.list.line(row, self.is_old_side(position.x), document).map(|line| line.text.clone());
        items.push(MenuItem::new("Copy Line").disabled(line.is_none()).on_select(move |_, cx| {
            if let Some(line) = &line {
                cx.write_to_clipboard(ClipboardItem::new_string(line.clone()));
            }
        }));
        let path = self.file.to_string_lossy().into_owned();
        items.push(
            MenuItem::new("Copy File Path")
                .on_select(move |_, cx| cx.write_to_clipboard(ClipboardItem::new_string(path.clone()))),
        );
        let menu = ContextMenu::new(position, items, window, cx);
        let subscription = cx.subscribe(&menu, |this: &mut Self, _, _: &gpui::DismissEvent, cx| {
            this.menu = None;
            cx.notify();
        });
        self.menu = Some((menu, subscription));
        cx.notify();
    }

    // MARK: - Navigation

    /// The list row at window y, from what the list laid out last.
    fn row_at(&self, y: Pixels) -> Option<usize> {
        let top = self.list_state.logical_scroll_top().item_ix;
        (top..self.list.rows.len())
            .map_while(|ix| self.list_state.bounds_for_item(ix).map(|bounds| (ix, bounds)))
            .find(|(_, bounds)| bounds.top() <= y && y < bounds.bottom())
            .map(|(ix, _)| ix)
    }

    /// The list row a third of the way down the visible area, where change navigation reads
    /// from and puts its target.
    fn anchor_row(&self) -> usize {
        let viewport = self.list_state.viewport_bounds();
        let y = viewport.top() + viewport.size.height / 3.0;
        self.row_at(y).unwrap_or_else(|| {
            if self.list_state.logical_scroll_top().item_ix > 0 { self.list.rows.len() } else { 0 }
        })
    }

    /// Moves to the next or previous change relative to the row a third of the way down.
    pub fn navigate(&mut self, forward: bool, cx: &mut Context<Self>) {
        if self.document.is_none() || self.list.change_rows.is_empty() {
            return;
        }
        let anchor = self.anchor_row();
        let target = if forward { self.list.next_change(anchor) } else { self.list.previous_change(anchor) };
        let Some(target) = target else { return };
        self.scroll_to_row(target, self.list_state.viewport_bounds().size.height / 3.0);
        cx.notify();
    }

    /// Scrolls so `row` sits `above` below the top of the list.
    fn scroll_to_row(&self, row: usize, above: Pixels) {
        let mut remaining = above;
        let mut ix = row;
        while ix > 0 && remaining > px(0.0) {
            let height =
                self.list_state.bounds_for_item(ix - 1).map_or(px(LINE_HEIGHT), |bounds| bounds.size.height);
            if height > remaining {
                break;
            }
            remaining -= height;
            ix -= 1;
        }
        self.list_state.scroll_to(ListOffset { item_ix: ix, offset_in_item: px(0.0) });
    }

    fn next_change(&mut self, _: &NextChange, _: &mut Window, cx: &mut Context<Self>) {
        self.navigate(true, cx);
    }

    fn previous_change(&mut self, _: &PreviousChange, _: &mut Window, cx: &mut Context<Self>) {
        self.navigate(false, cx);
    }

    /// Runs `change` and scrolls back to the file line that was at the top.
    fn preserving_top_line(&mut self, change: impl FnOnce(&mut Self)) {
        let top = self.list_state.logical_scroll_top().item_ix;
        let line = self.document.as_deref().and_then(|document| {
            (top..self.list.rows.len()).find_map(|row| self.list.anchor_line(row, document))
        });
        change(self);
        if let (Some(line), Some(document)) = (line, self.document.as_deref())
            && let Some(row) = self.list.row_for_line(line, document)
        {
            self.list_state.scroll_to(ListOffset { item_ix: row, offset_in_item: px(0.0) });
        }
    }

    /// Stacked ↔ split; the choice is remembered for new diff views.
    pub fn set_layout(&mut self, layout: DiffListLayout, cx: &mut Context<Self>) {
        if layout == self.layout {
            return;
        }
        self.layout = layout;
        self.state.set(SIDE_BY_SIDE_STATE_KEY, &(layout == DiffListLayout::Split));
        self.text_offset = 0.0;
        self.preserving_top_line(Self::rebuild_list);
        cx.notify();
    }

    pub fn toggle_layout(&mut self, cx: &mut Context<Self>) {
        let next = if self.layout == DiffListLayout::Unified {
            DiffListLayout::Split
        } else {
            DiffListLayout::Unified
        };
        self.set_layout(next, cx);
    }

    pub fn wraps_lines() -> bool {
        WRAPS_LINES.load(Ordering::Relaxed)
    }

    fn toggle_wrap(&mut self, cx: &mut Context<Self>) {
        WRAPS_LINES.store(!Self::wraps_lines(), Ordering::Relaxed);
        self.text_offset = 0.0;
        self.preserving_top_line(|this| this.list_state.remeasure());
        cx.notify();
    }

    fn toggle_collapsed(&mut self, cx: &mut Context<Self>) {
        self.collapsed = !self.collapsed;
        self.rebuild_list();
        self.list_state.scroll_to(ListOffset::default());
        cx.notify();
    }

    fn expand(&mut self, fold: &DiffFold, cx: &mut Context<Self>) {
        let top = self.list_state.logical_scroll_top();
        self.expanded.insert(fold.id);
        self.rebuild_list();
        // The first shown line takes the strip's place on screen.
        self.list_state.scroll_to(top);
        cx.notify();
    }

    fn copy_path(&mut self, cx: &mut Context<Self>) {
        if let Some(document) = self.document.as_deref() {
            cx.write_to_clipboard(ClipboardItem::new_string(document.path.clone()));
        }
        self.path_copied = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(1500)).await;
            let _ = this.update(cx, |this, cx| {
                this.path_copied = None;
                cx.notify();
            });
        }));
        cx.notify();
    }

    // MARK: - Horizontal text scroll (no wrap)

    fn scroll_text(&mut self, event: &ScrollEvent, window: &mut Window, cx: &mut Context<Self>) {
        if Self::wraps_lines() {
            return;
        }
        let Some(document) = self.document.as_deref() else { return };
        let delta = event.delta.pixel_delta(px(LINE_HEIGHT));
        if delta.x.abs() <= delta.y.abs() {
            return;
        }
        let row_width: f32 = self.list_state.viewport_bounds().size.width.into();
        let zoom = cx.soprano_theme().zoom();
        let column = digit_width(DIFF_FONT_SIZE, window);
        let limit = ((document.max_columns + 1) as f32 * column
            - code_width(row_width / zoom, self.layout, self.number_width))
        .ceil()
        .max(0.0);
        if limit <= 0.0 {
            return;
        }
        let next = (self.text_offset - f32::from(delta.x) / zoom).clamp(0.0, limit);
        if next != self.text_offset {
            self.text_offset = next;
            cx.notify();
        }
        cx.stop_propagation();
    }

    // MARK: - Rows

    /// What a layout row draws on one side; `None` for a filler.
    fn side(
        document: &DiffDocument,
        row: &soprano_git::changes::GitDiffRow,
        old_side: bool,
    ) -> Option<DiffSide> {
        document.side(row, old_side)
    }

    fn render_row(&mut self, index: usize, _: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let (Some(document), Some(row)) = (self.document.as_deref(), self.list.rows.get(index)) else {
            return div().into_any_element();
        };
        let layout = DiffRowLayout {
            number_width: self.number_width,
            wrap: Self::wraps_lines(),
            text_offset: self.text_offset,
        };
        let selected = self.selection.filter(|selection| selection.rows().contains(&index));
        let element = match row {
            DiffListRow::Header => return div().into_any_element(),
            DiffListRow::End => return div().h(cx.soprano_theme().z(END_HEIGHT)).into_any_element(),
            DiffListRow::Fold(fold) => {
                let fold_clone = fold.clone();
                return DiffFoldRow::new(("diff-fold", index), fold.clone(), self.number_width)
                    .on_expand(cx.listener(move |this, _, _, cx| this.expand(&fold_clone, cx)))
                    .into_any_element();
            }
            DiffListRow::Line(ix) => {
                let layout_row = &document.unified.rows[*ix];
                let Some(side) = Self::side(document, layout_row, layout_row.kind == GitDiffRowKind::Removed)
                else {
                    return div().into_any_element();
                };
                DiffLineRow::new(("diff-line", index), side, layout)
                    .selected(selected.is_some())
                    .into_any_element()
            }
            DiffListRow::Pair(ix) => DiffSplitRow::new(
                ("diff-pair", index),
                Self::side(document, &document.old.rows[*ix], true),
                Self::side(document, &document.new.rows[*ix], false),
                layout,
            )
            .selected_side(selected.map(|selection| selection.old_side))
            .into_any_element(),
        };
        div()
            .id(("diff-row", index))
            .w_full()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    cx.emit(DiffEvent::FocusRequested);
                    this.focus.focus(window, cx);
                    this.dragging = true;
                    let old_side = this.is_old_side(event.position.x);
                    this.begin_selection(index, old_side, event.modifiers.shift, cx);
                }),
            )
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    this.context_menu(index, event.position, window, cx);
                }),
            )
            .on_mouse_move(cx.listener(move |this, event: &gpui::MouseMoveEvent, _, cx| {
                if this.dragging && event.pressed_button == Some(MouseButton::Left) {
                    this.extend_selection(index, cx);
                }
            }))
            .child(element)
            .into_any_element()
    }

    fn render_subheader(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        let z = |value: f32| theme.z(value);
        let has_changes = !self.list.change_rows.is_empty();
        let wrap = Self::wraps_lines();
        let wrap_label = if wrap { "Disable line wrapping" } else { "Enable line wrapping" };
        let file = self.file.clone();
        div()
            .flex_shrink_0()
            .mt(z(8.0))
            .ml(z(16.0))
            .mr(z(12.0))
            .h(z(SUBHEADER_HEIGHT))
            .flex()
            .flex_row()
            .items_center()
            .gap(z(2.0))
            .child(
                div()
                    .h(z(24.0))
                    .px(z(8.0))
                    .flex()
                    .items_center()
                    .rounded(z(8.0))
                    .bg(theme.raised)
                    .when(!theme.is_dark(), |pill| pill.border_1().border_color(theme.border.opacity(0.7)))
                    .text_size(z(size::SMALL))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(theme.foreground)
                    .child(scope_title(self.staged)),
            )
            .child(div().flex_1())
            .when_some(self.document.as_deref(), |row, document| {
                row.child(div().mr(z(6.0)).child(DiffStat::new(document.additions, document.deletions, 10.0)))
            })
            .child(toolbar_button(
                "diff-previous",
                IconName::ChevronUp,
                "Previous Change (⇧F7)",
                has_changes,
                cx.listener(|this, _, _, cx| this.navigate(false, cx)),
            ))
            .child(toolbar_button(
                "diff-next",
                IconName::ChevronDown,
                "Next Change (F7)",
                has_changes,
                cx.listener(|this, _, _, cx| this.navigate(true, cx)),
            ))
            .child(
                div()
                    .ml(z(4.0))
                    .mr(z(4.0))
                    .p(z(2.0))
                    .rounded(z(8.0))
                    .bg(theme.foreground.opacity(if theme.is_dark() { 0.06 } else { 0.05 }))
                    .flex()
                    .flex_row()
                    .child(
                        IconButton::new("diff-stacked", IconName::Rows2)
                            .icon_size(13.0)
                            .selected(self.layout == DiffListLayout::Unified)
                            .tooltip("Stacked diff view")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.set_layout(DiffListLayout::Unified, cx)),
                            ),
                    )
                    .child(
                        IconButton::new("diff-split", IconName::Columns2)
                            .icon_size(13.0)
                            .selected(self.layout == DiffListLayout::Split)
                            .tooltip("Split diff view")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.set_layout(DiffListLayout::Split, cx)),
                            ),
                    ),
            )
            .child(
                IconButton::new("diff-wrap", IconName::TextWrap)
                    .icon_size(14.0)
                    .selected(wrap)
                    .tooltip(wrap_label)
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_wrap(cx))),
            )
            .child(toolbar_button(
                "diff-open-file",
                IconName::FileText,
                "Open File",
                self.file_exists,
                cx.listener(move |_, _, _, cx| cx.emit(DiffEvent::OpenFile(file.clone()))),
            ))
    }

    fn render_file_header(&self, document: &DiffDocument, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        let colors = SurfaceColors::of(cx);
        let z = |value: f32| theme.z(value);
        let (glyph, tint) = match document.change {
            FileChange::Added => (IconName::SquarePlus, colors.diff_add_foreground),
            FileChange::Deleted => (IconName::SquareMinus, colors.diff_delete_foreground),
            FileChange::Modified => (IconName::SquareDot, mix(colors.info, colors.muted, 0.5)),
        };
        let (folder, name) = match document.path.rfind('/') {
            Some(slash) => (document.path[..=slash].to_string(), document.path[slash + 1..].to_string()),
            None => (String::new(), document.path.clone()),
        };
        let scrolled = self.list_state.logical_scroll_top() != ListOffset::default();
        div()
            .id("diff-file-header")
            .flex_shrink_0()
            .w_full()
            .h(z(HEADER_HEIGHT))
            .pl(z(8.0))
            .pr(z(14.0))
            .flex()
            .flex_row()
            .items_center()
            .gap(z(6.0))
            .bg(theme.background)
            .when(scrolled, |header| header.border_b_1().border_color(theme.border))
            .on_click(cx.listener(|this, event: &gpui::ClickEvent, _, cx| {
                if event.click_count() == 1 {
                    this.toggle_collapsed(cx);
                }
            }))
            .child(
                IconButton::new(
                    "diff-collapse",
                    if self.collapsed { IconName::ChevronRight } else { IconName::ChevronDown },
                )
                .icon_size(11.0)
                .tooltip(if self.collapsed { "Expand diff" } else { "Collapse diff" })
                .on_click(cx.listener(|this, _, _, cx| {
                    cx.stop_propagation();
                    this.toggle_collapsed(cx);
                })),
            )
            .child(icon(glyph).size(12.0 * theme.zoom()).color(tint))
            .child(
                div()
                    .min_w_0()
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .text_ellipsis_start()
                    .flex()
                    .flex_row()
                    .items_center()
                    .text_size(z(size::ROW))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child(div().text_color(colors.muted).child(folder))
                    .child(div().text_color(colors.foreground).child(name))
                    .when(self.staged, |title| {
                        title.child(
                            div()
                                .text_size(z(size::SMALL))
                                .font_weight(gpui::FontWeight::NORMAL)
                                .text_color(colors.muted)
                                .child("\u{a0}\u{a0}Staged"),
                        )
                    }),
            )
            .child(
                IconButton::new(
                    "diff-copy-path",
                    if self.path_copied.is_some() { IconName::Check } else { IconName::Copy },
                )
                .icon_size(10.0)
                .tooltip("Copy path")
                .on_click(cx.listener(|this, _, _, cx| {
                    cx.stop_propagation();
                    this.copy_path(cx);
                })),
            )
            .child(div().flex_1())
            .child(DiffStat::new(document.additions, document.deletions, size::SMALL).mute_zero(true))
    }
}

/// `a` mixed toward `b` by `t`, in RGB.
fn mix(a: gpui::Hsla, b: gpui::Hsla, t: f32) -> gpui::Hsla {
    let (a, b) = (a.to_rgb(), b.to_rgb());
    gpui::Rgba {
        r: a.r + (b.r - a.r) * t,
        g: a.g + (b.g - a.g) * t,
        b: a.b + (b.b - a.b) * t,
        a: a.a + (b.a - a.a) * t,
    }
    .into()
}

impl Render for DiffView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        if let Some(document) = self.document.as_deref() {
            self.number_width = crate::rich::diff::number_width(document.max_line, window);
        }
        let background = theme.background;
        let body: AnyElement = match self.document.as_deref() {
            Some(document) => {
                let header = self.render_file_header(document, cx).into_any_element();
                let rows = list(self.list_state.clone(), cx.processor(Self::render_row)).size_full();
                div()
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .flex()
                    .flex_col()
                    .child(header)
                    .child(
                        div()
                            .id("diff-list")
                            .flex_1()
                            .min_h_0()
                            .w_full()
                            .on_scroll(cx.listener(Self::scroll_text))
                            .on_mouse_up(
                                MouseButton::Left,
                                cx.listener(|this, _, _, _| this.dragging = false),
                            )
                            .child(rows),
                    )
                    .into_any_element()
            }
            None => div()
                .flex_1()
                .min_h_0()
                .w_full()
                .when_some(self.message.clone(), |area, text| {
                    area.child(SurfaceMessage::new(SharedString::from(text)))
                })
                .into_any_element(),
        };
        div()
            .id("soprano-diff")
            .key_context(DIFF_CONTEXT)
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .bg(background)
            .on_action(cx.listener(Self::next_change))
            .on_action(cx.listener(Self::previous_change))
            .on_action(cx.listener(Self::copy_lines))
            .on_action(cx.listener(Self::select_all_lines))
            .on_action(cx.listener(Self::clear_selection))
            .on_mouse_down(MouseButton::Left, cx.listener(|_, _, _, cx| cx.emit(DiffEvent::FocusRequested)))
            .child(self.render_subheader(cx))
            .child(div().h(theme.z(8.0)).flex_shrink_0())
            .child(body)
            .when_some(self.menu.as_ref().map(|(menu, _)| menu.clone()), |root, menu| root.child(menu))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::TestAppContext;

    fn setup(cx: &mut TestAppContext) {
        cx.update(|cx| {
            soprano_ui::init_for_tests(cx);
            cx.bind_keys(key_bindings(cx));
        });
    }

    fn git(root: &Path, args: &[&str]) {
        let status = std::process::Command::new("git")
            .args(args)
            .current_dir(root)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .status()
            .expect("git runs");
        assert!(status.success(), "git {args:?}");
    }

    #[test]
    fn staged_and_working_diffs_have_their_own_scope_titles() {
        assert_eq!(scope_title(true), "Staged changes");
        assert_eq!(scope_title(false), "Changes");
    }

    #[gpui::test]
    async fn a_file_outside_any_repository_says_so(cx: &mut TestAppContext) {
        setup(cx);
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("loose.txt");
        std::fs::write(&path, "x\n").unwrap();
        let state = StateStore::in_memory();
        let (view, cx) =
            cx.add_window_view(|window, cx| DiffView::new(path.clone(), false, state.clone(), window, cx));
        cx.run_until_parked();
        let message = view.read_with(cx, |view, _| view.message().map(str::to_string));
        assert!(matches!(
            message.as_deref(),
            Some("This file is not in a Git repository.") | Some("Git is not installed.")
        ));
        assert!(view.read_with(cx, |view, _| view.document().is_none()));
    }

    #[gpui::test]
    async fn the_layout_choice_is_remembered_for_new_diff_views(cx: &mut TestAppContext) {
        setup(cx);
        if soprano_git::reader::executable().is_none() {
            return;
        }
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        let path = root.path().join("a.txt");
        let original: String = (1..=30).map(|n| format!("line {n}\n")).collect();
        std::fs::write(&path, &original).unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-q", "-m", "one"]);
        std::fs::write(&path, original.replace("line 3\n", "line three\n").replace("line 25\n", "")).unwrap();

        let state = StateStore::in_memory();
        let (view, cx) =
            cx.add_window_view(|window, cx| DiffView::new(path.clone(), false, state.clone(), window, cx));
        cx.run_until_parked();
        let (additions, deletions) = view
            .read_with(cx, |view, _| view.document().map(|d| (d.additions, d.deletions)).unwrap_or_default());
        assert_eq!((additions, deletions), (1, 2));
        assert_eq!(view.read_with(cx, |view, _| view.list().change_rows.len()), 2);
        assert_eq!(view.read_with(cx, |view, _| view.layout()), DiffListLayout::Unified);

        view.update(cx, |view, cx| view.toggle_layout(cx));
        assert_eq!(state.get::<bool>(SIDE_BY_SIDE_STATE_KEY), Some(true));
        let second_state = state.clone();
        let (second, cx) = cx.add_window_view(|window, cx| {
            DiffView::new(path.clone(), false, second_state.clone(), window, cx)
        });
        assert_eq!(second.read_with(cx, |view, _| view.layout()), DiffListLayout::Split);

        // Selecting the changed line and copying it gives the file's text.
        cx.run_until_parked();
        let row = second.read_with(cx, |view, _| view.list().change_rows[0]);
        second.update(cx, |view, cx| view.begin_selection(row, false, false, cx));
        assert_eq!(second.read_with(cx, |view, _| view.selected_text()), Some("line three".to_string()));
        second.update(cx, |view, cx| view.begin_selection(row, true, false, cx));
        assert_eq!(second.read_with(cx, |view, _| view.selected_text()), Some("line 3".to_string()));
    }

    #[test]
    fn mixing_halves_two_colors() {
        let black = gpui::black();
        let white = gpui::white();
        let mid = mix(black, white, 0.5).to_rgb();
        assert!((mid.r - 0.5).abs() < 0.01);
    }
}
