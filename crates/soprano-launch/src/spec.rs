//! What a pane starts (`TerminalConfig` in `Terminal/TerminalSurfaceView.swift`, plus the
//! environment Ghostty added when it spawned the surface's process).

use std::collections::BTreeMap;
use std::path::PathBuf;

use soprano_types::{AgentConversation, AgentLaunch, AgentProfile};

use crate::integrations::{
    claude_integration_settings, codex_integration_arguments, file_url, opencode_cli_config_content,
    opencode_config_content,
};
use crate::quote::{ShellFlavor, powershell_quoted, shell_quoted};
use crate::resources::Resources;
use crate::shell_integration::{
    LIST_SEPARATOR, apply_shell_integration, apply_terminal_environment, path_string,
};

/// Pane identity variables. Inherited values (a Soprano started from one of its own panes)
/// never pass through: every pane sets its own, and a plain shell must not look like an agent.
const PANE_IDENTITY_KEYS: [&str; 8] = [
    "SOPRANO_BIN",
    "SOPRANO_PANE_ID",
    "SOPRANO_TAB_ID",
    "SOPRANO_APP_PID",
    "SOPRANO_SOCKET",
    "SOPRANO_AGENT_PROFILE",
    "SOPRANO_AGENT_NAME",
    "SOPRANO_RESUME_SESSION_ID",
];

/// PATH when neither the profile nor the app has one.
const DEFAULT_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

/// The account choices an agent pane starts with (`AccountLaunchState.Adjustments`):
/// `CODEX_HOME` for Codex, `--config <overlay>` for omp. The accounts layer computes them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AccountAdjustments {
    /// Exported for the agent after the login shell's rc files ran.
    pub environment: BTreeMap<String, String>,
    pub arguments: Vec<String>,
}

/// Everything about the running app a launch needs. [`LaunchContext::current`] reads it from
/// the process; tests build it by hand.
#[derive(Clone, Debug)]
pub struct LaunchContext {
    /// `SOPRANO_BIN`: the app executable, which also serves the CLI.
    pub soprano_bin: String,
    /// `SOPRANO_APP_PID`.
    pub app_pid: u32,
    /// `SOPRANO_SOCKET`: the IPC endpoint the CLI talks to.
    pub socket: Option<String>,
    /// `TERM_PROGRAM_VERSION`.
    pub app_version: String,
    /// The user's login shell (`DefaultAgents.terminal.command`).
    pub login_shell: String,
    pub resources: Resources,
    /// The environment panes inherit (the app's own).
    pub base_env: BTreeMap<String, String>,
    pub home: PathBuf,
}

impl LaunchContext {
    pub fn current(socket: Option<String>) -> Self {
        let soprano_bin = std::env::current_exe()
            .ok()
            .and_then(|p| p.canonicalize().ok())
            .map(|p| path_string(&p))
            .or_else(|| std::env::args().next())
            .unwrap_or_else(|| "soprano".into());
        Self {
            soprano_bin,
            app_pid: std::process::id(),
            socket,
            app_version: soprano_platform::identity::app_version().into(),
            login_shell: soprano_platform::shell::user_shell(),
            resources: Resources::locate(),
            base_env: std::env::vars().collect(),
            home: soprano_platform::paths::home_dir(),
        }
    }

    fn flavor(&self) -> ShellFlavor {
        ShellFlavor::of(&self.login_shell)
    }
}

/// How to start a pane's process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchSpec {
    /// Program and arguments; `argv[0]` is looked up on `env["PATH"]`.
    pub argv: Vec<String>,
    /// Working directory; `None` lets the terminal pick (the home folder).
    pub cwd: Option<PathBuf>,
    /// The complete environment of the process.
    pub env: BTreeMap<String, String>,
    /// Typed into the shell once it starts (a profile's `launchScript`, plus a newline).
    pub initial_input: Option<String>,
    /// Keep the pane open after the process exits (Ghostty's `wait-after-command`).
    pub wait_after_command: bool,
}

/// One agent pane to start (`TerminalConfig.forAgent`'s arguments).
#[derive(Clone, Debug)]
pub struct AgentRequest<'a> {
    pub profile: &'a AgentProfile,
    pub cwd: Option<&'a str>,
    pub pane_id: &'a str,
    pub tab_id: &'a str,
    /// The agent's own conversation to resume.
    pub conversation: Option<&'a AgentConversation>,
    /// An automation run's prompt, model and autonomy.
    pub launch: Option<&'a AgentLaunch>,
    pub accounts: &'a AccountAdjustments,
}

impl<'a> AgentRequest<'a> {
    pub fn new(profile: &'a AgentProfile, pane_id: &'a str, tab_id: &'a str) -> Self {
        static NO_ACCOUNTS: std::sync::LazyLock<AccountAdjustments> =
            std::sync::LazyLock::new(AccountAdjustments::default);
        Self { profile, cwd: None, pane_id, tab_id, conversation: None, launch: None, accounts: &NO_ACCOUNTS }
    }
}

impl LaunchSpec {
    /// A plain terminal pane: the user's login shell (`TerminalConfig.defaultShell`).
    pub fn default_shell(ctx: &LaunchContext, cwd: Option<&str>, pane_id: &str, tab_id: &str) -> Self {
        let raw = RawConfig { cwd: cwd.map(|c| expand(ctx, c)), ..RawConfig::default() };
        raw.finish(ctx, pane_id, tab_id)
    }

    /// Runs `arguments` in the login shell, then leaves the pane in an interactive login shell
    /// (`TerminalConfig.forCommand`).
    pub fn for_command(
        ctx: &LaunchContext,
        arguments: &[String],
        cwd: Option<&str>,
        pane_id: &str,
        tab_id: &str,
    ) -> Self {
        let argv = match ctx.flavor() {
            ShellFlavor::Posix => {
                let script = [
                    "trap true INT".to_owned(),
                    join_quoted(arguments, shell_quoted),
                    fallback_shell(&ctx.login_shell, ctx.resources.zsh_startup_dir().as_deref()),
                ]
                .join("; ");
                vec![ctx.login_shell.clone(), "-lic".into(), script]
            }
            ShellFlavor::PowerShell => {
                powershell_argv(ctx, &format!("& {}", join_quoted(arguments, powershell_quoted)))
            }
        };
        let raw = RawConfig { argv: Some(argv), cwd: cwd.map(|c| expand(ctx, c)), ..RawConfig::default() };
        raw.finish(ctx, pane_id, tab_id)
    }

    /// An agent pane (`TerminalConfig.forAgent`).
    pub fn for_agent(ctx: &LaunchContext, request: &AgentRequest<'_>) -> Self {
        let profile = request.profile;
        let conversation = request
            .conversation
            .filter(|c| AgentConversation::supports(&profile.id) && AgentConversation::valid_id(&c.id));
        let cwd = conversation
            .and_then(|c| c.cwd.as_deref())
            .or(request.cwd)
            .or(profile.cwd.as_deref())
            .map(|c| expand(ctx, c));

        let mut env = profile.env.clone().unwrap_or_default();
        env.insert("SOPRANO_BIN".into(), ctx.soprano_bin.clone());
        env.insert("SOPRANO_PANE_ID".into(), request.pane_id.into());
        env.insert("SOPRANO_TAB_ID".into(), request.tab_id.into());
        env.insert("SOPRANO_AGENT_PROFILE".into(), profile.id.clone());
        env.insert("SOPRANO_AGENT_NAME".into(), profile.name.clone());
        env.insert("TERM_PROGRAM".into(), "Soprano".into());

        let mut arguments = match conversation {
            Some(c) => c.resume_arguments(&profile.id, &profile.args),
            None => profile.args.clone(),
        };
        if let Some(conversation) = conversation {
            // Custom launch scripts can opt into the same exact-session recovery.
            env.insert("SOPRANO_RESUME_SESSION_ID".into(), conversation.id.clone());
        }
        match profile.id.as_str() {
            "codex" => arguments.extend(codex_integration_arguments(&ctx.soprano_bin)),
            "claude-code" => arguments.extend(["--settings".to_owned(), claude_integration_settings()]),
            "opencode" => {
                // What the pane starts with: a profile's env wins over Soprano's own.
                let mut pane_env = inherited_env(ctx);
                pane_env.extend(env.clone());
                // OpenCode 1.x loads a server plugin from the pane's inline config.
                if let Some(plugin) = ctx.resources.opencode_plugin() {
                    let launch = request.launch;
                    let content = opencode_config_content(
                        &file_url(&plugin),
                        launch.and_then(|l| l.model.as_deref()),
                        launch.map(|l| l.model_agents.as_slice()).unwrap_or_default(),
                        &pane_env,
                    );
                    if let Some(content) = content {
                        env.insert("OPENCODE_CONFIG_CONTENT".into(), content);
                    }
                }
                // OpenCode 2 runs sessions in one shared background server that never sees
                // this pane's environment, so it reports from the terminal UI.
                if let Some(tui) = ctx.resources.opencode_tui_plugin()
                    && let Some(content) =
                        opencode_cli_config_content(&path_string(&tui), &pane_env, &ctx.home)
                {
                    env.insert("OPENCODE_CLI_CONFIG_CONTENT".into(), content);
                }
            }
            "omp" => {
                if let Some(extension) = ctx.resources.omp_extension() {
                    arguments.extend(["--extension".to_owned(), path_string(&extension)]);
                }
            }
            _ => {}
        }

        // The chosen account: CODEX_HOME for codex, the preference overlay for omp.
        let accounts = request.accounts;
        arguments.extend(accounts.arguments.iter().cloned());
        env.extend(accounts.environment.clone());

        if let Some(launch) = request.launch {
            // A resumed conversation already has its prompt.
            arguments.extend(launch_arguments(&profile.id, launch, conversation.is_none()));
        }

        let mut raw = RawConfig { cwd, env, ..RawConfig::default() };
        match profile.launch_script.as_deref().filter(|s| !s.is_empty()) {
            Some(script) => raw.initial_input = Some(format!("{script}\n")),
            None => {
                let mut command = vec![profile.command.clone()];
                command.extend(arguments);
                raw.argv = Some(agent_argv(ctx, &command, accounts));
            }
        }
        raw.finish(ctx, request.pane_id, request.tab_id)
    }
}

/// What an automation run adds to its CLI's command line: the model, the switch that skips
/// approval prompts, then the prompt as the first message, after `--` so a prompt that starts
/// with a dash (a Markdown list) is not read as an option. OpenCode takes its prompt by flag.
pub fn launch_arguments(profile_id: &str, launch: &AgentLaunch, including_prompt: bool) -> Vec<String> {
    let prompt = if including_prompt { launch.prompt.trim() } else { "" };
    let mut arguments: Vec<String> = Vec::new();
    match profile_id {
        "claude-code" | "codex" | "omp" => {
            if let Some(model) = &launch.model {
                if profile_id == "omp" {
                    arguments.push(format!("--model={model}"));
                } else {
                    arguments.extend(["--model".to_owned(), model.clone()]);
                }
            }
            if launch.skips_approvals {
                arguments.push(
                    match profile_id {
                        "claude-code" => "--dangerously-skip-permissions",
                        "codex" => "--dangerously-bypass-approvals-and-sandbox",
                        _ => "--auto-approve",
                    }
                    .into(),
                );
            }
            if !prompt.is_empty() {
                arguments.extend(["--".to_owned(), prompt.to_owned()]);
            }
        }
        "opencode" => {
            // Its model goes into OPENCODE_CONFIG_CONTENT; there is no flag. Only a private
            // server reads that: OpenCode 2's shared one never sees the pane.
            if launch.starts_private_server {
                arguments.push("--standalone".into());
            }
            if launch.skips_approvals {
                arguments.push("--auto".into());
            }
            if !prompt.is_empty() {
                arguments.push(format!("--prompt={prompt}"));
            }
        }
        _ => {}
    }
    arguments
}

/// Replaces the launch script's shell with an interactive login shell once the agent exits.
///
/// Agents are quit with Ctrl+C, often pressed again while they shut down, and a SIGINT that
/// lands while zsh sources its startup files aborts them, leaving a bare prompt without the
/// user's theme or plugins. zsh therefore starts from `SopranoZsh/.zshenv`, which ignores
/// SIGINT until the first prompt and then hands over to the user's own files; only an
/// exported ZDOTDIR is passed on, as plain `exec` would.
pub fn fallback_shell(login_shell: &str, zsh_startup_dir: Option<&std::path::Path>) -> String {
    let exec = format!("exec {} -l", shell_quoted(login_shell));
    match zsh_startup_dir {
        Some(dir) if soprano_platform::shell::shell_name(login_shell) == "zsh" => format!(
            "if [[ ${{(t)ZDOTDIR}} == *export* ]]; then export SOPRANO_ZSH_ZDOTDIR=\"$ZDOTDIR\"; \
             else unset SOPRANO_ZSH_ZDOTDIR; fi; ZDOTDIR={} {exec}",
            shell_quoted(&path_string(dir))
        ),
        _ => exec,
    }
}

/// The login-shell command line that runs an agent.
///
/// Running the agent directly would skip the user's interactive PATH; use the same login
/// shell as regular terminals so agent CLIs installed on it also start after a workspace
/// restore. When the agent exits, report it and continue in an interactive login shell (see
/// [`fallback_shell`]) so the pane stays a usable terminal instead of a dead surface. That
/// shell is no longer the agent: an agent typed into it must report on its own (omp's
/// ambient extension stays quiet under SOPRANO_AGENT_PROFILE, trusting the launcher's
/// --extension), so the launch identity goes first. The INT trap stops an interactive zsh
/// from abandoning the rest of the line when Ctrl+C kills the agent; children still get
/// default SIGINT. Account variables are exported again after the rc files ran, so a profile
/// that sets, say, CODEX_HOME cannot override the chosen account.
fn agent_argv(ctx: &LaunchContext, command: &[String], accounts: &AccountAdjustments) -> Vec<String> {
    match ctx.flavor() {
        ShellFlavor::Posix => {
            let mut script = vec!["trap true INT".to_owned()];
            script
                .extend(accounts.environment.iter().map(|(k, v)| format!("export {k}={}", shell_quoted(v))));
            script.push(join_quoted(command, shell_quoted));
            script.push("test -z \"$SOPRANO_BIN\" || \"$SOPRANO_BIN\" agent-event stopped".into());
            script.push("unset SOPRANO_AGENT_PROFILE SOPRANO_AGENT_NAME SOPRANO_RESUME_SESSION_ID".into());
            script.push(fallback_shell(&ctx.login_shell, ctx.resources.zsh_startup_dir().as_deref()));
            vec![ctx.login_shell.clone(), "-lic".into(), script.join("; ")]
        }
        ShellFlavor::PowerShell => {
            // PowerShell has no SIGINT trap to set and stays open with -NoExit, so the pane
            // continues in the same shell after the agent exits.
            let mut script: Vec<String> = accounts
                .environment
                .iter()
                .map(|(k, v)| format!("$env:{k} = {}", powershell_quoted(v)))
                .collect();
            script.push(format!("& {}", join_quoted(command, powershell_quoted)));
            script.push("if ($env:SOPRANO_BIN) { & $env:SOPRANO_BIN agent-event stopped }".into());
            script.push(
                "Remove-Item -ErrorAction SilentlyContinue Env:SOPRANO_AGENT_PROFILE, \
                 Env:SOPRANO_AGENT_NAME, Env:SOPRANO_RESUME_SESSION_ID"
                    .into(),
            );
            powershell_argv(ctx, &script.join("; "))
        }
    }
}

/// `<shell> -NoLogo -NoExit -Command <script>`: the profile loads (PowerShell's "login"),
/// and the shell stays once the script ends.
fn powershell_argv(ctx: &LaunchContext, script: &str) -> Vec<String> {
    vec![ctx.login_shell.clone(), "-NoLogo".into(), "-NoExit".into(), "-Command".into(), script.into()]
}

fn join_quoted(values: &[String], quote: fn(&str) -> String) -> String {
    values.iter().map(|v| quote(v)).collect::<Vec<_>>().join(" ")
}

fn expand(ctx: &LaunchContext, path: &str) -> PathBuf {
    soprano_platform::paths::expand_tilde_in(path, &ctx.home)
}

/// The app's environment without another pane's identity.
fn inherited_env(ctx: &LaunchContext) -> BTreeMap<String, String> {
    let mut env = ctx.base_env.clone();
    for key in PANE_IDENTITY_KEYS {
        env.remove(key);
    }
    env
}

/// `TerminalConfig` before the surface scoped it to its pane.
#[derive(Default)]
struct RawConfig {
    /// `None`: the login shell (Ghostty's default command).
    argv: Option<Vec<String>>,
    cwd: Option<PathBuf>,
    env: BTreeMap<String, String>,
    initial_input: Option<String>,
}

impl RawConfig {
    /// `TerminalSurfaceView.scopedConfig` plus what Ghostty added when spawning.
    fn finish(mut self, ctx: &LaunchContext, pane_id: &str, tab_id: &str) -> LaunchSpec {
        self.env.insert("SOPRANO_BIN".into(), ctx.soprano_bin.clone());
        self.env.insert("SOPRANO_APP_PID".into(), ctx.app_pid.to_string());
        self.env.insert("SOPRANO_PANE_ID".into(), pane_id.into());
        self.env.insert("SOPRANO_TAB_ID".into(), tab_id.into());
        self.env.insert("TERM_PROGRAM".into(), "Soprano".into());
        if let Some(socket) = &ctx.socket {
            self.env.insert("SOPRANO_SOCKET".into(), socket.clone());
        }
        if let Some(cli_dir) = cli_dir(ctx) {
            let inherited = self
                .env
                .get("PATH")
                .or_else(|| ctx.base_env.get("PATH"))
                .cloned()
                .unwrap_or_else(|| DEFAULT_PATH.into());
            let path = if inherited.split(LIST_SEPARATOR).any(|entry| entry == cli_dir) {
                inherited
            } else {
                format!("{cli_dir}{LIST_SEPARATOR}{inherited}")
            };
            self.env.insert("PATH".into(), path);
        }

        let mut env = inherited_env(ctx);
        env.extend(self.env);
        apply_terminal_environment(&mut env, &ctx.resources, &ctx.app_version);

        let argv = self.argv.unwrap_or_else(|| login_shell_argv(&ctx.login_shell));
        let argv = apply_shell_integration(argv, &mut env, ctx.resources.ghostty_resources_dir(), &ctx.home);
        LaunchSpec { argv, cwd: self.cwd, env, initial_input: self.initial_input, wait_after_command: true }
    }
}

/// Soprano's CLI folder for PATH: the packaged `bin/` holding `soprano`, else (a build run
/// from its target folder) the folder of the `soprano` executable itself.
fn cli_dir(ctx: &LaunchContext) -> Option<String> {
    if let Some(dir) = ctx.resources.cli_dir() {
        return Some(path_string(&dir));
    }
    let bin = std::path::Path::new(&ctx.soprano_bin);
    let stem = bin.file_stem()?.to_string_lossy();
    (stem == "soprano").then(|| bin.parent().map(path_string)).flatten().filter(|d| !d.is_empty())
}

/// The interactive login shell a plain pane runs.
pub fn login_shell_argv(shell: &str) -> Vec<String> {
    match ShellFlavor::of(shell) {
        ShellFlavor::PowerShell => vec![shell.into(), "-NoLogo".into()],
        // elvish has no login mode.
        ShellFlavor::Posix if soprano_platform::shell::shell_name(shell) == "elvish" => vec![shell.into()],
        ShellFlavor::Posix => vec![shell.into(), "-l".into()],
    }
}
