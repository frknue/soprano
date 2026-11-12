//! How a chat tab starts its agent (`AgentChatLaunch` in `Chat/AgentChatSession.swift`): the
//! agent's ACP server, run through the user's login shell like an agent pane so it finds the
//! same CLI and sees the same environment.

use std::collections::BTreeMap;
use std::path::Path;

use soprano_types::AgentProfile;

use crate::quote::{ShellFlavor, powershell_quoted, shell_quoted};
use crate::shell_integration::path_string;
use crate::spec::AccountAdjustments;

/// The agent's setting that says when it asks before a tool call, and the values it takes.
const APPROVAL_MODE_SETTING: &str = "tools.approvalMode";
const APPROVAL_MODES: [&str; 4] = ["always-ask", "always-ask-cached", "write", "yolo"];

/// Starts the agent's ACP server (`$0 acp "$@"`) so that a chat asks for approval exactly
/// when the agent's terminal would. omp's ACP server asks before every command unless its
/// approval mode is named, whatever [`APPROVAL_MODE_SETTING`] resolves to — a terminal omp
/// follows the setting — so the mode the agent resolves under `profile_flags` (the launch's
/// `--profile`) is read and passed on. An agent that does not answer with a mode starts as
/// it would have.
fn approval_mode_script(profile_flags: &[String]) -> String {
    let flags: String = profile_flags.iter().map(|flag| format!("{} ", shell_quoted(flag))).collect();
    format!(
        r#"mode=$("$0" {flags}config get {APPROVAL_MODE_SETTING} 2>/dev/null); case "$mode" in {}) exec "$0" acp "$@" "--approval-mode=$mode";; *) exec "$0" acp "$@";; esac"#,
        APPROVAL_MODES.join("|")
    )
}

/// What the launch's `arguments` say about the context the agent's settings come from.
#[derive(Debug, Default, PartialEq, Eq)]
struct SettingsContext {
    /// The launch says itself when the agent asks: with a flag, or in a `--config` overlay
    /// (which the agent's own lookup does not read). Nothing is added to such a launch.
    names_approval_mode: bool,
    /// The `--profile` the agent runs under, as the flags the lookup repeats.
    profile_flags: Vec<String>,
}

impl SettingsContext {
    /// Reads `arguments`; a relative overlay is looked for in `working_directory`.
    fn of(arguments: &[String], working_directory: &Path) -> Self {
        let mut context = Self::default();
        let mut rest = arguments.iter();
        while let Some(argument) = rest.next() {
            let (flag, inline) = match argument.split_once('=') {
                Some((flag, value)) => (flag, Some(value)),
                None => (argument.as_str(), None),
            };
            match flag {
                "--auto-approve" | "--approval-mode" => context.names_approval_mode = true,
                "--config" => {
                    let overlay = inline.map(str::to_owned).or_else(|| rest.next().cloned());
                    let sets_mode = overlay.is_some_and(|overlay| {
                        std::fs::read_to_string(working_directory.join(overlay))
                            .is_ok_and(|settings| sets_approval_mode(&settings))
                    });
                    context.names_approval_mode |= sets_mode;
                }
                "--profile" => match inline {
                    Some(_) => context.profile_flags = vec![argument.clone()],
                    None => {
                        context.profile_flags =
                            std::iter::once(argument).chain(rest.next()).cloned().collect();
                    }
                },
                _ => {}
            }
        }
        context
    }
}

/// Whether an overlay's YAML sets the approval mode: the key `approvalMode` under `tools`,
/// the one place the agent reads it from (a dotted `tools.approvalMode` key sets nothing
/// there). An overlay that is not YAML sets nothing either.
fn sets_approval_mode(settings: &str) -> bool {
    let [section, key] = APPROVAL_MODE_SETTING.split('.').collect::<Vec<_>>()[..] else { return false };
    yaml_rust2::YamlLoader::load_from_str(settings)
        .is_ok_and(|documents| documents.iter().any(|document| !document[section][key].is_badvalue()))
}

/// The process behind a chat tab: `shell arguments…` in `working_directory`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatLaunch {
    pub profile_id: String,
    pub agent_name: String,
    pub shell: String,
    pub arguments: Vec<String>,
    /// The complete environment of the process.
    pub environment: BTreeMap<String, String>,
    pub working_directory: String,
}

impl ChatLaunch {
    /// Agents a chat tab can run, by profile id: those whose CLI serves the Agent Client
    /// Protocol on stdio.
    pub fn supports(profile_id: &str) -> bool {
        profile_id == "omp"
    }

    /// The catalog's agents that open as a chat, in catalog order.
    pub fn chat_profiles() -> Vec<AgentProfile> {
        soprano_types::AgentCatalog::shared().all().into_iter().filter(|p| Self::supports(&p.id)).collect()
    }

    /// What a throwaway conversation adds to the agent's command line (reading what a new
    /// thread would offer): omp keeps it in `session_directory` instead of the folder's
    /// session history.
    pub fn throwaway_arguments(session_directory: &Path) -> Vec<String> {
        vec!["--session-dir".into(), path_string(session_directory)]
    }

    /// `None` for agents without an ACP server.
    pub fn for_profile(
        profile: &AgentProfile,
        cwd: Option<&str>,
        login_shell: &str,
        accounts: &AccountAdjustments,
        environment: &BTreeMap<String, String>,
        home: &Path,
    ) -> Option<Self> {
        if !Self::supports(&profile.id) {
            return None;
        }
        // Like `SopranoConfig.expandPath`: `~` expands, a relative folder resolves against the
        // app's working folder, and only an empty one falls back to home.
        let raw = cwd.or(profile.cwd.as_deref()).unwrap_or("").trim();
        let directory = if raw.is_empty() {
            None
        } else {
            let expanded = soprano_platform::paths::expand_tilde_in(raw, home);
            let absolute = if expanded.is_absolute() {
                Some(expanded)
            } else {
                std::env::current_dir().ok().map(|dir| dir.join(expanded))
            };
            absolute.map(|p| soprano_platform::paths::normalize(&p))
        };
        let working_directory = path_string(directory.as_deref().unwrap_or(home));

        // A Soprano started from one of its own panes must not pass that pane's identity on:
        // hooks would report this chat as that pane.
        let mut process_environment: BTreeMap<String, String> = environment
            .iter()
            .filter(|(k, _)| !k.starts_with("SOPRANO_"))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        process_environment.extend(profile.env.clone().unwrap_or_default());
        // omp's ambient extension stays quiet for an agent Soprano launched.
        process_environment.insert("SOPRANO_AGENT_PROFILE".into(), profile.id.clone());
        process_environment.insert("SOPRANO_AGENT_NAME".into(), profile.name.clone());

        let mut arguments = vec!["acp".to_owned()];
        arguments.extend(profile.args.iter().cloned());
        arguments.extend(accounts.arguments.iter().cloned());
        let context = SettingsContext::of(&arguments, Path::new(&working_directory));
        let follows_terminal = !context.names_approval_mode;

        // Account variables go after the rc files, as in an agent pane.
        let arguments = match ShellFlavor::of(login_shell) {
            ShellFlavor::Posix => {
                let mut script: Vec<String> = accounts
                    .environment
                    .iter()
                    .map(|(k, v)| format!("export {k}={}", shell_quoted(v)))
                    .collect();
                // Every shell here runs `exec <command> <quoted arguments>`; the lookup needs
                // more than that, so it runs in `sh`, with the agent as `$0`.
                let lookup = approval_mode_script(&context.profile_flags);
                let command: Vec<&str> = if follows_terminal {
                    ["sh", "-c", &lookup, &profile.command]
                        .into_iter()
                        .chain(arguments[1..].iter().map(String::as_str))
                        .collect()
                } else {
                    std::iter::once(profile.command.as_str())
                        .chain(arguments.iter().map(String::as_str))
                        .collect()
                };
                let quoted: Vec<String> = command.into_iter().map(shell_quoted).collect();
                script.push(format!("exec {}", quoted.join(" ")));
                vec!["-lic".into(), script.join("; ")]
            }
            ShellFlavor::PowerShell => {
                let mut script: Vec<String> = accounts
                    .environment
                    .iter()
                    .map(|(k, v)| format!("$env:{k} = {}", powershell_quoted(v)))
                    .collect();
                let agent = powershell_quoted(&profile.command);
                let run = |arguments: &[String]| {
                    let quoted: Vec<String> = arguments.iter().map(|a| powershell_quoted(a)).collect();
                    format!("& {agent} {}", quoted.join(" "))
                };
                script.push(crate::command_runner::powershell_missing_command_check(&profile.command));
                if follows_terminal {
                    let modes: Vec<String> =
                        APPROVAL_MODES.iter().map(|mode| powershell_quoted(mode)).collect();
                    let flags: String = context
                        .profile_flags
                        .iter()
                        .map(|flag| format!("{} ", powershell_quoted(flag)))
                        .collect();
                    script.push(format!(
                        "$mode = \"$(& {agent} {flags}'config' 'get' {} 2>$null)\".Trim()",
                        powershell_quoted(APPROVAL_MODE_SETTING)
                    ));
                    script.push(format!(
                        "if ($mode -in {}) {{ {} \"--approval-mode=$mode\" }} else {{ {} }}",
                        modes.join(","),
                        run(&arguments),
                        run(&arguments)
                    ));
                } else {
                    script.push(run(&arguments));
                }
                script.push("exit $LASTEXITCODE".into());
                vec!["-NoLogo".into(), "-Command".into(), script.join("; ")]
            }
        };
        Some(Self {
            profile_id: profile.id.clone(),
            agent_name: profile.name.clone(),
            shell: login_shell.into(),
            arguments,
            environment: process_environment,
            working_directory,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_types::DefaultAgents;

    #[test]
    fn the_chat_launches_the_agents_acp_server_through_the_login_shell() {
        let profile = AgentProfile {
            args: vec!["--model".into(), "it's".into()],
            env: Some(BTreeMap::from([("EXTRA".to_owned(), "1".to_owned())])),
            ..DefaultAgents::omp()
        };
        let environment = BTreeMap::from([
            ("PATH".to_owned(), "/usr/bin".to_owned()),
            ("SOPRANO_PANE_ID".to_owned(), "pane-1".to_owned()),
        ]);
        let home = Path::new("/home/me");
        let none = AccountAdjustments::default();
        let launch =
            ChatLaunch::for_profile(&profile, Some("/work/repo"), "/bin/zsh", &none, &environment, home)
                .expect("omp chats");
        assert_eq!(launch.shell, "/bin/zsh");
        assert_eq!(
            launch.arguments,
            vec![
                "-lic".to_owned(),
                format!(
                    r"exec 'sh' '-c' {} 'omp' '--model' 'it'\''s'",
                    shell_quoted(&approval_mode_script(&[]))
                )
            ]
        );
        assert_eq!(launch.working_directory, "/work/repo");
        assert_eq!(launch.environment.get("SOPRANO_PANE_ID"), None);
        assert_eq!(launch.environment["SOPRANO_AGENT_PROFILE"], "omp");
        assert_eq!(launch.environment["EXTRA"], "1");
        assert_eq!(launch.environment["PATH"], "/usr/bin");

        let home_launch =
            ChatLaunch::for_profile(&profile, None, "/bin/zsh", &none, &BTreeMap::new(), home).expect("omp");
        assert_eq!(home_launch.working_directory, "/home/me");
        assert!(
            ChatLaunch::for_profile(&DefaultAgents::codex(), None, "/bin/zsh", &none, &BTreeMap::new(), home)
                .is_none()
        );
    }

    #[test]
    fn a_chosen_account_is_exported_after_the_rc_files_and_its_arguments_follow_the_profiles() {
        let accounts = AccountAdjustments {
            environment: BTreeMap::from([("X_HOME".to_owned(), "/a b".to_owned())]),
            arguments: vec!["--config".into(), "/o.yml".into()],
        };
        let launch = ChatLaunch::for_profile(
            &DefaultAgents::omp(),
            Some("~/repo"),
            "/bin/zsh",
            &accounts,
            &BTreeMap::new(),
            Path::new("/home/me"),
        )
        .expect("omp");
        assert_eq!(
            launch.arguments[1],
            format!(
                "export X_HOME='/a b'; exec 'sh' '-c' {} 'omp' '--config' '/o.yml'",
                shell_quoted(&approval_mode_script(&[]))
            )
        );
        assert_eq!(launch.working_directory, "/home/me/repo");
    }

    #[test]
    fn powershell_runs_the_acp_server_with_its_profile_loaded() {
        let launch = ChatLaunch::for_profile(
            &DefaultAgents::omp(),
            Some("/w"),
            "pwsh.exe",
            &AccountAdjustments::default(),
            &BTreeMap::new(),
            Path::new("/home/me"),
        )
        .expect("omp");
        assert_eq!(
            launch.arguments,
            vec![
                "-NoLogo",
                "-Command",
                "if (-not (Get-Command -ErrorAction SilentlyContinue 'omp')) { [Console]::Error.WriteLine('omp: \
                 command not found'); exit 127 }; $mode = \"$(& 'omp' 'config' 'get' 'tools.approvalMode' \
                 2>$null)\".Trim(); if ($mode -in 'always-ask','always-ask-cached','write','yolo') { & 'omp' \
                 'acp' \"--approval-mode=$mode\" } else { & 'omp' 'acp' }; exit $LASTEXITCODE"
            ]
        );
    }

    #[test]
    fn a_relative_chat_folder_resolves_against_the_apps_working_folder() {
        let launch = ChatLaunch::for_profile(
            &DefaultAgents::omp(),
            Some("sub/../repo"),
            "/bin/zsh",
            &AccountAdjustments::default(),
            &BTreeMap::new(),
            Path::new("/home/me"),
        )
        .expect("omp");
        let expected = std::env::current_dir().expect("cwd").join("repo");
        assert_eq!(launch.working_directory, path_string(&expected));
    }

    /// Launches a chat for a stand-in agent at `agent` that answers the approval-mode lookup
    /// with `answer` (its exit status as well) and prints the arguments it is started with.
    #[cfg(unix)]
    fn started_with(agent: &Path, args: &[&str]) -> String {
        let profile = AgentProfile {
            command: path_string(agent),
            args: args.iter().map(|argument| (*argument).to_owned()).collect(),
            ..DefaultAgents::omp()
        };
        let launch = ChatLaunch::for_profile(
            &profile,
            Some("/tmp"),
            "/bin/sh",
            &AccountAdjustments::default(),
            &BTreeMap::new(),
            Path::new("/tmp"),
        )
        .expect("omp");
        // Without the login and interactive switches: the script alone is under test.
        let output =
            std::process::Command::new("/bin/sh").args(["-c", &launch.arguments[1]]).output().expect("sh");
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    }

    #[cfg(unix)]
    fn stand_in_agent(folder: &Path, lookup: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt as _;
        let agent = folder.join("omp agent");
        let script =
            format!("#!/bin/sh\ncase \" $* \" in *\" config get \"*) {lookup};; esac\necho \"$@\"\n");
        std::fs::write(&agent, script).expect("agent");
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).expect("executable");
        agent
    }

    #[cfg(unix)]
    #[test]
    fn a_chat_starts_with_the_approval_mode_the_agents_terminal_follows() {
        let folder = tempfile::tempdir().expect("folder");
        let yolo = stand_in_agent(folder.path(), "echo yolo; exit 0");
        assert_eq!(started_with(&yolo, &[]), "acp --approval-mode=yolo");
        assert_eq!(started_with(&yolo, &["--model", "it's"]), "acp --model it's --approval-mode=yolo");
        // A launch that names its mode keeps it, and the agent is not asked.
        assert_eq!(started_with(&yolo, &["--approval-mode=write"]), "acp --approval-mode=write");
        assert_eq!(started_with(&yolo, &["--auto-approve"]), "acp --auto-approve");

        let asking = stand_in_agent(folder.path(), "echo always-ask; exit 0");
        assert_eq!(started_with(&asking, &[]), "acp --approval-mode=always-ask");
    }

    #[cfg(unix)]
    #[test]
    fn an_agent_that_names_no_approval_mode_starts_as_it_always_did() {
        let folder = tempfile::tempdir().expect("folder");
        // An omp without the setting, or one that answers with something else.
        let silent = stand_in_agent(folder.path(), "echo 'Unknown setting' >&2; exit 1");
        assert_eq!(started_with(&silent, &["--model", "opus"]), "acp --model opus");
        let odd = stand_in_agent(folder.path(), "echo 'yolo; rm -rf /'; exit 0");
        assert_eq!(started_with(&odd, &[]), "acp");
    }

    #[cfg(unix)]
    #[test]
    fn an_overlay_that_sets_the_approval_mode_is_not_overruled_by_the_agents_own_setting() {
        let folder = tempfile::tempdir().expect("folder");
        // The agent's own lookup never reads an overlay: it answers with its base setting.
        let agent = stand_in_agent(folder.path(), "echo always-ask; exit 0");
        let strict = folder.path().join("strict.yml");
        std::fs::write(&strict, "tools:\n  approvalMode: yolo\n").expect("overlay");
        let accounts = folder.path().join("accounts.yml");
        // It only talks about the mode: in a comment and in a value.
        std::fs::write(
            &accounts,
            "# approvalMode is inherited\nauth:\n  accountPolicies: []  # not approvalMode: yolo\nnote: \"use approvalMode: yolo\"\n",
        )
        .expect("overlay");
        let (strict, accounts) = (path_string(&strict), path_string(&accounts));

        // The overlay's mode stands: a flag would win over it.
        assert_eq!(started_with(&agent, &["--config", &strict]), format!("acp --config {strict}"));
        let inline = format!("--config={strict}");
        assert_eq!(started_with(&agent, &[&inline]), format!("acp {inline}"));
        // An overlay about something else (the chosen account's) leaves the mode to the agent.
        assert_eq!(
            started_with(&agent, &["--config", &accounts]),
            format!("acp --config {accounts} --approval-mode=always-ask")
        );
    }

    #[cfg(unix)]
    #[test]
    fn the_approval_mode_is_read_under_the_profile_the_chat_runs_in() {
        let folder = tempfile::tempdir().expect("folder");
        let agent = stand_in_agent(
            folder.path(),
            r#"case "$*" in "--profile work's config get"*|"--profile=work config get"*) echo write;; *) echo yolo;; esac; exit 0"#,
        );
        assert_eq!(started_with(&agent, &[]), "acp --approval-mode=yolo");
        assert_eq!(
            started_with(&agent, &["--profile", "work's", "--model", "opus"]),
            "acp --profile work's --model opus --approval-mode=write"
        );
        assert_eq!(started_with(&agent, &["--profile=work"]), "acp --profile=work --approval-mode=write");
    }

    #[test]
    fn an_overlay_sets_the_approval_mode_only_with_the_key_under_tools() {
        for settings in [
            "tools:\n  approvalMode: write\n",
            "tools: {approvalMode: yolo}\n",
            "tools: { \"approvalMode\" : \"yolo\" }  # strict here\n",
            "auth: {}\ntools:\n  approval: {}\n  approvalMode: always-ask\n",
        ] {
            assert!(sets_approval_mode(settings), "{settings}");
        }
        for settings in [
            "",
            "# tools:\n#   approvalMode: yolo\n",
            "tools:\n  approval: {}  # approvalMode: yolo\n",
            // The word in a value, with a colon, quoted or in a block.
            "note: \"use approvalMode: yolo\"\n",
            "tools:\n  note: 'approvalMode: yolo'\n",
            "example: |\n  tools:\n    approvalMode: yolo\n",
            // The agent reads neither a dotted key nor the key elsewhere.
            "tools.approvalMode: always-ask\n",
            "approvalMode: yolo\n",
            "other:\n  approvalMode: yolo\n",
            "tools: [approvalMode\n",
        ] {
            assert!(!sets_approval_mode(settings), "{settings}");
        }
    }
}
