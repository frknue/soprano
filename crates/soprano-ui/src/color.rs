//! Color math the themes need beyond `soprano_types::Color` (`NSColor+Theme` in `Theme.swift`):
//! WCAG contrast, hue distance, CIELAB distance, and the conversion to GPUI's `Hsla`.

use gpui::{Hsla, Rgba};
use soprano_types::Color;

/// `color` as GPUI's color type, alpha included.
pub fn hsla(color: Color) -> Hsla {
    Rgba {
        r: color.r as f32 / 255.0,
        g: color.g as f32 / 255.0,
        b: color.b as f32 / 255.0,
        a: color.a as f32 / 255.0,
    }
    .into()
}

/// `color` with its alpha set to `alpha` (0…1): Swift's `withAlphaComponent`.
pub fn with_alpha(color: Color, alpha: f32) -> Color {
    color.with_alpha(alpha)
}

fn linear(channel: u8) -> f64 {
    let c = channel as f64 / 255.0;
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

/// WCAG relative luminance (0 black … 1 white), with the sRGB 0.04045 knee Swift uses.
pub fn relative_luminance(color: Color) -> f64 {
    0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
}

/// WCAG contrast ratio between two opaque colors (1…21).
pub fn contrast_ratio(a: Color, b: Color) -> f64 {
    let (l1, l2) = (relative_luminance(a), relative_luminance(b));
    (l1.max(l2) + 0.05) / (l1.min(l2) + 0.05)
}

/// The HSB hue in degrees (0…360); 0 for grays, like `NSColor.hueComponent`.
pub fn hue_degrees(color: Color) -> f64 {
    let (r, g, b) = (color.r as f64 / 255.0, color.g as f64 / 255.0, color.b as f64 / 255.0);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;
    if delta == 0.0 {
        return 0.0;
    }
    let hue = if max == r {
        ((g - b) / delta).rem_euclid(6.0)
    } else if max == g {
        (b - r) / delta + 2.0
    } else {
        (r - g) / delta + 4.0
    };
    hue * 60.0
}

/// Shortest distance between two hues, in degrees (0…180).
pub fn hue_distance(a: Color, b: Color) -> f64 {
    let delta = (hue_degrees(a) - hue_degrees(b)).abs();
    delta.min(360.0 - delta)
}

/// CIELAB (D65) coordinates.
fn lab(color: Color) -> (f64, f64, f64) {
    let (r, g, b) = (linear(color.r), linear(color.g), linear(color.b));
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    let f = |t: f64| if t > 0.008856 { t.cbrt() } else { 7.787 * t + 16.0 / 116.0 };
    (116.0 * f(y) - 16.0, 500.0 * (f(x) - f(y)), 200.0 * (f(y) - f(z)))
}

/// CIELAB ΔE (1976): about 2.3 is just noticeable, above 10 reads as a different color.
pub fn lab_distance(a: Color, b: Color) -> f64 {
    let (a, b) = (lab(a), lab(b));
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2) + (a.2 - b.2).powi(2)).sqrt()
}

/// Herdr's light/dark test (`settings.rs` `is_light`): the Rec. 709 weights over the
/// gamma-encoded channels, above one half.
pub fn is_light_background(color: Color) -> bool {
    let ch = |c: u8| c as f32 / 255.0;
    0.2126 * ch(color.r) + 0.7152 * ch(color.g) + 0.0722 * ch(color.b) > 0.5
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hue_distance_wraps_around_red() {
        let red = Color::hex(0xff0000);
        let magenta_red = Color::hex(0xff0020);
        assert!(hue_distance(red, magenta_red) < 10.0);
        assert!((hue_distance(Color::hex(0xff0000), Color::hex(0x00ffff)) - 180.0).abs() < 0.01);
    }

    #[test]
    fn contrast_of_black_on_white_is_twenty_one() {
        assert!((contrast_ratio(Color::BLACK, Color::WHITE) - 21.0).abs() < 0.01);
    }

    #[test]
    fn lab_distance_is_zero_for_equal_colors_and_large_for_opposites() {
        assert!(lab_distance(Color::hex(0x336699), Color::hex(0x336699)) < 1e-9);
        assert!(lab_distance(Color::BLACK, Color::WHITE) > 99.0);
    }
}
