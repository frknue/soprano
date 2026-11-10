//! Panes on a remote machine: the local command line, and the remote script run by a POSIX
//! shell as sshd would, against a temporary home.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use soprano_launch::{
    AgentRequest, LaunchContext, LaunchSpec, Platform, RemoteProgram, RemoteTarget, Resources,
    ShellIntegrationConfig,
};
use soprano_types::{DefaultAgents, Machine};

fn context() -> LaunchContext {
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources");
    LaunchContext {
        soprano_bin: "/opt/soprano/bin/soprano".into(),
        app_pid: 4242,
        socket: None,
        app_version: "0.1.0".into(),
        login_shell: "/bin/zsh".into(),
        resources: Resources::at(Some(soprano_platform::paths::normalize(&resources))).without_ghostty(),
        base_env: BTreeMap::from([("SSH_AUTH_SOCK".into(), "/tmp/agent.sock".into())]),
        home: PathBuf::from("/home/me"),
        platform: Platform::Unix,
        shell_integration: ShellIntegrationConfig::default(),
    }
}

fn machine() -> Machine {
    Machine {
        name: "vps".into(),
        destination: "me@vps.example".into(),
        ssh_args: vec!["-p".into(), "2222".into()],
        directory: Some("~/code".into()),
    }
}

/// Runs the script ssh would hand the remote login shell, without tmux.
fn run_remotely(spec: &LaunchSpec, home: &Path) -> std::process::Output {
    let script = spec.argv.last().expect("remote command");
    Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .env_clear()
        .env("HOME", home)
        .env("SHELL", "/bin/sh")
        .env("PATH", "/usr/bin:/bin")
        .env("SOPRANO_TMUX", home.join("no-tmux"))
        .stdin(std::process::Stdio::null())
        .output()
        .expect("runs")
}

#[test]
fn a_remote_pane_runs_ssh_through_the_reconnecting_loop_with_a_portable_terminal() {
    let machine = machine();
    let target =
        RemoteTarget { machine: &machine, directory: None, session: "soprano-k-tab-2", generation: None };
    let spec = LaunchSpec::remote(&context(), target, RemoteProgram::Shell, "pane-1", "tab-2");

    let (wrapper, ssh) = spec.argv.split_at(5);
    assert_eq!(wrapper, ["/opt/soprano/bin/soprano", "remote-attach", "--machine", "vps", "--"]);
    assert_eq!(ssh[..2], ["ssh", "-t"]);
    // Connections to the machine are shared, so a password typed once serves later ones.
    assert!(ssh.iter().any(|arg| arg == "ControlMaster=auto"));
    assert!(ssh.iter().any(|arg| arg.starts_with("ControlPath=/tmp/soprano-ssh-") && arg.ends_with("/%C")));
    // The machine's own options come right before its destination, then the remote command.
    let end = ssh.len();
    assert_eq!(ssh[end - 5..end - 1], ["-p", "2222", "--", "me@vps.example"]);
    assert!(ssh[end - 1].starts_with("exec /bin/sh -c "));
    assert_eq!(spec.env.get("TERM").map(String::as_str), Some("xterm-256color"));
    // ssh still finds the user's agent.
    assert_eq!(spec.env.get("SSH_AUTH_SOCK").map(String::as_str), Some("/tmp/agent.sock"));
}

#[test]
fn the_remote_script_installs_the_helper_once_and_hooks_report_through_it() {
    let home = tempfile::tempdir().expect("home");
    let code = home.path().join("code");
    std::fs::create_dir(&code).expect("code dir");
    let machine = machine();
    let session = soprano_launch::remote_session_name("k1", "tab:2");
    assert_eq!(session, "soprano-k1-tab-2");
    let target = RemoteTarget { machine: &machine, directory: None, session: &session, generation: None };
    // What a hook does: report through $SOPRANO_BIN, from the pane's folder.
    let command = [
        "sh".to_owned(),
        "-c".to_owned(),
        "pwd > \"$HOME/pwd\"; \"$SOPRANO_BIN\" agent-event needs-input --reason approval --title 'Claude Code' --body 'Approve?'"
            .to_owned(),
    ];
    let spec = LaunchSpec::remote(&context(), target, RemoteProgram::Command(&command), "pane-1", "tab:2");

    let output = run_remotely(&spec, home.path());
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(String::from_utf8_lossy(&output.stdout).contains("tmux is not installed"));
    assert_eq!(std::fs::read_to_string(home.path().join("pwd")).expect("pwd").trim(), code.to_string_lossy());

    // The report the next attach replays: OSC 7501 with the agent's words in base64.
    let state = std::fs::read_to_string(home.path().join(".soprano/state/soprano-k1-tab-2")).expect("state");
    assert_eq!(
        state,
        "\x1b]7501;state=blocked:kind=permission:title=Q2xhdWRlIENvZGU=:msg=QXBwcm92ZT8=\x1b\\"
    );

    let installed: Vec<PathBuf> = std::fs::read_dir(home.path().join(".soprano"))
        .expect("installed")
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.file_name().is_some_and(|name| name != "state"))
        .collect();
    assert_eq!(installed.len(), 3, "the helper, the tmux settings and the agent kit");
    let helper = installed.iter().map(|dir| dir.join("soprano")).find(|path| path.exists()).expect("helper");
    use std::os::unix::fs::PermissionsExt;
    assert_ne!(std::fs::metadata(&helper).expect("helper").permissions().mode() & 0o111, 0);

    // A second attach reuses what is there and leaves no partial copies behind.
    let count =
        || -> usize { installed.iter().map(|dir| std::fs::read_dir(dir).expect("dir").count()).sum() };
    let before = count();
    let again = run_remotely(&spec, home.path());
    assert!(again.status.success());
    assert_eq!(count(), before);
    // Copies are written as `<name>.<pid>` and renamed into place: none is left over.
    let leftovers: Vec<String> = installed
        .iter()
        .flat_map(|dir| std::fs::read_dir(dir).expect("dir"))
        .map(|entry| entry.expect("entry").file_name().to_string_lossy().into_owned())
        .filter(|name| {
            name.rsplit_once('.').is_some_and(|(_, suffix)| suffix.bytes().all(|b| b.is_ascii_digit()))
        })
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

/// Installs everything a pane on a machine uses into `home`; returns the helper and the
/// agent kit's folder.
fn install_kit(home: &Path) -> (PathBuf, PathBuf) {
    let machine = machine();
    let target =
        RemoteTarget { machine: &machine, directory: None, session: "soprano-k-tab-1", generation: None };
    let spec = LaunchSpec::remote(
        &context(),
        target,
        RemoteProgram::Command(&["true".to_owned()]),
        "pane-1",
        "tab-1",
    );
    let output = run_remotely(&spec, home);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let dirs: Vec<PathBuf> = std::fs::read_dir(home.join(".soprano"))
        .expect("installed")
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .collect();
    let helper = dirs.iter().map(|dir| dir.join("soprano")).find(|path| path.exists()).expect("helper");
    let kit = dirs.iter().find(|dir| dir.join("bashrc").exists()).expect("kit").clone();
    (helper, kit)
}

#[test]
fn agents_typed_on_a_machine_start_through_stand_ins_with_soprano_hooks() {
    let home = tempfile::tempdir().expect("home");
    let (helper, kit) = install_kit(home.path());
    // Fake agent CLIs that print what they were started with.
    let real = home.path().join("real-bin");
    std::fs::create_dir(&real).expect("bin");
    for name in ["claude", "codex"] {
        let path = real.join(name);
        std::fs::write(
            &path,
            "#!/bin/sh\necho \"PROFILE=$SOPRANO_AGENT_PROFILE\"\nfor a in \"$@\"; do echo \"ARG=$a\"; done\n",
        )
        .expect("fake");
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    }
    let run = |name: &str, extra: &[(&str, &str)]| {
        let mut command = Command::new("/bin/sh");
        command
            .arg(kit.join(name))
            .arg("hello")
            .env_clear()
            .env("HOME", home.path())
            .env("PATH", format!("{}:{}:/usr/bin:/bin", kit.display(), real.display()))
            .env("SOPRANO_BIN", &helper)
            .env("SOPRANO_TMUX_SESSION", "soprano-k-tab-1");
        for (key, value) in extra {
            command.env(key, value);
        }
        String::from_utf8(command.output().expect("runs").stdout).expect("utf8")
    };

    let claude = run("claude", &[]);
    assert!(claude.contains("PROFILE=claude-code"), "{claude}");
    assert!(claude.contains("ARG=--settings") && claude.contains("agent-event"), "{claude}");
    assert!(claude.trim_end().ends_with("ARG=hello"), "{claude}");
    let codex = run("codex", &[]);
    assert!(codex.contains("tui.notification_method=\"bel\""), "{codex}");
    // Started by Soprano with its hooks already: the stand-in steps aside.
    let tab = run("claude", &[("SOPRANO_AGENT_PROFILE", "claude-code")]);
    assert_eq!(tab, "PROFILE=claude-code\nARG=hello\n");
    // The agent's end clears the status the next attach would replay.
    assert!(!home.path().join(".soprano/state/soprano-k-tab-1").exists());
}

#[test]
fn bash_on_a_machine_puts_the_stand_ins_first_after_the_users_startup_files() {
    let home = tempfile::tempdir().expect("home");
    let (_, kit) = install_kit(home.path());
    std::fs::write(home.path().join(".profile"), "PATH=/user/first:$PATH; export PATH\n").expect("profile");
    let output = Command::new("/bin/bash")
        .args(["--rcfile"])
        .arg(kit.join("bashrc"))
        .args(["-i", "-c", "echo \"PATH=$PATH\""])
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", "/usr/bin:/bin")
        .env("SOPRANO_AGENT_BIN", &kit)
        .stdin(std::process::Stdio::null())
        .output()
        .expect("bash");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let path = stdout.lines().find_map(|line| line.strip_prefix("PATH=")).expect("PATH printed");
    assert!(path.starts_with(&format!("{}:/user/first:", kit.display())), "{path}");
}

#[test]
fn a_remote_agent_finds_its_integration_files_on_the_machine() {
    let home = tempfile::tempdir().expect("home");
    let machine = Machine::new("box");
    let omp = DefaultAgents::all().into_iter().find(|p| p.id == "omp").expect("omp");
    let request = AgentRequest::new(&omp, "pane-1", "tab-2");
    let spec = LaunchSpec::remote(
        &context(),
        RemoteTarget {
            machine: &machine,
            directory: Some("/nowhere"),
            session: "soprano-k-tab-2",
            generation: None,
        },
        RemoteProgram::Agent(&request),
        "pane-1",
        "tab-2",
    );
    assert_eq!(spec.argv[spec.argv.len() - 2], "box");

    // omp isn't installed here; the pane still starts, in the home folder, and the extension
    // the command line names is on disk.
    let output = run_remotely(&spec, home.path());
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let extension = std::fs::read_dir(home.path().join(".soprano"))
        .expect("installed")
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path().join("SopranoOmpExtension.js"))
        .find(|path| path.exists())
        .expect("extension installed");
    let relative = extension.strip_prefix(home.path()).expect("in home").to_string_lossy().into_owned();
    assert!(spec.argv.last().expect("script").contains(&relative.replacen(".soprano", "", 1)));
}
