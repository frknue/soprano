//! The Automations page (`AutomationsViewController` and its views): every scheduled prompt in
//! a list, one automation's settings and run history, and one run's report. It covers the
//! workspace to the right of the sidebar, reads the [`AutomationController`] (and the workspace,
//! to know whether a run's tab is open), writes `settings.json` through it, and asks the app
//! shell for everything that needs the workspace through [`AutomationsPageEvent`].

use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Utc};
use chrono_tz::Tz;
use gpui::{
    AnyElement, App, AppContext as _, ClickEvent, Context, DismissEvent, Entity, EventEmitter, FocusHandle,
    Focusable, FontWeight, InteractiveElement, IntoElement, KeyDownEvent, MouseButton, ParentElement, Pixels,
    Point, Render, ScrollHandle, SharedString, StatefulInteractiveElement, Styled, Subscription, Task,
    Window, canvas, div, prelude::*,
};
use gpui_component::input::{Escape, MoveDown, MoveUp};
use soprano_automations::{AutomationController, AutomationRun, RunStatus, RunTrigger, RunWorktree};
use soprano_config::{Automation, AutomationCadence};
use soprano_editor::rich::{Markdown, MarkdownStyle};
use soprano_model::Workspace;
use soprano_types::AgentConversation;
use soprano_ui::button::{Button, ButtonSize, ButtonVariant, IconButton};
use soprano_ui::controls::TextInput;
use soprano_ui::dialog::{Dialog, DialogContent, DialogResult, DialogShortcut};
use soprano_ui::fonts::{self, size};
use soprano_ui::keycaps::{KeyPlatform, chord_cap};
use soprano_ui::menu::{ContextMenu, MenuItem};
use soprano_ui::theme::ActiveSopranoTheme;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{IconName, InputEvent, InputState, SopranoTheme, StatusPill, StatusPillSpec, icon};

use crate::content;
use crate::editor::{AutomationEditor, EditorClosed, EditorSetup};
use crate::format;
use crate::pill;
use crate::selection::Selection;
use crate::templates::AutomationTemplate;

/// The page header (`Metrics.topbarHeight`).
const HEADER_HEIGHT: f32 = 52.0;
/// The page column's padding (`px-6`).
pub const PAGE_PADDING: f32 = 24.0;
/// The page column's reading width.
pub const MAX_WIDTH: f32 = 1_040.0;
/// The list's toolbar (search and New Automation).
const TOOLBAR_HEIGHT: f32 = 60.0;
const LIST_ROW_HEIGHT: f32 = 52.0;
const RUN_ROW_HEIGHT: f32 = 34.0;
const COLUMN_GAP: f32 = 16.0;
/// Schedule, Last run, Agent and Status; Name takes the rest.
const LIST_COLUMNS: [f32; 4] = [170.0, 120.0, 160.0, 92.0];
/// Run, Trigger, Started and Duration; Status takes the rest.
const RUN_COLUMNS: [f32; 4] = [56.0, 110.0, 190.0, 130.0];
const TEMPLATE_CARD_HEIGHT: f32 = 132.0;
/// "in 3 hr" and "5 min ago" are recomputed this often while the page shows.
const REFRESH_INTERVAL: Duration = Duration::from_secs(30);

/// Which page shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Page {
    List,
    Automation(String),
    Run(String),
}

/// What the page asks the app shell to do; the page never touches the workspace itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AutomationsPageEvent {
    /// Esc on the list, or Done: close the page.
    Dismiss,
    /// `AutomationController::run_now`.
    RunNow { automation_id: String },
    /// Open Run or Resume Conversation: `AutomationController::open_run`; when it returns
    /// true the run's agent is on screen and the shell closes the page.
    OpenRun { run_id: String },
    /// Confirmed Delete: `AutomationController::delete`; when it returns false call
    /// [`AutomationsPage::show_write_failure`].
    Delete { automation_id: String },
}

/// What a row's ⋯ menu, its context menu and the detail's buttons do to one automation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AutomationAction {
    RunNow,
    Edit,
    ToggleEnabled,
    Delete,
}

pub struct AutomationsPage {
    controller: Entity<AutomationController>,
    workspace: Entity<Workspace>,
    page: Page,
    list_selection: Selection,
    run_selection: Selection,
    search: Entity<InputState>,
    editor: Option<(Entity<AutomationEditor>, Subscription)>,
    dialog: Option<(Entity<Dialog>, Subscription)>,
    menu: Option<(Entity<ContextMenu>, Subscription)>,
    focus: FocusHandle,
    scroll: ScrollHandle,
    /// The row to scroll into view once it is laid out.
    reveal: Rc<RefCell<Option<String>>>,
    _subscriptions: Vec<Subscription>,
    _refresh: Task<()>,
}

impl EventEmitter<AutomationsPageEvent> for AutomationsPage {}

impl Focusable for AutomationsPage {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// One automation as the list shows it.
struct ListItem {
    automation: Automation,
    next_run: Option<DateTime<Utc>>,
    last_run: Option<AutomationRun>,
}

impl AutomationsPage {
    pub fn new(
        controller: Entity<AutomationController>,
        workspace: Entity<Workspace>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search automations"));
        let subscriptions = vec![
            cx.observe(&controller, |_, _, cx| cx.notify()),
            cx.observe(&workspace, |_, _, cx| cx.notify()),
            cx.subscribe_in(&search, window, |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::PressEnter { .. } => this.activate_selection(window, cx),
                InputEvent::Change => cx.notify(),
                _ => {}
            }),
        ];
        let refresh = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor().timer(REFRESH_INTERVAL).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    return;
                }
            }
        });
        let focus = cx.focus_handle();
        focus.focus(window, cx);
        Self {
            controller,
            workspace,
            page: Page::List,
            list_selection: Selection::default(),
            run_selection: Selection::default(),
            search,
            editor: None,
            dialog: None,
            menu: None,
            focus,
            scroll: ScrollHandle::new(),
            reveal: Rc::new(RefCell::new(None)),
            _subscriptions: subscriptions,
            _refresh: refresh,
        }
    }

    pub fn page(&self) -> &Page {
        &self.page
    }

    pub fn editor(&self) -> Option<&Entity<AutomationEditor>> {
        self.editor.as_ref().map(|(editor, _)| editor)
    }

    pub fn dialog(&self) -> Option<&Entity<Dialog>> {
        self.dialog.as_ref().map(|(dialog, _)| dialog)
    }

    /// The selected automation on the list.
    pub fn selected_automation(&self) -> Option<&str> {
        self.list_selection.selected()
    }

    /// The selected run on an automation's page.
    pub fn selected_run(&self) -> Option<&str> {
        self.run_selection.selected()
    }

    #[cfg(test)]
    pub(crate) fn focus_search(&self, window: &mut Window, cx: &mut App) {
        self.search.update(cx, |state, cx| state.focus(window, cx));
    }

    /// Hands the keyboard to the page so J/K, Return and Esc work at once.
    pub fn focus_page(&self, window: &mut Window, cx: &mut App) {
        self.focus.focus(window, cx);
    }

    /// Opens a run's report, as clicking its banner asks; an unknown run shows the list.
    pub fn show_run(&mut self, run_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let known = self.controller.read(cx).run(run_id).is_some();
        self.display(if known { Page::Run(run_id.to_owned()) } else { Page::List }, window, cx);
    }

    /// Opens an automation's page.
    pub fn show_automation(&mut self, automation_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.display(Page::Automation(automation_id.to_owned()), window, cx);
    }

    /// ⌘N: the editor for a new automation.
    pub fn new_automation(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.present_editor(None, None, window, cx);
    }

    fn display(&mut self, page: Page, window: &mut Window, cx: &mut Context<Self>) {
        if self.page != page {
            if let Page::Automation(_) = page {
                self.run_selection = Selection::default();
            }
            self.page = page;
            self.scroll.set_offset(gpui::point(Pixels::ZERO, Pixels::ZERO));
        }
        self.focus_page(window, cx);
        cx.notify();
    }

    /// Esc steps back: run → automation → list → workspace; on the list it first clears the
    /// search.
    pub fn handle_escape(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.editor.is_some() || self.dialog.is_some() {
            return;
        }
        match self.page {
            Page::List => {
                if !self.clear_search(window, cx) {
                    cx.emit(AutomationsPageEvent::Dismiss);
                }
            }
            Page::Automation(_) | Page::Run(_) => self.go_back(window, cx),
        }
    }

    pub fn go_back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.page.clone() {
            Page::List => cx.emit(AutomationsPageEvent::Dismiss),
            Page::Automation(id) => {
                let ids = self.visible_ids(cx);
                self.list_selection.select(&id, &ids);
                self.display(Page::List, window, cx);
                self.reveal(id);
            }
            Page::Run(run_id) => {
                let automation_id =
                    self.controller.read(cx).run(&run_id).map(|run| run.automation_id.clone());
                match automation_id {
                    Some(automation_id) => {
                        self.display(Page::Automation(automation_id.clone()), window, cx);
                        let ids = self.run_ids(&automation_id, cx);
                        self.run_selection.select(&run_id, &ids);
                        self.reveal(run_id);
                    }
                    None => self.display(Page::List, window, cx),
                }
            }
        }
    }

    /// Scrolls the row `id` into view once it is laid out (it may not be on screen yet).
    fn reveal(&self, id: String) {
        *self.reveal.borrow_mut() = Some(id);
    }

    /// How far the page is scrolled.
    pub fn scroll_offset(&self) -> Point<Pixels> {
        self.scroll.offset()
    }

    /// A marker laid over a row that scrolls the page to it when it is the row to reveal.
    fn reveal_marker(&self, id: String) -> impl IntoElement {
        let reveal = self.reveal.clone();
        let scroll = self.scroll.clone();
        canvas(
            move |bounds, window, _| {
                if reveal.borrow().as_deref() != Some(id.as_str()) {
                    return;
                }
                reveal.borrow_mut().take();
                let view = scroll.bounds();
                let mut offset = scroll.offset();
                if bounds.top() < view.top() {
                    offset.y += view.top() - bounds.top();
                } else if bounds.bottom() > view.bottom() {
                    offset.y -= bounds.bottom() - view.bottom();
                } else {
                    return;
                }
                scroll.set_offset(offset);
                window.refresh();
            },
            |_, _, _, _| {},
        )
        .absolute()
        .inset_0()
    }

    fn clear_search(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.search.read(cx).value().is_empty() {
            return false;
        }
        self.search.update(cx, |state, cx| state.set_value("", window, cx));
        cx.notify();
        true
    }

    // MARK: - Data

    fn now_and_zone(&self, cx: &App) -> (DateTime<Utc>, Tz) {
        let clock = self.controller.read(cx).clock();
        (clock.now(), clock.time_zone())
    }

    fn query(&self, cx: &App) -> String {
        self.search.read(cx).value().trim().to_owned()
    }

    fn visible_automations(&self, cx: &App) -> Vec<Automation> {
        let query = self.query(cx);
        self.controller
            .read(cx)
            .automations()
            .iter()
            .filter(|automation| query.is_empty() || content::matches(automation, &query))
            .cloned()
            .collect()
    }

    fn visible_ids(&self, cx: &App) -> Vec<String> {
        self.visible_automations(cx).into_iter().map(|automation| automation.id).collect()
    }

    fn run_ids(&self, automation_id: &str, cx: &App) -> Vec<String> {
        self.controller.read(cx).runs(automation_id).into_iter().map(|run| run.id).collect()
    }

    /// Whether a run's tab is still open, which decides between Open Run and Resume
    /// Conversation.
    fn is_live(&self, run: &AutomationRun, cx: &App) -> bool {
        run.target()
            .is_some_and(|target| self.workspace.read(cx).tab(&target.pane_id, &target.tab_id).is_some())
    }

    /// A page whose automation or run went away (deleted, or removed from settings.json)
    /// falls back to the list; selections follow the rows that show.
    fn reconcile(&mut self, cx: &App) {
        let controller = self.controller.read(cx);
        match &self.page {
            Page::Automation(id) if controller.automation(id).is_none() => self.page = Page::List,
            Page::Run(id) if controller.run(id).is_none() => self.page = Page::List,
            _ => {}
        }
        let ids = self.visible_ids(cx);
        self.list_selection.reconcile(&ids);
        if let Page::Automation(id) = &self.page {
            let ids = self.run_ids(id, cx);
            self.run_selection.reconcile(&ids);
        }
    }

    // MARK: - Keyboard

    /// Whether the search field has the keyboard and no editor, dialog or menu is up: its
    /// arrows and Esc then drive the list, as in Orca.
    fn search_has_keyboard(&self, window: &Window, cx: &App) -> bool {
        self.editor.is_none()
            && self.dialog.is_none()
            && self.menu.is_none()
            && self.search.read(cx).focus_handle(cx).is_focused(window)
    }

    fn search_move(&mut self, delta: isize, window: &mut Window, cx: &mut Context<Self>) {
        // Capture-phase action listeners pass the action on unless they stop it.
        if self.search_has_keyboard(window, cx) {
            cx.stop_propagation();
            self.move_selection(delta, cx);
        }
    }

    fn search_escape(&mut self, _: &Escape, window: &mut Window, cx: &mut Context<Self>) {
        if self.search_has_keyboard(window, cx) {
            cx.stop_propagation();
            self.handle_escape(window, cx);
        }
    }

    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.editor.is_some() || self.dialog.is_some() || self.menu.is_some() {
            return;
        }
        let keystroke = &event.keystroke;
        if DialogShortcut::command("n").matches(keystroke, KeyPlatform::current()) {
            cx.stop_propagation();
            self.new_automation(window, cx);
            return;
        }
        let modifiers = &keystroke.modifiers;
        if modifiers.control || modifiers.alt || modifiers.platform {
            return;
        }
        let in_search = self.search.read(cx).focus_handle(cx).is_focused(window);
        let handled = match keystroke.key.as_str() {
            "escape" if !modifiers.shift => {
                self.handle_escape(window, cx);
                true
            }
            "down" => {
                self.move_selection(1, cx);
                true
            }
            "up" => {
                self.move_selection(-1, cx);
                true
            }
            // Return in the search field arrives as its PressEnter.
            "enter" if !in_search => {
                self.activate_selection(window, cx);
                true
            }
            "j" if !in_search => {
                self.move_selection(1, cx);
                true
            }
            "k" if !in_search => {
                self.move_selection(-1, cx);
                true
            }
            "space" if !in_search => {
                self.activate_selection(window, cx);
                true
            }
            _ => false,
        };
        if handled {
            cx.stop_propagation();
        }
    }

    pub fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        let selected = match self.page.clone() {
            Page::List => {
                let ids = self.visible_ids(cx);
                self.list_selection.move_by(&ids, delta);
                self.list_selection.selected().map(str::to_owned)
            }
            Page::Automation(id) => {
                let ids = self.run_ids(&id, cx);
                self.run_selection.move_by(&ids, delta);
                self.run_selection.selected().map(str::to_owned)
            }
            Page::Run(_) => return,
        };
        if let Some(selected) = selected {
            self.reveal(selected);
        }
        cx.notify();
    }

    pub fn activate_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.page.clone() {
            Page::List => {
                if let Some(id) = self.list_selection.selected().map(str::to_owned)
                    && self.visible_ids(cx).contains(&id)
                {
                    self.display(Page::Automation(id), window, cx);
                }
            }
            Page::Automation(automation_id) => {
                if let Some(run_id) = self.run_selection.selected().map(str::to_owned)
                    && self.run_ids(&automation_id, cx).contains(&run_id)
                {
                    self.display(Page::Run(run_id), window, cx);
                }
            }
            Page::Run(_) => {}
        }
    }

    // MARK: - Actions

    pub fn perform(
        &mut self,
        action: AutomationAction,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(automation) = self.controller.read(cx).automation(id) else { return };
        match action {
            AutomationAction::RunNow => {
                cx.emit(AutomationsPageEvent::RunNow { automation_id: id.to_owned() })
            }
            AutomationAction::Edit => self.present_editor(Some(automation), None, window, cx),
            AutomationAction::ToggleEnabled => {
                if !self.controller.read(cx).set_enabled(id, !automation.enabled) {
                    self.show_write_failure(window, cx);
                }
                cx.notify();
            }
            AutomationAction::Delete => self.confirm_delete(&automation, window, cx),
        }
    }

    fn confirm_delete(&mut self, automation: &Automation, window: &mut Window, cx: &mut Context<Self>) {
        let content = DialogContent::confirm(
            format!("Delete {}?", automation.name),
            "Its run history goes too. Windows and worktrees of earlier runs stay.",
            "Delete",
            true,
        );
        let automation_id = automation.id.clone();
        self.present_dialog(content, window, cx, move |_, result, _, cx| {
            if result.index == Some(1) {
                cx.emit(AutomationsPageEvent::Delete { automation_id: automation_id.clone() });
            }
        });
    }

    /// Says settings.json could not be written (a failed pause, resume or delete).
    pub fn show_write_failure(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let path = self.controller.read(cx).config().display_path();
        let content = DialogContent::alert(
            "Soprano couldn't change settings.json",
            format!("Check that {path} is writable, then try again."),
        );
        self.present_dialog(content, window, cx, |_, _, _, _| {});
    }

    fn present_dialog(
        &mut self,
        content: DialogContent,
        window: &mut Window,
        cx: &mut Context<Self>,
        answered: impl Fn(&mut Self, &DialogResult, &mut Window, &mut Context<Self>) + 'static,
    ) {
        if self.dialog.is_some() {
            return;
        }
        let dialog = Dialog::new(content, window, cx);
        let subscription =
            cx.subscribe_in(&dialog, window, move |this, _, result: &DialogResult, window, cx| {
                this.dialog = None;
                answered(this, result, window, cx);
                this.focus_page(window, cx);
                cx.notify();
            });
        self.dialog = Some((dialog, subscription));
        cx.notify();
    }

    pub fn present_editor(
        &mut self,
        automation: Option<Automation>,
        template: Option<AutomationTemplate>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.editor.is_some() {
            return;
        }
        let controller = self.controller.read(cx);
        let setup = EditorSetup {
            automation,
            template,
            automations: controller.automations().to_vec(),
            taken_ids: controller.taken_ids(),
            project_directories: controller.config().settings().project_directories,
            settings_path: controller.config().display_path(),
            clock: controller.clock().clone(),
        };
        let editor = cx.new(|cx| AutomationEditor::new(setup, window, cx));
        let controller = self.controller.clone();
        let page = cx.entity().downgrade();
        editor.update(cx, |editor, _| {
            editor.set_on_save(move |automation, _, cx| {
                let saved = controller.read(cx).save(automation);
                if saved {
                    let id = automation.id.clone();
                    page.update(cx, |page, cx| page.saved(&id, cx)).ok();
                }
                saved
            })
        });
        let subscription = cx.subscribe_in(&editor, window, |this, _, _: &EditorClosed, window, cx| {
            this.editor = None;
            this.focus_page(window, cx);
            cx.notify();
        });
        self.editor = Some((editor, subscription));
        cx.notify();
    }

    fn saved(&mut self, automation_id: &str, cx: &mut Context<Self>) {
        if self.page == Page::List {
            let ids = self.visible_ids(cx);
            self.list_selection.select(automation_id, &ids);
            self.reveal(automation_id.to_owned());
        }
        cx.notify();
    }

    fn open_menu(
        &mut self,
        automation_id: &str,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(automation) = self.controller.read(cx).automation(automation_id) else { return };
        let page = cx.entity().downgrade();
        let item = |label: &str, action: AutomationAction| {
            let page = page.clone();
            let id = automation.id.clone();
            MenuItem::new(label.to_owned()).on_select(move |window, cx| {
                page.update(cx, |page, cx| page.perform(action, &id, window, cx)).ok();
            })
        };
        let items = vec![
            item("Run Now", AutomationAction::RunNow),
            item("Edit…", AutomationAction::Edit),
            item(if automation.enabled { "Pause" } else { "Resume" }, AutomationAction::ToggleEnabled),
            MenuItem::separator(),
            item("Delete…", AutomationAction::Delete),
        ];
        let menu = ContextMenu::new(position, items, window, cx);
        let subscription = cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.menu = None;
            cx.notify();
        });
        self.menu = Some((menu, subscription));
        cx.notify();
    }

    // MARK: - Rendering: shared

    fn header(&self, theme: &SopranoTheme, subtitle: String, cx: &mut Context<Self>) -> AnyElement {
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(10.))
            .h(theme.z(HEADER_HEIGHT))
            .pl(theme.z(20.))
            .pr(theme.z(12.))
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex_none()
                    .text_size(theme.z(size::UI))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Automations"),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(theme.z(size::ROW))
                    .text_color(theme.muted)
                    .child(subtitle),
            )
            .child(
                Button::new("automations-done", "Done")
                    .ghost()
                    .size(ButtonSize::Sm)
                    .keycap("esc")
                    .tooltip("Return to the workspace (Esc)")
                    .on_click(cx.listener(|_, _, _, cx| cx.emit(AutomationsPageEvent::Dismiss))),
            )
            .into_any_element()
    }

    /// The page column: centered, up to the reading width, `px-6`.
    fn column(theme: &SopranoTheme) -> gpui::Div {
        div().w_full().max_w(theme.z(MAX_WIDTH)).mx_auto().px(theme.z(PAGE_PADDING)).flex().flex_col()
    }

    /// A board card: rounded, bordered, with `inset` padding.
    fn card(theme: &SopranoTheme, inset: f32) -> gpui::Div {
        div()
            .flex()
            .flex_col()
            .w_full()
            .p(theme.z(inset))
            .rounded(theme.z(12.))
            .border_1()
            .border_color(theme.border)
            .bg(theme.surface)
    }

    /// A titled card holding `body`.
    fn titled_card(
        theme: &SopranoTheme,
        title: &str,
        hint: Option<String>,
        body: Vec<AnyElement>,
    ) -> AnyElement {
        Self::card(theme, 16.)
            .gap(theme.z(8.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_baseline()
                    .gap(theme.z(10.))
                    .mb(theme.z(4.))
                    .child(
                        div()
                            .text_size(theme.z(size::UI))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(title.to_owned()),
                    )
                    .when_some(hint, |row, hint| {
                        row.child(div().text_size(theme.z(size::META)).text_color(theme.muted).child(hint))
                    }),
            )
            .children(body)
            .into_any_element()
    }

    fn tile(
        theme: &SopranoTheme,
        title: &'static str,
        value: AnyElement,
        detail: Option<String>,
    ) -> AnyElement {
        Self::card(theme, 14.)
            .gap(theme.z(4.))
            .child(
                div()
                    .mb(theme.z(2.))
                    .text_size(theme.z(size::META))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.muted)
                    .child(title),
            )
            .child(value)
            .when_some(detail.filter(|d| !d.is_empty()), |tile, detail| {
                tile.child(div().text_size(theme.z(size::META)).text_color(theme.muted).child(detail))
            })
            .into_any_element()
    }

    /// A tile's value: medium, wrapping, foreground (muted for an unset value); `mono` for
    /// commands, cron and paths; `path` keeps one line.
    fn tile_value(
        theme: &SopranoTheme,
        text: impl Into<SharedString>,
        mono: bool,
        muted: bool,
        path: bool,
    ) -> AnyElement {
        div()
            .text_size(theme.z(if mono || path { size::ROW } else { size::UI }))
            .font_weight(FontWeight::MEDIUM)
            .text_color(if muted { theme.muted } else { theme.foreground })
            .when(mono || path, |value| value.font_family(fonts::MONO_FONT_FAMILY))
            .when(path, |value| value.truncate())
            .child(text.into())
            .into_any_element()
    }

    fn tile_grid(theme: &SopranoTheme, tiles: Vec<AnyElement>) -> AnyElement {
        div().grid().grid_cols(4).gap(theme.z(12.)).w_full().children(tiles).into_any_element()
    }

    fn pill(spec: StatusPillSpec, now: DateTime<Utc>) -> StatusPill {
        StatusPill::new(Some(spec)).now(SystemTime::from(now))
    }

    fn column_title(theme: &SopranoTheme, title: &'static str) -> gpui::Div {
        div()
            .text_size(theme.z(size::META))
            .font_weight(FontWeight::MEDIUM)
            .text_color(theme.muted)
            .truncate()
            .child(title)
    }

    /// The back button and trail above a page's title: `‹ Automations / Weekday audit`.
    fn breadcrumb(&self, theme: &SopranoTheme, trail: Vec<String>, cx: &mut Context<Self>) -> AnyElement {
        let back_to = trail.iter().rev().nth(1).cloned().unwrap_or_else(|| "Automations".into());
        let count = trail.len();
        let mut row = div().flex().flex_row().items_center().gap(theme.z(6.)).child(
            div().mr(theme.z(-2.)).child(
                IconButton::new("automations-back", IconName::ChevronLeft)
                    .icon_size(12.)
                    .tooltip(format!("Back to {back_to}"))
                    .on_click(cx.listener(|this, _, window, cx| this.go_back(window, cx))),
            ),
        );
        for (index, part) in trail.into_iter().enumerate() {
            let last = index + 1 == count;
            if index > 0 {
                row = row.child(div().text_size(theme.z(size::ROW)).text_color(theme.dim).child("/"));
            }
            row = row.child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_size(theme.z(size::ROW))
                    .font_weight(if last { FontWeight::MEDIUM } else { FontWeight::NORMAL })
                    .text_color(if last { theme.foreground } else { theme.muted })
                    .child(part),
            );
        }
        row.into_any_element()
    }

    /// A page's title row: the 20 px title and its pill, the actions at the far edge.
    fn title_row(
        theme: &SopranoTheme,
        title: String,
        pill: StatusPill,
        buttons: Vec<AnyElement>,
    ) -> AnyElement {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(theme.z(8.))
            .mt(theme.z(-10.))
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .mr(theme.z(4.))
                    .text_size(theme.z(20.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(pill)
            .child(div().flex_1())
            .children(buttons)
            .into_any_element()
    }

    fn row_fill(theme: &SopranoTheme, selected: bool, focused: bool) -> Option<gpui::Hsla> {
        selected.then_some(if focused { theme.selected } else { theme.hover })
    }

    // MARK: - Rendering: the list

    fn render_list(
        &mut self,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (now, _) = self.now_and_zone(cx);
        let controller = self.controller.read(cx);
        let has_any = !controller.automations().is_empty();
        let items: Vec<ListItem> = self
            .visible_automations(cx)
            .into_iter()
            .map(|automation| ListItem {
                next_run: controller.next_run_date_of(&automation),
                last_run: controller.last_run(&automation.id).cloned(),
                automation,
            })
            .collect();
        let focused = self.focus.is_focused(window);
        let new_cap = chord_cap(false, true, false, "n", KeyPlatform::current());

        let toolbar =
            Self::column(theme).flex_row().items_center().h(theme.z(TOOLBAR_HEIGHT)).pt(theme.z(8.)).child(
                div().w(theme.z(280.)).min_w_0().child(
                    TextInput::new(&self.search).prefix(icon(IconName::Search).size(13.).color(theme.muted)),
                ),
            );
        let toolbar = toolbar.child(div().flex_1().min_w(theme.z(16.))).child(
            Button::new("automations-new", "New Automation")
                .primary()
                .keycap(new_cap.clone())
                .tooltip(format!("New Automation ({new_cap})"))
                .on_click(cx.listener(|this, _, window, cx| this.new_automation(window, cx))),
        );

        let body = if !has_any {
            self.render_empty_state(theme, cx)
        } else if items.is_empty() {
            Self::card(theme, 8.)
                .child(
                    div()
                        .p(theme.z(8.))
                        .text_size(theme.z(size::ROW))
                        .text_color(theme.muted)
                        .child("No automations match."),
                )
                .into_any_element()
        } else {
            let header = div()
                .flex()
                .flex_row()
                .items_center()
                .h(theme.z(30.))
                .px(theme.z(8.))
                .gap(theme.z(COLUMN_GAP))
                .child(Self::column_title(theme, "Name").flex_1().min_w(theme.z(160.)))
                .child(Self::column_title(theme, "Schedule").w(theme.z(LIST_COLUMNS[0])).flex_none())
                .child(Self::column_title(theme, "Last run").w(theme.z(LIST_COLUMNS[1])).flex_none())
                .child(Self::column_title(theme, "Agent").w(theme.z(LIST_COLUMNS[2])).flex_none())
                .child(Self::column_title(theme, "Status").w(theme.z(LIST_COLUMNS[3])).flex_none())
                .child(div().w(theme.z(24.)).flex_none());
            let rows: Vec<AnyElement> = items
                .iter()
                .enumerate()
                .map(|(index, item)| {
                    let selected = self.list_selection.selected() == Some(item.automation.id.as_str());
                    self.render_list_row(theme, index, item, now, selected, focused, cx)
                })
                .collect();
            Self::card(theme, 8.).gap(theme.z(2.)).child(header).children(rows).into_any_element()
        };

        div()
            .flex()
            .flex_col()
            .size_full()
            .child(toolbar)
            .child(
                div()
                    .id("automations-list-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .child(Self::column(theme).pt(theme.z(4.)).pb(theme.z(32.)).child(body)),
            )
            .into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn render_list_row(
        &self,
        theme: &SopranoTheme,
        index: usize,
        item: &ListItem,
        now: DateTime<Utc>,
        selected: bool,
        focused: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let automation = &item.automation;
        let id = automation.id.clone();
        let cadence = automation.cadence();
        let (schedule, schedule_mono) = match &cadence {
            AutomationCadence::Custom(expression) => (expression.clone(), true),
            other => (other.summary(), false),
        };
        let next_text = match item.next_run {
            Some(next) => format!("Next {}", format::relative(next, now)),
            None if automation.enabled => "No next run".into(),
            None => "Paused".into(),
        };
        let zone = self.controller.read(cx).clock().time_zone();
        let line = |text: String, muted: bool| {
            div()
                .min_w_0()
                .truncate()
                .text_size(theme.z(if muted { size::META } else { size::ROW }))
                .text_color(if muted { theme.muted } else { theme.foreground })
                .child(text)
        };
        let last_run = match &item.last_run {
            Some(run) => div()
                .flex()
                .flex_col()
                .gap(theme.z(1.))
                .child(Self::pill(pill::run(run.status, None), now))
                .child(line(format::relative(run.finished_at.unwrap_or(run.started_at), now), true))
                .into_any_element(),
            None => line("Never".into(), false).text_color(theme.muted).into_any_element(),
        };
        let open_id = id.clone();
        let menu_id = id.clone();
        let context_id = id.clone();
        div()
            .id(("automations-row", index))
            .relative()
            .child(self.reveal_marker(automation.id.clone()))
            .flex()
            .flex_row()
            .items_center()
            .h(theme.z(LIST_ROW_HEIGHT))
            .px(theme.z(8.))
            .gap(theme.z(COLUMN_GAP))
            .rounded(theme.z(8.))
            .when_some(Self::row_fill(theme, selected, focused), |row, fill| row.bg(fill))
            .when(!selected, |row| row.hover(|row| row.bg(theme.hover)))
            .cursor_pointer()
            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                let ids = this.visible_ids(cx);
                this.list_selection.select(&open_id, &ids);
                this.display(Page::Automation(open_id.clone()), window, cx);
            }))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, event: &gpui::MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    this.open_menu(&context_id, event.position, window, cx);
                }),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w(theme.z(160.))
                    .gap(theme.z(1.))
                    .child(line(automation.name.clone(), false).font_weight(FontWeight::MEDIUM))
                    .child(line(format::first_line(&automation.prompt), true)),
            )
            .child(
                div()
                    .id(("automations-row-schedule", index))
                    .flex()
                    .flex_col()
                    .flex_none()
                    .w(theme.z(LIST_COLUMNS[0]))
                    .gap(theme.z(1.))
                    .child(
                        line(schedule, false).when(schedule_mono, |s| s.font_family(fonts::MONO_FONT_FAMILY)),
                    )
                    .child(line(next_text, true))
                    .when_some(item.next_run, |column, next| {
                        column.tooltip(tooltip(format::date_time(next, zone)))
                    }),
            )
            .child(
                div()
                    .id(("automations-row-last-run", index))
                    .flex_none()
                    .w(theme.z(LIST_COLUMNS[1]))
                    .min_w_0()
                    .when_some(item.last_run.as_ref().and_then(|run| run.message.clone()), |cell, message| {
                        cell.tooltip(tooltip(message))
                    })
                    .child(last_run),
            )
            .child(
                div()
                    .id(("automations-row-agent", index))
                    .flex()
                    .flex_col()
                    .flex_none()
                    .w(theme.z(LIST_COLUMNS[2]))
                    .gap(theme.z(1.))
                    .tooltip(tooltip(automation.folder.clone()))
                    .child(line(format::agent_name(&automation.agent_id), false))
                    .child(line(format::path(&automation.folder), true).font_family(fonts::MONO_FONT_FAMILY)),
            )
            .child(
                div()
                    .flex_none()
                    .w(theme.z(LIST_COLUMNS[3]))
                    .child(Self::pill(pill::state(automation, item.last_run.as_ref()), now)),
            )
            .child(
                div().flex_none().w(theme.z(24.)).child(
                    IconButton::new(("automations-row-menu", index), IconName::Ellipsis)
                        .icon_size(13.)
                        .tooltip("Automation Actions")
                        .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                            cx.stop_propagation();
                            let position = event.mouse_position().unwrap_or_else(|| window.mouse_position());
                            this.open_menu(&menu_id, position, window, cx);
                        })),
                ),
            )
            .into_any_element()
    }

    /// "No automations yet" over Orca's four templates and a blank card.
    fn render_empty_state(&self, theme: &SopranoTheme, cx: &mut Context<Self>) -> AnyElement {
        let mut cards: Vec<AnyElement> = AutomationTemplate::all()
            .into_iter()
            .enumerate()
            .map(|(index, template)| self.template_card(theme, index, Some(template), cx))
            .collect();
        cards.push(self.template_card(theme, cards.len(), None, cx));
        div()
            .id("automations-empty")
            .flex()
            .flex_col()
            .pt(theme.z(24.))
            .pb(theme.z(8.))
            .child(
                div().text_size(theme.z(16.)).font_weight(FontWeight::SEMIBOLD).child("No automations yet"),
            )
            .child(
                div()
                    .mt(theme.z(6.))
                    .text_size(theme.z(size::UI))
                    .text_color(theme.muted)
                    .child("An automation sends a prompt to an agent on a schedule while Soprano is open."),
            )
            .child(
                div()
                    .mt(theme.z(28.))
                    .text_size(theme.z(size::UI))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Start from a template"),
            )
            .child(div().mt(theme.z(12.)).grid().grid_cols(3).gap(theme.z(12.)).children(cards))
            .into_any_element()
    }

    fn template_card(
        &self,
        theme: &SopranoTheme,
        index: usize,
        template: Option<AutomationTemplate>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (title, detail, footer) = match &template {
            Some(template) => {
                (template.label.to_owned(), template.description.to_owned(), template.cadence.summary())
            }
            None => {
                ("New automation".to_owned(), "Write your own prompt and schedule.".to_owned(), String::new())
            }
        };
        let lead = match &template {
            Some(template) => div()
                .mb(theme.z(2.))
                .text_size(theme.z(size::META))
                .font_weight(FontWeight::MEDIUM)
                .text_color(theme.muted)
                .child(template.category)
                .into_any_element(),
            None => div()
                .mb(theme.z(2.))
                .child(icon(IconName::Plus).size(13.).color(theme.muted))
                .into_any_element(),
        };
        div()
            .id(("automations-template", index))
            .flex()
            .flex_col()
            .justify_between()
            .h(theme.z(TEMPLATE_CARD_HEIGHT))
            .p(theme.z(14.))
            .rounded(theme.z(12.))
            .border_1()
            .border_color(theme.border)
            .bg(theme.surface)
            .hover(|card| card.bg(theme.hover))
            .cursor_pointer()
            .on_click(
                cx.listener(move |this, _, window, cx| {
                    this.present_editor(None, template.clone(), window, cx)
                }),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(theme.z(4.))
                    .child(lead)
                    .child(div().text_size(theme.z(size::UI)).font_weight(FontWeight::SEMIBOLD).child(title))
                    .child(
                        div()
                            .text_size(theme.z(size::META))
                            .text_color(theme.muted)
                            .line_clamp(3)
                            .child(detail),
                    ),
            )
            .child(
                div()
                    .text_size(theme.z(size::META))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.muted)
                    .child(footer),
            )
            .into_any_element()
    }

    // MARK: - Rendering: one automation

    fn render_automation(
        &mut self,
        automation: Automation,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (now, zone) = self.now_and_zone(cx);
        let controller = self.controller.read(cx);
        let runs = controller.runs(&automation.id);
        let next_run = controller.next_run_date_of(&automation);
        let focused = self.focus.is_focused(window);
        let id = automation.id.clone();

        let action = |label: &'static str,
                      variant: ButtonVariant,
                      action: AutomationAction,
                      cx: &mut Context<Self>| {
            let id = id.clone();
            Button::new(SharedString::from(format!("automations-detail-{label}")), label)
                .variant(variant)
                .size(ButtonSize::Sm)
                .on_click(cx.listener(move |this, _, window, cx| this.perform(action, &id, window, cx)))
                .into_any_element()
        };
        let buttons = vec![
            action("Run Now", ButtonVariant::Primary, AutomationAction::RunNow, cx),
            action("Edit…", ButtonVariant::Secondary, AutomationAction::Edit, cx),
            action(
                if automation.enabled { "Pause" } else { "Resume" },
                ButtonVariant::Secondary,
                AutomationAction::ToggleEnabled,
                cx,
            ),
            action("Delete…", ButtonVariant::Destructive, AutomationAction::Delete, cx),
        ];
        let mut views: Vec<AnyElement> = vec![
            self.breadcrumb(theme, vec!["Automations".into(), automation.name.clone()], cx),
            Self::title_row(
                theme,
                automation.name.clone(),
                Self::pill(pill::state(&automation, runs.first()), now),
                buttons,
            ),
            // `~/git/shop · Claude Code`
            div()
                .id("automations-detail-meta")
                .flex()
                .flex_row()
                .items_baseline()
                .gap(theme.z(6.))
                .mt(theme.z(-16.))
                .tooltip(tooltip(automation.folder.clone()))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .font_family(fonts::MONO_FONT_FAMILY)
                        .text_size(theme.z(size::META))
                        .text_color(theme.muted)
                        .child(format::path(&automation.folder)),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(theme.z(size::ROW))
                        .text_color(theme.muted)
                        .child(format!("· {}", format::agent_name(&automation.agent_id))),
                )
                .into_any_element(),
        ];

        if let Some(last) = runs.first().filter(|run| run.status == RunStatus::Failed) {
            let run_id = last.id.clone();
            let message = last.message.as_deref().map(format::first_paragraph).unwrap_or_default();
            views.push(
                Self::card(theme, 12.)
                    .flex_row()
                    .items_center()
                    .gap(theme.z(10.))
                    .child(icon(IconName::CircleAlert).size(14.).color(theme.failed))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(theme.z(size::ROW))
                            .text_color(theme.failed)
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("Last run failed."))
                            .when(!message.is_empty(), |text| text.child(message)),
                    )
                    .child(
                        Button::new("automations-view-failed-run", "View Run")
                            .variant(ButtonVariant::Secondary)
                            .size(ButtonSize::Sm)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.display(Page::Run(run_id.clone()), window, cx)
                            })),
                    )
                    .into_any_element(),
            );
        }

        views.push(Self::tile_grid(theme, Self::automation_tiles(theme, &automation, next_run, now, zone)));
        views.push(Self::titled_card(
            theme,
            "Prompt",
            None,
            vec![
                div()
                    .text_size(theme.z(size::UI))
                    .line_height(gpui::relative(1.4))
                    .child(automation.prompt.clone())
                    .into_any_element(),
            ],
        ));
        views.push(self.runs_card(theme, &runs, now, zone, focused, cx));

        div()
            .id("automations-detail")
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .child(Self::column(theme).gap(theme.z(20.)).pt(theme.z(20.)).pb(theme.z(32.)).children(views))
            .into_any_element()
    }

    fn automation_tiles(
        theme: &SopranoTheme,
        automation: &Automation,
        next_run: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
        zone: Tz,
    ) -> Vec<AnyElement> {
        let value = |text: String| Self::tile_value(theme, text, false, false, false);
        let schedule = match automation.cadence() {
            AutomationCadence::Custom(expression) => Self::tile(
                theme,
                "Schedule",
                Self::tile_value(theme, expression, true, false, false),
                Some("Custom cron".into()),
            ),
            cadence => Self::tile(theme, "Schedule", value(cadence.summary()), None),
        };
        let next = match next_run {
            Some(next) => Self::tile(
                theme,
                "Next run",
                value(format::date_time(next, zone)),
                Some(format::relative(next, now)),
            ),
            None => {
                Self::tile(theme, "Next run", Self::tile_value(theme, "Paused", false, true, false), None)
            }
        };
        let precheck = match &automation.precheck {
            Some(command) => Self::tile(
                theme,
                "Precheck",
                Self::tile_value(theme, command.clone(), true, false, false),
                Some(format!("{} timeout", format::timeout(automation.precheck_timeout_seconds))),
            ),
            None => Self::tile(theme, "Precheck", Self::tile_value(theme, "None", false, true, false), None),
        };
        vec![
            schedule,
            next,
            Self::tile(theme, "Runs in", value(format::workspace(&automation.workspace)), None),
            Self::tile(theme, "Session", value(format::session(automation.session).into()), None),
            Self::tile(theme, "Grace", value(format::grace(automation.grace_minutes)), None),
            precheck,
            Self::tile(theme, "Agent", value(format::agent_name(&automation.agent_id)), None),
            Self::tile(
                theme,
                "Model",
                match &automation.model {
                    Some(model) => Self::tile_value(theme, model.clone(), true, false, false),
                    None => Self::tile_value(theme, "CLI default", false, true, false),
                },
                None,
            ),
        ]
    }

    /// `Runs  12 runs · 9 completed`, the column titles and one row per run.
    fn runs_card(
        &self,
        theme: &SopranoTheme,
        runs: &[AutomationRun],
        now: DateTime<Utc>,
        zone: Tz,
        focused: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let completed = runs.iter().filter(|run| run.status == RunStatus::Completed).count();
        let hint = (!runs.is_empty())
            .then(|| format!("{} · {completed} completed", format::count(runs.len(), "run")));
        let mut body: Vec<AnyElement> = Vec::new();
        if runs.is_empty() {
            body.push(
                div()
                    .px(theme.z(8.))
                    .pb(theme.z(8.))
                    .text_size(theme.z(size::ROW))
                    .text_color(theme.muted)
                    .child("No runs yet.")
                    .into_any_element(),
            );
        } else {
            body.push(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .h(theme.z(26.))
                    .px(theme.z(8.))
                    .gap(theme.z(COLUMN_GAP))
                    .child(Self::column_title(theme, "Run").w(theme.z(RUN_COLUMNS[0])).flex_none())
                    .child(Self::column_title(theme, "Trigger").w(theme.z(RUN_COLUMNS[1])).flex_none())
                    .child(Self::column_title(theme, "Started").w(theme.z(RUN_COLUMNS[2])).flex_none())
                    .child(Self::column_title(theme, "Duration").w(theme.z(RUN_COLUMNS[3])).flex_none())
                    .child(Self::column_title(theme, "Status").flex_1())
                    .into_any_element(),
            );
            for (index, run) in runs.iter().enumerate() {
                let selected = self.run_selection.selected() == Some(run.id.as_str());
                body.push(self.run_row(theme, index, run, now, zone, selected, focused, cx));
            }
        }
        Self::card(theme, 8.)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_baseline()
                    .gap(theme.z(10.))
                    .p(theme.z(8.))
                    .pb(theme.z(8.))
                    .child(div().text_size(theme.z(size::UI)).font_weight(FontWeight::SEMIBOLD).child("Runs"))
                    .when_some(hint, |row, hint| {
                        row.child(div().text_size(theme.z(size::META)).text_color(theme.muted).child(hint))
                    }),
            )
            .children(body)
            .into_any_element()
    }

    /// One run: `#3  Scheduled  Oct 29, 9:00 AM  4m 12s  ✓ Done`.
    #[allow(clippy::too_many_arguments)]
    fn run_row(
        &self,
        theme: &SopranoTheme,
        index: usize,
        run: &AutomationRun,
        now: DateTime<Utc>,
        zone: Tz,
        selected: bool,
        focused: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (duration, duration_muted) = content::run_duration(run, now);
        let run_id = run.id.clone();
        let cell = |width: f32, text: String| {
            div().flex_none().w(theme.z(width)).truncate().text_size(theme.z(size::ROW)).child(text)
        };
        div()
            .id(("automations-run-row", index))
            .relative()
            .child(self.reveal_marker(run.id.clone()))
            .flex()
            .flex_row()
            .items_center()
            .h(theme.z(RUN_ROW_HEIGHT))
            .px(theme.z(8.))
            .gap(theme.z(COLUMN_GAP))
            .rounded(theme.z(8.))
            .when_some(Self::row_fill(theme, selected, focused), |row, fill| row.bg(fill))
            .when(!selected, |row| row.hover(|row| row.bg(theme.hover)))
            .cursor_pointer()
            .when_some(run.message.clone(), |row, message| row.tooltip(tooltip(message)))
            .on_click(cx.listener(move |this, _, window, cx| {
                if let Page::Automation(automation_id) = this.page.clone() {
                    let ids = this.run_ids(&automation_id, cx);
                    this.run_selection.select(&run_id, &ids);
                }
                this.display(Page::Run(run_id.clone()), window, cx);
            }))
            .child(cell(RUN_COLUMNS[0], format!("#{}", run.number)).font_weight(FontWeight::MEDIUM))
            .child(cell(RUN_COLUMNS[1], format::trigger(run.trigger).into()))
            .child(cell(RUN_COLUMNS[2], format::date_time(run.started_at, zone)))
            .child(cell(RUN_COLUMNS[3], duration).when(duration_muted, |c| c.text_color(theme.muted)))
            .child(div().flex_1().min_w_0().child(Self::pill(pill::run(run.status, None), now)))
            .into_any_element()
    }

    // MARK: - Rendering: one run

    fn render_run(&mut self, run: AutomationRun, theme: &SopranoTheme, cx: &mut Context<Self>) -> AnyElement {
        let (now, zone) = self.now_and_zone(cx);
        let automation = self.controller.read(cx).automation(&run.automation_id);
        let name = automation.as_ref().map_or_else(|| run.automation_id.clone(), |a| a.name.clone());
        let live = self.is_live(&run, cx);

        let mut buttons: Vec<AnyElement> = Vec::new();
        let open_title = if run.target().is_some() && live {
            Some("Open Run")
        } else if run.conversation.is_some() && AgentConversation::supports(&run.profile_id) {
            Some("Resume Conversation")
        } else {
            None
        };
        if let Some(title) = open_title {
            let run_id = run.id.clone();
            buttons.push(
                Button::new("automations-open-run", title)
                    .primary()
                    .size(ButtonSize::Sm)
                    .on_click(cx.listener(move |_, _, _, cx| {
                        cx.emit(AutomationsPageEvent::OpenRun { run_id: run_id.clone() })
                    }))
                    .into_any_element(),
            );
        }
        if let Some(worktree) = run.worktree.clone().filter(|w| !w.removed) {
            buttons.push(
                Button::new("automations-reveal-worktree", "Reveal Worktree")
                    .variant(ButtonVariant::Secondary)
                    .size(ButtonSize::Sm)
                    .on_click(move |_, _, _| {
                        let _ = soprano_platform::system::reveal_in_file_manager(std::path::Path::new(
                            &worktree.path,
                        ));
                    })
                    .into_any_element(),
            );
        }

        let mut views: Vec<AnyElement> = vec![
            self.breadcrumb(theme, vec!["Automations".into(), name.clone(), format!("#{}", run.number)], cx),
            Self::title_row(
                theme,
                AutomationController::run_title(&name, run.number),
                Self::pill(pill::for_run(&run), now),
                buttons,
            ),
            Self::tile_grid(theme, Self::run_tiles(theme, &run, now, zone)),
        ];
        if let Some(message) = &run.message {
            let (reason, output) = content::message_parts(message);
            let mut body = vec![div().text_size(theme.z(size::UI)).child(reason).into_any_element()];
            if let Some(output) = output {
                body.push(
                    Markdown::new(
                        "automations-run-precheck-output",
                        content::fenced_code(&output),
                        MarkdownStyle::ASSISTANT,
                    )
                    .into_any_element(),
                );
            }
            views.push(Self::titled_card(theme, content::message_title(run.status), None, body));
        }
        if let Some(worktree) = &run.worktree {
            views.push(Self::worktree_card(theme, worktree));
        }
        let report = match &run.output {
            Some(output) => div()
                .id("automations-run-report")
                .w_full()
                .child(Markdown::new(
                    "automations-run-report-markdown",
                    output.clone(),
                    MarkdownStyle::ASSISTANT,
                ))
                .into_any_element(),
            None => div()
                .text_size(theme.z(size::ROW))
                .text_color(theme.muted)
                .child(if run.status.is_final() { "No report" } else { "No report yet" })
                .into_any_element(),
        };
        views.push(Self::titled_card(theme, "Report", None, vec![report]));

        div()
            .id("automations-run")
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .child(Self::column(theme).gap(theme.z(20.)).pt(theme.z(20.)).pb(theme.z(32.)).children(views))
            .into_any_element()
    }

    fn run_tiles(theme: &SopranoTheme, run: &AutomationRun, now: DateTime<Utc>, zone: Tz) -> Vec<AnyElement> {
        let value = |text: String| Self::tile_value(theme, text, false, false, false);
        let muted = |text: String| Self::tile_value(theme, text, false, true, false);
        let mut tiles =
            vec![Self::tile(theme, "Started", value(format::date_time(run.started_at, zone)), None)];
        tiles.push(match run.finished_at {
            Some(finished) => Self::tile(theme, "Finished", value(format::date_time(finished, zone)), None),
            None => Self::tile(
                theme,
                "Finished",
                muted(if run.status.is_final() { "—".into() } else { "Not yet".into() }),
                None,
            ),
        });
        tiles.push(match run.duration() {
            Some(duration) => Self::tile(theme, "Duration", value(format::duration(duration)), None),
            None => Self::tile(
                theme,
                "Duration",
                muted(format!("{} so far", format::duration(now - run.started_at))),
                None,
            ),
        });
        if run.trigger == RunTrigger::Scheduled
            && let Some(scheduled_for) = run.scheduled_for
        {
            tiles.push(Self::tile(
                theme,
                "Scheduled for",
                value(format::date_time(scheduled_for, zone)),
                None,
            ));
        }
        tiles.push(Self::tile(theme, "Trigger", value(format::trigger(run.trigger).into()), None));
        tiles.push(Self::tile(theme, "Agent", value(format::agent_name(&run.profile_id)), None));
        tiles.push(
            div()
                .id("automations-run-folder")
                .tooltip(tooltip(run.folder.clone()))
                .child(Self::tile(
                    theme,
                    "Worked in",
                    Self::tile_value(theme, format::path(&run.folder), false, false, true),
                    None,
                ))
                .into_any_element(),
        );
        tiles
    }

    fn worktree_card(theme: &SopranoTheme, worktree: &RunWorktree) -> AnyElement {
        let mut body = vec![
            div()
                .font_family(fonts::MONO_FONT_FAMILY)
                .text_size(theme.z(size::ROW))
                .text_color(if worktree.removed { theme.muted } else { theme.foreground })
                .child(format::path(&worktree.path))
                .into_any_element(),
            div()
                .font_family(fonts::MONO_FONT_FAMILY)
                .text_size(theme.z(size::META))
                .text_color(theme.muted)
                .child(worktree.branch.clone())
                .into_any_element(),
        ];
        if worktree.removed {
            body.push(
                div()
                    .text_size(theme.z(size::META))
                    .text_color(theme.muted)
                    .child("Removed, the run changed nothing.")
                    .into_any_element(),
            );
        }
        Self::titled_card(theme, "Worktree", None, body)
    }
}

impl Render for AutomationsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.reconcile(cx);
        let theme = cx.soprano_theme().clone();
        let (now, _) = self.now_and_zone(cx);
        let controller = self.controller.read(cx);
        let automations = controller.automations();
        let next_runs: Vec<DateTime<Utc>> =
            automations.iter().filter_map(|automation| controller.next_run_date_of(automation)).collect();
        let subtitle = content::subtitle(automations.len(), &next_runs, now);

        let body = match self.page.clone() {
            Page::List => self.render_list(&theme, window, cx),
            Page::Automation(id) => match self.controller.read(cx).automation(&id) {
                Some(automation) => self.render_automation(automation, &theme, window, cx),
                None => self.render_list(&theme, window, cx),
            },
            Page::Run(id) => match self.controller.read(cx).run(&id).cloned() {
                Some(run) => self.render_run(run, &theme, cx),
                None => self.render_list(&theme, window, cx),
            },
        };
        let header = self.header(&theme, subtitle, cx);

        div()
            .id("automations")
            .key_context("AutomationsPage")
            .track_focus(&self.focus)
            .capture_key_down(cx.listener(Self::on_key))
            .capture_action(cx.listener(|this, _: &MoveDown, window, cx| this.search_move(1, window, cx)))
            .capture_action(cx.listener(|this, _: &MoveUp, window, cx| this.search_move(-1, window, cx)))
            .capture_action(cx.listener(Self::search_escape))
            .relative()
            .flex()
            .flex_col()
            .size_full()
            .bg(theme.background)
            .text_color(theme.foreground)
            .font_family(fonts::UI_FONT_FAMILY)
            .child(header)
            .child(div().flex_1().min_h_0().child(body))
            .when_some(self.editor.as_ref().map(|(editor, _)| editor.clone()), |page, editor| {
                page.child(editor)
            })
            .when_some(self.dialog.as_ref().map(|(dialog, _)| dialog.clone()), |page, dialog| {
                page.child(dialog)
            })
            .when_some(self.menu.as_ref().map(|(menu, _)| menu.clone()), |page, menu| page.child(menu))
    }
}
