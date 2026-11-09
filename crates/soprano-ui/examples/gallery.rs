//! Every soprano-ui widget in every state on the current theme, with a theme switcher.
//!
//! `cargo run -p soprano-ui --example gallery`

use std::path::Path;
use std::time::{Duration, SystemTime};

use gpui::{
    App, AppContext as _, Bounds, Context, DismissEvent, Entity, FontWeight, IntoElement, ParentElement,
    Pixels, Point, Render, ScrollHandle, SharedString, Styled, Subscription, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, size,
};
use gpui_component::Root;
use gpui_component::scroll::ScrollbarMode;
use soprano_types::{AgentStatus, AgentWaitingReason};
use soprano_ui::chrome::{
    Card, CardHeader, PanelToggle, ScrollList, SectionHeader, SidebarRow, StatusBar, StatusBarItem, TabPill,
};
use soprano_ui::dialog::{Dialog, DialogContent, DialogResult};
use soprano_ui::fonts::size as font_size;
use soprano_ui::status::{GlyphKind, tab_tooltip};
use soprano_ui::theme::{AppearancePreference, theme_options};
use soprano_ui::{
    ActiveSopranoTheme, Avatar, Button, ButtonSize, ButtonVariant, ContextMenu, Icon, IconButton,
    IconButtonSize, IconName, InputState, Keycaps, MenuItem, Monogram, Picker, PickerEvent, PickerItem,
    SegmentedControl, Select, SelectChanged, SelectOption, SopranoAssets, SopranoTheme, StatusGlyph,
    StatusPill, StatusPillSpec, Switch, TabBadge, TextInput, Toast, ToastLevel, ToastStack, file_type_icon,
    icon,
};

struct Gallery {
    theme_select: Entity<Select>,
    input: Entity<InputState>,
    invalid_input: Entity<InputState>,
    toasts: Entity<ToastStack>,
    menu: Option<Entity<ContextMenu>>,
    dialog: Option<Entity<Dialog>>,
    picker: Option<Entity<Picker>>,
    last_answer: SharedString,
    switch_on: bool,
    segment: usize,
    appearance: usize,
    collapsed: bool,
    selected_row: usize,
    scroll: ScrollHandle,
    _subscriptions: Vec<Subscription>,
}

impl Gallery {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let options: Vec<SelectOption> =
            theme_options().into_iter().map(|option| SelectOption::new(option.id, option.name)).collect();
        let current = cx.soprano_theme().manager().theme_id().to_owned();
        let selected = options.iter().position(|o| o.value.as_ref() == current);
        let theme_select = Select::new("theme", options, selected, cx);
        theme_select.update(cx, |select, _| select.set_width(180.));
        let subscription = cx.subscribe(&theme_select, |_, _, changed: &SelectChanged, cx| {
            SopranoTheme::set_theme(&changed.value, cx);
        });
        let appearance_observer = cx.observe_global::<SopranoTheme>(|_, cx| cx.notify());
        let input = cx.new(|cx| InputState::new(window, cx).placeholder("Commit message"));
        let invalid_input = cx.new(|cx| InputState::new(window, cx).default_value("bad/name"));
        Self {
            theme_select,
            input,
            invalid_input,
            toasts: ToastStack::new(cx),
            menu: None,
            dialog: None,
            picker: None,
            last_answer: "—".into(),
            switch_on: true,
            segment: 0,
            appearance: 0,
            collapsed: false,
            selected_row: 0,
            scroll: ScrollHandle::new(),
            _subscriptions: vec![
                subscription,
                appearance_observer,
                SopranoTheme::observe_system_appearance(window),
            ],
        }
    }

    fn open_menu(&mut self, position: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        let items = vec![
            MenuItem::header("Tab"),
            MenuItem::new("Rename").icon(IconName::SquarePen).shortcut("⌘R"),
            MenuItem::new("New tab").icon(IconName::Plus).shortcut("⌘T"),
            MenuItem::submenu(
                "Open in",
                vec![
                    MenuItem::new("Finder").icon(IconName::Folder),
                    MenuItem::new("Editor").icon(IconName::Code),
                ],
            )
            .icon(IconName::ExternalLink),
            MenuItem::new("Priority").icon(IconName::Clock).checked(true),
            MenuItem::new("Not installed").icon(IconName::Bot).shortcut("not installed").disabled(true),
            MenuItem::separator(),
            MenuItem::new("Close").icon(IconName::X).shortcut("⌘W"),
        ];
        let menu = ContextMenu::new(position, items, window, cx);
        cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.menu = None;
            cx.notify();
        })
        .detach();
        self.menu = Some(menu);
        cx.notify();
    }

    fn open_dialog(&mut self, content: DialogContent, window: &mut Window, cx: &mut Context<Self>) {
        let dialog = Dialog::new(content, window, cx);
        cx.subscribe(&dialog, |this, _, result: &DialogResult, cx| {
            this.last_answer = format!("{:?} {:?}", result.index, result.text).into();
            this.dialog = None;
            cx.notify();
        })
        .detach();
        self.dialog = Some(dialog);
        cx.notify();
    }

    fn open_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let items = vec![
            PickerItem::new("new-tab", "New tab")
                .group("Recent")
                .icon(IconName::Plus)
                .keycaps(vec!["⌘T".into()]),
            PickerItem::new("split-right", "Split right")
                .group("Pane")
                .icon(IconName::SplitRight)
                .description("Open a terminal to the right")
                .keycaps(vec!["⌘D".into()]),
            PickerItem::new("split-down", "Split down")
                .group("Pane")
                .icon(IconName::SplitDown)
                .keycaps(vec!["⇧⌘D".into()]),
            PickerItem::new("git", "Open in Soprano Git")
                .group("App")
                .icon(IconName::GitBranch)
                .keycaps(vec!["⌃A".into(), "G".into()]),
            PickerItem::new("claude", "Launch Claude Code")
                .group("Agent")
                .with_icon(Icon::program("claude"))
                .search_text("anthropic"),
        ];
        let picker = Picker::new(items, window, cx);
        picker.update(cx, |picker, _| picker.set_search_keycaps(vec!["⇧⌘P".into()]));
        cx.subscribe(&picker, |this, _, event: &PickerEvent, cx| {
            this.last_answer = format!("{event:?}").into();
            this.picker = None;
            cx.notify();
        })
        .detach();
        self.picker = Some(picker);
        cx.notify();
    }
}

fn section(title: &str, cx: &App) -> gpui::Div {
    let theme = cx.soprano_theme();
    div().flex().flex_col().gap(theme.z(10.)).child(
        div()
            .text_size(theme.z(font_size::PANEL_TITLE))
            .font_weight(FontWeight::SEMIBOLD)
            .child(title.to_owned()),
    )
}

fn row(cx: &App) -> gpui::Div {
    div().flex().flex_row().flex_wrap().items_center().gap(cx.soprano_theme().z(10.))
}

impl Render for Gallery {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        cx.soprano_theme().apply_to_window(window);
        let theme = cx.soprano_theme().clone();
        let z = |v: f32| theme.z(v);
        let now = SystemTime::now();
        let working_since = now - Duration::from_secs(130);
        let entity = cx.entity();

        let header = row(cx)
            .child(
                div()
                    .text_size(z(font_size::BRAND))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("soprano-ui gallery"),
            )
            .child(self.theme_select.clone())
            .child(
                SegmentedControl::new("appearance", ["System", "Light", "Dark"])
                    .selected(self.appearance)
                    .on_select({
                        let entity = entity.clone();
                        move |index, _, cx| {
                            entity.update(cx, |this, _| this.appearance = index);
                            let preference = [
                                AppearancePreference::System,
                                AppearancePreference::Light,
                                AppearancePreference::Dark,
                            ][index];
                            SopranoTheme::set_appearance(preference, cx);
                        }
                    }),
            )
            .child(
                IconButton::new("zoom-out", IconName::Minus)
                    .tooltip("Zoom out")
                    .on_click(|_, _, cx| SopranoTheme::zoom_out(cx)),
            )
            .child(
                Button::new("zoom-reset", format!("{:.0}%", theme.zoom() * 100.))
                    .size(ButtonSize::Xs)
                    .on_click(|_, _, cx| SopranoTheme::reset_zoom(cx)),
            )
            .child(
                IconButton::new("zoom-in", IconName::Plus)
                    .tooltip("Zoom in")
                    .on_click(|_, _, cx| SopranoTheme::zoom_in(cx)),
            )
            .child(div().text_color(theme.muted).child("Reduce motion"))
            .child(
                Switch::new("reduce-motion", theme.reduce_motion())
                    .on_change(|on, _, cx| SopranoTheme::set_reduce_motion(on, cx)),
            );

        let swatches = [
            ("canvas", theme.canvas),
            ("chrome", theme.chrome),
            ("background", theme.background),
            ("popover", theme.popover),
            ("raised", theme.raised),
            ("hover", theme.hover),
            ("selected", theme.selected),
            ("border", theme.border),
            ("input", theme.input),
            ("foreground", theme.foreground),
            ("muted", theme.muted),
            ("dim", theme.dim),
            ("accent", theme.accent),
            ("solid", theme.solid),
            ("selection", theme.selection),
            ("working", theme.working),
            ("approval", theme.approval),
            ("input tone", theme.input_tone),
            ("failed", theme.failed),
            ("done", theme.done),
            ("running", theme.running_command),
            ("attention", theme.attention),
            ("diff +", theme.diff_add),
            ("diff −", theme.diff_delete),
        ];
        let tokens = section("Tokens", cx)
            .child(row(cx).children(swatches.into_iter().map(|(name, color)| {
                div()
                    .flex()
                    .flex_col()
                    .gap(z(4.))
                    .items_center()
                    .child(div().size(z(36.)).rounded(z(6.)).border_1().border_color(theme.border).bg(color))
                    .child(div().text_size(z(font_size::SMALL)).text_color(theme.muted).child(name))
            })))
            .child(
                row(cx).children(theme.ansi.iter().map(|color| div().size(z(18.)).rounded(z(4.)).bg(*color))),
            );

        let variants = [
            ("Primary", ButtonVariant::Primary),
            ("Secondary", ButtonVariant::Secondary),
            ("Ghost", ButtonVariant::Ghost),
            ("Destructive", ButtonVariant::Destructive),
            ("Don't Save", ButtonVariant::DestructiveOutline),
            ("Text", ButtonVariant::Text),
        ];
        let mut buttons = section("Buttons", cx);
        for (size_index, button_size) in
            [ButtonSize::Xs, ButtonSize::Sm, ButtonSize::Regular].into_iter().enumerate()
        {
            buttons =
                buttons.child(row(cx).children(variants.iter().enumerate().map(|(i, (label, variant))| {
                    Button::new(("button", size_index * 10 + i), *label).variant(*variant).size(button_size)
                })));
        }
        let buttons = buttons
            .child(
                row(cx)
                    .child(Button::new("with-icon", "Commit").primary().icon(IconName::Check).keycap("⌘↵"))
                    .child(Button::new("disabled", "Disabled").disabled(true))
                    .child(Button::new("disabled-primary", "Disabled").primary().disabled(true)),
            )
            .child(
                row(cx)
                    .child(IconButton::new("chrome", IconName::Search).tooltip("Search"))
                    .child(IconButton::new("chrome-on", IconName::Sidebar).selected(true).tooltip("Sidebar"))
                    .child(IconButton::new("chrome-off", IconName::Settings).disabled(true))
                    .child(
                        IconButton::new("pane-split", IconName::SplitRight)
                            .size(IconButtonSize::Pane)
                            .color(theme.dim),
                    )
                    .child(
                        IconButton::new("pane-zoom", IconName::Zoom)
                            .size(IconButtonSize::Pane)
                            .color(theme.dim),
                    )
                    .child(
                        IconButton::new("tab-close", IconName::PaneClose)
                            .size(IconButtonSize::Tab)
                            .color(theme.dim),
                    )
                    .child(IconButton::with_icon("program", Icon::program("claude")).tooltip("Claude Code")),
            );

        let pills = [
            StatusPillSpec::of(AgentStatus::Running, None, Some(working_since)),
            StatusPillSpec::of(AgentStatus::Starting, None, None),
            StatusPillSpec::of(AgentStatus::Waiting, Some(AgentWaitingReason::Approval), None),
            StatusPillSpec::of(AgentStatus::Waiting, Some(AgentWaitingReason::Question), None),
            StatusPillSpec::of(AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded), None),
            StatusPillSpec::of(AgentStatus::Error, None, None),
            StatusPillSpec::of(AgentStatus::Stopped, None, None),
            Some(StatusPillSpec::RUNNING),
        ];
        let status = section("Status", cx)
            .child(
                row(cx)
                    .children(pills.into_iter().map(|pill| StatusPill::new(pill).now(now)))
                    .child(StatusPill::new(None).relative_to(Some(now - Duration::from_secs(7200))).now(now)),
            )
            .child(
                row(cx)
                    .child(StatusGlyph::spinner().color(theme.working))
                    .child(StatusGlyph::needs_you().color(theme.approval))
                    .child(StatusGlyph::new(GlyphKind::Alert).color(theme.failed))
                    .child(StatusGlyph::dot().color(theme.done))
                    .child(StatusGlyph::new(GlyphKind::SmallDot).color(theme.done))
                    .child(StatusGlyph::ring().color(theme.idle)),
            );

        let sidebar = div()
            .flex()
            .flex_col()
            .w(z(268.))
            .h(z(360.))
            .bg(theme.chrome)
            .rounded(z(10.))
            .overflow_hidden()
            .child(
                SectionHeader::new("spaces", "Spaces")
                    .count(3)
                    .collapsed(self.collapsed)
                    .on_toggle({
                        let entity = entity.clone();
                        move |_, _, cx| {
                            entity.update(cx, |this, cx| {
                                this.collapsed = !this.collapsed;
                                cx.notify();
                            })
                        }
                    })
                    .end_slot(
                        IconButton::new("add-space", IconName::Plus)
                            .icon_size(14.)
                            .color(theme.dim)
                            .tooltip("New window"),
                    ),
            )
            .when(!self.collapsed, |sidebar| {
                sidebar.child(
                    ScrollList::new("space-list", &self.scroll)
                        .mode(ScrollbarMode::Always)
                        .px(z(8.))
                        .children(
                            ["dotfiles", "storefront", "soprano", "~", "web3 dashboard", "notes", "infra"]
                                .into_iter()
                                .enumerate()
                                .map(|(index, name)| {
                                    let click = entity.clone();
                                    let menu = entity.clone();
                                    SidebarRow::new(("space", index))
                                        .selected(self.selected_row == index)
                                        .child(if name == "~" {
                                            Avatar::new(name).color(theme.ansi[6])
                                        } else {
                                            Avatar::new(name)
                                        })
                                        .child(div().max_w(z(150.)).truncate().child(name))
                                        .child(div().flex_1())
                                        .when(index == 1, |row| {
                                            row.child(StatusGlyph::spinner().color(theme.working))
                                        })
                                        .when(index == 2, |row| {
                                            row.child(StatusGlyph::needs_you().color(theme.approval))
                                        })
                                        .on_click(move |_, _, cx| {
                                            click.update(cx, |this, cx| {
                                                this.selected_row = index;
                                                cx.notify();
                                            })
                                        })
                                        .on_secondary_click(move |position, window, cx| {
                                            menu.update(cx, |this, cx| this.open_menu(position, window, cx))
                                        })
                                }),
                        ),
                )
            })
            .child(SectionHeader::new("agents", "Agents").medium().count(2))
            .child(
                SidebarRow::new("agent-row")
                    .child(Icon::program("claude").size(16.).color(theme.foreground))
                    .child(div().flex_1().truncate().child("Claude Code"))
                    .child(StatusPill::new(pills[0]).now(now)),
            )
            .child(
                SidebarRow::new("monogram-row")
                    .child(Monogram::new("storefront theme"))
                    .child(div().flex_1().truncate().child("storefront theme"))
                    .child(StatusPill::new(None).relative_to(Some(now - Duration::from_secs(400))).now(now)),
            );

        let agents =
            [(AgentStatus::Running, None), (AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded))];
        let tabs = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(3.))
            .h(z(42.))
            .px(z(10.))
            .bg(theme.chrome)
            .border_b_1()
            .border_color(theme.border)
            .child(TabPill::new("tab-1", "1").icon(Icon::new(IconName::Terminal)).tooltip("Tab 1"))
            .child(
                TabPill::new("tab-2", "Claude Code")
                    .active(true)
                    .icon(Icon::program("claude"))
                    .badges([TabBadge::agents(&agents), TabBadge::running_commands(1)])
                    .tooltip(tab_tooltip(
                        "Tab 2: Claude Code",
                        &[AgentStatus::Running, AgentStatus::Waiting],
                        1,
                    ))
                    .on_close(|_, _, _| {}),
            )
            .child(
                TabPill::new("tab-3", "codex")
                    .icon(Icon::program("codex"))
                    .status(Some(StatusGlyph::spinner().color(theme.working))),
            )
            .child(TabPill::new("tab-4", "Failed").badges([TabBadge::agents(&[(AgentStatus::Error, None)])]))
            .child(div().flex_1())
            .child(IconButton::new("tab-add", IconName::Plus).color(theme.dim))
            .child(PanelToggle::new("files", IconName::File, "Files").on(true))
            .child(PanelToggle::new("changes", IconName::Changes, "Changes"));

        let cards = row(cx)
            .items_start()
            .children(
                [("Unfocused", false, false), ("Focused", true, false), ("Wants you", false, true)]
                    .into_iter()
                    .map(|(title, focused, attention)| {
                        Card::new()
                            .focused(focused)
                            .attention(attention)
                            .w(z(220.))
                            .h(z(120.))
                            .child(
                                CardHeader::pane()
                                    .child(icon(IconName::Terminal).color(theme.dim))
                                    .child(div().font_weight(FontWeight::MEDIUM).child(title))
                                    .child(
                                        div()
                                            .flex_1()
                                            .truncate()
                                            .text_color(theme.dim)
                                            .child("~/git/private"),
                                    ),
                            )
                            .child(
                                div().p(z(12.)).text_color(theme.terminal_foreground).child("$ cargo test"),
                            )
                    }),
            )
            .child(
                Card::new()
                    .w(z(260.))
                    .h(z(120.))
                    .child(
                        CardHeader::panel()
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("Files"))
                            .child(
                                div()
                                    .flex_1()
                                    .text_right()
                                    .text_size(z(font_size::META))
                                    .text_color(theme.dim)
                                    .child("dotfiles"),
                            ),
                    )
                    .child(div().p(z(6.)).children(
                        ["Cargo.toml", "main.rs", "README.md", ".env"].into_iter().enumerate().map(
                            |(index, name)| {
                                SidebarRow::new(("file", index))
                                    .height(28.)
                                    .child(icon(file_type_icon(name)).color(theme.muted))
                                    .child(div().truncate().child(name))
                            },
                        ),
                    )),
            );

        let entity_for_menu = entity.clone();
        let controls = section("Controls", cx)
            .child(
                row(cx)
                    .child(Switch::new("switch", self.switch_on).on_change({
                        let entity = entity.clone();
                        move |on, _, cx| {
                            entity.update(cx, |this, cx| {
                                this.switch_on = on;
                                cx.notify();
                            })
                        }
                    }))
                    .child(Switch::new("switch-off", false))
                    .child(Switch::new("switch-disabled", true).disabled(true))
                    .child(
                        SegmentedControl::new("segments", ["Grouped", "Priority", "Disabled"])
                            .selected(self.segment)
                            .disabled_segments([2])
                            .on_select({
                                let entity = entity.clone();
                                move |index, _, cx| {
                                    entity.update(cx, |this, cx| {
                                        this.segment = index;
                                        cx.notify();
                                    })
                                }
                            }),
                    ),
            )
            .child(
                row(cx)
                    .child(div().w(z(260.)).child(TextInput::new(&self.input)))
                    .child(div().w(z(260.)).child(TextInput::new(&self.invalid_input).small().invalid(true)))
                    .child(
                        div().w(z(300.)).child(
                            TextInput::new(&self.input)
                                .large()
                                .accent()
                                .prefix(icon(IconName::Search).size(15.).color(theme.dim))
                                .suffix(
                                    div().text_size(z(font_size::SMALL)).text_color(theme.dim).child("Esc"),
                                ),
                        ),
                    ),
            )
            .child(
                row(cx)
                    .child(Keycaps::new(["⌘D"]))
                    .child(Keycaps::new(["⇧⌘P"]))
                    .child(Keycaps::new(["⌃A", "G"]))
                    .child(Keycaps::new(["esc"]).small())
                    .child(Keycaps::alternatives(vec![vec!["⌘D".into()], vec!["⌃A".into(), "|".into()]])),
            );

        let overlays = section("Overlays", cx)
            .child(
                row(cx)
                    .child(Button::new("open-menu", "Context menu").on_click(move |event, window, cx| {
                        entity_for_menu.update(cx, |this, cx| this.open_menu(event.position(), window, cx))
                    }))
                    .child(Button::new("open-confirm", "Confirm").on_click({
                        let entity = entity.clone();
                        move |_, window, cx| {
                            entity.update(cx, |this, cx| {
                                this.open_dialog(
                                    DialogContent::confirm(
                                        "Close Session?",
                                        "Its 3 windows and their panes close.",
                                        "Close Session",
                                        true,
                                    ),
                                    window,
                                    cx,
                                )
                            })
                        }
                    }))
                    .child(Button::new("open-save", "Save changes").on_click({
                        let entity = entity.clone();
                        move |_, window, cx| {
                            entity.update(cx, |this, cx| {
                                this.open_dialog(
                                    DialogContent::save_changes(
                                        "Save changes to main.rs?",
                                        "Your changes are lost if you don't save them.",
                                    ),
                                    window,
                                    cx,
                                )
                            })
                        }
                    }))
                    .child(Button::new("open-prompt", "Prompt").on_click({
                        let entity = entity.clone();
                        move |_, window, cx| {
                            entity.update(cx, |this, cx| {
                                let content = DialogContent::prompt(
                                    "Rename Session",
                                    "Name this group of windows.",
                                    "Session name",
                                    "Main",
                                    "Rename",
                                )
                                .hint("Slashes are not allowed.")
                                .validate(|text| {
                                    if text.contains('/') {
                                        Err("Names can't contain a slash.".into())
                                    } else {
                                        Ok(())
                                    }
                                });
                                this.open_dialog(content, window, cx)
                            })
                        }
                    }))
                    .child(Button::new("open-alert", "Alert").on_click({
                        let entity = entity.clone();
                        move |_, window, cx| {
                            entity.update(cx, |this, cx| {
                                this.open_dialog(
                                    DialogContent::alert(
                                        "Update ready",
                                        "Restart Soprano to finish updating.",
                                    ),
                                    window,
                                    cx,
                                )
                            })
                        }
                    }))
                    .child(Button::new("open-picker", "Picker").primary().keycap("⇧⌘P").on_click({
                        let entity = entity.clone();
                        move |_, window, cx| entity.update(cx, |this, cx| this.open_picker(window, cx))
                    }))
                    .children(
                        [ToastLevel::Info, ToastLevel::Success, ToastLevel::Warning, ToastLevel::Error]
                            .into_iter()
                            .enumerate()
                            .map(|(index, level)| {
                                let toasts = self.toasts.clone();
                                Button::new(("toast", index), format!("{level:?} toast"))
                                    .size(ButtonSize::Sm)
                                    .on_click(move |_, _, cx| {
                                        toasts.update(cx, |stack, cx| {
                                            stack.push(
                                                Toast::new(level, format!("{level:?}"))
                                                    .body("Something happened in a background pane."),
                                                cx,
                                            );
                                        });
                                    })
                            }),
                    ),
            )
            .child(div().text_color(theme.muted).child(format!("Last answer: {}", self.last_answer)));

        let icons = section("Icons", cx).child(row(cx).children(IconName::ALL.iter().map(|name| {
            div()
                .id(SharedString::from(name.stem()))
                .p(z(4.))
                .rounded(z(4.))
                .hover(|s| s.bg(theme.hover))
                .tooltip(soprano_ui::tooltip(name.stem()))
                .child(icon(*name).size(16.).color(theme.foreground))
        })));

        let status_bar = StatusBar::new()
            .child(StatusBarItem::new("This computer").icon(IconName::Monitor))
            .child(StatusBarItem::new("main").icon(IconName::Branch))
            .child(StatusBarItem::new("2 agents").dot(theme.dim))
            .child(StatusBarItem::new("· 1 needs you").color(theme.approval))
            .end(div().text_color(theme.dim).child(Keycaps::new(["⇧⌘P"]).small()));

        div()
            .size_full()
            .relative()
            .flex()
            .flex_col()
            .bg(theme.canvas)
            .text_color(theme.foreground)
            .font_family(soprano_ui::fonts::UI_FONT_FAMILY)
            .text_size(z(font_size::UI))
            .child(tabs)
            .child(
                div()
                    .id("gallery-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p(z(16.))
                    .flex()
                    .flex_col()
                    .gap(z(24.))
                    .child(header)
                    .child(tokens)
                    .child(buttons)
                    .child(status)
                    .child(row(cx).items_start().child(sidebar).child(cards))
                    .child(controls)
                    .child(overlays)
                    .child(icons),
            )
            .child(status_bar)
            .children(self.menu.clone())
            .children(self.picker.clone())
            .children(self.dialog.clone())
            .child(self.toasts.clone())
    }
}

fn main() {
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources");
    gpui_platform::application().with_assets(SopranoAssets::new(resources.clone())).run(
        move |cx: &mut App| {
            soprano_ui::init(cx, "folio", AppearancePreference::System);
            if let Err(error) = soprano_ui::fonts::register_fonts_from(&resources.join("fonts"), cx) {
                eprintln!("fonts: {error:#}");
            }
            let bounds = Bounds::centered(None, size(px(1280.), px(900.)), cx);
            let options =
                WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..Default::default() };
            cx.open_window(options, |window, cx| {
                let gallery = cx.new(|cx| Gallery::new(window, cx));
                cx.new(|cx| Root::new(gallery, window, cx))
            })
            .expect("open the gallery window");
            cx.activate(true);
        },
    );
}
