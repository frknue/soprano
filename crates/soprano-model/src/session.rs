//! The workspace snapshot format (`Models/WorkspaceSession.swift`): every live session, window,
//! layout tab, pane and pane tab, for save/restore.
//!
//! Field names and shapes match what the Swift app's `JSONEncoder` wrote (camelCase keys, `nil`
//! optionals omitted, `savedAt` as seconds since 2001-01-01), and every format it ever wrote
//! still decodes: windows without tabs (one layout), windows with depth layers (reopened as
//! tabs), snapshots without windows or sessions, tabs without titles or conversations.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use soprano_platform::StateStore;
use soprano_types::AgentConversation;

use crate::pane::{PaneType, Remote};
use crate::split_node::SplitNode;
use crate::window::TerminalSessionState;

/// Seconds between the Unix epoch and Foundation's reference date, 2001-01-01T00:00:00Z.
const REFERENCE_DATE_UNIX_SECONDS: f64 = 978_307_200.0;

/// A point in time as Foundation's `JSONEncoder` writes a `Date` by default: seconds since
/// 2001-01-01. Kept as the raw number so dates far outside `SystemTime`'s range (Swift's
/// `.distantPast`) still round-trip on every OS.
#[derive(Clone, Copy, Debug, Default, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ReferenceDate(pub f64);

impl ReferenceDate {
    /// Swift's `Date.distantPast` (0001-01-01).
    pub const DISTANT_PAST: ReferenceDate = ReferenceDate(-63_114_076_800.0);

    pub fn now() -> Self {
        Self::from_system_time(SystemTime::now())
    }

    pub fn from_system_time(time: SystemTime) -> Self {
        let unix = match time.duration_since(UNIX_EPOCH) {
            Ok(after) => after.as_secs_f64(),
            Err(before) => -before.duration().as_secs_f64(),
        };
        Self(unix - REFERENCE_DATE_UNIX_SECONDS)
    }

    /// The same instant as a `SystemTime`, or `None` when the platform cannot represent it.
    pub fn to_system_time(self) -> Option<SystemTime> {
        let unix = self.0 + REFERENCE_DATE_UNIX_SECONDS;
        if !unix.is_finite() {
            return None;
        }
        if unix >= 0.0 {
            UNIX_EPOCH.checked_add(Duration::try_from_secs_f64(unix).ok()?)
        } else {
            UNIX_EPOCH.checked_sub(Duration::try_from_secs_f64(-unix).ok()?)
        }
    }
}

/// A workspace snapshot containing every live session for save/restore.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSession {
    pub id: String,
    pub name: String,
    pub saved_at: ReferenceDate,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<SplitNode>,
    pub panes: Vec<SavedPane>,
    pub active_pane_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub windows: Option<Vec<SavedWindow>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_window_id: Option<String>,
    /// Missing in older snapshots, whose windows belong to one default session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_sessions: Option<Vec<TerminalSessionState>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedWindow {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_title_custom: Option<bool>,
    /// Optional for backward compatibility with sessions saved before sidebar disclosure
    /// state was persisted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_sidebar_collapsed: Option<bool>,
    /// The active tab's layout and focused pane. Builds without tabs restore them as the
    /// window's only layout.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<SplitNode>,
    pub active_pane_id: String,
    /// Missing in workspaces saved before windows had tabs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tabs: Option<Vec<SavedLayoutTab>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_tab_index: Option<i64>,
    /// Window depth from builds before tabs: one complete layout per layer, which reopen as
    /// tabs in the same order. Read, never written.
    #[serde(default, skip_serializing)]
    pub depth_layers: Option<Vec<SavedLayoutTab>>,
    #[serde(default, skip_serializing)]
    pub active_depth_layer_index: Option<i64>,
    /// The active layer of the first depth builds, which stacked layers.
    #[serde(default, skip_serializing)]
    pub active_depth: Option<i64>,
}

impl SavedWindow {
    /// The tabs this window reopens with, from whichever format wrote it: tabs, else depth
    /// layers, else the single layout of the oldest workspaces.
    pub fn restorable_tabs(&self) -> Vec<SavedLayoutTab> {
        self.tabs.clone().or_else(|| self.depth_layers.clone()).unwrap_or_else(|| {
            vec![SavedLayoutTab { layout: self.layout.clone(), active_pane_id: self.active_pane_id.clone() }]
        })
    }

    pub fn restorable_active_tab_index(&self) -> i64 {
        self.active_tab_index.or(self.active_depth_layer_index).or(self.active_depth).unwrap_or(0)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedLayoutTab {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<SplitNode>,
    pub active_pane_id: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedPane {
    pub id: String,
    pub active_tab_index: i64,
    pub tabs: Vec<SavedTab>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedTab {
    pub id: String,
    #[serde(rename = "type")]
    pub pane_type: PaneType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Optional so pre-reader sessions keep decoding, and older builds ignore this
    /// specialization while retaining the browser pane.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview_owner_pane_id: Option<String>,
    /// Missing in older workspaces, which continue to start fresh agents.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<AgentConversation>,
    /// The machine the tab's program runs on; restoring reattaches to it there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<Remote>,
}

impl SavedTab {
    /// A tab with only id and type set.
    pub fn new(id: impl Into<String>, pane_type: PaneType) -> Self {
        Self {
            id: id.into(),
            pane_type,
            profile_id: None,
            cwd: None,
            url: None,
            title: None,
            content_kind: None,
            preview_owner_pane_id: None,
            conversation: None,
            remote: None,
        }
    }
}

impl WorkspaceSession {
    /// A snapshot in the oldest format: one layout, no windows or sessions.
    pub fn legacy(
        id: impl Into<String>,
        name: impl Into<String>,
        layout: Option<SplitNode>,
        panes: Vec<SavedPane>,
        active_pane_id: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            saved_at: ReferenceDate::DISTANT_PAST,
            layout,
            panes,
            active_pane_id: active_pane_id.into(),
            windows: None,
            active_window_id: None,
            terminal_sessions: None,
        }
    }

    // MARK: - Session List Persistence

    pub const SESSIONS_KEY: &'static str = "soprano-sessions";
    pub const LAST_SESSION_KEY: &'static str = "soprano-last-session";

    /// The saved named workspaces; empty when none are stored or the list does not decode.
    pub fn load_all(store: &StateStore) -> Vec<WorkspaceSession> {
        store.get(Self::SESSIONS_KEY).unwrap_or_default()
    }

    pub fn save_all(sessions: &[WorkspaceSession], store: &StateStore) {
        store.set(Self::SESSIONS_KEY, sessions);
    }

    // MARK: - Last Session Persistence

    pub fn load_last(store: &StateStore) -> Option<WorkspaceSession> {
        store.get(Self::LAST_SESSION_KEY)
    }

    pub fn save_last(session: &WorkspaceSession, store: &StateStore) {
        store.set(Self::LAST_SESSION_KEY, session);
    }

    pub fn clear_last(store: &StateStore) {
        store.remove(Self::LAST_SESSION_KEY);
    }
}
