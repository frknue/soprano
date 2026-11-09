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
