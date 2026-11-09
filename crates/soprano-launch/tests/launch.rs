//! Agent and terminal launches (ported from `AgentConversationTests`, `AccountLaunchTests`,
//! `AgentWaitingReasonTests`, `AutomationControllerTests`, `SopranoConfigTests`), plus golden
//! command lines and environments for every built-in agent.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::Value;
use soprano_launch::integrations::{opencode_cli_config_content, opencode_config_content};
use soprano_launch::{
    AccountAdjustments, AgentRequest, LaunchContext, LaunchSpec, Platform, Resources, ShellFeatures,
    ShellIntegrationConfig, ShellIntegrationMode, launch_arguments,
};
use soprano_types::{AgentConversation, AgentLaunch, AgentProfile, DefaultAgents};

const BIN: &str = "/opt/soprano/bin/soprano";

fn resources_root() -> PathBuf {
    soprano_platform::paths::normalize(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources"))
}

fn bundle() -> String {
    resources_root().join("Soprano_Soprano.bundle").to_string_lossy().into_owned()
}

/// The repository's resources without Ghostty's integration, as the Swift tests saw a
/// `TerminalConfig` before Ghostty spawned it.
fn context(login_shell: &str) -> LaunchContext {
    LaunchContext {
        soprano_bin: BIN.into(),
        app_pid: 4242,
        socket: Some("/tmp/soprano-dev.sock".into()),
        app_version: "0.1.0".into(),
        login_shell: login_shell.into(),
        resources: Resources::at(Some(resources_root())).without_ghostty(),
        base_env: BTreeMap::new(),
        home: PathBuf::from("/home/me"),
        platform: Platform::Unix,
        shell_integration: ShellIntegrationConfig::default(),
    }
}

fn agent(profile: &AgentProfile, conversation: Option<&AgentConversation>) -> LaunchSpec {
    let mut request = AgentRequest::new(profile, "pane-1", "tab-2");
    request.conversation = conversation;
    LaunchSpec::for_agent(&context("/bin/zsh"), &request)
}

fn command(spec: &LaunchSpec) -> String {
    spec.argv.join(" ")
}

fn fallback() -> String {
    format!(
        "if [[ ${{(t)ZDOTDIR}} == *export* ]]; then export SOPRANO_ZSH_ZDOTDIR=\"$ZDOTDIR\"; \
         else unset SOPRANO_ZSH_ZDOTDIR; fi; ZDOTDIR='{}/SopranoZsh' exec '/bin/zsh' -l",
        bundle()
    )
}

fn tail() -> String {
    format!(
        "test -z \"$SOPRANO_BIN\" || \"$SOPRANO_BIN\" agent-event stopped; \
         unset SOPRANO_AGENT_PROFILE SOPRANO_AGENT_NAME SOPRANO_RESUME_SESSION_ID; {}",
        fallback()
    )
}

const CODEX_HOOKS: &str = "'-c' 'notify=[\"/opt/soprano/bin/soprano\",\"agent-event\",\"needs-input\",\"--notify\",\
     \"--title\",\"Codex\",\"--body\",\"Response ready\"]' '-c' 'tui.notifications=[\"approval-requested\"]' \
     '-c' 'tui.notification_method=\"osc9\"' '-c' 'tui.notification_condition=\"always\"'";

fn claude_settings() -> String {
    soprano_launch::integrations::claude_integration_settings()
}

fn env_of(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// What every pane carries.
fn pane_env(extra: &[(&str, &str)]) -> BTreeMap<String, String> {
    let mut env = env_of(&[
        ("COLORTERM", "truecolor"),
        ("GHOSTTY_SHELL_FEATURES", "cursor:blink,path,title"),
        ("PATH", "/opt/soprano/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
        ("SOPRANO_APP_PID", "4242"),
        ("SOPRANO_BIN", BIN),
        ("SOPRANO_PANE_ID", "pane-1"),
        ("SOPRANO_SOCKET", "/tmp/soprano-dev.sock"),
        ("SOPRANO_TAB_ID", "tab-2"),
        ("TERM", "xterm-256color"),
        ("TERM_PROGRAM", "Soprano"),
        ("TERM_PROGRAM_VERSION", "0.1.0"),
    ]);
    env.extend(env_of(extra));
    env
}

// MARK: Golden launches

#[test]
fn codex_starts_through_the_login_shell_with_its_notify_and_approval_hooks() {
    let spec = agent(&DefaultAgents::codex(), None);
    assert_eq!(
        spec.argv,
        vec![
            "/bin/zsh".to_owned(),
            "-lic".into(),
            format!("trap true INT; 'codex' {CODEX_HOOKS}; {}", tail())
        ]
    );
    assert_eq!(spec.env, pane_env(&[("SOPRANO_AGENT_PROFILE", "codex"), ("SOPRANO_AGENT_NAME", "Codex")]));
    assert_eq!(spec.cwd, None);
    assert_eq!(spec.initial_input, None);
    assert!(spec.wait_after_command);
}

#[test]
fn a_resumed_codex_automation_in_a_chosen_account_keeps_its_autonomy_but_not_its_prompt() {
    let profile = DefaultAgents::codex();
    let conversation =
        AgentConversation { cwd: Some("/tmp/repo".into()), ..AgentConversation::new("saved-chat") };
    let launch = AgentLaunch {
        prompt: "Audit".into(),
        model: Some("gpt-5".into()),
        skips_approvals: true,
        ..Default::default()
    };
    let accounts =
        AccountAdjustments { environment: env_of(&[("CODEX_HOME", "/acc/codex")]), arguments: vec![] };
    let mut request = AgentRequest::new(&profile, "pane-1", "tab-2");
    request.conversation = Some(&conversation);
    request.launch = Some(&launch);
    request.accounts = &accounts;
    let spec = LaunchSpec::for_agent(&context("/bin/zsh"), &request);
    assert_eq!(
        spec.argv[2],
        format!(
            "trap true INT; export CODEX_HOME='/acc/codex'; 'codex' 'resume' 'saved-chat' {CODEX_HOOKS} \
             '--model' 'gpt-5' '--dangerously-bypass-approvals-and-sandbox'; {}",
            tail()
        )
    );
    assert_eq!(
        spec.env,
        pane_env(&[
            ("SOPRANO_AGENT_PROFILE", "codex"),
            ("SOPRANO_AGENT_NAME", "Codex"),
            ("SOPRANO_RESUME_SESSION_ID", "saved-chat"),
            ("CODEX_HOME", "/acc/codex"),
            ("PWD", "/tmp/repo"),
        ])
    );
    assert_eq!(spec.cwd.as_deref(), Some(Path::new("/tmp/repo")));
}

#[test]
fn claude_code_gets_its_hooks_as_launch_scoped_settings_and_an_automation_prompt_after_the_options() {
    let profile = DefaultAgents::claude_code();
    let launch = AgentLaunch {
        prompt: "  Fix it\n".into(),
        model: Some("opus".into()),
        skips_approvals: true,
        ..Default::default()
    };
    let mut request = AgentRequest::new(&profile, "pane-1", "tab-2");
    request.launch = Some(&launch);
    let spec = LaunchSpec::for_agent(&context("/bin/zsh"), &request);
    assert_eq!(
        spec.argv[2],
        format!(
            "trap true INT; 'claude' '--settings' '{}' '--model' 'opus' '--dangerously-skip-permissions' \
             '--' 'Fix it'; {}",
            claude_settings(),
            tail()
        )
    );
    assert_eq!(
        spec.env,
        pane_env(&[("SOPRANO_AGENT_PROFILE", "claude-code"), ("SOPRANO_AGENT_NAME", "Claude Code")])
    );

    let resumed = agent(&profile, Some(&AgentConversation::new("saved-chat")));
    assert_eq!(
        resumed.argv[2],
        format!(
            "trap true INT; 'claude' '--resume' 'saved-chat' '--settings' '{}'; {}",
            claude_settings(),
            tail()
        )
    );
}

#[test]
fn opencode_loads_both_plugins_from_its_environment_and_takes_the_run_model_inline() {
    let profile = DefaultAgents::open_code();
    let launch = AgentLaunch {
        prompt: "Do it".into(),
        model: Some("a/b".into()),
        skips_approvals: true,
        starts_private_server: true,
        model_agents: vec!["build".into()],
    };
    let mut request = AgentRequest::new(&profile, "pane-1", "tab-2");
    request.launch = Some(&launch);
    let spec = LaunchSpec::for_agent(&context("/bin/zsh"), &request);
    assert_eq!(
        spec.argv[2],
        format!("trap true INT; 'opencode' '--standalone' '--auto' '--prompt=Do it'; {}", tail())
    );
    let plugin_url = format!("file://{}/SopranoOpenCodePlugin.js", bundle());
    assert_eq!(
        spec.env,
        pane_env(&[
            ("SOPRANO_AGENT_PROFILE", "opencode"),
            ("SOPRANO_AGENT_NAME", "Open Code"),
            (
                "OPENCODE_CONFIG_CONTENT",
                &format!(
                    r#"{{"plugin":["{plugin_url}"],"model":"a/b","agents":{{"build":{{"model":"a/b"}}}}}}"#
                ),
            ),
            ("OPENCODE_CLI_CONFIG_CONTENT", &format!(r#"{{"plugins":["{}/SopranoOpenCode"]}}"#, bundle())),
        ])
    );

    let resumed = agent(&profile, Some(&AgentConversation::new("saved-chat")));
    assert_eq!(resumed.argv[2], format!("trap true INT; 'opencode' '--session' 'saved-chat'; {}", tail()));
}

#[test]
fn omp_gets_its_extension_and_the_accounts_preference_overlay() {
    let profile = DefaultAgents::omp();
    let conversation = AgentConversation::new("saved-chat");
    let launch = AgentLaunch {
        prompt: "Go".into(),
        model: Some("x".into()),
        skips_approvals: true,
        ..Default::default()
    };
    let accounts = AccountAdjustments {
        environment: BTreeMap::new(),
        arguments: vec!["--config".into(), "/acc/omp.yml".into()],
    };
    let mut request = AgentRequest::new(&profile, "pane-1", "tab-2");
    request.conversation = Some(&conversation);
    request.launch = Some(&launch);
    request.accounts = &accounts;
    let spec = LaunchSpec::for_agent(&context("/bin/zsh"), &request);
    assert_eq!(
        spec.argv[2],
        format!(
            "trap true INT; 'omp' '--resume' 'saved-chat' '--extension' '{}/SopranoOmpExtension.js' \
             '--config' '/acc/omp.yml' '--model=x' '--auto-approve'; {}",
            bundle(),
            tail()
        )
    );
    assert_eq!(
        spec.env,
        pane_env(&[
            ("SOPRANO_AGENT_PROFILE", "omp"),
            ("SOPRANO_AGENT_NAME", "omp"),
            ("SOPRANO_RESUME_SESSION_ID", "saved-chat"),
        ])
    );

    let fresh = agent(&profile, None);
    assert_eq!(
        fresh.argv[2],
        format!("trap true INT; 'omp' '--extension' '{}/SopranoOmpExtension.js'; {}", bundle(), tail())
    );
}

#[test]
fn a_plain_terminal_is_the_login_shell_with_the_pane_identity_only() {
    let spec = LaunchSpec::default_shell(&context("/bin/zsh"), Some("~/repo"), "pane-1", "tab-2");
    assert_eq!(spec.argv, vec!["/bin/zsh", "-l"]);
    assert_eq!(spec.env, pane_env(&[("PWD", "/home/me/repo")]));
    assert_eq!(spec.cwd.as_deref(), Some(Path::new("/home/me/repo")));
}

#[test]
fn a_command_pane_runs_the_command_then_stays_in_the_login_shell() {
    let spec =
        LaunchSpec::for_command(&context("/bin/zsh"), &["git".into(), "log".into()], None, "pane-1", "tab-2");
    assert_eq!(
        spec.argv,
        vec!["/bin/zsh".to_owned(), "-lic".into(), format!("trap true INT; 'git' 'log'; {}", fallback())]
    );
}

#[test]
fn a_bash_login_shell_falls_back_without_the_zsh_startup_files() {
    let spec = LaunchSpec::for_command(&context("/usr/local/bin/bash"), &["ls".into()], None, "p", "t");
    assert_eq!(spec.argv[2], "trap true INT; 'ls'; exec '/usr/local/bin/bash' -l");
}

#[test]
fn powershell_runs_the_agent_and_stays_open_afterwards() {
    let profile = DefaultAgents::codex();
    let accounts =
        AccountAdjustments { environment: env_of(&[("CODEX_HOME", r"C:\acc\it's")]), arguments: vec![] };
    let mut request = AgentRequest::new(&profile, "pane-1", "tab-2");
    request.accounts = &accounts;
    let spec = LaunchSpec::for_agent(&context("pwsh.exe"), &request);
    let hooks = CODEX_HOOKS.to_owned();
    assert_eq!(
        spec.argv,
        vec![
            "pwsh.exe".to_owned(),
            "-NoLogo".into(),
            "-NoExit".into(),
            "-Command".into(),
            format!(
                "$env:CODEX_HOME = 'C:\\acc\\it''s'; & 'codex' {hooks}; \
                 if ($env:SOPRANO_BIN) {{ & $env:SOPRANO_BIN agent-event stopped }}; \
                 Remove-Item -ErrorAction SilentlyContinue Env:SOPRANO_AGENT_PROFILE, Env:SOPRANO_AGENT_NAME, \
                 Env:SOPRANO_RESUME_SESSION_ID"
            ),
        ]
    );
    let shell = LaunchSpec::default_shell(&context("pwsh.exe"), None, "p", "t");
    assert_eq!(shell.argv, vec!["pwsh.exe", "-NoLogo"]);
}

#[test]
fn ghostty_shell_integration_and_the_app_environment_reach_the_pane() {
    let mut ctx = context("/bin/zsh");
    ctx.resources = Resources::at(Some(resources_root()));
    ctx.base_env = env_of(&[
        ("PATH", "/usr/bin:/bin"),
        ("ZDOTDIR", "/home/me/.config/zsh"),
        ("SOPRANO_AGENT_PROFILE", "codex"),
        ("LANG", "en_US.UTF-8"),
    ]);
    let spec = LaunchSpec::default_shell(&ctx, None, "p", "t");
    let ghostty = ctx.resources.ghostty_resources_dir().expect("ghostty").to_string_lossy().into_owned();
    assert_eq!(spec.env["GHOSTTY_RESOURCES_DIR"], ghostty);
    assert_eq!(spec.env["ZDOTDIR"], format!("{ghostty}/shell-integration/zsh"));
    assert_eq!(spec.env["GHOSTTY_ZSH_ZDOTDIR"], "/home/me/.config/zsh");
    assert_eq!(spec.env["PATH"], "/opt/soprano/bin:/usr/bin:/bin");
    assert_eq!(spec.env["LANG"], "en_US.UTF-8");
    // Another pane's agent identity never leaks into a plain shell.
    assert!(!spec.env.contains_key("SOPRANO_AGENT_PROFILE"));
}

#[test]
fn the_profiles_environment_wins_over_the_terminal_variables_and_shell_integration() {
    let mut ctx = context("/bin/zsh");
    ctx.resources = Resources::at(Some(resources_root()));
    ctx.base_env = env_of(&[("ZDOTDIR", "/home/me/.config/zsh"), ("PWD", "/somewhere/else")]);
    let profile = AgentProfile {
        env: Some(env_of(&[
            ("TERM", "xterm-kitty"),
            ("ZDOTDIR", "/profile/zsh"),
            ("TERM_PROGRAM_VERSION", "9"),
        ])),
        ..DefaultAgents::omp()
    };
    let mut request = AgentRequest::new(&profile, "p", "t");
    request.cwd = Some("/work/repo");
    let spec = LaunchSpec::for_agent(&ctx, &request);
    assert_eq!(spec.env["TERM"], "xterm-kitty");
    assert_eq!(spec.env["TERM_PROGRAM_VERSION"], "9");
    // Shell integration saw the inherited ZDOTDIR; the profile's then overrides it.
    assert_eq!(spec.env["ZDOTDIR"], "/profile/zsh");
    assert_eq!(spec.env["GHOSTTY_ZSH_ZDOTDIR"], "/home/me/.config/zsh");
    assert_eq!(spec.env["PWD"], "/work/repo");
}

#[test]
fn windows_prepends_the_cli_folder_to_the_existing_path_spelling() {
    let root = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir_all(root.path().join("bin")).expect("mkdir");
    std::fs::write(root.path().join("bin/soprano.cmd"), "@echo off\r\n").expect("write");
    let cli = root.path().join("bin").to_string_lossy().into_owned();

    let mut ctx = context("pwsh.exe");
    ctx.platform = Platform::Windows;
    ctx.resources = Resources::at(Some(root.path().to_path_buf()));
    ctx.base_env = env_of(&[("Path", r"C:\Windows;C:\Tools")]);
    let spec = LaunchSpec::default_shell(&ctx, None, "p", "t");
    assert_eq!(spec.env["Path"], format!(r"{cli};C:\Windows;C:\Tools"));
    assert!(!spec.env.contains_key("PATH"));

    // A profile's differently cased PATH replaces the inherited one instead of sitting beside it.
    let profile = AgentProfile { env: Some(env_of(&[("PATH", r"D:\bin")])), ..DefaultAgents::codex() };
    let spec = LaunchSpec::for_agent(&ctx, &AgentRequest::new(&profile, "p", "t"));
    assert_eq!(spec.env["PATH"], format!(r"{cli};D:\bin"));
    assert!(!spec.env.contains_key("Path"));

    // No Unix default when nothing sets a path.
    ctx.base_env = BTreeMap::new();
    let spec = LaunchSpec::default_shell(&ctx, None, "p", "t");
    assert_eq!(spec.env["PATH"], cli);
}

#[test]
fn the_terminal_settings_shape_the_shell_features_and_can_turn_integration_off() {
    let mut ctx = context("/bin/zsh");
    ctx.resources = Resources::at(Some(resources_root()));
    let mut features = ShellFeatures::default();
    features.apply("sudo");
    ctx.shell_integration =
        ShellIntegrationConfig { mode: ShellIntegrationMode::None, features, cursor_blink: Some(false) };
    let spec = LaunchSpec::default_shell(&ctx, None, "p", "t");
    assert_eq!(spec.env["GHOSTTY_SHELL_FEATURES"], "cursor:steady,path,sudo,title");
    assert!(!spec.env.contains_key("ZDOTDIR"));
    assert!(spec.env.contains_key("GHOSTTY_RESOURCES_DIR"));
}

#[cfg(unix)]
#[test]
fn a_variable_that_is_not_utf8_does_not_stop_a_pane_from_starting() {
    use std::os::unix::ffi::OsStringExt;
    let env = soprano_launch::spec::lossy_environment([(
        std::ffi::OsString::from("LATIN1"),
        std::ffi::OsString::from_vec(b"caf\xe9".to_vec()),
    )]);
    assert_eq!(env["LATIN1"], "caf\u{FFFD}");
}

// MARK: Ported Swift tests

#[test]
fn older_workspaces_still_open_fresh_agents_without_guessing_the_last_conversation() {
    let spec = agent(&DefaultAgents::codex(), None);
    assert!(!command(&spec).contains("'resume'"));
    assert!(!command(&spec).contains("'--last'"));
}

#[test]
fn resume_commands_target_the_saved_id_and_keep_model_options_and_hooks() {
    let conversation =
        AgentConversation { cwd: Some("/tmp/original repo".into()), ..AgentConversation::new("saved-chat") };
    for profile in [
        DefaultAgents::codex(),
        DefaultAgents::claude_code(),
        DefaultAgents::open_code(),
        DefaultAgents::omp(),
    ] {
        let mut request = AgentRequest::new(&profile, "pane-1", "tab-2");
        request.cwd = Some("/tmp/other");
        request.conversation = Some(&conversation);
        let spec = LaunchSpec::for_agent(&context("/bin/zsh"), &request);
        assert_eq!(spec.cwd.as_deref(), Some(Path::new("/tmp/original repo")));
        assert_eq!(spec.env["SOPRANO_RESUME_SESSION_ID"], "saved-chat");
        assert_eq!(spec.env["SOPRANO_PANE_ID"], "pane-1");
        assert_eq!(spec.env["SOPRANO_TAB_ID"], "tab-2");
        match profile.id.as_str() {
            "codex" => assert!(command(&spec).contains("notify=")),
            "claude-code" => assert!(command(&spec).contains("'--settings'")),
            "opencode" => {
                assert!(spec.env["OPENCODE_CONFIG_CONTENT"].contains("SopranoOpenCodePlugin"));
                assert!(spec.env["OPENCODE_CLI_CONFIG_CONTENT"].contains("SopranoOpenCode"));
            }
            _ => assert!(command(&spec).contains("'--extension'")),
        }
    }
    let strings = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let c = AgentConversation::new("saved-chat");
    assert_eq!(
        c.resume_arguments("codex", &strings(&["resume", "--last", "--model", "chosen-model"])),
        strings(&["resume", "saved-chat", "--model", "chosen-model"])
    );
    assert_eq!(
        c.resume_arguments("opencode", &strings(&["--continue", "--session", "old-chat", "--fork"])),
        strings(&["--session", "saved-chat"])
    );
}

#[test]
fn an_invalid_or_unsupported_conversation_is_not_resumed() {
    let spec = agent(&DefaultAgents::codex(), Some(&AgentConversation::new("--last")));
    assert!(!spec.env.contains_key("SOPRANO_RESUME_SESSION_ID"));
    assert!(!command(&spec).contains("'resume'"));
}

#[test]
fn opencode_terminal_plugins_from_cli_json_keep_loading_beside_sopranos_and_an_inherited_override_wins() {
    let home = tempfile::tempdir().expect("tempdir");
    let directory = home.path().join(".config/opencode");
    std::fs::create_dir_all(&directory).expect("mkdir");
    std::fs::write(
        directory.join("cli.json"),
        r#"{
          // Terminal-only plugins
          "plugins": ["-opencode.notifications", "./plugins/status", {"package": "../shared/review", "options": {"compact": true}}],
        }"#,
    )
    .expect("write");

    let plugins = |content: Option<String>| -> Vec<Value> {
        let object: Value = serde_json::from_str(&content.expect("content")).expect("json");
        object["plugins"].as_array().expect("plugins").clone()
    };
    let merged =
        plugins(opencode_cli_config_content("/Soprano/SopranoOpenCode", &BTreeMap::new(), home.path()));
    assert_eq!(merged.len(), 4);
    assert_eq!(merged[0], "-opencode.notifications");
    assert_eq!(merged[1], directory.join("plugins/status").to_string_lossy().as_ref());
    assert_eq!(merged[2]["package"], home.path().join(".config/shared/review").to_string_lossy().as_ref());
    assert_eq!(merged[2]["options"]["compact"], true);
    assert_eq!(merged[3], "/Soprano/SopranoOpenCode");

    let inherited = plugins(opencode_cli_config_content(
        "/Soprano/SopranoOpenCode",
        &env_of(&[(
            "OPENCODE_CLI_CONFIG_CONTENT",
            r#"{"plugins":["/Soprano/SopranoOpenCode"],"mouse":false}"#,
        )]),
        home.path(),
    ));
    assert_eq!(inherited, vec![Value::from("/Soprano/SopranoOpenCode")]);
}

#[test]
fn a_prompt_that_starts_like_an_option_is_passed_after_the_end_of_options() {
    let launch = AgentLaunch {
        prompt: "- check the PRs\n- report".into(),
        model: Some("opus".into()),
        skips_approvals: true,
        starts_private_server: true,
        model_agents: vec![],
    };
    assert_eq!(
        launch_arguments("claude-code", &launch, true),
        vec!["--model", "opus", "--dangerously-skip-permissions", "--", "- check the PRs\n- report"]
    );
    assert_eq!(
        launch_arguments("omp", &launch, true),
        vec!["--model=opus", "--auto-approve", "--", "- check the PRs\n- report"]
    );
    assert_eq!(
        launch_arguments("opencode", &launch, true),
        vec!["--standalone", "--auto", "--prompt=- check the PRs\n- report"]
    );
}

#[test]
fn a_resumed_run_keeps_its_autonomy_but_is_not_given_its_prompt_again() {
    let profile = DefaultAgents::codex();
    let launch =
        AgentLaunch { prompt: "Audit the repo.".into(), skips_approvals: true, ..Default::default() };
    let conversation =
        AgentConversation { cwd: Some("/tmp".into()), ..AgentConversation::new("0199a1b2-c3d4") };
    let mut request = AgentRequest::new(&profile, "pane-1", "tab-2");
    request.conversation = Some(&conversation);
    request.launch = Some(&launch);
    let command = command(&LaunchSpec::for_agent(&context("/bin/zsh"), &request));
    assert!(command.contains("--dangerously-bypass-approvals-and-sandbox"));
    assert!(command.contains("resume"));
    assert!(!command.contains("Audit the repo."));
}

#[test]
fn an_opencode_run_without_a_private_server_takes_only_its_prompt() {
    let launch =
        AgentLaunch { prompt: "Audit".into(), model: Some("anthropic/x".into()), ..Default::default() };
    assert_eq!(launch_arguments("opencode", &launch, true), vec!["--prompt=Audit"]);
}

#[test]
fn a_runs_model_is_pinned_on_every_agent_a_session_can_start_with_so_an_agents_own_model_cannot_win() {
    let content = opencode_config_content(
        "file:///Soprano/SopranoOpenCodePlugin.js",
        Some("b/requested"),
        &["build".into(), "review".into()],
        &env_of(&[("OPENCODE_CONFIG_CONTENT", r#"{"agents":{"build":{"temperature":0.2}}}"#)]),
    )
    .expect("content");
    let object: Value = serde_json::from_str(&content).expect("json");
    assert_eq!(object["model"], "b/requested");
    assert_eq!(object["agents"]["build"]["model"], "b/requested");
    assert_eq!(object["agents"]["build"]["temperature"], 0.2);
    assert_eq!(object["agents"]["review"]["model"], "b/requested");
    assert!(object["agents"].get("explore").is_none());
    assert_eq!(object["plugin"][0], "file:///Soprano/SopranoOpenCodePlugin.js");
}

#[test]
fn a_malformed_inherited_opencode_config_is_left_alone() {
    let mut ctx = context("/bin/zsh");
    ctx.base_env = env_of(&[("OPENCODE_CONFIG_CONTENT", "not json")]);
    let profile = DefaultAgents::open_code();
    let spec = LaunchSpec::for_agent(&ctx, &AgentRequest::new(&profile, "p", "t"));
    assert_eq!(spec.env["OPENCODE_CONFIG_CONTENT"], "not json");
}

#[test]
fn a_codex_pane_starts_in_the_chosen_accounts_home_even_if_the_shell_profile_sets_another() {
    let profile = DefaultAgents::codex();
    let accounts =
        AccountAdjustments { environment: env_of(&[("CODEX_HOME", "/acc/home")]), arguments: vec![] };
    let mut request = AgentRequest::new(&profile, "p", "t");
    request.accounts = &accounts;
    let spec = LaunchSpec::for_agent(&context("/bin/zsh"), &request);
    assert_eq!(spec.env["CODEX_HOME"], "/acc/home");
    // Exported again inside the -lic script, after the rc files ran.
    assert!(command(&spec).contains("export CODEX_HOME="));
}

#[test]
fn an_omp_pane_loads_the_preference_overlay_it_is_given() {
    let profile = DefaultAgents::omp();
    let before = LaunchSpec::for_agent(&context("/bin/zsh"), &AgentRequest::new(&profile, "p", "t"));
    assert!(!command(&before).contains("--config"));

    let accounts = AccountAdjustments {
        environment: BTreeMap::new(),
        arguments: vec!["--config".into(), "/acc/omp.yml".into()],
    };
    let mut request = AgentRequest::new(&profile, "p", "t");
    request.accounts = &accounts;
    let after = command(&LaunchSpec::for_agent(&context("/bin/zsh"), &request));
    assert!(after.contains("--config"));
    assert!(after.contains("/acc/omp.yml"));
}

#[test]
fn other_agents_start_untouched_by_account_choices() {
    let spec = agent(&DefaultAgents::claude_code(), None);
    assert!(!command(&spec).contains("--config"));
    assert!(!command(&spec).contains("CODEX_HOME"));
    assert!(!spec.env.contains_key("CODEX_HOME"));
}

#[test]
fn a_configured_launch_script_replaces_the_command() {
    let profile = AgentProfile {
        id: "aider".into(),
        command: "aider".into(),
        launch_script: Some("nvm use 22 && aider".into()),
        ..DefaultAgents::terminal()
    };
    let spec = agent(&profile, Some(&AgentConversation::new("ignored")));
    assert_eq!(spec.initial_input.as_deref(), Some("nvm use 22 && aider\n"));
    assert_eq!(spec.argv, vec!["/bin/zsh", "-l"]);
    // Only agents with resumable conversations get an id to resume.
    assert!(!spec.env.contains_key("SOPRANO_RESUME_SESSION_ID"));
}

// MARK: Running the launch command (zsh)

#[cfg(unix)]
mod running {
    use super::*;
    use std::process::{Command, Stdio};

    fn aider() -> AgentProfile {
        AgentProfile {
            id: "aider".into(),
            name: "Aider".into(),
            command: "aider".into(),
            args: vec!["--no-auto-commits".into(), "a file.py".into(), "$(echo smuggled)".into()],
            env: Some(env_of(&[("AIDER_DARK_MODE", "1")])),
            cwd: Some("~".into()),
            ..DefaultAgents::terminal()
        }
    }

    struct Run {
        lines: Vec<String>,
        status: i32,
    }

    /// Runs a launch's argv the way the terminal does, as a login process with stub agent
    /// CLIs on the interactive PATH (`runAgentLaunchCommand`).
    fn run(
        spec: &LaunchSpec,
        stubs: &[(&str, &str)],
        reports_through: Option<&str>,
        zprofile: &str,
        zshrc: &str,
        in_terminal: bool,
    ) -> Option<Run> {
        if !Path::new("/bin/zsh").exists() {
            return None;
        }
        let directory = tempfile::tempdir().expect("tempdir");
        let bin = directory.path().join("bin");
        std::fs::create_dir_all(&bin).expect("mkdir");
        std::fs::write(
            directory.path().join(".zshrc"),
            format!("export PATH=\"$ZDOTDIR/bin:$PATH\"\n{zshrc}\n"),
        )
        .expect("write");
        std::fs::write(directory.path().join(".zprofile"), format!("{zprofile}\n")).expect("write");
        for (name, body) in stubs {
            let path = bin.join(name);
            std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write");
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        }

        let line = spec.argv.iter().map(|a| soprano_launch::shell_quoted(a)).collect::<Vec<_>>().join(" ");
        let launch = ["/bin/bash", "--noprofile", "--norc", "-c"].map(str::to_owned).to_vec();
        let mut command = if in_terminal {
            let mut c = Command::new("/usr/bin/script");
            c.args(["-q", "/dev/null"]).args(&launch);
            c
        } else {
            let mut c = Command::new(&launch[0]);
            c.args(&launch[1..]);
            c
        };
        command.arg(format!("exec -l {line}"));
        // The terminal starts the command with the launch environment; the harness's own
        // variables win, and SOPRANO_BIN is set only below.
        let mut env: BTreeMap<String, String> = spec
            .env
            .iter()
            .filter(|(k, _)| *k != "SOPRANO_BIN")
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let home = directory.path().to_string_lossy().into_owned();
        env.extend(env_of(&[
            ("HOME", &home),
            ("ZDOTDIR", &home),
            ("PATH", "/usr/bin:/bin"),
            ("TERM", "dumb"),
        ]));
        if let Some(stub) = reports_through {
            env.insert("SOPRANO_BIN".into(), bin.join(stub).to_string_lossy().into_owned());
        }
        // The fallback login shell reads commands from stdin; give it none.
        let output =
            command.env_clear().envs(&env).stdin(Stdio::null()).stderr(Stdio::null()).output().expect("ran");
        // Like Swift's `isNewline`, a carriage return ends a line too.
        let lines = String::from_utf8_lossy(&output.stdout)
            .split(['\n', '\r'])
            .filter(|l| !l.is_empty())
            .map(|l| l.trim_matches([' ', '\t']).to_owned())
            .collect();
        Some(Run { lines, status: output.status.code().unwrap_or(-1) })
    }

    #[test]
    fn restored_omp_finds_executable_added_by_interactive_shell() {
        let spec = agent(&DefaultAgents::omp(), Some(&AgentConversation::new("saved-chat")));
        let Some(run) = run(&spec, &[("omp", "printf '%s\\n' \"$@\"")], None, "", "", false) else { return };
        assert_eq!(run.status, 0);
        assert_eq!(&run.lines[..3], ["--resume", "saved-chat", "--extension"]);
    }

    #[test]
    fn a_dedicated_agent_reports_its_exit_and_leaves_the_login_shell_behind() {
        let spec = agent(&DefaultAgents::omp(), None);
        let Some(run) = run(
            &spec,
            &[("omp", "echo agent-ran; exit 3"), ("soprano-stub", "echo \"reported $*\"")],
            Some("soprano-stub"),
            // Only the fallback shell is a login shell without a -c command.
            "[[ -z $ZSH_EXECUTION_STRING ]] && echo fallback-shell",
            "",
            false,
        ) else {
            return;
        };
        assert_eq!(run.lines, vec!["agent-ran", "reported agent-event stopped", "fallback-shell"]);
    }

    #[test]
    fn an_agent_started_by_hand_after_the_launched_one_exits_is_not_taken_for_the_launched_one() {
        // omp's ambient extension stays quiet under SOPRANO_AGENT_PROFILE, trusting the
        // launcher's --extension. An omp typed into the shell the pane falls back to has no
        // --extension, so the shell must not carry the launched agent's identity.
        let spec = agent(&DefaultAgents::omp(), Some(&AgentConversation::new("saved-chat")));
        let Some(run) = run(
            &spec,
            &[("omp", "echo \"agent profile=${SOPRANO_AGENT_PROFILE-unset}\"")],
            None,
            "[[ -z $ZSH_EXECUTION_STRING ]] && echo \"shell profile=${SOPRANO_AGENT_PROFILE-unset} \\\n\
             name=${SOPRANO_AGENT_NAME-unset} resume=${SOPRANO_RESUME_SESSION_ID-unset} pane=${SOPRANO_PANE_ID-unset}\"",
            "",
            false,
        ) else {
            return;
        };
        assert_eq!(
            run.lines,
            vec!["agent profile=omp", "shell profile=unset name=unset resume=unset pane=pane-1"]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_ctrl_c_while_the_fallback_shell_starts_leaves_its_startup_files_intact() {
        let spec = agent(&DefaultAgents::omp(), None);
        // Only the fallback shell runs without a -c command. It takes a Ctrl+C halfway
        // through .zshrc and reports at its first prompt.
        let zshrc = r#"if [[ -z $ZSH_EXECUTION_STRING ]]; then
    kill -INT $$
    echo rc-finished
    _report() { [[ $ZDOTDIR == $HOME ]] && echo zdotdir-restored; trap; exit }
    precmd_functions+=(_report)
fi"#;
        let Some(run) = run(&spec, &[("omp", "exit 0")], None, "", zshrc, true) else { return };
        // `script` echoes the ^D it forwards from empty stdin ahead of the output.
        assert!(run.lines.iter().any(|l| l.ends_with("rc-finished")), "{:?}", run.lines);
        assert!(run.lines.iter().any(|l| l == "zdotdir-restored"), "{:?}", run.lines);
        // Ctrl+C works again once the prompt is up.
        assert!(!run.lines.iter().any(|l| l.contains("INT")), "{:?}", run.lines);
    }

    #[test]
    fn configured_agent_arguments_are_quoted_through_both_shell_layers() {
        // Both shell layers quote arguments, so a path with spaces survives and command text
        // cannot smuggle shell syntax; use launchScript for that.
        let spec = agent(&aider(), None);
        assert_eq!(spec.env["AIDER_DARK_MODE"], "1");
        assert_eq!(spec.env["SOPRANO_AGENT_PROFILE"], "aider");
        assert_eq!(spec.env["SOPRANO_AGENT_NAME"], "Aider");
        assert_eq!(spec.cwd.as_deref(), Some(Path::new("/home/me")));
        let Some(run) = run(&spec, &[("aider", "printf '%s\\n' \"$@\"")], None, "", "", false) else {
            return;
        };
        assert_eq!(run.lines, vec!["--no-auto-commits", "a file.py", "$(echo smuggled)"]);
    }
}
