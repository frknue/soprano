//! The terminal environment Ghostty gave every pane process, and Ghostty's automatic shell
//! integration (`ghostty/src/termio/Exec.zig`, `ghostty/src/termio/shell_integration.zig`):
//! OSC 133 prompt marks and OSC 7 working directories for bash, zsh, fish, elvish and
//! nushell. PowerShell has no automatic integration in Ghostty and gets none here.

use std::collections::BTreeMap;
use std::path::Path;

use crate::resources::Resources;

/// `PATH`-style list separator of the host OS.
pub(crate) const LIST_SEPARATOR: char = if cfg!(windows) { ';' } else { ':' };

/// Ghostty's default `shell-integration-features` (cursor, path, title) with its default
/// blinking cursor, as `GHOSTTY_SHELL_FEATURES` spells them.
pub const DEFAULT_SHELL_FEATURES: &str = "cursor:blink,path,title";

/// Sets the variables Ghostty's `Exec` set for a child: `GHOSTTY_RESOURCES_DIR`, `TERM`
/// (`xterm-ghostty` with `TERMINFO` only when the terminfo entry is bundled, else
/// `xterm-256color`), `COLORTERM`, `TERM_PROGRAM` (Soprano, as the Swift app exported),
/// `TERM_PROGRAM_VERSION` and `GHOSTTY_SHELL_FEATURES`; drops `VTE_VERSION` so children do
/// not think they run under VTE.
pub fn apply_terminal_environment(env: &mut BTreeMap<String, String>, resources: &Resources, version: &str) {
    if let Some(dir) = resources.ghostty_resources_dir() {
        env.insert("GHOSTTY_RESOURCES_DIR".into(), path_string(dir));
    }
    match resources.terminfo_dir() {
        Some(terminfo) => {
            env.insert("TERM".into(), "xterm-ghostty".into());
            env.insert("TERMINFO".into(), path_string(&terminfo));
        }
        None => {
            env.insert("TERM".into(), "xterm-256color".into());
        }
    }
    env.insert("COLORTERM".into(), "truecolor".into());
    env.insert("TERM_PROGRAM".into(), "Soprano".into());
    env.insert("TERM_PROGRAM_VERSION".into(), version.into());
    env.remove("VTE_VERSION");
    env.insert("GHOSTTY_SHELL_FEATURES".into(), DEFAULT_SHELL_FEATURES.into());
}

/// Shells Ghostty integrates automatically.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shell {
    Bash,
    Elvish,
    Fish,
    Nushell,
    Zsh,
}

/// Which shell `argv` starts, by its executable's file name. Apple's `/bin/bash` 3.2
/// disables the ENV-based POSIX startup path, so it is never integrated on macOS.
pub fn detect_shell(argv: &[String], is_macos: bool) -> Option<Shell> {
    let arg0 = argv.first()?;
    let exe = soprano_platform::shell::shell_name(arg0);
    let exe = exe.strip_suffix(".exe").unwrap_or(exe);
    match exe {
        "bash" if is_macos && arg0 == "/bin/bash" => None,
        "bash" => Some(Shell::Bash),
        "elvish" => Some(Shell::Elvish),
        "fish" => Some(Shell::Fish),
        "nu" => Some(Shell::Nushell),
        "zsh" => Some(Shell::Zsh),
        _ => None,
    }
}

/// Injects Ghostty's shell integration into `argv` and `env` the way Ghostty does, returning
/// the command to run (`argv` unchanged when the shell or its options are not integrated).
pub fn apply_shell_integration(
    argv: Vec<String>,
    env: &mut BTreeMap<String, String>,
    ghostty_resources: Option<&Path>,
    home: &Path,
) -> Vec<String> {
    let Some(resources) = ghostty_resources else { return argv };
    let Some(shell) = detect_shell(&argv, cfg!(target_os = "macos")) else { return argv };
    let integrated = match shell {
        Shell::Bash => setup_bash(&argv, resources, env, home),
        Shell::Nushell => setup_nushell(&argv, resources, env),
        Shell::Zsh => setup_zsh(resources, env).then(|| argv.clone()),
        Shell::Elvish | Shell::Fish => setup_xdg_data_dirs(resources, env).then(|| argv.clone()),
    };
    integrated.unwrap_or(argv)
}

/// Starts bash in POSIX mode with `ENV` pointing at Ghostty's script, which then loads the
/// user's startup files itself and leaves POSIX mode. `-c` (never interactive) and `--posix`
/// are not integrated.
fn setup_bash(
    argv: &[String],
    resources: &Path,
    env: &mut BTreeMap<String, String>,
    home: &Path,
) -> Option<Vec<String>> {
    let mut iter = argv.iter();
    let mut command = vec![iter.next()?.clone(), "--posix".into()];
    // Always at least "1" so the script tells automatic injection from manual sourcing.
    let mut inject = String::from("1");
    let mut rcfile: Option<String> = None;
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--posix" => return None,
            "--norc" => inject.push_str(" --norc"),
            "--noprofile" => inject.push_str(" --noprofile"),
            "--rcfile" | "--init-file" => rcfile = iter.next().cloned(),
            "-" | "--" => {
                command.push(arg.clone());
                command.extend(iter.by_ref().cloned());
                break;
            }
            short if short.len() > 1 && short.starts_with('-') && !short.starts_with("--") => {
                if short.contains('c') {
                    return None;
                }
                command.push(arg.clone());
            }
            _ => command.push(arg.clone()),
        }
    }

    let script = resources.join("shell-integration/bash/ghostty.bash");
    if !script.is_file() {
        return None;
    }
    if let Some(previous) = env.get("ENV").cloned() {
        env.insert("GHOSTTY_BASH_ENV".into(), previous);
    }
    env.insert("ENV".into(), path_string(&script));
    env.insert("GHOSTTY_BASH_INJECT".into(), inject);
    if let Some(rcfile) = rcfile {
        env.insert("GHOSTTY_BASH_RCFILE".into(), rcfile);
    }
    // In POSIX mode HISTFILE defaults to ~/.sh_history; point it back at ~/.bash_history.
    if !env.contains_key("HISTFILE") {
        env.insert("HISTFILE".into(), path_string(&home.join(".bash_history")));
        env.insert("GHOSTTY_BASH_UNEXPORT_HISTFILE".into(), "1".into());
    }
    Some(command)
}

/// Prepends the shell-integration folder to `XDG_DATA_DIRS` (default
/// `/usr/local/share:/usr/share`, so the standard folders are not lost) and records it in
/// `GHOSTTY_SHELL_INTEGRATION_XDG_DIR`, which the shell's integration removes again.
fn setup_xdg_data_dirs(resources: &Path, env: &mut BTreeMap<String, String>) -> bool {
    let integration = resources.join("shell-integration");
    if !integration.is_dir() {
        return false;
    }
    let integration = path_string(&integration);
    env.insert("GHOSTTY_SHELL_INTEGRATION_XDG_DIR".into(), integration.clone());
    let current = env.get("XDG_DATA_DIRS").cloned().unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    let value =
        if current.is_empty() { integration } else { format!("{integration}{LIST_SEPARATOR}{current}") };
    env.insert("XDG_DATA_DIRS".into(), value);
    true
}

/// Nushell autoloads `nushell/vendor/autoload/ghostty.nu` from `XDG_DATA_DIRS`; `--execute
/// 'use ghostty *'` turns its features on. `--command`, `-c` and `--lsp` are not integrated
/// (the `XDG_DATA_DIRS` entry stays, as in Ghostty).
fn setup_nushell(
    argv: &[String],
    resources: &Path,
    env: &mut BTreeMap<String, String>,
) -> Option<Vec<String>> {
    if !setup_xdg_data_dirs(resources, env) {
        return None;
    }
    let mut iter = argv.iter();
    let mut command = vec![iter.next()?.clone(), "--execute".into(), "use ghostty *".into()];
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--command" | "--lsp" => return None,
            "-" | "--" => {
                command.push(arg.clone());
                command.extend(iter.by_ref().cloned());
                break;
            }
            short if short.len() > 1 && short.starts_with('-') && !short.starts_with("--") => {
                if short.contains('c') {
                    return None;
                }
                command.push(arg.clone());
            }
            _ => command.push(arg.clone()),
        }
    }
    Some(command)
}

/// Points `ZDOTDIR` at Ghostty's zsh folder, whose `.zshenv` restores the user's `ZDOTDIR`
/// (kept in `GHOSTTY_ZSH_ZDOTDIR`) and loads the integration into interactive shells.
fn setup_zsh(resources: &Path, env: &mut BTreeMap<String, String>) -> bool {
    let integration = resources.join("shell-integration/zsh");
    if !integration.is_dir() {
        return false;
    }
    if let Some(previous) = env.get("ZDOTDIR").cloned() {
        env.insert("GHOSTTY_ZSH_ZDOTDIR".into(), previous);
    }
    env.insert("ZDOTDIR".into(), path_string(&integration));
    true
}

pub(crate) fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn resources_for(shell: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        let integration = dir.path().join("shell-integration");
        match shell {
            "bash" => {
                fs::create_dir_all(integration.join("bash")).expect("mkdir");
                fs::write(integration.join("bash/ghostty.bash"), "").expect("write");
            }
            other => fs::create_dir_all(integration.join(other)).expect("mkdir"),
        }
        dir
    }

    fn args(line: &str) -> Vec<String> {
        line.split(' ').map(str::to_owned).collect()
    }

    #[test]
    fn shells_are_detected_by_executable_name() {
        assert_eq!(detect_shell(&args("sh"), false), None);
        assert_eq!(detect_shell(&args("bash"), false), Some(Shell::Bash));
        assert_eq!(detect_shell(&args("elvish"), false), Some(Shell::Elvish));
        assert_eq!(detect_shell(&args("fish"), false), Some(Shell::Fish));
        assert_eq!(detect_shell(&args("nu"), false), Some(Shell::Nushell));
        assert_eq!(detect_shell(&args("/usr/bin/zsh"), false), Some(Shell::Zsh));
        assert_eq!(detect_shell(&args("bash -c command"), false), Some(Shell::Bash));
        assert_eq!(detect_shell(&args("/bin/bash"), true), None);
        assert_eq!(detect_shell(&args("/opt/homebrew/bin/bash"), true), Some(Shell::Bash));
    }

    #[test]
    fn bash_starts_in_posix_mode_with_ghosttys_script_as_env() {
        let res = resources_for("bash");
        let mut env = BTreeMap::new();
        let argv = apply_shell_integration(args("bash"), &mut env, Some(res.path()), Path::new("/home/me"));
        assert_eq!(argv, args("bash --posix"));
        assert_eq!(env["GHOSTTY_BASH_INJECT"], "1");
        assert!(env["ENV"].ends_with("shell-integration/bash/ghostty.bash"));
        assert_eq!(env["HISTFILE"], "/home/me/.bash_history");
        assert_eq!(env["GHOSTTY_BASH_UNEXPORT_HISTFILE"], "1");
    }

    #[test]
    fn bash_options_are_forwarded_to_the_integration_script() {
        let res = resources_for("bash");
        let home = Path::new("/h");
        let mut env = BTreeMap::new();
        assert_eq!(
            apply_shell_integration(args("bash --norc"), &mut env, Some(res.path()), home),
            args("bash --posix")
        );
        assert_eq!(env["GHOSTTY_BASH_INJECT"], "1 --norc");

        let mut env = BTreeMap::new();
        let argv =
            apply_shell_integration(args("bash --rcfile profile.sh"), &mut env, Some(res.path()), home);
        assert_eq!(argv, args("bash --posix"));
        assert_eq!(env["GHOSTTY_BASH_RCFILE"], "profile.sh");

        let mut env =
            BTreeMap::from([("ENV".to_owned(), "env.sh".to_owned()), ("HISTFILE".into(), "h".into())]);
        let argv = apply_shell_integration(args("bash - --arg file1"), &mut env, Some(res.path()), home);
        assert_eq!(argv, args("bash --posix - --arg file1"));
        assert_eq!(env["GHOSTTY_BASH_ENV"], "env.sh");
        assert_eq!(env["HISTFILE"], "h");
        assert!(!env.contains_key("GHOSTTY_BASH_UNEXPORT_HISTFILE"));
    }

    #[test]
    fn bash_commands_and_posix_mode_are_left_alone() {
        let res = resources_for("bash");
        for line in ["bash -c command", "bash -lic script", "bash --posix"] {
            let mut env = BTreeMap::new();
            assert_eq!(
                apply_shell_integration(args(line), &mut env, Some(res.path()), Path::new("/h")),
                args(line)
            );
            assert!(env.is_empty(), "{line}");
        }
    }

    #[test]
    fn zsh_keeps_the_users_zdotdir_for_ghosttys_zshenv() {
        let res = resources_for("zsh");
        let mut env = BTreeMap::from([("ZDOTDIR".to_owned(), "$HOME/.config/zsh".to_owned())]);
        let argv = apply_shell_integration(args("zsh -lic x"), &mut env, Some(res.path()), Path::new("/h"));
        assert_eq!(argv, args("zsh -lic x"));
        assert!(env["ZDOTDIR"].ends_with("shell-integration/zsh"));
        assert_eq!(env["GHOSTTY_ZSH_ZDOTDIR"], "$HOME/.config/zsh");
    }

    #[cfg(unix)]
    #[test]
    fn fish_and_elvish_find_the_integration_through_xdg_data_dirs() {
        let res = resources_for("fish");
        let integration = path_string(&res.path().join("shell-integration"));
        let mut env = BTreeMap::new();
        apply_shell_integration(args("fish -l"), &mut env, Some(res.path()), Path::new("/h"));
        assert_eq!(env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"], integration);
        assert_eq!(env["XDG_DATA_DIRS"], format!("{integration}:/usr/local/share:/usr/share"));

        let mut env = BTreeMap::from([("XDG_DATA_DIRS".to_owned(), "/opt/share".to_owned())]);
        apply_shell_integration(args("elvish"), &mut env, Some(res.path()), Path::new("/h"));
        assert_eq!(env["XDG_DATA_DIRS"], format!("{integration}:/opt/share"));
    }

    #[test]
    fn nushell_uses_the_ghostty_module_unless_it_runs_a_command() {
        let res = resources_for("nushell");
        let mut env = BTreeMap::new();
        let argv = apply_shell_integration(args("nu"), &mut env, Some(res.path()), Path::new("/h"));
        assert_eq!(argv, vec!["nu".to_owned(), "--execute".into(), "use ghostty *".into()]);
        for line in ["nu --command exit", "nu --lsp", "nu -c script.sh", "nu -ic script.sh"] {
            let mut env = BTreeMap::new();
            assert_eq!(
                apply_shell_integration(args(line), &mut env, Some(res.path()), Path::new("/h")),
                args(line)
            );
            assert!(env.contains_key("XDG_DATA_DIRS"));
            assert!(env.contains_key("GHOSTTY_SHELL_INTEGRATION_XDG_DIR"));
        }
    }

    #[test]
    fn missing_resources_change_nothing() {
        let empty = tempfile::tempdir().expect("tempdir");
        for line in ["bash", "zsh", "fish", "nu"] {
            let mut env = BTreeMap::new();
            assert_eq!(
                apply_shell_integration(args(line), &mut env, Some(empty.path()), Path::new("/h")),
                args(line)
            );
            assert!(env.is_empty(), "{line}");
        }
    }

    #[test]
    fn term_is_xterm_256color_without_a_bundled_terminfo() {
        let mut env = BTreeMap::from([("VTE_VERSION".to_owned(), "1".to_owned())]);
        apply_terminal_environment(&mut env, &Resources::none(), "1.2.3");
        assert_eq!(env["TERM"], "xterm-256color");
        assert_eq!(env["COLORTERM"], "truecolor");
        assert_eq!(env["TERM_PROGRAM"], "Soprano");
        assert_eq!(env["TERM_PROGRAM_VERSION"], "1.2.3");
        assert!(!env.contains_key("TERMINFO") && !env.contains_key("VTE_VERSION"));

        let root = tempfile::tempdir().expect("tempdir");
        fs::create_dir_all(root.path().join("terminfo")).expect("mkdir");
        let mut env = BTreeMap::new();
        apply_terminal_environment(&mut env, &Resources::at(Some(root.path().to_path_buf())), "1");
        assert_eq!(env["TERM"], "xterm-ghostty");
        assert_eq!(env["TERMINFO"], path_string(&root.path().join("terminfo")));
    }
}
