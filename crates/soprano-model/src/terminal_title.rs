//! What the sidebar calls a terminal or agent tab, where a row has room for a word or two
//! (`Models/TerminalTitle.swift`).
//!
//! A shell's own title is its prompt location — zsh's `user@host:~/git/shop` or oh-my-zsh's
//! `…/git/shop` — which only says where it is, so it reads as that folder; a command's title
//! (`npm run dev`, `vim index.ts`) stays. An agent's title loses the brand and state glyphs its
//! CLI puts in front (omp's `π > `, Claude Code's `✳ `), which the row's status mark already
//! shows, and falls back to the agent's name. Nerd-font icons go too: they live in the Private
//! Use Areas, which the system fonts cannot draw.

use unicode_general_category::{GeneralCategory, get_general_category};

/// The display title for a tab titled `title`, using the user's home folder.
pub fn display(title: &str, working_directory: Option<&str>, agent_name: Option<&str>) -> String {
    let home = soprano_platform::paths::home_dir();
    display_in(title, working_directory, agent_name, &home.to_string_lossy())
}

/// [`display`] with an explicit home folder.
pub fn display_in(
    title: &str,
    working_directory: Option<&str>,
    agent_name: Option<&str>,
    home: &str,
) -> String {
    let label = without_decorations(title);
    if !is_generic(&label, agent_name) {
        return label;
    }
    if let Some(agent_name) = agent_name {
        return agent_name.to_owned();
    }
    if let Some(directory) = working_directory {
        return folder_name_in(directory, home);
    }
    if let Some(location) = shell_location(&label).filter(|location| !location.is_empty()) {
        return folder_name_in(&location, "~");
    }
    if label.is_empty() { "Terminal".to_owned() } else { label }
}

/// `soprano` for `~/git/private/soprano`, `~` for the home folder itself.
pub fn folder_name(path: &str) -> String {
    let home = soprano_platform::paths::home_dir();
    folder_name_in(path, &home.to_string_lossy())
}

/// [`folder_name`] with an explicit home folder.
pub fn folder_name_in(path: &str, home: &str) -> String {
    let trimmed = match path.chars().last() {
        Some(last) if std::path::is_separator(last) && path.chars().count() > 1 => {
            &path[..path.len() - last.len_utf8()]
        }
        _ => path,
    };
    if trimmed == home || trimmed == "~" {
        return "~".to_owned();
    }
    crate::file_url::last_segment(trimmed).unwrap_or(trimmed).to_owned()
}

/// The title without private-use icons and without the leading brand and state glyphs agent
/// CLIs add.
pub fn without_decorations(title: &str) -> String {
    let filtered: String = title.chars().filter(|c| !is_private_use(*c)).collect();
    let mut text = without_omp_brand(filtered.trim()).to_owned();
    // Claude Code spins through `·✢✳✶✻✽` in front of its task; other CLIs use braille spinners
    // or an emoji. A glyph's trailing variation selector or joiner goes with it.
    while let Some(first) = text.chars().next() {
        if !is_leading_decoration(first) {
            break;
        }
        text = text[first.len_utf8()..].trim_matches(is_horizontal_whitespace).to_owned();
    }
    text
}

/// omp titles its terminal `π > label` (your turn), `π ⠋ label` (working, one spinner column),
/// `π ! label` (blocked on you), or `π: label`.
fn without_omp_brand(text: &str) -> &str {
    let Some(mut rest) = text.strip_prefix('π') else { return text };
    if let Some(after_colon) = rest.strip_prefix(':') {
        rest = after_colon;
    } else if rest.starts_with(char::is_whitespace) {
        rest = rest.trim_start_matches(char::is_whitespace);
        let mut chars = rest.chars();
        if let Some(separator) = chars.next()
            && !separator.is_alphabetic()
            && !separator.is_numeric()
            && chars.next().is_none_or(char::is_whitespace)
        {
            rest = &rest[separator.len_utf8()..];
        }
    } else if !rest.is_empty() {
        // A word that starts with π, not omp's brand.
        return text;
    }
    rest.trim_matches(is_horizontal_whitespace)
}

/// Whether the title says nothing the row does not already: empty, the shell's location, the
/// agent's bare name, or Soprano's own `Agent: folder` placeholder from before the agent titled
/// itself — the folder it started in, which need not be the one it is in now.
fn is_generic(label: &str, agent_name: Option<&str>) -> bool {
    if label.is_empty() || label == "Terminal" || shell_location(label).is_some() {
        return true;
    }
    let Some(agent_name) = agent_name else { return false };
    if label.to_lowercase() == agent_name.to_lowercase() {
        return true;
    }
    let prefix = format!("{agent_name}: ");
    let Some(folder) = label.strip_prefix(&prefix) else { return false };
    !folder.is_empty() && !folder.contains(char::is_whitespace)
}

/// The path a prompt title shows — `~/git/shop` from `user@host:~/git/shop`, `…/git/shop` as
/// is, empty for a bare `user@host` — or `None` when the title is not a location.
pub fn shell_location(label: &str) -> Option<String> {
    if let Some(location) = prompt_location(label) {
        return Some(location);
    }
    ["~", "/", "…", ".."].iter().any(|prefix| label.starts_with(prefix)).then(|| label.to_owned())
}

/// Matches `[A-Za-z0-9._-]+@[A-Za-z0-9._-]+(?::\s*(.*))?` against the whole label.
fn prompt_location(label: &str) -> Option<String> {
    fn is_name(c: char) -> bool {
        c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')
    }
    let (user, rest) = label.split_once('@')?;
    if user.is_empty() || !user.chars().all(is_name) {
        return None;
    }
    let host_end = rest.find(|c: char| !is_name(c)).unwrap_or(rest.len());
    if host_end == 0 {
        return None;
    }
    let after_host = &rest[host_end..];
    if after_host.is_empty() {
        return Some(String::new());
    }
    let path = after_host.strip_prefix(':')?.trim_start_matches(char::is_whitespace);
    // `.` does not match line breaks.
    (!path.contains(['\n', '\r'])).then(|| path.to_owned())
}

fn is_horizontal_whitespace(c: char) -> bool {
    c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn is_private_use(c: char) -> bool {
    matches!(c as u32, 0xE000..=0xF8FF | 0xF0000..=0x10FFFF)
}

fn is_leading_decoration(c: char) -> bool {
    match get_general_category(c) {
        GeneralCategory::OtherSymbol
        | GeneralCategory::NonspacingMark
        | GeneralCategory::EnclosingMark
        | GeneralCategory::Format => true,
        // Claude Code's dimmest spinner frame.
        _ => c == '\u{00B7}',
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/Users/furkan";

    fn show(title: &str, cwd: Option<&str>, agent: Option<&str>) -> String {
        display_in(title, cwd, agent, HOME)
    }

    #[test]
    fn a_shells_prompt_title_reads_as_the_folder_it_is_in() {
        let cwd = Some("/Users/furkan/git/private/soprano-cast");
        assert_eq!(show("furkan@MacBook-Pro-3:~/git/private/soprano-cast", cwd, None), "soprano-cast");
        assert_eq!(show("…/git/private/soprano-cast", cwd, None), "soprano-cast");
        assert_eq!(show("furkan@MacBook-Pro-3", cwd, None), "soprano-cast");
        assert_eq!(show("~", Some(HOME), None), "~");
    }

    #[test]
    fn without_a_working_directory_the_prompts_own_path_names_the_folder() {
        assert_eq!(
            show("furkan@MacBook-Pro-3:~/git/work/valkental-b2c-app", None, None),
            "valkental-b2c-app"
        );
        assert_eq!(show("…/git/work/valkental-int-frontend", None, None), "valkental-int-frontend");
        assert_eq!(show("~/dotfiles", None, None), "dotfiles");
    }

    #[test]
    fn a_commands_title_is_kept() {
        assert_eq!(show("npm run dev", Some("/Users/furkan/git/shop"), None), "npm run dev");
        assert_eq!(
            show("vim SidebarView.swift", Some("/Users/furkan/git/shop"), None),
            "vim SidebarView.swift"
        );
    }

    #[test]
    fn omps_brand_and_state_separator_go_in_every_state() {
        for title in [
            "π > MIGR: Plan Conversion",
            "π ⠋ MIGR: Plan Conversion",
            "π ! MIGR: Plan Conversion",
            "π : MIGR: Plan Conversion",
            "π: MIGR: Plan Conversion",
            "π - MIGR: Plan Conversion",
        ] {
            assert_eq!(show(title, None, Some("omp")), "MIGR: Plan Conversion", "{title}");
        }
    }

    #[test]
    fn nerd_font_icons_are_dropped_because_the_system_font_cannot_draw_them() {
        assert_eq!(show("π > \u{F04E1} MIGR: Plan Conversion", None, Some("omp")), "MIGR: Plan Conversion");
        assert_eq!(show("\u{E0A0} main", Some("/tmp"), None), "main");
    }

    #[test]
    fn claude_codes_spinner_glyph_in_front_of_its_task_goes() {
        for glyph in ["✳", "✶", "✻", "✽", "✢", "·", "⠙"] {
            assert_eq!(
                show(&format!("{glyph} Fix the sidebar"), None, Some("Claude Code")),
                "Fix the sidebar",
                "{glyph}"
            );
        }
        assert_eq!(show("🚀\u{FE0F} Deploy", Some("/tmp"), None), "Deploy");
    }

    #[test]
    fn an_agent_without_a_task_title_is_called_by_its_name() {
        assert_eq!(show("π >", None, Some("omp")), "omp");
        assert_eq!(show("omp", None, Some("omp")), "omp");
        assert_eq!(show("Codex: soprano", Some("/Users/furkan/git/soprano"), Some("Codex")), "Codex");
        // The placeholder keeps the folder the agent started in.
        assert_eq!(show("Codex: soprano", Some("/Users/furkan/git/soprano/Sources"), Some("Codex")), "Codex");
        assert_eq!(show("Codex: fix the build", None, Some("Codex")), "Codex: fix the build");
        // The shell's title lingers until an agent typed into it titles itself.
        assert_eq!(
            show("furkan@MacBook-Pro-3:~/git/soprano", Some("/Users/furkan/git/soprano"), Some("omp")),
            "omp"
        );
    }

    #[test]
    fn a_word_that_starts_with_pi_is_not_omps_brand() {
        assert_eq!(show("πr² calculator", Some("/tmp"), None), "πr² calculator");
    }

    #[test]
    fn a_path_title_not_at_the_home_folder_is_not_named_tilde() {
        assert_eq!(folder_name_in("/Users/furkan/", HOME), "~");
        assert_eq!(folder_name_in("/", HOME), "/");
        assert_eq!(folder_name_in("/Users/furkan/git/", HOME), "git");
    }
}
