//! The main window's frame per OS: the only module that knows how each platform draws the title
//! bar. macOS gets a transparent title bar with the traffic lights at (12, 16) over the brand
//! row (`MainWindowAppearance`); `hideWindowBar` hides them. Linux and Windows draw client-side
//! decorations: Soprano's own min/max/close buttons at the right end of the top tab row
//! (HERDR-UI §6), which `hideWindowBar` hides.

use gpui::{
    App, Bounds, InteractiveElement, IntoElement, ParentElement, Pixels, RenderOnce, Size,
    StatefulInteractiveElement, Styled, TitlebarOptions, Window, WindowBackgroundAppearance, WindowBounds,
    WindowDecorations, WindowOptions, div, point, px, rgb,
};
use soprano_ui::{ActiveSopranoTheme, Icon, IconName};

use crate::sizing;

/// Where the traffic lights sit (HERDR-UI §1).
pub const TRAFFIC_LIGHTS: (f32, f32) = (12.0, 16.0);
/// The traffic lights' footprint plus breathing room: content starts this far right.
const TRAFFIC_LIGHT_INSET: f32 = 76.0;

const IS_MACOS: bool = cfg!(target_os = "macos");

/// The left inset the top-left row keeps clear of the traffic lights: `Some(76)` on macOS while
/// they show (window bar not hidden, not fullscreen), else `None` (the row uses its own Herdr
/// padding).
pub fn traffic_light_inset(window: &Window, hide_window_bar: bool) -> Option<f32> {
    (IS_MACOS && !hide_window_bar && !window.is_fullscreen()).then_some(TRAFFIC_LIGHT_INSET)
}

/// Whether Soprano draws its own window buttons (Linux and Windows, unless `hideWindowBar`).
pub fn shows_window_buttons(hide_window_bar: bool) -> bool {
    !IS_MACOS && !hide_window_bar
}

/// The main window's options for a frame.
pub fn main_window_options(frame: sizing::Frame) -> WindowOptions {
    let bounds = Bounds {
        origin: point(px(frame.x as f32), px(frame.y as f32)),
        size: Size { width: px(frame.width as f32), height: px(frame.height as f32) },
    };
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: Some(TitlebarOptions {
            title: Some("Soprano".into()),
            appears_transparent: true,
            traffic_light_position: Some(point(px(TRAFFIC_LIGHTS.0), px(TRAFFIC_LIGHTS.1))),
        }),
        app_owns_titlebar_drag: true,
        window_min_size: Some(Size {
            width: px(sizing::MINIMUM_WIDTH as f32),
            height: px(sizing::MINIMUM_HEIGHT as f32),
        }),
        window_decorations: Some(WindowDecorations::Client),
        window_background: WindowBackgroundAppearance::Opaque,
        app_id: Some(soprano_platform::AppIdentity::current().id),
        ..WindowOptions::default()
    }
}

/// Shows or hides the native window bar where the OS draws one (the macOS traffic lights).
pub fn apply_window_bar(window: &Window, hide_window_bar: bool) {
    #[cfg(target_os = "macos")]
    macos::set_traffic_lights_hidden(window, hide_window_bar);
    #[cfg(not(target_os = "macos"))]
    let _ = (window, hide_window_bar);
}

/// The window's frame in global logical pixels, for `soprano-main-window-frame-v2`.
pub fn current_frame(window: &Window) -> sizing::Frame {
    let bounds = window.window_bounds().get_bounds();
    frame_of(bounds)
}

pub fn frame_of(bounds: Bounds<Pixels>) -> sizing::Frame {
    sizing::Frame::new(
        f32::from(bounds.origin.x) as f64,
        f32::from(bounds.origin.y) as f64,
        f32::from(bounds.size.width) as f64,
        f32::from(bounds.size.height) as f64,
    )
}

/// Every display's visible frame (the menu bar and dock excluded where the OS reports them).
pub fn visible_frames(cx: &App) -> Vec<sizing::Frame> {
    cx.displays().iter().map(|display| frame_of(display.visible_bounds())).collect()
}

/// The primary display's full height (AppKit's coordinate flip).
pub fn primary_display_height(cx: &App) -> Option<f64> {
    cx.primary_display().map(|display| f64::from(f32::from(display.bounds().size.height)))
}

/// The visible frame of the primary display.
pub fn main_visible_frame(cx: &App) -> sizing::Frame {
    cx.primary_display()
        .map(|display| frame_of(display.visible_bounds()))
        .unwrap_or(sizing::FALLBACK_VISIBLE_FRAME)
}

/// Linux/Windows client-side window buttons: minimize, maximize/restore, close (26×26).
#[derive(IntoElement, Default)]
pub struct WindowButtons;

impl RenderOnce for WindowButtons {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let side = theme.z(26.0);
        let icon_size = 16.0 * theme.zoom();
        let muted = theme.muted;
        let hover = theme.hover;
        let foreground = theme.foreground;
        let maximized = window.is_maximized();
        let button = |id: &'static str, name: IconName| {
            div()
                .id(id)
                .size(side)
                .flex()
                .items_center()
                .justify_center()
                .rounded(theme.z(6.0))
                .text_color(muted)
                .child(Icon::new(name).size(icon_size).color(muted))
                .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
        };
        div()
            .flex()
            .items_center()
            .gap(theme.z(3.0))
            .child(
                button("window-minimize", IconName::WinMin)
                    .hover(move |style| style.bg(hover).text_color(foreground))
                    .on_click(|_, window, _| window.minimize_window()),
            )
            .child(
                button("window-maximize", if maximized { IconName::WinRestore } else { IconName::WinMax })
                    .hover(move |style| style.bg(hover).text_color(foreground))
                    .on_click(|_, window, _| window.zoom_window()),
            )
            .child(
                button("window-close", IconName::WinClose)
                    .hover(|style| style.bg(rgb(0xc42b1c)).text_color(rgb(0xffffff)))
                    // Closing the main window quits: through Quit, so unsaved files are asked about
                    // and the workspace is saved (removing the window would skip both).
                    .on_click(|_, window, cx| window.dispatch_action(Box::new(crate::menus::Quit), cx)),
            )
    }
}

/// A drag region: mouse-down moves the window, a double-click zooms it (the title bar's
/// double-click), as Herdr's brand and tab rows do.
pub fn window_drag_region<E: InteractiveElement>(element: E) -> E {
    element.on_mouse_down(gpui::MouseButton::Left, |event, window, _| {
        if event.click_count >= 2 {
            window.zoom_window();
        } else {
            window.start_window_move();
        }
    })
}

/// The point where the traffic lights start, for tests and layout.
#[cfg(test)]
pub fn traffic_light_origin() -> gpui::Point<Pixels> {
    point(px(TRAFFIC_LIGHTS.0), px(TRAFFIC_LIGHTS.1))
}

#[cfg(target_os = "macos")]
mod macos {
    use gpui::Window;
    use objc2_app_kit::{NSView, NSWindowButton};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    /// `MainWindowAppearance.apply(hideWindowBar:)`: GPUI keeps the full-size content view, so
    /// hiding the bar means hiding the three buttons.
    pub fn set_traffic_lights_hidden(window: &Window, hidden: bool) {
        let Ok(handle) = HasWindowHandle::window_handle(window) else { return };
        let RawWindowHandle::AppKit(handle) = handle.as_raw() else { return };
        // SAFETY: GPUI hands out its live content view; we only message it on the main thread.
        let view: &NSView = unsafe { handle.ns_view.cast().as_ref() };
        let Some(ns_window) = view.window() else { return };
        for kind in
            [NSWindowButton::CloseButton, NSWindowButton::MiniaturizeButton, NSWindowButton::ZoomButton]
        {
            if let Some(button) = ns_window.standardWindowButton(kind) {
                button.setHidden(hidden);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_buttons_show_only_where_the_app_draws_its_own_decorations() {
        assert_eq!(shows_window_buttons(false), !cfg!(target_os = "macos"));
        assert!(!shows_window_buttons(true));
    }

    #[test]
    fn the_main_window_keeps_its_minimum_size() {
        let options = main_window_options(sizing::Frame::new(10.0, 20.0, 1200.0, 800.0));
        let minimum = options.window_min_size.expect("minimum size");
        assert_eq!(minimum.width, px(600.0));
        assert_eq!(minimum.height, px(400.0));
        let titlebar = options.titlebar.expect("titlebar");
        assert!(titlebar.appears_transparent);
        assert_eq!(titlebar.traffic_light_position, Some(traffic_light_origin()));
    }
}
