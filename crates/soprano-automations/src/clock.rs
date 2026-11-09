//! Where automations get the time and the time zone schedules are read in: injectable so
//! tests run schedules at any hour.

use std::sync::Mutex;

use chrono::{DateTime, Utc};
use chrono_tz::Tz;

pub trait Clock: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
    /// The zone a schedule's wall-clock times are in; follows the machine as it moves (travel).
    fn time_zone(&self) -> Tz;
}

/// The machine's clock and its current time zone, read again on every call.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }

    fn time_zone(&self) -> Tz {
        iana_time_zone::get_timezone().ok().and_then(|name| name.parse().ok()).unwrap_or(Tz::UTC)
    }
}

/// A clock that stays where it is set.
#[derive(Debug)]
pub struct FixedClock {
    now: Mutex<DateTime<Utc>>,
    zone: Tz,
}

impl FixedClock {
    pub fn new(now: DateTime<Utc>, zone: Tz) -> Self {
        Self { now: Mutex::new(now), zone }
    }

    pub fn set(&self, now: DateTime<Utc>) {
        *self.now.lock().unwrap_or_else(|e| e.into_inner()) = now;
    }
}

impl Clock for FixedClock {
    fn now(&self) -> DateTime<Utc> {
        *self.now.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn time_zone(&self) -> Tz {
        self.zone
    }
}
