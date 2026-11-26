//! Git branch switcher popover anchored above the composer context bar's `[GitBranch] <name>`
//! trigger, shared by both the Chat UI composer and the Agent Dashboard composer.

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gpui::{
    Anchor, AnyElement, App, Bounds, ClipboardItem, Context, Entity, EventEmitter, FocusHandle, Focusable,
    FontWeight, IntoElement, KeyDownEvent, ParentElement, Pixels, Render, ScrollHandle, SharedString, Styled,
    Subscription, Task, Window, anchored, deferred, div, point, prelude::*,
};
use gpui_component::input::{Enter, Escape, MoveDown, MoveUp};
use soprano_git::{BranchInfo, BranchList};
use soprano_ui::fonts::UI_FONT_FAMILY;
use soprano_ui::{ActiveSopranoTheme, IconName, InputEvent, InputState, SopranoTheme, icon, text_input};

use crate::widgets::text_size;

const POPOVER_WIDTH: f32 = 320.0;
const LIST_MAX_HEIGHT: f32 = 320.0;
const GAP: f32 = 6.0;

/// Events emitted by [`BranchSwitcher`] to its hosting composer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BranchSwitcherEvent {
    /// Successfully checked out a different local branch.
    Switched(String),
    /// Closed via Escape, outside click, or selecting the already-active branch.
    Dismissed,
}

/// Floating searchable git branch picker (Orca's branch switcher): search field, dirty-tree
/// notice when uncommitted files block switching, current branch with copy action + checkmark,
/// worktree-occupied branches with their checkout path, and other local branches with relative
/// commit times.
pub struct BranchSwitcher {
    cwd: PathBuf,
    anchor: Bounds<Pixels>,
    use_chat_zoom: bool,
    search: Entity<InputState>,
    focus: FocusHandle,
    scroll: ScrollHandle,
    branches: Option<BranchList>,
    highlighted: Option<usize>,
    switching: Option<String>,
    error: Option<String>,
    copied: bool,
    load_task: Option<Task<()>>,
    checkout_task: Option<Task<()>>,
    copied_reset_task: Option<Task<()>>,
    _subscription: Subscription,
}

impl EventEmitter<BranchSwitcherEvent> for BranchSwitcher {}

impl Focusable for BranchSwitcher {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.search.focus_handle(cx)
    }
}

impl BranchSwitcher {
    /// Creates a branch switcher that loads local branches for `cwd` in the background.
    pub fn new(
        cwd: PathBuf,
        anchor: Bounds<Pixels>,
        use_chat_zoom: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut switcher = Self::build(cwd.clone(), anchor, use_chat_zoom, None, window, cx);
        switcher.load_task = Some(cx.spawn(async move |this, cx| {
            let loaded =
                cx.background_executor().spawn(async move { soprano_git::reader::branches(&cwd) }).await;
            let _ = this.update(cx, |this, cx| {
                this.load_task = None;
                match loaded {
                    Some(list) => {
                        this.branches = Some(list);
                        this.sync_highlight(cx);
                    }
                    None => {
                        this.branches = Some(BranchList::default());
                        this.error = Some("Could not read git branches.".into());
                    }
                }
                cx.notify();
            });
        }));
        switcher
    }

    /// Creates a branch switcher pre-populated with `branches` (for deterministic tests).
    pub fn with_branches(
        cwd: PathBuf,
        anchor: Bounds<Pixels>,
        use_chat_zoom: bool,
        branches: BranchList,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut switcher = Self::build(cwd, anchor, use_chat_zoom, Some(branches), window, cx);
        switcher.sync_highlight(cx);
        switcher
    }

    fn build(
        cwd: PathBuf,
        anchor: Bounds<Pixels>,
        use_chat_zoom: bool,
        branches: Option<BranchList>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search branches"));
        let subscription = cx.subscribe(&search, |this, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.sync_highlight(cx);
                cx.notify();
            }
        });
        search.update(cx, |input, cx| input.focus(window, cx));
        Self {
            cwd,
            anchor,
            use_chat_zoom,
            search,
            focus: cx.focus_handle(),
            scroll: ScrollHandle::new(),
            branches,
            highlighted: None,
            switching: None,
            error: None,
            copied: false,
            load_task: None,
            checkout_task: None,
            copied_reset_task: None,
            _subscription: subscription,
        }
    }

    pub fn search_input(&self) -> &Entity<InputState> {
        &self.search
    }

    pub fn highlighted(&self) -> Option<usize> {
        self.highlighted
    }

    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }

    /// The filtered branches currently shown for the search query.
    pub fn shown_branches(&self, cx: &App) -> Vec<BranchInfo> {
        let Some(list) = &self.branches else { return Vec::new() };
        let query = self.search.read(cx).value().to_string();
        matching_branches(&list.branches, &query).into_iter().cloned().collect()
    }

    fn sync_highlight(&mut self, cx: &App) {
        let shown = self.shown_branches(cx);
        if shown.is_empty() {
            self.highlighted = None;
            return;
        }
        let query = self.search.read(cx).value().to_string();
        let next = if query.trim().is_empty() {
            shown.iter().position(|b| b.is_current).or(Some(0))
        } else {
            Some(0)
        };
        self.highlighted = next;
        if let Some(index) = next {
            self.scroll.scroll_to_item(index);
        }
    }

    fn move_highlight(&mut self, delta: isize, cx: &mut Context<Self>) {
        let count = self.shown_branches(cx).len();
        if count == 0 {
            return;
        }
        let current = self.highlighted.map_or(if delta > 0 { -1 } else { count as isize }, |h| h as isize);
        let index = (current + delta).clamp(0, count as isize - 1) as usize;
        self.highlighted = Some(index);
        self.scroll.scroll_to_item(index);
        cx.notify();
    }

    fn activate_highlighted(&mut self, cx: &mut Context<Self>) {
        let shown = self.shown_branches(cx);
        let Some(branch) = self.highlighted.and_then(|i| shown.get(i)) else { return };
        if branch.is_current {
            cx.emit(BranchSwitcherEvent::Dismissed);
            return;
        }
        if branch.worktree_path.is_some() || self.changed_files() > 0 {
            return;
        }
        self.checkout(branch.name.clone(), cx);
    }

    fn changed_files(&self) -> usize {
        self.branches.as_ref().map_or(0, |b| b.changed_files)
    }

    fn copy_branch(&mut self, name: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(name));
        self.copied = true;
        cx.notify();
        self.copied_reset_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(1_500)).await;
            let _ = this.update(cx, |this, cx| {
                this.copied = false;
                cx.notify();
            });
        }));
    }

    fn checkout(&mut self, branch: String, cx: &mut Context<Self>) {
        if self.switching.is_some() || self.changed_files() > 0 {
            return;
        }
        self.error = None;
        self.switching = Some(branch.clone());
        cx.notify();
        let cwd = self.cwd.clone();
        let target = branch.clone();
        self.checkout_task = Some(cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { soprano_git::reader::checkout_branch(&cwd, &target) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.checkout_task = None;
                this.switching = None;
                match result {
                    Ok(()) => cx.emit(BranchSwitcherEvent::Switched(branch)),
                    Err(message) => {
                        this.error = Some(message);
                        cx.notify();
                    }
                }
            });
        }));
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        match event.keystroke.key.as_str() {
            "escape" => {
                cx.stop_propagation();
                cx.emit(BranchSwitcherEvent::Dismissed);
            }
            "down" => {
                cx.stop_propagation();
                self.move_highlight(1, cx);
            }
            "up" => {
                cx.stop_propagation();
                self.move_highlight(-1, cx);
            }
            "enter" => {
                cx.stop_propagation();
                self.activate_highlighted(cx);
            }
            _ => {}
        }
    }

    fn scale(&self, t: &SopranoTheme, value: f32) -> Pixels {
        if self.use_chat_zoom { t.cz(value) } else { t.z(value) }
    }

    fn zoom_factor(&self, t: &SopranoTheme) -> f32 {
        if self.use_chat_zoom { t.chat_zoom_factor() } else { 1.0 }
    }
}

impl Render for BranchSwitcher {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let scale = |v: f32| self.scale(&t, v);
        let zoom = self.zoom_factor(&t);
        let anchor = self.anchor;
        let position = point(anchor.left(), anchor.top() - scale(GAP));
        let now_secs = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);

        let changed_files = self.changed_files();
        let loading = self.branches.is_none();
        let shown = self.shown_branches(cx);
        let highlighted = self.highlighted;
        let switching = self.switching.clone();
        let copied = self.copied;

        let rows: Vec<AnyElement> = shown
            .into_iter()
            .enumerate()
            .map(|(index, branch)| {
                let is_highlighted = highlighted == Some(index);
                let is_busy = branch.worktree_path.is_some();
                let is_switching = switching.as_deref() == Some(branch.name.as_str());
                let can_switch = !branch.is_current && !is_busy && changed_files == 0 && switching.is_none();

                if branch.is_current {
                    let copy_name = branch.name.clone();
                    let row_bg = t.foreground.opacity(if is_highlighted { 0.10 } else { 0.07 });
                    let row_border = if is_highlighted { t.border } else { t.border.opacity(0.6) };
                    return div()
                        .id(SharedString::from(format!("branch-row-{index}")))
                        .min_h(scale(32.0))
                        .px(scale(8.0))
                        .py(scale(5.0))
                        .rounded(scale(6.0))
                        .bg(row_bg)
                        .border_1()
                        .border_color(row_border)
                        .flex()
                        .items_center()
                        .gap(scale(8.0))
                        .cursor_pointer()
                        .on_click(cx.listener(|_, _, _, cx| cx.emit(BranchSwitcherEvent::Dismissed)))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .font_family(UI_FONT_FAMILY)
                                .text_size(scale(text_size::BODY))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(t.foreground)
                                .truncate()
                                .child(branch.name),
                        )
                        .child(
                            div()
                                .id(SharedString::from(format!("branch-copy-{index}")))
                                .flex_none()
                                .size(scale(22.0))
                                .rounded(scale(4.0))
                                .flex()
                                .items_center()
                                .justify_center()
                                .cursor_pointer()
                                .hover(|s| s.bg(t.foreground.opacity(0.10)))
                                .tooltip(soprano_ui::tooltip(if copied {
                                    "Copied"
                                } else {
                                    "Copy branch name"
                                }))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    cx.stop_propagation();
                                    this.copy_branch(copy_name.clone(), cx);
                                }))
                                .child(
                                    icon(if copied { IconName::Check } else { IconName::Copy })
                                        .size(12.0 * zoom)
                                        .color(if copied { t.accent } else { t.muted }),
                                ),
                        )
                        .child(
                            div()
                                .flex_none()
                                .w(scale(14.0))
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(icon(IconName::Check).size(13.0 * zoom).color(t.foreground)),
                        )
                        .into_any_element();
                }

                if let Some(wt_path) = branch.worktree_path {
                    return div()
                        .id(SharedString::from(format!("branch-row-{index}")))
                        .px(scale(8.0))
                        .py(scale(5.0))
                        .rounded(scale(6.0))
                        .when(is_highlighted, |row| row.bg(t.foreground.opacity(0.05)))
                        .flex()
                        .flex_col()
                        .gap(scale(2.0))
                        .opacity(0.6)
                        .child(
                            div()
                                .font_family(UI_FONT_FAMILY)
                                .text_size(scale(text_size::BODY))
                                .text_color(t.muted)
                                .truncate()
                                .child(branch.name),
                        )
                        .child(
                            div()
                                .font_family(UI_FONT_FAMILY)
                                .text_size(scale(text_size::SMALL))
                                .text_color(t.muted.opacity(0.85))
                                .line_clamp(3)
                                .child(format!("Checked out in\n{wt_path}")),
                        )
                        .into_any_element();
                }

                let time_text = if is_switching {
                    "Switching…".to_owned()
                } else {
                    branch
                        .committer_timestamp
                        .map(|ts| relative_commit_time(ts, now_secs))
                        .unwrap_or_default()
                };
                let target_branch = branch.name.clone();
                div()
                    .id(SharedString::from(format!("branch-row-{index}")))
                    .min_h(scale(30.0))
                    .px(scale(8.0))
                    .py(scale(5.0))
                    .rounded(scale(6.0))
                    .flex()
                    .items_center()
                    .gap(scale(8.0))
                    .when(is_highlighted, |row| {
                        row.bg(t.foreground.opacity(if can_switch { 0.09 } else { 0.05 }))
                    })
                    .when(can_switch, |row| {
                        row.cursor_pointer().hover(|s| s.bg(t.foreground.opacity(0.09))).on_click(
                            cx.listener(move |this, _, _, cx| {
                                this.checkout(target_branch.clone(), cx);
                            }),
                        )
                    })
                    .when(!can_switch && !is_switching, |row| row.opacity(0.55))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(scale(text_size::BODY))
                            .text_color(t.foreground)
                            .truncate()
                            .child(branch.name),
                    )
                    .when(!time_text.is_empty(), |row| {
                        row.child(
                            div()
                                .flex_none()
                                .font_family(UI_FONT_FAMILY)
                                .text_size(scale(text_size::SMALL))
                                .text_color(t.muted)
                                .whitespace_nowrap()
                                .child(time_text),
                        )
                    })
                    .into_any_element()
            })
            .collect();

        let empty = !loading && rows.is_empty();
        let card = div()
            .id("branch-switcher-popover")
            .debug_selector(|| "branch-switcher-popover".into())
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::on_key_down))
            .capture_action(cx.listener(|_, _: &Escape, _, cx| {
                cx.stop_propagation();
                cx.emit(BranchSwitcherEvent::Dismissed);
            }))
            .capture_action(cx.listener(|this, _: &MoveUp, _, cx| {
                cx.stop_propagation();
                this.move_highlight(-1, cx);
            }))
            .capture_action(cx.listener(|this, _: &MoveDown, _, cx| {
                cx.stop_propagation();
                this.move_highlight(1, cx);
            }))
            .capture_action(cx.listener(|this, _: &Enter, _, cx| {
                cx.stop_propagation();
                this.activate_highlighted(cx);
            }))
            .on_mouse_down_out(cx.listener(move |_, event: &gpui::MouseDownEvent, _, cx| {
                if anchor.contains(&event.position) {
                    return;
                }
                cx.emit(BranchSwitcherEvent::Dismissed);
            }))
            .occlude()
            .w(scale(POPOVER_WIDTH))
            .rounded(scale(8.0))
            .border_1()
            .border_color(t.border)
            .bg(t.popover)
            .shadow_lg()
            .overflow_hidden()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(scale(6.0))
                    .px(scale(10.0))
                    .py(scale(4.0))
                    .border_b_1()
                    .border_color(t.border.opacity(0.7))
                    .child(icon(IconName::Search).size(13.0 * zoom).color(t.muted))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(text_input(&self.search).small().text_size(scale(text_size::BODY))),
                    ),
            )
            .when(changed_files > 0, |col| {
                let files_word = if changed_files == 1 { "file" } else { "files" };
                col.child(
                    div()
                        .flex()
                        .items_start()
                        .gap(scale(8.0))
                        .px(scale(10.0))
                        .py(scale(8.0))
                        .border_b_1()
                        .border_color(t.border.opacity(0.7))
                        .child(
                            div()
                                .flex_none()
                                .pt(scale(1.0))
                                .child(icon(IconName::Info).size(14.0 * zoom).color(t.muted)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .font_family(UI_FONT_FAMILY)
                                .text_size(scale(text_size::SMALL))
                                .text_color(t.muted)
                                .child(format!(
                                    "Commit or discard {changed_files} changed {files_word} before switching branches."
                                )),
                        ),
                )
            })
            .when_some(self.error.clone(), |col, error| {
                col.child(
                    div()
                        .flex()
                        .items_start()
                        .gap(scale(8.0))
                        .px(scale(10.0))
                        .py(scale(8.0))
                        .border_b_1()
                        .border_color(t.border.opacity(0.7))
                        .child(
                            div()
                                .flex_none()
                                .pt(scale(1.0))
                                .child(icon(IconName::CircleAlert).size(14.0 * zoom).color(t.failed)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .font_family(UI_FONT_FAMILY)
                                .text_size(scale(text_size::SMALL))
                                .text_color(t.failed)
                                .line_clamp(3)
                                .child(error),
                        ),
                )
            })
            .when(loading, |col| {
                col.child(
                    div().h(scale(44.0)).flex().items_center().justify_center().child(
                        div()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(scale(text_size::SMALL))
                            .text_color(t.muted)
                            .child("Loading branches…"),
                    ),
                )
            })
            .when(empty, |col| {
                col.child(
                    div().h(scale(44.0)).flex().items_center().justify_center().child(
                        div()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(scale(text_size::SMALL))
                            .text_color(t.muted)
                            .child("No branches found"),
                    ),
                )
            })
            .when(!loading && !empty, |col| {
                col.child(
                    div()
                        .id("branch-switcher-list")
                        .p(scale(4.0))
                        .max_h(scale(LIST_MAX_HEIGHT))
                        .overflow_y_scroll()
                        .track_scroll(&self.scroll)
                        .flex()
                        .flex_col()
                        .gap(scale(2.0))
                        .children(rows),
                )
            });

        deferred(
            anchored()
                .position(position)
                .anchor(Anchor::BottomLeft)
                .snap_to_window_with_margin(scale(8.0))
                .child(card),
        )
        .with_priority(1)
    }
}

/// Filters `branches` by `query`: case-insensitive prefix matches first, then substring matches,
/// then fuzzy subsequence matches, preserving the input order within each tier.
pub fn matching_branches<'a>(branches: &'a [BranchInfo], query: &str) -> Vec<&'a BranchInfo> {
    let needle = query.trim().to_ascii_lowercase();
    if needle.is_empty() {
        return branches.iter().collect();
    }
    let mut ranked: Vec<(u8, usize, &'a BranchInfo)> = branches
        .iter()
        .enumerate()
        .filter_map(|(index, branch)| {
            let lower = branch.name.to_ascii_lowercase();
            let rank = if lower.starts_with(&needle) {
                0
            } else if lower.contains(&needle) {
                1
            } else if is_subsequence(&needle, &lower) {
                2
            } else {
                return None;
            };
            Some((rank, index, branch))
        })
        .collect();
    ranked.sort_by_key(|(rank, index, _)| (*rank, *index));
    ranked.into_iter().map(|(_, _, branch)| branch).collect()
}

fn is_subsequence(needle: &str, haystack: &str) -> bool {
    let mut chars = needle.chars();
    let Some(mut target) = chars.next() else { return true };
    for ch in haystack.chars() {
        if ch == target {
            match chars.next() {
                Some(next) => target = next,
                None => return true,
            }
        }
    }
    false
}

/// Human-readable relative commit age ("just now", "2 days ago", "3 months ago").
pub fn relative_commit_time(timestamp: i64, now: i64) -> String {
    let delta = (now - timestamp).max(0);
    if delta < 60 {
        return "just now".into();
    }
    let minutes = delta / 60;
    if minutes < 60 {
        return format!("{minutes} {} ago", if minutes == 1 { "minute" } else { "minutes" });
    }
    let hours = delta / 3_600;
    if hours < 24 {
        return format!("{hours} {} ago", if hours == 1 { "hour" } else { "hours" });
    }
    let days = delta / 86_400;
    if days < 30 {
        return format!("{days} {} ago", if days == 1 { "day" } else { "days" });
    }
    let months = days / 30;
    if months < 12 {
        return format!("{months} {} ago", if months == 1 { "month" } else { "months" });
    }
    let years = days / 365;
    format!("{years} {} ago", if years == 1 { "year" } else { "years" })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn branch(name: &str, is_current: bool) -> BranchInfo {
        BranchInfo { name: name.into(), is_current, committer_timestamp: Some(1_000), worktree_path: None }
    }

    #[test]
    fn matching_branches_ranks_prefix_ahead_of_substring_and_subsequence() {
        let all = vec![
            branch("main", true),
            branch("fix/cli5-error-doc", false),
            branch("feat/shipping-protection-de", false),
            branch("shipping-hotfix", false),
        ];
        let names: Vec<&str> = matching_branches(&all, "ship").into_iter().map(|b| b.name.as_str()).collect();
        assert_eq!(names, ["shipping-hotfix", "feat/shipping-protection-de"]);

        let fuzzy: Vec<&str> = matching_branches(&all, "fced").into_iter().map(|b| b.name.as_str()).collect();
        assert_eq!(fuzzy, ["fix/cli5-error-doc"]);
    }

    #[test]
    fn relative_commit_time_formats_seconds_through_years() {
        let now = 1_700_000_000;
        assert_eq!(relative_commit_time(now - 10, now), "just now");
        assert_eq!(relative_commit_time(now - 60, now), "1 minute ago");
        assert_eq!(relative_commit_time(now - 3_600 * 5, now), "5 hours ago");
        assert_eq!(relative_commit_time(now - 86_400 * 2, now), "2 days ago");
        assert_eq!(relative_commit_time(now - 86_400 * 65, now), "2 months ago");
        assert_eq!(relative_commit_time(now - 86_400 * 400, now), "1 year ago");
    }
}
