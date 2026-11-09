//! A select (dropdown): a field-like trigger (h28, px10, radius 8, `input` border, label and
//! chevron) that opens a [`ContextMenu`] of options under itself, the current one checked.

use std::cell::Cell;
use std::rc::Rc;

use gpui::{
    App, AppContext as _, Bounds, Context, DismissEvent, ElementId, Entity, EventEmitter, InteractiveElement,
    IntoElement, ParentElement, Pixels, Render, SharedString, StatefulInteractiveElement, Styled,
    Subscription, Window, canvas, div, point, prelude::*,
};

use crate::fonts::size;
use crate::icons::{IconName, icon};
use crate::menu::{ContextMenu, MenuItem};
use crate::theme::ActiveSopranoTheme;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectOption {
    pub value: SharedString,
    pub label: SharedString,
    pub icon: Option<IconName>,
}

impl SelectOption {
    pub fn new(value: impl Into<SharedString>, label: impl Into<SharedString>) -> Self {
        Self { value: value.into(), label: label.into(), icon: None }
    }

    pub fn icon(mut self, icon: IconName) -> Self {
        self.icon = Some(icon);
        self
    }
}

/// The selection changed (by the person).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectChanged {
    pub index: usize,
    pub value: SharedString,
}

pub struct Select {
    id: ElementId,
    options: Vec<SelectOption>,
    selected: Option<usize>,
    placeholder: SharedString,
    width: Option<f32>,
    disabled: bool,
    menu: Option<(Entity<ContextMenu>, Subscription)>,
    bounds: Rc<Cell<Bounds<Pixels>>>,
}

impl EventEmitter<SelectChanged> for Select {}

impl Select {
    pub fn new(
        id: impl Into<ElementId>,
        options: Vec<SelectOption>,
        selected: Option<usize>,
        cx: &mut App,
    ) -> Entity<Self> {
        let id = id.into();
        cx.new(|_| Self {
            id,
            options,
            selected,
            placeholder: "Select…".into(),
            width: None,
            disabled: false,
            menu: None,
            bounds: Rc::new(Cell::new(Bounds::default())),
        })
    }

    pub fn set_placeholder(&mut self, placeholder: impl Into<SharedString>) {
        self.placeholder = placeholder.into();
    }

    /// Trigger width in designed px (default: fits the label).
    pub fn set_width(&mut self, width: f32) {
        self.width = Some(width);
    }

    pub fn set_disabled(&mut self, disabled: bool, cx: &mut Context<Self>) {
        self.disabled = disabled;
        cx.notify();
    }

    pub fn set_options(
        &mut self,
        options: Vec<SelectOption>,
        selected: Option<usize>,
        cx: &mut Context<Self>,
    ) {
        self.options = options;
        self.selected = selected.filter(|&i| i < self.options.len());
        cx.notify();
    }

    /// Selects without emitting (a settings reload).
    pub fn set_selected(&mut self, selected: Option<usize>, cx: &mut Context<Self>) {
        self.selected = selected.filter(|&i| i < self.options.len());
        cx.notify();
    }

    pub fn selected(&self) -> Option<&SelectOption> {
        self.selected.and_then(|i| self.options.get(i))
    }

    fn open(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let this = cx.entity().downgrade();
        let items = self
            .options
            .iter()
            .enumerate()
            .map(|(index, option)| {
                let this = this.clone();
                let item = MenuItem::new(option.label.clone())
                    .checked(self.selected == Some(index))
                    .on_select(move |_, cx| {
                        this.update(cx, |select, cx| {
                            select.selected = Some(index);
                            let value = select.options[index].value.clone();
                            cx.emit(SelectChanged { index, value });
                            cx.notify();
                        })
                        .ok();
                    });
                match option.icon {
                    Some(name) => item.icon(name),
                    None => item,
                }
            })
            .collect();
        let bounds = self.bounds.get();
        let position = point(bounds.left(), bounds.bottom() + cx.soprano_theme().z(4.));
        let menu = ContextMenu::new(position, items, window, cx);
        let width = (f32::from(bounds.size.width) / cx.soprano_theme().zoom()).max(160.);
        menu.update(cx, |menu, _| menu.set_width(width));
        let subscription = cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.menu = None;
            cx.notify();
        });
        self.menu = Some((menu, subscription));
        cx.notify();
    }
}

impl Render for Select {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let (label, color) = match self.selected() {
            Some(option) => (option.label.clone(), theme.foreground),
            None => (self.placeholder.clone(), theme.dim),
        };
        let open = self.menu.is_some();
        let bounds = self.bounds.clone();
        let hover = theme.hover;
        div()
            .id(self.id.clone())
            .relative()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(8.))
            .h(z(28.))
            .px(z(10.))
            .rounded(z(8.))
            .border_1()
            .border_color(if open { theme.accent } else { theme.input })
            .bg(theme.background)
            .text_size(z(size::META))
            .text_color(color)
            .when_some(self.width, |s, width| s.w(z(width)))
            .when(self.disabled, |s| s.opacity(0.5))
            .when(!self.disabled, |s| s.cursor_pointer().hover(move |st| st.bg(hover)))
            .child(canvas(move |b, _, _| bounds.set(b), |_, _, _, _| {}).absolute().size_full())
            .child(div().flex_1().min_w_0().truncate().child(label))
            .child(icon(IconName::ChevronDown).size(12.).color(theme.dim))
            .when(!self.disabled, |s| s.on_click(cx.listener(|this, _, window, cx| this.open(window, cx))))
            .children(self.menu.as_ref().map(|(menu, _)| menu.clone()))
    }
}
