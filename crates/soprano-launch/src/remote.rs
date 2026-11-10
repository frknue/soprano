//! Panes on a remote machine (`machines` in `settings.json`).
//!
//! The pane runs `soprano remote-attach -- ssh -t <machine> <script>`: that local loop
//! reconnects when the connection drops. The script installs Soprano's small helper in
//! `~/.soprano/` on the machine (content-addressed, so each version is copied once) and runs
//! the pane's program in a session of a private tmux server there, which keeps it running
//! while the laptop sleeps; every attach reconnects to the same session. Agent hooks call the
//! helper as `$SOPRANO_BIN`, and it reports their status in-band as OSC 7501, the only way
//! back to the app.
//!
//! Nothing on the machine needs setting up: shells start through the helper, which puts the
//! [`AgentKit`]'s stand-ins first on PATH, so agents typed there report too, without touching
//! the user's own agent configuration. Codex rings the bell for approvals there (tmux drops
//! OSC 9). Account choices (`CODEX_HOME`, omp's overlay) are local files and stay local;
//! OpenCode 2's terminal plugin would replace the remote `cli.json` plugins, so only
//! OpenCode 1.x reports.

use std::collections::BTreeMap;

use base64::Engine as _;
use soprano_types::Machine;

use crate::integrations::{
    CodexApprovalSignal, claude_integration_settings, codex_integration_arguments, opencode_config_content,
};
use crate::quote::shell_quoted;
use crate::spec::{AgentRequest, LaunchContext, LaunchSpec, RawConfig, launch_arguments};

/// Stands for `$HOME/.soprano` on the machine in words built here; [`remote_word`] expands it.
const REMOTE_DIR: &str = "@SOPRANO_REMOTE_DIR@";
const HELPER: &str = include_str!("remote/soprano.sh");
const TMUX_CONF: &str = include_str!("remote/tmux.conf");
/// A remote `$TERM` every machine has terminfo for (`xterm-ghostty` is rarely installed).
const REMOTE_TERM: &str = "xterm-256color";
/// The remote login shell: the helper sets `SHELL` to the account's (tmux would leave its
/// own default-shell there), so scripts the login shell runs need no `${…:-…}`, which fish
/// cannot parse.
const REMOTE_SHELL: &str = "\"$SHELL\"";

/// Where a remote pane runs.
#[derive(Clone, Copy, Debug)]
pub struct RemoteTarget<'a> {
    pub machine: &'a Machine,
    /// The remote folder (`~` allowed); the machine's `directory`, else home, when `None`.
    pub directory: Option<&'a str>,
    /// The tmux session keeping the program ([`remote_session_name`]).
    pub session: &'a str,
    /// Set on a restart: a program in that session started by anything but this restart ends
    /// first. Reconnects run the same command, so they attach to what the restart started.
    pub generation: Option<&'a str>,
}

/// What a remote pane runs.
#[derive(Clone, Copy, Debug)]
pub enum RemoteProgram<'a> {
    /// The remote login shell.
    Shell,
    /// A command in the login shell, which stays once it ends.
    Command(&'a [String]),
    Agent(&'a AgentRequest<'a>),
}

/// The tmux session that keeps a tab's program alive on its machine: `key` tells Soprano
/// sessions apart, the tab id the tabs within one.
pub fn remote_session_name(key: &str, tab_id: &str) -> String {
    let safe = |value: &str| -> String {
        value
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
            .collect()
    };
    format!("soprano-{}-{}", safe(key), safe(tab_id))
}

/// The command that ends a remote tab's program, run as `ssh <machine> <command>`. With
/// `stopped_at` (a stop, as a nanosecond time like a restart's generation), a program a
/// restart started after that moment keeps running, so a restart racing the stop survives.
pub fn remote_kill_command(session: &str, stopped_at: Option<&str>) -> String {
    let quoted = shell_quoted(session);
    let kill = format!(
        "tmux -L soprano kill-session -t ={quoted} 2>/dev/null; rm -f \"$HOME/.soprano/state/\"{quoted}"
    );
    let script = match stopped_at {
        None => kill,
        Some(stopped_at) => format!(
            "g=$(tmux -L soprano show-options -qv -t ={quoted}: @soprano_generation 2>/dev/null); \
             if [ -z \"$g\" ] || [ \"$g\" -lt {} ]; then {kill}; fi",
            shell_quoted(stopped_at)
        ),
    };
    format!("exec /bin/sh -c {}", shell_quoted(&format!("{TMUX_PATH}; {script}")))
}

/// What the helper adds to an ssh command's system PATH so tmux from Homebrew or Linuxbrew is
/// found (`remote/soprano.sh` does the same).
const TMUX_PATH: &str = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.nix-profile/bin\"; export PATH";

/// `ssh`'s arguments to `machine` before the remote command. Connections to a machine are
/// shared (`ControlMaster`): a password typed once in a pane also serves the commands Soprano
/// sends in the background, and later panes open at once.
pub fn ssh_arguments(machine: &Machine, interactive: bool) -> Vec<String> {
    let mut arguments = vec!["ssh".to_owned()];
    if interactive {
        arguments.push("-t".to_owned());
    } else {
        arguments.extend([
            "-o".to_owned(),
            "BatchMode=yes".to_owned(),
            "-o".to_owned(),
            "ConnectTimeout=10".to_owned(),
        ]);
    }
    arguments.extend(["-o".to_owned(), "ServerAliveInterval=10".to_owned()]);
    arguments.extend(["-o".to_owned(), "ServerAliveCountMax=3".to_owned()]);
    // A machine's first key is accepted, as typing "yes" would; a changed one still stops ssh.
    arguments.extend(["-o".to_owned(), "StrictHostKeyChecking=accept-new".to_owned()]);
    if let Some(dir) = control_dir() {
        arguments.extend([
            "-o".to_owned(),
            "ControlMaster=auto".to_owned(),
            "-o".to_owned(),
            format!("ControlPath={}/%C", dir.display()),
            "-o".to_owned(),
            "ControlPersist=60".to_owned(),
        ]);
    }
    arguments.extend(machine.ssh_args.iter().cloned());
    arguments.extend(["--".to_owned(), machine.destination().to_owned()]);
    arguments
}

/// Where shared ssh connections keep their sockets: a short private folder (socket paths are
/// limited to about 100 bytes), created on first use. `None` where ssh cannot share
/// connections (Windows) or when the folder belongs to someone else.
#[cfg(unix)]
fn control_dir() -> Option<std::path::PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let dir = std::path::PathBuf::from(format!("/tmp/soprano-ssh-{uid}"));
    let _ = std::fs::DirBuilder::new().mode(0o700).create(&dir);
    let meta = std::fs::symlink_metadata(&dir).ok()?;
    (meta.is_dir() && meta.uid() == uid && meta.permissions().mode() & 0o077 == 0).then_some(dir)
}

#[cfg(not(unix))]
fn control_dir() -> Option<std::path::PathBuf> {
    None
}

/// What [`check_machine`] found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MachineCheck {
    /// ssh logged in. `tmux` is its version (`tmux 3.4`), `None` when it is not installed:
    /// terminals there then end with their connection.
    Ready { tmux: Option<String>, system: String },
    /// ssh could not log in without asking (or at all): its last error line.
    Unreachable { message: String },
}

impl MachineCheck {
    /// One line for the UI.
    pub fn summary(&self) -> String {
        match self {
            Self::Ready { tmux: Some(tmux), system } => format!("Connected · {system} · {tmux}"),
            Self::Ready { tmux: None, system } => format!(
                "Connected · {system} · no tmux: terminals there end with the connection (install tmux to keep them)"
            ),
            Self::Unreachable { message } => message.clone(),
        }
    }
}

/// Logs in to `machine` without a terminal and asks what it has. Blocks for up to about ten
/// seconds: call it off the UI thread. A machine that needs a password answers once a pane
/// on it has logged in (connections are shared).
pub fn check_machine(machine: &Machine) -> MachineCheck {
    let probe = format!(
        "exec /bin/sh -c {}",
        shell_quoted(&format!(
            "{TMUX_PATH}; uname -s; command -v tmux >/dev/null 2>&1 && tmux -V || echo no-tmux"
        ))
    );
    let mut argv = ssh_arguments(machine, false);
    argv.push(probe);
    let output =
        std::process::Command::new(&argv[0]).args(&argv[1..]).stdin(std::process::Stdio::null()).output();
    let output = match output {
        Ok(output) => output,
        Err(error) => return MachineCheck::Unreachable { message: format!("Cannot run ssh: {error}") },
    };
    if !output.status.success() {
        let message = unreachable_message(&String::from_utf8_lossy(&output.stderr));
        return MachineCheck::Unreachable { message };
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut lines = stdout.lines().map(str::trim).filter(|line| !line.is_empty());
    let system = match lines.next() {
        Some("Darwin") => "macOS".to_owned(),
        Some(other) => other.to_owned(),
        None => "unknown system".to_owned(),
    };
    let tmux = lines.next().filter(|line| *line != "no-tmux").map(str::to_owned);
    MachineCheck::Ready { tmux, system }
}

/// ssh's last error line, with what to do about the common ones.
fn unreachable_message(stderr: &str) -> String {
    let last = stderr.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("ssh failed").trim();
    if last.contains("Permission denied") {
        format!("{last}. Add your ssh key there (ssh-copy-id), or open a terminal on it and log in once.")
    } else if last.contains("Host key verification failed") {
        format!(
            "{last} The machine's key differs from the one ~/.ssh/known_hosts remembers. If the machine \
             was reinstalled, remove the old key with ssh-keygen -R <host>."
        )
    } else {
        last.to_owned()
    }
}

impl LaunchSpec {
    /// A pane on `target.machine` (see the module docs).
    pub fn remote(
        ctx: &LaunchContext,
        target: RemoteTarget<'_>,
        program: RemoteProgram<'_>,
        pane_id: &str,
        tab_id: &str,
    ) -> Self {
        let helper = RemoteFile::new("soprano", HELPER.as_bytes().to_vec());
        let tmux_conf = RemoteFile::new("tmux.conf", TMUX_CONF.as_bytes().to_vec());
        let kit = AgentKit::new(ctx);
        let session = target.session.to_owned();
        let mut files = vec![helper.clone(), tmux_conf.clone()];

        let mut env = BTreeMap::new();
        env.insert("SOPRANO_PANE_ID".to_owned(), pane_id.to_owned());
        env.insert("SOPRANO_TAB_ID".to_owned(), tab_id.to_owned());
        env.insert("SOPRANO_BIN".to_owned(), helper.path());
        env.insert("SOPRANO_AGENT_BIN".to_owned(), kit.dir.clone());
        env.insert("SOPRANO_TMUX_SESSION".to_owned(), session.clone());
        env.insert("TERM_PROGRAM".to_owned(), "Soprano".to_owned());
        env.insert("TERM_PROGRAM_VERSION".to_owned(), ctx.app_version.clone());
        env.insert("COLORTERM".to_owned(), "truecolor".to_owned());

        // The login shell, with the agent stand-ins on PATH (the helper's `shell`).
        let login = "exec \"$SOPRANO_BIN\" shell".to_owned();
        let start = match program {
            RemoteProgram::Shell => login,
            RemoteProgram::Command(arguments) => {
                let script = ["trap true INT".to_owned(), join_words(arguments), login].join("; ");
                format!("exec {REMOTE_SHELL} -lic {}", shell_quoted(&script))
            }
            RemoteProgram::Agent(request) => {
                let command = agent_command(request, &kit, &mut env);
                let script = [
                    "trap true INT".to_owned(),
                    command,
                    "test -z \"$SOPRANO_BIN\" || \"$SOPRANO_BIN\" agent-event stopped".to_owned(),
                    "unset SOPRANO_AGENT_PROFILE SOPRANO_AGENT_NAME SOPRANO_RESUME_SESSION_ID".to_owned(),
                    login,
                ]
                .join("; ");
                format!("exec {REMOTE_SHELL} -lic {}", shell_quoted(&script))
            }
        };
        files.extend(kit.files);

        // What the tmux session runs (with /bin/sh): the pane's variables, the terminal the
        // helper writes status reports to, then the program.
        let mut inner: Vec<String> = env
            .iter()
            .filter(|(key, _)| valid_variable(key))
            .map(|(key, value)| format!("export {key}={}", remote_word(value)))
            .collect();
        inner.push("SOPRANO_TTY=$(tty) && export SOPRANO_TTY || unset SOPRANO_TTY".to_owned());
        inner.push(start);
        let inner = inner.join("; ");

        let directory = target.directory.or(target.machine.directory.as_deref()).unwrap_or("~");
        let mut script: Vec<String> = files.iter().map(RemoteFile::install).collect();
        let generation =
            target.generation.map(|g| format!("--generation {} ", shell_quoted(g))).unwrap_or_default();
        script.push(format!(
            "exec /bin/sh {} attach {generation}{} {} {} {}",
            remote_word(&helper.path()),
            shell_quoted(&session),
            shell_quoted(directory),
            remote_word(&tmux_conf.path()),
            shell_quoted(&inner),
        ));
        // The remote login shell may be fish or csh: hand everything to sh in one word.
        let remote_command = format!("exec /bin/sh -c {}", shell_quoted(&script.join("; ")));

        let mut argv = vec![
            ctx.soprano_bin.clone(),
            "remote-attach".to_owned(),
            "--machine".to_owned(),
            target.machine.name.clone(),
            "--".to_owned(),
        ];
        argv.extend(ssh_arguments(target.machine, true));
        argv.push(remote_command);

        let raw = RawConfig { argv: Some(argv), ..RawConfig::default() };
        let mut spec = raw.finish(ctx, pane_id, tab_id);
        let term = ctx.platform.existing_key(&spec.env, "TERM").unwrap_or_else(|| "TERM".to_owned());
        ctx.platform.insert(&mut spec.env, term, REMOTE_TERM.to_owned());
        spec
    }
}

/// The agent's command line as remote shell words; adds its variables. Its hooks' files come
/// from the kit.
fn agent_command(request: &AgentRequest<'_>, kit: &AgentKit, env: &mut BTreeMap<String, String>) -> String {
    let profile = request.profile;
    let conversation = request.conversation.filter(|c| {
        soprano_types::AgentConversation::supports(&profile.id)
            && soprano_types::AgentConversation::valid_id(&c.id)
    });
    let profile_env = profile.env.clone().unwrap_or_default();
    env.extend(profile_env.clone());
    env.insert("SOPRANO_AGENT_PROFILE".into(), profile.id.clone());
    env.insert("SOPRANO_AGENT_NAME".into(), profile.name.clone());

    let mut arguments = match conversation {
        Some(c) => c.resume_arguments(&profile.id, &profile.args),
        None => profile.args.clone(),
    };
    if let Some(conversation) = conversation {
        env.insert("SOPRANO_RESUME_SESSION_ID".into(), conversation.id.clone());
    }
    match profile.id.as_str() {
        "codex" => {
            arguments.extend(codex_integration_arguments(&CODEX_TRAMPOLINE, CodexApprovalSignal::Bell))
        }
        "claude-code" => arguments.extend(["--settings".to_owned(), claude_integration_settings()]),
        "opencode" => {
            if let Some(plugin) = kit.path(OPENCODE_PLUGIN) {
                let launch = request.launch;
                let content = opencode_config_content(
                    &format!("file://{plugin}"),
                    launch.and_then(|l| l.model.as_deref()),
                    launch.map(|l| l.model_agents.as_slice()).unwrap_or_default(),
                    &profile_env,
                );
                if let Some(content) = content {
                    env.insert("OPENCODE_CONFIG_CONTENT".into(), content);
                }
            }
        }
        "omp" => {
            if let Some(extension) = kit.path(OMP_EXTENSION) {
                arguments.extend(["--extension".to_owned(), extension]);
            }
        }
        _ => {}
    }
    if let Some(launch) = request.launch {
        arguments.extend(launch_arguments(&profile.id, launch, conversation.is_none()));
    }
    match profile.launch_script.as_deref().filter(|s| !s.is_empty()) {
        // Typed into the shell locally; here it is the shell's command, so a reattach never
        // types it into the running program again.
        Some(script) => script.to_owned(),
        None => {
            let mut command = vec![profile.command.clone()];
            command.extend(arguments);
            join_words(&command)
        }
    }
}

/// Soprano's agent stand-ins on a machine, in one folder (`$SOPRANO_AGENT_BIN`) that the
/// helper's `shell` puts first on PATH once the shell's startup files have run: `claude`,
/// `codex`, `omp` and `opencode` typed in a terminal there find the real CLI and start it with
/// Soprano's hooks, so they report their status with no setup on the machine. The folder also
/// holds the shells' startup shims and the omp extension and OpenCode plugin, which agent
/// tabs started by Soprano use too.
struct AgentKit {
    files: Vec<RemoteFile>,
    dir: String,
}

/// Stands for the kit's folder inside a stand-in, which finds it at run time.
const KIT_DIR: &str = "@SOPRANO_KIT@";
const OMP_EXTENSION: &str = "SopranoOmpExtension.js";
const OPENCODE_PLUGIN: &str = "SopranoOpenCodePlugin.js";

impl AgentKit {
    fn new(ctx: &LaunchContext) -> Self {
        let resource = |path: Option<std::path::PathBuf>| path.and_then(|path| std::fs::read(path).ok());
        let mut contents: Vec<(String, Vec<u8>)> = vec![
            (".zshenv".into(), include_bytes!("remote/zshenv").to_vec()),
            ("bashrc".into(), include_bytes!("remote/bashrc").to_vec()),
        ];
        let omp_extension = resource(ctx.resources.omp_extension());
        let opencode_plugin = resource(ctx.resources.opencode_plugin());
        let has_omp_extension = omp_extension.is_some();
        let has_opencode_plugin = opencode_plugin.is_some();
        contents.extend(omp_extension.map(|content| (OMP_EXTENSION.to_owned(), content)));
        contents.extend(opencode_plugin.map(|content| (OPENCODE_PLUGIN.to_owned(), content)));

        for profile in soprano_types::DefaultAgents::all() {
            let command = profile.command.as_str();
            if command.is_empty() || command.contains('/') {
                continue;
            }
            let (setup, arguments) = match profile.id.as_str() {
                "claude-code" => {
                    (String::new(), join_words(&["--settings".to_owned(), claude_integration_settings()]))
                }
                "codex" => (
                    String::new(),
                    join_words(&codex_integration_arguments(&CODEX_TRAMPOLINE, CodexApprovalSignal::Bell)),
                ),
                "omp" if has_omp_extension => {
                    (String::new(), format!("--extension \"$self_dir/{OMP_EXTENSION}\""))
                }
                "opencode" if has_opencode_plugin => {
                    let plugin = format!("file://{KIT_DIR}/{OPENCODE_PLUGIN}");
                    let content =
                        opencode_config_content(&plugin, None, &[], &BTreeMap::new()).unwrap_or_default();
                    let setup = format!(
                        "if [ -z \"${{OPENCODE_CONFIG_CONTENT:-}}\" ]; then\n    \
                         OPENCODE_CONFIG_CONTENT=$(printf '%s' {} | sed \"s|{KIT_DIR}|$self_dir|g\")\n    \
                         export OPENCODE_CONFIG_CONTENT\nfi",
                        shell_quoted(&content)
                    );
                    (setup, String::new())
                }
                _ => continue,
            };
            contents.push((
                command.to_owned(),
                stand_in(command, &profile.id, &profile.name, &setup, &arguments).into_bytes(),
            ));
        }

        let mut hash_input = Vec::new();
        for (name, content) in &contents {
            hash_input.extend(name.as_bytes());
            hash_input.push(0);
            hash_input.extend(content);
        }
        let dir = format!("{REMOTE_DIR}/{:016x}", fnv1a(&hash_input));
        let files = contents
            .into_iter()
            .map(|(name, content)| RemoteFile { name, content, dir: dir.clone() })
            .collect();
        Self { files, dir }
    }

    /// The kit's copy of `name`, when Soprano's resources have it.
    fn path(&self, name: &str) -> Option<String> {
        self.files.iter().find(|file| file.name == name).map(RemoteFile::path)
    }
}

/// How Codex on a machine runs `soprano agent-event`: sh finds the helper through
/// `$SOPRANO_BIN`.
const CODEX_TRAMPOLINE: [&str; 4] = ["sh", "-c", "exec \"$SOPRANO_BIN\" \"$@\"", "soprano"];

/// The stand-in script for `command` (see [`AgentKit`]).
fn stand_in(command: &str, profile_id: &str, name: &str, setup: &str, arguments: &str) -> String {
    format!(
        r#"#!/bin/sh
# Soprano's stand-in for `{command}` on this machine: starts the real one with Soprano's hooks so
# it reports its status, and steps aside when Soprano already started it that way.
self_dir=$(cd "$(dirname "$0")" && pwd -P)
real=
saved_ifs=$IFS
IFS=:
set -f
for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ "$(cd "$dir" 2>/dev/null && pwd -P)" = "$self_dir" ] && continue
    if [ -f "$dir/{command}" ] && [ -x "$dir/{command}" ]; then
        real=$dir/{command}
        break
    fi
done
set +f
IFS=$saved_ifs
if [ -z "$real" ]; then
    echo "{command}: command not found" >&2
    exit 127
fi
if [ -n "${{SOPRANO_AGENT_PROFILE:-}}" ] || [ -z "${{SOPRANO_BIN:-}}" ]; then
    exec "$real" "$@"
fi
SOPRANO_AGENT_PROFILE={profile_id}
SOPRANO_AGENT_NAME={name}
export SOPRANO_AGENT_PROFILE SOPRANO_AGENT_NAME
{setup}
"$SOPRANO_BIN" agent-event ready >/dev/null 2>&1
"$real" {arguments} "$@"
status=$?
"$SOPRANO_BIN" agent-event stopped >/dev/null 2>&1
exit $status
"#,
        profile_id = shell_quoted(profile_id),
        name = shell_quoted(name),
    )
}

/// A file Soprano keeps in `~/.soprano/<content hash>/<name>` on the machine.
#[derive(Clone, Debug)]
struct RemoteFile {
    name: String,
    content: Vec<u8>,
    /// `~/.soprano/<hash>`: of this file alone, or of the [`AgentKit`] it belongs to.
    dir: String,
}

impl RemoteFile {
    fn new(name: &str, content: Vec<u8>) -> Self {
        let dir = format!("{REMOTE_DIR}/{:016x}", fnv1a(&content));
        Self { name: name.to_owned(), content, dir }
    }

    fn directory(&self) -> String {
        self.dir.clone()
    }

    fn path(&self) -> String {
        format!("{}/{}", self.dir, self.name)
    }

    /// Writes the file unless that version is already there; a partial copy never takes its
    /// place.
    fn install(&self) -> String {
        let path = remote_word(&self.path());
        let data = base64::engine::general_purpose::STANDARD.encode(&self.content);
        format!(
            "[ -f {path} ] || {{ mkdir -p {dir} && printf %s '{data}' | base64 -d > {path}.$$ && chmod 755 {path}.$$ \
             && mv -f {path}.$$ {path}; }} || {{ echo 'Soprano: cannot install its helper in ~/.soprano' >&2; exit 1; }}",
            dir = remote_word(&self.directory()),
        )
    }
}

/// 64-bit FNV-1a: a version tag for remote files, stable across builds.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, b| (hash ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3))
}

/// One POSIX shell word for `value`, with [`REMOTE_DIR`] expanded by the remote shell.
fn remote_word(value: &str) -> String {
    if !value.contains(REMOTE_DIR) {
        return shell_quoted(value);
    }
    value
        .split(REMOTE_DIR)
        .enumerate()
        .flat_map(|(i, piece)| {
            let dir = (i > 0).then(|| "\"$HOME/.soprano\"".to_owned());
            dir.into_iter().chain((!piece.is_empty()).then(|| shell_quoted(piece)))
        })
        .collect()
}

fn join_words(values: &[String]) -> String {
    values.iter().map(|v| remote_word(v)).collect::<Vec<_>>().join(" ")
}

fn valid_variable(key: &str) -> bool {
    let mut chars = key.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_words_expand_the_soprano_folder_and_quote_the_rest() {
        assert_eq!(remote_word("it's"), r"'it'\''s'");
        assert_eq!(remote_word("@SOPRANO_REMOTE_DIR@/ab/x.js"), "\"$HOME/.soprano\"'/ab/x.js'");
        assert_eq!(remote_word("file://@SOPRANO_REMOTE_DIR@"), "'file://'\"$HOME/.soprano\"");
    }

    #[test]
    fn session_names_hold_only_what_tmux_accepts() {
        assert_eq!(remote_session_name("k:1", "tab.2"), "soprano-k-1-tab-2");
    }

    #[test]
    fn ssh_accepts_a_new_machines_key_and_explains_a_changed_one() {
        let args = ssh_arguments(&Machine::new("vps"), false);
        assert!(args.iter().any(|arg| arg == "StrictHostKeyChecking=accept-new"));
        let changed = unreachable_message(
            "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.\n",
        );
        assert!(changed.contains("ssh-keygen -R"), "{changed}");
        let denied = unreachable_message("me@vps: Permission denied (publickey).\n");
        assert!(denied.contains("ssh-copy-id"), "{denied}");
    }
}
