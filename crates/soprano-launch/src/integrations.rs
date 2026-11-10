//! Launch-scoped hook injection per agent CLI: nothing is written to the user's own agent
//! configuration; every hook rides on the command line or the pane's environment.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Map, Value, json};

use crate::quote::toml_quoted;

/// How Codex signals an approval request from its terminal UI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexApprovalSignal {
    /// An OSC 9 desktop notification (a pane on this computer).
    Osc9,
    /// The terminal bell: tmux, which keeps panes on a machine, drops OSC 9 but passes it on.
    Bell,
}

/// Codex appends its notification payload as a trailing JSON argument to the configured
/// notify program, so `agent-event` picks the message out of the arguments without any extra
/// flag here. Approval requests arrive from the TUI as `approvals`. `program` is how to run
/// `soprano` (its path, or a trampoline on a remote machine).
pub fn codex_integration_arguments(program: &[&str], approvals: CodexApprovalSignal) -> Vec<String> {
    let notify = program
        .iter()
        .chain(&["agent-event", "needs-input", "--notify", "--title", "Codex", "--body", "Response ready"])
        .map(|part| toml_quoted(part))
        .collect::<Vec<_>>()
        .join(",");
    let method = match approvals {
        CodexApprovalSignal::Osc9 => "osc9",
        CodexApprovalSignal::Bell => "bel",
    };
    vec![
        "-c".into(),
        format!("notify=[{notify}]"),
        "-c".into(),
        "tui.notifications=[\"approval-requested\"]".into(),
        "-c".into(),
        format!("tui.notification_method=\"{method}\""),
        "-c".into(),
        "tui.notification_condition=\"always\"".into(),
    ]
}

/// The JSON passed to Claude Code's `--settings`.
///
/// Claude Code pipes each hook a JSON payload on stdin. The notifying hooks forward it so the
/// banner can quote what the agent actually asked; `--body` stays as the fallback when the
/// payload carries no readable message.
pub fn claude_integration_settings() -> String {
    fn command(state: &str, notify: bool, body: Option<&str>) -> String {
        let mut value =
            format!("test -z \"$SOPRANO_BIN\" || \"$SOPRANO_BIN\" agent-event {state} --message-from-stdin");
        if notify {
            value.push_str(" --notify --title \"Claude Code\"");
        }
        if let Some(body) = body {
            value.push_str(&format!(" --body \"{body}\""));
        }
        value
    }
    fn hook(command: String) -> Value {
        json!([{ "hooks": [{ "type": "command", "command": command, "timeout": 5 }] }])
    }
    let settings = json!({
        "hooks": {
            // Claude Code also starts a session after compacting the context mid-turn; READY
            // then would claim a working agent is done.
            "SessionStart": [{
                "matcher": "startup|resume|clear",
                "hooks": [{ "type": "command", "command": command("ready", false, None), "timeout": 5 }],
            }],
            "UserPromptSubmit": hook(command("running", false, None)),
            "SessionEnd": hook(command("stopped", false, None)),
            "Stop": hook(command("needs-input", true, Some("Response ready"))),
            "Notification": [{
                // idle_prompt is what Claude Code sends when it finishes and sits waiting;
                // leaving it out meant the most common reason to look at a pane never
                // reached this hook.
                "matcher": "idle_prompt|permission_prompt|elicitation_dialog",
                "hooks": [{
                    "type": "command",
                    "command": command("needs-input", true, Some("Approval or input required")),
                    "timeout": 5,
                }],
            }],
        }
    });
    settings.to_string()
}

/// `OPENCODE_CONFIG_CONTENT`: the inherited override (which wins; a malformed one leaves the
/// variable alone) plus Soprano's server plugin.
///
/// A run's model goes into the inline config, which OpenCode 1.x and OpenCode 2's private
/// `--standalone` server read. OpenCode 2 prefers an agent's own model, so the model is also
/// pinned on `model_agents`.
pub fn opencode_config_content(
    plugin_url: &str,
    model: Option<&str>,
    model_agents: &[String],
    environment: &BTreeMap<String, String>,
) -> Option<String> {
    let mut content = Map::new();
    if let Some(inherited) = environment.get("OPENCODE_CONFIG_CONTENT").filter(|v| !v.is_empty()) {
        content = serde_json::from_str::<Map<String, Value>>(inherited).ok()?;
    }

    // Like Swift's `as? [String]`: a list with anything but strings starts over.
    let mut plugins: Vec<String> = content
        .get("plugin")
        .and_then(Value::as_array)
        .and_then(|list| list.iter().map(|v| v.as_str().map(str::to_owned)).collect())
        .unwrap_or_default();
    if !plugins.iter().any(|p| p == plugin_url) {
        plugins.push(plugin_url.to_owned());
    }
    content.insert("plugin".into(), json!(plugins));

    if let Some(model) = model {
        content.insert("model".into(), json!(model));
        let mut agents = content.get("agents").and_then(Value::as_object).cloned().unwrap_or_default();
        for id in model_agents {
            let mut agent = agents.get(id).and_then(Value::as_object).cloned().unwrap_or_default();
            agent.insert("model".into(), json!(model));
            agents.insert(id.clone(), Value::Object(agent));
        }
        if !agents.is_empty() {
            content.insert("agents".into(), Value::Object(agents));
        }
    }
    Some(Value::Object(content).to_string())
}

/// `OPENCODE_CLI_CONFIG_CONTENT`.
///
/// OpenCode 2 merges `OPENCODE_CLI_CONFIG_CONTENT` over `cli.json` but lets its arrays replace
/// the file's, so the plugin list starts from the inherited override or the user's own
/// `cli.json`: their terminal plugins keep loading.
pub fn opencode_cli_config_content(
    plugin_path: &str,
    environment: &BTreeMap<String, String>,
    home: &Path,
) -> Option<String> {
    let mut content = Map::new();
    if let Some(inherited) = environment.get("OPENCODE_CLI_CONFIG_CONTENT").filter(|v| !v.is_empty()) {
        content = serde_json::from_str::<Map<String, Value>>(inherited).ok()?;
    }
    let mut plugins = match content.get("plugins").and_then(Value::as_array) {
        Some(list) => list.clone(),
        None => user_opencode_cli_plugins(environment, home),
    };
    if !plugins.iter().any(|p| p.as_str() == Some(plugin_path)) {
        plugins.push(json!(plugin_path));
    }
    content.insert("plugins".into(), Value::Array(plugins));
    Some(Value::Object(content).to_string())
}

/// The `plugins` of `$XDG_CONFIG_HOME/opencode/cli.json` (else `~/.config/opencode/cli.json`),
/// with relative paths made absolute: they resolve against that file, which inline settings
/// do not have.
fn user_opencode_cli_plugins(environment: &BTreeMap<String, String>, home: &Path) -> Vec<Value> {
    let config_home = environment
        .get("XDG_CONFIG_HOME")
        .map(Path::new)
        .filter(|p| p.is_absolute())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| home.join(".config"));
    let directory = config_home.join("opencode");
    let Ok(text) = std::fs::read_to_string(directory.join("cli.json")) else { return vec![] };
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(&strict_json(&text)) else { return vec![] };
    let Some(Value::Array(plugins)) = object.get("plugins") else { return vec![] };

    let absolute = |spec: &str| -> String {
        if spec.starts_with("./") || spec.starts_with("../") {
            soprano_platform::paths::normalize(&directory.join(spec)).to_string_lossy().into_owned()
        } else {
            spec.to_owned()
        }
    };
    plugins
        .iter()
        .map(|entry| match entry {
            Value::String(spec) => json!(absolute(spec)),
            Value::Object(object) => match object.get("package").and_then(Value::as_str) {
                Some(spec) => {
                    let mut object = object.clone();
                    object.insert("package".into(), json!(absolute(spec)));
                    Value::Object(object)
                }
                None => entry.clone(),
            },
            other => other.clone(),
        })
        .collect()
}

/// JSONC → JSON: drops `//` and `/* */` comments and trailing commas outside strings.
pub(crate) fn strict_json(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    // A comma and the whitespace after it, held until the next token shows whether it trails.
    let mut pending: Option<String> = None;
    let mut i = 0;
    let mut in_string = false;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            out.push(c);
            if c == '\\' {
                if let Some(&next) = chars.get(i + 1) {
                    out.push(next);
                    i += 1;
                }
            } else if c == '"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        match (c, chars.get(i + 1)) {
            ('/', Some('/')) => {
                while i < chars.len() && chars[i] != '\n' {
                    i += 1;
                }
                continue;
            }
            ('/', Some('*')) => {
                i += 2;
                while i < chars.len() && !(chars[i] == '*' && chars.get(i + 1) == Some(&'/')) {
                    i += 1;
                }
                i += 2;
                continue;
            }
            _ if c.is_whitespace() => match pending.as_mut() {
                Some(held) => held.push(c),
                None => out.push(c),
            },
            _ => {
                if let Some(held) = pending.take() {
                    if c == '}' || c == ']' {
                        out.push_str(&held[1..]);
                    } else {
                        out.push_str(&held);
                    }
                }
                match c {
                    ',' => pending = Some(",".into()),
                    '"' => {
                        in_string = true;
                        out.push(c);
                    }
                    _ => out.push(c),
                }
            }
        }
        i += 1;
    }
    if let Some(held) = pending {
        out.push_str(&held);
    }
    out
}

/// A `file://` URL for an absolute path, percent-encoded like Foundation's
/// `URL.absoluteString` (what OpenCode's `plugin` list takes).
pub fn file_url(path: &Path) -> String {
    let mut text = path.to_string_lossy().replace('\\', "/");
    if !text.starts_with('/') {
        // Windows drive paths: file:///C:/…
        text.insert(0, '/');
    }
    let mut url = String::from("file://");
    for byte in text.bytes() {
        let keep = byte.is_ascii_alphanumeric() || b"-._~/!$&'()*+,;=:@".contains(&byte);
        if keep {
            url.push(byte as char);
        } else {
            url.push_str(&format!("%{byte:02X}"));
        }
    }
    url
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonc_comments_and_trailing_commas_are_removed_outside_strings() {
        let text = "{\n // note\n \"a\": \"x // y\", /* b */ \"c\": [1, 2,],\n}";
        let value: Value = serde_json::from_str(&strict_json(text)).expect("valid json");
        assert_eq!(value, json!({ "a": "x // y", "c": [1, 2] }));
    }

    #[test]
    fn file_urls_percent_encode_spaces() {
        assert_eq!(file_url(Path::new("/A b/Soprano.js")), "file:///A%20b/Soprano.js");
    }

    #[test]
    fn claude_settings_carry_every_lifecycle_hook() {
        let settings: Value = serde_json::from_str(&claude_integration_settings()).expect("json");
        for event in ["SessionStart", "UserPromptSubmit", "SessionEnd", "Stop", "Notification"] {
            assert!(settings["hooks"][event].is_array(), "{event}");
        }
        assert_eq!(settings["hooks"]["SessionStart"][0]["matcher"], "startup|resume|clear");
        assert_eq!(
            settings["hooks"]["Stop"][0]["hooks"][0]["command"],
            "test -z \"$SOPRANO_BIN\" || \"$SOPRANO_BIN\" agent-event needs-input --message-from-stdin \
             --notify --title \"Claude Code\" --body \"Response ready\""
        );
    }
}
