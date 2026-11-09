//! Motion: opacity-only fades of at most 150 ms, and none at all under Reduce Motion
//! ([`crate::SopranoTheme::set_reduce_motion`]). Hover fills switch instantly (Herdr defines no
//! transitions).

use std::time::Duration;

use gpui::{Animation, AnimationExt as _, AnyElement, App, ElementId, IntoElement, Styled};

use crate::theme::ActiveSopranoTheme;

/// The one fade duration (`Motion.fade`).
pub const FADE: Duration = Duration::from_millis(150);

/// Herdr's spinner: one revolution per 900 ms, redrawn every 100 ms.
pub const SPINNER_REVOLUTION: Duration = Duration::from_millis(900);
pub const SPINNER_STEP: Duration = Duration::from_millis(100);

/// Fades `element` in over [`FADE`] when it first appears; drawn at once under Reduce Motion.
/// `id` must stay stable while the element shows and change for a new appearance.
pub fn fade_in<E>(element: E, id: impl Into<ElementId>, cx: &App) -> AnyElement
where
    E: IntoElement + Styled + 'static,
{
    if cx.soprano_theme().reduce_motion() {
        return element.into_any_element();
    }
    element
        .with_animation(id, Animation::new(FADE).with_easing(ease_out), |element, delta| {
            element.opacity(delta)
        })
        .into_any_element()
}

/// Cubic ease-out.
pub fn ease_out(t: f32) -> f32 {
    1.0 - (1.0 - t).powi(3)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fades_never_run_longer_than_150_ms() {
        assert!(FADE <= Duration::from_millis(150));
        assert_eq!(ease_out(0.0), 0.0);
        assert_eq!(ease_out(1.0), 1.0);
    }
}
