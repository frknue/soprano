//! Both cards side by side on the current directory: `cargo run -p soprano-explorer --example
//! explorer_demo`. Panel events are printed to stderr.

use gpui::{
    App, AppContext, Bounds, Context, Entity, Render, Window, WindowBounds, WindowOptions, div, prelude::*,
    px, size,
};
use soprano_explorer::{ChangesPanel, FilesPanel, SidebarEvent};
use soprano_platform::StateStore;
use soprano_ui::ActiveSopranoTheme;
use soprano_ui::theme::AppearancePreference;

struct Demo {
    files: Entity<FilesPanel>,
    changes: Entity<ChangesPanel>,
}

impl Demo {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let cwd = std::env::current_dir().map(|path| path.to_string_lossy().into_owned()).unwrap_or_default();
        let files = cx.new(|cx| FilesPanel::new(StateStore::in_memory(), window, cx));
        let changes = cx.new(|cx| ChangesPanel::new(window, cx));
        files.update(cx, |files, cx| {
            files.set_working_directory(Some(&cwd), cx);
            files.set_active(true, cx);
        });
        changes.update(cx, |changes, cx| {
            changes.set_working_directory(Some(&cwd), cx);
            changes.set_active(true, cx);
        });
        cx.subscribe(&files, |_, _, event: &SidebarEvent, _| eprintln!("files: {event:?}")).detach();
        cx.subscribe(&changes, |_, _, event: &SidebarEvent, _| eprintln!("changes: {event:?}")).detach();
        Self { files, changes }
    }
}

impl Render for Demo {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        theme.apply_to_window(window);
        div()
            .size_full()
            .flex()
            .gap(theme.z(8.))
            .p(theme.z(8.))
            .bg(theme.canvas)
            .font_family(soprano_ui::fonts::UI_FONT_FAMILY)
            .child(div().w(theme.z(368.)).h_full().child(self.files.clone()))
            .child(div().w(theme.z(368.)).h_full().child(self.changes.clone()))
    }
}

fn main() {
    gpui_platform::application()
        .with_assets(soprano_ui::SopranoAssets::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../../resources")))
        .run(|cx: &mut App| {
            soprano_ui::init(cx, "folio", AppearancePreference::System);
            let bounds = Bounds::centered(None, size(px(780.), px(640.)), cx);
            cx.open_window(
                WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..Default::default() },
                |window, cx| {
                    let demo = cx.new(|cx| Demo::new(window, cx));
                    cx.new(|cx| gpui_component::Root::new(demo, window, cx))
                },
            )
            .expect("window opens");
            cx.activate(true);
        });
}
