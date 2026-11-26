//! The Mobile settings page: Tailscale HTTPS status, QR pairing code, paired devices, and
//! `mobile` keys in `settings.json`.

use chrono::{DateTime, Utc};
use soprano_config::{ConfigStore, Limits};
use soprano_mobile::{MobileObserver, MobileSource, MobileStateSnapshot, TailscaleStatus};

use crate::notifications::StatusTone;

pub const MOBILE_ENABLED_KEY: &[&str] = &["mobile", "enabled"];
pub const MOBILE_PORT_KEY: &[&str] = &["mobile", "port"];

pub const LEAD: &str = "Access your Soprano agents from your phone as a private PWA over Tailscale HTTPS. Soprano binds only to localhost and uses tailscale serve for automatic TLS certificates.";
pub const PAIRING_NOTE: &str = "Scan with your phone's camera while connected to Tailscale. Each code is single-use and expires after 5 minutes. On iOS or Android, add the page to your Home Screen for full-screen app mode.";
pub const NO_DEVICES_TITLE: &str = "No paired devices";
pub const NO_DEVICES_HINT: &str = "Scan the QR code above with your phone to pair it.";

pub fn set_enabled(store: &ConfigStore, enabled: bool) -> bool {
    store.write(enabled, MOBILE_ENABLED_KEY)
}

pub fn set_port(store: &ConfigStore, port: u16) -> bool {
    store.write(i64::from(port), MOBILE_PORT_KEY)
}

pub fn reset_port(store: &ConfigStore) -> bool {
    store.remove(MOBILE_PORT_KEY)
}

pub fn parse_port(raw: &str) -> Option<u16> {
    let parsed: i64 = raw.trim().parse().ok()?;
    Limits::MOBILE_PORT.contains(&parsed).then_some(parsed as u16)
}

/// Presentation of Tailscale connection status for the Settings status row.
pub struct MobileStatusRow {
    pub tone: StatusTone,
    pub title: String,
    pub description: String,
    pub action: Option<(&'static str, String)>,
}

pub fn status_row(snapshot: &MobileStateSnapshot) -> MobileStatusRow {
    if !snapshot.enabled {
        return MobileStatusRow {
            tone: StatusTone::Normal,
            title: "Mobile access is off".into(),
            description: "Turn it on to serve Soprano over Tailscale HTTPS.".into(),
            action: None,
        };
    }
    if snapshot.checking {
        return MobileStatusRow {
            tone: StatusTone::Normal,
            title: "Connecting to Tailscale…".into(),
            description: "Checking Tailscale status and configuring HTTPS proxy.".into(),
            action: None,
        };
    }
    match &snapshot.tailscale {
        TailscaleStatus::Disabled => MobileStatusRow {
            tone: StatusTone::Normal,
            title: "Mobile access is off".into(),
            description: "Turn it on to serve Soprano over Tailscale HTTPS.".into(),
            action: None,
        },
        TailscaleStatus::NotInstalled => MobileStatusRow {
            tone: StatusTone::Error,
            title: "Tailscale not found".into(),
            description: "Install Tailscale on this computer and your phone so Soprano can serve a private HTTPS endpoint.".into(),
            action: snapshot.tailscale.setup_url().map(|(l, u)| (l, u.to_owned())),
        },
        TailscaleStatus::NotRunning { state } => MobileStatusRow {
            tone: StatusTone::Error,
            title: format!("Tailscale is {state}"),
            description: "Start and connect Tailscale on this computer, then refresh.".into(),
            action: None,
        },
        TailscaleStatus::HttpsDisabled { admin_url, .. } => MobileStatusRow {
            tone: StatusTone::Error,
            title: "Tailscale HTTPS certificates are off".into(),
            description: "Enable MagicDNS and HTTPS Certificates in your Tailscale admin console so iOS and Android can install the PWA.".into(),
            action: Some(("Open Tailscale DNS settings", admin_url.clone())),
        },
        TailscaleStatus::ServeNeedsEnable { enable_url, .. } => MobileStatusRow {
            tone: StatusTone::Error,
            title: "Enable Tailscale Serve once".into(),
            description: "Approve Tailscale Serve on your tailnet, then click Refresh.".into(),
            action: Some(("Enable Tailscale Serve", enable_url.clone())),
        },
        TailscaleStatus::Ready { https_url, .. } => {
            let clients = match snapshot.connected_clients {
                0 => String::new(),
                1 => " · 1 phone connected".into(),
                n => format!(" · {n} phones connected"),
            };
            MobileStatusRow {
                tone: StatusTone::Success,
                title: format!("Connected via Tailscale{clients}"),
                description: https_url.clone(),
                action: None,
            }
        }
        TailscaleStatus::Error { message } => MobileStatusRow {
            tone: StatusTone::Error,
            title: "Could not start Tailscale HTTPS".into(),
            description: message.clone(),
            action: None,
        },
    }
}

/// Formats how long ago `then` was relative to `now` (e.g. `"Just now"`, `"4m ago"`, `"2h ago"`).
pub fn relative_ago(then: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let secs = (now - then).num_seconds().max(0);
    if secs < 45 {
        return "Just now".into();
    }
    let mins = secs / 60;
    if mins < 60 {
        return format!("{mins}m ago");
    }
    let hours = mins / 60;
    if hours < 24 {
        return format!("{hours}h ago");
    }
    let days = hours / 24;
    format!("{days}d ago")
}

/// Formats remaining time until `expires_at` relative to `now`.
pub fn expires_in(expires_at: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let secs = (expires_at - now).num_seconds();
    if secs <= 0 {
        return "Expired — regenerate to pair".into();
    }
    let mins = (secs + 59) / 60;
    if mins <= 1 { "Expires in < 1 minute".into() } else { format!("Expires in {mins} minutes") }
}

/// No-op [`MobileSource`] used when Settings runs standalone without a live mobile server.
#[derive(Default)]
pub struct DisabledMobileSource;

impl MobileSource for DisabledMobileSource {
    fn snapshot(&self) -> MobileStateSnapshot {
        MobileStateSnapshot::default()
    }
    fn add_observer(&self, _: &str, _: MobileObserver) {}
    fn remove_observer(&self, _: &str) {}
    fn refresh(&self) {}
    fn regenerate_pairing(&self) {}
    fn revoke_device(&self, _: &str) {}
    fn revoke_all_devices(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_types::{AgentCatalog, DefaultAgents};
    use std::sync::Arc;

    fn store() -> (ConfigStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = ConfigStore::with_catalog(
            dir.path().join("settings.json"),
            Arc::new(AgentCatalog::new(DefaultAgents::all())),
        );
        store.start(false, &AppSettings::default(), &DefaultKeybindings::config());
        (store, dir)
    }

    #[test]
    fn toggling_mobile_and_setting_port_writes_settings_json() {
        let (store, _dir) = store();
        assert!(!store.resolved().settings.mobile.enabled);
        assert!(set_enabled(&store, true));
        assert!(store.resolved().settings.mobile.enabled);
        assert!(set_port(&store, 9443));
        assert_eq!(store.resolved().settings.mobile.port, Some(9443));
        assert!(reset_port(&store));
        assert_eq!(store.resolved().settings.mobile.port, None);
    }

    #[test]
    fn port_parser_enforces_valid_bounds() {
        assert_eq!(parse_port("8443"), Some(8443));
        assert_eq!(parse_port("80"), None);
        assert_eq!(parse_port("70000"), None);
        assert_eq!(parse_port("abc"), None);
    }
}
