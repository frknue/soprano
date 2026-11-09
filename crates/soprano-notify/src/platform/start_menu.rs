//! Where the Windows backend keeps the Start menu shortcut that registers the app's
//! AppUserModelID. Plain path logic, so it is tested on every OS.

use std::path::{Path, PathBuf};

/// `<appdata>\Microsoft\Windows\Start Menu\Programs\<app name>.lnk`, with characters a file
/// name cannot hold replaced.
pub(crate) fn shortcut_path(appdata: &Path, app_name: &str) -> PathBuf {
    appdata
        .join("Microsoft")
        .join("Windows")
        .join("Start Menu")
        .join("Programs")
        .join(format!("{}.lnk", file_name(app_name)))
}

fn file_name(app_name: &str) -> String {
    let name: String = app_name
        .trim()
        .chars()
        .map(|c| {
            if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let name = name.trim_end_matches(['.', ' ']);
    if name.is_empty() { "Soprano".to_owned() } else { name.to_owned() }
}

/// Whether a shortcut's target is `exe`: Windows paths compare without regard to case or
/// separator style.
pub(crate) fn same_target(target: &str, exe: &str) -> bool {
    let normalize = |path: &str| path.replace('/', "\\").to_lowercase();
    !target.is_empty() && normalize(target) == normalize(exe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shortcut_lives_in_the_users_start_menu_programs_named_after_the_app() {
        let path = shortcut_path(Path::new("C:/Users/me/AppData/Roaming"), "Soprano Dev");
        assert!(path.ends_with(Path::new("Microsoft/Windows/Start Menu/Programs/Soprano Dev.lnk")));
        assert!(path.starts_with("C:/Users/me/AppData/Roaming"));
    }

    #[test]
    fn characters_a_file_name_cannot_hold_are_replaced() {
        let path = shortcut_path(Path::new("appdata"), "So:pr/ano?. ");
        assert_eq!(path.file_name().and_then(|n| n.to_str()), Some("So_pr_ano_.lnk"));
        let fallback = shortcut_path(Path::new("appdata"), " . ");
        assert_eq!(fallback.file_name().and_then(|n| n.to_str()), Some("Soprano.lnk"));
    }

    #[test]
    fn a_shortcut_pointing_at_another_executable_does_not_match() {
        assert!(same_target(r"C:\Tools\Soprano\soprano.exe", "c:/tools/soprano/SOPRANO.EXE"));
        assert!(!same_target(r"C:\Old\soprano.exe", r"C:\Tools\Soprano\soprano.exe"));
        assert!(!same_target("", r"C:\Tools\Soprano\soprano.exe"));
    }
}
