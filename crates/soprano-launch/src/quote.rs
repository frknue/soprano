//! Quoting for the shells Soprano writes command lines for.

/// POSIX single-quoting: `it's` → `'it'\''s'`. Nothing inside is expanded, so command text
/// cannot smuggle shell syntax.
pub fn shell_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// PowerShell single-quoting: `it's` → `'it''s'`.
pub fn powershell_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// A TOML basic string (JSON string escapes are valid TOML ones), for Codex `-c` overrides.
pub fn toml_quoted(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".into())
}

/// Which syntax a shell's command strings use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShellFlavor {
    /// sh, bash, zsh, fish, nu, elvish: started with `-lic <script>`.
    Posix,
    /// Windows PowerShell or PowerShell 7 (`powershell.exe`, `pwsh`).
    PowerShell,
}

impl ShellFlavor {
    /// The flavor of `shell` (a path or name), judged by its file name.
    pub fn of(shell: &str) -> Self {
        let name = soprano_platform::shell::shell_name(shell).to_ascii_lowercase();
        if name.starts_with("pwsh") || name.starts_with("powershell") {
            Self::PowerShell
        } else {
            Self::Posix
        }
    }

    pub fn quote(self, value: &str) -> String {
        match self {
            Self::Posix => shell_quoted(value),
            Self::PowerShell => powershell_quoted(value),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_quotes_survive_both_shells() {
        assert_eq!(shell_quoted("it's"), r"'it'\''s'");
        assert_eq!(powershell_quoted("it's"), "'it''s'");
        assert_eq!(toml_quoted("/a \"b\""), r#""/a \"b\"""#);
    }

    #[test]
    fn powershell_is_recognized_by_its_file_name() {
        assert_eq!(ShellFlavor::of(r"C:\Program Files\PowerShell\7\pwsh.exe"), ShellFlavor::PowerShell);
        assert_eq!(ShellFlavor::of("powershell.exe"), ShellFlavor::PowerShell);
        assert_eq!(ShellFlavor::of("/bin/zsh"), ShellFlavor::Posix);
    }
}
