//! Dev builds (`visual-snapshot`): the hidden visual-QA subcommands' input actions. The app
//! dispatches them through the main window as real input (`debug-keys`, `debug-modifiers`,
//! `debug-type`, `debug-click`, `debug-move`, `debug-scroll`) and replies once it has redrawn.

use serde::{Deserialize, Serialize};

/// One input action for the main window; coordinates are whole window logical pixels.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum DebugInput {
    /// GPUI keystrokes (`cmd-p`, `shift-cmd-p`, `escape`, `a`), one frame apart.
    Keys {
        keystrokes: Vec<String>,
    },
    /// The held modifiers (`ctrl`, `cmd-shift`, …, or `none`).
    Modifiers {
        modifiers: String,
    },
    /// Text typed key by key into whatever has focus.
    Type {
        text: String,
    },
    Click {
        x: i32,
        y: i32,
        right: bool,
        double: bool,
    },
    Move {
        x: i32,
        y: i32,
    },
    /// A pixel scroll; positive `dy` scrolls content down (toward the end), like a wheel.
    Scroll {
        x: i32,
        y: i32,
        dy: i32,
    },
}

pub const USAGE: &str = "Usage:
  soprano debug-keys <keystroke>...            (GPUI syntax: cmd-p, shift-cmd-p, escape, a)
  soprano debug-modifiers <mods|none>          (ctrl, alt, shift, cmd, fn joined with -)
  soprano debug-type <text>
  soprano debug-click <x> <y> [--right] [--double]
  soprano debug-move <x> <y>
  soprano debug-scroll <x> <y> <dy>";

impl DebugInput {
    /// The action `command` (`debug-keys`, …) with `args` asks for; `None` when `command` is
    /// none of these, `Err` with the problem on bad arguments.
    pub fn parse(command: &str, args: &[String]) -> Option<Result<Self, String>> {
        let number =
            |value: &String| value.parse::<i32>().map_err(|_| format!("Not a whole number: {value}"));
        let point = |args: &[String]| -> Result<(i32, i32), String> {
            match args {
                [x, y] => Ok((number(x)?, number(y)?)),
                _ => Err("Expected <x> <y>.".to_owned()),
            }
        };
        Some(match command {
            "debug-keys" if args.is_empty() => Err("Name at least one keystroke.".to_owned()),
            "debug-keys" => Ok(Self::Keys { keystrokes: args.to_vec() }),
            "debug-modifiers" => match args {
                [modifiers] => Ok(Self::Modifiers { modifiers: modifiers.clone() }),
                _ => Err("Name the modifiers, or none.".to_owned()),
            },
            "debug-type" if args.is_empty() => Err("Name the text to type.".to_owned()),
            "debug-type" => Ok(Self::Type { text: args.join(" ") }),
            "debug-click" => {
                let (flags, coordinates): (Vec<&String>, Vec<&String>) =
                    args.iter().partition(|arg| arg.starts_with("--") && number(arg).is_err());
                if let Some(flag) = flags.iter().find(|flag| !matches!(flag.as_str(), "--right" | "--double"))
                {
                    return Some(Err(format!("Unknown option: {flag}")));
                }
                let coordinates: Vec<String> = coordinates.into_iter().cloned().collect();
                point(&coordinates).map(|(x, y)| Self::Click {
                    x,
                    y,
                    right: flags.iter().any(|flag| *flag == "--right"),
                    double: flags.iter().any(|flag| *flag == "--double"),
                })
            }
            "debug-move" => point(args).map(|(x, y)| Self::Move { x, y }),
            "debug-scroll" => match args {
                [x, y, dy] => (|| Ok(Self::Scroll { x: number(x)?, y: number(y)?, dy: number(dy)? }))(),
                _ => Err("Expected <x> <y> <dy>.".to_owned()),
            },
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn debug_input_commands_parse_their_arguments() {
        assert_eq!(
            DebugInput::parse("debug-keys", &args(&["cmd-p", "escape"])),
            Some(Ok(DebugInput::Keys { keystrokes: args(&["cmd-p", "escape"]) }))
        );
        assert_eq!(
            DebugInput::parse("debug-click", &args(&["--double", "10", "20", "--right"])),
            Some(Ok(DebugInput::Click { x: 10, y: 20, right: true, double: true }))
        );
        assert_eq!(
            DebugInput::parse("debug-scroll", &args(&["1", "2", "-30"])),
            Some(Ok(DebugInput::Scroll { x: 1, y: 2, dy: -30 }))
        );
        assert_eq!(
            DebugInput::parse("debug-type", &args(&["hello", "world"])),
            Some(Ok(DebugInput::Type { text: "hello world".to_owned() }))
        );
        assert!(matches!(DebugInput::parse("debug-click", &args(&["1", "2", "--left"])), Some(Err(_))));
        assert!(matches!(DebugInput::parse("debug-move", &args(&["1"])), Some(Err(_))));
        assert!(matches!(DebugInput::parse("debug-keys", &[]), Some(Err(_))));
        assert_eq!(DebugInput::parse("markdown", &[]), None);
    }
}
