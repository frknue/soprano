//! The native menu bar on macOS (`AppDelegate.installApplicationMenu` and
//! `MainWindowController.installCommandsMenu`): Soprano ▸ Quit, Edit, and Commands. On Linux and
//! Windows there is no menu bar; the same commands are in the command palette and the brand
//! row's ⋯ menu ([`commands_menu_items`]).
//!
//! The Commands menu's key equivalents come from the live keybindings, so a rebound chord shows
//! (and an unbound one shows none). The keys themselves are resolved by the keybinding layer
//! before GPUI's keymap; the keymap entries here exist so the menu can show them, in a key
//! context nothing ever enters.

use gpui::{App, KeyBinding, Menu, MenuItem, OsAction, actions};
use gpui_component::input::{Copy, Cut, Delete, Paste, Redo, SelectAll, Undo};
use soprano_types::{KeyBindingConfig, KeyBindingMode};

use crate::shell::Command;

actions!(
    soprano,
    [
        Quit,
        FindWindow,
        CommandPalette,
        OpenProject,
        OpenInSopranoGit,
        OpenMarkdown,
        AgentDashboard,
        Automations,
        OpenSettingsFile,
    ]
);

/// The key context of the display-only menu bindings.
const MENU_DISPLAY_CONTEXT: &str = "SopranoMenuDisplay";

/// The command each Commands-menu action runs.
pub fn command_for(action: &dyn gpui::Action) -> Option<Command> {
    let any = action.as_any();
    if any.is::<FindWindow>() {
        Some(Command::FindWindow)
    } else if any.is::<CommandPalette>() {
        Some(Command::OpenCommandPalette)
    } else if any.is::<OpenProject>() {
        Some(Command::OpenProjectSearch)
    } else if any.is::<OpenInSopranoGit>() {
        Some(Command::OpenInSopranoGit)
    } else if any.is::<OpenMarkdown>() {
        Some(Command::OpenMarkdown { pane_id: None })
    } else if any.is::<AgentDashboard>() {
        Some(Command::OpenDashboard)
    } else if any.is::<Automations>() {
        Some(Command::OpenAutomations)
    } else if any.is::<OpenSettingsFile>() {
        Some(Command::OpenSettingsFile)
    } else {
        None
    }
}

/// One Commands menu row: title, binding id (for the key equivalent), action.
type MenuCommand = (&'static str, Option<&'static str>, Box<dyn gpui::Action>);

/// The Commands menu's rows: title, binding id (for the key equivalent), action.
fn commands() -> Vec<Option<MenuCommand>> {
    vec![
        Some(("Find Window…", Some("find-window"), Box::new(FindWindow))),
        Some(("Command Palette…", Some("command-palette"), Box::new(CommandPalette))),
        Some(("Open Project…", Some("open-project"), Box::new(OpenProject))),
        Some(("Open in Soprano Git", Some("open-in-soprano-git"), Box::new(OpenInSopranoGit))),
        Some(("Open Markdown…", None, Box::new(OpenMarkdown))),
        Some(("Agent Dashboard", Some("agent-dashboard"), Box::new(AgentDashboard))),
        Some(("Automations", None, Box::new(Automations))),
        None,
        Some(("Open settings.json", None, Box::new(OpenSettingsFile))),
    ]
}

/// A binding's menu key equivalent: direct, single-key chords only (`makeCommandsMenuItem`).
pub fn key_equivalent(config: &KeyBindingConfig, binding_id: &str) -> Option<String> {
    let binding = config.bindings.iter().find(|binding| binding.id == binding_id)?;
    if binding.mode != KeyBindingMode::Direct || binding.key.chars().count() != 1 {
        return None;
    }
    let mut parts = Vec::new();
    if binding.ctrl == Some(true) {
        parts.push("ctrl".to_owned());
    }
    if binding.meta == Some(true) {
        parts.push("cmd".to_owned());
    }
    if binding.shift == Some(true) {
        parts.push("shift".to_owned());
    }
    let key = match binding.key.as_str() {
        " " => "space".to_owned(),
        key => key.to_lowercase(),
    };
    parts.push(key);
    Some(parts.join("-"))
}

/// Installs (or rebuilds after a settings change) the menu bar.
pub fn install(config: &KeyBindingConfig, cx: &mut App) {
    let mut display_bindings = vec![KeyBinding::new("cmd-q", Quit, None)];
    let mut items = Vec::new();
    for row in commands() {
        match row {
            None => items.push(MenuItem::separator()),
            Some((title, binding_id, action)) => {
                if let Some(chord) = binding_id.and_then(|id| key_equivalent(config, id))
                    && let Ok(binding) = KeyBinding::load(
                        &chord,
                        action.boxed_clone(),
                        gpui::KeyBindingContextPredicate::parse(MENU_DISPLAY_CONTEXT).ok().map(Into::into),
                        false,
                        None,
                        cx,
                    )
                {
                    display_bindings.push(binding);
                }
                items.push(MenuItem::Action {
                    name: title.into(),
                    action,
                    os_action: None,
                    checked: false,
                    disabled: false,
                });
            }
        }
    }
    replace_menu_bindings(display_bindings, cx);
    cx.set_menus([
        Menu::new("Soprano").items([MenuItem::action("Quit Soprano", Quit)]),
        Menu::new("Edit").items([
            MenuItem::os_action("Undo", Undo, OsAction::Undo),
            MenuItem::os_action("Redo", Redo, OsAction::Redo),
            MenuItem::separator(),
            MenuItem::os_action("Cut", Cut, OsAction::Cut),
            MenuItem::os_action("Copy", Copy, OsAction::Copy),
            MenuItem::os_action("Paste", Paste, OsAction::Paste),
            MenuItem::action("Delete", Delete),
            MenuItem::separator(),
            MenuItem::os_action("Select All", SelectAll, OsAction::SelectAll),
        ]),
        Menu::new("Commands").items(items),
    ]);
}

/// Swaps the previous install's menu bindings for `bindings`. GPUI only appends key bindings and
/// its menu shows an action's first binding, so appending again would freeze the menu (and
/// its key equivalents) at the launch-time chords; every other binding is kept as it is.
fn replace_menu_bindings(bindings: Vec<KeyBinding>, cx: &mut App) {
    let keymap = cx.key_bindings();
    let kept: Vec<KeyBinding> =
        keymap.borrow().bindings().filter(|binding| !is_menu_binding(binding)).cloned().collect();
    cx.clear_key_bindings();
    cx.bind_keys(kept);
    cx.bind_keys(bindings);
}

/// A binding [`install`] adds: Quit's, or one in the menu-display context.
fn is_menu_binding(binding: &KeyBinding) -> bool {
    binding.action().as_any().is::<Quit>()
        || binding.predicate().is_some_and(|predicate| predicate.to_string() == MENU_DISPLAY_CONTEXT)
}

/// The Commands menu as a soprano-ui menu, for the ⋯ button off macOS.
pub fn commands_menu_items() -> Vec<(&'static str, Command)> {
    vec![
        ("Find Window…", Command::FindWindow),
        ("Command Palette…", Command::OpenCommandPalette),
        ("Open Project…", Command::OpenProjectSearch),
        ("Open in Soprano Git", Command::OpenInSopranoGit),
        ("Open Markdown…", Command::OpenMarkdown { pane_id: None }),
        ("Agent Dashboard", Command::OpenDashboard),
        ("Automations", Command::OpenAutomations),
        ("Open settings.json", Command::OpenSettingsFile),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::DefaultKeybindings;

    #[test]
    fn menu_key_equivalents_follow_the_live_bindings() {
        let mut config = DefaultKeybindings::config();
        assert!(key_equivalent(&config, "command-palette").is_some());
        if let Some(binding) = config.bindings.iter_mut().find(|b| b.id == "command-palette") {
            binding.mode = KeyBindingMode::Prefix;
        }
        // Prefix chords cannot be menu key equivalents.
        assert_eq!(key_equivalent(&config, "command-palette"), None);
        assert_eq!(key_equivalent(&config, "no-such-binding"), None);
    }

    #[gpui::test]
    fn reinstalling_the_menu_replaces_its_key_equivalents(cx: &mut gpui::TestAppContext) {
        let mut config = DefaultKeybindings::config();
        cx.update(|cx| {
            cx.bind_keys([KeyBinding::new("cmd-c", Copy, None)]);
            install(&config, cx);
        });
        if let Some(binding) = config.bindings.iter_mut().find(|b| b.id == "command-palette") {
            binding.key = "j".to_owned();
        }
        cx.update(|cx| install(&config, cx));
        cx.update(|cx| {
            let keymap = cx.key_bindings();
            let keymap = keymap.borrow();
            let palette: Vec<String> = keymap
                .bindings_for_action(&CommandPalette)
                .map(|binding| {
                    binding.keystrokes().iter().map(|k| k.key().to_owned()).collect::<Vec<_>>().join(" ")
                })
                .collect();
            assert_eq!(palette.len(), 1);
            assert_eq!(palette[0], "j");
            assert_eq!(keymap.bindings_for_action(&Quit).count(), 1);
            // Bindings the menu does not own stay.
            assert_eq!(keymap.bindings_for_action(&Copy).count(), 1);
        });
    }

    #[test]
    fn every_commands_menu_row_maps_to_a_command() {
        for row in commands().into_iter().flatten() {
            assert!(command_for(row.2.as_ref()).is_some(), "{}", row.0);
        }
    }
}
