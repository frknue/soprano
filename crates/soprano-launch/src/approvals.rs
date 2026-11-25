//! Every agent starts with its approval prompts skipped ("bypass permissions"). Most of them
//! work where nobody watches (a thread of the Agent Dashboard, an automation run, a tab behind
//! another), and a prompt there waits unseen. There is no exception: an approval mode an
//! agent's own `args` name gives way, because the CLIs refuse or misread it beside the bypass.

/// What an agent's CLI takes about approvals: the switch that skips them, and the options
/// that say something else.
struct ApprovalOptions {
    bypass: &'static str,
    /// Options that take a value, as `--option value` or `--option=value`.
    valued: &'static [&'static str],
    switches: &'static [&'static str],
}

impl ApprovalOptions {
    /// `None` for a CLI Soprano does not know.
    fn of(profile_id: &str) -> Option<Self> {
        Some(match profile_id {
            "claude-code" => Self {
                bypass: "--dangerously-skip-permissions",
                valued: &["--permission-mode"],
                switches: &[],
            },
            "codex" => Self {
                bypass: "--dangerously-bypass-approvals-and-sandbox",
                valued: &["--ask-for-approval", "-a", "--sandbox", "-s"],
                switches: &["--full-auto", "--yolo"],
            },
            "omp" => Self { bypass: "--auto-approve", valued: &["--approval-mode"], switches: &[] },
            "opencode" => Self { bypass: "--auto", valued: &[], switches: &[] },
            "agy" => Self {
                bypass: "--dangerously-skip-permissions",
                valued: &["--mode"],
                switches: &["--sandbox"],
            },
            _ => return None,
        })
    }
}

/// Makes `arguments` (the command line of `profile_id`'s CLI so far, without its prompt) skip
/// the CLI's approval prompts: options that name another approval mode are taken out, and
/// the bypass switch goes at the end. A CLI Soprano does not know is left as it is.
pub fn bypass_approvals(profile_id: &str, arguments: &mut Vec<String>) {
    let Some(options) = ApprovalOptions::of(profile_id) else { return };
    replace_approval_options(&options, options.bypass, arguments);
}

/// [`bypass_approvals`] for a chat server: omp uses `--approval-mode=yolo`; agy and claude-code
/// use `--dangerously-skip-permissions`; codex's app-server configures approval policy in its
/// JSON-RPC `thread/start` request, so CLI-only approval flags are stripped; opencode's ACP
/// server takes no approval flag.
pub(crate) fn bypass_chat_approvals(profile_id: &str, arguments: &mut Vec<String>) {
    match profile_id {
        "omp" => {
            if let Some(options) = ApprovalOptions::of("omp") {
                replace_approval_options(&options, "--approval-mode=yolo", arguments);
            }
        }
        "agy" | "claude-code" => bypass_approvals(profile_id, arguments),
        "codex" => {
            if let Some(options) = ApprovalOptions::of("codex") {
                strip_approval_options(&options, arguments);
            }
        }
        _ => {}
    }
}

fn strip_approval_options(options: &ApprovalOptions, arguments: &mut Vec<String>) {
    let mut kept = Vec::with_capacity(arguments.len());
    let mut rest = std::mem::take(arguments).into_iter();
    while let Some(argument) = rest.next() {
        let (name, has_inline_value) = match argument.split_once('=') {
            Some((name, _)) => (name, true),
            None => (argument.as_str(), false),
        };
        if options.valued.contains(&name) {
            if !has_inline_value {
                rest.next();
            }
        } else if name != options.bypass && !options.switches.contains(&name) {
            kept.push(argument);
        }
    }
    *arguments = kept;
}

fn replace_approval_options(options: &ApprovalOptions, bypass: &str, arguments: &mut Vec<String>) {
    let mut kept = Vec::with_capacity(arguments.len() + 1);
    let mut rest = std::mem::take(arguments).into_iter();
    while let Some(argument) = rest.next() {
        let (name, has_inline_value) = match argument.split_once('=') {
            Some((name, _)) => (name, true),
            None => (argument.as_str(), false),
        };
        if options.valued.contains(&name) {
            if !has_inline_value {
                rest.next();
            }
        } else if name != options.bypass && !options.switches.contains(&name) {
            kept.push(argument);
        }
    }
    kept.push(bypass.to_owned());
    *arguments = kept;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bypassed(profile_id: &str, arguments: &[&str]) -> Vec<String> {
        let mut arguments = arguments.iter().map(|argument| argument.to_string()).collect();
        bypass_approvals(profile_id, &mut arguments);
        arguments
    }

    #[test]
    fn the_bypass_replaces_whatever_the_arguments_say_about_approvals() {
        assert_eq!(bypassed("claude-code", &[]), ["--dangerously-skip-permissions"]);
        assert_eq!(
            bypassed("claude-code", &["--permission-mode", "plan", "--verbose"]),
            ["--verbose", "--dangerously-skip-permissions"]
        );
        assert_eq!(
            bypassed("codex", &["resume", "abc", "-a", "untrusted", "--sandbox=read-only", "--full-auto"]),
            ["resume", "abc", "--dangerously-bypass-approvals-and-sandbox"]
        );
        assert_eq!(
            bypassed("omp", &["--approval-mode=write", "--model=x", "--auto-approve"]),
            ["--model=x", "--auto-approve"]
        );
        assert_eq!(bypassed("opencode", &["--session", "s", "--auto"]), ["--session", "s", "--auto"]);
        assert_eq!(
            bypassed("agy", &["--mode", "plan", "--sandbox", "--model", "gemini"]),
            ["--model", "gemini", "--dangerously-skip-permissions"]
        );
        // An option at the very end, missing its value, takes nothing with it.
        assert_eq!(bypassed("claude-code", &["--permission-mode"]), ["--dangerously-skip-permissions"]);
    }

    #[test]
    fn values_of_other_options_and_unknown_agents_are_left_alone() {
        // Codex's own settings travel as `-c key=value`: a value is never read as an option.
        assert_eq!(
            bypassed("codex", &["-c", "notify=[\"x\"]", "--model", "gpt"]),
            ["-c", "notify=[\"x\"]", "--model", "gpt", "--dangerously-bypass-approvals-and-sandbox"]
        );
        assert_eq!(bypassed("aider", &["--yes"]), ["--yes"]);
    }

    #[test]
    fn a_chat_server_is_started_in_the_mode_that_asks_for_nothing() {
        let mut arguments: Vec<String> =
            ["acp", "--approval-mode", "always-ask", "--auto-approve", "--config", "/o.yml"]
                .map(String::from)
                .to_vec();
        bypass_chat_approvals("omp", &mut arguments);
        assert_eq!(arguments, ["acp", "--config", "/o.yml", "--approval-mode=yolo"]);

        let mut agy_args: Vec<String> = ["acp", "--mode", "plan", "--sandbox"].map(String::from).to_vec();
        bypass_chat_approvals("agy", &mut agy_args);
        assert_eq!(agy_args, ["acp", "--dangerously-skip-permissions"]);

        let mut codex_args: Vec<String> =
            ["app-server", "--stdio", "--full-auto", "-s", "read-only", "-c", "model=\"o3\""]
                .map(String::from)
                .to_vec();
        bypass_chat_approvals("codex", &mut codex_args);
        assert_eq!(codex_args, ["app-server", "--stdio", "-c", "model=\"o3\""]);
    }
}
