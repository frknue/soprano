//! `soprano browser [--pane pane-id] <command> ...`: browser automation, routed only to the app
//! process that owns the calling terminal and answered over the same connection.

use std::collections::HashMap;
use std::path::Path;

use crate::caller_cwd;

pub const HELP: &str = "Usage:
  soprano browser open [url]
  soprano browser [--pane pane-id] goto <url>
  soprano browser [--pane pane-id] back|forward|reload|url|title
  soprano browser [--pane pane-id] snapshot [--interactive]
  soprano browser [--pane pane-id] eval <javascript>
  soprano browser [--pane pane-id] click|dblclick|focus|hover <selector|@ref>
  soprano browser [--pane pane-id] fill|type <selector|@ref> <text>
  soprano browser [--pane pane-id] check|uncheck|scroll-into-view <selector|@ref>
  soprano browser [--pane pane-id] press <key>
  soprano browser [--pane pane-id] get <text|html|value|attr|count> <selector> [attribute]
  soprano browser [--pane pane-id] is <visible|enabled|checked> <selector|@ref>
  soprano browser [--pane pane-id] screenshot <path.png>

`snapshot` assigns ephemeral refs such as `e1`; pass them back as `@e1`.";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrowserCommandRequest {
    pub command: String,
    pub arguments: Vec<String>,
    pub target_pane_id: Option<String>,
}

impl BrowserCommandRequest {
    /// `Ok(None)` when the invocation is not `browser`; `Err(message)` for invalid arguments.
    /// The command `help` means: print [`HELP`].
    pub fn parse(
        command_line: &[String],
        environment: &HashMap<String, String>,
        current_directory: &Path,
    ) -> Result<Option<Self>, String> {
        if command_line.len() < 2 || command_line[1] != "browser" {
            return Ok(None);
        }
        let mut tokens = &command_line[2..];
        let help = |target_pane_id| Self { command: "help".into(), arguments: Vec::new(), target_pane_id };
        if tokens.is_empty() || tokens == ["--help"] || tokens == ["help"] {
            return Ok(Some(help(None)));
        }

        // `--pane` is only an option immediately after `browser`; later tokens belong to the
        // command (`fill #q --pane` types the literal text).
        let mut target_pane_id = None;
        if tokens[0] == "--pane" {
            let Some(pane) = tokens.get(1) else { return Err("--pane requires a pane ID".into()) };
            target_pane_id = Some(pane.clone());
            tokens = &tokens[2..];
        }

        let Some((command, rest)) = tokens.split_first() else { return Ok(Some(help(target_pane_id))) };
        let mut arguments = rest.to_vec();
        if command == "screenshot"
            && let Some(path) = arguments.first_mut()
            && !Path::new(path.as_str()).is_absolute()
        {
            let full = caller_cwd::resolve(environment, current_directory).join(path.as_str());
            *path = soprano_platform::paths::normalize(&full).to_string_lossy().into_owned();
        }
        Ok(Some(Self { command: command.clone(), arguments, target_pane_id }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(values: &[&str]) -> Result<Option<BrowserCommandRequest>, String> {
        let arguments: Vec<String> = values.iter().map(|v| v.to_string()).collect();
        BrowserCommandRequest::parse(&arguments, &HashMap::new(), Path::new("/tmp/browser-project"))
    }

    #[cfg(unix)]
    #[test]
    fn browser_command_parser_accepts_pane_target_and_normalizes_screenshot_path() {
        assert_eq!(
            parse(&["soprano", "browser", "--pane", "pane-8", "click", "@e2"]),
            Ok(Some(BrowserCommandRequest {
                command: "click".into(),
                arguments: vec!["@e2".into()],
                target_pane_id: Some("pane-8".into())
            }))
        );
        let screenshot = parse(&["soprano", "browser", "screenshot", "artifacts/page.png"]).unwrap().unwrap();
        assert_eq!(screenshot.arguments, vec!["/tmp/browser-project/artifacts/page.png".to_string()]);
        assert_eq!(
            parse(&["soprano", "browser", "fill", "#q", "--pane"]),
            Ok(Some(BrowserCommandRequest {
                command: "fill".into(),
                arguments: vec!["#q".into(), "--pane".into()],
                target_pane_id: None
            }))
        );
    }

    #[test]
    fn help_and_a_dangling_pane_option_are_recognized() {
        assert_eq!(parse(&["soprano", "browser"]).unwrap().unwrap().command, "help");
        assert_eq!(parse(&["soprano", "browser", "--help"]).unwrap().unwrap().command, "help");
        assert_eq!(parse(&["soprano", "browser", "--pane"]), Err("--pane requires a pane ID".into()));
        assert_eq!(parse(&["soprano", "browser", "--pane", "pane-2"]).unwrap().unwrap().command, "help");
        assert_eq!(parse(&["soprano", "md"]), Ok(None));
    }
}
