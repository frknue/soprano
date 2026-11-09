//! The user's login shell.

/// The user's shell: `$SHELL` when set, else the account's shell from the password database
/// (a GUI launch on macOS may not carry `$SHELL`), else `/bin/zsh` on macOS and `/bin/sh`
/// elsewhere. On Windows: `pwsh.exe` when installed, else `powershell.exe`.
pub fn user_shell() -> String {
    #[cfg(windows)]
    {
        return windows_shell();
    }
    #[cfg(unix)]
    {
        if let Ok(shell) = std::env::var("SHELL") {
            if !shell.trim().is_empty() {
                return shell;
            }
        }
        if let Some(shell) = passwd_shell() {
            return shell;
        }
        if cfg!(target_os = "macos") { "/bin/zsh".into() } else { "/bin/sh".into() }
    }
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
