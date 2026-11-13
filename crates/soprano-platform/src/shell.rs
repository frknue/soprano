//! The user's login shell, and how a word is written for one.

/// The user's shell on Windows: `pwsh.exe` when installed, else `powershell.exe`.
#[cfg(windows)]
pub fn user_shell() -> String {
    windows_shell()
}

/// The user's shell: `$SHELL` when set, else the account's shell from the password database
/// (a GUI launch on macOS may not carry `$SHELL`), else `/bin/zsh` on macOS and `/bin/sh`
/// elsewhere.
#[cfg(unix)]
pub fn user_shell() -> String {
    if let Ok(shell) = std::env::var("SHELL")
        && !shell.trim().is_empty()
    {
        return shell;
    }
    if let Some(shell) = passwd_shell() {
        return shell;
    }
    if cfg!(target_os = "macos") { "/bin/zsh".into() } else { "/bin/sh".into() }
}

#[cfg(unix)]
fn passwd_shell() -> Option<String> {
    // getent/dscl differ per OS; /etc/passwd covers Linux, and macOS always sets $SHELL for
    // apps launched by launchd, so the fallback is rarely reached there.
    let user = std::env::var("USER").ok()?;
    let passwd = std::fs::read_to_string("/etc/passwd").ok()?;
    passwd.lines().find_map(|line| {
        let fields: Vec<&str> = line.split(':').collect();
        (fields.first() == Some(&user.as_str()) && fields.len() >= 7)
            .then(|| fields[6].to_owned())
            .filter(|s| !s.is_empty())
    })
}

#[cfg(windows)]
fn windows_shell() -> String {
    let has_pwsh = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).any(|dir| dir.join("pwsh.exe").is_file()))
        .unwrap_or(false);
    if has_pwsh { "pwsh.exe".into() } else { "powershell.exe".into() }
}

/// The shell's file name without directories: `zsh`, `bash`, `fish`, `pwsh.exe`.
pub fn shell_name(shell: &str) -> &str {
    shell.rsplit(['/', '\\']).next().unwrap_or(shell)
}

/// Backslash-escapes every character that would change how a shell splits or expands a word:
/// how a terminal types a dropped file, and how agents read a path inside a message.
pub fn shell_escape(value: &str) -> String {
    const SPECIAL: &str = "\\ ()[]{}<>\"'`!#$&;|*?\t";
    let mut escaped = String::with_capacity(value.len());
    for c in value.chars() {
        if SPECIAL.contains(c) {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

/// A file's path as one word, the way it is typed after a command: backslash-escaped for a
/// POSIX shell; on Windows, where a backslash separates folders, in double quotes when it
/// has a space.
pub fn path_word(path: &std::path::Path) -> String {
    let path = path.to_string_lossy();
    if !cfg!(windows) {
        shell_escape(&path)
    } else if path.contains(' ') {
        format!("\"{path}\"")
    } else {
        path.into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_escapes_characters_that_would_change_a_command_line() {
        assert_eq!(
            shell_escape("/tmp/Screen Shot [draft] #1.png"),
            "/tmp/Screen\\ Shot\\ \\[draft\\]\\ \\#1.png"
        );
    }

    #[test]
    fn a_backslash_is_escaped_once() {
        assert_eq!(shell_escape("a\\b"), "a\\\\b");
    }
}
