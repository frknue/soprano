//! Small pieces of terminal state with rules of their own: the dashboard's view of a
//! terminal, the left mouse button, whether the shell runs a command, keyboard focus, and
//! re-entrant teardown (`TerminalInteractionState.swift`, `TerminalSurfaceView.swift`).

/// The dashboard-facing state of one exact terminal surface.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TerminalInteractionState {
    pub is_available: bool,
    pub visible_text: String,
}

impl TerminalInteractionState {
    pub fn unavailable() -> Self {
        Self { is_available: false, visible_text: String::new() }
    }
}

/// The left button as the terminal last heard of it, so a press whose release went
/// elsewhere (another view, a lost window) is released exactly once.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MouseButtonState {
    is_left_button_pressed: bool,
}

impl MouseButtonState {
    pub fn is_left_button_pressed(&self) -> bool {
        self.is_left_button_pressed
    }

    pub fn press_left_button(&mut self) {
        self.is_left_button_pressed = true;
    }

    /// Whether there was a press to release.
    pub fn release_left_button(&mut self) -> bool {
        std::mem::replace(&mut self.is_left_button_pressed, false)
    }

    /// Movement with no physical left button down ends a stale press; returns whether it did.
    pub fn reconcile(&mut self, pressed_mouse_buttons: u32) -> bool {
        if !self.is_left_button_pressed || pressed_mouse_buttons & 1 != 0 {
            return false;
        }
        self.is_left_button_pressed = false;
        true
    }
}

/// Tells whether a terminal's shell is running a command.
///
/// Shell integration's prompt marks say "at a prompt". A shell without integration never
/// reports a prompt, nor does an agent started as the pane's own command, so a terminal
/// counts as running only once it has been seen at a prompt.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CommandActivity {
    has_shown_prompt: bool,
}

impl CommandActivity {
    pub fn is_running_command(&mut self, at_prompt: bool) -> bool {
        if at_prompt {
            self.has_shown_prompt = true;
        }
        !at_prompt && self.has_shown_prompt
    }
}

/// Keyboard focus as the terminal reports it: focused only while its window is the active
/// one *and* it holds the window's keyboard focus. Only changes are reported, so repeated
/// window activations don't re-send focus events.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SurfaceFocusTracker {
    last: Option<bool>,
}

impl SurfaceFocusTracker {
    /// The new focus when it changed. A gain is when a "terminal focused" notice goes out.
    pub fn sync(&mut self, window_is_active: bool, holds_keyboard_focus: bool) -> Option<bool> {
        let focused = window_is_active && holds_keyboard_focus;
        if self.last == Some(focused) {
            return None;
        }
        self.last = Some(focused);
        Some(focused)
    }

    /// Forgets the last state: a replacement terminal must hear the current one even when
    /// it equals what the old one was told.
    pub fn reset(&mut self) {
        self.last = None;
    }

    pub fn last(&self) -> Option<bool> {
        self.last
    }
}

/// Runs teardown once even when the teardown itself asks for teardown again.
#[derive(Debug, Default)]
pub struct SurfaceDestructionGate {
    is_performing: bool,
}

impl SurfaceDestructionGate {
    pub fn perform(&mut self, operation: impl FnOnce(&mut Self)) {
        if self.is_performing {
            return;
        }
        self.is_performing = true;
        operation(self);
        self.is_performing = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn movement_with_no_physical_button_releases_a_stale_terminal_press() {
        let mut state = MouseButtonState::default();
        state.press_left_button();
        assert!(state.reconcile(0));
        assert!(!state.is_left_button_pressed());
    }

    #[test]
    fn movement_during_a_real_drag_keeps_the_terminal_press_active() {
        let mut state = MouseButtonState::default();
        state.press_left_button();
        assert!(!state.reconcile(1));
        assert!(state.is_left_button_pressed());
    }

    #[test]
    fn releasing_or_losing_focus_only_reports_an_existing_press_once() {
        let mut state = MouseButtonState::default();
        assert!(!state.release_left_button());
        state.press_left_button();
        assert!(state.release_left_button());
        assert!(!state.release_left_button());
    }

    #[test]
    fn a_terminal_counts_as_running_only_once_its_shell_has_shown_a_prompt() {
        let mut activity = CommandActivity::default();
        let results = [
            activity.is_running_command(false),
            activity.is_running_command(true),
            activity.is_running_command(false),
            activity.is_running_command(true),
        ];
        assert_eq!(results, [false, false, true, false]);
    }

    #[test]
    fn losing_and_regaining_window_key_status_updates_the_still_focused_surface() {
        let mut tracker = SurfaceFocusTracker::default();
        assert_eq!(tracker.sync(true, true), Some(true));
        let mut events = Vec::new();
        events.extend(tracker.sync(false, true));
        assert_eq!(events, [false]);
        events.extend(tracker.sync(true, true));
        assert_eq!(events, [false, true]);
    }

    #[test]
    fn becoming_first_responder_in_a_non_key_window_does_not_focus_the_surface() {
        let mut tracker = SurfaceFocusTracker::default();
        let mut events = Vec::new();
        events.extend(tracker.sync(false, false));
        events.clear();
        events.extend(tracker.sync(false, true));
        assert!(!events.contains(&true));
        events.extend(tracker.sync(true, true));
        assert_eq!(events.last(), Some(&true));
    }

    #[test]
    fn responder_transfers_focus_only_the_new_responder_and_ignore_repeated_window_events() {
        let (mut first, mut second) = (SurfaceFocusTracker::default(), SurfaceFocusTracker::default());
        first.sync(true, true);
        second.sync(true, false);
        let (mut a, mut b) = (Vec::new(), Vec::new());
        a.extend(first.sync(true, false));
        b.extend(second.sync(true, true));
        assert_eq!((a.as_slice(), b.as_slice()), (&[false][..], &[true][..]));
        for _ in 0..2 {
            a.extend(first.sync(true, false));
            b.extend(second.sync(true, true));
        }
        assert_eq!((a.as_slice(), b.as_slice()), (&[false][..], &[true][..]));
        for _ in 0..2 {
            a.extend(first.sync(false, false));
            b.extend(second.sync(false, true));
        }
        assert_eq!((a.as_slice(), b.as_slice()), (&[false][..], &[true, false][..]));
    }

    #[test]
    fn detaching_and_reattaching_resynchronizes_focus_and_destruction_clears_the_cache() {
        let mut tracker = SurfaceFocusTracker::default();
        tracker.sync(true, true);
        let mut events = Vec::new();
        // Detached from its window: no longer focused.
        events.extend(tracker.sync(false, false));
        assert_eq!(events, [false]);
        events.extend(tracker.sync(true, true));
        assert_eq!(events.last(), Some(&true));
        events.clear();
        tracker.reset();
        // The replacement surface hears the current state even though it is unchanged.
        events.extend(tracker.sync(true, true));
        assert_eq!(events, [true]);
    }

    #[test]
    fn focus_notifications_are_emitted_only_when_the_surface_actually_gains_focus() {
        let mut tracker = SurfaceFocusTracker::default();
        let mut gained = 0;
        for (window, holds) in [(false, true), (true, true), (true, true), (false, true), (true, true)] {
            if tracker.sync(window, holds) == Some(true) {
                gained += 1;
            }
        }
        assert_eq!(gained, 2);
    }

    #[test]
    fn reentrant_destruction_is_skipped_but_later_sequential_call_runs() {
        let mut gate = SurfaceDestructionGate::default();
        let mut operations = Vec::new();
        gate.perform(|gate| {
            operations.push("outer");
            gate.perform(|_| operations.push("inner"));
        });
        gate.perform(|_| operations.push("later"));
        assert_eq!(operations, ["outer", "later"]);
    }

    #[test]
    fn an_unavailable_terminal_has_no_text() {
        assert_eq!(TerminalInteractionState::unavailable(), TerminalInteractionState::default());
    }
}
