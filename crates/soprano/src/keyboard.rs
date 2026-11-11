//! Keyboard routing (`KeybindingManager`'s event monitor): every key goes through the
//! [`KeybindingResolver`] before any content view sees it, with the focused content, the
//! navigation passthrough claims and the pane hints of the session. The resolver's timers
//! (prefix and pane-hint timeouts) run here.

use std::time::Instant;

use gpui::{KeyBinding, Keystroke, NoAction};
use soprano_keys::{KeyEvent, Modifiers};

/// Content whose own key handling owns Tab and Shift-Tab: a terminal sends them to its program
/// (`\t`, `ESC [ Z`); the Agent Dashboard moves between its list and reply box (in its
/// keystroke interceptor) and, like Swift, does nothing on ⇧Tab in the list, where Root's
/// traversal would otherwise move focus.
pub const TAB_TAKING_CONTEXTS: [&str; 2] = [soprano_term::view::KEY_CONTEXT, "AgentDashboard"];

/// gpui-component's `Root` binds Tab / Shift-Tab (context `Root`, an ancestor of every view)
/// to focus traversal. A matched binding wins over key-down listeners, so without these the
/// terminal never sees Tab and no shell completion or TUI gets it. A `NoAction` binding in the
/// deeper content context cancels the Root binding there only; dialogs, Settings and the
/// Automations editor keep moving focus with Tab, and bindings of contexts nested deeper
/// (text inputs) still apply.
pub fn tab_passthrough_bindings() -> Vec<KeyBinding> {
    TAB_TAKING_CONTEXTS
        .iter()
        .flat_map(|context| ["tab", "shift-tab"].map(|key| KeyBinding::new(key, NoAction, Some(context))))
        .collect()
}

/// The resolver's view of a GPUI keystroke: `key` with Shift applied (AppKit's
/// `charactersIgnoringModifiers`), `base_key` without it, and Shift set whenever `key` is a
/// symbol that needs it.
///
/// GPUI folds Shift into the symbol it produces and clears the flag on every platform: Shift+\
/// arrives as `|` without Shift. Bindings carry Shift for such symbols (`KeyChord::new` infers
/// it, and the built-in `split-vertical` is Prefix → Shift+|), so the flag and the unshifted base
/// key are restored here; otherwise every shifted-symbol binding matches nothing.
pub fn key_event(keystroke: &Keystroke) -> KeyEvent {
    let modifiers = &keystroke.modifiers;
    let reported = keystroke.key.as_str();
    let base = unshifted(reported).unwrap_or(reported);
    let key = if base.chars().count() == 1 {
        let typed = keystroke
            .key_char
            .as_deref()
            .filter(|c| c.chars().count() == 1 && !c.chars().any(char::is_control))
            .filter(|_| !modifiers.control && !modifiers.platform);
        match typed {
            Some(typed) => typed.to_owned(),
            None if modifiers.shift || base != reported => shifted(base),
            None => base.to_owned(),
        }
    } else {
        base.to_owned()
    };
    KeyEvent {
        shift: modifiers.shift || soprano_keys::is_shifted_symbol(&key),
        key,
        base_key: Some(base.to_owned()),
        ctrl: modifiers.control,
        alt: modifiers.alt,
        cmd: modifiers.platform,
        is_repeat: false,
    }
}

pub fn modifiers(modifiers: &gpui::Modifiers) -> Modifiers {
    Modifiers { ctrl: modifiers.control, alt: modifiers.alt, shift: modifiers.shift, cmd: modifiers.platform }
}

/// Each key of a US layout and the symbol Shift makes of it.
const SHIFT_PAIRS: [(&str, &str); 21] = [
    ("1", "!"),
    ("2", "@"),
    ("3", "#"),
    ("4", "$"),
    ("5", "%"),
    ("6", "^"),
    ("7", "&"),
    ("8", "*"),
    ("9", "("),
    ("0", ")"),
    ("-", "_"),
    ("=", "+"),
    ("[", "{"),
    ("]", "}"),
    ("\\", "|"),
    (";", ":"),
    ("'", "\""),
    (",", "<"),
    (".", ">"),
    ("/", "?"),
    ("`", "~"),
];

/// The character Shift makes of `key` on a US layout.
fn shifted(key: &str) -> String {
    SHIFT_PAIRS
        .iter()
        .find(|(base, _)| *base == key)
        .map_or_else(|| key.to_uppercase(), |(_, symbol)| (*symbol).to_owned())
}

/// The US-layout key Shift turns into `symbol`, or `None` when `symbol` needs no Shift.
fn unshifted(symbol: &str) -> Option<&'static str> {
    SHIFT_PAIRS.iter().find(|(_, shifted)| *shifted == symbol).map(|(base, _)| *base)
}

/// When the resolver next needs a tick, as a delay from now.
pub fn delay_until(deadline: Instant, now: Instant) -> std::time::Duration {
    deadline.saturating_duration_since(now)
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::Path;
    use std::rc::Rc;
    use std::time::{Duration, Instant};

    use gpui::{AppContext, Entity, Focusable, TestAppContext, Window};
    use gpui_component::Root;
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_model::Workspace;
    use soprano_platform::StateStore;
    use soprano_term::{TerminalLaunch, TerminalSettings, TerminalView};

    use crate::content::{ContentHost, TerminalFactory};
    use crate::shell::Shell;
    use crate::views::split_tree::SplitTree;
    use crate::workspace::WorkspaceHandle;

    /// Every terminal runs `script` under /bin/sh instead of the user's shell.
    struct ScriptTerminals(String);

    impl TerminalFactory for ScriptTerminals {
        fn create(
            &self,
            _: TerminalLaunch,
            settings: TerminalSettings,
            window: &mut Window,
            cx: &mut gpui::App,
        ) -> anyhow::Result<Entity<TerminalView>> {
            let launch = TerminalLaunch {
                argv: vec!["/bin/sh".into(), "-c".into(), self.0.clone()],
                env: [("PATH".to_owned(), "/bin:/usr/bin".to_owned())].into(),
                ..TerminalLaunch::default()
            };
            TerminalView::spawn(launch, settings, window, cx)
        }

        fn restart(&self, _: &Entity<TerminalView>, _: TerminalLaunch, _: &mut gpui::App) -> bool {
            false
        }

        fn run_detached(&self, _: Vec<String>) {}
    }

    /// The file at `path` once it exists with at least `bytes` bytes (or after 10 s).
    fn wait_for(path: &Path, bytes: usize) -> Option<Vec<u8>> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let read = std::fs::read(path).ok().filter(|read| read.len() >= bytes);
            if read.is_some() || Instant::now() > deadline {
                return read;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Regression: Root's Tab focus traversal swallowed Tab and Shift-Tab before the terminal's
    /// key handler, so `cat -v` saw nothing and shells never completed.
    #[gpui::test]
    fn tab_and_shift_tab_reach_the_program_in_a_terminal_pane(cx: &mut TestAppContext) {
        let folder = tempfile::tempdir().expect("folder");
        let (ready, output) = (folder.path().join("ready"), folder.path().join("bytes"));
        let script = format!("stty raw -echo; : > '{}'; head -c 4 > '{}'", ready.display(), output.display());
        // A real PTY: its reader and wait threads wake tasks from outside the test scheduler.
        cx.executor().allow_parking();
        cx.update(|cx| {
            soprano_ui::init_for_tests(cx);
            gpui_component::init(cx);
            cx.bind_keys(soprano_term::default_key_bindings());
            cx.bind_keys(tab_passthrough_bindings());
        });
        let host: Rc<std::cell::RefCell<Option<Entity<ContentHost>>>> = Rc::default();
        let stash = host.clone();
        let (_, cx) = cx.add_window_view(move |window, cx| {
            let workspace = WorkspaceHandle::new(Workspace::new(), cx);
            let shell = cx.new(|_| {
                Shell::new(
                    StateStore::in_memory(),
                    AppSettings::default_settings(),
                    DefaultKeybindings::config(),
                )
            });
            let content = cx.new(|cx| {
                ContentHost::new(
                    workspace.clone(),
                    shell.clone(),
                    Rc::new(ScriptTerminals(script)),
                    crate::content::tests::context(),
                    TerminalSettings::default(),
                    cx.new(|_| soprano_editor::EditorDocuments::new()),
                    StateStore::in_memory(),
                    window,
                    cx,
                )
            });
            *stash.borrow_mut() = Some(content.clone());
            let tree = cx.new(|cx| SplitTree::new(workspace, content, shell, cx));
            Root::new(tree, window, cx)
        });
        cx.run_until_parked();
        let content = host.borrow().clone().expect("content host");
        assert!(wait_for(&ready, 0).is_some(), "the program did not start");
        cx.update(|window, cx| {
            let terminal = content.read(cx).active_terminal(cx).expect("terminal");
            window.focus(&terminal.focus_handle(cx), cx);
        });
        cx.run_until_parked();
        cx.simulate_keystrokes("tab shift-tab");
        cx.run_until_parked();
        assert_eq!(wait_for(&output, 4).as_deref(), Some(&b"\t\x1b[Z"[..]));
        // The program has ended (`head` got its bytes); let its exit report arrive while the
        // scheduler still runs, then tear the terminal down before the test returns.
        let terminal = cx.update(|_, cx| content.read(cx).active_terminal(cx)).expect("terminal");
        let deadline = Instant::now() + Duration::from_secs(10);
        while !cx.update(|_, cx| terminal.read(cx).has_exited()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
            cx.run_until_parked();
        }
        cx.update(|_, cx| terminal.update(cx, |terminal, cx| terminal.destroy(cx)));
        cx.run_until_parked();
    }

    fn stroke(source: &'static str) -> Keystroke {
        Keystroke::parse(source).unwrap_or_else(|_| panic!("keystroke {source}"))
    }

    #[test]
    fn shifted_letters_and_symbols_read_as_typed_with_the_base_key_kept() {
        let event = key_event(&stroke("cmd-shift-p"));
        assert_eq!(event.key, "P");
        assert_eq!(event.base_key.as_deref(), Some("p"));
        assert!(event.cmd && event.shift && !event.ctrl);

        let event = key_event(&stroke("cmd-shift-["));
        assert_eq!(event.key, "{");
        assert_eq!(event.base_key.as_deref(), Some("["));
    }

    #[test]
    fn named_keys_keep_their_names() {
        assert_eq!(key_event(&stroke("ctrl-shift-tab")).key, "tab");
        assert_eq!(key_event(&stroke("escape")).key, "escape");
        assert_eq!(key_event(&stroke("pageup")).key, "pageup");
    }

    #[test]
    fn control_chords_use_the_key_not_its_control_character() {
        let event = key_event(&stroke("ctrl-a"));
        assert_eq!(event.key, "a");
        assert!(event.ctrl);
    }

    /// The keystroke GPUI delivers on every platform for Shift plus a symbol key: the symbol,
    /// with the Shift flag cleared.
    fn folded(symbol: &str, control: bool) -> Keystroke {
        Keystroke {
            modifiers: gpui::Modifiers { control, ..Default::default() },
            key: symbol.into(),
            key_char: (!control).then(|| symbol.into()),
        }
    }

    /// Regression: GPUI reports Shift+\ as `|` without Shift, so Prefix → | (split right) and
    /// every other shifted-symbol binding fell through while the palette and buttons worked.
    #[test]
    fn a_shifted_symbol_with_shift_folded_in_still_runs_its_prefix_binding() {
        let event = key_event(&folded("|", false));
        assert_eq!((event.key.as_str(), event.base_key.as_deref(), event.shift), ("|", Some("\\"), true));

        let mut resolver = soprano_keys::KeybindingResolver::new(
            DefaultKeybindings::config(),
            soprano_keys::Platform::MacOs,
        );
        let context = soprano_keys::KeyContext::new(Instant::now());
        let prefix = key_event(&folded("a", true));
        for (symbol, binding) in [("|", "split-vertical"), (">", "next-pane-tab"), ("<", "prev-pane-tab")] {
            assert_eq!(resolver.handle(&prefix, &context), soprano_keys::KeyOutcome::EnterPrefix);
            assert_eq!(
                resolver.handle(&key_event(&folded(symbol, false)), &context),
                soprano_keys::KeyOutcome::Action(binding.into())
            );
        }
    }
}
