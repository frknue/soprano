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

// MARK: - Helpers

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
}
