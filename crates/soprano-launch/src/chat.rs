//! How a chat tab starts its agent (`AgentChatLaunch` in `Chat/AgentChatSession.swift`): the
//! agent's ACP server, run through the user's login shell like an agent pane so it finds the
//! same CLI and sees the same environment.

use std::collections::BTreeMap;
use std::path::Path;

use soprano_types::AgentProfile;

use crate::approvals::bypass_chat_approvals;
use crate::quote::{ShellFlavor, powershell_quoted, shell_quoted};
use crate::shell_integration::path_string;
use crate::spec::AccountAdjustments;

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
        // Like every agent, the server asks for nothing: a chat's approvals are answered in
        // its tab, which a thread's tab is behind.
        bypass_chat_approvals(&mut arguments);

        // Account variables go after the rc files, as in an agent pane.
        let arguments = match ShellFlavor::of(login_shell) {
            ShellFlavor::Posix => {
                let mut script: Vec<String> = accounts
                    .environment
                    .iter()
                    .map(|(k, v)| format!("export {k}={}", shell_quoted(v)))
                    .collect();
                let quoted: Vec<String> = std::iter::once(profile.command.as_str())
                    .chain(arguments.iter().map(String::as_str))
                    .map(shell_quoted)
                    .collect();
                script.push(format!("exec {}", quoted.join(" ")));
                vec!["-lic".into(), script.join("; ")]
            }
            ShellFlavor::PowerShell => {
                let mut script: Vec<String> = accounts
                    .environment
                    .iter()
                    .map(|(k, v)| format!("$env:{k} = {}", powershell_quoted(v)))
                    .collect();
                let quoted: Vec<String> = arguments.iter().map(|a| powershell_quoted(a)).collect();
                script.push(crate::command_runner::powershell_missing_command_check(&profile.command));
                script.push(format!("& {} {}", powershell_quoted(&profile.command), quoted.join(" ")));
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
                r"exec 'omp' 'acp' '--model' 'it'\''s' '--approval-mode=yolo'".to_owned()
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
            "export X_HOME='/a b'; exec 'omp' 'acp' '--config' '/o.yml' '--approval-mode=yolo'"
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
                 command not found'); exit 127 }; & 'omp' 'acp' '--approval-mode=yolo'; exit $LASTEXITCODE"
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

    /// What a chat of the stand-in agent at `agent` is started with: the agent prints its
    /// arguments.
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
    fn stand_in_agent(folder: &Path) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt as _;
        let agent = folder.join("omp agent");
        std::fs::write(&agent, "#!/bin/sh\necho \"$@\"\n").expect("agent");
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o755)).expect("executable");
        agent
    }

    #[cfg(unix)]
    #[test]
    fn a_chat_starts_asking_for_nothing_whatever_its_agents_arguments_say() {
        let folder = tempfile::tempdir().expect("folder");
        let agent = stand_in_agent(folder.path());
        assert_eq!(started_with(&agent, &[]), "acp --approval-mode=yolo");
        assert_eq!(started_with(&agent, &["--model", "it's"]), "acp --model it's --approval-mode=yolo");
        assert_eq!(started_with(&agent, &["--approval-mode=write"]), "acp --approval-mode=yolo");
        assert_eq!(
            started_with(&agent, &["--auto-approve", "--model", "x"]),
            "acp --model x --approval-mode=yolo"
        );
        // An overlay that sets a stricter mode stays on the command line; the flag wins over it.
        assert_eq!(
            started_with(&agent, &["--config", "/tmp/strict.yml"]),
            "acp --config /tmp/strict.yml --approval-mode=yolo"
        );
    }
}
