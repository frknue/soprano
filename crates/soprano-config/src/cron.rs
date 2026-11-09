//! Five-field cron schedules for automations and the editor's named cadences
//! (`Automations/CronSchedule.swift`). Lives here because `settings.json`'s `automations`
//! entries are validated by parsing their `schedule`.

use std::collections::BTreeSet;
use std::fmt;

use chrono::{DateTime, Datelike, Duration, LocalResult, NaiveDate, TimeZone, Timelike};

/// Why an expression is not a schedule; `message` is shown to the user verbatim.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CronParseError {
    pub message: String,
}

impl fmt::Display for CronParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CronParseError {}

fn error(message: impl Into<String>) -> CronParseError {
    CronParseError { message: message.into() }
}

/// A five-field cron expression — minute, hour, day of month, month, day of week — evaluated
/// in a caller-chosen time zone (the machine's own by default).
///
/// Fields take `*`, numbers, `a-b` ranges, `,` lists, and `/n` steps. Day of week runs 0–7,
/// where both 0 and 7 are Sunday, and months and weekdays also take their three-letter English
/// names (`jan`, `mon`). As in cron, when both day fields are restricted a day matching either
/// one runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CronSchedule {
    /// The expression as written, whitespace collapsed.
    pub expression: String,
    pub minutes: BTreeSet<u32>,
    pub hours: BTreeSet<u32>,
    pub days_of_month: BTreeSet<u32>,
    pub months: BTreeSet<u32>,
    /// 0 = Sunday … 6 = Saturday.
    pub weekdays: BTreeSet<u32>,
    pub restricts_day_of_month: bool,
    pub restricts_weekday: bool,
}

struct Field {
    name: &'static str,
    low: u32,
    high: u32,
    names: &'static [&'static str],
    /// Value of `names[0]`.
    names_base: u32,
}

const FIELDS: [Field; 5] = [
    Field { name: "minute", low: 0, high: 59, names: &[], names_base: 0 },
    Field { name: "hour", low: 0, high: 23, names: &[], names_base: 0 },
    Field { name: "day of month", low: 1, high: 31, names: &[], names_base: 0 },
    Field {
        name: "month",
        low: 1,
        high: 12,
        names: &["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"],
        names_base: 1,
    },
    Field {
        name: "day of week",
        low: 0,
        high: 7,
        names: &["sun", "mon", "tue", "wed", "thu", "fri", "sat"],
        names_base: 0,
    },
];

impl CronSchedule {
    pub fn parse(text: &str) -> Result<Self, CronParseError> {
        let parts: Vec<String> = text.split_whitespace().map(str::to_lowercase).collect();
        if parts.len() != 5 {
            return Err(error("A schedule has five fields: minute, hour, day of month, month, day of week."));
        }
        let mut sets = Vec::with_capacity(5);
        for (part, field) in parts.iter().zip(FIELDS.iter()) {
            sets.push(values(part, field)?);
        }
        let weekdays = sets[4].iter().map(|day| day % 7).collect();
        Ok(Self {
            expression: parts.join(" "),
            minutes: sets[0].clone(),
            hours: sets[1].clone(),
            days_of_month: sets[2].clone(),
            months: sets[3].clone(),
            weekdays,
            restricts_day_of_month: !parts[2].starts_with('*'),
            restricts_weekday: !parts[4].starts_with('*'),
        })
    }

    /// Whether the schedule runs on a day with this day of month and weekday (0 = Sunday).
    fn runs_on_day(&self, day: u32, weekday: u32) -> bool {
        let day_matches = self.days_of_month.contains(&day);
        let weekday_matches = self.weekdays.contains(&weekday);
        match (self.restricts_day_of_month, self.restricts_weekday) {
            (true, true) => day_matches || weekday_matches,
            (true, false) => day_matches,
            (false, true) => weekday_matches,
            (false, false) => true,
        }
    }

    /// The first minute strictly after `date` the schedule runs at, in `date`'s time zone.
    /// Searches up to eight years ahead, far enough for any February 29th; `None` means the
    /// expression names a date that never comes, such as `0 0 31 2 *`.
    pub fn next_occurrence<Tz: TimeZone>(&self, date: &DateTime<Tz>) -> Option<DateTime<Tz>> {
        let zone = date.timezone();
        let start_minute = date.with_second(0)?.with_nanosecond(0)?;
        let first = start_minute + Duration::minutes(1);
        let mut day: NaiveDate = first.date_naive();
        for _ in 0..(366 * 8) {
            if self.months.contains(&day.month())
                && self.runs_on_day(day.day(), day.weekday().num_days_from_sunday())
            {
                for &hour in &self.hours {
                    for &minute in &self.minutes {
                        let Some(naive) = day.and_hms_opt(hour, minute, 0) else { continue };
                        // A time the clocks skip (a spring-forward gap) does not exist that
                        // day; a repeated one runs at its first occurrence.
                        let candidate = match zone.from_local_datetime(&naive) {
                            LocalResult::Single(candidate) => candidate,
                            LocalResult::Ambiguous(earliest, _) => earliest,
                            LocalResult::None => continue,
                        };
                        if candidate >= first {
                            return Some(candidate);
                        }
                    }
                }
            }
            day = day.succ_opt()?;
        }
        None
    }

    /// The latest occurrence in `start..=end`, where `start` is itself an occurrence (the run
    /// that was due), or `None` when `start` is after `end`.
    pub fn latest_occurrence<Tz: TimeZone>(
        &self,
        start: &DateTime<Tz>,
        end: &DateTime<Tz>,
    ) -> Option<DateTime<Tz>> {
        if start > end {
            return None;
        }
        let mut latest = start.clone();
        while let Some(next) = self.next_occurrence(&latest) {
            if next > *end {
                break;
            }
            latest = next;
        }
        Some(latest)
    }
}

impl std::str::FromStr for CronSchedule {
    type Err = CronParseError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        Self::parse(text)
    }
}

fn values(part: &str, field: &Field) -> Result<BTreeSet<u32>, CronParseError> {
    let mut result = BTreeSet::new();
    for item in part.split(',') {
        if item.is_empty() {
            return Err(error(format!("The {} field has an empty list item.", field.name)));
        }
        let pieces: Vec<&str> = item.split('/').collect();
        if pieces.len() > 2 {
            return Err(error(format!("The {} field has more than one step in \"{item}\".", field.name)));
        }
        let mut step = 1;
        if pieces.len() == 2 {
            step = match parse_int(pieces[1]) {
                Some(value) if value > 0 => value as u32,
                _ => {
                    return Err(error(format!(
                        "The {} step in \"{item}\" must be a positive number.",
                        field.name
                    )));
                }
            };
        }
        let (low, high) = if pieces[0] == "*" {
            (field.low, field.high)
        } else {
            let ends: Vec<&str> = pieces[0].split('-').collect();
            if ends.len() > 2 {
                return Err(error(format!("The {} field has a malformed range \"{item}\".", field.name)));
            }
            let low = value(ends[0], field)?;
            let high = if ends.len() == 2 {
                value(ends[1], field)?
            } else if pieces.len() == 2 {
                field.high
            } else {
                low
            };
            if low > high {
                return Err(error(format!("The {} range \"{}\" runs backwards.", field.name, pieces[0])));
            }
            (low, high)
        };
        result.extend((low..=high).step_by(step as usize));
    }
    Ok(result)
}

/// Swift's `Int(String)`: optional sign, ASCII digits.
fn parse_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

fn value(text: &str, field: &Field) -> Result<u32, CronParseError> {
    if let Some(number) = parse_int(text) {
        if number < i64::from(field.low) || number > i64::from(field.high) {
            return Err(error(format!(
                "{number} is outside the {} range {}–{}.",
                field.name, field.low, field.high
            )));
        }
        return Ok(number as u32);
    }
    if let Some(index) = field.names.iter().position(|name| *name == text) {
        return Ok(field.names_base + index as u32);
    }
    Err(error(format!("\"{text}\" is not a valid {}.", field.name)))
}

/// The schedules the editor offers by name; anything else is custom cron.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AutomationCadence {
    Hourly {
        minute: u32,
    },
    Daily {
        hour: u32,
        minute: u32,
    },
    Weekdays {
        hour: u32,
        minute: u32,
    },
    /// `weekday`: 0 = Sunday … 6 = Saturday.
    Weekly {
        weekday: u32,
        hour: u32,
        minute: u32,
    },
    Custom(String),
}

const WEEKDAY_NAMES: [&str; 7] =
    ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

impl AutomationCadence {
    pub fn from_schedule(schedule: &CronSchedule) -> Self {
        let custom = || Self::Custom(schedule.expression.clone());
        let every_day = !schedule.restricts_day_of_month && schedule.months.len() == 12;
        let minute = match schedule.minutes.iter().next() {
            Some(&minute) if every_day && schedule.minutes.len() == 1 => minute,
            _ => return custom(),
        };
        if schedule.hours.len() == 24 && !schedule.restricts_weekday {
            return Self::Hourly { minute };
        }
        let hour = match schedule.hours.iter().next() {
            Some(&hour) if schedule.hours.len() == 1 => hour,
            _ => return custom(),
        };
        if !schedule.restricts_weekday || schedule.weekdays.len() == 7 {
            Self::Daily { hour, minute }
        } else if schedule.weekdays == (1..=5).collect::<BTreeSet<u32>>() {
            Self::Weekdays { hour, minute }
        } else if schedule.weekdays.len() == 1 {
            let weekday = schedule.weekdays.iter().next().copied().unwrap_or_default();
            Self::Weekly { weekday, hour, minute }
        } else {
            custom()
        }
    }

    pub fn expression(&self) -> String {
        match self {
            Self::Hourly { minute } => format!("{minute} * * * *"),
            Self::Daily { hour, minute } => format!("{minute} {hour} * * *"),
            Self::Weekdays { hour, minute } => format!("{minute} {hour} * * 1-5"),
            Self::Weekly { weekday, hour, minute } => format!("{minute} {hour} * * {weekday}"),
            Self::Custom(expression) => expression.clone(),
        }
    }

    /// "Weekdays at 9:00 AM", "Hourly at :15", "Thursdays at 2:00 PM".
    pub fn summary(&self) -> String {
        match self {
            Self::Hourly { minute } => format!("Hourly at :{minute:02}"),
            Self::Daily { hour, minute } => format!("Daily at {}", Self::time(*hour, *minute)),
            Self::Weekdays { hour, minute } => format!("Weekdays at {}", Self::time(*hour, *minute)),
            Self::Weekly { weekday, hour, minute } => {
                format!("{}s at {}", WEEKDAY_NAMES[(*weekday % 7) as usize], Self::time(*hour, *minute))
            }
            Self::Custom(expression) => expression.clone(),
        }
    }

    /// A short clock time, `2:00 PM`.
    pub fn time(hour: u32, minute: u32) -> String {
        let period = if hour < 12 { "AM" } else { "PM" };
        let twelve = match hour % 12 {
            0 => 12,
            other => other,
        };
        format!("{twelve}:{minute:02} {period}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Local, NaiveDateTime};
    use chrono_tz::{Europe::Berlin, Tz};

    fn date(text: &str) -> DateTime<Tz> {
        let naive = NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M").expect("date");
        Berlin.from_local_datetime(&naive).earliest().expect("exists in Berlin")
    }

    fn schedule(text: &str) -> CronSchedule {
        CronSchedule::parse(text).expect("parses")
    }

    fn set(values: &[u32]) -> BTreeSet<u32> {
        values.iter().copied().collect()
    }

    #[test]
    fn a_weekday_schedule_due_on_friday_evening_next_runs_on_monday_morning() {
        // 2026-10-30 is a Friday.
        let next = schedule("0 9 * * 1-5").next_occurrence(&date("2026-10-30 10:00"));
        assert_eq!(next, Some(date("2026-11-02 09:00")));
    }

    #[test]
    fn the_next_occurrence_is_strictly_after_the_time_it_is_asked_from() {
        let next = schedule("30 * * * *").next_occurrence(&date("2026-10-29 08:30"));
        assert_eq!(next, Some(date("2026-10-29 09:30")));
    }

    #[test]
    fn when_both_day_fields_are_restricted_either_one_matching_runs() {
        // The 13th, or any Friday — cron's rule, not "Friday the 13th".
        let next = schedule("0 12 13 * 5").next_occurrence(&date("2026-10-29 13:00"));
        assert_eq!(next, Some(date("2026-10-30 12:00")));
    }

    #[test]
    fn steps_ranges_lists_and_names_expand_to_the_times_they_name() {
        let schedule = schedule("*/15 9-11,14 * jan-mar MON-fri");
        assert_eq!(schedule.minutes, set(&[0, 15, 30, 45]));
        assert_eq!(schedule.hours, set(&[9, 10, 11, 14]));
        assert_eq!(schedule.months, set(&[1, 2, 3]));
        assert_eq!(schedule.weekdays, set(&[1, 2, 3, 4, 5]));
    }

    #[test]
    fn seven_and_zero_both_mean_sunday() {
        assert_eq!(schedule("0 9 * * 7").weekdays, set(&[0]));
        assert_eq!(schedule("0 9 * * 0").weekdays, set(&[0]));
    }

    #[test]
    fn a_value_outside_its_field_is_rejected_with_the_field_and_range_named() {
        assert_eq!(CronSchedule::parse("61 * * * *"), Err(error("61 is outside the minute range 0–59.")));
    }

    #[test]
    fn an_expression_without_five_fields_is_rejected() {
        assert!(CronSchedule::parse("0 9 * *").is_err());
    }

    #[test]
    fn a_date_that_never_comes_has_no_next_occurrence() {
        assert_eq!(schedule("0 0 31 2 *").next_occurrence(&Local::now()), None);
    }

    #[test]
    fn a_time_the_clocks_skip_is_not_run_that_day() {
        // Clocks in Berlin jump from 02:00 to 03:00 on 2026-03-29.
        let next = schedule("30 2 * * *").next_occurrence(&date("2026-03-28 03:00"));
        assert_eq!(next, Some(date("2026-03-30 02:30")));
    }

    #[test]
    fn the_latest_occurrence_of_a_span_is_the_last_one_not_after_its_end() {
        let latest =
            schedule("15 * * * *").latest_occurrence(&date("2026-10-29 01:15"), &date("2026-10-29 07:40"));
        assert_eq!(latest, Some(date("2026-10-29 07:15")));
    }

    #[test]
    fn the_editors_presets_are_recognized_from_their_cron_and_written_back_the_same() {
        let presets = [
            AutomationCadence::Hourly { minute: 15 },
            AutomationCadence::Daily { hour: 16, minute: 30 },
            AutomationCadence::Weekdays { hour: 9, minute: 0 },
            AutomationCadence::Weekly { weekday: 4, hour: 14, minute: 0 },
        ];
        for preset in presets {
            assert_eq!(AutomationCadence::from_schedule(&schedule(&preset.expression())), preset);
        }
    }

    #[test]
    fn a_schedule_no_preset_describes_stays_custom() {
        assert_eq!(
            AutomationCadence::from_schedule(&schedule("0 9,17 * * 1-5")),
            AutomationCadence::Custom("0 9,17 * * 1-5".into())
        );
    }

    #[test]
    fn presets_summarize_the_way_the_editor_names_them() {
        assert_eq!(AutomationCadence::Hourly { minute: 5 }.summary(), "Hourly at :05");
        assert!(
            AutomationCadence::Weekly { weekday: 4, hour: 14, minute: 0 }
                .summary()
                .starts_with("Thursdays at 2:00")
        );
        assert_eq!(AutomationCadence::Daily { hour: 0, minute: 5 }.summary(), "Daily at 12:05 AM");
    }
}
