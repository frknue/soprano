//! An sRGB color with alpha, and CSS-style hex parsing (`NSColor+Hex.swift`).

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// sRGB color, 8 bits per channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const WHITE: Color = Color::rgb(0xff, 0xff, 0xff);
    pub const BLACK: Color = Color::rgb(0, 0, 0);
    pub const CLEAR: Color = Color::rgba(0, 0, 0, 0);

    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 0xff }
    }

    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    /// `0xRRGGBB`, opaque.
    pub const fn hex(rgb: u32) -> Self {
        Self::rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)
    }

    /// Parses `#ff8019`, `ff8019`, the short `#f81`, or `#ff801980` with alpha last.
    pub fn parse_hex(hex: &str) -> Option<Self> {
        let s = hex.trim();
        let s = s.strip_prefix('#').unwrap_or(s);
        let expanded: String;
        let s = if s.chars().count() == 3 {
            expanded = s.chars().flat_map(|c| [c, c]).collect();
            expanded.as_str()
        } else {
            s
        };
        if !(s.len() == 6 || s.len() == 8) || !s.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        let mut value = u64::from_str_radix(s, 16).ok()?;
        if s.len() == 6 {
            value = (value << 8) | 0xff;
        }
        Some(Self::rgba((value >> 24) as u8, (value >> 16) as u8, (value >> 8) as u8, value as u8))
    }

    /// Like [`Color::parse_hex`], but anything unparseable is white (the Swift behavior).
    pub fn from_hex(hex: &str) -> Self {
        Self::parse_hex(hex).unwrap_or(Self::WHITE)
    }

    /// `#rrggbb`, or `#rrggbbaa` when not opaque.
    pub fn to_hex(self) -> String {
        if self.a == 0xff {
            format!("#{:02x}{:02x}{:02x}", self.r, self.g, self.b)
        } else {
            format!("#{:02x}{:02x}{:02x}{:02x}", self.r, self.g, self.b, self.a)
        }
    }

    pub fn with_alpha(self, alpha: f32) -> Self {
        Self { a: (alpha.clamp(0.0, 1.0) * 255.0).round() as u8, ..self }
    }

    pub fn alpha_f32(self) -> f32 {
        self.a as f32 / 255.0
    }

    /// Linear blend toward `other` by `fraction` (0 = self, 1 = other), alpha included.
    pub fn mix(self, other: Color, fraction: f32) -> Self {
        let t = fraction.clamp(0.0, 1.0);
        let lerp = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * t).round() as u8;
        Self {
            r: lerp(self.r, other.r),
            g: lerp(self.g, other.g),
            b: lerp(self.b, other.b),
            a: lerp(self.a, other.a),
        }
    }

    /// Relative luminance (WCAG), 0 (black) to 1 (white).
    pub fn luminance(self) -> f32 {
        fn channel(c: u8) -> f32 {
            let c = c as f32 / 255.0;
            if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        }
        0.2126 * channel(self.r) + 0.7152 * channel(self.g) + 0.0722 * channel(self.b)
    }

    pub fn is_dark(self) -> bool {
        self.luminance() < 0.5
    }

    /// `0xRRGGBBAA`, the layout `gpui::rgba` takes.
    pub const fn to_rgba_u32(self) -> u32 {
        ((self.r as u32) << 24) | ((self.g as u32) << 16) | ((self.b as u32) << 8) | self.a as u32
    }
}

impl Serialize for Color {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_hex())
    }
}

impl<'de> Deserialize<'de> for Color {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        Color::parse_hex(&s).ok_or_else(|| serde::de::Error::custom(format!("not a hex color: {s:?}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn components(hex: &str) -> [u8; 4] {
        let c = Color::from_hex(hex);
        [c.r, c.g, c.b, c.a]
    }

    #[test]
    fn short_and_alpha_hex_colors_are_read_like_css_instead_of_falling_back_to_white() {
        assert_eq!(components("#ff8019"), [255, 128, 25, 255]);
        assert_eq!(components("#f81"), [255, 136, 17, 255]);
        assert_eq!(components("ff801980"), [255, 128, 25, 128]);
        assert_eq!(components("#ff80"), [255, 255, 255, 255]);
        assert_eq!(components("#+f8019"), [255, 255, 255, 255]);
    }

    #[test]
    fn hex_round_trips_and_keeps_alpha_only_when_translucent() {
        assert_eq!(Color::from_hex("#10a37f").to_hex(), "#10a37f");
        assert_eq!(Color::from_hex("#10a37f80").to_hex(), "#10a37f80");
    }
}
