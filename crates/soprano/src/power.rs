//! Whether any display is awake (Swift `CGDisplayIsAsleep` over the online displays): an
//! automation run's terminal waits while every display sleeps. The only per-OS piece of the
//! automations wiring; Linux and Windows report awake (their renderers need no display).

#[cfg(target_os = "macos")]
pub fn display_is_awake() -> bool {
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGGetOnlineDisplayList(max_displays: u32, displays: *mut u32, count: *mut u32) -> i32;
        fn CGDisplayIsAsleep(display: u32) -> u32;
    }
    let mut displays = [0u32; 16];
    let mut count = 0u32;
    // SAFETY: the buffer holds `displays.len()` ids and `count` receives how many were written.
    let status = unsafe { CGGetOnlineDisplayList(displays.len() as u32, displays.as_mut_ptr(), &mut count) };
    if status != 0 || count == 0 {
        return true;
    }
    // SAFETY: each id came from CoreGraphics' online display list.
    displays[..count as usize].iter().any(|display| unsafe { CGDisplayIsAsleep(*display) } == 0)
}

#[cfg(not(target_os = "macos"))]
pub fn display_is_awake() -> bool {
    true
}

/// Notices that the machine slept (Swift's `NSWorkspace.didWakeNotification`, portable): it is
/// sampled every [`WAKE_SAMPLE_INTERVAL`], and a timer cannot fire while the machine sleeps, so
/// wall-clock time between two samples running more than [`WAKE_JUMP`] past the interval means
/// it woke. A busy UI thread can look the same; that only costs an extra, harmless tick.
#[derive(Default)]
pub struct WakeDetector {
    last: Option<std::time::SystemTime>,
}

/// How far past the sample interval the wall clock may move before it counts as a sleep.
pub const WAKE_JUMP: std::time::Duration = std::time::Duration::from_secs(5);
/// How often [`WakeDetector::observe`] is sampled.
pub const WAKE_SAMPLE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);

impl WakeDetector {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records a sample; true when the machine woke since the previous one. A clock set
    /// backwards is not a wake.
    pub fn observe(&mut self, wall: std::time::SystemTime) -> bool {
        let Some(last) = self.last.replace(wall) else { return false };
        wall.duration_since(last).is_ok_and(|elapsed| elapsed > WAKE_SAMPLE_INTERVAL + WAKE_JUMP)
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, SystemTime};

    use super::*;

    #[test]
    fn a_wall_clock_gap_between_samples_counts_as_a_wake() {
        let start = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
        let mut detector = WakeDetector::new();
        assert!(!detector.observe(start));
        // Regular and slightly late samples.
        assert!(!detector.observe(start + Duration::from_secs(1)));
        assert!(!detector.observe(start + Duration::from_secs(6)));
        // Slept for an hour.
        assert!(detector.observe(start + Duration::from_secs(3_606)));
        // The clock set backwards is not a wake.
        assert!(!detector.observe(start));
    }
}
