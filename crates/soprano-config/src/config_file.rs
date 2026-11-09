//! Location, creation, and reading/writing of `settings.json` (`Config/ConfigFile.swift`).
//!
//! The file lives where a terminal user expects a dotfile — `~/.config/soprano/`, honoring
//! `XDG_CONFIG_HOME` — on every OS, so it can be symlinked out of a dotfiles repo the same way
//! `~/.config/ghostty/config` is.

use std::io;
use std::path::{Path, PathBuf};

use soprano_platform::paths;
use soprano_types::KeyBindingConfig;

use crate::app_settings::{AppSettings, AppearancePreference, KNOWN_THEME_IDS};
use crate::default_keybindings::DefaultKeybindings;
use crate::key_chord::{KeyChord, KeyPlatform};

/// Escape hatch used by tests and by anyone running two configurations.
pub const PATH_ENVIRONMENT_KEY: &str = "SOPRANO_CONFIG";

/// `settings.json`: `$SOPRANO_CONFIG` > `$XDG_CONFIG_HOME/soprano/settings.json` >
/// `~/.config/soprano/settings.json`.
pub fn config_path() -> PathBuf {
    config_path_from(|key| std::env::var(key).ok(), &paths::home_dir())
}

/// [`config_path`] with the environment and home directory injectable.
pub fn config_path_from(env: impl Fn(&str) -> Option<String>, home: &Path) -> PathBuf {
    let non_empty = |key: &str| env(key).filter(|value| !value.is_empty());
    if let Some(path) = non_empty(PATH_ENVIRONMENT_KEY) {
        return paths::normalize(&paths::expand_tilde_in(&path, home));
    }
    if let Some(xdg) = non_empty("XDG_CONFIG_HOME") {
        return paths::normalize(&paths::expand_tilde_in(&xdg, home)).join("soprano").join("settings.json");
    }
    home.join(".config").join("soprano").join("settings.json")
}

/// The directory holding [`config_path`].
pub fn config_directory() -> PathBuf {
    let path = config_path();
    path.parent().map(Path::to_path_buf).unwrap_or(path)
}

/// The path as a user would type it, with `$HOME` folded back to `~`.
pub fn display_path(path: &Path) -> String {
    paths::abbreviate_home(path)
}

/// `$HOME`-relative form, so paths written by the UI read the way a person would have typed
/// them. A sibling sharing the home directory's name as a prefix stays absolute.
pub fn abbreviating_home(path: &str) -> String {
    paths::abbreviate_home(Path::new(path))
}

pub fn exists(path: &Path) -> bool {
    path.exists()
}

/// Returns the file's text, or `None` when it does not exist yet. A file that exists but
/// cannot be read is an error, never an empty configuration.
pub fn read(path: &Path) -> io::Result<Option<String>> {
    if !exists(path) {
        return Ok(None);
    }
    std::fs::read_to_string(path).map(Some)
}

/// Writes atomically so a watcher never observes a half-written document.
///
/// Writes through a symlink rather than over it: an atomic write is a rename onto the path,
/// which would replace the link with a regular file and quietly detach `settings.json` from
/// the dotfiles repo it points into — the exact setup the README recommends.
pub fn write(text: &str, path: &Path) -> io::Result<()> {
    let target = resolving_symlink(path);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    soprano_platform::state::write_atomically(&target, text.as_bytes())
}

/// The file a symlink points at, following chains, or the path itself.
pub fn resolving_symlink(path: &Path) -> PathBuf {
    let mut resolved = path.to_path_buf();
    // Bounded so a link cycle cannot spin here.
    for _ in 0..8 {
        let Ok(destination) = std::fs::read_link(&resolved) else { break };
        let next = match resolved.parent() {
            Some(parent) if destination.is_relative() => parent.join(destination),
            _ => destination,
        };
        resolved = paths::normalize(&next);
    }
    resolved
}

// MARK: - First run

/// Creates the file if it is missing, seeded from whatever the user had already configured
/// through the UI, and returns its text.
///
/// Seeding matters: `settings.json` moved the source of truth off the app's stored
/// preferences, and silently resetting someone's theme and keybindings on upgrade would be a
/// bug, not a fresh start.
pub fn create_if_missing(
    settings: &AppSettings,
    keybindings: &KeyBindingConfig,
    path: &Path,
) -> io::Result<String> {
    if let Some(existing) = read(path)? {
        return Ok(existing);
    }
    let text = template(settings, keybindings);
    write(&text, path)?;
    Ok(text)
}

/// [`template_for`] on the running OS.
pub fn template(settings: &AppSettings, keybindings: &KeyBindingConfig) -> String {
    template_for(settings, keybindings, KeyPlatform::current())
}

/// A fully commented starter document — the schema *is* the documentation, so the file
/// explains itself without a trip to the README. Shortcuts and OS names in the comments are
/// rendered for `platform`.
pub fn template_for(settings: &AppSettings, keybindings: &KeyBindingConfig, platform: KeyPlatform) -> String {
    let themes = KNOWN_THEME_IDS.iter().map(|id| format!("\"{id}\"")).collect::<Vec<_>>().join(" | ");
    let appearances = AppearancePreference::ALL
        .iter()
        .map(|p| format!("\"{}\"", p.raw_value()))
        .collect::<Vec<_>>()
        .join(" | ");
    let project_directories = json_array_literal(
        &settings.project_directories.iter().map(|p| abbreviating_home(p)).collect::<Vec<_>>(),
        "  ",
    );
    let binding_overrides = seeded_binding_overrides(keybindings);
    let chord =
        |text: &str| KeyChord::parse(text).map(|c| c.display_string_for(platform)).unwrap_or_default();
    let (window_switch, find_window, open_project) = match platform {
        KeyPlatform::Mac => ("⌃1…⌃9".to_owned(), "⌘F".to_owned(), "⇧⌘P".to_owned()),
        KeyPlatform::Other => ("Ctrl+1…Ctrl+9".to_owned(), chord("cmd+f"), chord("cmd+shift+p")),
    };
    let (os_name, notifications_note, cmd_note) = match platform {
        KeyPlatform::Mac => (
            "macOS",
            "    // Whether banners appear at all is macOS's call — see\n    // System Settings ▸ Notifications ▸ Soprano.",
            "",
        ),
        KeyPlatform::Other => (
            "the system",
            "    // Whether banners appear at all is your desktop's call — see\n    // its notification settings.",
            "\n    // On Linux and Windows \"cmd\" is Ctrl+Shift, and \"cmd+shift\" is Ctrl+Shift+Alt.",
        ),
    };
    let title_bar = match platform {
        KeyPlatform::Mac => "macOS title bar",
        KeyPlatform::Other => "system title bar",
    };

    format!(
        r##"// Soprano settings.
//
// This file is the source of truth: the in-app Settings screen reads and
// writes it, and saving here applies immediately — no restart. Comments,
// key order, and formatting survive edits made from the UI.
//
// Every key is optional. Delete one to fall back to the default.
{{
  // Color theme: {themes}
  // "folio" follows the appearance: Folio Paper when light, Folio Ink
  // when dark. The other themes are dark.
  "theme": {theme},

  // App appearance: {appearances}. "system" follows {os_name}.
  "appearance": "{appearance}",

  // Remove the {title_bar} and window controls so panes can use
  // the full window. Off by default.
  "hideWindowBar": {hide_window_bar},

  // Hide the numbered window tabs; the tab row moves up into their
  // place. Switch windows from the sidebar, {window_switch}, or {find_window}. On by default;
  // set false to show the window tabs above the tab row.
  "hideWindowTabs": {hide_window_tabs},

  "statusBar": {{
    // Show how long Soprano has been running ("Up 2:14:07") in the
    // status bar. Off by default.
    "uptime": {uptime}
  }},

  // Restore the previous workspace on launch.
  "restoreLastSession": {restore_last_session},

  // Roots offered by "Open Project…" ({open_project}). "~" is expanded.
  "projectDirectories": {project_directories},

  "notifications": {{
    // Play a sound with each banner. Off by default: a pane that wants
    // you already shows a banner, an unread ring, and a status.
{notifications_note}
    "sound": {sound}
  }},

  "keybindings": {{
    // The tmux-style prefix is Ctrl+<prefixKey>.
    "prefixKey": {prefix_key},
    "prefixTimeoutMs": {prefix_timeout_ms},

    // How much one prefix-resize step moves a split, in percent.
    "resizeTickPercent": {resize_tick_percent},

    // Rebind any action by its id — see Settings ▸ Keyboard Shortcuts
    // for the full list. Modifiers: "cmd", "ctrl", "shift", "prefix".{cmd_note}
    // Set an action to null to turn it off.
    //
    //   "split-vertical": "prefix+v",
    //   "new-browser": "cmd+shift+b",
    //   "zoom-reset": null
    "bindings": {binding_overrides}
  }},

  // Your own agents. Reusing a built-in id ("codex", "claude-code",
  // "opencode", "omp") patches that profile field by field; a new id
  // defines a new agent and needs at least "command". Plain terminal panes are
  // not configured here — they run your login shell.
  //
  //   {{
  //     "id": "aider",
  //     "name": "Aider",
  //     "command": "aider",
  //     "args": ["--no-auto-commits"],
  //     "color": "#8bd5ca",
  //     "launchKey": "cmd+5"
  //   }}
  "agents": [],

  // Prompts an agent runs on a schedule while Soprano is open; the
  // sidebar's Automations page creates and edits them too. Each run
  // opens its agent in the "Automations" session without switching to
  // it, skips the agent's approval prompts (nobody is there to answer),
  // keeps the agent's final reply, and closes its window if you never
  // looked at it.
  //
  //   "weekday-audit": {{
  //     "name": "Weekday repo audit",
  //     "agent": "omp",                  // omp | claude-code | codex | opencode
  //     "folder": "~/git/shop",
  //     "prompt": "Review the repository health and summarize what needs attention.",
  //     "schedule": "0 9 * * 1-5",       // cron: minute hour day month weekday
  //     "enabled": true,
  //     "worktree": false,               // true: each run in a fresh git worktree
  //     "baseBranch": "origin/main",     // worktree base; default origin's default branch
  //     "session": "fresh",              // "reuse": hand the prompt to the last run's open agent
  //     "graceMinutes": 720,             // how late a run missed while asleep may still start
  //     "precheck": "gh pr list --json number -q '.[0].number'",  // skip unless it exits 0
  //     "precheckTimeoutSeconds": 60,
  //     "model": "sonnet"                // the CLI's default when left out
  //   }}
  "automations": {{}}
}}
"##,
        theme = json_string_literal(&settings.theme_id),
        appearance = settings.appearance.raw_value(),
        hide_window_bar = settings.hide_window_bar,
        hide_window_tabs = settings.hide_window_tabs,
        uptime = settings.status_bar_uptime,
        restore_last_session = settings.restore_last_session,
        sound = settings.notification_sound,
        prefix_key = json_string_literal(&keybindings.prefix_key),
        prefix_timeout_ms = keybindings.prefix_timeout_ms,
        resize_tick_percent = keybindings.resize_tick_percent as i64,
    )
}

/// Carries UI-made keybinding changes into the new file so an upgrade does not quietly revert
/// them.
fn seeded_binding_overrides(keybindings: &KeyBindingConfig) -> String {
    let defaults = DefaultKeybindings::config();
    let mut changed: Vec<_> = keybindings
        .bindings
        .iter()
        .filter(|binding| match defaults.bindings.iter().find(|d| d.id == binding.id) {
            Some(fallback) => KeyChord::from_binding(binding) != KeyChord::from_binding(fallback),
            None => true,
        })
        .collect();
    changed.sort_by(|a, b| a.id.cmp(&b.id));
    if changed.is_empty() {
        return "{}".into();
    }
    let entries: Vec<String> = changed
        .iter()
        .map(|binding| {
            format!(
                "      {}: {}",
                json_string_literal(&binding.id),
                json_string_literal(&KeyChord::from_binding(binding).canonical_string())
            )
        })
        .collect();
    format!("{{\n{}\n    }}", entries.join(",\n"))
}

fn json_array_literal(values: &[String], indent: &str) -> String {
    if values.is_empty() {
        return "[]".into();
    }
    let entries: Vec<String> =
        values.iter().map(|v| format!("{indent}  {}", json_string_literal(v))).collect();
    format!("[\n{}\n{indent}]", entries.join(",\n"))
}

fn json_string_literal(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\t' => escaped.push_str("\\t"),
            other => escaped.push(other),
        }
    }
    escaped.push('"');
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_and_paths_inside_it_become_tilde_relative() {
        let home = paths::home_dir().display().to_string();
        assert_eq!(abbreviating_home(&home), "~");
        let git = paths::home_dir().join("git").display().to_string();
        assert_eq!(abbreviating_home(&git), format!("~{}git", std::path::MAIN_SEPARATOR));
    }

    #[test]
    fn a_sibling_directory_sharing_the_home_name_prefix_stays_absolute() {
        let home = paths::home_dir().display().to_string();
        let sibling = format!("{home}2/git");
        assert_eq!(abbreviating_home(&sibling), sibling);
        assert_eq!(abbreviating_home("/tmp/x"), "/tmp/x");
    }

    #[test]
    fn the_file_path_honors_an_explicit_override_then_xdg_then_dot_config() {
        let home = Path::new("/home/me");
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
        };
        assert_eq!(
            config_path_from(
                env(&[("SOPRANO_CONFIG", "~/x/../soprano.json"), ("XDG_CONFIG_HOME", "/xdg")]),
                home
            ),
            PathBuf::from("/home/me/soprano.json")
        );
        assert_eq!(
            config_path_from(env(&[("SOPRANO_CONFIG", ""), ("XDG_CONFIG_HOME", "/xdg")]), home),
            PathBuf::from("/xdg/soprano/settings.json")
        );
        assert_eq!(config_path_from(env(&[]), home), PathBuf::from("/home/me/.config/soprano/settings.json"));
        assert!(config_path().ends_with("settings.json") || std::env::var_os(PATH_ENVIRONMENT_KEY).is_some());
    }

    #[test]
    fn the_display_path_folds_home_back_to_a_tilde() {
        let path = paths::home_dir().join(".config/soprano/settings.json");
        assert_eq!(display_path(&path).replace('\\', "/"), "~/.config/soprano/settings.json");
    }

    #[test]
    fn the_template_documents_the_settings_a_new_user_would_look_for() {
        for platform in [KeyPlatform::Mac, KeyPlatform::Other] {
            let template = template_for(&AppSettings::default(), &DefaultKeybindings::config(), platform);
            assert!(template.contains("\"notifications\""));
            assert!(template.contains("\"sound\": false"));
            assert!(template.contains("\"hideWindowBar\": false"));
            assert!(template.contains("Off by default"));
            let decoded: crate::SopranoConfig = crate::jsonc::decode(&template).expect("template parses");
            assert_eq!(decoded.resolved().issues, vec![]);
        }
    }

    #[test]
    fn writing_creates_missing_directories_and_reads_back() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested/settings.json");
        assert_eq!(read(&path).expect("readable"), None);
        write("{}", &path).expect("writes");
        assert_eq!(read(&path).expect("readable").as_deref(), Some("{}"));
    }
}
