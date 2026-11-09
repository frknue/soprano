//! The Changes card (`SourceControlView.swift`): the focused pane's repository as changed
//! files grouped by area (Conflicts, Changes, Staged Changes, Untracked Files), each
//! opening its diff. No staging or committing: that stays in the terminal and Soprano Git.
//!
//! The repository follows the pane the app reports through
//! [`ChangesPanel::set_working_directory`]. Nothing is read, watched, or run while the
//! panel is inactive.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Instant;

use futures::StreamExt;
use futures::channel::mpsc;
use gpui::{
    App, ClickEvent, ClipboardItem, Context, Entity, FocusHandle, FontWeight, IntoElement, KeyDownEvent,
    MouseButton, MouseDownEvent, ParentElement, Pixels, Point, Render, ScrollStrategy, SharedString, Styled,
    Subscription, Task, UniformListScrollHandle, Window, div, prelude::*, uniform_list,
};
use soprano_files::FileSystemWatcher;
use soprano_files::root::{external_git_directory, real_path, relative_path_in_roots};
use soprano_git::branch::repository_root;
use soprano_git::{GitChange, GitChangeArea, GitChangeList, GitFileStatus, GitStatusSnapshot};
use soprano_ui::fonts::size;
use soprano_ui::{ActiveSopranoTheme, ContextMenu, IconName, MenuItem, SopranoTheme, file_type_icon, icon};

use crate::chords;
use crate::refresh::RefreshGate;
use crate::{SidebarEvent, ui};

/// What the focused pane asks the panel to show.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Target {
    Repository(PathBuf),
    NotRepository,
}

/// One row: a section header or a change in it.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Entry {
    Section(GitChangeArea),
    Change(GitChangeArea, String),
}

#[derive(Clone, Debug)]
enum Row {
    Section { area: GitChangeArea, count: usize, expanded: bool },
    Change(GitChange),
}

impl Row {
    fn entry(&self) -> Entry {
        match self {
            Row::Section { area, .. } => Entry::Section(*area),
            Row::Change(change) => Entry::Change(change.area, change.path.clone()),
        }
    }
}

pub struct ChangesPanel {
    focus_handle: FocusHandle,
    is_active: bool,
    target: Option<Target>,
    shown_target: Option<Target>,
    root: Option<PathBuf>,
    /// The root fully resolved through symlinks, which file watchers report.
    real_root: Option<PathBuf>,
    external_git_directory: Option<PathBuf>,
    ignored: GitStatusSnapshot,
    /// `None` until the first read for the current root finishes; false when git failed.
    last_read_succeeded: Option<bool>,
    change_list: GitChangeList,
    generation: u64,
    gate: RefreshGate,
    timer: Option<Task<()>>,
    watcher: Option<FileSystemWatcher>,
    _watch_task: Option<Task<()>>,
    collapsed: HashSet<GitChangeArea>,
    rows: Vec<Row>,
    selected: Option<Entry>,
    scroll: UniformListScrollHandle,
    context_menu: Option<(Entity<ContextMenu>, Subscription)>,
    _subscriptions: Vec<Subscription>,
}

impl ChangesPanel {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let subscriptions = vec![cx.observe_window_activation(window, |this, window, cx| {
            // Catches changes nothing under the watched paths reflects.
            if window.is_window_active() && this.is_active {
                this.schedule_refresh(false, cx);
            }
        })];
        Self {
            focus_handle: cx.focus_handle(),
            is_active: false,
            target: None,
            shown_target: None,
            root: None,
            real_root: None,
            external_git_directory: None,
            ignored: GitStatusSnapshot::empty(),
            last_read_succeeded: None,
            change_list: GitChangeList::empty(),
            generation: 0,
            gate: RefreshGate::default(),
            timer: None,
            watcher: None,
            _watch_task: None,
            collapsed: HashSet::new(),
            rows: Vec::new(),
            selected: None,
            scroll: UniformListScrollHandle::new(),
            context_menu: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn is_active(&self) -> bool {
        self.is_active
    }

    /// The repository shown, if any.
    pub fn root(&self) -> Option<&Path> {
        self.root.as_deref()
    }

    pub fn change_list(&self) -> &GitChangeList {
        &self.change_list
    }

    /// Whether the keyboard is in the list.
    pub fn contains_focus(&self, window: &Window, cx: &App) -> bool {
        self.focus_handle.contains_focused(window, cx)
    }

    /// Moves the keyboard into the list, onto the first change if nothing is selected.
    pub fn focus_list(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus_handle, cx);
        if self.selected.is_none() {
            let first = self.rows.iter().find(|row| matches!(row, Row::Change(_))).or(self.rows.first());
            self.selected = first.map(Row::entry);
        }
        cx.notify();
    }

    /// Starts or stops git reads and watching (sidebar open and showing Changes).
    pub fn set_active(&mut self, active: bool, cx: &mut Context<Self>) {
        if active == self.is_active {
            return;
        }
        self.is_active = active;
        if active {
            match self.target.clone() {
                Some(target) if Some(&target) != self.shown_target.as_ref() => self.apply(target, cx),
                _ if self.root.is_some() => {
                    self.start_watching(cx);
                    self.schedule_refresh(true, cx);
                }
                _ => {}
            }
        } else {
            self.watcher = None;
            self._watch_task = None;
            self.timer = None;
            self.gate.cancel();
        }
        cx.notify();
    }

    /// The working directory of the focused pane's tab; `None` keeps the current one.
    pub fn set_working_directory(&mut self, cwd: Option<&str>, cx: &mut Context<Self>) {
        let Some(cwd) = cwd else { return };
        let expanded = soprano_platform::paths::expand_tilde(cwd).to_string_lossy().into_owned();
        let target = repository_root(&expanded).map_or(Target::NotRepository, Target::Repository);
        self.target = Some(target.clone());
        if self.is_active && Some(&target) != self.shown_target.as_ref() {
            self.apply(target, cx);
        }
        cx.notify();
    }

    /// The app became active again: re-read git (window activation does this too).
    pub fn app_did_become_active(&mut self, cx: &mut Context<Self>) {
        if self.is_active {
            self.schedule_refresh(false, cx);
        }
    }

    fn apply(&mut self, target: Target, cx: &mut Context<Self>) {
        self.shown_target = Some(target.clone());
        match target {
            Target::Repository(path) => self.set_root(Some(path), cx),
            Target::NotRepository => self.set_root(None, cx),
        }
    }

    fn set_root(&mut self, path: Option<PathBuf>, cx: &mut Context<Self>) {
        self.generation += 1;
        self.real_root = path.as_deref().and_then(real_path);
        self.external_git_directory = path.as_deref().and_then(external_git_directory);
        self.root = path;
        self.ignored = GitStatusSnapshot::empty();
        self.last_read_succeeded = None;
        self.timer = None;
        self.gate.cancel();
        self.watcher = None;
        self._watch_task = None;
        self.show(GitChangeList::empty(), false);
        if self.root.is_some() {
            self.start_watching(cx);
            self.schedule_refresh(true, cx);
        }
    }

    // MARK: - Watching

    fn start_watching(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else { return };
        let mut paths = vec![root];
        paths.extend(self.external_git_directory.clone());
        let (sender, mut receiver) = mpsc::unbounded::<(Vec<PathBuf>, bool)>();
        self.watcher =
            FileSystemWatcher::new(paths, soprano_files::watcher::DEFAULT_LATENCY, move |paths, rescan| {
                sender.unbounded_send((paths, rescan)).ok();
            });
        self._watch_task = Some(cx.spawn(async move |this, cx| {
            while let Some((paths, rescan)) = receiver.next().await {
                if this.update(cx, |this, cx| this.handle_file_system_events(&paths, rescan, cx)).is_err() {
                    break;
                }
            }
        }));
    }

    fn handle_file_system_events(&mut self, paths: &[PathBuf], needs_rescan: bool, cx: &mut Context<Self>) {
        if !self.is_active || self.root.is_none() {
            return;
        }
        if needs_rescan || self.affects_status(paths) {
            self.schedule_refresh(false, cx);
        }
    }

    /// Whether any changed path can change `git status`: the git directory, or a working
    /// tree path outside ignored folders (build output).
    fn affects_status(&self, paths: &[PathBuf]) -> bool {
        let roots: Vec<&Path> =
            self.root.iter().map(PathBuf::as_path).chain(self.real_root.as_deref()).collect();
        paths.iter().any(|path| {
            if let Some(git_directory) = &self.external_git_directory
                && path.starts_with(git_directory)
            {
                return true;
            }
            let Some(relative) = relative_path_in_roots(path, &roots) else {
                return false;
            };
            relative == ".git" || relative.starts_with(".git/") || !self.ignored.is_ignored(&relative)
        })
    }

    // MARK: - Git

    fn schedule_refresh(&mut self, immediately: bool, cx: &mut Context<Self>) {
        if !self.is_active || self.root.is_none() || soprano_git::reader::executable().is_none() {
            return;
        }
        let Some(delay) = self.gate.schedule(immediately, Instant::now()) else { return };
        self.timer = Some(cx.spawn(async move |this, cx| {
            if !delay.is_zero() {
                cx.background_executor().timer(delay).await;
            }
            this.update(cx, |this, cx| this.run_refresh(cx)).ok();
        }));
    }

    fn run_refresh(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone().filter(|_| self.is_active) else {
            self.gate.cancel();
            return;
        };
        self.gate.begin(Instant::now());
        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            let (list, ignored) = cx
                .background_executor()
                .spawn(async move {
                    (soprano_git::reader::changes(&root), soprano_git::reader::ignored_paths(&root))
                })
                .await;
            this.update(cx, |this, cx| this.finish_refresh(list, ignored, generation, cx)).ok();
        })
        .detach();
    }

    fn finish_refresh(
        &mut self,
        list: Option<GitChangeList>,
        ignored: HashSet<String>,
        generation: u64,
        cx: &mut Context<Self>,
    ) {
        let again = self.gate.finish();
        if generation != self.generation {
            self.schedule_refresh(true, cx);
            return;
        }
        self.ignored = GitStatusSnapshot::new(&[], ignored);
        self.last_read_succeeded = Some(list.is_some());
        self.show(list.unwrap_or_default(), true);
        if again {
            self.schedule_refresh(false, cx);
        }
        cx.notify();
    }

    /// Replaces the list, keeping the selected change.
    fn show(&mut self, list: GitChangeList, keeping_state: bool) {
        let changed = list != self.change_list || !keeping_state;
        self.change_list = list;
        if !changed {
            return;
        }
        if !keeping_state {
            self.selected = None;
            self.scroll.scroll_to_item(0, ScrollStrategy::Top);
        }
        self.rebuild_rows();
    }

    fn rebuild_rows(&mut self) {
        let mut rows = Vec::new();
        for area in GitChangeArea::ALL {
            let changes = self.change_list.changes_in(area);
            if changes.is_empty() {
                continue;
            }
            let expanded = !self.collapsed.contains(&area);
            rows.push(Row::Section { area, count: changes.len(), expanded });
            if expanded {
                rows.extend(changes.into_iter().cloned().map(Row::Change));
            }
        }
        self.rows = rows;
        if let Some(selected) = &self.selected
            && !self.rows.iter().any(|row| row.entry() == *selected)
        {
            self.selected = None;
        }
    }

    fn status(&self) -> Option<&'static str> {
        if soprano_git::reader::executable().is_none() {
            return Some("Source Control needs Git, which is not installed.");
        }
        if self.root.is_none() {
            return Some(if self.shown_target == Some(Target::NotRepository) {
                "Source Control is only available for Git repositories"
            } else {
                "Focus a terminal inside a Git repository to see its changes."
            });
        }
        match self.last_read_succeeded {
            None => Some("Loading changes…"),
            Some(false) => Some("Could not read this repository's status."),
            Some(true) if self.change_list.changes.is_empty() => {
                Some("No changes\nThe working tree is clean.")
            }
            Some(true) => None,
        }
    }

    // MARK: - Actions

    fn toggle(&mut self, area: GitChangeArea, cx: &mut Context<Self>) {
        if !self.collapsed.remove(&area) {
            self.collapsed.insert(area);
        }
        self.rebuild_rows();
        cx.notify();
    }

    fn file_path(&self, change: &GitChange) -> Option<PathBuf> {
        self.root.as_ref().map(|root| root.join(&change.path))
    }

    /// Opens a change's diff, or the file itself for a conflict, whose markers are
    /// resolved in the editor. The keyboard follows unless `focus` is false.
    fn open(&mut self, change: &GitChange, preview: bool, focus: bool, cx: &mut Context<Self>) {
        let Some(path) = self.file_path(change) else { return };
        if change.area == GitChangeArea::Conflicts {
            cx.emit(SidebarEvent::OpenFile { path, preview, focus });
        } else {
            cx.emit(SidebarEvent::OpenDiff {
                path,
                staged: change.area == GitChangeArea::Staged,
                preview,
                focus,
            });
        }
    }

    fn selected_index(&self) -> Option<usize> {
        let selected = self.selected.as_ref()?;
        self.rows.iter().position(|row| row.entry() == *selected)
    }

    fn row_clicked(&mut self, index: usize, event: &ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus_handle, cx);
        let Some(row) = self.rows.get(index).cloned() else { return };
        let modifiers = event.modifiers();
        if modifiers.platform || modifiers.shift || modifiers.alt || modifiers.control {
            return;
        }
        match row {
            // A click on a header only toggles it; the keyboard may land on it.
            Row::Section { area, .. } => {
                if event.click_count() == 1 {
                    self.toggle(area, cx);
                }
            }
            Row::Change(change) => {
                self.selected = Some(Entry::Change(change.area, change.path.clone()));
                // A second click keeps the preview opened by the first.
                self.open(&change, event.click_count() < 2, true, cx);
            }
        }
        cx.notify();
    }

    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let _ = window;
        let keystroke = &event.keystroke;
        let plain = chords::is_plain(&keystroke.modifiers);
        let row = self.selected_index().and_then(|index| self.rows.get(index).cloned());
        match keystroke.key.as_str() {
            "escape" => cx.emit(SidebarEvent::FocusPane),
            key @ ("space" | "enter") if plain => match row {
                Some(Row::Section { area, .. }) => self.toggle(area, cx),
                Some(Row::Change(change)) => {
                    let is_space = key == "space";
                    self.open(&change, is_space, !is_space, cx);
                }
                None => return,
            },
            key @ ("left" | "right") if plain => {
                let Some(Row::Section { area, expanded, .. }) = row else { return };
                if (key == "right") != expanded {
                    self.toggle(area, cx);
                }
            }
            key @ ("up" | "down") if plain => {
                if self.rows.is_empty() {
                    return;
                }
                let last = self.rows.len() - 1;
                let index = match (self.selected_index(), key) {
                    (None, "down") => 0,
                    (None, _) => last,
                    (Some(index), "down") => (index + 1).min(last),
                    (Some(index), _) => index.saturating_sub(1),
                };
                self.selected = Some(self.rows[index].entry());
                self.scroll.scroll_to_item(index, ScrollStrategy::Nearest);
            }
            "home" if plain && !self.rows.is_empty() => {
                self.selected = Some(self.rows[0].entry());
                self.scroll.scroll_to_item(0, ScrollStrategy::Nearest);
            }
            "end" if plain && !self.rows.is_empty() => {
                let last = self.rows.len() - 1;
                self.selected = Some(self.rows[last].entry());
                self.scroll.scroll_to_item(last, ScrollStrategy::Nearest);
            }
            _ => return,
        }
        cx.stop_propagation();
        cx.notify();
    }

    fn open_context_menu(
        &mut self,
        change: GitChange,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(path) = self.file_path(&change) else { return };
        let exists = path.exists();
        let this = cx.entity().downgrade();
        let mut items = Vec::new();
        if change.area != GitChangeArea::Conflicts {
            let (this, change) = (this.clone(), change.clone());
            items.push(MenuItem::new("Open Diff").icon(IconName::FileDiff).on_select(
                move |_, cx: &mut App| {
                    this.update(cx, |panel, cx| panel.open(&change, false, true, cx)).ok();
                },
            ));
        }
        {
            let (this, path) = (this.clone(), path.clone());
            items.push(MenuItem::new("Open File").disabled(!exists).on_select(move |_, cx: &mut App| {
                this.update(cx, |_, cx| {
                    cx.emit(SidebarEvent::OpenFile { path: path.clone(), preview: false, focus: true })
                })
                .ok();
            }));
        }
        items.push(MenuItem::separator());
        {
            let path = path.clone();
            items.push(MenuItem::new("Copy Path").icon(IconName::Copy).on_select(move |_, cx: &mut App| {
                cx.write_to_clipboard(ClipboardItem::new_string(path.to_string_lossy().into_owned()));
            }));
        }
        {
            let relative = change.path.clone();
            items.push(MenuItem::new("Copy Relative Path").on_select(move |_, cx: &mut App| {
                cx.write_to_clipboard(ClipboardItem::new_string(relative.clone()));
            }));
        }
        items.push(MenuItem::separator());
        items.push(MenuItem::new(soprano_platform::system::reveal_label()).disabled(!exists).on_select(
            move |_, cx: &mut App| {
                if let Err(error) = soprano_platform::system::reveal_in_file_manager(&path) {
                    this.update(cx, |_, cx| cx.emit(SidebarEvent::ShowError(error.to_string()))).ok();
                }
            },
        ));
        let menu = ContextMenu::new(position, items, window, cx);
        let subscription = cx.subscribe(&menu, |this, _, _: &gpui::DismissEvent, cx| {
            this.context_menu = None;
            cx.notify();
        });
        self.context_menu = Some((menu, subscription));
        cx.notify();
    }

    fn manual_refresh(&mut self, cx: &mut Context<Self>) {
        self.start_watching(cx);
        self.schedule_refresh(true, cx);
    }

    // MARK: - Rendering

    fn render_row(
        &self,
        index: usize,
        t: &SopranoTheme,
        focused: bool,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let row = &self.rows[index];
        let selected = self.selected.as_ref() == Some(&row.entry());
        let fill = selected.then(|| if focused { t.selected } else { t.hover });
        let hover = t.hover;
        let base = div()
            .id(("changes-row", index))
            .flex()
            .items_center()
            .h(t.z(28.))
            .px(t.z(8.))
            .gap(t.z(8.))
            .rounded(t.z(7.))
            .when_some(fill, |row, fill| row.bg(fill))
            .when(fill.is_none(), |row| row.hover(move |style| style.bg(hover)))
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                cx.stop_propagation();
                this.row_clicked(index, event, window, cx);
            }));
        match row {
            Row::Section { area, count, expanded } => base
                .text_size(t.z(size::META))
                .font_weight(FontWeight::MEDIUM)
                .text_color(t.muted)
                .child(
                    icon(if *expanded { IconName::ChevronDown } else { IconName::ChevronRight })
                        .size(12.)
                        .color(t.dim),
                )
                .child(div().min_w_0().truncate().child(area.title()))
                .child(div().text_color(t.dim).child(count.to_string()))
                .into_any_element(),
            Row::Change(change) => {
                let is_deleted = change.status == GitFileStatus::Deleted;
                let is_conflict = change.area == GitChangeArea::Conflicts;
                let tooltip: SharedString = match &change.original_path {
                    Some(original) => format!("{}\nRenamed from {original}", change.path).into(),
                    None => change.path.clone().into(),
                };
                let added = change.lines_added.unwrap_or(0);
                let deleted = change.lines_deleted.unwrap_or(0);
                let context_change = change.clone();
                base.pl(t.z(8. + 18.))
                    .tooltip(soprano_ui::tooltip::tooltip(tooltip))
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                            cx.stop_propagation();
                            this.selected =
                                Some(Entry::Change(context_change.area, context_change.path.clone()));
                            this.open_context_menu(context_change.clone(), event.position, window, cx);
                        }),
                    )
                    .child(
                        div()
                            .flex_none()
                            .w(t.z(14.))
                            .text_size(t.z(size::SMALL))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(ui::status_color(t, change.status, is_conflict))
                            .child(change.letter()),
                    )
                    .child(icon(file_type_icon(change.name())).size(14.).color(t.muted))
                    .child(
                        div()
                            .flex()
                            .flex_1()
                            .min_w_0()
                            .gap(t.z(6.))
                            .items_baseline()
                            .child(
                                div()
                                    .flex_none()
                                    .max_w(t.z(260.))
                                    .truncate()
                                    .text_color(if is_deleted { t.muted } else { t.foreground })
                                    .when(is_deleted, |name| name.line_through())
                                    .child(change.name().to_owned()),
                            )
                            .when(!change.directory().is_empty(), |line| {
                                line.child(
                                    div()
                                        .min_w_0()
                                        .truncate()
                                        .text_size(t.z(size::SMALL))
                                        .text_color(t.dim)
                                        .child(change.directory().to_owned()),
                                )
                            }),
                    )
                    .when(added > 0, |row| {
                        row.child(
                            div()
                                .flex_none()
                                .text_size(t.z(size::SMALL))
                                .text_color(t.ansi[2])
                                .child(format!("+{added}")),
                        )
                    })
                    .when(deleted > 0, |row| {
                        row.child(
                            div()
                                .flex_none()
                                .text_size(t.z(size::SMALL))
                                .text_color(t.ansi[1])
                                .child(format!("\u{2212}{deleted}")),
                        )
                    })
                    .into_any_element()
            }
        }
    }
}

impl Render for ChangesPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let files: HashSet<&str> =
            self.change_list.changes.iter().map(|change| change.path.as_str()).collect();
        let added: usize = self.change_list.changes.iter().filter_map(|change| change.lines_added).sum();
        let deleted: usize = self.change_list.changes.iter().filter_map(|change| change.lines_deleted).sum();
        let has_root = self.root.is_some();
        let root_name = self.root.as_ref().map(|root| {
            let name = root.file_name().map(|name| name.to_string_lossy().into_owned());
            (
                name.unwrap_or_else(|| root.to_string_lossy().into_owned()),
                soprano_platform::paths::abbreviate_home(root),
            )
        });
        let branch = if has_root { self.change_list.branch.clone() } else { None };

        let header = ui::header(&t, "Changes")
            .when(has_root, |header| {
                header.child(
                    div()
                        .flex_none()
                        .px(t.z(5.))
                        .py(t.z(1.))
                        .rounded(t.z(4.))
                        .border_1()
                        .border_color(t.border)
                        .text_size(t.z(10.))
                        .text_color(t.muted)
                        .child(if files.len() == 1 {
                            "1 file".to_owned()
                        } else {
                            format!("{} files", files.len())
                        }),
                )
            })
            .child(
                div()
                    .id("changes-root")
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(t.z(size::META))
                    .text_color(t.dim)
                    .when_some(root_name, |label, (name, full)| {
                        let text = match &branch {
                            Some(branch) => format!("{name} · {branch}"),
                            None => name,
                        };
                        label.child(text).tooltip(soprano_ui::tooltip::tooltip(full))
                    }),
            )
            .when(added > 0, |header| {
                header
                    .child(div().text_size(t.z(size::SMALL)).text_color(t.ansi[2]).child(format!("+{added}")))
            })
            .when(deleted > 0, |header| {
                header.child(
                    div()
                        .text_size(t.z(size::SMALL))
                        .text_color(t.ansi[1])
                        .child(format!("\u{2212}{deleted}")),
                )
            })
            .child(ui::icon_button(
                "changes-refresh",
                IconName::RefreshCw,
                "Refresh Source Control",
                has_root,
                cx.listener(|this, _, _, cx| this.manual_refresh(cx)),
            ));

        let body: gpui::AnyElement = match self.status() {
            Some(message) => ui::empty_state(&t, message).into_any_element(),
            None => {
                let t2 = t.clone();
                uniform_list(
                    "changes-rows",
                    self.rows.len(),
                    cx.processor(move |this, range: std::ops::Range<usize>, window, cx| {
                        let focused = this.focus_handle.is_focused(window);
                        range.map(|index| this.render_row(index, &t2, focused, cx)).collect::<Vec<_>>()
                    }),
                )
                .track_scroll(&self.scroll)
                .size_full()
                .into_any_element()
            }
        };
        let _ = window;

        ui::card(&t)
            .child(header)
            .child(
                div()
                    .id("changes-list")
                    .key_context("ChangesList")
                    .track_focus(&self.focus_handle)
                    .flex_1()
                    .min_h_0()
                    .p(t.z(6.))
                    .on_key_down(cx.listener(Self::key_down))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, _, window, cx| {
                            window.focus(&this.focus_handle, cx);
                        }),
                    )
                    .child(body),
            )
            .children(self.context_menu.as_ref().map(|(menu, _)| menu.clone()))
    }
}

#[cfg(test)]
mod tests;
