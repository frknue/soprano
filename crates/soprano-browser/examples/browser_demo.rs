//! Opens one browser tab: `cargo run -p soprano-browser --example browser_demo [url]`.

use gpui::{App, AppContext as _, WindowOptions};
use soprano_browser::{BrowserTarget, BrowserView};

fn main() {
    let url = std::env::args().nth(1).unwrap_or_else(|| "localhost:5173".to_string());
    gpui_platform::application().run(move |cx: &mut App| {
        gpui_component::init(cx);
        soprano_browser::bind_keys(cx);
        cx.open_window(WindowOptions::default(), |window, cx| {
            let browser =
                cx.new(|cx| BrowserView::new(BrowserTarget::new("pane-1", "tab-1"), Some(&url), window, cx));
            cx.new(|cx| gpui_component::Root::new(browser, window, cx))
        })
        .expect("the demo window opens");
        cx.activate(true);
    });
}
