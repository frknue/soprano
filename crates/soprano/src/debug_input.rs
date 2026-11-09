//! Dev builds (`visual-snapshot`): input from `soprano debug-keys|debug-modifiers|debug-type|
//! debug-click|debug-move|debug-scroll`, dispatched through the main window with GPUI's own
//! `Window::dispatch_event` / `dispatch_keystroke`, so it takes the same path as real input
//! (the keystroke interceptor, key bindings, hover, clicks). The reply goes out once the window
//! has drawn the result, so a following `debug-snapshot` shows it.

use std::time::Duration;

use gpui::{
    App, AsyncWindowContext, Keystroke, Modifiers, ModifiersChangedEvent, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, PlatformInput, ScrollDelta, ScrollEvent, Window, point, px,
};
use soprano_ipc::Response;
use soprano_ipc::debug::DebugInput;

/// How long to wait for a frame before answering anyway (a fully hidden window may not draw).
const FRAME_TIMEOUT: Duration = Duration::from_secs(2);

/// Dispatches `input` through `window` and calls `respond` after the result is drawn.
pub fn perform(
    input: DebugInput,
    window: &mut Window,
    cx: &mut App,
    respond: impl FnOnce(Response) + 'static,
) {
    window
        .spawn(cx, async move |cx| {
            let result = run(input, cx).await;
            respond(match result {
                Ok(()) => Response::success("ok"),
                Err(error) => Response::failure(error),
            })
        })
        .detach();
}

async fn run(input: DebugInput, cx: &mut AsyncWindowContext) -> Result<(), String> {
    match input {
        DebugInput::Keys { keystrokes } => {
            for source in keystrokes {
                cx.update(|window, cx| press(&source, window, cx)).map_err(|e| e.to_string())??;
                settle(cx).await;
            }
            Ok(())
        }
        DebugInput::Modifiers { modifiers } => {
            let modifiers = parse_modifiers(&modifiers)?;
            cx.update(|window, cx| set_modifiers(modifiers, window, cx)).map_err(|e| e.to_string())?;
            settle(cx).await;
            Ok(())
        }
        DebugInput::Type { text } => {
            cx.update(|window, cx| {
                for character in text.chars() {
                    let keystroke = typed_keystroke(character);
                    window.dispatch_keystroke(keystroke.clone(), cx);
                    window.dispatch_event(PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke }), cx);
                }
            })
            .map_err(|e| e.to_string())?;
            settle(cx).await;
            Ok(())
        }
        DebugInput::Click { x, y, right, double } => {
            cx.update(|window, cx| {
                let position = point(px(x as f32), px(y as f32));
                let modifiers = window.modifiers();
                let button = if right { MouseButton::Right } else { MouseButton::Left };
                window.dispatch_event(
                    PlatformInput::MouseMove(MouseMoveEvent { position, pressed_button: None, modifiers }),
                    cx,
                );
                for click_count in 1..=(if double { 2 } else { 1 }) {
                    window.dispatch_event(
                        PlatformInput::MouseDown(MouseDownEvent {
                            button,
                            position,
                            modifiers,
                            click_count,
                            first_mouse: false,
                        }),
                        cx,
                    );
                    window.dispatch_event(
                        PlatformInput::MouseUp(MouseUpEvent { button, position, modifiers, click_count }),
                        cx,
                    );
                }
            })
            .map_err(|e| e.to_string())?;
            settle(cx).await;
            Ok(())
        }
        DebugInput::Move { x, y } => {
            cx.update(|window, cx| move_to(x, y, window, cx)).map_err(|e| e.to_string())?;
            settle(cx).await;
            Ok(())
        }
        DebugInput::Scroll { x, y, dy } => {
            cx.update(|window, cx| {
                let position = move_to(x, y, window, cx);
                // Positive `dy` scrolls toward the end, as a wheel turned down does.
                let delta = ScrollDelta::Pixels(point(px(0.0), px(-dy as f32)));
                let modifiers = window.modifiers();
                window.dispatch_event(
                    PlatformInput::Scroll(ScrollEvent {
                        position,
                        delta,
                        modifiers,
                        ..ScrollEvent::default()
                    }),
                    cx,
                );
            })
            .map_err(|e| e.to_string())?;
            settle(cx).await;
            Ok(())
        }
    }
}

/// A keystroke as a real key press: its modifiers go down first and come back up after.
fn press(source: &str, window: &mut Window, cx: &mut App) -> Result<(), String> {
    let keystroke = Keystroke::parse_with_os(source, cx.platform_info().os)
        .map_err(|error| format!("Not a keystroke: {source} ({error})"))?;
    let held = window.modifiers();
    if keystroke.modifiers != held {
        set_modifiers(keystroke.modifiers, window, cx);
    }
    window.dispatch_keystroke(keystroke.clone(), cx);
    window.dispatch_event(PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke: keystroke.clone() }), cx);
    if keystroke.modifiers != held {
        set_modifiers(held, window, cx);
    }
    Ok(())
}

fn set_modifiers(modifiers: Modifiers, window: &mut Window, cx: &mut App) {
    window.dispatch_event(
        PlatformInput::ModifiersChanged(ModifiersChangedEvent {
            modifiers,
            ..ModifiersChangedEvent::default()
        }),
        cx,
    );
}

fn move_to(x: i32, y: i32, window: &mut Window, cx: &mut App) -> gpui::Point<gpui::Pixels> {
    let position = point(px(x as f32), px(y as f32));
    let modifiers = window.modifiers();
    window.dispatch_event(
        PlatformInput::MouseMove(MouseMoveEvent { position, pressed_button: None, modifiers }),
        cx,
    );
    position
}

/// `ctrl`, `cmd-shift`, `alt+shift`, … or `none`.
pub fn parse_modifiers(source: &str) -> Result<Modifiers, String> {
    let mut modifiers = Modifiers::default();
    if source.eq_ignore_ascii_case("none") {
        return Ok(modifiers);
    }
    for part in source.split(['-', '+']).filter(|part| !part.is_empty()) {
        match part.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => modifiers.control = true,
            "alt" | "option" | "opt" => modifiers.alt = true,
            "shift" => modifiers.shift = true,
            "cmd" | "command" | "super" | "win" | "platform" => modifiers.platform = true,
            "fn" | "function" => modifiers.function = true,
            other => return Err(format!("Unknown modifier: {other}")),
        }
    }
    Ok(modifiers)
}

/// The key press that types `character` without an input method.
pub fn typed_keystroke(character: char) -> Keystroke {
    let key = match character {
        ' ' => "space".to_owned(),
        '\n' => "enter".to_owned(),
        '\t' => "tab".to_owned(),
        other => other.to_lowercase().to_string(),
    };
    let modifiers = Modifiers { shift: character.is_uppercase(), ..Modifiers::default() };
    Keystroke { modifiers, key, key_char: Some(character.to_string()) }
}

/// Waits until the window has drawn what the input changed: the callback registered now runs at
/// the start of the next frame (before that frame draws), so the second one runs after it.
async fn settle(cx: &mut AsyncWindowContext) {
    for _ in 0..2 {
        let (sender, receiver) = async_channel::bounded::<()>(2);
        let timeout = sender.clone();
        let registered = cx.update(move |window, _| {
            window.on_next_frame(move |_, _| {
                let _ = sender.try_send(());
            });
            window.refresh();
        });
        if registered.is_err() {
            return;
        }
        let timer = cx.background_executor().timer(FRAME_TIMEOUT);
        cx.background_executor()
            .spawn(async move {
                timer.await;
                let _ = timeout.try_send(());
            })
            .detach();
        let _ = receiver.recv().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifiers_and_typed_keys_parse_like_key_presses() {
        let held = parse_modifiers("ctrl-shift").expect("modifiers");
        assert!(held.control && held.shift && !held.platform);
        assert_eq!(parse_modifiers("none"), Ok(Modifiers::default()));
        assert!(parse_modifiers("hyper").is_err());
        let capital = typed_keystroke('A');
        assert_eq!((capital.key.as_str(), capital.modifiers.shift), ("a", true));
        assert_eq!(typed_keystroke(' ').key, "space");
        assert_eq!(typed_keystroke('\n').key_char.as_deref(), Some("\n"));
    }
}
