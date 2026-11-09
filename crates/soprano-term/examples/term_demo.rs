//! One window with one terminal running `$SHELL`.
//!
//! `cargo run -p soprano-term --example term_demo`

use gpui::*;
use soprano_term::{TerminalLaunch, TerminalSettings, TerminalTheme, TerminalView, default_key_bindings};

fn main() {
    gpui_platform::application().run(|cx: &mut App| {
        cx.bind_keys(default_key_bindings());
        // The app bundles JetBrains Mono; the demo loads it the same way when it's there.
        let font = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../resources/fonts/JetBrainsMono-Variable.ttf");
        if let Ok(bytes) = std::fs::read(font) {
            let _ = cx.text_system().add_fonts(vec![bytes.into()]);
        }
        let shell = soprano_platform::shell::user_shell();
        let launch = TerminalLaunch { argv: vec![shell, "-l".into()], ..TerminalLaunch::default() };
        let settings = TerminalSettings::from_user_config(TerminalTheme::default());
        let bounds = Bounds::centered(None, size(px(900.0), px(600.0)), cx);
        let opened = cx.open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..WindowOptions::default() },
            |window, cx| {
                let view = cx.new(|cx| {
                    TerminalView::new(launch, settings, window, cx).unwrap_or_else(|e| {
                        eprintln!("cannot start the terminal: {e:#}");
                        std::process::exit(1)
                    })
                });
                cx.subscribe(&view, |_, event: &soprano_term::TerminalEvent, cx| {
                    if matches!(event, soprano_term::TerminalEvent::CloseRequested) {
                        cx.quit();
                    }
                })
                .detach();
                window.focus(&view.read(cx).focus_handle(cx), cx);
                view
            },
        );
        if let Err(e) = opened {
            eprintln!("cannot open a window: {e:#}");
            cx.quit();
        }
        cx.activate(true);
    });
}
