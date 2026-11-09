//! What the General page's controls do to `settings.json`, kept free of the view so it tests
//! without a window: one key per control, the same keys and values as the Swift screen.

use std::ops::RangeInclusive;

use soprano_config::{AppearancePreference, ConfigStore, KeyPlatform, config_file, expand_path};

// MARK: - Keys

pub const THEME_KEY: &[&str] = &["theme"];
pub const APPEARANCE_KEY: &[&str] = &["appearance"];
pub const HIDE_WINDOW_BAR_KEY: &[&str] = &["hideWindowBar"];
pub const HIDE_WINDOW_TABS_KEY: &[&str] = &["hideWindowTabs"];
pub const STATUS_BAR_UPTIME_KEY: &[&str] = &["statusBar", "uptime"];
pub const RESTORE_LAST_SESSION_KEY: &[&str] = &["restoreLastSession"];
pub const NOTIFICATION_SOUND_KEY: &[&str] = &["notifications", "sound"];
pub const PROJECT_DIRECTORIES_KEY: &[&str] = &["projectDirectories"];
pub const PREFIX_KEY_KEY: &[&str] = &["keybindings", "prefixKey"];
pub const PREFIX_TIMEOUT_KEY: &[&str] = &["keybindings", "prefixTimeoutMs"];
pub const RESIZE_STEP_KEY: &[&str] = &["keybindings", "resizeTickPercent"];

/// The on/off switches of the General page: label (also the switch's accessible name), the
/// key it writes, and how to read the current value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Toggle {
    HideWindowBar,
    HideWindowTabs,
    StatusBarUptime,
    RestoreLastSession,
    NotificationSound,
}

impl Toggle {
    pub const ALL: [Toggle; 5] = [
        Toggle::HideWindowBar,
        Toggle::HideWindowTabs,
        Toggle::StatusBarUptime,
        Toggle::RestoreLastSession,
        Toggle::NotificationSound,
    ];

    pub fn key(self) -> &'static [&'static str] {
        match self {
            Self::HideWindowBar => HIDE_WINDOW_BAR_KEY,
            Self::HideWindowTabs => HIDE_WINDOW_TABS_KEY,
            Self::StatusBarUptime => STATUS_BAR_UPTIME_KEY,
            Self::RestoreLastSession => RESTORE_LAST_SESSION_KEY,
            Self::NotificationSound => NOTIFICATION_SOUND_KEY,
        }
    }

    /// The row title.
    pub fn title(self) -> &'static str {
        match self {
            Self::HideWindowBar => "Hide window bar",
            Self::HideWindowTabs => "Hide window tabs",
            Self::StatusBarUptime => "Show uptime in status bar",
            Self::RestoreLastSession => "Restore workspace",
            Self::NotificationSound => "Play a sound",
        }
    }

    /// The switch's accessible name (the Swift `accessibilityLabel`).
    pub fn label(self) -> &'static str {
        match self {
            Self::RestoreLastSession => "Restore last session",
            other => other.title(),
        }
    }

    pub fn description(self, platform: KeyPlatform) -> &'static str {
        match self {
            Self::HideWindowBar => {
                "Hide the title bar and traffic-light controls so panes use the full window."
            }
            Self::HideWindowTabs => match platform {
                KeyPlatform::Mac => {
                    "Hide the numbered window tabs; the tab row moves up. Switch windows from the sidebar, ⌃1…⌃9, or ⌘F."
                }
                KeyPlatform::Other => {
                    "Hide the numbered window tabs; the tab row moves up. Switch windows from the sidebar, Ctrl+1…Ctrl+9, or Ctrl+Shift+F."
                }
            },
            Self::StatusBarUptime => {
                "How long Soprano has been running, as Up h:mm:ss at the end of the status bar."
            }
            Self::RestoreLastSession => "Reopen the workspace from the previous launch when Soprano starts.",
            Self::NotificationSound => "Play the system sound with each notification.",
        }
    }

    pub fn value(self, settings: &soprano_config::AppSettings) -> bool {
        match self {
            Self::HideWindowBar => settings.hide_window_bar,
            Self::HideWindowTabs => settings.hide_window_tabs,
            Self::StatusBarUptime => settings.status_bar_uptime,
            Self::RestoreLastSession => settings.restore_last_session,
            Self::NotificationSound => settings.notification_sound,
        }
    }

    /// Writes the switch's new state.
    pub fn write(self, store: &ConfigStore, is_on: bool) -> bool {
        store.write(is_on, self.key())
    }
}

/// The appearance segments' titles, in `AppearancePreference::ALL` order.
pub fn appearance_title(preference: AppearancePreference) -> &'static str {
    match preference {
        AppearancePreference::System => "System",
        AppearancePreference::Light => "Light",
        AppearancePreference::Dark => "Dark",
    }
}

/// The Appearance row's description; "System follows the macOS appearance" names the OS.
pub fn appearance_description() -> &'static str {
    if cfg!(target_os = "macos") {
        "Light or dark for Folio. System follows the macOS appearance."
    } else if cfg!(windows) {
        "Light or dark for Folio. System follows the Windows appearance."
    } else {
        "Light or dark for Folio. System follows the desktop appearance."
    }
}

pub const THEME_DESCRIPTION: &str =
    "Folio follows the appearance below; the other themes pin their own palette.";

// MARK: - Numbers

/// Reads a number field the way the Swift `NumberFormatter` did (decimal, no minus, grouping
/// tolerated) and clamps it into `range`. `None` means the text is not a number: the field
/// reverts to the value in force.
pub fn committed_integer(text: &str, range: &RangeInclusive<i64>) -> Option<i64> {
    // A millisecond count is not a quantity anyone groups, but a pasted "1'500" or "1,500"
    // should still read as the number it shows rather than silently reverting.
    let digits: String = text
        .trim()
        .chars()
        .filter(|c| !matches!(c, ',' | '\'' | '_' | ' ' | '\u{a0}' | '\u{202f}'))
        .collect();
    if digits.is_empty() || digits.starts_with('-') {
        return None;
    }
    let value: f64 = digits.parse().ok()?;
    if !value.is_finite() {
        return None;
    }
    // `intValue` truncates toward zero.
    let truncated = value.trunc().clamp(i64::MIN as f64, i64::MAX as f64) as i64;
    Some(truncated.clamp(*range.start(), *range.end()))
}

// MARK: - Prefix key

/// The key a prefix recording accepts from one keystroke (GPUI's `key`, the key without Shift,
/// and whether Shift was held), lowercased, or `None` to refuse it.
///
/// The prefix matches Control alone, so a character that needs Shift (⇧1 is "!") could never
/// be typed with it; a shifted letter is still that letter. Invisible and function keys (named
/// keys such as `space`, `f1`, `left`) are refused too.
pub fn recorded_prefix_key(key: &str, shift: bool) -> Option<String> {
    let mut chars = key.chars();
    let (Some(character), None) = (chars.next(), chars.next()) else {
        return None;
    };
    if character.is_whitespace() || character.is_control() || ('\u{F700}'..='\u{F8FF}').contains(&character) {
        return None;
    }
    let lowered: String = character.to_lowercase().collect();
    if lowered.chars().count() != 1 {
        return None;
    }
    if shift && !character.is_alphabetic() {
        return None;
    }
    Some(lowered)
}

/// The prefix control's legend while it waits for a key.
pub fn recording_legend(platform: KeyPlatform) -> &'static str {
    match platform {
        KeyPlatform::Mac => "⌃…",
        KeyPlatform::Other => "Ctrl+…",
    }
}

/// "⌃ + this key starts a prefix chord: ⌃A, then the key. …"
pub fn prefix_key_description(prefix_key: &str, platform: KeyPlatform) -> String {
    let legend = soprano_config::prefix_legend_for(prefix_key, platform);
    let control = match platform {
        KeyPlatform::Mac => "⌃",
        KeyPlatform::Other => "Ctrl",
    };
    format!(
        "{control} + this key starts a prefix chord: {legend}, then the key. Click it and press a key to change it."
    )
}

// MARK: - Project directories

/// The roots exactly as `settings.json` lists them — unexpanded, including any that are not
/// reachable right now. The list shows what the file says, not the resolved result: a root on
/// an unmounted volume is dropped during resolution, and rendering the resolved list would make
/// "Remove" renumber onto the wrong entry and a later write delete the missing root for good.
pub fn configured_project_directories(store: &ConfigStore) -> Vec<String> {
    store.config().project_directories.unwrap_or_default()
}

/// Whether a listed root is a directory right now ("Not found" otherwise).
pub fn is_reachable_directory(raw: &str) -> bool {
    let path = expand_path(raw);
    !path.is_empty() && std::path::Path::new(&path).is_dir()
}

/// What adding a folder did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AddDirectoryOutcome {
    /// Nothing typed: nothing happens.
    Empty,
    /// Not a directory: the field keeps its text and the app beeps.
    NotADirectory,
    /// Listed already: the field clears, the file is left alone.
    AlreadyListed,
    /// Written (home-relative); the field clears.
    Added,
    /// The file could not be written; the store reports the issue.
    WriteFailed,
}

impl AddDirectoryOutcome {
    /// Whether the input field empties afterwards.
    pub fn clears_input(self) -> bool {
        matches!(self, Self::AlreadyListed | Self::Added)
    }
}

/// Adds `raw` (typed or chosen) to `projectDirectories`, written home-relative: this list is
/// meant to be read and edited by hand, and `/Users/you/git` reads worse than `~/git`.
pub fn add_project_directory(store: &ConfigStore, raw: &str) -> AddDirectoryOutcome {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return AddDirectoryOutcome::Empty;
    }
    let path = expand_path(trimmed);
    if !std::path::Path::new(&path).is_dir() {
        return AddDirectoryOutcome::NotADirectory;
    }
    let mut directories = configured_project_directories(store);
    if directories.iter().any(|listed| expand_path(listed) == path) {
        return AddDirectoryOutcome::AlreadyListed;
    }
    directories.push(config_file::abbreviating_home(&path));
    if store.write(directories, PROJECT_DIRECTORIES_KEY) {
        AddDirectoryOutcome::Added
    } else {
        AddDirectoryOutcome::WriteFailed
    }
}

/// Removes the `index`th listed root (by the file's order).
pub fn remove_project_directory(store: &ConfigStore, index: usize) -> bool {
    let mut directories = configured_project_directories(store);
    if index >= directories.len() {
        return false;
    }
    directories.remove(index);
    store.write(directories, PROJECT_DIRECTORIES_KEY)
}

pub const PROJECT_DIRECTORIES_NOTE: &str = "Directories available to project-aware features.";
pub const NO_PROJECT_DIRECTORIES: &str = "No project directories";
pub const NO_PROJECT_DIRECTORIES_HINT: &str =
    "Add a folder below, or list them under \"projectDirectories\" in settings.json.";

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::{AppSettings, DefaultKeybindings, Limits};

    fn store() -> (ConfigStore, tempfile::TempDir) {
        let directory = tempfile::tempdir().expect("temp dir");
        let store = ConfigStore::with_catalog(
            directory.path().join("settings.json"),
            std::sync::Arc::new(soprano_types::AgentCatalog::new(soprano_types::DefaultAgents::all())),
        );
        store.start(false, &AppSettings::default(), &DefaultKeybindings::config());
        (store, directory)
    }

    fn text(store: &ConfigStore) -> String {
        std::fs::read_to_string(store.file_path()).unwrap_or_default()
    }

    #[test]
    fn every_switch_writes_its_own_key_in_both_directions() {
        let (store, _dir) = store();
        for toggle in Toggle::ALL {
            let before = toggle.value(&store.settings());
            assert!(toggle.write(&store, !before));
            assert_eq!(toggle.value(&store.settings()), !before, "{toggle:?}");
            assert!(toggle.write(&store, before));
            assert_eq!(toggle.value(&store.settings()), before, "{toggle:?}");
        }
        assert!(text(&store).contains("\"uptime\": false"));
        assert!(text(&store).contains("\"sound\": false"));
    }

    #[test]
    fn toggling_restore_last_session_rewrites_its_key_in_the_file() {
        let (store, _dir) = store();
        assert!(Toggle::RestoreLastSession.write(&store, false));
        assert!(!store.settings().restore_last_session);
        assert!(text(&store).contains("\"restoreLastSession\": false"));
    }

    #[test]
    fn toggling_hide_window_bar_rewrites_its_key_in_the_file() {
        let (store, _dir) = store();
        assert!(Toggle::HideWindowBar.write(&store, true));
        assert!(store.settings().hide_window_bar);
        assert!(text(&store).contains("\"hideWindowBar\": true"));
    }

    #[test]
    fn the_switches_keep_their_swift_accessible_names() {
        assert_eq!(Toggle::RestoreLastSession.label(), "Restore last session");
        assert_eq!(Toggle::HideWindowBar.label(), "Hide window bar");
        assert_eq!(Toggle::StatusBarUptime.label(), "Show uptime in status bar");
        assert_eq!(Toggle::NotificationSound.label(), "Play a sound");
    }

    #[test]
    fn number_fields_clamp_into_their_limits_and_refuse_text() {
        let timeout = Limits::PREFIX_TIMEOUT_MS;
        assert_eq!(committed_integer("99999", &timeout), Some(5000));
        assert_eq!(committed_integer("10", &timeout), Some(300));
        assert_eq!(committed_integer(" 1500 ", &timeout), Some(1500));
        assert_eq!(committed_integer("1'500", &timeout), Some(1500));
        assert_eq!(committed_integer("1,500", &timeout), Some(1500));
        assert_eq!(committed_integer("abc", &timeout), None);
        assert_eq!(committed_integer("", &timeout), None);
        assert_eq!(committed_integer("-5", &timeout), None);
        assert_eq!(committed_integer("12.9", &Limits::RESIZE_TICK_PERCENT), Some(12));
    }

    #[test]
    fn editing_the_prefix_timeout_clamps_and_writes_the_nested_key() {
        let (store, _dir) = store();
        let value = committed_integer("99999", &Limits::PREFIX_TIMEOUT_MS).expect("a number");
        assert!(store.write(value, PREFIX_TIMEOUT_KEY));
        assert_eq!(store.keybindings().prefix_timeout_ms, 5000);
        assert!(text(&store).contains("\"prefixTimeoutMs\": 5000"));
    }

    #[test]
    fn a_recorded_prefix_key_is_one_lowercased_character() {
        assert_eq!(recorded_prefix_key("b", false).as_deref(), Some("b"));
        // A shifted letter is still that letter: ⌃B types it without Shift.
        assert_eq!(recorded_prefix_key("B", true).as_deref(), Some("b"));
        assert_eq!(recorded_prefix_key("b", true).as_deref(), Some("b"));
        assert_eq!(recorded_prefix_key("1", false).as_deref(), Some("1"));
    }

    #[test]
    fn a_prefix_key_that_needs_shift_is_refused_because_control_alone_could_never_type_it() {
        assert_eq!(recorded_prefix_key("!", true), None);
        assert_eq!(recorded_prefix_key("1", true), None);
    }

    #[test]
    fn invisible_and_named_keys_cannot_become_the_prefix() {
        for key in ["space", "escape", "enter", "tab", "f1", "left", " ", "\t", "\u{F700}"] {
            assert_eq!(recorded_prefix_key(key, false), None, "{key:?}");
        }
    }

    #[test]
    fn recording_a_prefix_key_writes_it_and_shows_it_as_a_control_chord() {
        let (store, _dir) = store();
        let key = recorded_prefix_key("b", false).expect("accepted");
        assert!(store.write(key, PREFIX_KEY_KEY));
        assert_eq!(store.keybindings().prefix_key, "b");
        assert!(text(&store).contains("\"prefixKey\": \"b\""));
        assert_eq!(soprano_config::prefix_legend_for("b", KeyPlatform::Mac), "⌃B");
        assert_eq!(recording_legend(KeyPlatform::Mac), "⌃…");
        assert_eq!(recording_legend(KeyPlatform::Other), "Ctrl+…");
    }

    #[test]
    fn the_prefix_description_names_the_current_chord() {
        assert_eq!(
            prefix_key_description("a", KeyPlatform::Mac),
            "⌃ + this key starts a prefix chord: ⌃A, then the key. Click it and press a key to change it."
        );
        assert!(prefix_key_description("b", KeyPlatform::Other).starts_with("Ctrl + this key"));
    }

    #[test]
    fn adding_a_project_directory_writes_it_home_relative_and_resolves_it_back() {
        let (store, _dir) = store();
        let home = soprano_platform::paths::home_dir();
        assert_eq!(add_project_directory(&store, &home.display().to_string()), AddDirectoryOutcome::Added);
        assert!(text(&store).contains("\"~\""));
        assert_eq!(store.settings().project_directories, vec![expand_path(&home.display().to_string())]);
    }

    #[test]
    fn adding_a_directory_twice_or_a_missing_one_leaves_the_file_alone() {
        let (store, dir) = store();
        let folder = dir.path().join("project");
        std::fs::create_dir(&folder).expect("folder");
        let path = folder.display().to_string();
        assert_eq!(add_project_directory(&store, "   "), AddDirectoryOutcome::Empty);
        assert_eq!(add_project_directory(&store, &path), AddDirectoryOutcome::Added);
        let written = text(&store);
        assert_eq!(add_project_directory(&store, &format!("{path}/")), AddDirectoryOutcome::AlreadyListed);
        assert_eq!(
            add_project_directory(&store, &dir.path().join("missing").display().to_string()),
            AddDirectoryOutcome::NotADirectory
        );
        assert_eq!(text(&store), written);
        assert!(AddDirectoryOutcome::AlreadyListed.clears_input());
        assert!(!AddDirectoryOutcome::NotADirectory.clears_input());
    }

    #[test]
    fn removing_a_directory_goes_by_the_files_order_even_when_a_root_is_unreachable() {
        let (store, dir) = store();
        let folder = dir.path().join("project");
        std::fs::create_dir(&folder).expect("folder");
        let missing = dir.path().join("unmounted").display().to_string();
        let path = folder.display().to_string();
        assert!(store.write(vec![missing.clone(), path.clone()], PROJECT_DIRECTORIES_KEY));
        // Resolution drops the missing root; the page lists the file.
        assert_eq!(store.settings().project_directories.len(), 1);
        assert_eq!(configured_project_directories(&store), vec![missing.clone(), path.clone()]);
        assert!(!is_reachable_directory(&missing));
        assert!(is_reachable_directory(&path));

        assert!(remove_project_directory(&store, 1));
        assert_eq!(configured_project_directories(&store), vec![missing]);
        assert!(store.settings().project_directories.is_empty());
        assert!(!remove_project_directory(&store, 5));
    }
}
