# soprano-launch — API report from LaunchPort

All of `soprano-launch` is built, and its 56 tests pass on macOS. Clippy reports no warnings for this crate on macOS, Linux and Windows. I followed the Swift for Claude Code: it builds the hook settings inline rather than loading `resources/AgentHooks/claude-settings.json`, which also differs in content (it adds `--profile`, `--body` texts, and a timeout of 3 on SessionEnd).

## 1. Public API

The crate depends only on `soprano-types`, `soprano-platform`, `serde_json`, `regex` and `libc` (Unix). It does not depend on `soprano-accounts`. Callers pass the account adjustments in, which AccountsPort agreed to.

**`spec`** (re-exported at the crate root)
- `struct LaunchContext { soprano_bin: String, app_pid: u32, socket: Option<String>, app_version: String, login_shell: String, resources: Resources, base_env: BTreeMap<String,String>, home: PathBuf }`
  - `LaunchContext::current(socket: Option<String>) -> Self` reads all of this from the running process.
- `struct LaunchSpec { argv: Vec<String>, cwd: Option<PathBuf>, env: BTreeMap<String,String>, initial_input: Option<String>, wait_after_command: bool }`
  - `env` is the child's complete environment.
  - `initial_input` is a profile's `launchScript` plus a newline, typed into the shell once it starts.
- Builders:
  - `LaunchSpec::default_shell(ctx, cwd: Option<&str>, pane_id, tab_id)`
  - `LaunchSpec::for_command(ctx, arguments: &[String], cwd, pane_id, tab_id)`
  - `LaunchSpec::for_agent(ctx, &AgentRequest)`
- `struct AgentRequest<'a> { profile, cwd, pane_id, tab_id, conversation: Option<&AgentConversation>, launch: Option<&AgentLaunch>, accounts: &AccountAdjustments }`, created with `AgentRequest::new(profile, pane_id, tab_id)`.
- `struct AccountAdjustments { environment: BTreeMap<String,String>, arguments: Vec<String> }`
- Helpers: `launch_arguments(profile_id, &AgentLaunch, including_prompt) -> Vec<String>`, `fallback_shell(login_shell, zsh_startup_dir: Option<&Path>) -> String`, `login_shell_argv(shell) -> Vec<String>`.

**`chat`**
- `ChatLaunch { profile_id, agent_name, shell, arguments, environment, working_directory }`
- `ChatLaunch::supports(id)`, `ChatLaunch::chat_profiles()`
- `ChatLaunch::for_profile(profile, cwd, login_shell, &AccountAdjustments, &env, home) -> Option<ChatLaunch>`

**`command_runner`**
- `CommandRunner { shell }` (`Default` uses the user's login shell):
  - `run_cli(&args, &overrides, RunOptions)` runs through the login shell.
  - `run(executable, &args, RunOptions)` runs a program directly.
  - `cli_arguments(..)` returns the script `run_cli` would use.
- `RunOptions { timeout, environment, input, keep_stdin_open, on_output_line: Option<Arc<dyn Fn(&str)>>, cancel: Option<CancelToken> }`, created with `RunOptions::with_timeout(d)`.
- `CommandResult { status, stdout, stderr }` with `succeeded()`, `failure_message()`, `failure_message_running(cmd)`.
- `CommandError::{LaunchFailed(String), TimedOut, Cancelled}`
- `CancelToken`
- Free functions: `background_environment(env)`, `stripping_terminal_codes(text)`, `first_url(line) -> Option<String>`, `COMMAND_START_MARKER`.

**`resources`**
- `Resources::locate()`, `Resources::at(Option<PathBuf>)`, `Resources::none()`, `.without_ghostty()`
- Lookups: `bundle_dir`, `bundle_resource(name)`, `opencode_plugin`, `opencode_tui_plugin`, `omp_extension`, `zsh_startup_dir`, `agent_hooks_dir`, `cli_dir`, `ghostty_resources_dir`, `terminfo_dir`
- `packaged_bundle_dir(root, exists)`

**`integrations`**
- `codex_integration_arguments(bin)`
- `claude_integration_settings() -> String`
- `opencode_config_content(plugin_url, model, model_agents, &env)`
- `opencode_cli_config_content(plugin_path, &env, home)`
- `file_url(path)`

**`shell_integration`**
- `apply_terminal_environment(&mut env, &Resources, version)`
- `apply_shell_integration(argv, &mut env, ghostty_dir, home)`
- `detect_shell(argv, is_macos)`, `enum Shell`, `DEFAULT_SHELL_FEATURES`

**`quote`**
- `shell_quoted`, `powershell_quoted`, `toml_quoted`
- `ShellFlavor::{Posix, PowerShell}::of(shell)`

### What each agent gets (zsh, from the golden tests)

Every agent runs as `/bin/zsh -lic "<script>"`. In the scripts below, TAIL stands for this, after the agent command:

```
test -z "$SOPRANO_BIN" || "$SOPRANO_BIN" agent-event stopped; unset SOPRANO_AGENT_PROFILE SOPRANO_AGENT_NAME SOPRANO_RESUME_SESSION_ID; if [[ ${(t)ZDOTDIR} == *export* ]]; then export SOPRANO_ZSH_ZDOTDIR="$ZDOTDIR"; else unset SOPRANO_ZSH_ZDOTDIR; fi; ZDOTDIR='<bundle>/SopranoZsh' exec '/bin/zsh' -l
```

**Codex**
- Fresh:
  ```
  trap true INT; 'codex' '-c' 'notify=["<bin>","agent-event","needs-input","--notify","--title","Codex","--body","Response ready"]' '-c' 'tui.notifications=["approval-requested"]' '-c' 'tui.notification_method="osc9"' '-c' 'tui.notification_condition="always"'; TAIL
  ```
- Resumed automation with a chosen account:
  ```
  trap true INT; export CODEX_HOME='/acc/codex'; 'codex' 'resume' 'saved-chat' <hooks> '--model' 'gpt-5' '--dangerously-bypass-approvals-and-sandbox'; TAIL
  ```
  The prompt is left out because a resumed conversation already has it.

**Claude Code**
- Automation:
  ```
  trap true INT; 'claude' '--settings' '<json>' '--model' 'opus' '--dangerously-skip-permissions' '--' 'Fix it'; TAIL
  ```
- Resume puts `'--resume' 'saved-chat'` first.
- The settings JSON has SessionStart (matcher `startup|resume|clear`) → `ready`, UserPromptSubmit → `running`, SessionEnd → `stopped`, Stop → `needs-input --notify`, and Notification (matcher `idle_prompt|permission_prompt|elicitation_dialog`) → `needs-input --notify`. All use `--message-from-stdin` and a timeout of 5.

**OpenCode**
- Command:
  ```
  trap true INT; 'opencode' '--standalone' '--auto' '--prompt=Do it'; TAIL
  ```
  Resume is `'--session' '<id>'`.
- `OPENCODE_CONFIG_CONTENT={"plugin":["file://<bundle>/SopranoOpenCodePlugin.js"],"model":"a/b","agents":{"build":{"model":"a/b"}}}`
- `OPENCODE_CLI_CONFIG_CONTENT={"plugins":[<user cli.json plugins…>,"<bundle>/SopranoOpenCode"]}`

**omp**
```
trap true INT; 'omp' '--resume' 'saved-chat' '--extension' '<bundle>/SopranoOmpExtension.js' '--config' '/acc/omp.yml' '--model=x' '--auto-approve'; TAIL
```

**Plain terminal**: `/bin/zsh -l`. A `launchScript` profile also starts as `/bin/zsh -l`, with `initial_input` set to the script.

**PowerShell** (example for Codex):
```
pwsh.exe -NoLogo -NoExit -Command "$env:CODEX_HOME = '…'; & 'codex' <hooks>; if ($env:SOPRANO_BIN) { & $env:SOPRANO_BIN agent-event stopped }; Remove-Item -ErrorAction SilentlyContinue Env:SOPRANO_AGENT_PROFILE, Env:SOPRANO_AGENT_NAME, Env:SOPRANO_RESUME_SESSION_ID"
```

**Environment of every pane**
- `SOPRANO_BIN`, `SOPRANO_APP_PID`, `SOPRANO_PANE_ID`, `SOPRANO_TAB_ID`, `SOPRANO_SOCKET`
- `TERM_PROGRAM=Soprano`, `TERM_PROGRAM_VERSION`, `COLORTERM=truecolor`, `GHOSTTY_SHELL_FEATURES=cursor:blink,path,title`
- `TERM=xterm-ghostty` plus `TERMINFO=<res>/terminfo` only when `<res>/terminfo` exists; otherwise `TERM=xterm-256color`
- `GHOSTTY_RESOURCES_DIR` when the shell-integration scripts are found
- `PATH` with the CLI folder put first
- Agents add `SOPRANO_AGENT_PROFILE`, `SOPRANO_AGENT_NAME`, `SOPRANO_RESUME_SESSION_ID` (only when resuming), the profile's own `env`, and the account variables.

## 2. What was ported

| Swift | Rust |
|---|---|
| `TerminalConfig` (TerminalSurfaceView.swift lines 1–383), `scopedConfig` (544–571) | `spec.rs`, `integrations.rs` |
| `AgentChatLaunch` (AgentChatSession.swift lines 1–73) | `chat.rs` |
| `CommandRunner.swift` | `command_runner.rs` |
| `AccountLaunchState.Adjustments` | `AccountAdjustments` (the account logic itself stays in AccountsPort's crate) |
| `SopranoResources.swift` | `resources.rs` |
| Ghostty `Exec.zig` (child environment) and `shell_integration.zig` | `shell_integration.rs` |

Tests: 56 in total.
- 28 integration tests in `tests/launch.rs`:
  - From AgentConversationTests: 6.
  - From AccountLaunchTests: 3.
  - From AgentWaitingReasonTests: 2.
  - From AutomationControllerTests: 2 (launch-argument and config parts).
  - From SopranoConfigTests: 2.
  - New: 10 golden tests, plus 3 edge cases (an invalid conversation is not resumed, a malformed inherited OpenCode config is left alone, a bash fallback).
- 28 unit tests in the modules:
  - From AgentChatSessionTests: 1, plus 2 extras.
  - From PackagedResourceLookupTests: 2.
  - Ports of Ghostty's own tests: 9.
  - Command runner: 9.
  - Quoting and JSON helpers: 5.

Skipped:
- TerminalLifecycleTests and TerminalSessionTests: they test the model and the surface cache, not how processes start.
- The Codex home-linking assertion in AccountLaunchTests: that is `CodexHomeLinker`, which lives in the accounts crate.
- The `SplitTreeView` restart test: it is a view test.

## 3. Cross-platform decisions and changes from Swift
- **Shell syntax** is chosen from the shell's name, not the OS: pwsh/powershell get PowerShell syntax, everything else gets POSIX. Git Bash on Windows therefore works.
- **PowerShell launches:**
  - Agents and commands run with `-NoLogo -NoExit -Command`, so the pane stays in PowerShell after the agent exits. There is no Ctrl+C trap and no zsh fallback there.
  - Chat and `run_cli` use `-NoLogo -Command … ; exit $LASTEXITCODE`.
- **Hook commands on Windows:** Claude's hook commands are POSIX (`test -z …`) and are kept as they are, because Claude Code runs hooks through Git Bash on Windows. Codex `notify` is an argument list, and the OpenCode and omp plugins are JavaScript, so those work on every OS.
- **Windows PowerShell 5.1 quoting caveat:** 5.1 mangles embedded `"` when passing arguments to native programs, which affects Claude's `--settings` JSON. PowerShell 7.3+ is fine; this is noted, not worked around.
- **Ghostty's job now done here:** Ghostty used to add the terminal environment and shell integration itself, so this crate does it now, following the Zig code.
  - `GHOSTTY_BIN_DIR` and the macOS `XDG_DATA_DIRS`/`MANPATH` additions are left out because they point at Ghostty's own app.
  - When running from a source checkout, shell integration falls back to `<repo>/ghostty/src` because `<res>/ghostty` does not exist there.
- **Inherited pane identity is dropped:** `SOPRANO_*` pane-identity variables inherited from a parent pane are removed before a pane starts. Swift let `SOPRANO_AGENT_PROFILE` leak into plain shells.
- **CLI folder on PATH:** `<res>/bin` is used when it contains `soprano`, as in Swift. When it doesn't (a build run from the target folder), the folder of the running `soprano` binary is used instead.
- **Codex TOML quoting:** Rust's JSON encoder writes `/` instead of Swift's `\/`, which is not a valid TOML escape anyway.
- **JSON details:** key order in the Claude settings is deterministic. `cli.json` is read as JSONC by a small local parser instead of depending on `soprano-config`.
- **Command runner:** it is synchronous (threads plus `CancelToken`). On Windows, stopping a command kills it outright because there is no SIGTERM.

## 4. Verification
- `CARGO_TARGET_DIR=target/agent-soprano-launch cargo test -p soprano-launch`: 28 + 28 passed, including the real `/bin/zsh` launch tests and the macOS-only Ctrl+C test that runs under `script`.
- `cargo clippy -p soprano-launch --all-targets`: no warnings.
- `cargo fmt -p soprano-launch`: done.
- `CARGO_TARGET_DIR=target/agent-soprano-launch-cross cargo clippy --target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` with `-p soprano-launch --all-targets`: both finish with no warnings for this crate. The only warning is a needless `return` in the frozen `soprano-platform/src/shell.rs:9`, which I did not touch.