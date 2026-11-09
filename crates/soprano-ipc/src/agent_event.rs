//! `soprano agent-event <state> [options]`: the small bridge agent lifecycle hooks call. It
//! posts to the already-running app and exits before any UI or terminal engine is initialized.

use std::collections::HashMap;

use serde_json::{Map, Value};
use soprano_types::{AgentConversation, AgentWaitingReason};

use crate::protocol::{AgentEvent, AgentEventState, Request};

/// Longest agent message a banner shows before it is elided. Notification centers truncate well
/// before this, but the string also lands in the pane's status, so it is bounded here rather than
/// left to the window server.
pub const MESSAGE_LIMIT: usize = 180;

/// Longest agent message an event carries for an automation run's record; the transcript, when
/// the CLI writes one, has the rest.
pub const FULL_MESSAGE_LIMIT: usize = 8_192;

/// Keys the supported agents use for the text a human should read. Tried in order, so the most
/// specific wins.
const MESSAGE_KEYS: [&str; 7] = [
    "message",                // Claude Code notification hooks
    "last-assistant-message", // Codex notify payloads
    "last_assistant_message",
    "description",
    "body",
    "text",
    "prompt",
];

/// Builds the request for an `agent-event` invocation (Swift `notificationEnvelope`). `None` when
/// the state is unknown or the call does not come from a Soprano terminal (`SOPRANO_APP_PID`,
/// `SOPRANO_PANE_ID`, `SOPRANO_TAB_ID`). `standard_input` and `hook_owner_process_id` are only
/// called for a valid invocation.
pub fn agent_event_request(
    arguments: &[String],
    environment: &HashMap<String, String>,
    standard_input: impl FnOnce() -> Option<Vec<u8>>,
    hook_owner_process_id: impl FnOnce() -> Option<i32>,
) -> Option<Request> {
    let state = AgentEventState::from_raw(arguments.get(2)?)?;
    non_empty(environment, "SOPRANO_APP_PID")?;
    let pane_id = non_empty(environment, "SOPRANO_PANE_ID")?;
    let tab_id = non_empty(environment, "SOPRANO_TAB_ID")?;

    let mut notify = false;
    let mut profile_id = environment.get("SOPRANO_AGENT_PROFILE").cloned();
    let mut title = environment.get("SOPRANO_AGENT_NAME").cloned().unwrap_or_else(|| "Agent".into());
    let mut body = state.default_body().to_string();
    let mut process_id: Option<i32> = None;
    let mut reads_standard_input = false;
    let mut payloads: Vec<String> = Vec::new();
    let mut reason: Option<AgentWaitingReason> = None;
    let mut index = 3;

    while index < arguments.len() {
        let has_value = index + 1 < arguments.len();
        match arguments[index].as_str() {
            "--notify" => {
                notify = true;
                index += 1;
            }
            "--profile" if has_value => {
                profile_id = Some(arguments[index + 1].clone());
                index += 2;
            }
            "--title" if has_value => {
                title = arguments[index + 1].clone();
                index += 2;
            }
            "--body" if has_value => {
                body = arguments[index + 1].clone();
                index += 2;
            }
            "--pid" if has_value => {
                process_id = arguments[index + 1].parse::<i32>().ok().filter(|pid| *pid > 0);
                index += 2;
            }
            "--reason" if has_value => {
                reason = waiting_reason_from_raw(&arguments[index + 1]);
                index += 2;
            }
            "--message-from-stdin" => {
                reads_standard_input = true;
                index += 1;
            }
            "--message-json" if has_value => {
                payloads.push(arguments[index + 1].clone());
                index += 2;
            }
            other => {
                // Codex appends its notification payload as one trailing JSON argument rather
                // than passing it through a flag.
                payloads.push(other.to_string());
                index += 1;
            }
        }
    }

    // Lifecycle hooks rarely pass --pid, and some never report exit (an older Claude Code merge
    // has no SessionEnd). The process that ran the hook lets the app detach the agent once its
    // shell prompt returns.
    if process_id.is_none() {
        process_id = hook_owner_process_id();
    }

    if reads_standard_input
        && let Some(data) = standard_input()
        && !data.is_empty()
    {
        payloads.push(String::from_utf8_lossy(&data).into_owned());
    }

    // Kept for the agent's record (an automation run's reply), not for the banner: that names
    // the alert and the conversation, nothing more.
    let message = payloads
        .iter()
        .find_map(|payload| agent_message_text(payload))
        .map(|message| message.chars().take(FULL_MESSAGE_LIMIT).collect());
    let reason = if state == AgentEventState::NeedsInput {
        reason.or_else(|| payloads.iter().find_map(|payload| waiting_reason(payload)))
    } else {
        None
    };
    let conversation = payloads.iter().find_map(|payload| AgentConversation::from_payload(payload));

    Some(Request::AgentEvent(AgentEvent {
        pane_id,
        tab_id,
        state,
        notify,
        title,
        body,
        profile_id,
        process_id,
        message,
        reason,
        conversation,
    }))
}

fn non_empty(environment: &HashMap<String, String>, key: &str) -> Option<String> {
    environment.get(key).filter(|value| !value.is_empty()).cloned()
}

fn waiting_reason_from_raw(raw: &str) -> Option<AgentWaitingReason> {
    match raw {
        "turn" => Some(AgentWaitingReason::TurnEnded),
        "approval" => Some(AgentWaitingReason::Approval),
        "question" => Some(AgentWaitingReason::Question),
        _ => None,
    }
}

/// Claude Code sends a type rather than prose for some notifications.
fn message_for_notification_type(kind: &str) -> Option<&'static str> {
    match kind {
        "idle_prompt" => Some("Waiting for your next prompt"),
        "permission_prompt" => Some("Approval required"),
        "elicitation_dialog" => Some("Input required"),
        _ => None,
    }
}

fn json_object(payload: &str) -> Option<Map<String, Value>> {
    let trimmed = payload.trim();
    if !trimmed.starts_with('{') {
        return None;
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

/// Pulls a human-readable line out of an agent payload. Every agent hands us a different shape,
/// so this reads whichever known key is present instead of modelling schemas that upstream can
/// change at will.
pub fn agent_message(payload: &str) -> Option<String> {
    agent_message_text(payload).and_then(|text| summarize(&text))
}

/// The agent's message from a payload as it wrote it, untrimmed of inner whitespace.
pub fn agent_message_text(payload: &str) -> Option<String> {
    let json = json_object(payload)?;
    for key in MESSAGE_KEYS {
        if let Some(Value::String(value)) = json.get(key) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    match json.get("notification_type") {
        Some(Value::String(kind)) => message_for_notification_type(kind).map(str::to_string),
        _ => None,
    }
}

/// What a hook payload says the agent waits for: Claude Code's notification types tell a blocked
/// tool call or question from a turn that ended; its Stop hook and Codex's turn notification end
/// turns.
pub fn waiting_reason(payload: &str) -> Option<AgentWaitingReason> {
    let json = json_object(payload)?;
    let string = |key: &str| json.get(key).and_then(Value::as_str);
    match string("notification_type") {
        Some("permission_prompt") => return Some(AgentWaitingReason::Approval),
        Some("elicitation_dialog") => return Some(AgentWaitingReason::Question),
        Some("idle_prompt") => return Some(AgentWaitingReason::TurnEnded),
        _ => {}
    }
    if string("hook_event_name") == Some("Stop") || string("type") == Some("agent-turn-complete") {
        return Some(AgentWaitingReason::TurnEnded);
    }
    if string("hook_event_name") == Some("PermissionRequest") {
        return Some(AgentWaitingReason::Approval);
    }
    None
}

/// Agent output is multi-line and unbounded; a banner is one line.
pub fn summarize(raw: &str) -> Option<String> {
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        return None;
    }
    if collapsed.chars().count() <= MESSAGE_LIMIT {
        return Some(collapsed);
    }
    let clipped: String = collapsed.chars().take(MESSAGE_LIMIT).collect();
    Some(format!("{}…", clipped.trim()))
}

const SHELL_NAMES: [&str; 8] = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"];

/// Windows hooks run through these instead of a POSIX shell.
#[cfg(windows)]
const WINDOWS_SHELL_NAMES: [&str; 3] = ["cmd", "powershell", "pwsh"];

fn is_shell(name: &str) -> bool {
    #[cfg(windows)]
    if WINDOWS_SHELL_NAMES.contains(&name) {
        return true;
    }
    SHELL_NAMES.contains(&name)
}

/// Hooks run this command directly or through `sh -c`, so the agent is the nearest ancestor that
/// is not a shell. Reaching `login` or the app means it was typed into the pane's own shell, where
/// no agent owns the event.
pub fn hook_owner_process_id(
    starting_at: i32,
    app_process_id: Option<i32>,
    lookup: impl Fn(i32) -> Option<(i32, String)>,
) -> Option<i32> {
    let mut current = starting_at;
    for _ in 0..8 {
        if current <= 1 || Some(current) == app_process_id {
            return None;
        }
        let (parent, name) = lookup(current)?;
        let name = name.strip_prefix('-').unwrap_or(&name);
        if !is_shell(name) {
            return if name == "login" { None } else { Some(current) };
        }
        current = parent;
    }
    None
}

/// [`hook_owner_process_id`] for the current process, walking the real process table.
pub fn current_hook_owner_process_id(app_process_id: Option<i32>) -> Option<i32> {
    hook_owner_process_id(process::parent_id()?, app_process_id, process::parent_and_name)
}

/// Process-table lookups: `sysctl`-equivalent `proc_pidinfo` on macOS, `/proc` on Linux,
/// Toolhelp snapshots on Windows.
pub mod process {
    #[cfg(unix)]
    pub fn parent_id() -> Option<i32> {
        // SAFETY: getppid has no preconditions and cannot fail.
        Some(unsafe { libc::getppid() })
    }

    #[cfg(windows)]
    pub fn parent_id() -> Option<i32> {
        parent_and_name(std::process::id() as i32).map(|(parent, _)| parent)
    }

    #[cfg(not(any(unix, windows)))]
    pub fn parent_id() -> Option<i32> {
        None
    }

    /// The parent pid and short executable name (at most 16 bytes on macOS, as `p_comm`).
    #[cfg(target_os = "macos")]
    pub fn parent_and_name(pid: i32) -> Option<(i32, String)> {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: `info` is a correctly sized, writable `proc_bsdinfo`.
        let written = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size,
            )
        };
        if written != size {
            return None;
        }
        let bytes: Vec<u8> = info.pbi_comm.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
        Some((info.pbi_ppid as i32, String::from_utf8_lossy(&bytes).into_owned()))
    }

    #[cfg(target_os = "linux")]
    pub fn parent_and_name(pid: i32) -> Option<(i32, String)> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let open = stat.find('(')?;
        let close = stat.rfind(')')?;
        let name = stat.get(open + 1..close)?.to_string();
        let parent = stat.get(close + 1..)?.split_whitespace().nth(1)?.parse().ok()?;
        Some((parent, name))
    }

    #[cfg(windows)]
    pub fn parent_and_name(pid: i32) -> Option<(i32, String)> {
        use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
        };
        // SAFETY: plain Win32 calls with a correctly sized entry; the handle is closed below.
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snapshot == INVALID_HANDLE_VALUE {
                return None;
            }
            let mut entry: PROCESSENTRY32W = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            let mut found = None;
            let mut ok = Process32FirstW(snapshot, &mut entry) != 0;
            while ok {
                if entry.th32ProcessID == pid as u32 {
                    let len = entry.szExeFile.iter().position(|c| *c == 0).unwrap_or(entry.szExeFile.len());
                    let exe = String::from_utf16_lossy(&entry.szExeFile[..len]).to_lowercase();
                    let name = exe.strip_suffix(".exe").unwrap_or(&exe).to_string();
                    found = Some((entry.th32ParentProcessID as i32, name));
                    break;
                }
                ok = Process32NextW(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
            found
        }
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
    pub fn parent_and_name(_pid: i32) -> Option<(i32, String)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::AgentEvent;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    fn environment() -> HashMap<String, String> {
        HashMap::from([
            ("SOPRANO_APP_PID".into(), "4242".into()),
            ("SOPRANO_PANE_ID".into(), "pane-1".into()),
            ("SOPRANO_TAB_ID".into(), "tab-2".into()),
        ])
    }

    fn event_with(
        arguments: &[&str],
        env: &HashMap<String, String>,
        stdin: Option<&str>,
    ) -> Option<AgentEvent> {
        match agent_event_request(&strings(arguments), env, || stdin.map(|s| s.as_bytes().to_vec()), || None)?
        {
            Request::AgentEvent(event) => Some(event),
            _ => None,
        }
    }

    fn event(arguments: &[&str], stdin: Option<&str>) -> Option<AgentEvent> {
        event_with(arguments, &environment(), stdin)
    }

    fn base(state: AgentEventState, notify: bool, body: &str) -> AgentEvent {
        AgentEvent {
            pane_id: "pane-1".into(),
            tab_id: "tab-2".into(),
            state,
            notify,
            title: "Agent".into(),
            body: body.into(),
            profile_id: None,
            process_id: None,
            message: None,
            reason: None,
            conversation: None,
        }
    }

    // ExternalEventRoutingTests

    #[test]
    fn agent_event_request_carries_the_exact_terminal_target() {
        assert_eq!(
            event(&["soprano", "agent-event", "needs-input", "--notify"], None),
            Some(base(AgentEventState::NeedsInput, true, "Input required"))
        );
    }

    #[test]
    fn stopped_agent_event_uses_the_session_end_state() {
        let mut expected = base(AgentEventState::Stopped, false, "Stopped");
        expected.profile_id = Some("codex".into());
        assert_eq!(event(&["soprano", "agent-event", "stopped", "--profile", "codex"], None), Some(expected));
    }

    #[test]
    fn agent_event_without_a_process_or_terminal_identity_builds_no_request() {
        let mut no_app = environment();
        no_app.remove("SOPRANO_APP_PID");
        assert_eq!(event_with(&["soprano", "agent-event", "ready"], &no_app, None), None);
        let mut no_tab = environment();
        no_tab.remove("SOPRANO_TAB_ID");
        assert_eq!(event_with(&["soprano", "agent-event", "ready"], &no_tab, None), None);
    }

    // AgentMessageForwardingTests

    fn message(arguments: &[&str], stdin: Option<&str>) -> Option<String> {
        event(arguments, stdin).and_then(|e| e.message)
    }

    fn body(arguments: &[&str], stdin: Option<&str>) -> Option<String> {
        event(arguments, stdin).map(|e| e.body)
    }

    #[test]
    fn claude_code_hook_payload_on_standard_input_becomes_the_message() {
        let payload = r#"{"hook_event_name":"Notification","message":"Drop the legacy column? [y/n]"}"#;
        assert_eq!(
            message(
                &[
                    "soprano",
                    "agent-event",
                    "needs-input",
                    "--notify",
                    "--message-from-stdin",
                    "--body",
                    "Approval or input required"
                ],
                Some(payload)
            )
            .as_deref(),
            Some("Drop the legacy column? [y/n]")
        );
    }

    #[test]
    fn codex_appends_its_payload_as_a_trailing_argument_and_it_still_reaches_the_app() {
        let payload = r#"{"type":"agent-turn-complete","last-assistant-message":"Migration applied."}"#;
        assert_eq!(
            message(
                &[
                    "soprano",
                    "agent-event",
                    "needs-input",
                    "--notify",
                    "--title",
                    "Codex",
                    "--body",
                    "Response ready",
                    payload
                ],
                None
            )
            .as_deref(),
            Some("Migration applied.")
        );
    }

    #[test]
    fn open_code_passes_its_event_properties_through_message_json() {
        let payload = r#"{"description":"Allow writing to Package.swift?"}"#;
        assert_eq!(
            message(
                &[
                    "soprano",
                    "agent-event",
                    "needs-input",
                    "--notify",
                    "--message-json",
                    payload,
                    "--body",
                    "Approval required"
                ],
                None
            )
            .as_deref(),
            Some("Allow writing to Package.swift?")
        );
    }

    #[test]
    fn a_notification_type_without_prose_still_reads_as_something_human_facing() {
        let payload = r#"{"notification_type":"idle_prompt","cwd":"/tmp"}"#;
        assert_eq!(
            message(
                &["soprano", "agent-event", "needs-input", "--notify", "--message-from-stdin"],
                Some(payload)
            )
            .as_deref(),
            Some("Waiting for your next prompt")
        );
    }

    #[test]
    fn the_static_body_stays_when_the_payload_carries_no_readable_message() {
        assert_eq!(
            body(
                &[
                    "soprano",
                    "agent-event",
                    "needs-input",
                    "--notify",
                    "--message-from-stdin",
                    "--body",
                    "Approval or input required"
                ],
                Some(r#"{"session_id":"abc","cwd":"/tmp"}"#)
            )
            .as_deref(),
            Some("Approval or input required")
        );
    }

    #[test]
    fn a_missing_or_unparseable_payload_falls_back_rather_than_losing_the_notification() {
        let arguments = ["soprano", "agent-event", "error", "--notify", "--message-from-stdin"];
        assert_eq!(
            body(&arguments, Some("not json at all")).as_deref(),
            Some("The agent stopped with an error")
        );
        assert_eq!(body(&arguments, None).as_deref(), Some("The agent stopped with an error"));
    }

    #[test]
    fn multi_line_agent_output_collapses_to_a_single_banner_line() {
        assert_eq!(
            summarize("  Applied 3 files.\n\n  Ran   tests.\t Done.  ").as_deref(),
            Some("Applied 3 files. Ran tests. Done.")
        );
    }

    #[test]
    fn an_unbounded_agent_message_is_elided_rather_than_handed_to_the_window_server_whole() {
        let long = "a".repeat(MESSAGE_LIMIT + 50);
        let summary = summarize(&long).expect("summary");
        assert_eq!(summary.chars().count(), MESSAGE_LIMIT + 1);
        assert!(summary.ends_with('…'));
    }

    #[test]
    fn whitespace_only_output_is_not_treated_as_a_message() {
        assert_eq!(summarize("   \n\t "), None);
        assert_eq!(agent_message(r#"{"message":"   "}"#), None);
    }

    #[test]
    fn the_body_no_longer_quotes_the_agent_so_the_banner_stays_one_clean_line() {
        assert_eq!(
            body(
                &[
                    "soprano",
                    "agent-event",
                    "needs-input",
                    "--notify",
                    "--message-from-stdin",
                    "--body",
                    "Response ready"
                ],
                Some(r#"{"hook_event_name":"Stop","last_assistant_message":"Done.\n\nRan tests."}"#)
            )
            .as_deref(),
            Some("Response ready")
        );
    }

    #[test]
    fn codex_permission_request_hook_waits_for_approval() {
        assert_eq!(
            waiting_reason(r#"{"hook_event_name":"PermissionRequest"}"#),
            Some(AgentWaitingReason::Approval)
        );
    }

    // AgentConversationTests (CLI side)

    #[test]
    fn lifecycle_payloads_carry_an_exact_conversation_alongside_the_notification() {
        let payloads = [
            (r#"{"thread-id":"codex-one","cwd":"/tmp/repo","last-assistant-message":"Done"}"#, "codex-one"),
            (
                r#"{"session_id":"claude-two","cwd":"/tmp/repo","hook_event_name":"SessionStart"}"#,
                "claude-two",
            ),
            (r#"{"sessionID":"ses_three","cwd":"/tmp/repo","message":"Approval required"}"#, "ses_three"),
        ];
        for (payload, expected) in payloads {
            let event =
                event(&["soprano", "agent-event", "ready", "--message-json", payload], None).expect("event");
            let conversation = event.conversation.expect("conversation");
            assert_eq!(conversation.id, expected);
            assert_eq!(conversation.cwd.as_deref(), Some("/tmp/repo"));
            assert_eq!(event.pane_id, "pane-1");
            assert_eq!(event.tab_id, "tab-2");
        }
    }

    #[test]
    fn a_hook_without_pid_reports_its_owning_process() {
        let request = agent_event_request(
            &strings(&["soprano", "agent-event", "ready", "--profile", "claude-code"]),
            &environment(),
            || None,
            || Some(777),
        );
        let Some(Request::AgentEvent(event)) = request else { panic!("expected an agent event") };
        assert_eq!(event.process_id, Some(777));
    }

    #[test]
    fn hook_owner_is_the_nearest_non_shell_ancestor_but_never_the_pane_shells_login_or_the_app() {
        let processes: HashMap<i32, (i32, &str)> = HashMap::from([
            (50, (40, "sh")),
            (40, (30, "claude")),
            (30, (20, "-zsh")),
            (20, (10, "login")),
            (10, (1, "Soprano")),
            (60, (30, "codex")),
            (31, (10, "zsh")),
        ]);
        let owner = |pid: i32| {
            hook_owner_process_id(pid, Some(10), |p| {
                processes.get(&p).map(|(parent, name)| (*parent, name.to_string()))
            })
        };
        assert_eq!(owner(50), Some(40));
        assert_eq!(owner(60), Some(60));
        assert_eq!(owner(30), None);
        assert_eq!(owner(31), None);
        assert_eq!(owner(99), None);
    }

    #[test]
    fn the_current_process_table_names_this_test_runners_parent() {
        let parent = process::parent_id().expect("parent pid");
        assert!(process::parent_and_name(parent).is_some());
    }
}
