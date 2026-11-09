//! Addresses and directions of the pane layout, shared by the model, key handling, IPC and the
//! browser.

use serde::{Deserialize, Serialize};

/// One tab of one pane: the exact address of a terminal surface, agent, browser or document.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TerminalTarget {
    pub pane_id: String,
    pub tab_id: String,
}

impl TerminalTarget {
    pub fn new(pane_id: impl Into<String>, tab_id: impl Into<String>) -> Self {
        Self { pane_id: pane_id.into(), tab_id: tab_id.into() }
    }
}

/// A direction between panes (Swift `NavigationDirection`, raw values `left`/`right`/`up`/`down`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NavigationDirection {
    Left,
    Right,
    Up,
    Down,
}

impl NavigationDirection {
    /// Parses `left`, `right`, `up`, `down`.
    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            "up" => Some(Self::Up),
            "down" => Some(Self::Down),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Up => "up",
            Self::Down => "down",
        }
    }

    pub fn is_horizontal(self) -> bool {
        matches!(self, Self::Left | Self::Right)
    }
}

/// How a split divides its space (Swift `SplitDirection`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SplitDirection {
    /// Side by side (left | right).
    Horizontal,
    /// Stacked (top / bottom).
    Vertical,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directions_serialize_lowercase() {
        assert_eq!(serde_json::to_string(&NavigationDirection::Left).unwrap(), "\"left\"");
        assert_eq!(serde_json::to_string(&SplitDirection::Vertical).unwrap(), "\"vertical\"");
        for direction in [
            NavigationDirection::Left,
            NavigationDirection::Right,
            NavigationDirection::Up,
            NavigationDirection::Down,
        ] {
            assert_eq!(NavigationDirection::from_raw(direction.as_str()), Some(direction));
        }
    }
}
