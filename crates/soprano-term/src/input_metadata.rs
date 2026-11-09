//! Input bookkeeping between the platform and the terminal (`TerminalInputMetadata.swift`):
//! edit commands as terminal binding actions, which key releases a terminal may see, scroll
//! metadata and modifier-key transitions.

use std::collections::HashMap;
use std::hash::Hash;

/// The standard edit commands a window menu sends to the focused terminal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditCommand {
    Copy,
    Paste,
    SelectAll,
    Cut,
}

/// The terminal binding action (Ghostty's names) an edit command performs.
pub fn binding_action_for(command: EditCommand) -> Option<&'static str> {
    match command {
        EditCommand::Copy => Some("copy_to_clipboard"),
        EditCommand::Paste => Some("paste_from_clipboard"),
        EditCommand::SelectAll => Some("select_all"),
        EditCommand::Cut => None,
    }
}

/// Where a key equivalent (a Command or Control chord) goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyEquivalentRoute {
    /// Not the terminal's: let the app (menus, shortcuts) have it.
    PassThrough,
    /// Deliver the press to the terminal now.
    DeliverPress,
    /// Already dealt with; swallow it.
    Handled,
}

/// The modifiers that make a key press a key equivalent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct KeyEquivalentModifiers {
    pub command: bool,
    pub control: bool,
}

impl KeyEquivalentModifiers {
    pub const COMMAND: Self = Self { command: true, control: false };
    pub const CONTROL: Self = Self { command: false, control: true };
}

/// Whether a key release reaches the terminal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyUpRoute {
    Deliver,
    Suppress,
}

#[derive(Clone, Debug, PartialEq)]
struct EventIdentity<K> {
    timestamp: f64,
    key: K,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PressDisposition {
    HandledOutsideTerminal,
    AwaitingTerminalDelivery,
    DeliveredToTerminal,
}

#[derive(Clone, Debug)]
struct EquivalentPress<K> {
    event: EventIdentity<K>,
    disposition: PressDisposition,
}

/// Tracks key equivalents so the terminal sees exactly one press and one release for every
/// chord it handles, and no release for a chord something else (a menu, an app shortcut)
/// took. `K` identifies a physical key (a key code, or GPUI's key name).
#[derive(Clone, Debug)]
pub struct KeyEquivalentRouter<K: Eq + Hash + Clone = u16> {
    pending_event: Option<EventIdentity<K>>,
    active_presses: HashMap<K, EquivalentPress<K>>,
    completed_events: HashMap<K, EventIdentity<K>>,
}

impl<K: Eq + Hash + Clone> Default for KeyEquivalentRouter<K> {
    fn default() -> Self {
        Self { pending_event: None, active_presses: HashMap::new(), completed_events: HashMap::new() }
    }
}

impl<K: Eq + Hash + Clone> KeyEquivalentRouter<K> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn route_key_equivalent(
        &mut self,
        timestamp: f64,
        key: K,
        modifiers: KeyEquivalentModifiers,
        is_terminal_binding: bool,
        menu_handled: bool,
    ) -> KeyEquivalentRoute {
        if timestamp == 0.0 {
            return KeyEquivalentRoute::PassThrough;
        }
        if !modifiers.command && !modifiers.control {
            self.pending_event = None;
            return KeyEquivalentRoute::PassThrough;
        }

        let event = EventIdentity { timestamp, key: key.clone() };

        if self.completed_events.get(&key) == Some(&event) {
            self.pending_event = None;
            return KeyEquivalentRoute::Handled;
        }

        if let Some(active) = self.active_presses.get(&key)
            && active.event == event
        {
            let is_pending_pass_through = active.disposition == PressDisposition::HandledOutsideTerminal
                && self.pending_event.as_ref() == Some(&event);
            if !is_pending_pass_through {
                self.pending_event = None;
                return KeyEquivalentRoute::Handled;
            }
        }

        if menu_handled {
            self.pending_event = None;
            self.active_presses.insert(
                key,
                EquivalentPress { event, disposition: PressDisposition::HandledOutsideTerminal },
            );
            return KeyEquivalentRoute::Handled;
        }

        if is_terminal_binding || self.pending_event.as_ref() == Some(&event) {
            self.pending_event = None;
            self.active_presses.insert(
                key,
                EquivalentPress { event, disposition: PressDisposition::AwaitingTerminalDelivery },
            );
            return KeyEquivalentRoute::DeliverPress;
        }

        self.pending_event = Some(event.clone());
        self.active_presses
            .insert(key, EquivalentPress { event, disposition: PressDisposition::HandledOutsideTerminal });
        KeyEquivalentRoute::PassThrough
    }

    pub fn should_redispatch_key_equivalent(&self, timestamp: f64, key: &K) -> bool {
        timestamp != 0.0
            && self.pending_event.as_ref().is_some_and(|e| e.timestamp == timestamp && &e.key == key)
    }

    pub fn prepare_for_key_down(&mut self, timestamp: f64, key: K) {
        self.pending_event = None;
        self.completed_events.remove(&key);
        if self.active_presses.contains_key(&key) {
            let event = EventIdentity { timestamp, key: key.clone() };
            self.active_presses.insert(
                key,
                EquivalentPress { event, disposition: PressDisposition::AwaitingTerminalDelivery },
            );
        }
    }

    pub fn record_key_down_delivery(&mut self, key: &K) {
        if let Some(active) = self.active_presses.get_mut(key)
            && active.disposition == PressDisposition::AwaitingTerminalDelivery
        {
            active.disposition = PressDisposition::DeliveredToTerminal;
        }
    }

    pub fn route_key_up(&mut self, key: &K) -> KeyUpRoute {
        if self.pending_event.as_ref().is_some_and(|e| &e.key == key) {
            self.pending_event = None;
        }
        if let Some(active) = self.active_presses.remove(key) {
            let delivered = active.disposition == PressDisposition::DeliveredToTerminal;
            self.completed_events.insert(key.clone(), active.event);
            return if delivered { KeyUpRoute::Deliver } else { KeyUpRoute::Suppress };
        }
        if self.completed_events.contains_key(key) { KeyUpRoute::Suppress } else { KeyUpRoute::Deliver }
    }

    pub fn reset(&mut self) {
        self.pending_event = None;
        self.active_presses.clear();
        self.completed_events.clear();
    }
}

/// The platform's momentum phase of a scroll event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollMomentum {
    None = 0,
    Began = 1,
    Stationary = 2,
    Changed = 3,
    Ended = 4,
    Cancelled = 5,
    MayBegin = 6,
}

/// Modifier flags in Ghostty's layout (`ghostty_input_mods_e`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModifierFlags(pub u32);

impl ModifierFlags {
    pub const SHIFT: u32 = 1 << 0;
    pub const CONTROL: u32 = 1 << 1;
    pub const OPTION: u32 = 1 << 2;
    pub const COMMAND: u32 = 1 << 3;
    pub const CAPS_LOCK: u32 = 1 << 4;
    pub const SHIFT_RIGHT: u32 = 1 << 6;
    pub const CONTROL_RIGHT: u32 = 1 << 7;
    pub const OPTION_RIGHT: u32 = 1 << 8;
    pub const COMMAND_RIGHT: u32 = 1 << 9;

    pub fn contains(self, flag: u32) -> bool {
        self.0 & flag != 0
    }
}

/// Which side of each modifier is down (AppKit's device-dependent flags).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModifierDeviceFlags(pub u32);

impl ModifierDeviceFlags {
    pub const CONTROL_LEFT: u32 = 0x0000_0001;
    pub const SHIFT_LEFT: u32 = 0x0000_0002;
    pub const SHIFT_RIGHT: u32 = 0x0000_0004;
    pub const COMMAND_LEFT: u32 = 0x0000_0008;
    pub const COMMAND_RIGHT: u32 = 0x0000_0010;
    pub const OPTION_LEFT: u32 = 0x0000_0020;
    pub const OPTION_RIGHT: u32 = 0x0000_0040;
    pub const CONTROL_RIGHT: u32 = 0x0000_2000;

    pub fn contains(self, flag: u32) -> bool {
        self.0 & flag != 0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModifierAction {
    Press,
    Release,
}

/// Scroll flags as Ghostty reads them: bit 0 precise, bits 1.. the momentum phase.
pub fn scroll_flags(precise: bool, momentum: ScrollMomentum) -> i32 {
    i32::from(precise) | ((momentum as i32) << 1)
}

/// Precise (trackpad) deltas count double, as in Ghostty's macOS app; wheel deltas as given.
pub fn scroll_deltas(x: f64, y: f64, precise: bool) -> (f64, f64) {
    let multiplier = if precise { 2.0 } else { 1.0 };
    (x * multiplier, y * multiplier)
}

/// Whether a modifier key (by macOS virtual key code) went down or up, from the side it is
/// on: releasing the left Shift while the right one stays down is still a release.
pub fn modifier_transition(
    key_code: u16,
    modifiers: ModifierFlags,
    device: ModifierDeviceFlags,
) -> Option<ModifierAction> {
    let down = match key_code {
        0x39 => modifiers.contains(ModifierFlags::CAPS_LOCK),
        0x38 => device.contains(ModifierDeviceFlags::SHIFT_LEFT),
        0x3C => device.contains(ModifierDeviceFlags::SHIFT_RIGHT),
        0x3B => device.contains(ModifierDeviceFlags::CONTROL_LEFT),
        0x3E => device.contains(ModifierDeviceFlags::CONTROL_RIGHT),
        0x3A => device.contains(ModifierDeviceFlags::OPTION_LEFT),
        0x3D => device.contains(ModifierDeviceFlags::OPTION_RIGHT),
        0x37 => device.contains(ModifierDeviceFlags::COMMAND_LEFT),
        0x36 => device.contains(ModifierDeviceFlags::COMMAND_RIGHT),
        _ => return None,
    };
    Some(if down { ModifierAction::Press } else { ModifierAction::Release })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edit_selectors_map_to_exact_ghostty_binding_actions() {
        assert_eq!(binding_action_for(EditCommand::Copy), Some("copy_to_clipboard"));
        assert_eq!(binding_action_for(EditCommand::Paste), Some("paste_from_clipboard"));
        assert_eq!(binding_action_for(EditCommand::SelectAll), Some("select_all"));
        assert_eq!(binding_action_for(EditCommand::Cut), None);
    }

    #[test]
    fn unhandled_command_and_control_equivalents_redispatch_their_exact_event_once() {
        for (modifiers, key) in
            [(KeyEquivalentModifiers::COMMAND, 47u16), (KeyEquivalentModifiers::CONTROL, 8)]
        {
            let mut router = KeyEquivalentRouter::new();
            let timestamp = 42.5;
            assert_eq!(
                router.route_key_equivalent(timestamp, key, modifiers, false, false),
                KeyEquivalentRoute::PassThrough
            );
            assert!(router.should_redispatch_key_equivalent(timestamp, &key));
            assert!(!router.should_redispatch_key_equivalent(timestamp, &(key + 1)));

            assert_eq!(
                router.route_key_equivalent(timestamp, key, modifiers, false, false),
                KeyEquivalentRoute::DeliverPress
            );
            router.prepare_for_key_down(timestamp, key);
            router.record_key_down_delivery(&key);

            let duplicate_press = router.route_key_equivalent(timestamp, key, modifiers, false, false);
            let release = router.route_key_up(&key);
            let duplicate_release = router.route_key_up(&key);
            assert_eq!(duplicate_press, KeyEquivalentRoute::Handled);
            assert_eq!(release, KeyUpRoute::Deliver);
            assert_eq!(duplicate_release, KeyUpRoute::Suppress);
            assert!(!router.should_redispatch_key_equivalent(timestamp, &key));
        }
    }

    #[test]
    fn same_timestamp_equivalent_key_codes_remain_independent() {
        let mut router = KeyEquivalentRouter::new();
        let timestamp = 66.0;
        let command =
            router.route_key_equivalent(timestamp, 47u16, KeyEquivalentModifiers::COMMAND, true, false);
        router.prepare_for_key_down(timestamp, 47);
        router.record_key_down_delivery(&47);
        let control = router.route_key_equivalent(timestamp, 8, KeyEquivalentModifiers::CONTROL, true, false);
        router.prepare_for_key_down(timestamp, 8);
        router.record_key_down_delivery(&8);
        assert_eq!(command, KeyEquivalentRoute::DeliverPress);
        assert_eq!(control, KeyEquivalentRoute::DeliverPress);
        assert_eq!(router.route_key_up(&47), KeyUpRoute::Deliver);
        assert_eq!(router.route_key_up(&8), KeyUpRoute::Deliver);
    }

    #[test]
    fn menu_handled_control_equivalent_emits_no_terminal_press_or_release() {
        let mut router = KeyEquivalentRouter::new();
        let (timestamp, key) = (73.25, 8u16);
        let press = router.route_key_equivalent(timestamp, key, KeyEquivalentModifiers::CONTROL, true, true);
        let release = router.route_key_up(&key);
        let duplicate = router.route_key_up(&key);
        assert_eq!(press, KeyEquivalentRoute::Handled);
        assert_eq!(release, KeyUpRoute::Suppress);
        assert_eq!(duplicate, KeyUpRoute::Suppress);
        assert!(!router.should_redispatch_key_equivalent(timestamp, &key));
    }

    #[test]
    fn passed_through_control_handled_elsewhere_emits_no_terminal_release() {
        let mut router = KeyEquivalentRouter::new();
        let (timestamp, key) = (79.5, 9u16);
        let press =
            router.route_key_equivalent(timestamp, key, KeyEquivalentModifiers::CONTROL, false, false);
        let release = router.route_key_up(&key);
        let duplicate = router.route_key_up(&key);
        assert_eq!(press, KeyEquivalentRoute::PassThrough);
        assert_eq!(release, KeyUpRoute::Suppress);
        assert_eq!(duplicate, KeyUpRoute::Suppress);
        assert!(!router.should_redispatch_key_equivalent(timestamp, &key));
    }

    #[test]
    fn delivered_control_equivalent_emits_exactly_one_press_and_release() {
        let mut router = KeyEquivalentRouter::new();
        let (timestamp, key) = (84.5, 8u16);
        let press = router.route_key_equivalent(timestamp, key, KeyEquivalentModifiers::CONTROL, true, false);
        assert_eq!(press, KeyEquivalentRoute::DeliverPress);
        router.prepare_for_key_down(timestamp, key);
        router.record_key_down_delivery(&key);
        assert_eq!(router.route_key_up(&key), KeyUpRoute::Deliver);
        assert_eq!(router.route_key_up(&key), KeyUpRoute::Suppress);
    }

    #[test]
    fn delivered_command_equivalent_releases_after_command_modifier_is_lifted() {
        let mut router = KeyEquivalentRouter::new();
        let key = 47u16;
        let press = router.route_key_equivalent(95.75, key, KeyEquivalentModifiers::COMMAND, true, false);
        assert_eq!(press, KeyEquivalentRoute::DeliverPress);
        router.prepare_for_key_down(95.75, key);
        router.record_key_down_delivery(&key);
        // Key-up intentionally has no modifier argument: the Command key may
        // already have been lifted when the character release arrives.
        assert_eq!(router.route_key_up(&key), KeyUpRoute::Deliver);
        assert_eq!(router.route_key_up(&key), KeyUpRoute::Suppress);
        // A subsequent ordinary press of the same key clears duplicate-release
        // history and remains independently deliverable.
        router.prepare_for_key_down(96.0, key);
        router.record_key_down_delivery(&key);
        assert_eq!(router.route_key_up(&key), KeyUpRoute::Deliver);
    }

    #[test]
    fn ordinary_non_equivalent_key_up_remains_deliverable() {
        let mut router = KeyEquivalentRouter::new();
        router.prepare_for_key_down(105.0, 12u16);
        router.record_key_down_delivery(&12);
        assert_eq!(router.route_key_up(&12), KeyUpRoute::Deliver);
    }

    #[test]
    fn zero_timestamp_equivalent_is_never_tracked_for_redispatch() {
        let mut router = KeyEquivalentRouter::new();
        let route = router.route_key_equivalent(0.0, 47u16, KeyEquivalentModifiers::COMMAND, false, false);
        assert_eq!(route, KeyEquivalentRoute::PassThrough);
        assert!(!router.should_redispatch_key_equivalent(0.0, &47));
    }

    #[test]
    fn scroll_metadata_keeps_precision_and_momentum_in_their_dedicated_bits() {
        assert_eq!(scroll_flags(false, ScrollMomentum::None), 0b0000);
        assert_eq!(scroll_flags(true, ScrollMomentum::Changed), 0b0111);
        assert_eq!(scroll_flags(false, ScrollMomentum::MayBegin), 0b1100);
    }

    #[test]
    fn precise_scroll_deltas_are_doubled_while_discrete_deltas_are_unchanged() {
        assert_eq!(scroll_deltas(1.25, -2.5, false), (1.25, -2.5));
        assert_eq!(scroll_deltas(1.25, -2.5, true), (2.5, -5.0));
    }

    fn flags(bits: &[u32]) -> ModifierFlags {
        ModifierFlags(bits.iter().fold(0, |a, b| a | b))
    }

    #[test]
    fn left_modifier_transitions_report_press_and_release() {
        let shift = flags(&[ModifierFlags::SHIFT]);
        assert_eq!(
            modifier_transition(0x38, shift, ModifierDeviceFlags(ModifierDeviceFlags::SHIFT_LEFT)),
            Some(ModifierAction::Press)
        );
        assert_eq!(
            modifier_transition(0x38, ModifierFlags(0), ModifierDeviceFlags(0)),
            Some(ModifierAction::Release)
        );
    }

    #[test]
    fn right_modifier_transitions_use_the_right_side_state() {
        let both = flags(&[ModifierFlags::OPTION, ModifierFlags::OPTION_RIGHT]);
        assert_eq!(
            modifier_transition(0x3D, both, ModifierDeviceFlags(ModifierDeviceFlags::OPTION_RIGHT)),
            Some(ModifierAction::Press)
        );
        assert_eq!(
            modifier_transition(
                0x3D,
                flags(&[ModifierFlags::OPTION]),
                ModifierDeviceFlags(ModifierDeviceFlags::OPTION_LEFT)
            ),
            Some(ModifierAction::Release)
        );
    }

    #[test]
    fn every_supported_right_modifier_reports_press_and_release() {
        use ModifierDeviceFlags as D;
        use ModifierFlags as F;
        let cases = [
            (0x3C, [F::SHIFT, F::SHIFT_RIGHT], F::SHIFT, D::SHIFT_RIGHT, D::SHIFT_LEFT),
            (0x3E, [F::CONTROL, F::CONTROL_RIGHT], F::CONTROL, D::CONTROL_RIGHT, D::CONTROL_LEFT),
            (0x3D, [F::OPTION, F::OPTION_RIGHT], F::OPTION, D::OPTION_RIGHT, D::OPTION_LEFT),
            (0x36, [F::COMMAND, F::COMMAND_RIGHT], F::COMMAND, D::COMMAND_RIGHT, D::COMMAND_LEFT),
        ];
        for (code, pressed, released, right, left) in cases {
            assert_eq!(modifier_transition(code, flags(&pressed), D(right)), Some(ModifierAction::Press));
            assert_eq!(modifier_transition(code, F(released), D(left)), Some(ModifierAction::Release));
        }
    }

    #[test]
    fn releasing_left_modifier_while_right_remains_held_reports_release() {
        use ModifierDeviceFlags as D;
        use ModifierFlags as F;
        let cases = [
            (0x38, [F::SHIFT, F::SHIFT_RIGHT], D::SHIFT_LEFT, D::SHIFT_RIGHT),
            (0x3B, [F::CONTROL, F::CONTROL_RIGHT], D::CONTROL_LEFT, D::CONTROL_RIGHT),
            (0x3A, [F::OPTION, F::OPTION_RIGHT], D::OPTION_LEFT, D::OPTION_RIGHT),
            (0x37, [F::COMMAND, F::COMMAND_RIGHT], D::COMMAND_LEFT, D::COMMAND_RIGHT),
        ];
        for (code, mods, left, right) in cases {
            assert_eq!(modifier_transition(code, flags(&mods), D(left)), Some(ModifierAction::Press));
            assert_eq!(modifier_transition(code, flags(&mods), D(right)), Some(ModifierAction::Release));
        }
    }

    #[test]
    fn caps_lock_transition_uses_its_aggregate_toggle_state() {
        assert_eq!(
            modifier_transition(0x39, flags(&[ModifierFlags::CAPS_LOCK]), ModifierDeviceFlags(0)),
            Some(ModifierAction::Press)
        );
        assert_eq!(
            modifier_transition(0x39, ModifierFlags(0), ModifierDeviceFlags(0)),
            Some(ModifierAction::Release)
        );
    }
}
