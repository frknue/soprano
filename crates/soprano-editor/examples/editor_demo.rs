//! One window with the three file surfaces side by side: a file in the editor, its git diff,
//! and a Markdown file in the reader.
//!
//! `cargo run -p soprano-editor --example editor_demo -- [file] [markdown-file]`
//! (defaults: this example's source and the repository README).

use std::path::PathBuf;

use gpui::{
    App, AppContext as _, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled, Window,
    WindowBounds, WindowOptions, div, px, size,
};
use gpui_component::Root;
use soprano_editor::{DiffView, EditorDocuments, EditorView, MarkdownReaderView, diff_view, editor, reader};
use soprano_platform::state::StateStore;
use soprano_ui::{ActiveSopranoTheme, AppearancePreference, SopranoAssets};

struct Demo {
    editor: Entity<EditorView<String>>,
    diff: Entity<DiffView>,
    reader: Entity<MarkdownReaderView>,
}

impl Render for Demo {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme();
        theme.apply_to_window(window);
        let card = |child: gpui::AnyView| {
            div()
                .flex_1()
                .min_w_0()
                .h_full()
                .rounded(px(10.0))
                .overflow_hidden()
                .border_1()
                .border_color(theme.border)
                .child(child)
        };
        div()
            .size_full()
            .flex()
            .flex_row()
            .gap(px(8.0))
            .p(px(8.0))
            .bg(theme.canvas)
            .text_color(theme.foreground)
            .font_family(soprano_ui::fonts::UI_FONT_FAMILY)
            .child(card(self.editor.clone().into()))
            .child(card(self.diff.clone().into()))
            .child(card(self.reader.clone().into()))
    }
}

fn main() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut args = std::env::args().skip(1);
    let file = args.next().map(PathBuf::from).unwrap_or_else(|| manifest.join("examples/editor_demo.rs"));
    let markdown = args.next().map(PathBuf::from).unwrap_or_else(|| manifest.join("../../README.md"));

    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(move |cx: &mut App| {
        soprano_ui::init(cx, soprano_ui::theme::FOLIO_ID, AppearancePreference::System);
        let bindings: Vec<_> = editor::key_bindings(cx)
            .into_iter()
            .chain(diff_view::key_bindings(cx))
            .chain(reader::key_bindings(cx))
            .collect();
        cx.bind_keys(bindings);
        let documents = cx.new(|_| EditorDocuments::<String>::new());
        let bounds = Bounds::centered(None, size(px(1500.0), px(900.0)), cx);
        let opened = cx.open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..WindowOptions::default() },
            |window, cx| {
                let editor = cx.new(|cx| {
                    EditorView::new(documents.clone(), "demo-tab".to_string(), file.clone(), window, cx)
                });
                let diff =
                    cx.new(|cx| DiffView::new(file.clone(), false, StateStore::in_memory(), window, cx));
                let reader = cx.new(|cx| MarkdownReaderView::new(&markdown, window, cx));
                let demo = cx.new(|_| Demo { editor, diff, reader });
                cx.new(|cx| Root::new(demo, window, cx))
            },
        );
        if let Err(error) = opened {
            eprintln!("cannot open a window: {error:#}");
            cx.quit();
        }
        cx.activate(true);
    });
}
