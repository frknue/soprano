//! The right sidebar (`RightSidebarView.swift` + the right-sidebar parts of
//! `MainContentViewController.swift`): both panels, which one shows, whether the sidebar
//! is open and how wide. It draws the active card and the resizable leading edge; the
//! app shell places it (with `frame_width()`) and supplies the window width it may share.
//!
//! A panel only reads and watches the disk while the sidebar is open and showing it.

use gpui::{
    App, Context, Entity, InteractiveElement, IntoElement, MouseButton, MouseMoveEvent, MouseUpEvent,
    ParentElement, Pixels, Render, Styled, Subscription, Window, canvas, div, prelude::*, px,
};
use soprano_platform::StateStore;
use soprano_ui::ActiveSopranoTheme;

use crate::sidebar::{PanelToggle, RightSidebarState, RightSidebarTab};
use crate::{ChangesPanel, FilesPanel, SidebarEvent};

/// The leading edge's grab area.
const HANDLE_WIDTH: f32 = 6.0;

pub struct RightSidebar {
    state: RightSidebarState,
    files: Entity<FilesPanel>,
    changes: Entity<ChangesPanel>,
    /// Window width minus the left sidebar: what a drag may share with the panes.
    available_width: Option<f32>,
    /// The sidebar's right edge in window coordinates while the edge is dragged.
    resizing: Option<Pixels>,
    resize_highlighted: bool,
    _subscriptions: Vec<Subscription>,
}

impl RightSidebar {
    pub fn new(store: StateStore, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let files = cx.new(|cx| FilesPanel::new(store.clone(), window, cx));
        let changes = cx.new(|cx| ChangesPanel::new(window, cx));
        let subscriptions = vec![
            cx.subscribe(&files, |_, _, event: &SidebarEvent, cx| cx.emit(event.clone())),
            cx.subscribe(&changes, |_, _, event: &SidebarEvent, cx| cx.emit(event.clone())),
        ];
        let mut sidebar = Self {
            state: RightSidebarState::load(store),
            files,
            changes,
            available_width: None,
            resizing: None,
            resize_highlighted: false,
            _subscriptions: subscriptions,
        };
        sidebar.update_activity(cx);
        sidebar
    }

    pub fn files(&self) -> &Entity<FilesPanel> {
        &self.files
    }

    pub fn changes(&self) -> &Entity<ChangesPanel> {
        &self.changes
    }

    pub fn tab(&self) -> RightSidebarTab {
        self.state.tab()
    }

    pub fn is_open(&self) -> bool {
        self.state.is_open()
    }

    /// The width while open.
    pub fn width(&self) -> f32 {
        self.state.width()
    }

    /// The width the shell gives the sidebar now (0 while closed).
    pub fn frame_width(&self) -> f32 {
        self.state.frame_width()
    }

    /// Window width minus the left sidebar (`None`: no cap besides the maximum).
    pub fn set_available_width(&mut self, width: Option<f32>) {
        self.available_width = width;
    }

    /// The focused pane's working directory, for both panels (`None` keeps the roots).
    pub fn set_working_directory(&mut self, cwd: Option<&str>, cx: &mut Context<Self>) {
        self.files.update(cx, |files, cx| files.set_working_directory(cwd, cx));
        self.changes.update(cx, |changes, cx| changes.set_working_directory(cwd, cx));
    }

    /// Whether the keyboard is in either panel.
    pub fn contains_focus(&self, window: &Window, cx: &App) -> bool {
        self.files.read(cx).contains_focus(window, cx) || self.changes.read(cx).contains_focus(window, cx)
    }

    /// Shows `tab` and remembers it; the keyboard moves along when it was in the panel
    /// being hidden.
    pub fn select_tab(&mut self, tab: RightSidebarTab, window: &mut Window, cx: &mut Context<Self>) {
        let had_focus = self.contains_focus(window, cx);
        if !self.state.select_tab(tab) {
            return;
        }
        self.update_activity(cx);
        if had_focus {
            self.focus_active_panel(window, cx);
        }
        cx.notify();
    }

    /// Opens or closes the sidebar (remembered). A closing sidebar hands the keyboard back
    /// to the panes ([`SidebarEvent::FocusPane`]).
    pub fn set_open(&mut self, open: bool, window: &mut Window, cx: &mut Context<Self>) {
        let had_focus = self.contains_focus(window, cx);
        if !self.state.set_open(open) {
            return;
        }
        self.update_activity(cx);
        if !open && had_focus {
            cx.emit(SidebarEvent::FocusPane);
        }
        cx.notify();
    }

    /// ⌘L / the Files and Changes toggles.
    pub fn toggle_open(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let open = !self.state.is_open();
        self.set_open(open, window, cx);
    }

    /// ⇧⌘E: opens the explorer and moves the keyboard into it; pressed again while the
    /// explorer has the keyboard, hides the sidebar and returns to the panes.
    pub fn toggle_explorer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.toggle_tab(RightSidebarTab::Explorer, window, cx);
    }

    /// ⇧⌘G: the same for the Changes list.
    pub fn toggle_source_control(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.toggle_tab(RightSidebarTab::SourceControl, window, cx);
    }

    fn toggle_tab(&mut self, tab: RightSidebarTab, window: &mut Window, cx: &mut Context<Self>) {
        let had_focus = self.contains_focus(window, cx);
        match self.state.toggle_tab(tab, had_focus) {
            PanelToggle::Hide => {
                self.update_activity(cx);
                cx.emit(SidebarEvent::FocusPane);
            }
            PanelToggle::ShowAndFocus => {
                self.update_activity(cx);
                self.focus_active_panel(window, cx);
            }
        }
        cx.notify();
    }

    /// Moves the keyboard into the active panel's list.
    pub fn focus_active_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.state.tab() {
            RightSidebarTab::Explorer => self.files.update(cx, |files, cx| files.focus_tree(window, cx)),
            RightSidebarTab::SourceControl => {
                self.changes.update(cx, |changes, cx| changes.focus_list(window, cx))
            }
        }
    }

    fn update_activity(&mut self, cx: &mut Context<Self>) {
        let open = self.state.is_open();
        let tab = self.state.tab();
        self.files.update(cx, |files, cx| files.set_active(open && tab == RightSidebarTab::Explorer, cx));
        self.changes
            .update(cx, |changes, cx| changes.set_active(open && tab == RightSidebarTab::SourceControl, cx));
    }

    /// Double-clicking the edge restores the default width.
    pub fn reset_width(&mut self, cx: &mut Context<Self>) {
        self.state.reset_width();
        cx.notify();
    }

    fn drag_to(&mut self, x: Pixels, cx: &mut Context<Self>) {
        let Some(right) = self.resizing else { return };
        let proposed = f32::from(right - x) / cx.soprano_theme().zoom();
        if self.state.drag_width(proposed, self.available_width) {
            cx.notify();
        }
    }

    fn end_resize(&mut self, cx: &mut Context<Self>) {
        if self.resizing.take().is_some() {
            self.state.save_width();
            self.resize_highlighted = false;
            cx.notify();
        }
    }
}

impl Render for RightSidebar {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        if !self.state.is_open() {
            return div().into_any_element();
        }
        let panel = match self.state.tab() {
            RightSidebarTab::Explorer => self.files.clone().into_any_element(),
            RightSidebarTab::SourceControl => self.changes.clone().into_any_element(),
        };
        let highlight = if self.resize_highlighted { t.input } else { gpui::transparent_black() };
        let entity = cx.entity().downgrade();
        let resizing = self.resizing.is_some();
        div()
            .relative()
            .h_full()
            .w(t.z(self.state.width()))
            .child(panel)
            .child(
                div()
                    .id("right-sidebar-resize-handle")
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .left(-t.z(HANDLE_WIDTH + 1.))
                    .w(t.z(HANDLE_WIDTH))
                    .cursor_col_resize()
                    .child(div().absolute().top_0().bottom_0().right(px(0.)).w(px(1.)).bg(highlight))
                    .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                        if this.resizing.is_none() {
                            this.resize_highlighted = *hovered;
                            cx.notify();
                        }
                    }))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, event: &gpui::MouseDownEvent, _, cx| {
                            cx.stop_propagation();
                            if event.click_count >= 2 {
                                this.reset_width(cx);
                                return;
                            }
                            let zoom = cx.soprano_theme().zoom();
                            // The sidebar's right edge stays put while its leading edge moves.
                            this.resizing = Some(event.position.x + px(this.state.width() * zoom));
                            this.resize_highlighted = true;
                            cx.notify();
                        }),
                    ),
            )
            .when(resizing, |sidebar| {
                // While dragging, follow the pointer anywhere in the window.
                sidebar.child(
                    canvas(
                        |_, _, _| {},
                        move |_, _, window, _| {
                            let moved = entity.clone();
                            window.on_mouse_event(move |event: &MouseMoveEvent, phase, _, cx| {
                                if phase.bubble() {
                                    moved.update(cx, |this, cx| this.drag_to(event.position.x, cx)).ok();
                                }
                            });
                            let released = entity.clone();
                            window.on_mouse_event(move |_: &MouseUpEvent, phase, _, cx| {
                                if phase.bubble() {
                                    released.update(cx, |this, cx| this.end_resize(cx)).ok();
                                }
                            });
                        },
                    )
                    .absolute()
                    .size_0(),
                )
            })
            .into_any_element()
    }
}
