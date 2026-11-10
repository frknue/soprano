//! Terminal settings, and the parts of the user's Ghostty config a libghostty-vt renderer
//! honors (`Terminal/GhosttyAppManager.swift` loaded the whole config through libghostty).
//!
//! Read: `font-family`, `font-size`, `cursor-style`, `cursor-style-blink`, `scrollback-limit`,
//! `mouse-hide-while-typing`, `copy-on-select`, `window-padding-x`, `window-padding-y`, plus
//! the clipboard policy keys the Swift app's confirmations followed (`clipboard-read`,
//! `clipboard-write`, `clipboard-paste-protection`, `clipboard-paste-bracketed-safe`,
//! `selection-clear-on-copy`) and `macos-option-as-alt`, which changes key encoding.
//! Colors are ignored: Soprano's theme always overrode them. `config-file` includes are
//! followed. Everything else is ignored.

use crate::keybinds::TerminalKeybinds;
use crate::theme::TerminalTheme;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// The cursor's shape when the program doesn't choose one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum CursorStyle {
    #[default]
    Block,
    Bar,
    Underline,
    BlockHollow,
}

/// Where a selection made with the mouse is copied (Ghostty's `copy-on-select`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum CopyOnSelect {
    False,
    /// The selection clipboard (the primary selection on Linux, a private one elsewhere),
    /// which a middle click pastes.
    #[default]
    True,
    /// The selection clipboard and the system clipboard.
    Clipboard,
}

/// What a program may do with the clipboard (`clipboard-read`, `clipboard-write`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipboardAccess {
    Allow,
    Deny,
    Ask,
}

/// Whether macOS Option acts as Alt (`macos-option-as-alt`). GPUI doesn't say which Option
/// key was held, so `Left` and `Right` apply to either.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum OptionAsAlt {
    #[default]
    False,
    True,
    Left,
    Right,
}

impl OptionAsAlt {
    pub fn applies(self) -> bool {
        self != OptionAsAlt::False
    }
}

/// Padding around the grid, in logical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Padding {
    pub left: f32,
    pub right: f32,
    pub top: f32,
    pub bottom: f32,
}

/// Everything about how one terminal looks and behaves that isn't its program.
#[derive(Clone, Debug, PartialEq)]
pub struct TerminalSettings {
    pub font_family: String,
    pub font_size: f32,
    pub theme: TerminalTheme,
    pub padding: Padding,
    pub cursor_style: CursorStyle,
    /// `None`: the program decides (DECSCUSR); Ghostty's default.
    pub cursor_blink: Option<bool>,
    /// Scrollback size in bytes (Ghostty's `scrollback-limit`).
    pub scrollback_limit: usize,
    pub mouse_hide_while_typing: bool,
    pub copy_on_select: CopyOnSelect,
    pub clipboard_read: ClipboardAccess,
    pub clipboard_write: ClipboardAccess,
    pub clipboard_paste_protection: bool,
    pub clipboard_paste_bracketed_safe: bool,
    /// Copying a selection clears it (Soprano's `SopranoCopyMode.conf` turns this on).
    pub selection_clear_on_copy: bool,
    pub option_as_alt: OptionAsAlt,
    /// Ghostty's macOS defaults plus the user's `keybind` lines that write to the program.
    pub keybinds: TerminalKeybinds,
}

impl TerminalSettings {
    pub const DEFAULT_FONT_FAMILY: &'static str = "JetBrains Mono";
    pub const DEFAULT_FONT_SIZE: f32 = 13.0;
    pub const DEFAULT_SCROLLBACK_LIMIT: usize = 10_000_000;

    /// The defaults with `theme`, overridden by the user's Ghostty config files.
    pub fn from_user_config(theme: TerminalTheme) -> Self {
        let mut settings = Self { theme, ..Self::default() };
        settings.apply_ghostty_config(&GhosttyConfig::load_default_files());
        settings
    }

    /// Applies every key the config sets.
    pub fn apply_ghostty_config(&mut self, config: &GhosttyConfig) {
        let defaults = Self::default();
        if let Some(family) = &config.font_family {
            self.font_family = family.clone().unwrap_or(defaults.font_family);
        }
        if let Some(size) = config.font_size {
            self.font_size = size.unwrap_or(defaults.font_size);
        }
        if let Some(style) = config.cursor_style {
            self.cursor_style = style.unwrap_or_default();
        }
        if let Some(blink) = config.cursor_style_blink {
            self.cursor_blink = blink;
        }
        if let Some(limit) = config.scrollback_limit {
            self.scrollback_limit = limit.unwrap_or(defaults.scrollback_limit);
        }
        if let Some(hide) = config.mouse_hide_while_typing {
            self.mouse_hide_while_typing = hide.unwrap_or(defaults.mouse_hide_while_typing);
        }
        if let Some(copy) = config.copy_on_select {
            self.copy_on_select = copy.unwrap_or_default();
        }
        if let Some(x) = config.window_padding_x {
            let (left, right) = x.unwrap_or((defaults.padding.left, defaults.padding.right));
            (self.padding.left, self.padding.right) = (left, right);
        }
        if let Some(y) = config.window_padding_y {
            let (top, bottom) = y.unwrap_or((defaults.padding.top, defaults.padding.bottom));
            (self.padding.top, self.padding.bottom) = (top, bottom);
        }
        if let Some(read) = config.clipboard_read {
            self.clipboard_read = read.unwrap_or(defaults.clipboard_read);
        }
        if let Some(write) = config.clipboard_write {
            self.clipboard_write = write.unwrap_or(defaults.clipboard_write);
        }
        if let Some(v) = config.clipboard_paste_protection {
            self.clipboard_paste_protection = v.unwrap_or(defaults.clipboard_paste_protection);
        }
        if let Some(v) = config.clipboard_paste_bracketed_safe {
            self.clipboard_paste_bracketed_safe = v.unwrap_or(defaults.clipboard_paste_bracketed_safe);
        }
        if let Some(v) = config.macos_option_as_alt {
            self.option_as_alt = v.unwrap_or_default();
        }
        if !config.keybinds.is_empty() {
            self.keybinds = TerminalKeybinds::from_config_values(
                config.keybinds.iter().map(String::as_str),
                cfg!(target_os = "macos"),
            );
        }
    }
}

impl Default for TerminalSettings {
    fn default() -> Self {
        Self {
            font_family: Self::DEFAULT_FONT_FAMILY.to_owned(),
            font_size: Self::DEFAULT_FONT_SIZE,
            theme: TerminalTheme::default(),
            padding: Padding { left: 14.0, right: 14.0, top: 12.0, bottom: 12.0 },
            cursor_style: CursorStyle::Block,
            cursor_blink: None,
            scrollback_limit: Self::DEFAULT_SCROLLBACK_LIMIT,
            mouse_hide_while_typing: false,
            copy_on_select: CopyOnSelect::True,
            clipboard_read: ClipboardAccess::Ask,
            clipboard_write: ClipboardAccess::Allow,
            clipboard_paste_protection: true,
            clipboard_paste_bracketed_safe: true,
            selection_clear_on_copy: true,
            option_as_alt: OptionAsAlt::False,
            keybinds: TerminalKeybinds::default(),
        }
    }
}

/// The keys of a Ghostty config this crate reads. The outer `Option` is "the config set
/// it"; an inner `None` is an empty value, which resets the key to its default.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GhosttyConfig {
    pub font_family: Option<Option<String>>,
    pub font_size: Option<Option<f32>>,
    pub cursor_style: Option<Option<CursorStyle>>,
    pub cursor_style_blink: Option<Option<bool>>,
    pub scrollback_limit: Option<Option<usize>>,
    pub mouse_hide_while_typing: Option<Option<bool>>,
    pub copy_on_select: Option<Option<CopyOnSelect>>,
    pub window_padding_x: Option<Option<(f32, f32)>>,
    pub window_padding_y: Option<Option<(f32, f32)>>,
    pub clipboard_read: Option<Option<ClipboardAccess>>,
    pub clipboard_write: Option<Option<ClipboardAccess>>,
    pub clipboard_paste_protection: Option<Option<bool>>,
    pub clipboard_paste_bracketed_safe: Option<Option<bool>>,
    pub macos_option_as_alt: Option<Option<OptionAsAlt>>,
    /// `shell-integration`: the last value set; an empty value resets it.
    pub shell_integration: Option<Option<String>>,
    /// `shell-integration-features`: every value in order (Ghostty applies them one after
    /// another, so `no-cursor` then `cursor` turns the cursor back on). An empty value is
    /// kept as `""`, a reset.
    pub shell_integration_features: Vec<String>,
    /// Every `keybind` value in order (`""` and `clear` included); see [`TerminalKeybinds`].
    pub keybinds: Vec<String>,
}

impl GhosttyConfig {
    /// The files Ghostty loads by default, in order (later ones win): the XDG config
    /// (`$XDG_CONFIG_HOME/ghostty/`, else `~/.config/ghostty/`), then on macOS
    /// `~/Library/Application Support/com.mitchellh.ghostty/`; in each, `config` then
    /// `config.ghostty`.
    pub fn default_files() -> Vec<PathBuf> {
        let home = soprano_platform::paths::home_dir();
        let xdg = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home.join(".config"));
        let mut dirs = vec![xdg.join("ghostty")];
        if cfg!(target_os = "macos") {
            dirs.push(home.join("Library/Application Support/com.mitchellh.ghostty"));
        }
        dirs.iter().flat_map(|d| [d.join("config"), d.join("config.ghostty")]).collect()
    }

    pub fn load_default_files() -> Self {
        let mut config = Self::default();
        let mut seen = HashSet::new();
        for file in Self::default_files() {
            config.load_file(&file, &mut seen);
        }
        config
    }

    /// Loads one file (missing files are skipped), then the files it includes.
    pub fn load_file(&mut self, path: &Path, seen: &mut HashSet<PathBuf>) {
        let key = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        if !seen.insert(key) {
            return;
        }
        let Ok(text) = std::fs::read_to_string(path) else { return };
        let base = path.parent().map(Path::to_path_buf).unwrap_or_default();
        for include in self.parse(&text) {
            let (optional, file) = match include.strip_prefix('?') {
                Some(rest) => (true, rest),
                None => (false, include.as_str()),
            };
            let file = soprano_platform::paths::expand_tilde(file);
            let file = if Path::new(&file).is_absolute() { file } else { base.join(file) };
            if !optional && !file.exists() {
                tracing::warn!("ghostty config: included file {} not found", file.display());
            }
            self.load_file(&file, seen);
        }
    }

    /// Applies `text`'s lines; returns the `config-file` includes it names, in order.
    pub fn parse(&mut self, text: &str) -> Vec<String> {
        let mut includes = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else { continue };
            let key = key.trim();
            let value = unquote(value.trim());
            let empty = value.is_empty();
            match key {
                "config-file" if !empty => includes.push(value.to_owned()),
                "shell-integration" => {
                    self.shell_integration = Some((!empty).then(|| value.to_owned()));
                }
                "shell-integration-features" => self.shell_integration_features.push(value.to_owned()),
                "keybind" => self.keybinds.push(value.to_owned()),
                "font-family" => {
                    // Repeated keys add fallbacks; the first one is the font.
                    if empty {
                        self.font_family = Some(None);
                    } else if !matches!(self.font_family, Some(Some(_))) {
                        self.font_family = Some(Some(value.to_owned()));
                    }
                }
                "font-size" => set(&mut self.font_size, empty, value.parse().ok().filter(|s: &f32| *s > 0.0)),
                "cursor-style" => set(&mut self.cursor_style, empty, parse_cursor_style(value)),
                "cursor-style-blink" => {
                    self.cursor_style_blink = if empty { Some(None) } else { parse_bool(value).map(Some) }
                        .or(self.cursor_style_blink)
                }
                "scrollback-limit" => set(&mut self.scrollback_limit, empty, value.parse().ok()),
                "mouse-hide-while-typing" => set(&mut self.mouse_hide_while_typing, empty, parse_bool(value)),
                "copy-on-select" => set(
                    &mut self.copy_on_select,
                    empty,
                    match value {
                        "clipboard" => Some(CopyOnSelect::Clipboard),
                        _ => parse_bool(value)
                            .map(|b| if b { CopyOnSelect::True } else { CopyOnSelect::False }),
                    },
                ),
                "window-padding-x" => set(&mut self.window_padding_x, empty, parse_pair(value)),
                "window-padding-y" => set(&mut self.window_padding_y, empty, parse_pair(value)),
                "clipboard-read" => set(&mut self.clipboard_read, empty, parse_access(value)),
                "clipboard-write" => set(&mut self.clipboard_write, empty, parse_access(value)),
                "clipboard-paste-protection" => {
                    set(&mut self.clipboard_paste_protection, empty, parse_bool(value))
                }
                "clipboard-paste-bracketed-safe" => {
                    set(&mut self.clipboard_paste_bracketed_safe, empty, parse_bool(value))
                }
                "macos-option-as-alt" => set(
                    &mut self.macos_option_as_alt,
                    empty,
                    match value {
                        "left" => Some(OptionAsAlt::Left),
                        "right" => Some(OptionAsAlt::Right),
                        _ => {
                            parse_bool(value).map(|b| if b { OptionAsAlt::True } else { OptionAsAlt::False })
                        }
                    },
                ),
                _ => {}
            }
        }
        includes
    }
}

/// An empty value resets; an unparseable one leaves the key as it was (Ghostty logs it).
fn set<T>(slot: &mut Option<Option<T>>, empty: bool, parsed: Option<T>) {
    if empty {
        *slot = Some(None);
    } else if let Some(value) = parsed {
        *slot = Some(Some(value));
    }
}

fn unquote(value: &str) -> &str {
    value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value)
}

fn parse_bool(value: &str) -> Option<bool> {
    match value {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

fn parse_access(value: &str) -> Option<ClipboardAccess> {
    match value {
        "allow" => Some(ClipboardAccess::Allow),
        "deny" => Some(ClipboardAccess::Deny),
        "ask" => Some(ClipboardAccess::Ask),
        _ => None,
    }
}

fn parse_cursor_style(value: &str) -> Option<CursorStyle> {
    match value {
        "block" => Some(CursorStyle::Block),
        "bar" => Some(CursorStyle::Bar),
        "underline" => Some(CursorStyle::Underline),
        "block_hollow" => Some(CursorStyle::BlockHollow),
        _ => None,
    }
}

/// `N` (both sides) or `N,M`.
fn parse_pair(value: &str) -> Option<(f32, f32)> {
    let mut parts = value.split(',').map(|p| p.trim().parse::<f32>().ok().filter(|v| *v >= 0.0));
    let first = parts.next()??;
    let second = match parts.next() {
        Some(v) => v?,
        None => first,
    };
    parts.next().is_none().then_some((first, second))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_supported_keys_override_the_defaults_and_others_are_ignored() {
        let mut config = GhosttyConfig::default();
        config.parse(
            "# comment\n\
             font-family = \"Berkeley Mono\"\n\
             font-family = Symbols Nerd Font\n\
             font-size = 15.5\n\
             cursor-style = bar\n\
             cursor-style-blink = false\n\
             scrollback-limit = 2000000\n\
             mouse-hide-while-typing = true\n\
             copy-on-select = clipboard\n\
             window-padding-x = 4,6\n\
             window-padding-y = 8\n\
             clipboard-read = allow\n\
             clipboard-write = ask\n\
             macos-option-as-alt = left\n\
             background = 000000\n\
             theme = nord\n",
        );
        let mut s = TerminalSettings::default();
        s.apply_ghostty_config(&config);
        assert_eq!(s.font_family, "Berkeley Mono");
        assert_eq!(s.font_size, 15.5);
        assert_eq!(s.cursor_style, CursorStyle::Bar);
        assert_eq!(s.cursor_blink, Some(false));
        assert_eq!(s.scrollback_limit, 2_000_000);
        assert!(s.mouse_hide_while_typing);
        assert_eq!(s.copy_on_select, CopyOnSelect::Clipboard);
        assert_eq!(s.padding, Padding { left: 4.0, right: 6.0, top: 8.0, bottom: 8.0 });
        assert_eq!(s.clipboard_read, ClipboardAccess::Allow);
        assert_eq!(s.clipboard_write, ClipboardAccess::Ask);
        assert_eq!(s.option_as_alt, OptionAsAlt::Left);
        assert_eq!(s.theme, TerminalTheme::default());
    }

    #[test]
    fn an_empty_value_resets_a_key_and_a_bad_value_is_ignored() {
        let mut config = GhosttyConfig::default();
        config.parse("font-size = 20\nfont-size =\ncursor-style = wiggly\nfont-family = A\nfont-family =\n");
        let mut s = TerminalSettings::default();
        s.apply_ghostty_config(&config);
        assert_eq!(s.font_size, TerminalSettings::DEFAULT_FONT_SIZE);
        assert_eq!(s.cursor_style, CursorStyle::Block);
        assert_eq!(s.font_family, TerminalSettings::DEFAULT_FONT_FAMILY);
    }

    #[test]
    fn the_defaults_match_soprano_and_ghostty() {
        let s = TerminalSettings::default();
        assert_eq!((s.font_family.as_str(), s.font_size), ("JetBrains Mono", 13.0));
        assert_eq!(s.padding, Padding { left: 14.0, right: 14.0, top: 12.0, bottom: 12.0 });
        assert_eq!(s.clipboard_read, ClipboardAccess::Ask);
        assert_eq!(s.clipboard_write, ClipboardAccess::Allow);
        assert!(s.clipboard_paste_protection && s.clipboard_paste_bracketed_safe);
        assert!(s.selection_clear_on_copy);
        assert_eq!(s.cursor_blink, None);
    }

    #[test]
    fn shell_integration_keys_keep_the_last_mode_and_every_feature_list() {
        let mut config = GhosttyConfig::default();
        config.parse(
            "shell-integration = zsh\nshell-integration-features = no-cursor\nshell-integration-features = cursor,no-title\n",
        );
        assert_eq!(config.shell_integration, Some(Some("zsh".into())));
        assert_eq!(config.shell_integration_features, ["no-cursor", "cursor,no-title"]);
        config.parse("shell-integration =\nshell-integration-features =\n");
        assert_eq!(config.shell_integration, Some(None));
        assert_eq!(config.shell_integration_features.last().map(String::as_str), Some(""));
    }

    #[test]
    fn keybind_lines_reach_the_terminal_keybinds_in_order() {
        let mut config = GhosttyConfig::default();
        config.parse("keybind = shift+enter=text:\\x1b\\r\nkeybind = clear\nkeybind = ctrl+j=text:\\n\n");
        assert_eq!(config.keybinds, ["shift+enter=text:\\x1b\\r", "clear", "ctrl+j=text:\\n"]);
        let mut s = TerminalSettings::default();
        s.apply_ghostty_config(&config);
        assert_eq!(
            s.keybinds,
            TerminalKeybinds::from_config_values(
                config.keybinds.iter().map(String::as_str),
                cfg!(target_os = "macos")
            )
        );
    }

    #[test]
    fn included_files_load_after_the_including_file_and_cycles_stop() {
        let dir = std::env::temp_dir().join(format!("soprano-term-ghostty-config-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config"), "config-file = extra\nconfig-file = ?missing\nfont-size = 11\n")
            .unwrap();
        std::fs::write(dir.join("extra"), "font-size = 17\nconfig-file = config\n").unwrap();
        let mut config = GhosttyConfig::default();
        config.load_file(&dir.join("config"), &mut HashSet::new());
        assert_eq!(config.font_size, Some(Some(17.0)));
        std::fs::remove_dir_all(&dir).ok();
    }
}
