//! The timeline's times (`TimelineFormat`, `WorkingRowView.elapsed`): day-aware timestamps
//! ("3:42 PM", "yesterday at 3:42 PM", "3/14 3:42 PM", with the year when it differs), their
//! full-date tooltip, and the "Working for" clock.

use chrono::{DateTime, Datelike, Local, TimeZone};
use soprano_agents::{Date, turn_duration_text};

/// "" for a replayed item, which has no time.
pub fn timestamp(date: Option<Date>) -> String {
    timestamp_in(date, chrono::Utc::now(), &Local)
}

/// [`timestamp`] against `now` in `zone`.
pub fn timestamp_in<Tz: TimeZone>(date: Option<Date>, now: Date, zone: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    let Some(date) = date else { return String::new() };
    let date: DateTime<Tz> = date.with_timezone(zone);
    let now: DateTime<Tz> = now.with_timezone(zone);
    let clock = date.format("%-I:%M %p").to_string();
    let days = (now.date_naive() - date.date_naive()).num_days();
    if days <= 0 {
        return clock;
    }
    if days == 1 {
        return format!("yesterday at {clock}");
    }
    let day = if date.year() == now.year() {
        date.format("%-m/%-d").to_string()
    } else {
        date.format("%-m/%-d/%y").to_string()
    };
    format!("{day} {clock}")
}

/// Tooltip: the full date and time.
pub fn tooltip(date: Option<Date>) -> Option<String> {
    tooltip_in(date, &Local)
}

pub fn tooltip_in<Tz: TimeZone>(date: Option<Date>, zone: &Tz) -> Option<String>
where
    Tz::Offset: std::fmt::Display,
{
    let date = date?.with_timezone(zone);
    Some(date.format("%A, %B %-d, %Y at %-I:%M:%S %p").to_string())
}

/// "Working for 12s" while a turn runs ("Stopping… 12s" once Stop was pressed); "Working" /
/// "Stopping…" for a turn without a start time.
pub fn working_label(started_at: Option<Date>, stopping: bool, now: Date) -> String {
    let Some(started_at) = started_at else {
        return if stopping { "Stopping…".into() } else { "Working".into() };
    };
    let elapsed = working_elapsed(started_at, now);
    if stopping { format!("Stopping… {elapsed}") } else { format!("Working for {elapsed}") }
}

/// "12s" under a minute, else "1m 12s".
pub fn working_elapsed(start: Date, now: Date) -> String {
    let seconds = (now - start).num_seconds().max(0);
    if seconds < 60 { format!("{seconds}s") } else { turn_duration_text(seconds as f64) }
}

#[cfg(test)]
mod tests {
    use chrono::{FixedOffset, Utc};

    use super::*;

    fn utc(y: i32, m: u32, d: u32, h: u32, min: u32) -> Date {
        Utc.with_ymd_and_hms(y, m, d, h, min, 0).single().expect("date")
    }

    #[test]
    fn timestamps_name_the_day_only_when_it_is_not_today() {
        let zone = FixedOffset::east_opt(0).expect("zone");
        let now = utc(2026, 3, 14, 18, 0);
        assert_eq!(timestamp_in(Some(utc(2026, 3, 14, 15, 42)), now, &zone), "3:42 PM");
        assert_eq!(timestamp_in(Some(utc(2026, 3, 13, 15, 42)), now, &zone), "yesterday at 3:42 PM");
        assert_eq!(timestamp_in(Some(utc(2026, 3, 1, 9, 5)), now, &zone), "3/1 9:05 AM");
        assert_eq!(timestamp_in(Some(utc(2025, 12, 31, 9, 5)), now, &zone), "12/31/25 9:05 AM");
        assert_eq!(timestamp_in(None, now, &zone), "");
        assert_eq!(
            tooltip_in(Some(utc(2026, 3, 14, 15, 42)), &zone).as_deref(),
            Some("Saturday, March 14, 2026 at 3:42:00 PM")
        );
    }

    #[test]
    fn the_working_clock_counts_seconds_then_minutes() {
        let start = utc(2026, 3, 14, 15, 0);
        assert_eq!(
            working_label(Some(start), false, start + chrono::Duration::seconds(12)),
            "Working for 12s"
        );
        assert_eq!(
            working_label(Some(start), true, start + chrono::Duration::seconds(72)),
            "Stopping… 1m 12s"
        );
        assert_eq!(working_label(None, false, start), "Working");
        assert_eq!(working_label(None, true, start), "Stopping…");
    }
}
