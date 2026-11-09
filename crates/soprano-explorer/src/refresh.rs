//! When the panels re-read git: one read at a time, bursts coalesced into one read at most
//! every two seconds, and a read requested during another one repeated once it finishes
//! (`scheduleGitRefresh` / `finishGitRefresh` in both Swift panels).

use std::time::{Duration, Instant};

use soprano_files::tree::git_refresh_delay;

#[derive(Debug, Default)]
pub(crate) struct RefreshGate {
    in_flight: bool,
    pending: bool,
    scheduled: bool,
    last: Option<Instant>,
}

impl RefreshGate {
    /// Asks for a read. Returns the delay to wait before [`Self::begin`] when a new timer
    /// must be started (replacing any scheduled one), or `None` when the request is folded
    /// into a read that is running or already scheduled.
    pub(crate) fn schedule(&mut self, immediately: bool, now: Instant) -> Option<Duration> {
        if self.in_flight {
            self.pending = true;
            return None;
        }
        if self.scheduled && !immediately {
            return None;
        }
        self.scheduled = true;
        let since_last = self.last.map_or(Duration::MAX, |last| now.saturating_duration_since(last));
        Some(git_refresh_delay(immediately, since_last))
    }

    /// The timer fired and the read starts.
    pub(crate) fn begin(&mut self, now: Instant) {
        self.scheduled = false;
        self.in_flight = true;
        self.last = Some(now);
    }

    /// The read finished; returns whether another (coalesced) read must be scheduled.
    pub(crate) fn finish(&mut self) -> bool {
        self.in_flight = false;
        std::mem::take(&mut self.pending)
    }

    /// The scheduled timer was dropped (panel hidden, root changed).
    pub(crate) fn cancel(&mut self) {
        self.scheduled = false;
        self.pending = false;
    }

    pub(crate) fn is_in_flight(&self) -> bool {
        self.in_flight
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_read_during_another_is_repeated_once_it_finishes() {
        let mut gate = RefreshGate::default();
        let now = Instant::now();
        assert_eq!(gate.schedule(true, now), Some(Duration::ZERO));
        gate.begin(now);
        assert_eq!(gate.schedule(false, now), None);
        assert_eq!(gate.schedule(true, now), None);
        assert!(gate.finish());
        assert!(!gate.finish());
    }

    #[test]
    fn bursts_wait_for_the_scheduled_read_unless_asked_for_immediately() {
        let mut gate = RefreshGate::default();
        let now = Instant::now();
        gate.begin(now);
        gate.finish();
        let delay = gate.schedule(false, now).expect("scheduled");
        assert!(delay >= Duration::from_millis(1900));
        assert_eq!(gate.schedule(false, now), None);
        assert_eq!(gate.schedule(true, now), Some(Duration::ZERO));
    }
}
