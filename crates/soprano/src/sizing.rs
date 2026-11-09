//! `App/MainWindowSizing.swift`: the main window's first frame, which saved frames come back,
//! and the persisted frame (`soprano-main-window-frame-v2`).
//!
//! Frames are in GPUI's global coordinates (top-left origin); the rules only compare frames with
//! the displays' visible frames, so the origin convention does not change them.

use soprano_platform::StateStore;

/// A rectangle in logical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    pub const ZERO: Frame = Frame { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };

    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }

    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }

    /// The overlap of two frames; `None` when they do not touch (AppKit's null rect).
    pub fn intersection(&self, other: &Frame) -> Option<Frame> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let max_x = self.max_x().min(other.max_x());
        let max_y = self.max_y().min(other.max_y());
        (max_x > x && max_y > y).then(|| Frame::new(x, y, max_x - x, max_y - y))
    }

    pub fn contains(&self, other: &Frame) -> bool {
        other.x >= self.x && other.y >= self.y && other.max_x() <= self.max_x() && other.max_y() <= self.max_y()
    }

    /// AppKit's `integral`: the smallest whole-pixel frame containing this one.
    pub fn integral(&self) -> Frame {
        let x = self.x.floor();
        let y = self.y.floor();
        Frame::new(x, y, self.max_x().ceil() - x, self.max_y().ceil() - y)
    }

    /// `NSStringFromRect`: `{{x, y}, {w, h}}`.
    pub fn to_rect_string(&self) -> String {
        format!("{{{{{}, {}}}, {{{}, {}}}}}", self.x, self.y, self.width, self.height)
    }

    /// `NSRectFromString`: the four numbers in order; anything unreadable is zero, as there.
    pub fn from_rect_string(text: &str) -> Frame {
        let numbers: Vec<f64> = text
            .split(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-' || c == 'e' || c == '+'))
            .filter(|part| !part.is_empty())
            .filter_map(|part| part.parse().ok())
            .collect();
        let at = |index: usize| numbers.get(index).copied().unwrap_or(0.0);
        Frame::new(at(0), at(1), at(2), at(3))
    }
}

pub const FALLBACK_VISIBLE_FRAME: Frame = Frame::new(0.0, 0.0, 1440.0, 900.0);
pub const MINIMUM_WIDTH: f64 = 600.0;
pub const MINIMUM_HEIGHT: f64 = 400.0;

const VISIBLE_FRAME_FRACTION: f64 = 0.9;
const PREFERRED_ASPECT_RATIO: f64 = 16.0 / 10.0;

/// A large, centered terminal window without stretching across an entire ultrawide display.
pub fn initial_frame(visible: Frame) -> Frame {
    if visible.width <= 0.0 || visible.height <= 0.0 {
        return initial_frame(FALLBACK_VISIBLE_FRAME);
    }
    let maximum_width = visible.width * VISIBLE_FRAME_FRACTION;
    let maximum_height = visible.height * VISIBLE_FRAME_FRACTION;
    let width = maximum_width.min(maximum_height * PREFERRED_ASPECT_RATIO);
    let height = width / PREFERRED_ASPECT_RATIO;
    Frame::new(visible.mid_x() - width / 2.0, visible.mid_y() - height / 2.0, width, height).integral()
}

pub fn is_restorable(frame: &Frame, visible_frames: &[Frame]) -> bool {
    let finite = [frame.x, frame.y, frame.width, frame.height].iter().all(|value| value.is_finite());
    if !finite || frame.width < MINIMUM_WIDTH || frame.height < MINIMUM_HEIGHT {
        return false;
    }
    visible_frames.iter().any(|visible| {
        frame.intersection(visible).is_some_and(|overlap| {
            overlap.width >= frame.width.min(100.0) && overlap.height >= frame.height.min(100.0)
        })
    })
}

/// Fits a restorable frame into the visible frame it overlaps most, so a frame saved on a larger
/// display comes back inside the current one.
pub fn clamped(frame: Frame, visible_frames: &[Frame]) -> Frame {
    let overlap = |visible: &Frame| frame.intersection(visible).map_or(0.0, |o| o.width * o.height);
    let Some(visible) = visible_frames.iter().max_by(|a, b| overlap(a).total_cmp(&overlap(b))) else {
        return frame;
    };
    if overlap(visible) <= 0.0 {
        return frame;
    }
    let width = frame.width.min(visible.width.max(MINIMUM_WIDTH));
    let height = frame.height.min(visible.height.max(MINIMUM_HEIGHT));
    let x = frame.x.max(visible.x).min(visible.max_x() - width);
    let y = frame.y.max(visible.y).min(visible.max_y() - height);
    Frame::new(x, y, width, height)
}

/// Versioned so frames previously captured while Settings was affecting the window do not
/// override the repaired startup behavior.
pub const FRAME_KEY: &str = "soprano-main-window-frame-v2";

pub fn load_frame(store: &StateStore, visible_frames: &[Frame]) -> Option<Frame> {
    let stored: String = store.get(FRAME_KEY)?;
    let frame = Frame::from_rect_string(&stored);
    is_restorable(&frame, visible_frames).then(|| clamped(frame, visible_frames))
}

pub fn save_frame(store: &StateStore, frame: Frame) {
    store.set(FRAME_KEY, &frame.to_rect_string());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_initial_frame_uses_the_display_height_without_spanning_an_ultrawide_screen() {
        let visible = Frame::new(0.0, 0.0, 5120.0, 1400.0);
        let frame = initial_frame(visible);
        assert!((frame.height - 1260.0).abs() <= 1.0);
        assert!((frame.width / frame.height - 1.6).abs() < 0.01);
        assert!(frame.width < visible.width / 2.0);
        assert!((frame.mid_x() - visible.mid_x()).abs() <= 1.0);
        assert!((frame.mid_y() - visible.mid_y()).abs() <= 1.0);
    }

    #[test]
    fn the_initial_frame_fits_and_centers_on_a_conventional_display() {
        let visible = Frame::new(40.0, 25.0, 1440.0, 900.0);
        let frame = initial_frame(visible);
        assert!(visible.contains(&frame));
        assert!((frame.width - visible.width * 0.9).abs() <= 1.0);
        assert!((frame.mid_x() - visible.mid_x()).abs() <= 1.0);
        assert!((frame.mid_y() - visible.mid_y()).abs() <= 1.0);
    }

    #[test]
    fn an_invalid_visible_frame_uses_the_fallback_display() {
        assert_eq!(initial_frame(Frame::ZERO), initial_frame(FALLBACK_VISIBLE_FRAME));
    }

    #[test]
    fn the_frame_store_round_trips_a_visible_user_frame() {
        let store = StateStore::in_memory();
        let visible = Frame::new(0.0, 0.0, 5120.0, 1400.0);
        let user = Frame::new(750.0, 120.0, 3000.0, 1100.0);
        save_frame(&store, user);
        assert_eq!(load_frame(&store, &[visible]), Some(user));
    }

    #[test]
    fn the_frame_store_rejects_undersized_and_offscreen_frames() {
        let store = StateStore::in_memory();
        let visible = Frame::new(0.0, 0.0, 1440.0, 900.0);
        save_frame(&store, Frame::new(100.0, 100.0, 500.0, 300.0));
        assert_eq!(load_frame(&store, &[visible]), None);
        save_frame(&store, Frame::new(5000.0, 5000.0, 1200.0, 800.0));
        assert_eq!(load_frame(&store, &[visible]), None);
    }

    #[test]
    fn the_frame_store_fits_a_frame_saved_on_a_larger_display_into_the_screen_it_overlaps_most() {
        let store = StateStore::in_memory();
        let laptop = Frame::new(0.0, 0.0, 1440.0, 875.0);
        let side = Frame::new(1440.0, 0.0, 1920.0, 1055.0);
        save_frame(&store, Frame::new(200.0, 50.0, 3000.0, 1300.0));
        assert_eq!(load_frame(&store, &[laptop, side]), Some(Frame::new(1440.0, 0.0, 1920.0, 1055.0)));
    }

    #[test]
    fn frames_written_by_the_swift_app_parse_back() {
        assert_eq!(Frame::from_rect_string("{{750, 120}, {3000, 1100}}"), Frame::new(750.0, 120.0, 3000.0, 1100.0));
        assert_eq!(Frame::from_rect_string("{{-12.5, 3}, {800, 600}}"), Frame::new(-12.5, 3.0, 800.0, 600.0));
        assert_eq!(Frame::from_rect_string("garbage"), Frame::ZERO);
    }
}
