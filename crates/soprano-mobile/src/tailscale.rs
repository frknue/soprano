//! Tailscale CLI integration: probing the local node's MagicDNS name and HTTPS capability,
//! and configuring private `tailscale serve` forwarding to Soprano's loopback server.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;

/// Raw output from invoking the `tailscale` CLI.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandOutput {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

/// Injectable runner for `tailscale` commands so tests never spawn a real binary.
pub trait TailscaleRunner: Send + Sync {
    fn is_installed(&self) -> bool;
    fn run(&self, args: &[&str]) -> Result<CommandOutput, String>;
}

/// Runs the system `tailscale` binary, checking `$PATH` and standard macOS/Windows install
/// locations (the standalone macOS Tailscale.app hides its CLI inside the bundle).
#[derive(Clone, Debug, Default)]
pub struct SystemTailscaleRunner;

impl SystemTailscaleRunner {
    pub fn find_binary() -> Option<PathBuf> {
        if let Ok(path_var) = std::env::var("PATH") {
            let exe_name = if cfg!(windows) { "tailscale.exe" } else { "tailscale" };
            for dir in std::env::split_paths(&path_var) {
                let candidate = dir.join(exe_name);
                if is_executable(&candidate) {
                    return Some(candidate);
                }
            }
        }
        for candidate in fallback_binary_paths() {
            let path = Path::new(candidate);
            if is_executable(path) {
                return Some(path.to_path_buf());
            }
        }
        None
    }
}

fn fallback_binary_paths() -> &'static [&'static str] {
    #[cfg(target_os = "macos")]
    {
        &[
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
    }
    #[cfg(target_os = "windows")]
    {
        &[r"C:\Program Files\Tailscale\tailscale.exe"]
    }
    #[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
    {
        &["/usr/bin/tailscale", "/usr/local/bin/tailscale"]
    }
}

fn is_executable(path: &Path) -> bool {
    path.is_file()
}

impl TailscaleRunner for SystemTailscaleRunner {
    fn is_installed(&self) -> bool {
        Self::find_binary().is_some()
    }

    fn run(&self, args: &[&str]) -> Result<CommandOutput, String> {
        let Some(bin) = Self::find_binary() else {
            return Err("Tailscale CLI was not found.".into());
        };
        let output =
            Command::new(bin).args(args).output().map_err(|err| format!("Failed to run tailscale: {err}"))?;
        Ok(CommandOutput {
            success: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

/// Tailscale DNS console where MagicDNS HTTPS certificates are enabled.
pub const TAILSCALE_DNS_ADMIN_URL: &str = "https://login.tailscale.com/admin/dns";

/// Current Tailscale connectivity and `tailscale serve` state as presented in Settings.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TailscaleStatus {
    /// Mobile access is switched off.
    Disabled,
    /// `tailscale` binary was not found.
    NotInstalled,
    /// Tailscale is installed, but not connected (`BackendState != "Running"`).
    NotRunning { state: String },
    /// Tailscale is running, but MagicDNS HTTPS certificates are not enabled on the tailnet.
    HttpsDisabled { dns_name: Option<String>, tailscale_ip: Option<String>, admin_url: String },
    /// Tailscale Serve must be enabled once on the user's tailnet via the returned URL.
    ServeNeedsEnable { dns_name: String, enable_url: String },
    /// Loopback server is running and exposed privately over Tailscale HTTPS.
    Ready { dns_name: String, tailscale_ip: Option<String>, https_url: String, port: u16 },
    /// Any unexpected error from Tailscale or local binding.
    Error { message: String },
}

impl TailscaleStatus {
    /// The HTTPS base URL (without trailing slash) when ready.
    pub fn https_url(&self) -> Option<&str> {
        match self {
            Self::Ready { https_url, .. } => Some(https_url.as_str()),
            _ => None,
        }
    }

    /// Action URL Settings can offer to open in the browser when Tailscale needs one-time setup.
    pub fn setup_url(&self) -> Option<(&'static str, &str)> {
        match self {
            Self::HttpsDisabled { admin_url, .. } => {
                Some(("Open Tailscale DNS settings", admin_url.as_str()))
            }
            Self::ServeNeedsEnable { enable_url, .. } => {
                Some(("Enable Tailscale Serve", enable_url.as_str()))
            }
            Self::NotInstalled => Some(("Get Tailscale", "https://tailscale.com/download")),
            _ => None,
        }
    }
}

/// Parsed fields from `tailscale status --json`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TailscaleNodeInfo {
    pub backend_state: String,
    pub dns_name: Option<String>,
    pub tailscale_ip: Option<String>,
    pub has_https_certs: bool,
    pub host_name: Option<String>,
}

#[derive(Deserialize)]
struct RawStatus {
    #[serde(rename = "BackendState", default)]
    backend_state: String,
    #[serde(rename = "CertDomains", default)]
    cert_domains: Option<Vec<String>>,
    #[serde(rename = "Self")]
    self_node: Option<RawSelfNode>,
}

#[derive(Deserialize)]
struct RawSelfNode {
    #[serde(rename = "DNSName", default)]
    dns_name: String,
    #[serde(rename = "HostName", default)]
    host_name: String,
    #[serde(rename = "TailscaleIPs", default)]
    tailscale_ips: Vec<String>,
}

/// Queries `tailscale status --json` and parses node info.
pub fn probe_node(runner: &dyn TailscaleRunner) -> Result<TailscaleNodeInfo, TailscaleStatus> {
    if !runner.is_installed() {
        return Err(TailscaleStatus::NotInstalled);
    }
    let output = runner.run(&["status", "--json"]).map_err(|message| TailscaleStatus::Error { message })?;
    if !output.success {
        let msg = first_non_empty(&output.stderr, &output.stdout).unwrap_or("tailscale status failed");
        return Err(TailscaleStatus::Error { message: msg.to_owned() });
    }
    parse_status_json(&output.stdout).map_err(|message| TailscaleStatus::Error { message })
}

/// Parses raw JSON output from `tailscale status --json`.
pub fn parse_status_json(json: &str) -> Result<TailscaleNodeInfo, String> {
    let parsed: RawStatus =
        serde_json::from_str(json).map_err(|err| format!("Could not read Tailscale status: {err}"))?;
    let dns_name = parsed
        .self_node
        .as_ref()
        .map(|node| node.dns_name.trim().trim_end_matches('.').to_owned())
        .filter(|name| !name.is_empty());
    let host_name = parsed
        .self_node
        .as_ref()
        .map(|node| node.host_name.trim().to_owned())
        .filter(|name| !name.is_empty());
    let tailscale_ip = parsed.self_node.as_ref().and_then(|node| {
        node.tailscale_ips.iter().find(|ip| ip.contains('.')).or_else(|| node.tailscale_ips.first()).cloned()
    });
    let has_https_certs =
        parsed.cert_domains.as_ref().is_some_and(|domains| domains.iter().any(|d| !d.trim().is_empty()));
    Ok(TailscaleNodeInfo {
        backend_state: parsed.backend_state,
        dns_name,
        tailscale_ip,
        has_https_certs,
        host_name,
    })
}

/// Outcome of configuring `tailscale serve`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServeOutcome {
    Configured,
    NeedsTailnetEnable { enable_url: String },
    Failed(String),
}

/// Exposes `http://127.0.0.1:<local_port>` over private Tailscale HTTPS on `<https_port>`.
pub fn enable_serve(runner: &dyn TailscaleRunner, https_port: u16, local_port: u16) -> ServeOutcome {
    let https_flag = format!("--https={https_port}");
    let target = format!("http://127.0.0.1:{local_port}");
    let output = match runner.run(&["serve", "--bg", &https_flag, &target]) {
        Ok(out) => out,
        Err(message) => return ServeOutcome::Failed(message),
    };
    if output.success {
        return ServeOutcome::Configured;
    }
    let combined = format!("{}\n{}", output.stderr, output.stdout);
    if let Some(url) = extract_https_url(&combined)
        && url.contains("tailscale.com")
    {
        return ServeOutcome::NeedsTailnetEnable { enable_url: url };
    }
    let msg = first_non_empty(&output.stderr, &output.stdout).unwrap_or("tailscale serve failed").to_owned();
    ServeOutcome::Failed(msg)
}

/// Removes the `tailscale serve` HTTPS handler for `<https_port>`.
pub fn disable_serve(runner: &dyn TailscaleRunner, https_port: u16) -> Result<(), String> {
    if !runner.is_installed() {
        return Ok(());
    }
    let https_flag = format!("--https={https_port}");
    let output = runner.run(&["serve", &https_flag, "off"])?;
    if output.success {
        return Ok(());
    }
    let msg = first_non_empty(&output.stderr, &output.stdout).unwrap_or("tailscale serve off failed");
    Err(msg.to_owned())
}

/// Probes Tailscale and configures `tailscale serve` to forward `<https_port>` → `127.0.0.1:<local_port>`.
pub fn connect_serve(runner: &dyn TailscaleRunner, https_port: u16, local_port: u16) -> TailscaleStatus {
    let info = match probe_node(runner) {
        Ok(info) => info,
        Err(status) => return status,
    };
    if info.backend_state != "Running" {
        return TailscaleStatus::NotRunning {
            state: if info.backend_state.is_empty() { "Stopped".into() } else { info.backend_state },
        };
    }
    let Some(dns_name) = info.dns_name else {
        return TailscaleStatus::HttpsDisabled {
            dns_name: None,
            tailscale_ip: info.tailscale_ip,
            admin_url: TAILSCALE_DNS_ADMIN_URL.into(),
        };
    };
    if !info.has_https_certs {
        return TailscaleStatus::HttpsDisabled {
            dns_name: Some(dns_name),
            tailscale_ip: info.tailscale_ip,
            admin_url: TAILSCALE_DNS_ADMIN_URL.into(),
        };
    }
    match enable_serve(runner, https_port, local_port) {
        ServeOutcome::Configured => {
            let https_url = if https_port == 443 {
                format!("https://{dns_name}")
            } else {
                format!("https://{dns_name}:{https_port}")
            };
            TailscaleStatus::Ready { dns_name, tailscale_ip: info.tailscale_ip, https_url, port: https_port }
        }
        ServeOutcome::NeedsTailnetEnable { enable_url } => {
            TailscaleStatus::ServeNeedsEnable { dns_name, enable_url }
        }
        ServeOutcome::Failed(message) => TailscaleStatus::Error { message },
    }
}

fn first_non_empty<'a>(a: &'a str, b: &'a str) -> Option<&'a str> {
    a.lines().chain(b.lines()).map(str::trim).find(|line| !line.is_empty())
}

fn extract_https_url(text: &str) -> Option<String> {
    text.split_whitespace()
        .find(|token| token.starts_with("https://"))
        .map(|token| token.trim_end_matches(&['.', ',', ')', '"', '\''][..]).to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct FakeRunner {
        installed: bool,
        responses: Mutex<Vec<Result<CommandOutput, String>>>,
        calls: Mutex<Vec<Vec<String>>>,
    }

    impl FakeRunner {
        fn new(installed: bool, responses: Vec<Result<CommandOutput, String>>) -> Self {
            Self { installed, responses: Mutex::new(responses), calls: Mutex::new(Vec::new()) }
        }

        fn calls(&self) -> Vec<Vec<String>> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl TailscaleRunner for FakeRunner {
        fn is_installed(&self) -> bool {
            self.installed
        }

        fn run(&self, args: &[&str]) -> Result<CommandOutput, String> {
            self.calls.lock().unwrap().push(args.iter().map(|s| (*s).to_owned()).collect());
            self.responses.lock().unwrap().remove(0)
        }
    }

    const RUNNING_WITH_HTTPS: &str = r#"{
        "BackendState": "Running",
        "CertDomains": ["macbook.tail1234.ts.net"],
        "Self": {
            "DNSName": "macbook.tail1234.ts.net.",
            "HostName": "macbook",
            "TailscaleIPs": ["100.64.1.2", "fd7a:115c:a1e0::1"]
        }
    }"#;

    #[test]
    fn parsing_status_strips_trailing_dot_and_prefers_ipv4() {
        let info = parse_status_json(RUNNING_WITH_HTTPS).expect("parses");
        assert_eq!(info.backend_state, "Running");
        assert_eq!(info.dns_name.as_deref(), Some("macbook.tail1234.ts.net"));
        assert_eq!(info.tailscale_ip.as_deref(), Some("100.64.1.2"));
        assert!(info.has_https_certs);
    }

    #[test]
    fn connect_serve_configures_https_forwarding_when_ready() {
        let runner = FakeRunner::new(
            true,
            vec![
                Ok(CommandOutput { success: true, stdout: RUNNING_WITH_HTTPS.into(), stderr: String::new() }),
                Ok(CommandOutput { success: true, stdout: String::new(), stderr: String::new() }),
            ],
        );
        let status = connect_serve(&runner, 8443, 51234);
        assert_eq!(
            status,
            TailscaleStatus::Ready {
                dns_name: "macbook.tail1234.ts.net".into(),
                tailscale_ip: Some("100.64.1.2".into()),
                https_url: "https://macbook.tail1234.ts.net:8443".into(),
                port: 8443,
            }
        );
        assert_eq!(
            runner.calls(),
            vec![vec!["status", "--json"], vec!["serve", "--bg", "--https=8443", "http://127.0.0.1:51234"],]
        );
    }

    #[test]
    fn connect_serve_reports_when_tailscale_https_certs_are_disabled() {
        let status_json = r#"{
            "BackendState": "Running",
            "CertDomains": null,
            "Self": { "DNSName": "macbook.tail1234.ts.net.", "TailscaleIPs": ["100.64.1.2"] }
        }"#;
        let runner = FakeRunner::new(
            true,
            vec![Ok(CommandOutput { success: true, stdout: status_json.into(), stderr: String::new() })],
        );
        let status = connect_serve(&runner, 8443, 51234);
        assert!(matches!(status, TailscaleStatus::HttpsDisabled { .. }));
    }

    #[test]
    fn connect_serve_extracts_tailnet_enable_url_when_serve_is_not_enabled() {
        let runner = FakeRunner::new(
            true,
            vec![
                Ok(CommandOutput { success: true, stdout: RUNNING_WITH_HTTPS.into(), stderr: String::new() }),
                Ok(CommandOutput {
                    success: false,
                    stdout: String::new(),
                    stderr: "Serve is not enabled on your tailnet.\nTo enable, visit:\n  https://login.tailscale.com/f/serve?node=abc123\n".into(),
                }),
            ],
        );
        let status = connect_serve(&runner, 8443, 51234);
        assert_eq!(
            status,
            TailscaleStatus::ServeNeedsEnable {
                dns_name: "macbook.tail1234.ts.net".into(),
                enable_url: "https://login.tailscale.com/f/serve?node=abc123".into(),
            }
        );
    }
}
