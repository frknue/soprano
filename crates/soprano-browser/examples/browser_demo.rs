//! Opens one browser tab: `cargo run -p soprano-browser --example browser_demo [url]`.

use gpui::{App, AppContext as _, WindowOptions};
use soprano_browser::BrowserView;
use soprano_types::TerminalTarget;
use soprano_ui::{ActiveSopranoTheme as _, AppearancePreference, SopranoAssets};

fn main() {
    let url = std::env::args().nth(1).unwrap_or_else(|| "localhost:5173".to_string());
    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(move |cx: &mut App| {
        soprano_ui::init(cx, "folio", AppearancePreference::System);
        soprano_browser::bind_keys(cx);
        cx.open_window(WindowOptions::default(), |window, cx| {
            cx.soprano_theme().apply_to_window(window);
            let browser =
                cx.new(|cx| BrowserView::new(TerminalTarget::new("pane-1", "tab-1"), Some(&url), window, cx));
            cx.new(|cx| gpui_component::Root::new(browser, window, cx))
        })
        .expect("the demo window opens");
        cx.activate(true);
    });
}
