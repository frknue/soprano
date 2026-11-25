//! The providers' own rate-limit endpoints — the same ones Claude Code, the
//! Codex CLI and omp read.

use std::sync::LazyLock;
use std::time::Duration;

use chrono::DateTime;
use regex::Regex;
use serde_json::Value;

use crate::models::{
    AccountIdentity, AccountUsage, Timestamp, UsageWindow, seconds_since_epoch, timestamp_from_seconds,
};

/// A valid access token for one row, used to ask the provider about that
/// account's usage when omp does not report on it.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageCredential {
    pub row_id: String,
    pub identity: AccountIdentity,
    pub access_token: String,
    /// Codex: the ChatGPT account id the request is made for.
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UsageApiError {
    #[error("The usage service answered {0}.")]
    Http(u16),
    #[error("The usage service sent something Soprano could not read.")]
    Unreadable,
    #[error("{0}")]
    Transport(String),
}

pub const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const CLAUDE_PROFILE_URL: &str = "https://api.anthropic.com/api/oauth/profile";
pub const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const ANTIGRAVITY_PRIMARY_ENDPOINT: &str = "https://daily-cloudcode-pa.googleapis.com";
pub const ANTIGRAVITY_SANDBOX_ENDPOINT: &str = "https://daily-cloudcode-pa.sandbox.googleapis.com";
const ANTIGRAVITY_LOAD_CODE_ASSIST_PATH: &str = "/v1internal:loadCodeAssist";
const ANTIGRAVITY_QUOTA_SUMMARY_PATH: &str = "/v1internal:retrieveUserQuotaSummary";
const ANTIGRAVITY_FETCH_MODELS_PATH: &str = "/v1internal:fetchAvailableModels";

pub fn claude_usage(access_token: &str) -> Result<AccountUsage, UsageApiError> {
    let data = get(CLAUDE_USAGE_URL, &claude_headers(access_token))?;
    parse_claude_usage(&data, chrono::Utc::now())
}

/// Who an access token belongs to: proof of identity independent of the
/// files that merely claim it.
pub fn claude_profile(access_token: &str) -> Result<AccountIdentity, UsageApiError> {
    let data = get(CLAUDE_PROFILE_URL, &claude_headers(access_token))?;
    parse_claude_profile(&data).ok_or(UsageApiError::Unreadable)
}

pub fn codex_usage(access_token: &str, account_id: Option<&str>) -> Result<AccountUsage, UsageApiError> {
    let mut headers = vec![
        ("Authorization", format!("Bearer {access_token}")),
        ("User-Agent", "codex-cli".to_owned()),
        ("Accept", "application/json".to_owned()),
    ];
    if let Some(account_id) = account_id {
        headers.push(("ChatGPT-Account-Id", account_id.to_owned()));
    }
    let data = get(CODEX_USAGE_URL, &headers)?;
    parse_codex_usage(&data, chrono::Utc::now())
}

/// Fetches Antigravity quota windows via Cloud Code Assist: resolves the account's
/// `cloudaicompanionProject` through `loadCodeAssist`, then reads `retrieveUserQuotaSummary`
/// (falling back to `fetchAvailableModels`).
pub fn antigravity_usage(access_token: &str) -> Result<AccountUsage, UsageApiError> {
    let headers = antigravity_headers(access_token);
    let load_body = br#"{"metadata":{"ideType":"ANTIGRAVITY"}}"#;
    let project_id = post_antigravity(ANTIGRAVITY_LOAD_CODE_ASSIST_PATH, &headers, load_body)
        .ok()
        .and_then(|data| parse_antigravity_project(&data));
    let quota_body = match project_id {
        Some(project) => serde_json::json!({ "project": project }).to_string().into_bytes(),
        None => b"{}".to_vec(),
    };
    let now = chrono::Utc::now();
    if let Ok(summary_data) = post_antigravity(ANTIGRAVITY_QUOTA_SUMMARY_PATH, &headers, &quota_body)
        && let Ok(usage) = parse_antigravity_quota_summary(&summary_data, now)
    {
        return Ok(usage);
    }
    let models_data = post_antigravity(ANTIGRAVITY_FETCH_MODELS_PATH, &headers, &quota_body)?;
    parse_antigravity_models_usage(&models_data, now)
}

// MARK: - Parsing

/// `{"five_hour": {"utilization": 9, "resets_at": "…"}, "seven_day": …}`;
/// utilization is a percentage.
pub fn parse_claude_usage(data: &[u8], now: Timestamp) -> Result<AccountUsage, UsageApiError> {
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(data) else {
        return Err(UsageApiError::Unreadable);
    };
    let buckets = [
        ("five_hour", "5h"),
        ("seven_day", "7d"),
        ("seven_day_opus", "7d opus"),
        ("seven_day_sonnet", "7d sonnet"),
    ];
    let mut windows = Vec::new();
    for (key, label) in buckets {
        let Some(entry) = object.get(key).and_then(Value::as_object) else { continue };
        let Some(utilization) = entry.get("utilization").and_then(number) else { continue };
        windows.push(UsageWindow {
            label: label.to_owned(),
            used_fraction: utilization.max(0.0) / 100.0,
            resets_at: entry.get("resets_at").and_then(date),
        });
    }
    if windows.is_empty() {
        return Err(UsageApiError::Unreadable);
    }
    Ok(AccountUsage { windows, fetched_at: now })
}

/// `{"account": {"email": …}, "organization": {"uuid": …}}`.
pub fn parse_claude_profile(data: &[u8]) -> Option<AccountIdentity> {
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(data) else { return None };
    let account = object.get("account").and_then(Value::as_object);
    let organization = object.get("organization").and_then(Value::as_object);
    let field = |key: &str| account.and_then(|account| account.get(key)).and_then(Value::as_str);
    let email = field("email")
        .or_else(|| field("email_address"))
        .or_else(|| object.get("email").and_then(Value::as_str))?;
    if email.is_empty() {
        return None;
    }
    let organization_id = organization
        .and_then(|organization| organization.get("uuid"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    Some(AccountIdentity::new(email, organization_id))
}

/// `{"rate_limit": {"primary_window": {"used_percent": 15,
/// "limit_window_seconds": 604800, "reset_at": 1791959189}, …}}`.
pub fn parse_codex_usage(data: &[u8], now: Timestamp) -> Result<AccountUsage, UsageApiError> {
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(data) else {
        return Err(UsageApiError::Unreadable);
    };
    let Some(rate_limit) = object.get("rate_limit").and_then(Value::as_object) else {
        return Err(UsageApiError::Unreadable);
    };
    let mut windows = Vec::new();
    for key in ["primary_window", "secondary_window"] {
        let Some(entry) = rate_limit.get(key).and_then(Value::as_object) else { continue };
        let Some(used_percent) = entry.get("used_percent").and_then(number) else { continue };
        let seconds = entry.get("limit_window_seconds").and_then(number);
        let mut resets_at = entry.get("reset_at").and_then(date);
        if resets_at.is_none()
            && let Some(after) = entry.get("reset_after_seconds").and_then(number)
        {
            resets_at = timestamp_from_seconds(seconds_since_epoch(&now) + after);
        }
        let label = match seconds {
            Some(seconds) => window_label(seconds),
            None if key == "primary_window" => "primary".to_owned(),
            None => "secondary".to_owned(),
        };
        windows.push(UsageWindow { label, used_fraction: used_percent.clamp(0.0, 100.0) / 100.0, resets_at });
    }
    if windows.is_empty() {
        return Err(UsageApiError::Unreadable);
    }
    Ok(AccountUsage { windows, fetched_at: now })
}

/// "5h" for 18 000 s, "7d" for 604 800 s.
pub fn window_label(seconds: f64) -> String {
    let hours = (seconds / 3600.0).round() as i64;
    if hours < 24 || hours % 24 != 0 { format!("{hours}h") } else { format!("{}d", hours / 24) }
}

/// Extracts `cloudaicompanionProject` from a `loadCodeAssist` response.
pub fn parse_antigravity_project(data: &[u8]) -> Option<String> {
    let Value::Object(object) = serde_json::from_slice::<Value>(data).ok()? else { return None };
    object.get("cloudaicompanionProject").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
}

/// Parses `retrieveUserQuotaSummary` (`{"groups": [{"displayName": ..., "buckets": [...]}]}` or
/// top-level `buckets`) into percentage windows per quota pool (e.g. `5h gemini`, `7d gemini`,
/// `5h claude/gpt`, `7d claude/gpt`).
pub fn parse_antigravity_quota_summary(data: &[u8], now: Timestamp) -> Result<AccountUsage, UsageApiError> {
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(data) else {
        return Err(UsageApiError::Unreadable);
    };
    let mut windows: Vec<UsageWindow> = Vec::new();
    let mut push_bucket = |group_name: Option<&str>, bucket: &serde_json::Map<String, Value>| {
        if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let Some(remaining) = bucket.get("remainingFraction").and_then(number) else { return };
        let remaining = remaining.clamp(0.0, 1.0);
        let used_fraction = (1.0 - remaining).clamp(0.0, 1.0);
        let resets_at = bucket.get("resetTime").and_then(date);
        let window_raw = bucket.get("window").and_then(Value::as_str);
        let display_raw = bucket.get("displayName").and_then(Value::as_str);
        let bucket_id = bucket.get("bucketId").and_then(Value::as_str).unwrap_or("");
        let window_short = classify_antigravity_window(window_raw, display_raw, resets_at.as_ref(), &now);
        let family = antigravity_bucket_family(group_name, bucket_id);
        let label = match family {
            Some(family) => format!("{window_short} {family}"),
            None => window_short.to_owned(),
        };
        if let Some(existing) = windows.iter_mut().find(|w| w.label == label) {
            if used_fraction > existing.used_fraction {
                existing.used_fraction = used_fraction;
            }
            if existing.resets_at.is_none() {
                existing.resets_at = resets_at;
            }
        } else {
            windows.push(UsageWindow { label, used_fraction, resets_at });
        }
    };

    let groups = object.get("groups").and_then(Value::as_array);
    let mut found_grouped = false;
    if let Some(groups) = groups {
        for group in groups.iter().filter_map(Value::as_object) {
            let group_name = group.get("displayName").and_then(Value::as_str);
            if let Some(buckets) = group.get("buckets").and_then(Value::as_array) {
                for bucket in buckets.iter().filter_map(Value::as_object) {
                    found_grouped = true;
                    push_bucket(group_name, bucket);
                }
            }
        }
    }
    if !found_grouped && let Some(buckets) = object.get("buckets").and_then(Value::as_array) {
        for bucket in buckets.iter().filter_map(Value::as_object) {
            push_bucket(None, bucket);
        }
    }
    if windows.is_empty() {
        return Err(UsageApiError::Unreadable);
    }
    Ok(AccountUsage { windows, fetched_at: now })
}

/// Fallback parser for `fetchAvailableModels` (`{"models": {"...": {"quotaInfo": ...}}}`),
/// deduplicating shared model-family quota pools and preferring the tightest window per pool.
pub fn parse_antigravity_models_usage(data: &[u8], now: Timestamp) -> Result<AccountUsage, UsageApiError> {
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(data) else {
        return Err(UsageApiError::Unreadable);
    };
    let Some(models) = object.get("models").and_then(Value::as_object) else {
        return Err(UsageApiError::Unreadable);
    };
    let mut entries: Vec<(String, String, f64, Option<Timestamp>)> = Vec::new();
    for (_model_id, info) in models {
        let Some(info) = info.as_object() else { continue };
        let family = antigravity_model_family(info);
        let mut collect = |quota: &serde_json::Map<String, Value>, hint: Option<&str>| {
            let resets_at = quota.get("resetTime").and_then(date);
            let remaining = quota
                .get("remainingFraction")
                .and_then(number)
                .map(|r| r.clamp(0.0, 1.0))
                .or_else(|| resets_at.is_some().then_some(0.0));
            let Some(remaining) = remaining else { return };
            let used_fraction = (1.0 - remaining).clamp(0.0, 1.0);
            let window_id = quota.get("windowId").and_then(Value::as_str).or(hint);
            let window_label = quota.get("windowLabel").and_then(Value::as_str);
            let window_short =
                classify_antigravity_window(window_id, window_label, resets_at.as_ref(), &now).to_owned();
            entries.push((family.to_owned(), window_short, used_fraction, resets_at));
        };
        for (key, hint) in [
            ("quotaInfo", None),
            ("quotaInfos", None),
            ("dailyQuotaInfo", Some("daily")),
            ("dailyQuotaInfos", Some("daily")),
            ("weeklyQuotaInfo", Some("weekly")),
            ("weeklyQuotaInfos", Some("weekly")),
        ] {
            match info.get(key) {
                Some(Value::Object(q)) => collect(q, hint),
                Some(Value::Array(arr)) => {
                    for q in arr.iter().filter_map(Value::as_object) {
                        collect(q, hint);
                    }
                }
                _ => {}
            }
        }
        for map_key in ["quotaInfoByWindow", "quotaInfosByWindow"] {
            if let Some(map) = info.get(map_key).and_then(Value::as_object) {
                for (win_key, val) in map {
                    match val {
                        Value::Object(q) => collect(q, Some(win_key)),
                        Value::Array(arr) => {
                            for q in arr.iter().filter_map(Value::as_object) {
                                collect(q, Some(win_key));
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }
    // Skip unmetered entries (no resetTime) for a family that has metered entries.
    let metered_families: std::collections::HashSet<&str> = entries
        .iter()
        .filter(|(_, _, _, reset)| reset.is_some())
        .map(|(family, _, _, _)| family.as_str())
        .collect();
    let mut windows: Vec<UsageWindow> = Vec::new();
    for (family, window_short, used_fraction, resets_at) in &entries {
        if resets_at.is_none() && metered_families.contains(family.as_str()) {
            continue;
        }
        let label = if family.is_empty() { window_short.clone() } else { format!("{window_short} {family}") };
        if let Some(existing) = windows.iter_mut().find(|w| w.label == label) {
            if *used_fraction > existing.used_fraction {
                existing.used_fraction = *used_fraction;
            }
            if existing.resets_at.is_none() {
                existing.resets_at = *resets_at;
            }
        } else {
            windows.push(UsageWindow { label, used_fraction: *used_fraction, resets_at: *resets_at });
        }
    }
    if windows.is_empty() {
        return Err(UsageApiError::Unreadable);
    }
    Ok(AccountUsage { windows, fetched_at: now })
}

fn classify_antigravity_window(
    window_id: Option<&str>,
    display_name: Option<&str>,
    resets_at: Option<&Timestamp>,
    now: &Timestamp,
) -> &'static str {
    let source = format!("{} {}", window_id.unwrap_or(""), display_name.unwrap_or("")).to_lowercase();
    if source.contains("week")
        || source.contains("7d")
        || source.contains("7 day")
        || source.contains("7_day")
    {
        return "7d";
    }
    if source.contains("5h")
        || source.contains("five hour")
        || source.contains("five_hour")
        || source.contains("5 hour")
        || source.contains("5_hour")
    {
        return "5h";
    }
    if source.contains("day") || source.contains("daily") || source.contains("24h") {
        return "24h";
    }
    if let Some(resets_at) = resets_at {
        let secs = seconds_since_epoch(resets_at) - seconds_since_epoch(now);
        if secs > 86_400.0 {
            return "7d";
        }
        if secs > 0.0 && secs <= 5.5 * 3600.0 {
            return "5h";
        }
    }
    "5h"
}

fn antigravity_bucket_family(group_name: Option<&str>, bucket_id: &str) -> Option<&'static str> {
    let id = bucket_id.to_lowercase();
    let group = group_name.unwrap_or("").to_lowercase();
    if id.starts_with("gemini-argon-") {
        return Some("argon");
    }
    if id.starts_with("gemini-") || group.contains("gemini") {
        return Some("gemini");
    }
    if id.starts_with("3p-")
        || group.contains("claude")
        || group.contains("gpt")
        || group.contains("third party")
    {
        return Some("claude/gpt");
    }
    None
}

fn antigravity_model_family(info: &serde_json::Map<String, Value>) -> &'static str {
    match info.get("modelProvider").or_else(|| info.get("apiProvider")).and_then(Value::as_str) {
        Some("MODEL_PROVIDER_GOOGLE" | "API_PROVIDER_GOOGLE_GEMINI") => "gemini",
        Some(
            "MODEL_PROVIDER_ANTHROPIC"
            | "API_PROVIDER_ANTHROPIC_VERTEX"
            | "MODEL_PROVIDER_OPENAI"
            | "API_PROVIDER_OPENAI_VERTEX",
        ) => "claude/gpt",
        _ => "",
    }
}

// MARK: - Helpers

fn antigravity_headers(access_token: &str) -> Vec<(&'static str, String)> {
    let (os, arch) = if cfg!(target_os = "macos") {
        ("darwin", "arm64")
    } else if cfg!(target_os = "windows") {
        ("windows", "amd64")
    } else {
        ("linux", "amd64")
    };
    vec![
        ("Authorization", format!("Bearer {access_token}")),
        ("Content-Type", "application/json".to_owned()),
        (
            "User-Agent",
            format!("antigravity/hub/2.26.0 (aidev_client; os_type={os}; arch={arch}; cl=1005016104)"),
        ),
    ]
}

fn post_antigravity(path: &str, headers: &[(&str, String)], body: &[u8]) -> Result<Vec<u8>, UsageApiError> {
    let mut last_error = UsageApiError::Unreadable;
    for endpoint in [ANTIGRAVITY_PRIMARY_ENDPOINT, ANTIGRAVITY_SANDBOX_ENDPOINT] {
        let url = format!("{endpoint}{path}");
        match post(&url, headers, body) {
            Ok(data) => return Ok(data),
            Err(UsageApiError::Http(status)) if matches!(status, 429 | 500 | 502 | 503 | 504) => {
                last_error = UsageApiError::Http(status);
            }
            Err(UsageApiError::Transport(msg)) => {
                last_error = UsageApiError::Transport(msg);
            }
            Err(error) => return Err(error),
        }
    }
    Err(last_error)
}

fn post(url: &str, headers: &[(&str, String)], body: &[u8]) -> Result<Vec<u8>, UsageApiError> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(15)))
        .http_status_as_error(false)
        .build()
        .into();
    let mut request = agent.post(url);
    for (field, value) in headers {
        request = request.header(*field, value);
    }
    let mut response = request.send(body).map_err(|error| UsageApiError::Transport(error.to_string()))?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(UsageApiError::Http(status));
    }
    response.body_mut().read_to_vec().map_err(|error| UsageApiError::Transport(error.to_string()))
}

fn claude_headers(access_token: &str) -> Vec<(&'static str, String)> {
    vec![
        ("Authorization", format!("Bearer {access_token}")),
        ("anthropic-beta", "oauth-2025-04-20".to_owned()),
        ("User-Agent", "claude-code/2.1.0".to_owned()),
        ("Accept", "application/json".to_owned()),
    ]
}

fn get(url: &str, headers: &[(&str, String)]) -> Result<Vec<u8>, UsageApiError> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(15)))
        .http_status_as_error(false)
        .build()
        .into();
    let mut request = agent.get(url);
    for (field, value) in headers {
        request = request.header(*field, value);
    }
    let mut response = request.call().map_err(|error| UsageApiError::Transport(error.to_string()))?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(UsageApiError::Http(status));
    }
    response.body_mut().read_to_vec().map_err(|error| UsageApiError::Transport(error.to_string()))
}

/// A number, or a string holding one.
pub fn number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
}

static FRACTION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\.\d+").expect("valid pattern"));

/// ISO 8601 text (with or without fractional seconds), or epoch seconds or
/// milliseconds — the providers use all three.
pub fn date(value: &Value) -> Option<Timestamp> {
    if let Value::Number(number) = value {
        let seconds = number.as_f64()?;
        return timestamp_from_seconds(if seconds > 10_000_000_000.0 { seconds / 1000.0 } else { seconds });
    }
    let text = value.as_str().filter(|text| !text.is_empty())?;
    if let Ok(date) = DateTime::parse_from_rfc3339(text) {
        return Some(date.to_utc());
    }
    DateTime::parse_from_rfc3339(&FRACTION.replace_all(text, "")).ok().map(|date| date.to_utc())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: f64) -> Timestamp {
        timestamp_from_seconds(seconds).unwrap()
    }

    #[test]
    fn claude_usage_converts_percentages_and_microsecond_timestamps() {
        let json = r#"{
          "five_hour": { "utilization": 16.0, "resets_at": "2026-10-09T03:00:00.123456+00:00" },
          "seven_day": { "utilization": 12, "resets_at": "2026-10-15T10:00:00Z" },
          "seven_day_opus": null
        }"#;
        let usage = parse_claude_usage(json.as_bytes(), at(0.0)).unwrap();

        assert_eq!(usage.windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(), ["5h", "7d"]);
        assert_eq!(usage.windows[0].used_fraction, 0.16);
        let reset = usage.windows[0].resets_at.unwrap();
        assert!((seconds_since_epoch(&reset) - 1_791_514_800.0).abs() < 1.0);
        assert_eq!(usage.tightest().map(|w| w.label.as_str()), Some("5h"));
    }

    #[test]
    fn codex_usage_labels_windows_by_their_length_and_reads_epoch_resets() {
        let json = r#"{
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 15, "limit_window_seconds": 604800, "reset_at": 1791959189 },
            "secondary_window": { "used_percent": 140, "limit_window_seconds": 18000, "reset_after_seconds": 60 }
          }
        }"#;
        let now = at(1_000.0);
        let usage = parse_codex_usage(json.as_bytes(), now).unwrap();

        assert_eq!(usage.windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(), ["7d", "5h"]);
        assert_eq!(usage.windows[0].resets_at, Some(at(1_791_959_189.0)));
        // Percentages past 100 are clamped, as the Codex CLI shows them.
        assert_eq!(usage.windows[1].used_fraction, 1.0);
        assert_eq!(usage.windows[1].resets_at, Some(at(1_060.0)));
    }

    #[test]
    fn a_claude_profile_names_the_account_and_its_organization() {
        let identity =
            parse_claude_profile(br#"{"account":{"email_address":"a@b.c"},"organization":{"uuid":"o-1"}}"#)
                .unwrap();
        assert_eq!(identity, AccountIdentity::new("a@b.c", Some("o-1".into())));
        assert!(parse_claude_profile(br#"{"account":{"email":""}}"#).is_none());
    }

    #[test]
    fn usage_without_any_window_is_unreadable() {
        assert_eq!(parse_claude_usage(b"{}", at(0.0)), Err(UsageApiError::Unreadable));
        assert_eq!(parse_codex_usage(br#"{"rate_limit":{}}"#, at(0.0)), Err(UsageApiError::Unreadable));
    }

    #[test]
    fn dates_are_read_from_iso_text_and_epoch_seconds_or_milliseconds() {
        assert_eq!(date(&Value::from(1_791_511_800_000_i64)), Some(at(1_791_511_800.0)));
        assert_eq!(date(&Value::from(1_791_511_800_i64)), Some(at(1_791_511_800.0)));
        assert_eq!(date(&Value::from("1970-01-01T00:01:00Z")), Some(at(60.0)));
        assert_eq!(date(&Value::from("")), None);
        assert_eq!(window_label(18_000.0), "5h");
        assert_eq!(window_label(604_800.0), "7d");
        assert_eq!(window_label(129_600.0), "36h");
    }

    #[test]
    fn antigravity_quota_summary_parses_gemini_and_third_party_pools() {
        let json = r#"{
          "groups": [
            {
              "displayName": "Gemini",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0.72,
                  "resetTime": "2026-11-26T04:00:00Z"
                },
                {
                  "bucketId": "gemini-weekly",
                  "window": "weekly",
                  "remainingFraction": 0.84,
                  "resetTime": "2026-12-01T00:00:00Z"
                },
                {
                  "bucketId": "gemini-disabled",
                  "window": "5h",
                  "remainingFraction": 0.0,
                  "disabled": true
                }
              ]
            },
            {
              "displayName": "Claude & GPT",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "window": "five_hour",
                  "remainingFraction": 1.0,
                  "resetTime": "2026-11-26T04:00:00Z"
                }
              ]
            }
          ]
        }"#;
        let now = at(1_795_560_000.0);
        let usage = parse_antigravity_quota_summary(json.as_bytes(), now).unwrap();

        assert_eq!(
            usage.windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(),
            ["5h gemini", "7d gemini", "5h claude/gpt"]
        );
        assert!((usage.windows[0].used_fraction - 0.28).abs() < 1e-6);
        assert!((usage.windows[1].used_fraction - 0.16).abs() < 1e-6);
        assert!((usage.windows[2].used_fraction - 0.0).abs() < 1e-6);
    }

    #[test]
    fn antigravity_models_fallback_dedupes_families_and_skips_unmetered_when_metered_exists() {
        let json = r#"{
          "models": {
            "gemini-pro": {
              "modelProvider": "MODEL_PROVIDER_GOOGLE",
              "quotaInfo": { "remainingFraction": 0.6, "resetTime": "2026-11-26T04:00:00Z" }
            },
            "gemini-flash": {
              "modelProvider": "MODEL_PROVIDER_GOOGLE",
              "quotaInfo": { "remainingFraction": 0.9 }
            },
            "claude-sonnet": {
              "modelProvider": "MODEL_PROVIDER_ANTHROPIC",
              "quotaInfo": { "remainingFraction": 0.25, "resetTime": "2026-11-26T03:00:00Z" }
            }
          }
        }"#;
        let now = at(1_795_645_200.0);
        let usage = parse_antigravity_models_usage(json.as_bytes(), now).unwrap();

        assert_eq!(usage.windows.len(), 2);
        let gemini = usage.windows.iter().find(|w| w.label == "5h gemini").unwrap();
        assert!((gemini.used_fraction - 0.4).abs() < 1e-6);
        let third_party = usage.windows.iter().find(|w| w.label == "5h claude/gpt").unwrap();
        assert!((third_party.used_fraction - 0.75).abs() < 1e-6);
    }
}
