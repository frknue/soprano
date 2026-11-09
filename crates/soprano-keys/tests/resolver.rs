mod support;

use std::time::{Duration, Instant};

use soprano_keys::{
    BindingCommand, FocusedContent, KeyContext, KeyEvent, KeyOutcome, KeybindingResolver, Modifiers,
    PaneHintAssignment, PaneNavigationClaimRegistry, Platform, ResolverChange, TerminalTarget,
    should_forward_prefix_key,
};
use soprano_types::{AgentCatalog, DefaultAgents, KeyBindingMode, KeybindingState};
use support::default_config;

fn resolver(platform: Platform) -> KeybindingResolver {
    KeybindingResolver::new(default_config(), platform)
}

fn press(resolver: &mut KeybindingResolver, event: KeyEvent) -> KeyOutcome {
    resolver.handle(&event, &KeyContext::new(Instant::now()))
}

fn action(id: &str) -> KeyOutcome {
    KeyOutcome::Action(id.to_owned())
}

fn key(key: &str) -> KeyEvent {
    KeyEvent::new(key)
}

fn command(id: &str) -> Option<BindingCommand> {
    BindingCommand::from_binding_id(id, &AgentCatalog::new(DefaultAgents::all()))
}

// MARK: - PaneTabShortcutTests

#[test]
fn control_command_t_arrows_and_w_open_cycle_and_close_tabs_inside_the_focused_split_only() {
    let mut keys = resolver(Platform::MacOs);

    assert_eq!(press(&mut keys, key("t").with_ctrl().with_cmd()), action("new-pane-tab-direct"));
    assert_eq!(press(&mut keys, key("left").with_ctrl().with_cmd()), action("prev-pane-tab-direct"));
    assert_eq!(press(&mut keys, key("right").with_ctrl().with_cmd()), action("next-pane-tab-direct"));
    assert_eq!(press(&mut keys, key("w").with_ctrl().with_cmd()), action("close-pane-tab-direct"));

    assert_eq!(command("new-pane-tab-direct"), Some(BindingCommand::NewPaneTab));
    assert_eq!(command("prev-pane-tab-direct"), Some(BindingCommand::PreviousPaneTab));
    assert_eq!(command("next-pane-tab-direct"), Some(BindingCommand::NextPaneTab));
    assert_eq!(command("close-pane-tab-direct"), Some(BindingCommand::CloseActivePaneTab));
}

#[test]
fn command_w_and_prefix_x_close_only_the_active_pane_tab_until_the_last_one_takes_the_pane() {
    let mut keys = resolver(Platform::MacOs);

    assert_eq!(press(&mut keys, key("w").with_cmd()), action("close-active"));
    assert_eq!(press(&mut keys, key("a").with_ctrl()), KeyOutcome::EnterPrefix);
    assert_eq!(press(&mut keys, key("x")), action("kill-pane"));
    assert_eq!(keys.state(), KeybindingState::Normal);

    assert_eq!(command("close-active"), Some(BindingCommand::CloseActivePaneTab));
    assert_eq!(command("kill-pane"), Some(BindingCommand::CloseActivePaneTab));
}

#[test]
fn control_arrow_without_command_still_reaches_the_terminal() {
    let mut keys = resolver(Platform::MacOs);
    // ⌃→ (word jump, Spaces) goes on to the terminal untouched.
    assert_eq!(press(&mut keys, key("right").with_ctrl()), KeyOutcome::PassThrough);
}

// MARK: - KeybindingPassthroughTests

#[test]
fn the_command_palette_keeps_its_keys_and_a_plain_window_does_not() {
    let mut keys = resolver(Platform::MacOs);
    let now = Instant::now();
    let palette = KeyContext { keys_captured: true, ..KeyContext::new(now) };

    assert_eq!(keys.handle(&key("a").with_ctrl(), &palette), KeyOutcome::PassThrough);
    assert_eq!(keys.state(), KeybindingState::Normal);
    assert_eq!(keys.handle(&key("a").with_ctrl(), &KeyContext::new(now)), KeyOutcome::EnterPrefix);
}

#[test]
fn a_dialog_keeps_sopranos_chords_so_command_d_picks_dont_save_instead_of_opening_a_terminal() {
    let mut keys = resolver(Platform::MacOs);
    let now = Instant::now();
    let dialog = KeyContext { keys_captured: true, ..KeyContext::new(now) };
    let command_d = key("d").with_cmd();

    assert_eq!(keys.handle(&command_d, &dialog), KeyOutcome::PassThrough);
    assert!(keys.drain_changes().is_empty());

    // Once it closed, ⌘D is New Terminal again.
    assert_eq!(keys.handle(&command_d, &KeyContext::new(now)), action("new-terminal"));
}

// MARK: - Prefix

#[test]
fn repeated_prefix_forwards_literal_control_a() {
    assert!(!should_forward_prefix_key(KeybindingState::Normal));
    assert!(should_forward_prefix_key(KeybindingState::Prefix));

    let mut keys = resolver(Platform::MacOs);
    assert_eq!(press(&mut keys, key("a").with_ctrl()), KeyOutcome::EnterPrefix);
    assert_eq!(press(&mut keys, key("a").with_ctrl()), KeyOutcome::LiteralPrefix);
    assert_eq!(keys.state(), KeybindingState::Normal);
    assert_eq!(
        keys.drain_changes(),
        vec![ResolverChange::State(KeybindingState::Prefix), ResolverChange::State(KeybindingState::Normal)]
    );
}

#[test]
fn a_key_after_the_prefix_that_matches_nothing_is_swallowed_and_ends_prefix_mode() {
    let mut keys = resolver(Platform::MacOs);
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key("z")), KeyOutcome::Consumed);
    assert_eq!(keys.state(), KeybindingState::Normal);
    assert_eq!(press(&mut keys, key("x")), KeyOutcome::PassThrough);
}

#[test]
fn prefix_bindings_match_by_key_and_shift_alone() {
    let mut keys = resolver(Platform::MacOs);
    let mut after_prefix = |event: KeyEvent| {
        assert_eq!(press(&mut keys, key("a").with_ctrl()), KeyOutcome::EnterPrefix);
        press(&mut keys, event)
    };
    assert_eq!(after_prefix(key("l")), action("resize-right"));
    assert_eq!(after_prefix(key("L").with_shift()), action("last-window"));
    assert_eq!(after_prefix(key("|").with_shift()), action("split-vertical"));
    assert_eq!(after_prefix(key("-")), action("split-horizontal"));
    // Ctrl and Cmd on the second key are ignored.
    assert_eq!(after_prefix(key("x").with_ctrl()), action("kill-pane"));
    assert_eq!(after_prefix(key("x").with_cmd()), action("kill-pane"));
}

#[test]
fn the_prefix_times_out_after_prefix_timeout_ms() {
    let mut keys = resolver(Platform::MacOs);
    let start = Instant::now();
    assert_eq!(keys.handle(&key("a").with_ctrl(), &KeyContext::new(start)), KeyOutcome::EnterPrefix);
    let deadline = start + Duration::from_millis(1500);
    assert_eq!(keys.next_deadline(), Some(deadline));

    assert!(!keys.tick(deadline - Duration::from_millis(1)));
    assert_eq!(keys.state(), KeybindingState::Prefix);
    assert!(keys.tick(deadline));
    assert_eq!(keys.state(), KeybindingState::Normal);
    assert_eq!(keys.next_deadline(), None);
}

#[test]
fn a_key_after_an_unfired_prefix_timeout_is_not_a_prefix_key() {
    let mut keys = resolver(Platform::MacOs);
    let start = Instant::now();
    keys.handle(&key("a").with_ctrl(), &KeyContext::new(start));
    let late = KeyContext::new(start + Duration::from_secs(2));
    assert_eq!(keys.handle(&key("x"), &late), KeyOutcome::PassThrough);
}

#[test]
fn applying_a_new_config_drops_a_half_typed_prefix_chord() {
    let mut keys = resolver(Platform::MacOs);
    press(&mut keys, key("a").with_ctrl());
    let mut config = default_config();
    config.prefix_key = "b".into();
    keys.apply_config(config);

    assert_eq!(keys.state(), KeybindingState::Normal);
    assert_eq!(press(&mut keys, key("x")), KeyOutcome::PassThrough);
    assert_eq!(press(&mut keys, key("b").with_ctrl()), KeyOutcome::EnterPrefix);
}

#[test]
fn applying_a_config_outside_prefix_mode_reports_no_state_change() {
    let mut keys = resolver(Platform::MacOs);
    keys.apply_config(default_config());
    assert!(keys.drain_changes().is_empty());
}

// MARK: - Direct bindings and focused content

#[test]
fn zoom_in_accepts_command_equal_and_command_plus() {
    let mut keys = resolver(Platform::MacOs);
    assert_eq!(press(&mut keys, key("=").with_cmd()), action("zoom-in"));
    assert_eq!(press(&mut keys, key("+").with_cmd().with_shift()), action("zoom-in"));
    assert_eq!(press(&mut keys, key("+").with_cmd()), action("zoom-in"));
    assert_eq!(press(&mut keys, key("-").with_cmd()), action("zoom-out"));
}

#[test]
fn option_is_ignored_when_matching_on_macos() {
    let mut keys = resolver(Platform::MacOs);
    assert_eq!(press(&mut keys, key("d").with_cmd().with_alt()), action("new-terminal"));
    assert_eq!(press(&mut keys, key("a").with_ctrl().with_alt()), KeyOutcome::EnterPrefix);
}

#[test]
fn the_command_palette_and_open_project_go_through_the_app_menu() {
    let mut keys = resolver(Platform::MacOs);
    assert_eq!(press(&mut keys, key("p").with_cmd()), KeyOutcome::MenuAction("command-palette".into()));
    assert_eq!(
        press(&mut keys, key("p").with_cmd().with_shift()),
        KeyOutcome::MenuAction("open-project".into())
    );
    assert_eq!(press(&mut keys, key("f").with_cmd()), action("find-window"));
    assert_eq!(press(&mut keys, key("d").with_cmd().with_shift()), action("agent-dashboard"));
}

#[test]
fn a_focused_browser_or_editor_keeps_the_chords_it_owns() {
    let mut keys = resolver(Platform::MacOs);
    let now = Instant::now();
    let focused = |content| KeyContext { focused_content: content, ..KeyContext::new(now) };

    let browser = focused(FocusedContent::Browser);
    assert_eq!(keys.handle(&key("l").with_cmd(), &browser), KeyOutcome::PassThrough);
    assert_eq!(keys.handle(&key("f").with_cmd(), &browser), action("find-window"));

    let editor = focused(FocusedContent::Editor);
    assert_eq!(keys.handle(&key("f").with_cmd(), &editor), KeyOutcome::PassThrough);
    assert_eq!(keys.handle(&key("g").with_cmd().with_shift(), &editor), KeyOutcome::PassThrough);
    assert_eq!(keys.handle(&key("s").with_cmd().with_shift(), &editor), action("save-session"));

    let automations = focused(FocusedContent::Automations);
    assert_eq!(keys.handle(&key("n").with_cmd(), &automations), KeyOutcome::PassThrough);

    let terminal = focused(FocusedContent::Terminal);
    assert_eq!(keys.handle(&key("l").with_cmd(), &terminal), action("toggle-right-sidebar"));
    assert_eq!(keys.handle(&key("n").with_cmd(), &terminal), action("new-window"));
}

// MARK: - Navigation passthrough

#[test]
fn a_claimed_tab_gets_control_hjkl_and_every_other_tab_navigates() {
    let mut keys = resolver(Platform::MacOs);
    let claimed = TerminalTarget::new("pane-1", "tab-1");
    let mut claims = PaneNavigationClaimRegistry::new();
    claims.enable("nvim", &claimed);
    let now = Instant::now();

    let in_claimed =
        KeyContext { active_target: Some(claimed.clone()), claims: &claims, ..KeyContext::new(now) };
    for letter in ["h", "j", "k", "l"] {
        assert_eq!(keys.handle(&key(letter).with_ctrl(), &in_claimed), KeyOutcome::PassThrough);
    }
    // Other bindings still work in the claimed tab.
    assert_eq!(keys.handle(&key("1").with_ctrl(), &in_claimed), action("select-window-1"));

    let other_tab = KeyContext {
        active_target: Some(TerminalTarget::new("pane-1", "tab-2")),
        claims: &claims,
        ..KeyContext::new(now)
    };
    assert_eq!(keys.handle(&key("h").with_ctrl(), &other_tab), action("nav-left"));
}

// MARK: - Pane hints

fn hints() -> Vec<PaneHintAssignment> {
    vec![
        PaneHintAssignment::new("b", "pane-1"),
        PaneHintAssignment::new("zb", "pane-2"),
        PaneHintAssignment::new("zd", "pane-3"),
        PaneHintAssignment::new("g", "pane-4"),
    ]
}

#[test]
fn control_shift_and_a_hint_letter_focuses_its_pane() {
    let mut keys = resolver(Platform::MacOs);
    let hints = hints();
    let context = KeyContext { pane_hints: &hints, ..KeyContext::new(Instant::now()) };
    assert_eq!(
        keys.handle(&key("g").with_ctrl().with_shift(), &context),
        KeyOutcome::FocusPaneHint("pane-4".into())
    );
    // An unassigned letter is the terminal's.
    assert_eq!(keys.handle(&key("x").with_ctrl().with_shift(), &context), KeyOutcome::PassThrough);
    // A binding on the chord wins over a hint.
    let hints = [PaneHintAssignment::new("h", "pane-9")];
    let context = KeyContext { pane_hints: &hints, ..KeyContext::new(Instant::now()) };
    assert_eq!(keys.handle(&key("h").with_ctrl().with_shift(), &context), action("previous-window-direct"));
}

#[test]
fn a_claimed_terminal_keeps_control_shift_letters_from_pane_hints() {
    let mut keys = resolver(Platform::MacOs);
    let hints = hints();
    let target = TerminalTarget::new("pane-1", "tab-1");
    let mut claims = PaneNavigationClaimRegistry::new();
    claims.enable("nvim", &target);
    let context = KeyContext {
        active_target: Some(target),
        claims: &claims,
        pane_hints: &hints,
        ..KeyContext::new(Instant::now())
    };
    assert_eq!(keys.handle(&key("g").with_ctrl().with_shift(), &context), KeyOutcome::PassThrough);
}

#[test]
fn a_longer_hint_takes_its_next_letter_with_or_without_control_shift() {
    let mut keys = resolver(Platform::MacOs);
    let hints = hints();
    let now = Instant::now();
    let context = KeyContext { pane_hints: &hints, ..KeyContext::new(now) };

    assert_eq!(
        keys.handle(&key("z").with_ctrl().with_shift(), &context),
        KeyOutcome::PaneHintPending("z".into())
    );
    assert_eq!(keys.typed_pane_hint(), "z");
    assert_eq!(keys.handle(&key("d"), &context), KeyOutcome::FocusPaneHint("pane-3".into()));
    assert_eq!(keys.typed_pane_hint(), "");

    keys.handle(&key("z").with_ctrl().with_shift(), &context);
    assert_eq!(
        keys.handle(&key("b").with_ctrl().with_shift(), &context),
        KeyOutcome::FocusPaneHint("pane-2".into())
    );
    assert_eq!(
        keys.drain_changes(),
        vec![
            ResolverChange::TypedPaneHint("z".into()),
            ResolverChange::TypedPaneHint(String::new()),
            ResolverChange::TypedPaneHint("z".into()),
            ResolverChange::TypedPaneHint(String::new()),
        ]
    );
}

#[test]
fn escape_drops_a_started_hint_and_any_other_key_drops_it_and_does_what_it_always_does() {
    let mut keys = resolver(Platform::MacOs);
    let hints = hints();
    let context = KeyContext { pane_hints: &hints, ..KeyContext::new(Instant::now()) };

    keys.handle(&key("z").with_ctrl().with_shift(), &context);
    assert_eq!(keys.handle(&key("escape"), &context), KeyOutcome::Consumed);
    assert_eq!(keys.typed_pane_hint(), "");

    keys.handle(&key("z").with_ctrl().with_shift(), &context);
    assert_eq!(keys.handle(&key("x"), &context), KeyOutcome::PassThrough);
    assert_eq!(keys.typed_pane_hint(), "");

    // ⌘ never continues a hint: ⌘B after ⌃⇧Z is New Browser, not pane-2.
    keys.handle(&key("z").with_ctrl().with_shift(), &context);
    assert_eq!(keys.handle(&key("b").with_cmd(), &context), action("new-browser"));
}

#[test]
fn a_started_hint_times_out_after_prefix_timeout_ms() {
    let mut keys = resolver(Platform::MacOs);
    let hints = hints();
    let start = Instant::now();
    let context = KeyContext { pane_hints: &hints, ..KeyContext::new(start) };
    keys.handle(&key("z").with_ctrl().with_shift(), &context);
    keys.drain_changes();

    let deadline = start + Duration::from_millis(1500);
    assert_eq!(keys.next_deadline(), Some(deadline));
    assert!(keys.tick(deadline));
    assert_eq!(keys.typed_pane_hint(), "");
    assert_eq!(keys.drain_changes(), vec![ResolverChange::TypedPaneHint(String::new())]);

    // A late letter no longer completes the hint.
    keys.handle(&key("z").with_ctrl().with_shift(), &context);
    let late = KeyContext { pane_hints: &hints, ..KeyContext::new(start + Duration::from_secs(2)) };
    assert_eq!(keys.handle(&key("d"), &late), KeyOutcome::PassThrough);
}

// MARK: - Held control, copy mode

#[test]
fn holding_control_reveals_hints_until_released_or_the_app_resigns() {
    let mut keys = resolver(Platform::MacOs);
    keys.modifiers_changed(Modifiers { ctrl: true, ..Modifiers::default() });
    keys.modifiers_changed(Modifiers { ctrl: true, shift: true, ..Modifiers::default() });
    assert!(keys.is_control_key_held());
    keys.modifiers_changed(Modifiers::default());
    assert!(!keys.is_control_key_held());
    keys.modifiers_changed(Modifiers { ctrl: true, ..Modifiers::default() });
    keys.app_resigned_active();
    assert!(!keys.is_control_key_held());
    assert_eq!(
        keys.drain_changes(),
        vec![
            ResolverChange::ControlKeyHeld(true),
            ResolverChange::ControlKeyHeld(false),
            ResolverChange::ControlKeyHeld(true),
            ResolverChange::ControlKeyHeld(false),
        ]
    );
}

#[test]
fn copy_mode_shows_in_the_status_mode_without_touching_prefix_handling() {
    let mut keys = resolver(Platform::MacOs);
    keys.copy_mode_changed(KeybindingState::Copy);
    assert_eq!(keys.display_state(), KeybindingState::Copy);
    assert_eq!(keys.state(), KeybindingState::Normal);
    keys.copy_mode_changed(KeybindingState::CopySelection);
    assert_eq!(keys.display_state(), KeybindingState::CopySelection);
    assert_eq!(press(&mut keys, key("a").with_ctrl()), KeyOutcome::EnterPrefix);
    assert_eq!(keys.display_state(), KeybindingState::Prefix);
}

// MARK: - DefaultKeybindingsTests (resolver parts)

#[test]
fn numbered_window_bindings_remain_control_number() {
    let mut keys = resolver(Platform::MacOs);
    for number in 1..=9 {
        assert_eq!(
            press(&mut keys, key(&number.to_string()).with_ctrl()),
            action(&format!("select-window-{number}"))
        );
        assert_eq!(command(&format!("select-window-{number}")), Some(BindingCommand::SelectWindow(number)));
    }
}

#[test]
fn tmux_window_cycling_uses_prefix_p_and_n() {
    let mut keys = resolver(Platform::MacOs);
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key("p")), action("previous-window"));
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key("n")), action("next-window"));
    assert_eq!(press(&mut keys, key("h").with_ctrl().with_shift()), action("previous-window-direct"));
    assert_eq!(press(&mut keys, key("l").with_ctrl().with_shift()), action("next-window-direct"));
}

#[test]
fn pane_tab_cycling_uses_prefix_angle_brackets() {
    let mut keys = resolver(Platform::MacOs);
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key("<").with_shift()), action("prev-pane-tab"));
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key(">").with_shift()), action("next-pane-tab"));
}

#[test]
fn copy_mode_supports_both_tmux_bracket_shortcuts() {
    let mut keys = resolver(Platform::MacOs);
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key("[")), action("copy-mode"));
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key("]")), action("copy-mode-right-bracket"));
}

#[test]
fn command_t_opens_a_tab_and_control_tab_cycles_them() {
    let mut keys = resolver(Platform::MacOs);
    assert_eq!(press(&mut keys, key("t").with_cmd()), action("new-tab-direct"));
    press(&mut keys, key("a").with_ctrl());
    assert_eq!(press(&mut keys, key("t")), action("new-tab"));
    assert_eq!(press(&mut keys, key("tab").with_ctrl()), action("next-tab"));
    assert_eq!(press(&mut keys, key("\u{19}").with_ctrl().with_shift()), action("previous-tab"));
}

#[test]
fn every_default_binding_resolves_to_itself_on_macos() {
    let mut keys = resolver(Platform::MacOs);
    for binding in default_config().bindings {
        let mut event = KeyEvent::new(binding.key.clone());
        event.ctrl = binding.ctrl == Some(true);
        event.cmd = binding.meta == Some(true);
        event.shift = binding.shift == Some(true);
        if binding.mode == KeyBindingMode::Prefix {
            assert_eq!(press(&mut keys, key("a").with_ctrl()), KeyOutcome::EnterPrefix);
        }
        let outcome = press(&mut keys, event);
        let expected = if soprano_keys::dispatches_through_main_menu(&binding.id) {
            KeyOutcome::MenuAction(binding.id.clone())
        } else {
            action(&binding.id)
        };
        assert_eq!(outcome, expected, "binding {}", binding.id);
        assert!(command(&binding.id).is_some(), "command for {}", binding.id);
    }
}

// MARK: - Linux / Windows keyboard rule

#[test]
fn command_bindings_are_control_shift_on_linux_and_windows() {
    for platform in [Platform::Linux, Platform::Windows] {
        let mut keys = resolver(platform);
        assert_eq!(press(&mut keys, key("d").with_ctrl().with_shift()), action("new-terminal"));
        // ⌘1 is Ctrl+Shift+1, which reports `!` with Shift applied.
        assert_eq!(
            press(&mut keys, key("!").with_base_key("1").with_ctrl().with_shift()),
            action("launch-codex")
        );
        assert_eq!(press(&mut keys, key("d").with_ctrl().with_shift().with_alt()), action("agent-dashboard"));
        assert_eq!(press(&mut keys, key("t").with_ctrl().with_alt()), action("new-pane-tab-direct"));
        assert_eq!(press(&mut keys, key("right").with_ctrl().with_alt()), action("next-pane-tab-direct"));
        // Plain Ctrl chords stay Ctrl.
        assert_eq!(press(&mut keys, key("h").with_ctrl()), action("nav-left"));
        assert_eq!(press(&mut keys, key("3").with_ctrl()), action("select-window-3"));
        assert_eq!(press(&mut keys, key("tab").with_ctrl()), action("next-tab"));
        // Ctrl+Shift+L is both ⌃⇧L and ⌘L; the first binding in the table wins.
        assert_eq!(press(&mut keys, key("l").with_ctrl().with_shift()), action("next-window-direct"));
        // Super plays no part.
        assert_eq!(press(&mut keys, key("d").with_cmd()), KeyOutcome::PassThrough);
    }
}

#[test]
fn control_equal_and_control_plus_zoom_in_on_linux() {
    let mut keys = resolver(Platform::Linux);
    assert_eq!(press(&mut keys, key("=").with_ctrl()), action("zoom-in"));
    assert_eq!(press(&mut keys, key("+").with_base_key("=").with_ctrl().with_shift()), action("zoom-in"));
    assert_eq!(press(&mut keys, key("_").with_base_key("-").with_ctrl().with_shift()), action("zoom-out"));
}

#[test]
fn the_prefix_is_control_a_everywhere_but_control_alt_a_is_not_the_prefix_on_linux() {
    let mut keys = resolver(Platform::Linux);
    assert_eq!(press(&mut keys, key("a").with_ctrl().with_alt()), KeyOutcome::PassThrough);
    assert_eq!(press(&mut keys, key("a").with_ctrl()), KeyOutcome::EnterPrefix);
    assert_eq!(press(&mut keys, key("|").with_base_key("\\").with_shift()), action("split-vertical"));
}

#[test]
fn pane_hints_are_alt_shift_on_linux_and_windows() {
    let mut keys = resolver(Platform::Windows);
    let hints = hints();
    let context = KeyContext { pane_hints: &hints, ..KeyContext::new(Instant::now()) };
    assert_eq!(
        keys.handle(&key("g").with_alt().with_shift(), &context),
        KeyOutcome::FocusPaneHint("pane-4".into())
    );
    assert_eq!(
        keys.handle(&key("z").with_alt().with_shift(), &context),
        KeyOutcome::PaneHintPending("z".into())
    );
    assert_eq!(keys.handle(&key("d"), &context), KeyOutcome::FocusPaneHint("pane-3".into()));
    // Ctrl+Shift+B is ⌘B here.
    assert_eq!(keys.handle(&key("b").with_ctrl().with_shift(), &context), action("new-browser"));

    keys.modifiers_changed(Modifiers { alt: true, shift: true, ..Modifiers::default() });
    assert!(keys.is_control_key_held());
    keys.modifiers_changed(Modifiers { alt: true, ..Modifiers::default() });
    assert!(!keys.is_control_key_held());
}

#[test]
fn focused_content_owns_command_chords_on_linux_as_their_mapped_keys() {
    let mut keys = resolver(Platform::Linux);
    let editor = KeyContext { focused_content: FocusedContent::Editor, ..KeyContext::new(Instant::now()) };
    assert_eq!(keys.handle(&key("f").with_ctrl().with_shift(), &editor), KeyOutcome::PassThrough);
    assert_eq!(keys.handle(&key("g").with_ctrl().with_shift().with_alt(), &editor), KeyOutcome::PassThrough);
}

#[test]
fn a_command_chord_on_a_shifted_symbol_is_control_shift_without_alt_on_linux() {
    let mut config = default_config();
    config.bindings.retain(|binding| binding.id != "zoom-in");
    let mut plus = config.bindings[0].clone();
    plus.id = "custom-plus".into();
    plus.mode = KeyBindingMode::Direct;
    plus.key = "+".into();
    plus.ctrl = None;
    plus.meta = Some(true);
    plus.shift = Some(true);
    config.bindings.insert(0, plus);
    let mut keys = KeybindingResolver::new(config, Platform::Linux);

    let control_shift_plus = key("+").with_base_key("=").with_ctrl().with_shift();
    assert_eq!(press(&mut keys, control_shift_plus.clone()), action("custom-plus"));
    assert_eq!(press(&mut keys, control_shift_plus.with_alt()), KeyOutcome::PassThrough);
}
