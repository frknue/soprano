//! The keybinding state machine (Swift `KeybindingManager`), without a UI: the host feeds it
//! key events and modifier changes and executes what comes back.

use std::time::{Duration, Instant};

use soprano_types::{KeyBinding, KeyBindingConfig, KeyBindingMode, KeybindingState};

use crate::claims::PassthroughClaims;
use crate::command::{FocusedContent, dispatches_through_main_menu};
use crate::event::{ESCAPE, KeyEvent, Modifiers, Platform};
use crate::hints::{PaneHintAssignment, PaneHintStep, pane_hint_step};
use soprano_types::TerminalTarget;

/// Ctrl+H/J/K/L: the bindings a terminal program may claim through navigation passthrough.
pub const PANE_NAVIGATION_BINDING_IDS: [&str; 4] = ["nav-left", "nav-down", "nav-up", "nav-right"];

/// What the host does with one key event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyOutcome {
    /// Deliver the event on, to the focused terminal or view.
    PassThrough,
    /// Swallowed with nothing to run: a key after the prefix that matches no binding, or Esc
    /// dropping a started pane hint.
    Consumed,
    /// Swallowed; the prefix key started prefix mode (the next key picks a prefix binding).
    EnterPrefix,
    /// The prefix key pressed again while in prefix mode: prefix mode ended and this event (a
    /// literal Ctrl+`<prefix>`, e.g. ⌃A for the shell) goes on to the focused terminal.
    LiteralPrefix,
    /// Swallowed; run the binding with this id ([`crate::BindingCommand::from_binding_id`]).
    Action(String),
    /// The binding with this id matched, but the app menu owns it
    /// ([`crate::dispatches_through_main_menu`]): on macOS deliver the event on so the native
    /// menu's key equivalent runs it; a host without that menu equivalent runs the action.
    MenuAction(String),
    /// Swallowed; focus this pane (its hint was typed).
    FocusPaneHint(String),
    /// Swallowed; these letters of a longer pane hint are typed so far.
    PaneHintPending(String),
}

/// A change the UI shows, in the order it happened (the Swift manager's three change handlers).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ResolverChange {
    /// The status-bar mode. Sent on every prefix start and clear (also normal → normal, as the
    /// Swift `notifyStateChange` did) and for every [`KeybindingResolver::copy_mode_changed`].
    State(KeybindingState),
    /// Whether the hint-reveal modifier is held (window numbers and pane hints in the sidebar).
    /// Sent only on change.
    ControlKeyHeld(bool),
    /// The letters of a longer pane hint typed so far (`""` when none). Sent only on change.
    TypedPaneHint(String),
}

/// Everything about the app the resolver needs for one key event.
pub struct KeyContext<'a> {
    /// What has the keyboard.
    pub focused_content: FocusedContent,
    /// The command palette, a dialog (or the window it covers), or a recording shortcut field
    /// has the keyboard: it takes every key itself, so a chord there must not act on the panes
    /// behind it (⌘D picks Don't Save instead of opening a terminal).
    pub keys_captured: bool,
    /// The active pane's active tab, if any.
    pub active_target: Option<TerminalTarget>,
    /// Navigation passthrough claims.
    pub claims: &'a dyn PassthroughClaims,
    /// Every pane hint of the session's windows.
    pub pane_hints: &'a [PaneHintAssignment],
    /// The time of the event, for the prefix and pane-hint timeouts.
    pub now: Instant,
}

impl KeyContext<'static> {
    /// A context with nothing focused, no target, no claims and no hints.
    pub fn new(now: Instant) -> Self {
        KeyContext {
            focused_content: FocusedContent::Other,
            keys_captured: false,
            active_target: None,
            claims: &(),
            pane_hints: &[],
            now,
        }
    }
}

impl KeyContext<'_> {
    fn terminal_claims_control_keys(&self) -> bool {
        self.active_target.as_ref().is_some_and(|target| self.claims.has_claims(target))
    }
}

/// Resolves key events against a [`KeyBindingConfig`].
///
/// Timers are the host's: after every call, re-arm a timer for [`KeybindingResolver::next_deadline`]
/// and call [`KeybindingResolver::tick`] when it fires. Changes for the UI collect until
/// [`KeybindingResolver::drain_changes`].
#[derive(Debug)]
pub struct KeybindingResolver {
    config: KeyBindingConfig,
    platform: Platform,
    state: KeybindingState,
    display_state: KeybindingState,
    prefix_deadline: Option<Instant>,
    is_control_key_held: bool,
    /// Letters of a longer pane hint typed so far. After its first hint-chord letter the rest
    /// may be typed with or without the chord, within the prefix timeout.
    typed_pane_hint: String,
    pane_hint_deadline: Option<Instant>,
    changes: Vec<ResolverChange>,
}

impl KeybindingResolver {
    /// The config is injected rather than loaded here: `settings.json` is the source of truth for
    /// keybindings.
    pub fn new(config: KeyBindingConfig, platform: Platform) -> Self {
        KeybindingResolver {
            config,
            platform,
            state: KeybindingState::Normal,
            display_state: KeybindingState::Normal,
            prefix_deadline: None,
            is_control_key_held: false,
            typed_pane_hint: String::new(),
            pane_hint_deadline: None,
            changes: Vec::new(),
        }
    }

    pub fn config(&self) -> &KeyBindingConfig {
        &self.config
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }

    /// `Normal` or `Prefix`: the resolver's own mode.
    pub fn state(&self) -> KeybindingState {
        self.state
    }

    /// What the status bar shows: the last mode reported by the resolver or by
    /// [`KeybindingResolver::copy_mode_changed`], whichever came last (both fed the same status
    /// bar in the Swift app).
    pub fn display_state(&self) -> KeybindingState {
        self.display_state
    }

    pub fn is_control_key_held(&self) -> bool {
        self.is_control_key_held
    }

    pub fn typed_pane_hint(&self) -> &str {
        &self.typed_pane_hint
    }

    /// Adopts a new keybinding configuration in place.
    ///
    /// Deliberately not "throw the resolver away and build a new one": the host keeps its
    /// passthrough claims and timers wired to this instance, and reloading happens on every
    /// settings.json save.
    pub fn apply_config(&mut self, config: KeyBindingConfig) {
        self.config = config;
        // A half-typed prefix chord refers to the old table; drop it so the next key is
        // interpreted against the config the user just wrote.
        if self.state == KeybindingState::Prefix {
            self.clear_prefix_mode();
        }
    }

    /// The terminal's copy mode changed (`Copy`, `CopySelection`, or `Normal` when it ends). Only
    /// the status-bar mode follows; prefix handling is unaffected.
    pub fn copy_mode_changed(&mut self, state: KeybindingState) {
        self.notify_state(state);
    }

    /// The held modifiers changed (a flags-changed event).
    pub fn modifiers_changed(&mut self, modifiers: Modifiers) {
        self.set_control_key_held(self.platform.reveals_hints(modifiers));
    }

    /// The app stopped being active: nothing is held any more and a started hint is dropped.
    pub fn app_resigned_active(&mut self) {
        self.set_control_key_held(false);
        self.set_typed_pane_hint(String::new(), None);
    }

    /// The earliest moment [`KeybindingResolver::tick`] has work: the prefix or pane-hint timeout.
    pub fn next_deadline(&self) -> Option<Instant> {
        match (self.prefix_deadline, self.pane_hint_deadline) {
            (Some(prefix), Some(hint)) => Some(prefix.min(hint)),
            (prefix, hint) => prefix.or(hint),
        }
    }

    /// Expires the prefix mode and the typed pane hint whose timeout has passed by `now`.
    /// Returns whether anything expired.
    pub fn tick(&mut self, now: Instant) -> bool {
        let mut expired = false;
        if self.prefix_deadline.is_some_and(|deadline| deadline <= now) {
            self.clear_prefix_mode();
            expired = true;
        }
        if self.pane_hint_deadline.is_some_and(|deadline| deadline <= now) {
            self.set_typed_pane_hint(String::new(), None);
            expired = true;
        }
        expired
    }

    /// Changes for the UI since the last drain, oldest first.
    pub fn drain_changes(&mut self) -> Vec<ResolverChange> {
        std::mem::take(&mut self.changes)
    }

    /// Resolves one key-down event.
    pub fn handle(&mut self, event: &KeyEvent, context: &KeyContext<'_>) -> KeyOutcome {
        // A timer the host has not fired yet still counts as fired.
        self.tick(context.now);
        if context.keys_captured {
            return KeyOutcome::PassThrough;
        }

        let key = event.binding_key();
        let modifiers = event.modifiers();

        // A started pane hint takes its next letter with or without the hint chord. Esc drops
        // it; any other key drops it and then does what it always does.
        if !self.typed_pane_hint.is_empty() {
            let typed = self.typed_pane_hint.clone();
            self.set_typed_pane_hint(String::new(), None);
            if key == ESCAPE {
                return KeyOutcome::Consumed;
            }
            if self.platform.may_continue_pane_hint(modifiers)
                && let Some(outcome) = self
                    .perform_pane_hint_step(pane_hint_step(&typed, &key, false, context.pane_hints), context)
            {
                return outcome;
            }
        }

        if self.platform.is_ctrl_only(modifiers) && key == self.config.prefix_key.to_lowercase() {
            if should_forward_prefix_key(self.state) {
                self.clear_prefix_mode();
                return KeyOutcome::LiteralPrefix;
            }
            self.start_prefix_mode(context.now);
            return KeyOutcome::EnterPrefix;
        }

        if self.state == KeybindingState::Prefix {
            let binding =
                self.config.bindings.iter().find(|binding| matches_prefix_binding(binding, &key, modifiers));
            let id = binding.map(|binding| binding.id.clone());
            self.clear_prefix_mode();
            return id.map_or(KeyOutcome::Consumed, KeyOutcome::Action);
        }

        if let Some(binding) =
            self.config.bindings.iter().find(|binding| self.matches_direct_binding(binding, event))
        {
            // Terminal applications get first refusal for Ctrl+H/J/K/L. Vim, tmux, fuzzy finders,
            // and completion menus can consume the keys; the navigation bridge bubbles them back
            // to Soprano only when an inner layout reaches its boundary.
            if PANE_NAVIGATION_BINDING_IDS.contains(&binding.id.as_str())
                && context.terminal_claims_control_keys()
            {
                return KeyOutcome::PassThrough;
            }
            if dispatches_through_main_menu(&binding.id) {
                return KeyOutcome::MenuAction(binding.id.clone());
            }
            if context.focused_content.owns_chord(&binding.key, self.logical_modifiers(event, binding)) {
                return KeyOutcome::PassThrough;
            }
            return KeyOutcome::Action(binding.id.clone());
        }

        if self.platform.is_pane_shortcut_chord(modifiers) {
            let step = pane_hint_step("", &key, context.terminal_claims_control_keys(), context.pane_hints);
            if let Some(outcome) = self.perform_pane_hint_step(step, context) {
                return outcome;
            }
        }

        KeyOutcome::PassThrough
    }

    fn matches_direct_binding(&self, binding: &KeyBinding, event: &KeyEvent) -> bool {
        if binding.mode != KeyBindingMode::Direct {
            return false;
        }
        let key =
            if self.platform.adds_shift(binding) { event.base_binding_key() } else { event.binding_key() };

        // Ghostty accepts both Command+= and Command+plus for increasing the font size. Depending
        // on the keyboard layout, plus may be a dedicated key or a shifted equal, so accept either
        // representation here.
        let is_zoom_in_alias = binding.id == "zoom-in" && binding.key == "=" && (key == "=" || key == "+");
        if binding.key != key && !is_zoom_in_alias {
            return false;
        }

        let required = self.platform.required_modifiers(binding);
        self.platform.modifiers_match(event.modifiers(), required, is_zoom_in_alias)
    }

    /// The macOS-style flags `binding` was pressed with, for [`FocusedContent::owns_chord`]. On
    /// macOS they are the event's own (Option included, as in the Swift app); elsewhere the
    /// physical chord is ambiguous (Ctrl+Shift is ⌘ or ⌃⇧), so they come from the binding.
    fn logical_modifiers(&self, event: &KeyEvent, binding: &KeyBinding) -> Modifiers {
        match self.platform {
            Platform::MacOs => event.modifiers(),
            Platform::Linux | Platform::Windows => Modifiers {
                ctrl: binding.ctrl == Some(true),
                alt: false,
                shift: binding.shift == Some(true),
                cmd: binding.meta == Some(true),
            },
        }
    }

    /// The outcome of a step that used the key, or `None` when the key is not the hint's.
    fn perform_pane_hint_step(&mut self, step: PaneHintStep, context: &KeyContext<'_>) -> Option<KeyOutcome> {
        match step {
            PaneHintStep::PassThrough => None,
            PaneHintStep::Pending(typed) => {
                self.set_typed_pane_hint(typed.clone(), Some(context.now));
                Some(KeyOutcome::PaneHintPending(typed))
            }
            PaneHintStep::Focus(pane_id) => Some(KeyOutcome::FocusPaneHint(pane_id)),
        }
    }

    fn timeout(&self) -> Duration {
        Duration::from_millis(u64::try_from(self.config.prefix_timeout_ms).unwrap_or(0))
    }

    /// Sets the typed hint; a non-empty one (re)starts its timeout from `now`.
    fn set_typed_pane_hint(&mut self, typed: String, now: Option<Instant>) {
        self.pane_hint_deadline = match now {
            Some(now) if !typed.is_empty() => Some(now + self.timeout()),
            _ => None,
        };
        if self.typed_pane_hint == typed {
            return;
        }
        self.typed_pane_hint.clone_from(&typed);
        self.changes.push(ResolverChange::TypedPaneHint(typed));
    }

    fn start_prefix_mode(&mut self, now: Instant) {
        self.state = KeybindingState::Prefix;
        self.notify_state(KeybindingState::Prefix);
        self.prefix_deadline = Some(now + self.timeout());
    }

    fn clear_prefix_mode(&mut self) {
        self.state = KeybindingState::Normal;
        self.notify_state(KeybindingState::Normal);
        self.prefix_deadline = None;
    }

    fn notify_state(&mut self, state: KeybindingState) {
        self.display_state = state;
        self.changes.push(ResolverChange::State(state));
    }

    fn set_control_key_held(&mut self, held: bool) {
        if self.is_control_key_held == held {
            return;
        }
        self.is_control_key_held = held;
        self.changes.push(ResolverChange::ControlKeyHeld(held));
    }
}

/// Whether the prefix key is forwarded as a literal key (pressed again in prefix mode).
pub fn should_forward_prefix_key(state: KeybindingState) -> bool {
    state == KeybindingState::Prefix
}

/// A prefix binding matches by key and Shift alone: the prefix already consumed Ctrl, and
/// Ctrl/Cmd/Option are ignored on the second key.
fn matches_prefix_binding(binding: &KeyBinding, key: &str, modifiers: Modifiers) -> bool {
    binding.mode == KeyBindingMode::Prefix
        && binding.key == key
        && modifiers.shift == (binding.shift == Some(true))
}
