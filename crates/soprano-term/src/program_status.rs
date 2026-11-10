//! The Program Status Protocol (OSC 7501, revision 0.4): a program reports whether it is
//! working, blocked on the user, done, failed or idle. Only the parser lives here; the values
//! are `soprano_types::program_status`, and what a report means for a pane is the host's
//! business.

use base64::Engine as _;
use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
pub use soprano_types::program_status::{BlockedKind, ProgramState, ProgramStatus};

/// The longest complete frame, terminator included.
pub const MAX_FRAME: usize = 4096;
const MAX_KEY: usize = 16;
const MAX_MSG_ENCODED: usize = 2732;
const MAX_MSG: usize = 2048;
const MAX_TITLE_ENCODED: usize = 256;
const MAX_TITLE: usize = 192;
const MAX_APP: usize = 32;
const MAX_ID: usize = 128;
const MAX_SEGMENT: usize = 32;
const MAX_SEGMENTS: usize = 8;

/// What the terminal answers a capability query (`OSC 7501;?`) with.
pub const CAPABILITY_REPLY: &[u8] =
    b"\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\";

/// What an OSC 7501 body (everything after `7501;`) asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProgramStatusMessage {
    Report(ProgramStatus),
    /// `OSC 7501;?`: which states and kinds the terminal shows.
    Query,
}

/// Parses the body of an OSC 7501 sequence after its `7501;` prefix. `None` for a report the
/// protocol says to ignore or reject.
pub fn parse(body: &str) -> Option<ProgramStatusMessage> {
    // `OSC 7501;` + body + the two-byte ST.
    if body.len() + 9 > MAX_FRAME {
        return None;
    }
    if body.trim_start_matches(is_space).starts_with('?') {
        return Some(ProgramStatusMessage::Query);
    }
    let mut state = None;
    let mut id: Option<&str> = None;
    let mut kind = None;
    let mut progress = None;
    let mut app = None;
    let mut title = None;
    let mut msg = None;
    for pair in body.split(':') {
        let Some((key, value)) = pair.split_once('=') else { continue };
        let key = key.trim_matches(is_space);
        let value = value.trim_matches(is_space);
        if key.len() > MAX_KEY {
            return None;
        }
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_lowercase()) {
            continue;
        }
        // Limits apply before a malformed or overwritten value is skipped.
        match key {
            "app" if value.len() > MAX_APP => return None,
            "id" if value.len() > MAX_ID => return None,
            "title" if value.len() > MAX_TITLE_ENCODED => return None,
            "msg" if value.len() > MAX_MSG_ENCODED => return None,
            _ => {}
        }
        let valid_value = value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b));
        match key {
            // A recognizable but invalid text rejects the whole report.
            "title" => title = Some(decode_text(value, valid_value, MAX_TITLE)?),
            "msg" => msg = Some(decode_text(value, valid_value, MAX_MSG)?),
            _ if !valid_value => {
                if key == "id" {
                    // An invalid id never falls back to root; a later valid one may replace it.
                    id = Some(value);
                }
            }
            "state" => state = Some(value),
            "id" => id = Some(value),
            "kind" => kind = Some(value),
            "progress" => progress = Some(value),
            "app" => app = Some(value),
            _ => {}
        }
    }
    let state = match state? {
        "idle" => ProgramState::Idle,
        "working" => ProgramState::Working,
        "blocked" => ProgramState::Blocked,
        "done" => ProgramState::Done,
        "error" => ProgramState::Error,
        "clear" => ProgramState::Clear,
        _ => return None,
    };
    let id = match id {
        None => None,
        Some(id) if valid_id(id) => Some(id.to_owned()),
        Some(_) => return None,
    };
    let kind = kind.filter(|_| state == ProgramState::Blocked).and_then(|kind| match kind {
        "permission" => Some(BlockedKind::Permission),
        "question" => Some(BlockedKind::Question),
        "auth" => Some(BlockedKind::Auth),
        _ => None,
    });
    let progress = progress
        .filter(|_| matches!(state, ProgramState::Working | ProgramState::Blocked))
        .filter(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|p| p.parse::<u8>().ok())
        .filter(|p| *p <= 100);
    let app = app.filter(|a| !a.is_empty()).map(str::to_owned);
    Some(ProgramStatusMessage::Report(ProgramStatus { state, id, kind, progress, app, title, msg }))
}

fn is_space(c: char) -> bool {
    c.is_ascii_whitespace()
}

fn valid_id(id: &str) -> bool {
    let segments: Vec<&str> = id.split('/').collect();
    segments.len() <= MAX_SEGMENTS
        && segments.iter().all(|segment| {
            (1..=MAX_SEGMENT).contains(&segment.len())
                && segment.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b))
        })
}

/// Standard base64 with complete or no padding and canonical unused bits, decoding to UTF-8
/// without control characters.
fn decode_text(value: &str, valid_value: bool, limit: usize) -> Option<String> {
    const ENGINE: GeneralPurpose = GeneralPurpose::new(
        &alphabet::STANDARD,
        GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
    );
    if !valid_value || (value.contains('=') && !value.len().is_multiple_of(4)) {
        return None;
    }
    let bytes = ENGINE.decode(value).ok()?;
    if bytes.len() > limit {
        return None;
    }
    let text = String::from_utf8(bytes).ok()?;
    if text.chars().any(|c| c.is_control()) {
        return None;
    }
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(body: &str) -> Option<ProgramStatus> {
        match parse(body)? {
            ProgramStatusMessage::Report(report) => Some(report),
            ProgramStatusMessage::Query => None,
        }
    }

    #[test]
    fn a_blocked_report_carries_its_kind_app_and_text() {
        let status =
            report("state=blocked:kind=permission:app=claude-code:title=Q2xhdWRl:msg=QXBwcm92ZT8=").unwrap();
        assert_eq!(status.state, ProgramState::Blocked);
        assert_eq!(status.kind, Some(BlockedKind::Permission));
        assert_eq!(status.app.as_deref(), Some("claude-code"));
        assert_eq!(status.title.as_deref(), Some("Claude"));
        assert_eq!(status.msg.as_deref(), Some("Approve?"));
        assert_eq!(status.id, None);
    }

    #[test]
    fn unknown_states_and_keys_are_ignored_and_the_last_value_wins() {
        assert_eq!(report("state=sleeping"), None);
        assert_eq!(report("app=x"), None);
        let status = report(" state = working : color=red : state=done : progress=50 ").unwrap();
        assert_eq!(status.state, ProgramState::Done);
        // Progress applies only to working and blocked.
        assert_eq!(status.progress, None);
        assert_eq!(report("state=working:progress=101").unwrap().progress, None);
        assert_eq!(report("state=working:progress=42").unwrap().progress, Some(42));
        assert_eq!(report("state=done:kind=permission").unwrap().kind, None);
    }

    #[test]
    fn bad_text_or_ids_reject_the_whole_report() {
        // Partial padding, invalid UTF-8, a control character.
        assert_eq!(report("state=done:msg=YQ="), None);
        assert_eq!(report("state=done:msg=/w=="), None);
        assert_eq!(report("state=done:msg=YQph"), None);
        // An invalid text overwritten later still rejects.
        assert_eq!(report("state=done:title=YQ=:title=YQ=="), None);
        assert_eq!(report("state=done:id=a//b"), None);
        assert_eq!(report("state=done:id=a b"), None);
        assert_eq!(report("state=done:id=bad id:id=build/test").unwrap().id.as_deref(), Some("build/test"));
        assert_eq!(report(&format!("state=done:app={}", "a".repeat(33))), None);
        assert_eq!(report(&format!("state=done:{}=1", "k".repeat(17))), None);
    }

    #[test]
    fn a_query_asks_for_the_capabilities() {
        assert_eq!(parse("?"), Some(ProgramStatusMessage::Query));
        assert_eq!(parse("?:states=idle"), Some(ProgramStatusMessage::Query));
    }
}
